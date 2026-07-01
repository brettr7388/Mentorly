//
//  AskWindowManager.swift
//  Mentorly
//
//  A single, fixed-size window for the whole ask flow: shows the selected
//  screenshot, a text field for the question, then the streamed answer in
//  the same window. Always centered on screen, recomputed fresh from the
//  current screen geometry every time it's shown.
//
//  Deliberately one window instead of two independently-positioned,
//  dynamically-resizing panels — that design kept producing drift and
//  off-screen bugs. Fixed size, scrollable answer area, no resize math.
//

import AppKit
import Combine
import QuartzCore
import SwiftUI

/// Custom NSPanel subclass that can become the key window even with
/// .nonactivatingPanel style, allowing the text field to receive focus
/// without the app stealing focus from whatever the user was using.
private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class AskWindowViewModel: ObservableObject {
    @Published var screenshotPreviewImage: NSImage?
    @Published var questionText: String = ""
    @Published var isComposing: Bool = true
    @Published var submittedQuestionText: String = ""
    @Published var streamingAnswerText: String = ""
    /// The captured screenshot with Claude's arrows / highlight boxes / numbered
    /// steps drawn on top of it. Set only once the answer is complete — during
    /// streaming this stays nil so the user reads the explanation as it arrives,
    /// then the marked-up image appears as the answer's centerpiece.
    @Published var answerAnnotatedImage: NSImage?
    /// Whether the answer window is currently filling the screen (true) or shrunk
    /// to its compact content-fitted size (false). Drives the minimize/restore
    /// button icon. Answers open maximized so the screenshot is big.
    @Published var isAnswerMaximized: Bool = true
    /// Whether the answer body (screenshot + explanation) is shown. When false the
    /// window collapses to just the header bar so the user can see the screen
    /// behind it without losing the conversation. Drives the minimize button icon.
    @Published var isAnswerBodyVisible: Bool = true
    /// True only once the full answer has arrived (Mentorly is done thinking). The
    /// window-control buttons (collapse / resize) appear only then, so they don't
    /// flicker in mid-stream while the answer is still being written.
    @Published var isAnswerComplete: Bool = false
    /// True when the window is running in LIVE mode: a small chat box anchored at
    /// the bottom of the screen that streams a text answer while arrows are drawn
    /// on the real screen. No marked-up screenshot, and no full-screen maximize
    /// (there's no big image to enlarge).
    @Published var isLiveMode: Bool = false
    /// Bumped every time the window is shown so the view can refocus the
    /// text field even when the panel is being reused rather than recreated.
    @Published var presentationToken = UUID()
}

@MainActor
final class AskWindowManager: NSObject {
    private let viewModel = AskWindowViewModel()
    private var panel: NSPanel?
    private var onSubmitCallback: ((String) -> Void)?
    private var onCancelCallback: (() -> Void)?

    /// The window opens small — just enough for the header and the question
    /// pill — because at that point the user is only typing their thought. Sized
    /// to hug that content so there's no empty dark box below the input.
    private let composeWindowSize = CGSize(width: 480, height: 122)
    /// The answer window is fixed-width but its height is computed to fit the
    /// actual answer (question + marked-up screenshot + explanation). A short
    /// reply gets a short window instead of a big empty box; a long one is
    /// capped to `answerWindowMaxHeightFraction` of the screen and scrolls.
    /// Wider than before so the marked-up screenshot is large and legible —
    /// clamped to most of the screen width when shown so it always fits.
    private let answerWindowWidth: CGFloat = 920
    private let answerWindowMinHeight: CGFloat = 200
    private let answerWindowMaxHeightFraction: CGFloat = 0.92

    /// The compact content-fitted answer size, computed when the answer arrives
    /// and used when the user minimizes out of the full-screen view.
    private var compactAnswerSize: CGSize = CGSize(width: 920, height: 480)
    /// Height the window collapses to when the body is hidden (just the header).
    private let collapsedHeaderBarHeight: CGFloat = 60

    // MARK: Live-mode sizing

