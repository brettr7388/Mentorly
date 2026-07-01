//
//  CompanionManager.swift
//  Mentorly
//
//  Central state manager for Mentorly's ask flow. Owns the global shortcut
//  monitor, the screen-region capture, the Ask Window, the streaming
//  Claude call, and the ambient cursor overlay.
//

import Combine
import Foundation
import ScreenCaptureKit
import SwiftUI

enum CompanionAskState {
    case idle
    case processing
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var askState: CompanionAskState = .idle
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// True while the region-selection-through-Ask-Window sequence is active,
    /// so a second Control+C press doesn't spawn another selection on top
    /// of one already in progress. Cleared once the user submits or cancels.
    @Published private(set) var isAskFlowInProgress = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Only used by the onboarding demo —
    /// the main ask flow uses a manually-selected screen region, so we don't
    /// know its on-screen origin and can't point at anything within it.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    /// Persistent arrows drawn on the REAL screen in live mode, each pinned to
    /// an actual UI control whose exact frame came from the Accessibility tree.
    /// Several can show at once (e.g. numbered how-to steps) and they stay up
    /// while the user reads the answer. Cleared when a new ask begins or the
    /// answer window closes.
    @Published var liveArrowTargets: [LiveArrowTarget] = []

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the welcome
    /// message and pointing demo finish.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    // MARK: - Capture Prompt Bubble

    /// Typewriter-streamed bubble shown on the blue cursor the moment the ask
    /// hotkey is pressed — "take a screenshot for ilearn to see and help" in
    /// black text — giving the user a beat to read it before the system
    /// screenshot selection UI takes over. Cleared right before capture starts.
    @Published var capturePromptText: String = ""
    @Published var capturePromptOpacity: Double = 0.0
    @Published var showCapturePrompt: Bool = false

    let globalAskShortcutMonitor = GlobalAskShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    let askWindowManager = AskWindowManager()

    /// Base URL for the Cloudflare Worker proxy. Only used when the backend is
    /// the paid API path (`useClaudeCodeBackend == false`). Read from
    /// UserDefaults (set once locally via `defaults write`, never committed)
    /// rather than hardcoded.
    private static let workerBaseURL = UserDefaults.standard.string(forKey: "workerBaseURL")
        ?? "https://your-worker-name.your-subdomain.workers.dev"

    /// Shared secret the Worker requires as a bearer token, so a leaked Worker
    /// URL can't be used to run up Anthropic charges. Set locally with
    /// `defaults write com.ilearn.app workerAuthToken "<token>"` — the same value
    /// stored on the Worker as the `PROXY_AUTH_TOKEN` secret. Never committed.
    private static let workerAuthToken = UserDefaults.standard.string(forKey: "workerAuthToken")

