# ILearn - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

macOS menu bar companion app. Lives entirely in the macOS status bar (no dock icon, no main window). Press Control+Z anywhere to open a small ask box at the bottom of the screen, type a question about whatever you're looking at, and get a beginner-friendly answer from Claude that streams into the box. As it answers, Claude points at the real controls on your actual screen: labeled arrows are drawn directly on the live UI, pinned to the exact buttons / links / fields it's talking about, so you follow along on the real thing while you read. The arrow positions come from macOS's own **Accessibility (AX) tree** — the model only NAMES a control (from a menu of on-screen controls we hand it), and the OS supplies that control's precise frame — so the arrows land on the real element instead of a guessed pixel, and it stays free on the user's Claude subscription (no extra API). A blue cursor overlay (separate from the ask flow) also flies to and points at a UI element during the onboarding demo.

> **Replaced flow (legacy, still in the tree but unwired):** An earlier version drag-selected a screen region and had Claude mark up a *static screenshot* with `[ARROW]`/`[BOX]`/`[STEP]` tags. It was replaced because a manually-selected region's on-screen origin wasn't known to the app, so model-estimated coordinates often pointed at the wrong spot. The Accessibility-driven live arrows are exact. The static-markup code (`ScreenshotAnnotation.swift`, `ScreenRegionCapture.swift`, and `CompanionManager.beginAskFlow` / `sendQuestionToClaude` / `companionAskResponseSystemPrompt`) is left in place but no longer wired to Control+Z; it can be deleted as a follow-up.

There is no voice input or output — everything is typed and read.

By default, ILearn answers by driving the locally-installed **Claude Code CLI** (`claude`), which authenticates with the user's Claude subscription — so there is no API key and no per-token billing beyond the plan they already pay for. A Cloudflare Worker + Anthropic API key path is still available as a fallback (`defaults write com.ilearn.app useClaudeCodeBackend -bool false`), with the key held on the Worker so it never ships in the app binary.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for the menu bar panel, Ask Window, and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **AI Chat**: Claude (Haiku 4.5 default for low cost, Sonnet 4.6 optional). Two interchangeable backends behind the `ClaudeBackend` protocol — `ClaudeCodeBackend` (default; drives the local `claude` CLI on the user's subscription) and `ClaudeAPI` (Cloudflare Worker proxy + API key, SSE streaming). Selected by the `useClaudeCodeBackend` UserDefaults flag (default `true`).
- **Screen + Accessibility capture (at hotkey-press time)**: When Control+Z fires, ILearn records the frontmost app's PID, captures a full screenshot of the cursor's screen (`CompanionScreenCaptureUtility.swift`), and scans that app's Accessibility tree (`AccessibilityElementLocator.swift`) into a menu of actionable on-screen controls — each with its exact on-screen frame. Both are captured *before* the (non-activating) ask box appears, so the box never pollutes the screenshot and the AX scan reads the user's real target app via the stored PID.
- **Ask Input/Output**: Global Control+Z shortcut (listen-only `CGEvent` tap, see `GlobalAskShortcutMonitor.swift`) opens a small, bottom-center, non-activating ask box (`AskWindowManager.showLiveAskWindow`). On submit it grows to a streaming-answer size and the answer streams straight into the box; once complete it fits to the answer's content. Bottom-anchored (not centered) so it sits out of the way while the user watches the arrows land on the real UI above it.
- **Follow-up questions (same session)**: Once a live answer finishes, an "ask a follow-up…" field appears pinned under it (`AskWindowContentView.followUpInput`). `CompanionManager.submitLiveQuestion` routes by whether `conversationHistory` is empty: the first question sends with the context captured before the box appeared; a follow-up RE-captures a fresh screenshot + AX scan first (`recaptureLiveContextThenSend` → `captureLiveContext`), because the user has likely acted on the arrows and the screen has changed. The transcript shows only the latest turn (the arrows on the real screen carry the rest); the model keeps prior turns via `conversationHistory`. Sessions are bounded: history is cleared when the box closes AND at the start of each new Control+Z, so a fresh hotkey press is always a clean topic rather than one endless thread.
- **Live element pointing**: The live system prompt (`companionLiveResponseSystemPrompt`) hands Claude the menu of on-screen control names and instructs it to emit `[POINT:exact control name]` (one target) and `[STEP:n:exact control name]` (an ordered how-to step) at the END of its reply, naming ONLY controls from the provided list. `LivePointingParser` (in `CompanionManager.swift`) parses these out — with mid-stream and trailing-partial tag stripping so raw markup never flashes in the prose — and `AccessibilityElementLocator.bestMatch` resolves each named control to a real on-screen frame. `CompanionManager.liveArrowTargets` (an array of `LiveArrowTarget`) then drives the persistent labeled-arrow overlay. Because the arrows live on the real screen, several can be pinned at once (e.g. numbered steps), and they STAY pinned while the user reads — cleared only when the ask box closes.
- **Element Pointing (onboarding only)**: Separate from the live arrows. Used by the onboarding demo (`performOnboardingDemoInteraction` in `CompanionManager.swift`) — Claude embeds a `[POINT:x,y:label:screenN]` tag, and the overlay flies the single blue cursor along a bezier arc to the target. Drives `detectedElementScreenLocation`/`detectedElementDisplayFrame` (the older single-cursor flight pipeline), which is distinct from the `liveArrowTargets` Canvas overlay used by the live ask flow.
- **Concurrency**: `@MainActor` isolation, async/await throughout

