# Mentorly

A macOS menu bar buddy that helps you understand whatever you're looking at on your screen. Press **Control+Z** anywhere, type what you're confused about, and get a beginner-friendly explanation that streams into a small box at the bottom of your screen. As it answers, Mentorly draws labeled arrows **directly on your real screen**, pinned to the actual buttons, links, and fields it's talking about — so you follow along on the real thing while you read.

Mentorly runs on your existing **Claude subscription** through the [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI, so there's **no API key and no per-token billing** — nothing extra to pay for beyond the plan you already have. It's built on an open-source, MIT-licensed foundation (see `LICENSE`), reworked to drop the original voice pipeline (AssemblyAI + ElevenLabs) in favor of typed questions and read answers.

## Highlights

- **No voice.** No microphone, no speech-to-text, no text-to-speech. You type your question into a small box; the answer streams in right there.
- **Points at the real UI, not a screenshot.** When you press Control+Z, Mentorly reads the frontmost app's macOS **Accessibility tree** to learn the exact on-screen location of every control. Claude names the controls it wants to point at, and the app draws labeled arrows on the live screen at those exact spots — so the arrows land on the real element instead of a guessed pixel. Several arrows (e.g. numbered how-to steps) can stay pinned at once while you read.
- **Control+Z instead of Control+Option**, since Control+Option is already used by other Claude tooling. (The macOS undo shortcut is Command+Z, so there's no conflict, and the shortcut is listen-only — it never swallows the keystroke.)
- **Beginner-friendly answers.** The system prompt is tuned to explain things in plain language rather than assume background knowledge.
- **No analytics, no email capture.** Mentorly ships with **no telemetry** — no analytics SDK, no question/answer logging, no email capture, nothing phoning home.
- **Free to run on your Claude subscription.** By default Mentorly answers by driving the local `claude` CLI, which signs in with your Claude plan — no Anthropic API key and no per-token charges. (A Cloudflare Worker + API key path is still there as an optional fallback.)

A blue cursor buddy adds a little personality: during onboarding it flies to something on your screen and makes a short, quirky remark so you can see the pointing in action.

## Setup (default — your Claude subscription, no API key)

### Prerequisites

- macOS 14.2+ (for ScreenCaptureKit)
- Xcode 15+
- The [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI, installed and signed in with your Claude subscription

### 1. Install and sign in to the Claude Code CLI

Install Claude Code, then sign in once with your Claude account:

```bash
claude              # launches Claude Code; sign in with your Claude subscription
claude -p "hello"   # confirm it answers without an API key
```

Mentorly looks for the `claude` binary in `~/.local/bin`, Homebrew, and `/usr/local/bin`, and falls back to your login-shell `PATH`. If it's installed somewhere unusual, point the app at it:

```bash
defaults write com.ilearn.app claudeCliPath "/full/path/to/claude"
```

### 2. Open in Xcode and run

That's it — no Worker, no key. The app shells out to the CLI, which uses your subscription. Pick your model in the menu-bar panel (Haiku for speed/cost, Sonnet for depth).

```bash
open ILearn.xcodeproj
```

In Xcode:
1. Select the `ILearn` scheme
2. Set your signing team under Signing & Capabilities
3. Hit **Cmd + R** to build and run

The app appears in your menu bar (not the dock). Click the icon to open the panel, grant the permissions it asks for, and you're good.

### Permissions the app needs

- **Accessibility** — for the global Control+Z shortcut **and** to read the on-screen positions of controls so the arrows land on the real UI (load-bearing for the core pointing feature)
- **Screen Recording** — for capturing the screen when you press the hotkey
- **Screen Content** — for ScreenCaptureKit access (onboarding demo)

## Optional: Cloudflare Worker + API key fallback

If you'd rather use a pay-as-you-go Anthropic API key (for example, to distribute to people who don't have a Claude subscription), switch the backend off the CLI:

```bash
defaults write com.ilearn.app useClaudeCodeBackend -bool false
```

Then set up the Worker, which holds your API key so it never ships in the app binary. The Worker is **authenticated with a shared token** and only forwards an allowlisted set of models with a capped output size, so a leaked URL can't be used to run up your Anthropic bill.

```bash
cd worker
npm install
npx wrangler secret put ANTHROPIC_API_KEY     # your Anthropic key
npx wrangler secret put PROXY_AUTH_TOKEN       # any long random string you choose
npx wrangler deploy                            # prints a https://…workers.dev URL
```

Point the app at that URL and give it the same auth token (both read from local UserDefaults, never committed):

```bash
defaults write com.ilearn.app workerBaseURL "https://your-worker-name.your-subdomain.workers.dev"
defaults write com.ilearn.app workerAuthToken "the-same-token-you-set-above"
```

For local Worker development, `npx wrangler dev` serves `http://localhost:8787`; put `ANTHROPIC_API_KEY=sk-ant-...` and `PROXY_AUTH_TOKEN=...` in `worker/.dev.vars` and set `workerBaseURL` to the localhost URL. To also enable per-client rate limiting, uncomment the `RATE_LIMITER` binding in `worker/wrangler.toml` and redeploy. Relaunch the app after changing any of these.

## Architecture

If you want the full technical breakdown, read `CLAUDE.md`. Short version: a menu-bar app with no dock icon. Control+Z captures a full screenshot of the current screen and scans the frontmost app's Accessibility tree for actionable controls (each with its exact on-screen frame), then opens a small non-activating box at the bottom-center of the screen. Your typed question plus the screenshot go to Claude via streaming; the explanation streams into the box while Claude names controls with `[POINT:…]` / `[STEP:n:…]` tags. The app resolves each named control to its real frame and draws a labeled arrow on the live screen. A separate blue cursor overlay handles the onboarding demo. By default the answer comes from the local `claude` CLI running on your Claude subscription (no API key); an optional authenticated Cloudflare Worker + API key path is available as a fallback.

## Project structure

```
ILearn/                  # Swift source
  CompanionManager.swift          # Central state machine (capture → ask → arrows)
  CompanionPanelView.swift        # Menu bar panel UI
  AskWindowManager.swift          # The bottom ask box: input + streamed answer
  AccessibilityElementLocator.swift  # Scans the AX tree into on-screen controls
  CompanionScreenCaptureUtility.swift  # Full-screen capture (ScreenCaptureKit)
  ClaudeCodeBackend.swift         # Default backend: drives the local `claude` CLI
  ClaudeAPI.swift                 # Fallback backend: authenticated Worker proxy
  OverlayWindow.swift             # Blue cursor overlay + live labeled-arrow canvas
  GlobalAskShortcutMonitor.swift  # Control+Z global shortcut
worker/                  # Cloudflare Worker proxy
  src/index.ts                    # One route: /chat (token-auth, model allowlist)
CLAUDE.md                # Full architecture doc (agents read this)
scripts/release.sh       # Sign + notarize + DMG + Sparkle appcast + GitHub release
```

## License

MIT licensed — see `LICENSE`.