    /// Live mode is a small chat box anchored at the bottom of the screen — the
    /// answer streams in as text while arrows are drawn on the real screen, so
    /// it stays narrow and never covers the controls being pointed at.
    private let liveComposeWindowSize = CGSize(width: 520, height: 122)
    private let liveAnswerWindowWidth: CGFloat = 520
    /// Fixed height the box grows to the moment streaming starts, so the answer
    /// has room to read while it arrives (it then fits to content when complete).
    private let liveAnswerStreamingHeight: CGFloat = 340
    private let liveAnswerMinHeight: CGFloat = 140
    /// Live answers stay modest — capped to a bit over half the screen so the
    /// box never dominates; longer answers scroll inside it.
    private let liveAnswerMaxHeightFraction: CGFloat = 0.6
    /// Gap between the box and the bottom edge of the screen's usable area.
    private let liveBottomMargin: CGFloat = 40

    // MARK: - Live mode

    /// Shows the small live-mode ask box anchored at the bottom-center of the
    /// active screen, with the question field focused. In live mode the answer
    /// streams in as text while arrows are drawn on the real screen — so there's
    /// no marked-up screenshot and the box stays out of the way at the bottom.
    func showLiveAskWindow(
        onSubmit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        onSubmitCallback = onSubmit
        onCancelCallback = onCancel
        viewModel.screenshotPreviewImage = nil
        viewModel.questionText = ""
        viewModel.submittedQuestionText = ""
        viewModel.streamingAnswerText = ""
        viewModel.answerAnnotatedImage = nil
        viewModel.isComposing = true
        viewModel.isAnswerComplete = false
        viewModel.isLiveMode = true
        viewModel.isAnswerBodyVisible = true
        viewModel.isAnswerMaximized = false
        viewModel.presentationToken = UUID()

        if panel == nil {
            createPanel()
        }

        anchorPanelBottomCenter(size: liveComposeWindowSize, animated: false)

        panel?.alphaValue = 0
        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
        if let panel {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = DS.Animation.normal
                panel.animator().alphaValue = 1
            }
        }

