//
//  ClaudeCodeBackend.swift
//  Mentorly
//
//  An answer backend that drives the locally-installed Claude Code CLI
//  (`claude`) instead of the Cloudflare Worker + pay-as-you-go API key.
//
//  The CLI authenticates with the user's Claude subscription (the same login
//  Claude Code itself uses), so running Mentorly costs nothing beyond the plan
//  the user already pays for — there is no API key and no per-token billing.
//
//  This implements the same `ClaudeBackend` surface as `ClaudeAPI`, so the
//  rest of the app calls it identically and can be switched back to the
//  Worker path with a single UserDefaults flag.
//

import Foundation

/// The answer backend the app talks to. Two implementations exist:
///   - `ClaudeAPI`         — Cloudflare Worker proxy + Anthropic API key (paid).
///   - `ClaudeCodeBackend` — the local `claude` CLI using the user's
///                           subscription (no API key, no per-token billing).
/// Both expose the same streaming call so `CompanionManager` is agnostic to
/// which one is in use.
protocol ClaudeBackend: AnyObject {
    /// The Claude model used for answering (e.g. "claude-haiku-4-5"). Mutable
    /// so the menu-bar model picker can change it without rebuilding the backend.
    var model: String { get set }

    /// Sends the labeled screenshot(s) plus the user's question to Claude and
    /// streams the response. `onTextChunk` is called on the main actor with the
    /// full accumulated text each time more arrives, for progressive display.
    /// Returns the full answer text and the total round-trip duration.
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval)
}

/// Drives the `claude` command-line tool as the answer backend.
///
/// Each ask:
///   1. writes the selected screenshot region(s) to temporary image files,
///   2. spawns `claude -p ... --output-format stream-json`,
///   3. tells the model to Read those files and then answer the question,
///   4. parses the streamed JSON events and forwards the accumulated text.
final class ClaudeCodeBackend: ClaudeBackend {
    var model: String

    init(model: String) {
        self.model = model
    }

    enum ClaudeCodeBackendError: LocalizedError {
        case cliNotFound
        case launchFailed(String)
        case modelError(String)

        var errorDescription: String? {
            switch self {
            case .cliNotFound:
                return "couldn't find the Claude Code CLI (`claude`). install it from claude.com/code, sign in with your subscription, then try again. if it's installed somewhere unusual, run: defaults write com.ilearn.app claudeCliPath /full/path/to/claude"
            case .launchFailed(let details):
                return "couldn't start the Claude Code CLI — \(details)"
            case .modelError(let details):
                return details
            }
        }
    }

    /// One interpreted line of the CLI's JSONL stream. Pure (no side effects)
    /// so it can be unit-tested without spawning the `claude` process.
    enum StreamLineEvent: Equatable {
        /// An incremental chunk of the assistant's answer text (for live display).
        case textDelta(String)
        /// The terminal, authoritative final answer text.
        case finalResult(String)
        /// The run finished but reported an error.
        case modelError(String)
        /// A line we don't act on (thinking, tool-call JSON, blank, or malformed).
        case ignored
    }

    /// Interprets a single JSONL line from `claude --output-format stream-json`.
    /// We forward only the assistant's answer text — not its thinking, and not
    /// the JSON of any tool call it makes to Read the image.
    static func interpretStreamLine(_ line: String) -> StreamLineEvent {
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)
        guard !trimmedLine.isEmpty,
              let lineData = trimmedLine.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let eventType = event["type"] as? String else {
            return .ignored
        }

