# ILearn

A macOS menu bar buddy that helps you understand whatever you're looking at on your screen. Press **Control+I**, drag-select the part of your screen you're confused about (same interactive selection as Cmd+Shift+4), type your question, and get a beginner-friendly explanation streamed into the same window.

This is a personal fork of [Clicky](https://github.com/farzaa/clicky) by Farza (MIT licensed, forking explicitly encouraged) — rebranded and reworked to drop the voice pipeline (AssemblyAI + ElevenLabs) in favor of typed questions and read answers, so the only thing you need to pay for is your own Anthropic API key.

## What's different from the original Clicky

- **No voice.** No microphone, no speech-to-text, no text-to-speech. You type your question into a window centered on screen; the answer streams in right below it.
- **Manual screen-region selection.** Instead of automatically screenshotting your whole screen, pressing Control+I lets you drag-select exactly the area you want explained — using macOS's own interactive screenshot tool.
- **Control+I instead of Control+Option**, since Control+Option is already used by other Claude tooling.
- **Beginner-friendly answers.** The system prompt is tuned to explain things in plain language rather than assume background knowledge.
- **No analytics, no email capture.** The original shipped a live PostHog key that logged full question/answer text, plus an onboarding email form that posted to the original developer's FormSpark endpoint. Both are removed.
- **Cheaper to run.** The Cloudflare Worker only proxies Claude now — no AssemblyAI or ElevenLabs keys needed.

The blue cursor buddy, the onboarding pointing demo, and the menu bar panel are still here — they just don't carry voice features anymore.

## Get started with Claude Code

The fastest way to get this running is with [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Once you're in this repo, just ask it to help you set up the Cloudflare Worker with your own Anthropic API key and get the app building in Xcode — it already knows the architecture from `CLAUDE.md`.

## Manual setup

### Prerequisites

- macOS 14.2+ (for ScreenCaptureKit)
- Xcode 15+
- Node.js 18+ (for the Cloudflare Worker)
- A [Cloudflare](https://cloudflare.com) account (free tier works)
- An [Anthropic](https://console.anthropic.com) API key

### 1. Set up the Cloudflare Worker

The Worker is a tiny proxy that holds your API key. The app talks to the Worker, the Worker talks to Claude. This way your key never ships in the app binary.

```bash
cd worker
npm install
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler deploy
```

It'll give you a URL like `https://your-worker-name.your-subdomain.workers.dev`. Copy that.

### 2. Run the Worker locally (for development)

```bash
cd worker
npx wrangler dev
```

This starts a local server (usually `http://localhost:8787`) that behaves exactly like the deployed Worker. Create a `worker/.dev.vars` file with:

```
ANTHROPIC_API_KEY=sk-ant-...
```

Then update the proxy URL in the Swift code to point to `http://localhost:8787` instead of the deployed Worker URL while developing.

### 3. Update the proxy URL in the app

The app reads the Worker URL from a local UserDefaults value, not from source — that way it never ends up committed (the Worker has no auth check, so a real URL sitting in a public repo could let anyone use your Anthropic API key). Set it once:

```bash
defaults write com.ilearn.app workerBaseURL "https://your-worker-name.your-subdomain.workers.dev"
```

Relaunch the app after setting this. If the key is never set, it falls back to the placeholder in `ILearn/CompanionManager.swift`.

### 4. Open in Xcode and run

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

If you want the full technical breakdown, read `CLAUDE.md`. Short version: a menu-bar app with no dock icon. Control+I triggers macOS's own interactive screenshot selection (`screencapture -i -s`), then opens a single fixed-size window centered on screen with the screenshot thumbnail and a text field. Your typed question plus the selected screenshot go to Claude via streaming SSE, and the same window switches to show your question plus the streamed answer below it. A separate blue cursor overlay handles the onboarding demo, where Claude can point at things on screen via `[POINT:x,y:label]` tags. All Claude API calls are proxied through a Cloudflare Worker so the API key never ships in the app.

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