        // Put the cursor in the question field so the user can type the instant
        // the box appears, without clicking it first. Setting `@FocusState` in the
        // view's `onAppear` races the panel becoming key — SwiftUI assigns focus
        // before the window is actually key and it silently drops. Re-asserting on
        // the next runloop tick, once the panel is key, makes the field reliably
        // first responder. (The panel is a nonactivating `KeyablePanel`, so it can
        // hold keyboard focus without Mentorly stealing frontmost from the user's app.)
        DispatchQueue.main.async { [weak self] in
            self?.panel?.makeKey()
            self?.viewModel.presentationToken = UUID()
        }
    }

    /// Switches the live box from the question field to the streaming answer,
    /// growing it once to a comfortable reading height anchored at the bottom.
    func beginLiveStreamingAnswer(forQuestion questionText: String) {
        viewModel.submittedQuestionText = questionText
        // Clear the field so the follow-up box starts empty (the same
        // `questionText` binding is reused for both the first question and the
        // follow-up field shown under a finished answer).
        viewModel.questionText = ""
        viewModel.streamingAnswerText = ""
        viewModel.answerAnnotatedImage = nil
        viewModel.isComposing = false
        viewModel.isAnswerComplete = false
        anchorPanelBottomCenter(
            size: CGSize(width: liveAnswerWindowWidth, height: liveAnswerStreamingHeight),
            animated: true
        )
    }

    /// Called once the full live answer has arrived: shows the final text and
    /// fits the box to its content height (anchored at the bottom so it grows
    /// upward, never sliding down over the screen content below it).
    func finishLiveAnswer(finalText: String) {
        viewModel.streamingAnswerText = finalText
        viewModel.answerAnnotatedImage = nil
        viewModel.isAnswerComplete = true
        // Bump the token so the view refocuses into the follow-up field that
        // appears under the finished answer — the user can just keep typing.
        viewModel.presentationToken = UUID()
        anchorPanelBottomCenter(size: liveAnswerWindowSize(forAnswerText: finalText), animated: true)
    }

    /// Anchors the panel centered horizontally and `liveBottomMargin` above the
    /// bottom of the active screen's usable area. Recomputed fresh from screen
    /// geometry each time (same drift-free approach as `centerPanel`).
    private func anchorPanelBottomCenter(size: CGSize, animated: Bool) {
        guard let panel, let targetScreen = activeScreenForPanel() else { return }

        let visibleFrame = targetScreen.visibleFrame
        let originX = visibleFrame.midX - (size.width / 2)
        let originY = visibleFrame.minY + liveBottomMargin
        let newFrame = NSRect(x: originX, y: originY, width: size.width, height: size.height)

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.4
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(newFrame, display: true)
            }
        } else {
            panel.setFrame(newFrame, display: true)
        }
    }

    /// Fits the live box to its text content: fixed live width, height summing
    /// the header, the question, and the answer text — clamped between a small
    /// minimum and a bit over half the screen (beyond which the answer scrolls).
    private func liveAnswerWindowSize(forAnswerText answerText: String) -> CGSize {
        let width = liveAnswerWindowWidth
        let contentWidth = width - DS.Spacing.lg * 2

        let outerVerticalPadding = DS.Spacing.lg * 2
        let headerRowHeight: CGFloat = 26
        let headerBottomPadding = DS.Spacing.md
        let transcriptSpacing = DS.Spacing.lg

        let questionHeight = estimatedTextHeight(
            viewModel.submittedQuestionText,
            fontSize: 14,
            lineSpacing: 0,
            contentWidth: contentWidth
        )
        let answerHeight = estimatedTextHeight(
            answerText.isEmpty ? "thinking..." : answerText,
            fontSize: 14,
            lineSpacing: 4,
            contentWidth: contentWidth
        )
        let safetyBuffer: CGFloat = 24

        // Room for the "ask a follow-up…" field pinned under a finished answer.
        let followUpFieldHeight: CGFloat = DS.Spacing.md + 46

        let totalContentHeight =
            outerVerticalPadding
            + headerRowHeight
            + headerBottomPadding
            + questionHeight
            + transcriptSpacing
            + answerHeight
            + followUpFieldHeight
            + safetyBuffer

        let screenHeight = activeScreenForPanel()?.visibleFrame.height ?? 900
        let maxHeight = screenHeight * liveAnswerMaxHeightFraction
        let clampedHeight = min(max(totalContentHeight, liveAnswerMinHeight), maxHeight)

        return CGSize(width: width, height: clampedHeight)
    }

    /// Switches the same window from the question text field over to the
    /// streamed-answer view, showing the submitted question as a label.
    func beginStreamingAnswer(forQuestion questionText: String) {
        viewModel.submittedQuestionText = questionText
        viewModel.streamingAnswerText = ""
        viewModel.answerAnnotatedImage = nil
        viewModel.isComposing = false
        viewModel.isAnswerComplete = false
    }

    func updateStreamingAnswer(_ accumulatedText: String) {
        viewModel.streamingAnswerText = accumulatedText
    }

    /// Called once the full answer has arrived: shows the final explanation text
    /// and, if Claude marked up the screenshot, the annotated image above it.
    /// `annotatedImage` is nil when the answer had no location-based marks
    /// (e.g. a pure-concept question), in which case only the text is shown.
    func finishAnswer(annotatedImage: NSImage?, finalText: String) {
        viewModel.streamingAnswerText = finalText
        viewModel.answerAnnotatedImage = annotatedImage

        // Remember the compact (content-hugging) size for when the user minimizes,
        // then open the answer maximized so the marked-up screenshot is big and
        // easy to read.
        compactAnswerSize = answerWindowSize(forAnswerText: finalText, annotatedImage: annotatedImage)
        viewModel.isAnswerMaximized = true
        viewModel.isAnswerBodyVisible = true
        viewModel.isAnswerComplete = true
        centerPanel(size: maximizedAnswerSize(), animated: true)
    }

    /// Toggles the answer window between filling the screen and its compact
    /// content-fitted size (the minimize / restore button).
    func toggleAnswerMaximized() {
        // If the body is hidden, reveal it first so the resize is meaningful.
        viewModel.isAnswerBodyVisible = true
        viewModel.isAnswerMaximized.toggle()
        applyAnswerWindowLayout(centered: viewModel.isAnswerMaximized, animated: true)
    }

    /// Toggles the answer body (screenshot + text) hidden vs shown — when hidden
    /// the window collapses to just the header bar so the page is "invisible"
    /// without closing it (the eye button).
    func toggleAnswerBodyVisibility() {
        viewModel.isAnswerBodyVisible.toggle()
        // Keep the window where it is (the user may have dragged it) rather than
        // recentering when collapsing/expanding.
        applyAnswerWindowLayout(centered: false, animated: true)
    }

    /// Resizes the answer panel to match the current maximized / body-visible
    /// state. Centered when going full-screen; otherwise anchored to where the
    /// window currently sits so a dragged window doesn't jump back to center.
    private func applyAnswerWindowLayout(centered: Bool, animated: Bool) {
        let targetSize: CGSize
        if !viewModel.isAnswerBodyVisible {
            let currentWidth = panel?.frame.width ?? compactAnswerSize.width
            targetSize = CGSize(width: currentWidth, height: collapsedHeaderBarHeight)
        } else if viewModel.isAnswerMaximized {
            targetSize = maximizedAnswerSize()
        } else {
            targetSize = compactAnswerSize
        }

        if centered {
            centerPanel(size: targetSize, animated: animated)
        } else {
            resizePanelKeepingTopCenter(to: targetSize, animated: animated)
        }
    }

    /// The near-full-screen answer size (inset a little from the screen edges).
    private func maximizedAnswerSize() -> CGSize {
        guard let visibleFrame = activeScreenForPanel()?.visibleFrame else {
            return CGSize(width: 1100, height: 800)
        }
        return CGSize(width: visibleFrame.width - 32, height: visibleFrame.height - 32)
    }

    /// Computes a window size that fits the answer content: the fixed answer
    /// width, and a height summing the header, the question, the marked-up
    /// screenshot (scaled to the content width by its own aspect ratio), and the
    /// explanation text — clamped between a sensible minimum and most of the
    /// screen height (beyond which the answer scrolls instead of growing).
    private func answerWindowSize(forAnswerText answerText: String, annotatedImage: NSImage?) -> CGSize {
        let screenWidth = activeScreenForPanel()?.visibleFrame.width ?? 1200
        let width = min(answerWindowWidth, screenWidth * 0.95)
        let horizontalPadding = DS.Spacing.lg * 2
        let contentWidth = width - horizontalPadding

        // Fixed chrome: outer top+bottom padding, the header row + its bottom
        // padding, and the gap between the question and Mentorly's reply in the
        // transcript.
        let outerVerticalPadding = DS.Spacing.lg * 2
        let headerRowHeight: CGFloat = 26
        let headerBottomPadding = DS.Spacing.md
        let transcriptSpacing = DS.Spacing.lg

        // The question is now left-aligned and spans the full content width.
        let questionHeight = estimatedTextHeight(
            viewModel.submittedQuestionText,
            fontSize: 14,
            lineSpacing: 0,
            contentWidth: contentWidth
        )

        let imageHeight: CGFloat
        if let annotatedImage, annotatedImage.size.width > 0, annotatedImage.size.height > 0 {
            imageHeight = contentWidth * (annotatedImage.size.height / annotatedImage.size.width)
        } else {
            imageHeight = 0
        }
        // Gap between the image and the answer text inside the reply block.
        let imageToTextGap: CGFloat = imageHeight > 0 ? DS.Spacing.md : 0

        let answerHeight = estimatedTextHeight(
            answerText.isEmpty ? "thinking..." : answerText,
            fontSize: 14,
            lineSpacing: 4,
            contentWidth: contentWidth
        )

        // Slack so a slightly-underestimated last line never clips (a little
        // extra height is harmless; clipping the answer is not).
        let safetyBuffer: CGFloat = 28

        let totalContentHeight =
            outerVerticalPadding
            + headerRowHeight
            + headerBottomPadding
            + questionHeight
            + transcriptSpacing
            + imageHeight
            + imageToTextGap
            + answerHeight
            + safetyBuffer

        let screenHeight = activeScreenForPanel()?.visibleFrame.height ?? 900
        let maxHeight = screenHeight * answerWindowMaxHeightFraction
        let clampedHeight = min(max(totalContentHeight, answerWindowMinHeight), maxHeight)

        return CGSize(width: width, height: clampedHeight)
    }

    /// Rough height of a block of text wrapped to `contentWidth`. Accounts for
    /// explicit line breaks plus soft wrapping using an average character width.
    /// Deliberately an estimate (exact AppKit text measurement isn't worth the
    /// complexity here) — the answer view scrolls if it's a touch too small.
    private func estimatedTextHeight(
        _ text: String,
        fontSize: CGFloat,
        lineSpacing: CGFloat,
        contentWidth: CGFloat
    ) -> CGFloat {
        guard !text.isEmpty else { return 0 }

        let averageCharacterWidth = fontSize * 0.52
        let charactersPerLine = max(1, Int(contentWidth / averageCharacterWidth))

        var totalLineCount = 0
        for paragraph in text.components(separatedBy: "\n") {
            let paragraphLength = max(1, paragraph.count)
            totalLineCount += Int(ceil(Double(paragraphLength) / Double(charactersPerLine)))
        }

        let perLineHeight = fontSize + lineSpacing + 3
        return CGFloat(totalLineCount) * perLineHeight
    }

    func showAnswerError(_ message: String) {
        viewModel.streamingAnswerText = message
    }

    /// Whether the ask box is currently on screen. Lets the trigger act as a
    /// toggle (open when hidden, close when shown).
    var isAskWindowVisible: Bool {
        panel?.isVisible ?? false
    }

    func hideAskWindow() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = DS.Animation.fast
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel?.orderOut(nil)
        })
    }

    // MARK: - Private

    private func createPanel() {
        let contentView = AskWindowContentView(
            viewModel: viewModel,
            onSubmit: { [weak self] questionText in
                self?.onSubmitCallback?(questionText)
            },
            onCancel: { [weak self] in
                self?.hideAskWindow()
                self?.onCancelCallback?()
            },
            onToggleSize: { [weak self] in
                self?.toggleAnswerMaximized()
            },
            onToggleHidden: { [weak self] in
                self?.toggleAnswerBodyVisibility()
            }
        )

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(origin: .zero, size: composeWindowSize)
        // The hosting view fills the panel's content area as it resizes, so the
        // SwiftUI content (which uses a flexible frame) reflows to fit both the
        // small compose size and the larger answer size.
        hostingView.autoresizingMask = [.width, .height]
        // Clip the window itself to rounded corners so there are no visible square
        // panel corners behind the SwiftUI rounded background.
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = 18
        hostingView.layer?.masksToBounds = true

        let askWindowPanel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: composeWindowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        askWindowPanel.isFloatingPanel = true
        askWindowPanel.level = .floating
        askWindowPanel.isOpaque = false
        askWindowPanel.backgroundColor = .clear
        // A real window shadow (the SwiftUI shadow would be clipped by the rounded
        // layer mask) that follows the rounded content shape.
        askWindowPanel.hasShadow = true
        askWindowPanel.hidesOnDeactivate = false
        askWindowPanel.isExcludedFromWindowsMenu = true
        askWindowPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Let the user grab anywhere on the window background and drag it around.
        askWindowPanel.isMovableByWindowBackground = true
        askWindowPanel.titleVisibility = .hidden
        askWindowPanel.titlebarAppearsTransparent = true
        askWindowPanel.contentView = hostingView

        panel = askWindowPanel
    }

    /// Sizes the panel to `size` and centers it on the active screen. Always
    /// recentered from the current screen geometry (never derived from the
    /// panel's previous frame), which is what kept the window stable in the
    /// earlier drift bugs. The compose→answer growth is the one intentional
    /// resize, animated so it reads as a deliberate expansion rather than a jump.
    private func centerPanel(size: CGSize, animated: Bool) {
        guard let panel, let targetScreen = activeScreenForPanel() else { return }

        let visibleFrame = targetScreen.visibleFrame
        let originX = visibleFrame.midX - (size.width / 2)
        let originY = visibleFrame.midY - (size.height / 2)
        let newFrame = NSRect(x: originX, y: originY, width: size.width, height: size.height)

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.4
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(newFrame, display: true)
            }
        } else {
            panel.setFrame(newFrame, display: true)
        }
    }

    /// Resizes the panel while keeping its top edge and horizontal center fixed,
    /// clamped to stay on screen. Used for the minimize / hide toggles so the
    /// window grows and shrinks in place instead of jumping back to center
    /// (important now that the window is draggable).
    private func resizePanelKeepingTopCenter(to size: CGSize, animated: Bool) {
        guard let panel else { return }

        let currentFrame = panel.frame
        let topCenterX = currentFrame.midX
        let topEdgeY = currentFrame.maxY

        var originX = topCenterX - (size.width / 2)
        var originY = topEdgeY - size.height

        if let visibleFrame = activeScreenForPanel()?.visibleFrame {
            originX = min(max(originX, visibleFrame.minX), max(visibleFrame.minX, visibleFrame.maxX - size.width))
            originY = min(max(originY, visibleFrame.minY), max(visibleFrame.minY, visibleFrame.maxY - size.height))
        }

        let newFrame = NSRect(x: originX, y: originY, width: size.width, height: size.height)

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.32
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(newFrame, display: true)
            }
        } else {
            panel.setFrame(newFrame, display: true)
        }
    }

    /// The screen the panel should live on: the one it's already centered on if
    /// it's visible, otherwise the screen the cursor is on. Keeps the expand
    /// animation on the same display the user is looking at.
    private func activeScreenForPanel() -> NSScreen? {
        if let panel, panel.isVisible {
            let panelCenter = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
            if let screenUnderPanel = NSScreen.screens.first(where: { $0.frame.contains(panelCenter) }) {
                return screenUnderPanel
            }
        }
        return NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    }
}

