//
//  AskWindowManager.swift
//  ILearn
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

    private let windowWidth: CGFloat = 480
    private let windowHeight: CGFloat = 440

    /// Shows the window centered on the screen the cursor is currently on,
    /// with the question text field focused and ready for typing.
    func showAskWindow(
        screenshotPreviewImage: NSImage?,
        onSubmit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        onSubmitCallback = onSubmit
        onCancelCallback = onCancel
        viewModel.screenshotPreviewImage = screenshotPreviewImage
        viewModel.questionText = ""
        viewModel.submittedQuestionText = ""
        viewModel.streamingAnswerText = ""
        viewModel.isComposing = true
        viewModel.presentationToken = UUID()

        if panel == nil {
            createPanel()
        }

        centerPanelOnScreen()

        panel?.alphaValue = 0
        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
        if let panel {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = DS.Animation.normal
                panel.animator().alphaValue = 1
            }
        }
    }

    /// Switches the same window from the question text field over to the
    /// streamed-answer view, showing the submitted question as a label.
    func beginStreamingAnswer(forQuestion questionText: String) {
        viewModel.submittedQuestionText = questionText
        viewModel.streamingAnswerText = ""
        viewModel.isComposing = false
    }

    func updateStreamingAnswer(_ accumulatedText: String) {
        viewModel.streamingAnswerText = accumulatedText
    }

    func showAnswerError(_ message: String) {
        viewModel.streamingAnswerText = message
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
            }
        )

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)

        let askWindowPanel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        askWindowPanel.isFloatingPanel = true
        askWindowPanel.level = .floating
        askWindowPanel.isOpaque = false
        askWindowPanel.backgroundColor = .clear
        askWindowPanel.hasShadow = false
        askWindowPanel.hidesOnDeactivate = false
        askWindowPanel.isExcludedFromWindowsMenu = true
        askWindowPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        askWindowPanel.isMovableByWindowBackground = false
        askWindowPanel.titleVisibility = .hidden
        askWindowPanel.titlebarAppearsTransparent = true
        askWindowPanel.contentView = hostingView

        panel = askWindowPanel
    }

    /// Always centers fresh from the current screen geometry — never
    /// derives a new position from the panel's previous frame, which is
    /// what caused the earlier drift/off-screen bugs.
    private func centerPanelOnScreen() {
        guard let panel else { return }

        let targetScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let targetScreen else { return }

        let visibleFrame = targetScreen.visibleFrame
        let originX = visibleFrame.midX - (windowWidth / 2)
        let originY = visibleFrame.midY - (windowHeight / 2)

        panel.setFrame(
            NSRect(x: originX, y: originY, width: windowWidth, height: windowHeight),
            display: true
        )
    }
}

// MARK: - SwiftUI Content

private struct AskWindowContentView: View {
    @ObservedObject var viewModel: AskWindowViewModel
    var onSubmit: (String) -> Void
    var onCancel: () -> Void

    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            HStack {
                Text("ILearn")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)
                        .frame(width: 22, height: 22)
                        .background(
                            Circle().fill(Color.white.opacity(0.1))
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }

            if let screenshotPreviewImage = viewModel.screenshotPreviewImage {
                Image(nsImage: screenshotPreviewImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 140)
                    .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
                    )
            }

            if viewModel.isComposing {
                TextField(
                    "",
                    text: $viewModel.questionText,
                    prompt: Text("ask ilearn about this...").foregroundColor(DS.Colors.textTertiary)
                )
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, DS.Spacing.sm)
                    .padding(.vertical, DS.Spacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .fill(Color.white.opacity(0.07))
                    )
                    .focused($isTextFieldFocused)
                    .onSubmit(submitIfNotEmpty)

                Spacer(minLength: 0)
            } else {
                Text(viewModel.submittedQuestionText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()
                    .background(DS.Colors.borderSubtle)

                ScrollView {
                    Text(viewModel.streamingAnswerText.isEmpty ? "thinking..." : viewModel.streamingAnswerText)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding(DS.Spacing.lg)
        .frame(width: 480, height: 440, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.surface1)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                        .stroke(DS.Colors.overlayCursorBlue.opacity(0.55), lineWidth: 1.2)
                )
                .shadow(color: Color.black.opacity(0.5), radius: 30, x: 0, y: 16)
        )
        .onExitCommand(perform: onCancel)
        .onAppear { isTextFieldFocused = true }
        .onChange(of: viewModel.presentationToken) { _, _ in
            isTextFieldFocused = true
        }
    }

    private func submitIfNotEmpty() {
        let trimmedQuestion = viewModel.questionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty else { return }
        onSubmit(trimmedQuestion)
    }
}