### Answer Backends

Both backends conform to the `ClaudeBackend` protocol (`ClaudeCodeBackend.swift`), so `CompanionManager` calls them identically.

**Claude Code CLI (default — `ClaudeCodeBackend.swift`).** Shells out to the locally-installed `claude` binary in headless mode. Each ask writes the selected screenshot region(s) to temp files, then runs `claude --print <prompt> --model <model> --system-prompt <persona> --allowedTools Read --strict-mcp-config --mcp-config '{"mcpServers":{}}' --output-format stream-json --include-partial-messages --verbose`. The prompt instructs the model to Read the temp screenshot files, then answer. Stdout is JSONL: we accumulate `stream_event` → `content_block_delta` → `text_delta` chunks for progressive display and prefer the terminal `result` event's text as authoritative. Authenticates with the user's Claude subscription via the CLI's own login — **no API key, no per-token billing**. The CLI path is found by checking `~/.local/bin/claude`, Homebrew/`/usr/local` dirs, then a login-shell `command -v claude`; override with `defaults write com.ilearn.app claudeCliPath /full/path/to/claude`. The user's configured MCP servers are disabled per-invocation for speed.

**Cloudflare Worker + API key (fallback — `ClaudeAPI.swift`).** Used when `useClaudeCodeBackend` is `false`. Requests go through a Cloudflare Worker (`worker/src/index.ts`) that holds the real API key as a secret — the app never calls the Claude API directly.

| Route | Upstream | Purpose |
|-------|----------|---------|
| `POST /chat` | `api.anthropic.com/v1/messages` | Claude vision + streaming chat |

Worker secrets: `ANTHROPIC_API_KEY`

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The companion panel uses `NSStatusItem` for the menu bar icon and a custom borderless `NSPanel` for the floating control panel. This gives full control over appearance (dark, rounded corners, custom shadow) and avoids the standard macOS menu/popover chrome. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks. The Ask Window reuses this same non-activating-panel pattern.

**Cursor Overlay**: A full-screen transparent `NSPanel` hosts the blue cursor companion. It's non-activating, joins all Spaces, and never steals focus. Outside of the onboarding demo, it just idles near the system cursor and shows a spinner while an ask is processing.

**Global Ask Shortcut**: Control+Z is captured via a listen-only `CGEvent` tap (rather than an AppKit global monitor) so it's detected reliably while the app is running in the background. The tap is listen-only, so it never swallows the keystroke — Control+Z still works normally elsewhere (and the macOS undo shortcut is Command+Z, not Control+Z, so there's no undo conflict).