// MARK: - SwiftUI Content

private struct AskWindowContentView: View {
    @ObservedObject var viewModel: AskWindowViewModel
    var onSubmit: (String) -> Void
    var onCancel: () -> Void
    /// Minimize / restore between full-screen and compact.
    var onToggleSize: () -> Void
    /// Hide / show the answer body (collapse to just the header bar).
    var onToggleHidden: () -> Void

    @FocusState private var isTextFieldFocused: Bool

    /// Whether the typed question is non-empty (so the send button is active).
    private var canSubmitQuestion: Bool {
        !viewModel.questionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brandHeaderRow

            if viewModel.isComposing {
                composerInput
            } else if viewModel.isAnswerBodyVisible {
                answerTranscript

                // Once a live answer is finished, a follow-up field appears under
                // it (pinned below the scrollable transcript) so the user can ask
                // a connected question without reaching for the hotkey again.
                if viewModel.isLiveMode && viewModel.isAnswerComplete {
                    followUpInput
                        .padding(.top, DS.Spacing.md)
                }
            }
        }
        .padding(DS.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(DS.Colors.surface1)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
        .onExitCommand(perform: onCancel)
        .onAppear { isTextFieldFocused = true }
        .onChange(of: viewModel.presentationToken) { _, _ in
            isTextFieldFocused = true
        }
    }

