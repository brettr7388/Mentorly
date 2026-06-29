//
//  CompanionManager.swift
//  ILearn
//
//  Central state manager for ILearn's ask flow. Owns the global shortcut
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
    /// rather than hardcoded, since the Worker has no auth check — anyone who
    /// found the real URL in source could run up charges on your Anthropic
    /// account.
    private static let workerBaseURL = UserDefaults.standard.string(forKey: "workerBaseURL")
        ?? "https://your-worker-name.your-subdomain.workers.dev"

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
            print("🧠 ILearn answer backend: Claude Code CLI (subscription)")
            return ClaudeCodeBackend(model: selectedModel)
        } else {
            print("🧠 ILearn answer backend: Cloudflare Worker (API key)")
            return ClaudeAPI(proxyURL: "\(Self.workerBaseURL)/chat", model: selectedModel)
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
    /// ILearn, captured BEFORE the ask box appears so the box never pollutes it.
    private var liveCapturedScreenshot: Data?
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
    // beat. If we only flipped that switch when Control+Z is pressed, the very
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

    /// The Claude model used for answering. Defaults to the cheapest model
    /// (Haiku) to keep API costs minimal. Persisted to UserDefaults.
    @Published var selectedModel: String = UserDefaults.standard.string(forKey: "selectedClaudeModel") ?? "claude-haiku-4-5"

    func setSelectedModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedClaudeModel")
        claudeBackend.model = model
    }

    /// User preference for whether the ILearn cursor should be shown.
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
        print("🔑 ILearn start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindShortcutTransitions()
        startAccessibilityWarmup()
        startLiveArrowDismissClickMonitor()
        // Eagerly instantiate the answer backend. For the Worker/API path this
        // kicks off its TLS warmup handshake well before the onboarding demo
        // fires; for the CLI path it's a cheap no-op.
        _ = claudeBackend

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isILearnCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and pointing demo play.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .iLearnDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true

        // Show the overlay for the first time — isFirstAppearance triggers
        // the welcome animation and pointing demo
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Begins proactively warming app accessibility trees in the background so
    /// the first Control+Z never lands on a cold, empty tree (the old
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
                target: liveArrowTarget
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

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isILearnCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
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

        // Live mode: small ask box + arrows drawn on the real screen. (The old
        // drag-select static-screenshot flow is `beginAskFlow`, kept for now but
        // no longer wired to the hotkey.)
        beginLiveAskFlow()
    }

    // MARK: - Ask Flow

    /// Starts the ask flow: lets the user drag-select a region of their
    /// screen (the system's own interactive screenshot tool), then shows
    /// the Ask Window so they can type a question about it.
    private func beginAskFlow() {
        guard !isAskFlowInProgress else { return }
        isAskFlowInProgress = true

        pendingAskFlowTask?.cancel()
        pendingAskFlowTask = Task {
            // Show the prompt instantly (no delay before the screenshot tool) and
            // launch the system selection UI right away. The prompt stays on the
            // cursor while the user is in screenshot-selection mode, then clears
            // the moment selection finishes or is cancelled.
            showCapturePromptForSelection()

            let selectedRegionImageData: Data?
            do {
                selectedRegionImageData = try await ScreenRegionCapture.captureUserSelectedRegion()
            } catch {
                hideCapturePrompt()
                print("⚠️ Screen region capture error: \(error)")
                isAskFlowInProgress = false
                return
            }

            hideCapturePrompt()

            guard !Task.isCancelled else {
                isAskFlowInProgress = false
                return
            }

            guard let selectedRegionImageData else {
                // User pressed Escape during selection — nothing to ask about
                isAskFlowInProgress = false
                return
            }

            let screenshotPreviewImage = NSImage(data: selectedRegionImageData)

            askWindowManager.showAskWindow(
                screenshotPreviewImage: screenshotPreviewImage,
                onSubmit: { [weak self] questionText in
                    self?.isAskFlowInProgress = false
                    self?.sendQuestionToClaude(questionText: questionText, screenshotImageData: selectedRegionImageData)
                },
                onCancel: { [weak self] in
                    self?.isAskFlowInProgress = false
                    // If the user closes the window mid-answer, cancel the
                    // in-flight request and drop the cursor back to its normal
                    // arrow so it doesn't keep spinning the loading animation.
                    self?.currentResponseTask?.cancel()
                    self?.responseWatchdogTask?.cancel()
                    self?.askState = .idle
                }
            )
        }
    }

    /// Starts the LIVE ask flow: captures the screen and the target app's
    /// on-screen controls UP FRONT (before our own ask box appears, so the box
    /// neither pollutes the screenshot nor changes which app is frontmost), then
    /// shows the small bottom-anchored ask box. On submit, the question is sent
    /// with that captured context and arrows are drawn on the real screen.
    private func beginLiveAskFlow() {
        guard !isAskFlowInProgress else { return }
        isAskFlowInProgress = true
        clearLiveArrows()

        // A fresh Control+Z is a brand-new conversation — clear any history from a
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
                    guard let self else { return }
                    self.isAskFlowInProgress = false
                    // Closing the box cancels any in-flight request, clears the
                    // arrows from the real screen, ends the conversation, and
                    // drops the cursor to idle.
                    self.currentResponseTask?.cancel()
                    self.responseWatchdogTask?.cancel()
                    self.pendingAskFlowTask?.cancel()
                    self.clearLiveArrows()
                    self.conversationHistory.removeAll()
                    self.askState = .idle
                    // If the cursor was only showing transiently for this ask,
                    // fade the overlay back out now that the arrows are gone.
                    self.scheduleTransientHideIfNeeded()
                }
            )
        }
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

        liveCapturedScreenshot = cursorScreenCapture?.imageData
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

    /// Shows the "take a screenshot…" prompt on the cursor immediately (no
    /// typewriter, no delay) so it's already visible the instant the system
    /// screenshot-selection UI appears. Paired with `hideCapturePrompt()`, which
    /// is called as soon as selection finishes or is cancelled.
    private func showCapturePromptForSelection() {
        capturePromptText = "take a screenshot for ilearn to see and help"
        showCapturePrompt = true
        capturePromptOpacity = 0.0
        withAnimation(.easeIn(duration: 0.15)) {
            capturePromptOpacity = 1.0
        }
    }

    /// Fades the capture prompt out, then clears it once the fade has played.
    private func hideCapturePrompt() {
        withAnimation(.easeOut(duration: 0.15)) {
            capturePromptOpacity = 0.0
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 170_000_000)
            showCapturePrompt = false
            capturePromptText = ""
        }
    }

    // MARK: - Ask Prompt

    private static let companionAskResponseSystemPrompt = """
    you're ilearn, a friendly assistant that helps the user understand and do things they're looking at on their screen. the user selected a region of their screen and asked a question about it. the screenshot they selected is shown back to them with YOUR marks drawn on top of it — so you can literally point at things and highlight areas instead of only describing them. this is an ongoing conversation — you remember everything they've asked before.

    rules:
    - answer the user directly. NEVER narrate your own process or thinking, and never mention tools, files, reading, zooming, or images (no "I'll zoom in", "let me read the file", "using the Read tool", "looking more carefully"). the user only ever sees a clean explanation plus your marks — never a play-by-play of how you produced it. if you can't make something out, just give your best plain-language answer; don't describe the struggle.
    - explain things in the simplest, most beginner-friendly language possible. assume the user is brand new to this and has zero background knowledge — define every piece of jargon the first time you use it, in plain words. write like you're kindly explaining to a smart friend who has never seen this screen before.
    - keep the prose SHORT and warm. the marks you draw carry the "where," so your text should carry the "what" and "why" in a sentence or two, not a wall of text. don't repeat in words what an arrow already shows.
    - never say "simply" or "just" — if it were simple they wouldn't be asking.
    - don't mention coordinates or the tags in your prose. talk naturally ("the highlighted button", "the area marked 1").
    - mark what's RELEVANT to the question, and only that. accuracy beats quantity: one arrow on the exact right thing is far better than several where some are guesses or land on the wrong button.

    drawing marks on the screenshot:
    a faint MAGENTA COORDINATE GRID is drawn on top of the image for you, with numbered lines from 0 to 1000 running across (x, left→right) and down (y, top→bottom). use it to READ each mark's position: find the element, then look at which numbered gridlines it sits between and read off its x and y. x=0 is the left edge, x=1000 the right edge, x=500 the horizontal middle; y=0 is the top edge, y=1000 the bottom edge, y=500 the vertical middle. this grid is the same regardless of the image's real pixel size. put ALL mark tags at the very END of your reply, each on its own line, AFTER your explanation. use marks only when a location on the screenshot actually matters — for a pure-concept question with no specific spot, skip them and just explain.

    IMPORTANT: the magenta grid and its numbers are a measuring tool for YOU only — they are NOT really on the user's screen. never mention the grid, the numbers, or the color magenta in your reply. talk about the actual UI only.

    CRITICAL — only mark what you can actually SEE in this screenshot. a mark in the wrong place is worse than no mark, because the user will look exactly where you point.
    - only place a mark on an element that is genuinely visible in the image. do NOT guess a location for something that isn't shown. if the thing they're asking about (a button, menu, setting) is not visible in this capture, say so in plain words and tell them where it usually is ("the logout option is usually under your profile icon in the top-right") — and emit NO mark for it.
    - read the element's position off the grid carefully before writing the numbers. trace down from the element to the nearest x gridline number and across to the nearest y gridline number — don't eyeball it loosely. e.g. a "Star" button sitting two-thirds across and a third of the way down is near x=670, y=330, NOT x=900, y=50.
    - if you're not confident of an exact spot but the element IS visible, prefer a [BOX] around the general area over a precise [ARROW] — a slightly loose box is more forgiving than a pinpoint that's off.

    - point at one specific thing: [ARROW:x,y:short label]
    - highlight a whole region or element: [BOX:x1,y1,x2,y2:short label]   (x1,y1 = top-left corner, x2,y2 = bottom-right corner, all 0–1000)
    - show an ordered how-to ("how do i..."): one [STEP:n:x,y:short instruction] per step, numbered from 1, in order

    how many marks: mark exactly the elements the user needs for THIS question — no more.
    - if the question is about ONE thing (e.g. "how do i star this repo"), use ONE precise arrow on that one element. do NOT add arrows to nearby buttons (Fork, Watch, etc.) that aren't what they asked about — extra arrows on the wrong spots are confusing and usually misplaced.
    - only add more arrows when the question genuinely involves several elements, and only for things that are clearly visible — give each its own short label. never pad to hit a number, and never add a mark you're not confident is in the right place.
    - for any "how do i..." question with multiple clicks, lay out the real sequence as numbered [STEP] marks so they can follow along click by click.
    - keep every label/instruction to about 5 words max.

    examples (coordinates are on the 0–1000 grid):
    - "that's the Star button — clicking it bookmarks this repo to your account. [ARROW:780,255:Star button]"
    - "to deploy: open the menu, then pick production. [STEP:1:140,90:open the deploy menu] [STEP:2:560,470:choose production]"
    """

    private static let companionLiveResponseSystemPrompt = """
    you're ilearn, a friendly assistant that helps the user understand and do things on their screen. the user asked a question about what they're looking at right now. you can see a screenshot of their screen, and you point at real on-screen controls by NAME — a small labeled arrow then appears on their ACTUAL screen, pinned to each control you name, so they can follow along on the real thing while they read. this is an ongoing conversation — you remember everything they've asked before.

    rules:
    - answer the user directly. NEVER narrate your own process or thinking, and never mention tools, files, reading, the screenshot, or the list of controls. the user only sees a clean explanation plus arrows on their screen — never a play-by-play of how you produced it.
    - explain in the simplest, most beginner-friendly language possible. assume the user is brand new to this and has zero background knowledge — define every piece of jargon the first time you use it, in plain words. write like you're kindly explaining to a smart friend who has never seen this screen before.
    - keep the prose SHORT and warm. the arrows carry the "where," so your words carry the "what" and "why" in a sentence or two, not a wall of text. don't repeat in words what an arrow already shows.
    - never say "simply" or "just" — if it were simple they wouldn't be asking.
    - talk about the controls naturally in your prose ("the Star button", "the search box") — never mention tags, lists, names-in-quotes, or coordinates.

    pointing at real controls:
    - you'll be given a list of the controls currently on the user's screen, by their exact names. to point at one, write a tag using its EXACT name from that list.
    - point at one specific control: [POINT:exact control name]
    - show an ordered how-to ("how do i..."): one [STEP:n:exact control name] per step, numbered from 1, in the order to do them.
    - put ALL tags at the very END of your reply, each on its own line, AFTER your explanation.

    CRITICAL — only point at controls that actually appear in the provided list.
    - never invent a control name and never point at something not in the list. a tag with a name that isn't in the list does nothing.
    - if the thing they need is NOT in the list (it's off screen, in a menu that isn't open, or somewhere else), do not emit a tag for it — instead say so in plain words and tell them where it usually is ("the logout option is usually under your profile picture in the top-right").
    - accuracy beats quantity: point only at the controls THIS question needs. one correct arrow is far better than several where some are guesses. do NOT point at nearby unrelated controls.
    - for a pure-concept question with no specific control involved, just explain and emit no tags.

    examples:
    - "that's the Star button — clicking it bookmarks this repo to your account. [POINT:Star]"
    - "to post your message, type it in the box and then send it. [STEP:1:Post text field] [STEP:2:Post]"
    """

    /// Sends the typed question plus the selected screenshot region to Claude
    /// and streams the response into the same Ask Window as it arrives.
    private func sendQuestionToClaude(questionText: String, screenshotImageData: Data) {
        currentResponseTask?.cancel()
        responseWatchdogTask?.cancel()

        let timeout = responseTimeout
        currentResponseTask = Task {
            askState = .processing
            askWindowManager.beginStreamingAnswer(forQuestion: questionText)

            // Make sure the watchdog is cleaned up no matter how this exits.
            defer { responseWatchdogTask?.cancel() }

            // Back-stop: if no answer comes back within the timeout, stop waiting
            // and show an error instead of leaving the window on "thinking…".
            responseWatchdogTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self, !Task.isCancelled, self.askState == .processing else { return }
                self.currentResponseTask?.cancel()
                self.askWindowManager.showAnswerError("that took too long, so i stopped waiting. try asking again — and if it keeps happening, try selecting a smaller area.")
                self.askState = .idle
            }

            // Marks come back on a scale-invariant 0–1000 grid (see the system
            // prompt), so we no longer hand Claude pixel dimensions — they'd only
            // mislead, since it sees a downscaled copy of the image.
            let imageLabel = "the area of the screen the user selected (a magenta 0–1000 coordinate grid is overlaid to help you read off positions)"

            // Send the model a copy with a labeled 0–1000 grid drawn on it so it
            // can READ each mark's position off the nearest gridline instead of
            // guessing — the clean (ungridded) capture is what we draw the final
            // marks onto for the user.
            let imageDataForModel = AnnotatedScreenshotRenderer.renderCoordinateGridOverlay(baseImageData: screenshotImageData) ?? screenshotImageData

            do {
                let historyForAPI = conversationHistory.map { entry in
                    (userPlaceholder: entry.userQuestionText, assistantResponse: entry.assistantResponse)
                }

                let (fullResponseText, _) = try await claudeBackend.analyzeImageStreaming(
                    images: [(data: imageDataForModel, label: imageLabel)],
                    systemPrompt: Self.companionAskResponseSystemPrompt,
                    conversationHistory: historyForAPI,
                    userPrompt: questionText,
                    onTextChunk: { [weak self] accumulatedText in
                        // Strip annotation tags as they stream so the user never
                        // sees raw [ARROW:...] markup flash in the answer text.
                        let displayText = ScreenshotAnnotationParser.strippedForDisplay(accumulatedText)
                        self?.askWindowManager.updateStreamingAnswer(displayText)
                    }
                )

                // Answer is back — stand down the timeout watchdog.
                responseWatchdogTask?.cancel()

                guard !Task.isCancelled else { return }

                // Separate the prose from the marks, draw any marks onto the
                // screenshot, and show that as the answer's centerpiece. Always
                // render (even with no marks) so the user at least sees the clean
                // captured screenshot crisply, never a missing image.
                let (cleanText, annotations) = ScreenshotAnnotationParser.parse(from: fullResponseText)
                let annotatedImage = AnnotatedScreenshotRenderer.render(baseImageData: screenshotImageData, annotations: annotations)
                    ?? NSImage(data: screenshotImageData)

                conversationHistory.append((userQuestionText: questionText, assistantResponse: cleanText))

                // Keep only the last 10 exchanges to avoid unbounded context growth
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }

                askWindowManager.finishAnswer(annotatedImage: annotatedImage, finalText: cleanText)
            } catch is CancellationError {
                // User asked another question — this response was interrupted
            } catch {
                print("⚠️ Companion response error: \(error)")
                askWindowManager.showAnswerError("something went wrong getting an answer — \(error.localizedDescription)")
            }

            if !Task.isCancelled {
                askState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

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
                        // Strip pointing tags as they stream so the user never
                        // sees raw [POINT:...] / [STEP:...] markup flash.
                        let displayText = LivePointingParser.strippedForDisplay(accumulatedText)
                        self?.askWindowManager.updateStreamingAnswer(displayText)
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

    /// If the cursor is in transient mode (user toggled "Show ILearn" off),
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
    /// the captured Accessibility elements, and replaces the live arrows with the
    /// resulting set. Targets that don't match any real control are skipped (the
    /// model was told only to name controls from the provided list, but we guard
    /// anyway so a stray name never draws an arrow in the wrong place).
    private func applyLiveArrows(
        from pointings: [LivePointingParser.LivePointing],
        within elements: [AccessibleElement]
    ) {
        var resolvedTargets: [LiveArrowTarget] = []
        for pointing in pointings {
            guard let matchedElement = AccessibilityElementLocator.bestMatch(
                forTargetName: pointing.targetName,
                in: elements
            ) else {
                print("🎯 Live arrows: no on-screen control matched \"\(pointing.targetName)\"")
                continue
            }
            resolvedTargets.append(
                LiveArrowTarget(
                    screenLocation: matchedElement.screenCenter,
                    label: pointing.targetName,
                    stepNumber: pointing.stepNumber
                )
            )
        }
        liveArrowTargets = resolvedTargets
    }

    // MARK: - Onboarding

    /// Runs the onboarding pointing demo, then streams in the "press control + c"
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
        let message = "press control + z and ask about anything on your screen"
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
    you're ilearn, a small blue cursor buddy living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

    make a short quirky 3-6 word observation about the specific thing you picked — something fun, playful, or curious that shows you actually read/recognized it. no emojis ever. NEVER quote or repeat text you see on screen — just react to it. keep it to 6 words max, no exceptions.

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
