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
    /// so a second Control+I press doesn't spawn another selection on top
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

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the welcome
    /// message and pointing demo finish.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    let globalAskShortcutMonitor = GlobalAskShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    let askWindowManager = AskWindowManager()

    /// Base URL for the Cloudflare Worker proxy. All API requests route
    /// through this so the key never ships in the app binary. Read from
    /// UserDefaults (set once locally via `defaults write`, never
    /// committed) rather than hardcoded, since the Worker has no auth check
    /// — anyone who found the real URL in source could run up charges on
    /// your Anthropic account.
    private static let workerBaseURL = UserDefaults.standard.string(forKey: "workerBaseURL")
        ?? "https://your-worker-name.your-subdomain.workers.dev"

    private lazy var claudeAPI: ClaudeAPI = {
        return ClaudeAPI(proxyURL: "\(Self.workerBaseURL)/chat", model: selectedModel)
    }()

    /// Conversation history so Claude remembers prior exchanges within a session.
    /// Each entry is the user's question and Claude's response.
    private var conversationHistory: [(userQuestionText: String, assistantResponse: String)] = []

    /// The currently running AI response task, if any. Cancelled when the user
    /// asks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?
    /// The currently running region-capture → Ask Window task, if any. Cancelled
    /// when the user asks again before finishing the previous selection.
    private var pendingAskFlowTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// asks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

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
        claudeAPI.model = model
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

    func start() {
        refreshAllPermissions()
        print("🔑 ILearn start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindShortcutTransitions()
        // Eagerly touch the Claude API so its TLS warmup handshake completes
        // well before the onboarding demo fires at ~40s into the video.
        _ = claudeAPI

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

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func stop() {
        globalAskShortcutMonitor.stop()
        pendingAskFlowTask?.cancel()
        pendingAskFlowTask = nil
        askWindowManager.hideAskWindow()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        shortcutTransitionCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalAskShortcutMonitor.start()
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

        beginAskFlow()
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
            let selectedRegionImageData: Data?
            do {
                selectedRegionImageData = try await ScreenRegionCapture.captureUserSelectedRegion()
            } catch {
                print("⚠️ Screen region capture error: \(error)")
                isAskFlowInProgress = false
                return
            }

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
                }
            )
        }
    }

    // MARK: - Ask Prompt

    private static let companionAskResponseSystemPrompt = """
    you're ilearn, a friendly assistant that helps the user understand things they're looking at on their screen at work. the user selected a region of their screen and asked you a question about it. your reply is displayed as text, so you can use short paragraphs or a list when it helps. this is an ongoing conversation — you remember everything they've asked before.

    rules:
    - explain things in beginner-friendly, easy-to-understand language. assume the user doesn't have background knowledge on the topic — define jargon the first time you use it instead of assuming they already know it.
    - be clear and direct. short paragraphs. a numbered or bulleted list is fine when it makes steps easier to follow, but don't over-format a simple answer.
    - if the screenshot is relevant to the question, reference specific things you see in it.
    - if the screenshot doesn't seem relevant to the question, just answer the question directly.
    - you can help with anything — code, a tool's UI, a spreadsheet, an error message, a concept they don't recognize, whatever they selected.
    - never say "simply" or "just" — if it were simple they wouldn't be asking.
    - it's fine to end with a short pointer to something related worth understanding next, but don't end every answer with a question that forces them to respond.
    """

    /// Sends the typed question plus the selected screenshot region to Claude
    /// and streams the response into the same Ask Window as it arrives.
    private func sendQuestionToClaude(questionText: String, screenshotImageData: Data) {
        currentResponseTask?.cancel()

        currentResponseTask = Task {
            askState = .processing
            askWindowManager.beginStreamingAnswer(forQuestion: questionText)

            do {
                let historyForAPI = conversationHistory.map { entry in
                    (userPlaceholder: entry.userQuestionText, assistantResponse: entry.assistantResponse)
                }

                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: [(data: screenshotImageData, label: "the area of the screen the user selected")],
                    systemPrompt: Self.companionAskResponseSystemPrompt,
                    conversationHistory: historyForAPI,
                    userPrompt: questionText,
                    onTextChunk: { [weak self] accumulatedText in
                        self?.askWindowManager.updateStreamingAnswer(accumulatedText)
                    }
                )

                guard !Task.isCancelled else { return }

                conversationHistory.append((userQuestionText: questionText, assistantResponse: fullResponseText))

                // Keep only the last 10 exchanges to avoid unbounded context growth
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }

                askWindowManager.updateStreamingAnswer(fullResponseText)
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

    // MARK: - Onboarding

    /// Runs the onboarding pointing demo, then streams in the "press control + i"
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
        let message = "press control + i and drag-select something to ask about"
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

                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.onboardingDemoSystemPrompt,
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