    /// Whether to answer using the local Claude Code CLI (the user's Claude
    /// subscription, no API key, no per-token billing) instead of the
    /// Cloudflare Worker + Anthropic API key. Defaults to the subscription
    /// path. Set `defaults write com.ilearn.app useClaudeCodeBackend -bool false`
    /// to fall back to the Worker.
    private static var useClaudeCodeBackend: Bool {
        if UserDefaults.standard.object(forKey: "useClaudeCodeBackend") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "useClaudeCodeBackend")
    }

    /// The active answer backend. Either `ClaudeCodeBackend` (local CLI on the
    /// user's subscription) or `ClaudeAPI` (Worker proxy + API key), chosen by
    /// `useClaudeCodeBackend`. Both expose the same streaming call.
    private lazy var claudeBackend: ClaudeBackend = {
        if Self.useClaudeCodeBackend {
            print("🧠 Mentorly answer backend: Claude Code CLI (subscription)")
            return ClaudeCodeBackend(model: selectedModel)
        } else {
            print("🧠 Mentorly answer backend: Cloudflare Worker (API key)")
            return ClaudeAPI(proxyURL: "\(Self.workerBaseURL)/chat", model: selectedModel, authToken: Self.workerAuthToken)
        }
    }()

    /// Conversation history so Claude remembers prior exchanges within a session.
    /// Each entry is the user's question and Claude's response.
    private var conversationHistory: [(userQuestionText: String, assistantResponse: String)] = []

    /// The currently running AI response task, if any. Cancelled when the user
    /// asks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?
    /// Watchdog that times out a response that never comes back, so the window
    /// never sits on "thinking…" forever. Cancelled whenever a response finishes
    /// or a new ask begins.
    private var responseWatchdogTask: Task<Void, Never>?
    /// How long to wait for an answer before giving up. The subscription CLI can
    /// be slow, so this is generous — it's a stuck-state backstop, not a deadline.
    private let responseTimeout: TimeInterval = 150
    /// The currently running region-capture → Ask Window task, if any. Cancelled
    /// when the user asks again before finishing the previous selection.
    private var pendingAskFlowTask: Task<Void, Never>?

    // MARK: Live-ask context (captured at hotkey press, used at submit)

    /// The screenshot of the screen the user was looking at when they invoked
    /// Mentorly, captured BEFORE the ask box appears so the box never pollutes it.
    private var liveCapturedScreenshot: Data?
    /// True when the user replaced the auto full-screen shot with their own
    /// drag-selected region (the "capture region" button). While set, the
    /// context capture won't overwrite `liveCapturedScreenshot` with a fresh
    /// full-screen grab, so their chosen region is what gets sent.
    private var liveAskUsesUserProvidedScreenshot = false
    /// The actionable Accessibility elements of the user's target app at invoke
    /// time, used to resolve the model's named targets to exact on-screen frames.
    private var liveElementsForCurrentAsk: [AccessibleElement] = []
    /// The formatted on-screen-controls menu handed to the model so it can point
    /// at real controls by name.
    private var liveElementMenuTextForCurrentAsk: String = ""

    private var shortcutTransitionCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// asks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    // MARK: Accessibility warm-up
    //
    // Browsers/Electron apps keep their web-content accessibility tree OFF until
    // an assistive client asks for it, and building it the first time takes a
    // beat. If we only flipped that switch when the trigger fires, the very
    // first ask against a just-opened app would scan a still-empty tree and miss
    // every on-screen control — which is why it used to take TWO presses. To
    // avoid that, we proactively warm each app the moment it becomes frontmost
    // (and the current frontmost app at launch), so the tree is already built by
    // the time the user asks. Once enabled, an app stays warm for its lifetime.

    /// Observer token for "an app became frontmost" notifications.
    private var frontmostAppActivationObserver: NSObjectProtocol?
    /// Apps we've already warmed this session, so we don't redo it on every
    /// re-activation. (Re-warming is cheap and harmless, but this keeps it tidy.)
    private var accessibilityWarmedProcessIdentifiers: Set<pid_t> = []

    /// True when both required permissions (accessibility, screen recording)
    /// are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// The Claude model used for answering. Defaults to Haiku for the fastest
    /// answers (Sonnet 5 is one click away in the panel for harder questions).
    /// Persisted to UserDefaults. A saved model the picker no longer offers
    /// (e.g. the retired claude-sonnet-4-6) falls back to the default instead
    /// of being sent.
    @Published var selectedModel: String = {
        let offeredModelIDs = ["claude-haiku-4-5", "claude-sonnet-5"]
        if let savedModelID = UserDefaults.standard.string(forKey: "selectedClaudeModel"),
           offeredModelIDs.contains(savedModelID) {
            return savedModelID
        }
        return "claude-haiku-4-5"
    }()

    func setSelectedModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedClaudeModel")
        claudeBackend.model = model
    }

    // MARK: - Live arrow appearance (user-customizable)

    /// Size options for the live arrows + labels. `scale` multiplies every drawn
    /// dimension (connector, arrowhead, target ring, label) so the whole marker
    /// grows or shrinks together.
    enum ArrowSize: String, CaseIterable, Identifiable {
        case small, medium, large
        var id: String { rawValue }
        var displayName: String { rawValue.capitalized }
        var scale: CGFloat {
            switch self {
            case .small: return 0.8
            case .medium: return 1.0
            case .large: return 1.4
            }
        }
    }

    /// Preset colors offered in the panel for the live arrows. The name is shown
    /// to the user; the hex is what's stored and drawn. "Blue" is the classic
    /// default so nothing changes for users who never open the setting.
    static let arrowColorPresets: [(name: String, hex: String)] = [
        ("Blue", "#3380FF"),
        ("Red", "#FF4D4D"),
        ("Green", "#34C759"),
        ("Orange", "#FF9F0A"),
        ("Purple", "#BF5AF2"),
        ("Pink", "#FF375F"),
    ]

    /// Hex of the live-arrow color. Persisted; defaults to the classic blue.
    @Published var arrowColorHex: String = UserDefaults.standard.string(forKey: "arrowColorHex") ?? "#3380FF" {
        didSet { UserDefaults.standard.set(arrowColorHex, forKey: "arrowColorHex") }
    }

    /// The SwiftUI color the overlay draws the live arrows with.
    var arrowColor: Color { Color(hex: arrowColorHex) }

    /// Chosen arrow size. Persisted; the overlay reads `arrowSizeScale`.
    @Published var arrowSize: ArrowSize = ArrowSize(rawValue: UserDefaults.standard.string(forKey: "arrowSize") ?? "") ?? .medium {
        didSet { UserDefaults.standard.set(arrowSize.rawValue, forKey: "arrowSize") }
    }

    /// Multiplier the overlay applies to every drawn dimension. Shared by both
    /// the live arrows AND the cursor/pointer, so a single "Size" selector drives
    /// both (the cursor has no separate size or color setting of its own).
    var arrowSizeScale: CGFloat { arrowSize.scale }

    /// User preference for whether the Mentorly cursor should be shown.
    /// When toggled off, the overlay is hidden and the ambient buddy is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isILearnCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isILearnCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isILearnCursorEnabled")

    func setILearnCursorEnabled(_ enabled: Bool) {
        isILearnCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isILearnCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// Global mouse monitor that lets the user dismiss a live arrow by clicking
    /// on it. It is listen-only (it never consumes the click), so clicking
    /// anywhere else — or clicking the very control the arrow points at —
    /// behaves exactly as before; only a click that lands on the arrow's marker
    /// clears it.
    private var liveArrowDismissClickMonitor: Any?

    func start() {
        refreshAllPermissions()
        print("🔑 Mentorly start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindShortcutTransitions()
        startAccessibilityWarmup()
        startLiveArrowDismissClickMonitor()
        // Eagerly instantiate the answer backend. For the Worker/API path this
        // kicks off its TLS warmup handshake well before the onboarding demo
        // fires; for the CLI path it's a cheap no-op.
        _ = claudeBackend

        // If all permissions are granted, drop straight into the ready state:
        // mark setup complete and show the cursor overlay. If permissions were
        // revoked (e.g. signing change), this no-ops and the panel shows the
        // permissions UI instead.
        completeSetupIfPermitted()
    }

    /// Once every permission is granted there's nothing left to onboard (the
    /// welcome/pointing demo was removed), so mark setup complete and show the
    /// cursor overlay. This makes the app go straight to the ready UI instead of
    /// showing a "Hit Start" page. Safe to call repeatedly (it's idempotent) and
    /// no-ops until all permissions are granted. Setting `hasCompletedOnboarding`
    /// also lets the panel tell "first run" apart from "permissions revoked".
    private func completeSetupIfPermitted() {
        guard allPermissionsGranted else { return }

        if !hasCompletedOnboarding {
            hasCompletedOnboarding = true
        }

        if !isOverlayVisible && isILearnCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    /// Begins proactively warming app accessibility trees in the background so
    /// the first ask never lands on a cold, empty tree (the old
    /// "press it twice" problem). Warms whatever app is frontmost right now, then
    /// keeps warming each app as it becomes frontmost.
    private func startAccessibilityWarmup() {
        // Warm the app the user is currently looking at.
        if let frontmostProcessIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            warmAccessibilityTree(forProcessIdentifier: frontmostProcessIdentifier)
        }

        // Warm every app the user switches to from here on. NSWorkspace posts
        // this on its OWN notification center (not the default one).
        guard frontmostAppActivationObserver == nil else { return }
        frontmostAppActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let activatedApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self.warmAccessibilityTree(forProcessIdentifier: activatedApp.processIdentifier)
        }
    }

    /// Turns on web-content accessibility for one app (once per session). Cheap
    /// no-op without Accessibility permission or if we've already warmed this app.
    private func warmAccessibilityTree(forProcessIdentifier processIdentifier: pid_t) {
        guard AccessibilityElementLocator.hasAccessibilityPermission() else { return }
        // Skip our own process and apps we've already warmed.
        if processIdentifier == ProcessInfo.processInfo.processIdentifier { return }
        guard !accessibilityWarmedProcessIdentifiers.contains(processIdentifier) else { return }
        accessibilityWarmedProcessIdentifiers.insert(processIdentifier)
        AccessibilityElementLocator.enableEnhancedAccessibility(forProcessIdentifier: processIdentifier)
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    /// Removes all live-mode arrows from the real screen.
    func clearLiveArrows() {
        liveArrowTargets = []
    }

    /// Installs the global click monitor used to dismiss a live arrow by clicking
    /// it. Safe to call repeatedly — it only installs the monitor once.
    private func startLiveArrowDismissClickMonitor() {
        guard liveArrowDismissClickMonitor == nil else { return }
        liveArrowDismissClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown]
        ) { [weak self] _ in
            // Global monitor handlers fire on the main thread; capture the click
            // location now and hand off to the @MainActor dismiss logic.
            let clickLocationInGlobalScreenCoordinates = NSEvent.mouseLocation
            Task { @MainActor in
                self?.dismissLiveArrowIfClicked(
                    atGlobalScreenPoint: clickLocationInGlobalScreenCoordinates
                )
            }
        }
    }

    /// Clears any live arrow whose on-screen marker contains the clicked point,
    /// so clicking an arrow makes it disappear. Any other arrows are left in
    /// place (in practice there is only one arrow at a time).
    private func dismissLiveArrowIfClicked(atGlobalScreenPoint clickPointInGlobalScreenCoordinates: CGPoint) {
        guard !liveArrowTargets.isEmpty else { return }
        let remainingArrows = liveArrowTargets.filter { liveArrowTarget in
            !LiveArrowGeometry.arrowDismissHitTest(
                globalScreenPoint: clickPointInGlobalScreenCoordinates,
                target: liveArrowTarget,
                scale: arrowSizeScale
            )
        }
        if remainingArrows.count != liveArrowTargets.count {
            liveArrowTargets = remainingArrows
        }
    }

    func stop() {
        globalAskShortcutMonitor.stop()
        if let liveArrowDismissClickMonitor {
            NSEvent.removeMonitor(liveArrowDismissClickMonitor)
            self.liveArrowDismissClickMonitor = nil
        }
        pendingAskFlowTask?.cancel()
        pendingAskFlowTask = nil
        askWindowManager.hideAskWindow()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        responseWatchdogTask?.cancel()
        responseWatchdogTask = nil
        shortcutTransitionCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
        if let frontmostAppActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(frontmostAppActivationObserver)
            self.frontmostAppActivationObserver = nil
        }
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalAskShortcutMonitor.start()
            // If Accessibility was JUST granted, warm the current frontmost app
            // now so the user's very first ask doesn't hit a cold tree (they
            // won't necessarily switch apps first to trigger the activation warm).
            if !previouslyHadAccessibility,
               let frontmostProcessIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier {
                warmAccessibilityTree(forProcessIdentifier: frontmostProcessIdentifier)
            }
        } else {
            globalAskShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), screenContent: \(hasScreenContentPermission)")
        }

        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        // The instant every permission is in place, go straight to the ready
        // state (mark setup done + show the cursor) — no "Hit Start" step.
        completeSetupIfPermitted()
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")

                    // That may have been the last permission — if so, go straight
                    // to the ready state (mark setup done + show the cursor).
                    completeSetupIfPermitted()
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalAskShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    private func handleShortcutTransition(_ transition: AskShortcut.Transition) {
        guard transition == .pressed else { return }

        // Cancel any pending transient hide so the overlay stays visible
        transientHideTask?.cancel()
        transientHideTask = nil

        // Double-tap is a toggle: if the ask box is already open, this press
        // closes it and stops here. closeLiveAskFlow() resets the flow state so
        // the NEXT press reliably reopens it (the old bug left the in-progress
        // flag stuck, so after one open+close the box would never open again).
        if askWindowManager.isAskWindowVisible {
            askWindowManager.hideAskWindow()
            closeLiveAskFlow()
            return
        }

        // If the cursor is hidden, bring it back transiently for this interaction
        if !isILearnCursorEnabled && !isOverlayVisible {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }

        // Dismiss the menu bar panel so it doesn't cover the screen
        NotificationCenter.default.post(name: .iLearnDismissPanel, object: nil)

        // Cancel any in-progress response and clear stale UI from a previous ask
        currentResponseTask?.cancel()
        askWindowManager.hideAskWindow()
        clearDetectedElementLocation()
        // Clear any live arrows still pinned on screen from the previous answer.
        clearLiveArrows()

        // Dismiss the onboarding prompt if it's showing
        if showOnboardingPrompt {
            withAnimation(.easeOut(duration: 0.3)) {
                onboardingPromptOpacity = 0.0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self.showOnboardingPrompt = false
                self.onboardingPromptText = ""
            }
        }

        // Live mode: small ask box + arrows drawn on the real screen.
        beginLiveAskFlow()
    }

    // MARK: - Ask Flow

    /// Starts the LIVE ask flow: captures the screen and the target app's
    /// on-screen controls UP FRONT (before our own ask box appears, so the box
    /// neither pollutes the screenshot nor changes which app is frontmost), then
    /// shows the small bottom-anchored ask box. On submit, the question is sent
    /// with that captured context and arrows are drawn on the real screen.
    private func beginLiveAskFlow() {
        guard !isAskFlowInProgress else { return }
        isAskFlowInProgress = true
        // Each fresh ask starts from the auto full-screen capture; the user can
        // switch to their own region via the capture-region button in the box.
        liveAskUsesUserProvidedScreenshot = false
        clearLiveArrows()

        // A fresh trigger is a brand-new conversation — clear any history from a
        // previous session so this isn't one endless thread. (Follow-ups typed in
        // the box keep their history; pressing the hotkey again starts over.)
        conversationHistory.removeAll()

        pendingAskFlowTask?.cancel()
        pendingAskFlowTask = Task {
            // Capture the screen + the target app's on-screen controls UP FRONT,
            // before the (non-activating) box appears, so the box never pollutes
            // the screenshot or changes which app is frontmost.
            await captureLiveContext()

            guard !Task.isCancelled else {
                isAskFlowInProgress = false
                return
            }

            askWindowManager.showLiveAskWindow(
                onSubmit: { [weak self] questionText in
                    self?.submitLiveQuestion(questionText: questionText)
                },
                onCancel: { [weak self] in
                    // The box already hid itself before calling back; just tear
                    // down the flow state (the panel's own close/Escape path).
                    self?.closeLiveAskFlow()
                },
                onCaptureRegion: { [weak self] in
                    self?.captureUserRegionForCurrentAsk()
                }
            )
        }
    }

    /// Lets the user drag-select their own region of the screen (like ⌘⇧4) and
    /// use THAT as the screenshot for this ask, instead of the full screen. Useful
    /// when several tabs / windows are open and the question is about one specific
    /// part. Hides the ask box during selection so it isn't in the shot, then
    /// restores it (and the user's typed question).
    private func captureUserRegionForCurrentAsk() {
        Task {
            askWindowManager.setPanelHidden(true)
            // Give the panel a beat to disappear before the selection overlay.
            try? await Task.sleep(nanoseconds: 150_000_000)

            let regionScreenshot = await CompanionScreenCaptureUtility.captureUserSelectedRegionAsJPEG()

            askWindowManager.setPanelHidden(false)

            // nil means the user pressed Esc — keep the existing full-screen shot.
            guard let regionScreenshot else { return }
            liveCapturedScreenshot = regionScreenshot
            liveAskUsesUserProvidedScreenshot = true
        }
    }

    /// Tears down the live ask flow: cancels any in-flight request, clears the
    /// arrows from the real screen, ends the conversation, and drops the cursor
    /// to idle. Crucially it also resets `isAskFlowInProgress`, so the flow can
    /// never get wedged and the trigger always opens the box again next time.
    /// Shared by the box's own close/Escape button and by the trigger toggle.
    /// Does NOT hide the panel itself — callers that need the box hidden call
    /// `askWindowManager.hideAskWindow()` first (the panel's own close path
    /// already has).
    private func closeLiveAskFlow() {
        isAskFlowInProgress = false
        liveAskUsesUserProvidedScreenshot = false
        currentResponseTask?.cancel()
        responseWatchdogTask?.cancel()
        pendingAskFlowTask?.cancel()
        clearLiveArrows()
        conversationHistory.removeAll()
        askState = .idle
        // If the cursor was only showing transiently for this ask, fade the
        // overlay back out now that the arrows are gone.
        scheduleTransientHideIfNeeded()
    }

    /// Captures the live-ask context: the screenshot of the screen the user is
    /// looking at, plus the target app's actionable Accessibility controls (with
    /// their exact frames). Stored into the `live…ForCurrentAsk` properties for
    /// the next send. Used both for the first question (before the box appears)
    /// and for each follow-up (re-captured because the screen has likely changed).
    private func captureLiveContext() async {
        // The frontmost app is the user's target app — our box is non-activating,
        // so it never becomes frontmost even while a follow-up is being typed.
        let targetAppProcessIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier

        // Wake up web-content accessibility for the target app FIRST. Browsers /
        // Electron apps keep their page's AX tree off by default; enabling it here
        // (before the screenshot) lets the tree build while the capture runs.
        if let targetAppProcessIdentifier {
            AccessibilityElementLocator.enableEnhancedAccessibility(forProcessIdentifier: targetAppProcessIdentifier)
        }

        let screenCaptures = try? await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
        let cursorScreenCapture = screenCaptures?.first(where: { $0.isCursorScreen }) ?? screenCaptures?.first

        // A short extra wait makes a cold first scan robust (the tree is created
        // lazily the first time it's requested).
        try? await Task.sleep(nanoseconds: 200_000_000)

        let actionableElements: [AccessibleElement]
        if let targetAppProcessIdentifier {
            actionableElements = AccessibilityElementLocator.actionableElements(
                forProcessIdentifier: targetAppProcessIdentifier
            )
        } else {
            actionableElements = AccessibilityElementLocator.actionableElementsForFrontmostApp()
        }

        // Keep the user's own region if they chose one; otherwise use the fresh
        // full-screen capture. (The AX scan below always runs so arrows still
        // resolve against the real screen either way.)
        if !liveAskUsesUserProvidedScreenshot {
            liveCapturedScreenshot = cursorScreenCapture?.imageData
        }
        liveElementsForCurrentAsk = actionableElements
        liveElementMenuTextForCurrentAsk = formatLiveElementMenu(actionableElements)
    }

    /// Routes a submitted live question. The FIRST question already has fresh
    /// context (captured before the box appeared), so it sends immediately. A
    /// FOLLOW-UP (history already has a turn) re-captures the screen first —
    /// the user has likely acted on the arrows, so the screenshot and on-screen
    /// controls have changed — then sends with the conversation carried forward.
    private func submitLiveQuestion(questionText: String) {
        isAskFlowInProgress = false

        if conversationHistory.isEmpty {
            sendLiveQuestionToClaude(questionText: questionText)
        } else {
            recaptureLiveContextThenSend(questionText: questionText)
        }
    }

    /// Re-captures a fresh screenshot + Accessibility scan, then sends a follow-up
    /// question with it. The old arrows are cleared before capture so they aren't
    /// baked into the new screenshot.
    private func recaptureLiveContextThenSend(questionText: String) {
        clearLiveArrows()
        // Show the streaming state immediately so the user sees their follow-up
        // was received while the fresh capture + scan run in the background.
        askWindowManager.beginLiveStreamingAnswer(forQuestion: questionText)

        pendingAskFlowTask?.cancel()
        pendingAskFlowTask = Task {
            await captureLiveContext()
            guard !Task.isCancelled else { return }
            sendLiveQuestionToClaude(questionText: questionText)
        }
    }

    // MARK: - Ask Prompt

    private static let companionLiveResponseSystemPrompt = """
    you're mentorly, a friendly assistant that helps the user understand and do things on their screen. they asked about what they're looking at right now. you can see a screenshot, and you point at real on-screen controls by NAME, which makes a small labeled arrow appear on their actual screen pinned to that control. this is an ongoing conversation, so you remember what they've asked before.

    rules:
    - answer directly. never narrate your process or mention tools, files, the screenshot, or the control list. the user only sees a clean explanation plus arrows.
    - write for a total beginner: the simplest plain language, and define any jargon the first time you use it in parentheses.
    - sound like a real person, not a manual. short everyday sentences, contractions, warm casual tone. never say "simply" or "just".
    - never use em dashes or en dashes (— or –). use commas, periods, or parentheses instead.
    - keep it SHORT. the arrows carry the "where," your words carry the "what" and "why." don't restate what an arrow already shows.
    - name controls naturally in your prose ("the Star button", "the search box"), never mention tags, lists, quotes, or coordinates.

    format:
    - lead with ONE short sentence that answers the question or says what the thing is.
    - for a "how do i..." or anything multi-step, use a NUMBERED list, one action per line, in order.
    - for a few parallel options, use short "-" bullets, one idea per line.
    - for a plain concept, 1-2 sentences is enough; add an everyday analogy only when it truly helps ("think of it like a folder that holds other folders").

    pointing at real controls:
    - you'll get a list of the controls on screen by their exact names. to point at one, write a tag with its EXACT name from that list.
    - one control: [POINT:exact control name]
    - ordered how-to: one [STEP:n:exact control name] per step, numbered from 1, in order.
    - emit each tag right after the sentence or step that mentions its control (not bunched at the end), so the arrows appear in step with your words as you write. the tags are stripped from what the user reads, so they only ever see clean prose plus the arrows.

    CRITICAL, only point at controls that appear in the provided list:
    - never invent a name or point at something not in the list. a tag not in the list does nothing.
    - if what they need isn't in the list (off screen, in a closed menu, elsewhere), don't emit a tag. say so in plain words and tell them where it usually is ("the logout option is usually under your profile picture in the top-right").
    - accuracy beats quantity: point only at the controls THIS question needs. don't point at nearby unrelated controls.
    - for a pure-concept question with no specific control, just explain and emit no tags.

    examples:
    - "that's the Star button, clicking it bookmarks this repo to your account. [POINT:Star]"
    - "to post your message, type it in the box and then send it. [STEP:1:Post text field] [STEP:2:Post]"
    """

    /// Sends the typed question (in LIVE mode) to Claude along with the screen
    /// the user was looking at and the menu of real on-screen controls. Streams
    /// the explanation into the bottom ask box, then resolves the controls the
    /// model named into arrows drawn on the real screen.
    private func sendLiveQuestionToClaude(questionText: String) {
        currentResponseTask?.cancel()
        responseWatchdogTask?.cancel()

        let timeout = responseTimeout
        let capturedScreenshot = liveCapturedScreenshot
        let capturedElements = liveElementsForCurrentAsk
        let onScreenControlsMenu = liveElementMenuTextForCurrentAsk

        currentResponseTask = Task {
            askState = .processing
            askWindowManager.beginLiveStreamingAnswer(forQuestion: questionText)
            clearLiveArrows()

            defer { responseWatchdogTask?.cancel() }

            responseWatchdogTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self, !Task.isCancelled, self.askState == .processing else { return }
                self.currentResponseTask?.cancel()
                self.askWindowManager.showAnswerError("that took too long, so i stopped waiting. try asking again.")
                self.askState = .idle
            }

            // Hand the model the question plus the exact names of the controls
            // currently on screen, so it points by naming one of them.
            let userPromptWithControlsMenu = """
            \(questionText)

            the controls currently on the user's screen (point ONLY at these, using their exact names):
            \(onScreenControlsMenu)
            """

            let imagesForModel: [(data: Data, label: String)]
            if let capturedScreenshot {
                imagesForModel = [(data: capturedScreenshot, label: "a screenshot of what is currently on the user's screen")]
            } else {
                imagesForModel = []
            }

            do {
                let historyForAPI = conversationHistory.map { entry in
                    (userPlaceholder: entry.userQuestionText, assistantResponse: entry.assistantResponse)
                }

                let (fullResponseText, _) = try await claudeBackend.analyzeImageStreaming(
                    images: imagesForModel,
                    systemPrompt: Self.companionLiveResponseSystemPrompt,
                    conversationHistory: historyForAPI,
                    userPrompt: userPromptWithControlsMenu,
                    onTextChunk: { [weak self] accumulatedText in
                        guard let self else { return }
                        // Ignore chunks that arrive after the user closed the box
                        // mid-stream: closeLiveAskFlow() already cleared the arrows
                        // and set askState to .idle, but the backend can still
                        // deliver a few buffered chunks before cancellation lands.
                        // Without this guard a late chunk re-pins arrows onto a
                        // screen whose ask box is already gone, and nothing is
                        // left to clear them.
                        guard self.askState == .processing else { return }
                        // Strip pointing tags as they stream so the user never
                        // sees raw [POINT:...] / [STEP:...] markup flash.
                        let displayText = LivePointingParser.strippedForDisplay(accumulatedText)
                        self.askWindowManager.updateStreamingAnswer(displayText)
                        // Draw each arrow the moment its tag has fully streamed in,
                        // so arrows appear in step with the words instead of all at
                        // the end. (Only complete tags parse; partial ones wait.)
                        let (_, streamedPointings) = LivePointingParser.parse(from: accumulatedText)
                        self.applyLiveArrows(from: streamedPointings, within: capturedElements)
                    }
                )

                responseWatchdogTask?.cancel()
                guard !Task.isCancelled else { return }

                let (cleanText, pointings) = LivePointingParser.parse(from: fullResponseText)

                conversationHistory.append((userQuestionText: questionText, assistantResponse: cleanText))
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }

                // Show the final explanation, then draw arrows on the real screen
                // for each control the model named.
                askWindowManager.finishLiveAnswer(finalText: cleanText)
                applyLiveArrows(from: pointings, within: capturedElements)
            } catch is CancellationError {
                // User asked again — this response was interrupted
            } catch {
                print("⚠️ Live response error: \(error)")
                askWindowManager.showAnswerError("something went wrong getting an answer — \(error.localizedDescription)")
            }

            if !Task.isCancelled {
                askState = .idle
                // Unlike the static flow, we do NOT transient-hide the overlay
                // here: the live arrows must stay pinned on the real screen while
                // the user reads. The overlay is hidden instead when they close
                // the ask box (see the live onCancel handler).
            }
        }
    }

    /// If the cursor is in transient mode (user toggled "Show Mentorly" off),
    /// waits for any pointing animation to finish, then fades out the
    /// overlay after a 1-second pause. Cancelled automatically if the user
    /// starts another ask interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isILearnCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    // MARK: - Point Tag Parsing

    /// Result of parsing a [POINT:...] tag from Claude's response. Only
    /// used by the onboarding demo — the main ask flow doesn't instruct
    /// Claude to point at anything, since a manually-selected screen
    /// region's on-screen origin is unknown to us.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed.
        let spokenText: String
        /// The parsed pixel coordinate, or nil if Claude said "none" or no tag was found.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
    }

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from the end of Claude's response.
    /// Returns the text with the tag removed plus the optional coordinate + label + screen number.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        // Match [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2]
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) else {
            // No tag found at all
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        // Remove the tag from the text
        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if it's [POINT:none]
        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil)
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }

    // MARK: - Live Pointing (Accessibility)

    /// Builds the human-readable element menu handed to the model in live mode.
    /// Each actionable element discovered in the frontmost app's Accessibility
    /// tree is listed by its real label and role, so the model can simply NAME
    /// one to point at instead of estimating pixel coordinates. Returns the
    /// formatted list plus the elements themselves (for resolving the name back
    /// to an exact on-screen frame afterward).
    func liveElementMenuForFrontmostApp() -> (menuText: String, elements: [AccessibleElement]) {
        let elements = AccessibilityElementLocator.actionableElementsForFrontmostApp()
        return (menuText: formatLiveElementMenu(elements), elements: elements)
    }

    /// Formats a list of accessibility elements into the on-screen-controls menu
    /// shown to the model. De-duplicates by label so a screen with twenty
    /// identical "Close" buttons doesn't drown the menu — keeps the first
    /// occurrence of each label.
    func formatLiveElementMenu(_ elements: [AccessibleElement]) -> String {
        guard !elements.isEmpty else {
            return "(no labeled on-screen controls were found)"
        }

        var seenLabels = Set<String>()
        var uniqueElements: [AccessibleElement] = []
        for element in elements {
            let labelKey = element.label.lowercased()
            if seenLabels.contains(labelKey) { continue }
            seenLabels.insert(labelKey)
            uniqueElements.append(element)
        }

        let menuLines = uniqueElements.map { element -> String in
            let friendlyRole = element.role.replacingOccurrences(of: "AX", with: "")
            return "- \"\(element.label)\" (\(friendlyRole))"
        }
        return menuLines.joined(separator: "\n")
    }

    /// Resolves each model-named pointing target to an exact on-screen frame via
    /// the captured Accessibility elements and ADDS any not already pinned, so
    /// arrows can appear one-by-one as their tags stream in (rather than all at
    /// the end). Called repeatedly during streaming and once more at the end to
    /// catch any tag that only completed in the authoritative final text. Claude
    /// streams append-only, so tags never retract — we only ever add. Targets
    /// that don't match any real control are skipped (the model was told to name
    /// only controls from the provided list, but we guard anyway so a stray name
    /// never draws an arrow in the wrong place).
    private func applyLiveArrows(
        from pointings: [LivePointingParser.LivePointing],
        within elements: [AccessibleElement]
    ) {
        for pointing in pointings {
            // Already pinned this exact control (same step)? Skip so we don't
            // redraw it and cause a flicker as later chunks re-parse it.
            let alreadyPinned = liveArrowTargets.contains { existingTarget in
                existingTarget.label == pointing.targetName
                    && existingTarget.stepNumber == pointing.stepNumber
            }
            if alreadyPinned { continue }

            guard let matchedElement = AccessibilityElementLocator.bestMatch(
                forTargetName: pointing.targetName,
                in: elements
            ) else {
                print("🎯 Live arrows: no on-screen control matched \"\(pointing.targetName)\"")
                continue
            }
            liveArrowTargets.append(
                LiveArrowTarget(
                    screenLocation: matchedElement.screenCenter,
                    label: pointing.targetName,
                    stepNumber: pointing.stepNumber
                )
            )
        }
    }

    // MARK: - Onboarding

    /// Runs the onboarding pointing demo, then streams in the "double-tap command"
    /// prompt once it's had time to finish. Called by BlueCursorView right after
    /// the welcome message fades.
    func runOnboardingDemoThenShowPrompt() {
        performOnboardingDemoInteraction()
        // Approximate — covers the screenshot + Claude round trip plus the
        // flight-out, 3s hold, and flight-back animation in OverlayWindow.
        DispatchQueue.main.asyncAfter(deadline: .now() + 9.0) {
            self.startOnboardingPromptStream()
        }
    }

    private func startOnboardingPromptStream() {
        let message = "double-tap command and ask about anything on your screen"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                // Auto-dismiss after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }

    // MARK: - Onboarding Demo Interaction

    private static let onboardingDemoSystemPrompt = """
    you're mentorly, a small blue cursor buddy living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

    make a short quirky 3-6 word observation about the specific thing you picked, something fun, playful, or curious that shows you actually read/recognized it. no emojis ever. no em dashes or en dashes (— or –) ever. NEVER quote or repeat text you see on screen, just react to it. keep it to 6 words max, no exceptions.

    CRITICAL COORDINATE RULE: you MUST only pick elements near the CENTER of the screen. your x coordinate must be between 20%-80% of the image width. your y coordinate must be between 20%-80% of the image height. do NOT pick anything in the top 20%, bottom 20%, left 20%, or right 20% of the screen. no menu bar items, no dock icons, no sidebar items, no items near any edge. only things clearly in the middle area of the screen. if the only interesting things are near the edges, pick something boring in the center instead.

    respond with ONLY your short comment followed by the coordinate tag. nothing else. all lowercase.

    format: your comment [POINT:x,y:label]

    the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. origin (0,0) is top-left. x increases rightward, y increases downward.
    """

    /// Captures a screenshot and asks Claude to find something interesting to
    /// point at, then triggers the buddy's flight animation. Used to demo the
    /// pointing feature right after onboarding's welcome message.
    func performOnboardingDemoInteraction() {
        // Don't interrupt an active ask
        guard askState == .idle else { return }

        Task {
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                // Only send the cursor screen so Claude can't pick something
                // on a different monitor that we can't point at.
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    print("🎯 Onboarding demo: no cursor screen found")
                    return
                }

                let dimensionInfo = " (image dimensions: \(cursorScreenCapture.screenshotWidthInPixels)x\(cursorScreenCapture.screenshotHeightInPixels) pixels)"
                let labeledImages = [(data: cursorScreenCapture.imageData, label: cursorScreenCapture.label + dimensionInfo)]

                let (fullResponseText, _) = try await claudeBackend.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.onboardingDemoSystemPrompt,
                    conversationHistory: [],
                    userPrompt: "look around my screen and find something interesting to point at",
                    onTextChunk: { _ in }
                )

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)

                guard let pointCoordinate = parseResult.coordinate else {
                    print("🎯 Onboarding demo: no element to point at")
                    return
                }

                let screenshotWidth = CGFloat(cursorScreenCapture.screenshotWidthInPixels)
                let screenshotHeight = CGFloat(cursorScreenCapture.screenshotHeightInPixels)
                let displayWidth = CGFloat(cursorScreenCapture.displayWidthInPoints)
                let displayHeight = CGFloat(cursorScreenCapture.displayHeightInPoints)
                let displayFrame = cursorScreenCapture.displayFrame

                let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))
                let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                let displayLocalY = clampedY * (displayHeight / screenshotHeight)
                let appKitY = displayHeight - displayLocalY
                let globalLocation = CGPoint(
                    x: displayLocalX + displayFrame.origin.x,
                    y: appKitY + displayFrame.origin.y
                )

                // Set custom bubble text so the pointing animation uses Claude's
                // comment instead of a random phrase
                detectedElementBubbleText = parseResult.spokenText
                detectedElementScreenLocation = globalLocation
                detectedElementDisplayFrame = displayFrame
                print("🎯 Onboarding demo: pointing at \"\(parseResult.elementLabel ?? "element")\" — \"\(parseResult.spokenText)\"")
            } catch {
                print("⚠️ Onboarding demo error: \(error)")
            }
        }
    }
}