**Live arrows via the Accessibility tree, not estimated coordinates**: ILearn points at the *real* screen using macOS's Accessibility (AX) API, which is free and works on the Claude subscription (no Computer-Use / element-detection API billing). At hotkey-press time it walks the frontmost app's AX tree (`AXUIElementCreateApplication(pid)` → windows → children) collecting actionable controls (buttons, links, fields, tabs, etc.), reading each one's label and `kAXPosition`/`kAXSize`. The model is given that menu of names and only NAMES a target; the OS supplies the exact frame, so arrows are pixel-accurate rather than model-guessed. AX positions are in top-left-origin "global flipped" space and are converted to AppKit global (bottom-left, y-up) coordinates in `AccessibilityElementLocator.appKitScreenFrame(of:)` before being handed to the overlay. **Accessibility permission is now load-bearing** for the core pointing feature (previously it was only needed for the onboarding demo).

**Browsers/Electron need a web-content AX opt-in**: Chrome, Arc, Edge, Brave, and Electron apps keep the accessibility tree for their *web content* switched OFF by default — an AX scan of them otherwise sees only the native chrome (toolbar, tabs, address bar) and none of the page's buttons/links/fields, so the model gets handed a control menu missing the very thing being asked about. `AccessibilityElementLocator.enableEnhancedAccessibility(forProcessIdentifier:)` sets `AXManualAccessibility` + `AXEnhancedUserInterface` to true on the app element to turn it on. `CompanionManager.beginLiveAskFlow` calls it the instant Control+Z fires (before capturing the screenshot) so the tree has time to build, then waits a short beat before scanning since the tree is created lazily on first request.

**Persistent multi-arrow overlay, separate from the flight cursor**: The live arrows do NOT reuse the single flying blue cursor. A new `LiveArrowsCanvas` (SwiftUI `Canvas`, one instance per screen, in `OverlayWindow.swift`) draws every active `LiveArrowTarget` at once — a connector line, an arrowhead, a target ring, and a rounded labeled pill (step numbers prefixed as "n. label") — and the markers STAY pinned while the user reads. This is intentionally distinct from `detectedElementScreenLocation` (the single-cursor bezier flight used by onboarding): the live flow needs several simultaneous, persistent markers, which the flight animation can't express.