    // MARK: - Header

    /// Logo + wordmark on the left, close button on the right — the chat-app
    /// style top bar (mirrors ChatGPT / OpenRouter, with Mentorly's own mark).
    private var brandHeaderRow: some View {
        HStack(spacing: DS.Spacing.sm) {
            ILearnLogoBadge()

            // The wordmark is deliberately larger + heavier than the composer
            // text below it, so the brand title reads as a heading and never
            // gets visually confused with the question the user types.
            Text("Mentorly")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(DS.Colors.textPrimary)

            Spacer()

            // Window controls only appear once Mentorly is done thinking, so they
            // don't flicker in mid-stream while the answer is still being written.
            if viewModel.isAnswerComplete {
                // Minus / plus: collapse the answer body to just this bar (so the
                // screen behind is visible) and bring it back.
                headerControlButton(
                    systemName: viewModel.isAnswerBodyVisible ? "minus" : "plus",
                    action: onToggleHidden
                )

                // Minimize / restore between full-screen and the compact size.
                // Hidden in live mode — there's no big screenshot to enlarge.
                if !viewModel.isLiveMode {
                    headerControlButton(
                        systemName: viewModel.isAnswerMaximized
                            ? "arrow.down.right.and.arrow.up.left"
                            : "arrow.up.left.and.arrow.down.right",
                        action: onToggleSize
                    )
                }
            }

            headerControlButton(systemName: "xmark", action: onCancel)
        }
        .padding(.bottom, viewModel.isComposing ? DS.Spacing.lg : DS.Spacing.md)
    }