// MARK: - Live Pointing Parser

/// Parses the live-mode pointing tags out of Claude's reply. In live mode the
/// model names real on-screen controls (resolved to exact frames via the
/// Accessibility tree) rather than emitting pixel coordinates:
///   [POINT:exact control name]            — point at one control
///   [STEP:n:exact control name]           — one numbered step of a how-to
/// Both are stripped from the displayed prose (including mid-stream, so raw
/// markup never flashes) and returned as an ordered list of targets.
enum LivePointingParser {
    struct LivePointing {
        /// Step number for an ordered how-to, or nil for a plain point.
        let stepNumber: Int?
        /// The exact control name the model named (matched back to a real frame).
        let targetName: String
    }

    private static let stepPattern = #"\[STEP:\s*(\d+)\s*:\s*([^\]]+?)\s*\]"#
    private static let pointPattern = #"\[POINT:\s*([^\]]+?)\s*\]"#
    /// Catch-all so any malformed POINT/STEP tag is still stripped from display.
    private static let anyTagPattern = #"\[(?:POINT|STEP)[^\]]*\]"#
    /// An unterminated tag at the very end of the text (e.g. "[POINT:Sta" while
    /// streaming), stripped so a half-typed tag never flashes mid-stream.
    private static let trailingPartialTagPattern = #"\[(?:POINT|STEP)[^\]]*$"#

