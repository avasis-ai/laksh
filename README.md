# Laksh

[![License: MIT](https://img.shields.io/badge/license-MIT-ede8df.svg)](LICENSE)
[![Open source](https://img.shields.io/badge/open-source-MIT-7fb069.svg)](https://github.com/avasis-ai/laksh)

A native macOS app for controlling multiple CLI coding agents side-by-side — a minimal, local-first SwiftUI workspace.

Instead of a server + web dashboard + daemon, Laksh is a single Mac app that discovers agent CLIs on your `PATH` and spawns each one in a real PTY. No accounts, no backend, no database.

**Repository:** [github.com/avasis-ai/laksh](https://github.com/avasis-ai/laksh)  
**Marketing site:** static files in [`website/`](website/) (Claude-design document IA + tokens).  
**Promo media:** `python3 -m venv .venv && .venv/bin/pip install pillow` once, then  
`.venv/bin/python scripts/render-website-promo.py` (**ffmpeg** on PATH) refreshes `website/media/laksh-promo.{gif,mp4,png}`.

**Live site (after you enable Pages / connect Vercel):**

- **GitHub Pages:** [https://avasis-ai.github.io/laksh/](https://avasis-ai.github.io/laksh/) — enable *Settings → Pages → Source: GitHub Actions*, then push `main` (see [`.github/workflows/pages.yml`](.github/workflows/pages.yml)). Includes `website/.nojekyll` so assets are not processed by Jekyll.
- **Vercel:** import this repo; `vercel.json` sets `outputDirectory` to `website` (no build). Or set **Root Directory** to `website` in the Vercel project UI.

## What it does today (v0.1)

- Auto-detects installed agent CLIs on your interactive shell's `PATH`:
  Claude Code, Codex, Cursor Agent, OpenCode, OpenClaw, Gemini, Hermes, Pi, Aider, plus plain `zsh`.
- Spawn any number of agent sessions concurrently, each in its own pseudo-terminal.
- Three-pane UI: sidebar of agents + sessions → tab bar → terminal pane.
- **New Task** sheet (`⌘T`): pick agent, pick working directory, optional initial prompt that gets typed into the PTY after the agent boots.
- Real terminal emulation via [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (xterm/VT100, 256 color, truecolor). The same library approach Ghostty uses for its macOS UI — native AppKit/SwiftUI wrapping a Metal-accelerated cell renderer.

## Requirements

- macOS 13+
- Xcode command-line tools / Swift 5.9+
- At least one supported agent installed and on PATH (`claude`, `codex`, `opencode`, etc.)

## Build & run

```bash
# Debug run (opens window immediately)
swift run

# Build a release .app bundle
./scripts/build-app.sh release
open build/Laksh.app
```

## Architecture

```
Sources/Laksh
├── LakshApp.swift           SwiftUI @main, commands, key bindings
├── Model
│   ├── Agent.swift          Known agent registry (id, command, color)
│   ├── AgentSession.swift   One PTY session, owns a LocalProcessTerminalView
│   └── SessionStore.swift   @MainActor ObservableObject; sessions + sheet state
├── Agents
│   └── AgentDetector.swift  Scans PATH (+ login shell PATH + common bin dirs)
└── Views
    ├── RootView.swift       HSplit: Sidebar | TabBar + TerminalPane
    ├── Sidebar.swift        Agent list + session list + New Task button
    ├── TerminalPane.swift   NSViewRepresentable around LocalProcessTerminalView
    └── NewTaskSheet.swift   Spawn-a-session form
```

Each `AgentSession` owns its own `LocalProcessTerminalView` as a long-lived NSView, so tab switching doesn't tear down the PTY.

## Why SwiftTerm and not libghostty?

Ghostty's `libghostty` is the gold standard for terminal performance on macOS, but it requires a Zig toolchain and an unstable C-ABI bridge. SwiftTerm (by Miguel de Icaza) is a pure-Swift xterm/VT100 emulator with a Metal-accelerated renderer whose design was explicitly [inspired by Ghostty's GPU engine](https://github.com/migueldeicaza/SwiftTerm/commit/3c45fdcfcf4395c72d2a4ee23c0bce79017b5391). One SwiftPM dependency, zero build-system pain. We can revisit libghostty when it stabilizes.

## Roadmap — the "upgrade to something new" part

Ideas queued for v0.2+ once the MVP is comfortable:

- **Agent-native workspaces**: a session is bound to a repo; Laksh holds a local SQLite store of issues/tasks. Drag an issue onto an agent to spawn a scoped run.
- **Session recording**: every PTY session's transcript is persisted and replayable.
- **Skill library**: pin a prompt + target-agent + target-dir as a reusable "skill", one-click re-run.
- **Cross-agent comparison**: fire the same prompt at Claude, Codex, and OpenCode simultaneously in a 3-pane split; diff the outputs.
- **Menu-bar quick-launcher**: `⌘⇧Space`-style panel to spawn an agent anywhere.
- **Hooks into macOS**: Quick Look transcripts, Spotlight-indexed sessions, Shortcuts actions.