    /// A small circular icon button used in the header bar (close / minimize /
    /// hide). Kept uniform so the controls read as a set.
    private func headerControlButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Composer (ChatGPT-style input pill)

    private var composerInput: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: DS.Spacing.sm) {
                // The system overrides a TextField `prompt:` color, so the
                // placeholder is drawn as our own Text behind the field (shown
                // only while the field is empty). It's deliberately a dimmed
                // secondary tone — not the brand's bright white — so the prompt
                // reads as an input hint and stays distinct from the wordmark.
                ZStack(alignment: .leading) {
                    if viewModel.questionText.isEmpty {
                        Text(viewModel.isLiveMode ? "ask mentorly about your screen..." : "ask mentorly about this...")
                            .font(.system(size: 15))
                            .foregroundColor(DS.Colors.textSecondary)
                            .allowsHitTesting(false)
                    }

                    TextField("", text: $viewModel.questionText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .foregroundColor(DS.Colors.textPrimary)
                        .focused($isTextFieldFocused)
                        .onSubmit(submitIfNotEmpty)
                }

                sendButton
            }
            .padding(.leading, DS.Spacing.md)
            .padding(.trailing, DS.Spacing.xs + 2)
            .padding(.vertical, DS.Spacing.xs + 2)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
            )

            Spacer(minLength: 0)
        }
    }

    /// Compact "ask a follow-up…" field shown under a finished live answer.
    /// Reuses the same `questionText` binding and submit path as the first
    /// question — submitting it continues the same conversation (the model keeps
    /// the prior turn in context) against a freshly re-captured screen.
    private var followUpInput: some View {
        HStack(alignment: .center, spacing: DS.Spacing.sm) {
            ZStack(alignment: .leading) {
                if viewModel.questionText.isEmpty {
                    Text("ask a follow-up...")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.85))
                        .allowsHitTesting(false)
                }

                TextField("", text: $viewModel.questionText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundColor(DS.Colors.textPrimary)
                    .focused($isTextFieldFocused)
                    .onSubmit(submitIfNotEmpty)
            }

            sendButton
        }
        .padding(.leading, DS.Spacing.md)
        .padding(.trailing, DS.Spacing.xs + 2)
        .padding(.vertical, DS.Spacing.xs + 2)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
    }

    /// Circular send button on the right of the input, ChatGPT-style: a solid
    /// white circle with a dark up-arrow when there's text to send, dimmed and
    /// disabled when the field is empty.
    private var sendButton: some View {
        Button(action: submitIfNotEmpty) {
            Image(systemName: "arrow.up")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(canSubmitQuestion ? Color.black : DS.Colors.textTertiary)
                .frame(width: 30, height: 30)
                .background(
                    Circle().fill(canSubmitQuestion ? Color.white : Color.white.opacity(0.1))
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .disabled(!canSubmitQuestion)
    }

    // MARK: - Answer transcript (ChatGPT-style chat thread)

    private var answerTranscript: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                // The user's question, left-aligned (flush, no bubble) so the
                // thread stays on the left like the composer above it.
                Text(viewModel.submittedQuestionText)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Mentorly's reply: the marked-up screenshot, then the explanation,
                // left-aligned with no bubble (mirrors the assistant style in
                // ChatGPT where assistant messages sit flush, not in a bubble).
                VStack(alignment: .leading, spacing: DS.Spacing.md) {
                    if let answerAnnotatedImage = viewModel.answerAnnotatedImage {
                        Image(nsImage: answerAnnotatedImage)
                            .resizable()
                            .interpolation(.high)
                            .antialiased(true)
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(Color.white.opacity(0.1), lineWidth: 0.8)
                            )
                    }

                    Text(renderedAnswerText(viewModel.streamingAnswerText))
                        .font(.system(size: 14, weight: .regular))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// Renders the answer as markdown so inline formatting like **bold** and
    /// `code` shows up styled instead of as literal asterisks/backticks. Falls
    /// back to plain text (e.g. while a partial stream has an unclosed `**`).
    /// Whitespace and line breaks are preserved so paragraphs stay intact.
    private func renderedAnswerText(_ rawText: String) -> AttributedString {
        guard !rawText.isEmpty else { return AttributedString("thinking...") }

        let markdownOptions = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attributed = try? AttributedString(markdown: rawText, options: markdownOptions) {
            return attributed
        }
        return AttributedString(rawText)
    }

    private func submitIfNotEmpty() {
        let trimmedQuestion = viewModel.questionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty else { return }
        onSubmit(trimmedQuestion)
    }
}

/// Small rounded-square app mark shown in the Ask Window header — a blue gem
/// with a graduation-cap glyph, standing in for a real logo asset.
private struct ILearnLogoBadge: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        DS.Colors.overlayCursorBlue,
                        DS.Colors.overlayCursorBlue.opacity(0.65)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 26, height: 26)
            .overlay(
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
            )
    }
}
