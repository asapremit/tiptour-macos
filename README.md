# TipTour

**Ask your Mac how to do anything. Watch the cursor do it.**

TipTour is a macOS menu bar companion that teaches you software by voice. Hold a hotkey, ask "how do I render an animation in Blender?" — it hears you, sees your screen, and a cursor flies across it to the exact button you need to click. Then the next one. Then the one after that.

Works across every Mac app: Xcode, Blender, Figma, VS Code, GarageBand, browsers. Built on top of [Clicky](https://github.com/farzaa/clicky) by [@FarzaTV](https://x.com/farzatv).

---

## How it works

1. **Hold Control + Option** and speak naturally. "Where's the File menu?" / "How do I create a new file?" / "Walk me through exporting this."
2. **Google Gemini Live** (single streaming WebSocket) handles voice-in, screen-vision, voice-out, and tool calling in one model. No STT→LLM→TTS pipeline to orchestrate.
3. **Cursor flies to the exact UI element.** Under the hood, element resolution cascades:
   - **macOS Accessibility tree** — pixel-perfect, ~30ms. Works on native Mac apps, SwiftUI/AppKit, most Electron apps.
   - **On-device CoreML YOLO + Apple Vision OCR** — fallback for apps that render their own UI (Blender, Unity, games, canvas tools).
   - **Raw LLM coordinates** — absolute last resort.
4. **Multi-step workflows auto-advance.** Ask "how do I create a new file" and Gemini emits a structured plan. The cursor flies to step 1, waits for you to click it, then advances to step 2, narrating along the way. A global `CGEventTap` watches for your click — when it lands inside the resolved element, the checklist ticks forward.
5. **Neko mode (optional).** Toggle the blue triangle cursor for a pixel-art cat that runs across your screen in 8 directional sprites, leaves paw-print footprints, and falls asleep when idle. Because learning shouldn't be boring.

---

## Install

Coming soon — a signed + notarized DMG will be the primary distribution path.

Until then, clone and build from source (see [Building from source](#building-from-source) below).

---

## Permissions

TipTour asks for four macOS permissions on first run. All screen and microphone access is strictly user-initiated (only while you're holding the hotkey); nothing runs in the background:

- **Microphone** — voice input while you hold Control + Option
- **Accessibility** — global keyboard shortcut + reading the UI element tree of the app you're pointing at
- **Screen Recording** — screenshots for Gemini's visual context (captured on hotkey press, never continuously)
- **Screen Content** — needed on macOS 15+ for ScreenCaptureKit

---

## Building from source

**Prerequisites:**
- macOS 14+
- Xcode 16+
- Node.js 20+ (for the Cloudflare Worker API proxy)
- Apple Developer account (only if you want to notarize for distribution)

### 1. Set up the Cloudflare Worker

All API keys live on a Cloudflare Worker proxy — nothing sensitive ships in the app.

```bash
cd worker
npm install
```

Create `worker/.dev.vars` (gitignored):
```
GEMINI_API_KEY=your-google-ai-studio-key
ELEVENLABS_API_KEY=your-elevenlabs-key       # optional, only for legacy Claude mode
ELEVENLABS_VOICE_ID=your-voice-id            # optional
ANTHROPIC_API_KEY=your-anthropic-key         # optional, only for legacy Claude mode
OPENROUTER_API_KEY=your-openrouter-key       # optional, tutorial pointing fallback
```

Run locally:
```bash
npx wrangler dev
```

Deploy to your own account:
```bash
npx wrangler secret put GEMINI_API_KEY
npx wrangler deploy
```

### 2. Build the app

```bash
open TipTour.xcodeproj
```

In Xcode: set your signing team (Target → Signing & Capabilities), then Cmd+R.

The app runs as a menu bar-only app (no dock icon, no main window). Look for the TipTour icon in your menu bar.

---

## Architecture

```
User presses Control + Option
  → Gemini Live WebSocket opens (voice + vision)
  → User speaks; Gemini hears streaming PCM16 audio
  → Periodic screenshots stream over the same WebSocket
  → Gemini picks one of two tools:
      point_at_element(label)                — single-click ask
      submit_workflow_plan(goal, app, steps) — multi-step walkthrough
  → ElementResolver turns each label into pixel coords via:
      (1) macOS Accessibility tree (instant, pixel-perfect for native apps)
      (2) on-device CoreML YOLO + Apple Vision OCR (Blender, games, canvas)
      (3) raw LLM coordinates (last resort)
  → Cursor flies along a bezier arc to the target
  → ClickDetector (global CGEventTap) arms on the resolved element
  → User clicks → auto-advance to the next step
  → Gemini narrates the full plan in one natural turn
```

Key technical choices worth calling out:

- **Single-model architecture.** One Gemini Live WebSocket handles voice-in, vision, voice-out, and tool calling. No STT→LLM→TTS pipeline; no separate planner model. Cuts latency and eliminates state-sync bugs between components.
- **Grounding is deterministic, not LLM-guessed.** The LLM emits semantic labels ("File", "New", "Save"). Swift code does the pixel-to-label grounding on-device via AX tree + YOLO + OCR. Gemini is never asked to output raw coordinates (except as a last-resort fallback) — it's slow and imprecise at that.
- **On-device CoreML YOLO + Apple Vision OCR** for apps without accessibility support (Blender, games, canvas tools). No external detection server, no Python dependency.
- **Auto-adaptive AX-empty-tree cache.** When an app (e.g. Blender) returns zero AX children, we flag it and skip AX polling for 10 minutes — straight to YOLO. Saves ~2.7s per step and keeps Core Audio fed so Gemini's voice stays smooth.

See [AGENTS.md](AGENTS.md) for a deeper technical tour.

---

## Roadmap

- **YouTube tutorial follow-along** — paste a YouTube URL, the video plays picture-in-picture, and at each instructor action the cursor flies to the corresponding button in your real app. Infrastructure is built (WorkflowRunner, ClickDetector, ElementResolver); needs URL parsing, transcript extraction, and a PiP video player.
- **Distribution** — signed + notarized DMG + Sparkle auto-updates.
- **Step resolution telemetry** — anonymized success/failure rates per app to guide where to improve grounding.

---

## Contributing

PRs welcome. Before opening one:
1. Open `TipTour.xcodeproj` in Xcode, verify it builds.
2. Check that any new permission requests have matching `NS*UsageDescription` keys in `Info.plist`.
3. Run the app end-to-end once to make sure your change doesn't break the push-to-talk flow.

For non-trivial changes, open an issue first to discuss direction.

See [AGENTS.md](AGENTS.md) for code style, file organization, and architectural conventions.

---

## Credits

- [Clicky](https://github.com/farzaa/clicky) by [@FarzaTV](https://x.com/farzatv) — the open-source foundation TipTour forks from.
- [Gemini Live](https://ai.google.dev/gemini-api/docs/live-api) (Google) — realtime voice, vision, and tool calling in one model.
- [oneko](https://github.com/crgimenes/neko) (Masayuki Koba 1989, BSD-2 port by Cesar Gimenes) — pixel-art cat sprites used in Neko mode.
- Apple's macOS Accessibility APIs, ScreenCaptureKit, CoreML, and the Vision framework.

---

## License

[MIT](LICENSE). Use it, fork it, ship your own version — just keep the copyright notice.
