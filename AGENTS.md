# ILearn - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

macOS menu bar companion app. Lives entirely in the macOS status bar (no dock icon, no main window). Press Control+I anywhere to drag-select a region of your screen (using macOS's own interactive screenshot tool), type a question about it in the Ask Window that opens centered on screen, and get a beginner-friendly answer from Claude that streams into the same window below the question. A blue cursor overlay (separate from the ask flow) can also fly to and point at UI elements during the onboarding demo.

There is no voice input or output — everything is typed and read. The only paid dependency is your own Anthropic API key, held on a Cloudflare Worker proxy so it never ships in the app binary.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for the menu bar panel, Ask Window, and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **AI Chat**: Claude (Haiku 4.5 default for low cost, Sonnet 4.6 optional) via Cloudflare Worker proxy with SSE streaming
- **Screen Region Capture**: Shells out to `/usr/sbin/screencapture -i -s` (the same interactive tool behind Cmd+Shift+4) so the user drag-selects exactly the region they want answered about. See `ScreenRegionCapture.swift`.
- **Ask Input/Output**: Global Control+I shortcut (listen-only `CGEvent` tap, see `GlobalAskShortcutMonitor.swift`) opens a single fixed-size, centered window (`AskWindowManager.swift`) that shows the screenshot thumbnail, the question text field, and — after submitting — the same question plus Claude's streamed answer in a scrollable area. One window for the whole flow, not two independently-positioned panels.
- **Element Pointing**: Only used by the onboarding demo (`performOnboardingDemoInteraction` in `CompanionManager.swift`) — Claude embeds a `[POINT:x,y:label:screenN]` tag, and the overlay animates the blue cursor along a bezier arc to the target. Not used by the main ask flow, since a manually-selected screen region's on-screen origin isn't known to the app.
- **Concurrency**: `@MainActor` isolation, async/await throughout

### API Proxy (Cloudflare Worker)

The app never calls the Claude API directly. All requests go through a Cloudflare Worker (`worker/src/index.ts`) that holds the real API key as a secret.

| Route | Upstream | Purpose |
|-------|----------|---------|
| `POST /chat` | `api.anthropic.com/v1/messages` | Claude vision + streaming chat |

Worker secrets: `ANTHROPIC_API_KEY`

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The companion panel uses `NSStatusItem` for the menu bar icon and a custom borderless `NSPanel` for the floating control panel. This gives full control over appearance (dark, rounded corners, custom shadow) and avoids the standard macOS menu/popover chrome. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks. The Ask Window reuses this same non-activating-panel pattern.

**Cursor Overlay**: A full-screen transparent `NSPanel` hosts the blue cursor companion. It's non-activating, joins all Spaces, and never steals focus. Outside of the onboarding demo, it just idles near the system cursor and shows a spinner while an ask is processing.

**Global Ask Shortcut**: Control+I is captured via a listen-only `CGEvent` tap (rather than an AppKit global monitor) so it's detected reliably while the app is running in the background. Chosen over Control+Option since that combination is already used by other Claude tooling.

**Screen Region Capture via the System Tool**: Rather than building a custom drag-to-select overlay, `ScreenRegionCapture.swift` shells out to `/usr/sbin/screencapture -i -s`. This gets Apple's own polished, battle-tested selection UI for free (multi-monitor dragging, Retina scaling, Escape-to-cancel) at the cost of not knowing the selected region's on-screen origin afterward — which is why the main ask flow doesn't support element pointing.

**One Ask Window, Not Two Drifting Panels**: An earlier version used a separate input bar and a separately-positioned, dynamically-resizing answer overlay. Two independently-positioned panels that each recomputed their own anchor turned out fragile — resizing on every streamed text chunk caused visible drift, and the two panels could end up positioned inconsistently relative to each other. `AskWindowManager.swift` is a single fixed-size (480×440) window, centered fresh from the current screen's geometry every time it's shown (never derived from a previous frame), that just swaps its content between "composing" (text field) and "answering" (question + scrollable streamed text) states. No per-chunk window resizing, no inter-panel coordination.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `ILearnApp.swift` | ~86 | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which creates `MenuBarPanelManager` and starts `CompanionManager`. No main window — the app lives entirely in the status bar. |
| `CompanionManager.swift` | ~640 | Central state machine. Owns the global shortcut monitor, screen-region capture, the Ask Window, Claude streaming call, and cursor overlay. Tracks ask state (idle/processing), conversation history, model selection, and cursor visibility. Coordinates the full Control+I → region select → ask → stream pipeline, plus the separate onboarding pointing demo. |
| `MenuBarPanelManager.swift` | ~240 | NSStatusItem + custom NSPanel lifecycle. Creates the menu bar icon, manages the floating companion panel (show/hide/position), installs click-outside-to-dismiss monitor. |
| `CompanionPanelView.swift` | ~580 | SwiftUI panel content for the menu bar dropdown. Shows companion status, the Control+I instructions, model picker (Haiku/Sonnet), permissions UI, and quit button. Dark aesthetic using `DS` design system. |
| `AskWindowManager.swift` | ~270 | Single fixed-size, centered, non-activating `NSPanel` for the whole ask flow — screenshot thumbnail, question text field, then (after submit) the question plus a scrollable streamed answer, all in the same window. Replaced an earlier two-panel design (separate input bar + independently-positioned answer overlay) that drifted on screen. |
| `ScreenRegionCapture.swift` | ~50 | Shells out to `/usr/sbin/screencapture -i -s` for interactive drag-to-select screenshotting. Returns the captured region as PNG data, or nil if the user cancelled. |
| `OverlayWindow.swift` | ~830 | Full-screen transparent overlay hosting the blue cursor and pointing animation. Handles cursor following, the bezier-arc flight animation, multi-monitor coordinate mapping, and fade transitions. |
| `GlobalAskShortcutMonitor.swift` | ~165 | System-wide Control+I shortcut monitor. Owns the listen-only `CGEvent` tap and publishes press/release transitions. |
| `CompanionScreenCaptureUtility.swift` | ~130 | Multi-monitor full-screenshot capture using ScreenCaptureKit. Used by the onboarding pointing demo (the main ask flow uses `ScreenRegionCapture` instead). |
| `ClaudeAPI.swift` | ~290 | Claude vision API client with streaming (SSE) and non-streaming modes. TLS warmup optimization, image MIME detection, conversation history support. |
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
