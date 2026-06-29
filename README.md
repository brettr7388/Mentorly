# ILearn

A macOS menu bar buddy that helps you understand whatever you're looking at on your screen. Press **Control+I**, drag-select the part of your screen you're confused about (same interactive selection as Cmd+Shift+4), type your question, and get a beginner-friendly explanation streamed into the same window.

This is a personal fork of [Clicky](https://github.com/farzaa/clicky) by Farza (MIT licensed, forking explicitly encouraged) — rebranded and reworked to drop the voice pipeline (AssemblyAI + ElevenLabs) in favor of typed questions and read answers. By default it runs on your existing **Claude subscription** through the [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI, so there's **no API key and no per-token billing** — nothing extra to pay for beyond the plan you already have.

## What's different from the original Clicky

- **No voice.** No microphone, no speech-to-text, no text-to-speech. You type your question into a window centered on screen; the answer streams in right below it.
- **Manual screen-region selection.** Instead of automatically screenshotting your whole screen, pressing Control+I lets you drag-select exactly the area you want explained — using macOS's own interactive screenshot tool.
- **Control+I instead of Control+Option**, since Control+Option is already used by other Claude tooling.
- **Beginner-friendly answers.** The system prompt is tuned to explain things in plain language rather than assume background knowledge.
- **No analytics, no email capture.** The original shipped a live PostHog key that logged full question/answer text, plus an onboarding email form that posted to the original developer's FormSpark endpoint. Both are removed.
- **Free to run on your Claude subscription.** By default ILearn answers by driving the local `claude` CLI, which signs in with your Claude plan — no Anthropic API key and no per-token charges. (A Cloudflare Worker + API key path is still there as an optional fallback.)

The blue cursor buddy, the onboarding pointing demo, and the menu bar panel are still here — they just don't carry voice features anymore.

## Setup (default — your Claude subscription, no API key)

### Prerequisites

- macOS 14.2+ (for ScreenCaptureKit)
- Xcode 15+
- The [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI, installed and signed in with your Claude subscription

### 1. Install and sign in to the Claude Code CLI

Install Claude Code, then sign in once with your Claude account:

```bash
claude        # launches Claude Code; sign in with your Claude subscription
claude -p "hello"   # confirm it answers without an API key
```

ILearn looks for the `claude` binary in `~/.local/bin`, Homebrew, and `/usr/local/bin`, and falls back to your login-shell `PATH`. If it's installed somewhere unusual, point the app at it:

```bash
defaults write com.ilearn.app claudeCliPath "/full/path/to/claude"
```

### 2. Open in Xcode and run

That's it — no Worker, no key. The app shells out to the CLI, which uses your subscription. Pick your model in the menu-bar panel (Haiku for speed/cost, Sonnet for depth).

## Optional: Cloudflare Worker + API key fallback

If you'd rather use a pay-as-you-go Anthropic API key (for example, to distribute to people who don't have a Claude subscription), switch the backend off the CLI:

```bash
defaults write com.ilearn.app useClaudeCodeBackend -bool false
```

Then set up the Worker, which holds your API key so it never ships in the app binary:

```bash
cd worker
npm install
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler deploy   # prints a https://your-worker-name.your-subdomain.workers.dev URL
```

Point the app at that URL (read from local UserDefaults, never committed, since the Worker has no auth check):

```bash
defaults write com.ilearn.app workerBaseURL "https://your-worker-name.your-subdomain.workers.dev"
```

For local Worker development, `npx wrangler dev` serves `http://localhost:8787` (behaves like the deployed Worker); put `ANTHROPIC_API_KEY=sk-ant-...` in `worker/.dev.vars` and set `workerBaseURL` to the localhost URL. Relaunch the app after changing any of these.

### Open in Xcode and run

```bash
open ILearn.xcodeproj
```

In Xcode:
1. Select the `ILearn` scheme
2. Set your signing team under Signing & Capabilities
3. Hit **Cmd + R** to build and run

The app will appear in your menu bar (not the dock). Click the icon to open the panel, grant the permissions it asks for, and you're good.

### Permissions the app needs

- **Accessibility** — for the global Control+I keyboard shortcut
- **Screen Recording** — for capturing the region you select when you use the hotkey
- **Screen Content** — for ScreenCaptureKit access (onboarding demo)

## Architecture

If you want the full technical breakdown, read `CLAUDE.md`. Short version: a menu-bar app with no dock icon. Control+I triggers macOS's own interactive screenshot selection (`screencapture -i -s`), then opens a single fixed-size window centered on screen with the screenshot thumbnail and a text field. Your typed question plus the selected screenshot go to Claude via streaming SSE, and the same window switches to show your question plus the streamed answer below it. A separate blue cursor overlay handles the onboarding demo, where Claude can point at things on screen via `[POINT:x,y:label]` tags. By default the answer comes from the local `claude` CLI running on your Claude subscription (no API key); an optional Cloudflare Worker + API key path is available as a fallback.

## Project structure

```
ILearn/                  # Swift source
  CompanionManager.swift     # Central state machine
  CompanionPanelView.swift   # Menu bar panel UI
  AskWindowManager.swift     # The whole ask flow: input + streamed answer, one window
  ScreenRegionCapture.swift  # Drag-to-select screenshot capture
  ClaudeAPI.swift            # Claude streaming client
  OverlayWindow.swift        # Blue cursor overlay + onboarding demo
  GlobalAskShortcutMonitor.swift  # Control+I global shortcut
worker/                  # Cloudflare Worker proxy
  src/index.ts               # One route: /chat
CLAUDE.md                # Full architecture doc (agents read this)
```

## License

MIT, same as the original Clicky. See `LICENSE`.