    /// Returns the prose with all pointing tags removed plus the ordered list of
    /// targets the model named (numbered steps first, in order, then plain points).
    static func parse(from responseText: String) -> (cleanText: String, pointings: [LivePointing]) {
        var pointings: [LivePointing] = []
        let fullRange = NSRange(responseText.startIndex..., in: responseText)

        if let stepRegex = try? NSRegularExpression(pattern: stepPattern) {
            for match in stepRegex.matches(in: responseText, range: fullRange) {
                guard let numberRange = Range(match.range(at: 1), in: responseText),
                      let nameRange = Range(match.range(at: 2), in: responseText),
                      let stepNumber = Int(responseText[numberRange]) else { continue }
                let targetName = String(responseText[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !targetName.isEmpty {
                    pointings.append(LivePointing(stepNumber: stepNumber, targetName: targetName))
                }
            }
        }

        if let pointRegex = try? NSRegularExpression(pattern: pointPattern) {
            for match in pointRegex.matches(in: responseText, range: fullRange) {
                guard let nameRange = Range(match.range(at: 1), in: responseText) else { continue }
                let targetName = String(responseText[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !targetName.isEmpty {
                    pointings.append(LivePointing(stepNumber: nil, targetName: targetName))
                }
            }
        }

        // Numbered steps first (in step order), then any plain points.
        pointings.sort { lhs, rhs in
            switch (lhs.stepNumber, rhs.stepNumber) {
            case let (leftNumber?, rightNumber?): return leftNumber < rightNumber
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return false
            }
        }

        return (cleanText: strippedForDisplay(responseText), pointings: pointings)
    }

    /// Strips all pointing tags (complete, malformed, or a half-typed trailing
    /// one) so the user only ever reads clean prose.
    static func strippedForDisplay(_ text: String) -> String {
        var result = text
        for pattern in [stepPattern, pointPattern, anyTagPattern, trailingPartialTagPattern] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