        switch eventType {
        case "stream_event":
            guard let streamEvent = event["event"] as? [String: Any],
                  streamEvent["type"] as? String == "content_block_delta",
                  let delta = streamEvent["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let textChunk = delta["text"] as? String else {
                return .ignored
            }
            return .textDelta(textChunk)

        case "result":
            // Terminal event. `result` holds the final answer text; `is_error`
            // flags a failed run.
            if let isError = event["is_error"] as? Bool, isError {
                let message = (event["result"] as? String)
                    ?? (event["subtype"] as? String)
                    ?? "the Claude Code CLI reported an error"
                return .modelError(message)
            } else if let resultText = event["result"] as? String {
                return .finalResult(resultText)
            }
            return .ignored

        default:
            return .ignored
        }
    }

    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        guard let claudeCliPath = Self.resolveClaudeCliPath() else {
            throw ClaudeCodeBackendError.cliNotFound
        }

        // Write each screenshot to a temp file the CLI can Read. Cleaned up
        // when this method returns, regardless of success or failure.
        let temporaryDirectory = FileManager.default.temporaryDirectory
        var writtenImagePaths: [(path: String, label: String)] = []
        defer {
            for writtenImage in writtenImagePaths {
                try? FileManager.default.removeItem(atPath: writtenImage.path)
            }
        }

        for (imageIndex, image) in images.enumerated() {
            let fileExtension = Self.fileExtension(for: image.data)
            let temporaryImageURL = temporaryDirectory.appendingPathComponent(
                "ilearn-ask-\(UUID().uuidString)-\(imageIndex).\(fileExtension)"
            )
            try image.data.write(to: temporaryImageURL)
            writtenImagePaths.append((path: temporaryImageURL.path, label: image.label))
        }

        let promptText = Self.buildPromptText(
            imagePaths: writtenImagePaths,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudeCliPath)
        process.arguments = [
            "--print",
            promptText,
            "--model", model,
            // Replace Claude Code's coding-agent persona with Mentorly's tutor
            // persona entirely, so answers read like a friendly explainer.
            "--system-prompt", systemPrompt,
            // Let the model Read the screenshot temp files without a permission
            // prompt (there's no interactive terminal to answer one).
            "--allowedTools", "Read",
            // Disable the user's configured MCP servers — Mentorly only needs
            // Read, and loading them adds startup latency and noise.
            "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
            // Emit fine-grained streaming JSON so we can show text as it arrives.
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--verbose"
        ]

        // The CLI is a self-contained native binary, but ensure common tool
        // locations are on PATH in case it shells out to anything. A GUI app's
        // inherited PATH is minimal, so prepend the usual Homebrew/local dirs.
        var environment = ProcessInfo.processInfo.environment
        let supplementalPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if let existingPath = environment["PATH"], !existingPath.isEmpty {
            environment["PATH"] = supplementalPath + ":" + existingPath
        } else {
            environment["PATH"] = supplementalPath
        }
        process.environment = environment

        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe
        // `claude --print` reads no stdin; give it an empty input so it never
        // blocks waiting for one.
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw ClaudeCodeBackendError.launchFailed(error.localizedDescription)
        }

        // If the surrounding Task is cancelled (the user asked again), kill the
        // CLI process so we don't leak it or keep streaming a stale answer.
        return try await withTaskCancellationHandler {
            var accumulatedAnswerText = ""
            var finalResultText: String?
            var modelErrorMessage: String?

            // Each line of stdout is one JSON event (JSONL). We accumulate the
            // assistant's `text_delta` chunks for live display and prefer the
            // authoritative `result` text once the run finishes.
            for try await line in standardOutputPipe.fileHandleForReading.bytes.lines {
                switch Self.interpretStreamLine(line) {
                case .textDelta(let textChunk):
                    accumulatedAnswerText += textChunk
                    let currentAccumulatedText = accumulatedAnswerText
                    await onTextChunk(currentAccumulatedText)

                case .finalResult(let resultText):
                    finalResultText = resultText

                case .modelError(let message):
                    modelErrorMessage = message

                case .ignored:
                    continue
                }
            }

            process.waitUntilExit()

            if let modelErrorMessage {
                throw ClaudeCodeBackendError.modelError(modelErrorMessage)
            }

            // A non-zero exit with no parsed result means something failed
            // before the model produced an answer — surface stderr to explain.
            if process.terminationStatus != 0 && finalResultText == nil && accumulatedAnswerText.isEmpty {
                let standardErrorData = standardErrorPipe.fileHandleForReading.readDataToEndOfFile()
                let standardErrorText = String(data: standardErrorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let details = standardErrorText.isEmpty
                    ? "exited with status \(process.terminationStatus)"
                    : standardErrorText
                throw ClaudeCodeBackendError.launchFailed(details)
            }

            // Prefer the authoritative final result text; fall back to whatever
            // we accumulated from the stream.
            let answerText = finalResultText ?? accumulatedAnswerText
            if finalResultText != nil {
                await onTextChunk(answerText)
            }

            let duration = Date().timeIntervalSince(startTime)
            return (text: answerText, duration: duration)
        } onCancel: {
            process.terminate()
        }
    }

    // MARK: - Prompt Construction

    /// Builds the `-p` prompt text: tells the model which temp files to Read,
    /// replays any prior conversation as plain text, then poses the question.
    private static func buildPromptText(
        imagePaths: [(path: String, label: String)],
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String
    ) -> String {
        var promptSections: [String] = []

        if !imagePaths.isEmpty {
            var imageInstruction = "First, use the Read tool to view the screenshot image(s) below, then answer the user's question about what's in them:"
            for imagePath in imagePaths {
                imageInstruction += "\n- \(imagePath.path) — \(imagePath.label)"
            }
            promptSections.append(imageInstruction)
        }

        if !conversationHistory.isEmpty {
            var historyText = "Earlier in this conversation:"
            for exchange in conversationHistory {
                historyText += "\n[user]: \(exchange.userPlaceholder)"
                historyText += "\n[you]: \(exchange.assistantResponse)"
            }
            promptSections.append(historyText)
        }

        promptSections.append("The user's question:\n\(userPrompt)")

        return promptSections.joined(separator: "\n\n")
    }

    // MARK: - CLI Resolution

    /// Finds the `claude` executable. A GUI app inherits a minimal PATH, so we
    /// check the common install locations directly before falling back to a
    /// login shell's PATH. An explicit override can be set with:
    ///   defaults write com.ilearn.app claudeCliPath /full/path/to/claude
    private static func resolveClaudeCliPath() -> String? {
        let fileManager = FileManager.default

        if let overridePath = UserDefaults.standard.string(forKey: "claudeCliPath"),
           fileManager.isExecutableFile(atPath: overridePath) {
            return overridePath
        }

        let homeDirectoryPath = fileManager.homeDirectoryForCurrentUser.path
        let candidatePaths = [
            "\(homeDirectoryPath)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/usr/bin/claude"
        ]
        for candidatePath in candidatePaths where fileManager.isExecutableFile(atPath: candidatePath) {
            return candidatePath
        }

        return resolveClaudeCliPathViaLoginShell()
    }

    /// Last-resort resolution: ask a login shell where `claude` is, so a custom
    /// install location that's on the user's PATH still works.
    private static func resolveClaudeCliPathViaLoginShell() -> String? {
        let loginShell = Process()
        loginShell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        loginShell.arguments = ["-lc", "command -v claude"]
        let outputPipe = Pipe()
        loginShell.standardOutput = outputPipe
        loginShell.standardError = FileHandle.nullDevice
        loginShell.standardInput = FileHandle.nullDevice

        do {
            try loginShell.run()
            loginShell.waitUntilExit()
        } catch {
            return nil
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let resolvedPath = String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !resolvedPath.isEmpty,
            FileManager.default.isExecutableFile(atPath: resolvedPath) else {
            return nil
        }
        return resolvedPath
    }

    // MARK: - Image Helpers

    /// Picks a file extension matching the image data so the CLI's Read tool
    /// recognizes it. Screen captures are JPEG; pasted/clipboard images are PNG.
    private static func fileExtension(for imageData: Data) -> String {
        let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        if imageData.count >= 4, [UInt8](imageData.prefix(4)) == pngSignature {
            return "png"
        }
        return "jpg"
    }
}