**Bottom-anchored ask box, capture before it appears**: `AskWindowManager.showLiveAskWindow` anchors a small non-activating box at the bottom-center of the active screen (out of the way of the arrows above it), growing once when the answer starts streaming and fitting to content when done. Because the box is non-activating, ILearn never becomes frontmost — but to be safe the screenshot + AX scan are still taken at hotkey-press time using the stored frontmost PID, so the box can never be in the captured image and the AX scan always reads the user's real target app.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `ILearnApp.swift` | ~86 | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which creates `MenuBarPanelManager` and starts `CompanionManager`. No main window — the app lives entirely in the status bar. |
| `CompanionManager.swift` | ~900 | Central state machine. Owns the global shortcut monitor, full-screen + Accessibility capture, the Ask Window, the Claude streaming call, and both overlays. Coordinates the live Control+Z → capture screenshot + AX scan → ask → stream → parse `[POINT]`/`[STEP]` tags → resolve to real frames → pin persistent arrows pipeline (`beginLiveAskFlow` / `sendLiveQuestionToClaude` / `applyLiveArrows`, `companionLiveResponseSystemPrompt`, `liveArrowTargets`). Also hosts `LivePointingParser` (tag parsing + display stripping) and the separate onboarding pointing demo. The legacy static-screenshot flow (`beginAskFlow` / `sendQuestionToClaude` / `companionAskResponseSystemPrompt`) is still present but no longer wired to the hotkey. |
| `MenuBarPanelManager.swift` | ~240 | NSStatusItem + custom NSPanel lifecycle. Creates the menu bar icon, manages the floating companion panel (show/hide/position), installs click-outside-to-dismiss monitor. |
| `CompanionPanelView.swift` | ~580 | SwiftUI panel content for the menu bar dropdown. Shows companion status, the Control+Z instructions, model picker (Haiku/Sonnet), permissions UI, and quit button. Dark aesthetic using `DS` design system. |
| `AskWindowManager.swift` | ~360 | Non-activating `NSPanel` for the ask flow. The live flow (`showLiveAskWindow` / `beginLiveStreamingAnswer` / `finishLiveAnswer`, `isLiveMode`) anchors a small box at the bottom-center of the active screen, grows it to a streaming size on submit, and fits it to the answer's content when done (`anchorPanelBottomCenter`, `liveAnswerWindowSize`). The legacy centered static flow (`showAskWindow`) is retained but unwired. |
| `AccessibilityElementLocator.swift` | ~330 | Scans the frontmost app's Accessibility (AX) tree into actionable on-screen controls with exact frames. `actionableElementsForFrontmostApp` / `actionableElements(forProcessIdentifier:)` walk windows → children (role/label/position/size), capping nodes/depth; `bestMatch(forTargetName:in:)` resolves a model-named control (exact → containment → token-overlap). `AccessibleElement` carries the AppKit-global `screenFrame`/`screenCenter`; `appKitScreenFrame(of:)` does the AX→AppKit coordinate conversion. `hasAccessibilityPermission()` wraps `AXIsProcessTrusted()`. |
| `ScreenshotAnnotation.swift` | ~330 | **Legacy (unwired).** Parsed Claude's `[ARROW]`/`[BOX]`/`[STEP]` tags and drew them onto a static screenshot via Core Graphics. Belonged to the replaced drag-select flow; kept in the tree but no longer called. |
| `ScreenRegionCapture.swift` | ~50 | **Legacy (unwired).** Shelled out to `/usr/sbin/screencapture -i -s` for interactive drag-to-select. Belonged to the replaced static flow; no longer called by the hotkey path. |
| `OverlayWindow.swift` | ~1000 | Full-screen transparent overlay (one per screen). Hosts the onboarding blue cursor + bezier-arc flight animation AND the live `LiveArrowsCanvas` that draws every active `LiveArrowTarget` (connector, arrowhead, target ring, labeled pill) and keeps them pinned. Defines `LiveArrowTarget`. Handles multi-monitor coordinate mapping (`convertScreenPointToSwiftUICoordinates`) and fade transitions. |
| `GlobalAskShortcutMonitor.swift` | ~165 | System-wide Control+Z shortcut monitor. Owns the listen-only `CGEvent` tap and publishes press/release transitions. |
| `CompanionScreenCaptureUtility.swift` | ~130 | Multi-monitor full-screenshot capture using ScreenCaptureKit. Used by the live ask flow (captures the cursor's screen at hotkey-press time) and the onboarding pointing demo. |
| `ClaudeCodeBackend.swift` | ~310 | Default answer backend. Defines the `ClaudeBackend` protocol and drives the local `claude` CLI (subscription auth, no API key) via a streamed `claude --print ... --output-format stream-json` subprocess. Writes screenshots to temp files, parses JSONL stream events, supports Task cancellation (terminates the process), resolves the CLI path across common install locations. |
| `ClaudeAPI.swift` | ~290 | Fallback answer backend (conforms to `ClaudeBackend`). Claude vision API client over the Worker proxy with streaming (SSE) and non-streaming modes. TLS warmup optimization, image MIME detection, conversation history support. |
| `ElementLocationDetector.swift` | ~335 | Detects UI element locations in screenshots. Used by the onboarding pointing demo. |
| `DesignSystem.swift` | ~880 | Design system tokens — colors, corner radii, shared styles. All UI references `DS.Colors`, `DS.CornerRadius`, etc. |
| `WindowPositionManager.swift` | ~260 | Window placement logic, Screen Recording permission flow, and accessibility permission helpers. |
| `AppBundleConfiguration.swift` | ~30 | Runtime configuration reader for keys stored in the app bundle Info.plist. |
| `worker/src/index.ts` | ~70 | Cloudflare Worker proxy. One route: `/chat` (Claude). |

`OpenAIAPI.swift` exists in the source tree but isn't wired up anywhere — pre-existing dead code from before this fork, left untouched.

## Build & Run

```bash
# Open in Xcode
open ILearn.xcodeproj

# Select the ILearn scheme, set signing team, Cmd+R to build and run

# Known non-blocking warnings: Swift 6 concurrency warnings,
# deprecated onChange warning in OverlayWindow.swift. Do NOT attempt to fix these.
```

**Do NOT run `xcodebuild` from the terminal** — it invalidates TCC (Transparency, Consent, and Control) permissions and the app will need to re-request screen recording, accessibility, etc.

## Cloudflare Worker

```bash
cd worker
npm install

# Add the secret
npx wrangler secret put ANTHROPIC_API_KEY

# Deploy
npx wrangler deploy

# Local dev (create worker/.dev.vars with your key)
npx wrangler dev
```

## Code Style & Conventions

### Variable and Method Naming

IMPORTANT: Follow these naming rules strictly. Clarity is the top priority.

- Be as clear and specific with variable and method names as possible
- **Optimize for clarity over concision.** A developer with zero context on the codebase should immediately understand what a variable or method does just from reading its name
- Use longer names when it improves clarity. Do NOT use single-character variable names
- Example: use `originalQuestionLastAnsweredDate` instead of `originalAnswered`
- When passing props or arguments to functions, keep the same names as the original variable. Do not shorten or abbreviate parameter names. If you have `currentCardData`, pass it as `currentCardData`, not `card` or `cardData`

### Code Clarity

- **Clear is better than clever.** Do not write functionality in fewer lines if it makes the code harder to understand
- Write more lines of code if additional lines improve readability and comprehension
- Make things so clear that someone with zero context would completely understand the variable names, method names, what things do, and why they exist
- When a variable or method name alone cannot fully explain something, add a comment explaining what is happening and why

### Swift/SwiftUI Conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit (e.g., `NSPanel` for floating windows)
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- Comments should explain "why" not just "what", especially for non-obvious AppKit bridging
- AppKit `NSPanel`/`NSWindow` bridged into SwiftUI via `NSHostingView`
- All buttons must show a pointer cursor on hover
- For any interactive element, explicitly think through its hover behavior (cursor, visual feedback, and whether hover should communicate clickability)

### Do NOT

- Do not add features, refactor code, or make "improvements" beyond what was asked
- Do not add docstrings, comments, or type annotations to code you did not change
- Do not try to fix the known non-blocking warnings (Swift 6 concurrency, deprecated onChange)
- Do not run `xcodebuild` from the terminal — it invalidates TCC permissions
- Do not add analytics/telemetry SDKs or third-party crash reporting without being asked — this fork deliberately removed PostHog because it was logging full question/answer text to the original app's analytics project

## Git Workflow

- Branch naming: `feature/description` or `fix/description`
- Commit messages: imperative mood, concise, explain the "why" not the "what"
- Do not force-push to main

## Self-Update Instructions

<!-- AI agents: follow these instructions to keep this file accurate. -->

When you make changes to this project that affect the information in this file, update this file to reflect those changes. Specifically:

1. **New files**: Add new source files to the "Key Files" table with their purpose and approximate line count
2. **Deleted files**: Remove entries for files that no longer exist
3. **Architecture changes**: Update the architecture section if you introduce new patterns, frameworks, or significant structural changes
4. **Build changes**: Update build commands if the build process changes
5. **New conventions**: If the user establishes a new coding convention during a session, add it to the appropriate conventions section
6. **Line count drift**: If a file's line count changes significantly (>50 lines), update the approximate count in the Key Files table

Do NOT update this file for minor edits, bug fixes, or changes that don't affect the documented architecture or conventions.
