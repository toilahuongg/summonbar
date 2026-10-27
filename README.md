<p align="center">
  <img src="assets/logo.png" width="128" height="128" alt="Summonbar icon">
</p>

<h1 align="center">Summonbar</h1>

<p align="center">
  <b>A Raycast-style launcher for macOS with coding agents built in.</b><br>
  Press a hotkey, pick a project, type a task. Claude Code, Codex and others answer right inside the bar.
</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple">
  <img alt="Swift 5.10" src="https://img.shields.io/badge/Swift-5.10-F05138?logo=swift&logoColor=white">
  <img alt="No dependencies" src="https://img.shields.io/badge/dependencies-none-6E56CF">
</p>

<p align="center">
  <img src="assets/screenshots/agent-run.png" width="760" alt="A Claude Code run streaming inside Summonbar">
</p>

## Why

Coding agents live in terminals. That's great for long sessions, but most tasks are short: "add a flag", "why is this test failing", "scaffold a new app". Summonbar gets you from that thought to a running agent in the right folder in about two keystrokes, and lets you leave it running in the background.

- **Every project, one keystroke away.** Summonbar scans `~/Workspaces` (including group folders like `~/Workspaces/acme/*`) and ranks projects by what you used last.
- **Inline agent runs.** The answer streams into the launcher, with tool calls, file edits, command output and cost. Press ↵ to send a follow-up in the same session.
- **Hand off to the terminal.** ⌘T moves an inline conversation into your terminal (`claude --resume`, `codex resume`). ⌘↵ on a project opens the agent there right away.
- **New projects in one line.** `new my-app: build a todo app` creates `~/Workspaces/my-app`, runs `git init`, and pre-fills the prompt.
- **Background runs.** Hide the launcher and keep working. The menu bar shows how many agents are running.
- **Extensions.** Drop in shell scripts; Raycast Script Commands work as-is.
- **Native and small.** Swift + AppKit/SwiftUI, no Electron and no dependencies. It doesn't need Accessibility permission.

<p align="center">
  <img src="assets/screenshots/search.png" width="760" alt="Searching projects and asking an agent">
</p>

## Supported agents

Summonbar uses whichever of these are on your `PATH`, with the same login-shell environment your terminal has (nvm, `~/.local/bin`, …):

| Agent | Inline runs | Open in terminal | Resume |
|---|---|---|---|
| [Claude Code](https://docs.claude.com/en/docs/claude-code) | ✅ streamed | ✅ | ✅ |
| [Codex CLI](https://github.com/openai/codex) | ✅ streamed | ✅ | ✅ |
| Gemini CLI, Cursor Agent, opencode, Aider | plain output | ✅ | — |

## Install

Requires macOS 14+ and a Swift toolchain. The Xcode Command Line Tools are enough; you don't need full Xcode.

```bash
git clone https://github.com/toilahuongg/summonbar.git
cd summonbar
./scripts/build-app.sh --install   # builds Summonbar.app, copies it to ~/Applications and launches it
```

## Use

Default hotkey: **⇧⌘Space** (change it in Settings).

| Where | Key | Action |
|---|---|---|
| Anywhere | ↑ ↓ | Move selection |
| | ↵ / ⌘↵ | Primary / secondary action (shown in the footer) |
| | ⌘K | More actions for the selected item |
| | esc, or ⌫ on an empty field | Back / hide |
| | ⌘R · ⌘, | Reload projects & config · Settings |
| Project | ↵ or Tab | Ask an agent in this project |
| | ⌘↵ | Open the default agent in the terminal |
| Root search | type anything | "Ask Claude Code: …" runs it in the project you used last |
| | `new my-app` | Create `~/Workspaces/my-app` (with `git init`) |
| | `new my-app: build a todo app` | Create it and pre-fill the prompt |
| | `new acme/foo` | Create it inside a group folder |
| Agent run | ↵ | Send a follow-up (resumes the same agent session) |
| | ⌘T | Continue this conversation in the terminal (`claude --resume` / `codex resume`) |
| | ⌘. | Stop the run |

Run history is saved in `~/Library/Application Support/Summonbar/runs.json`.

### Scripting

```bash
open -a Summonbar --args --ask claude ~/Workspaces/foo "fix the failing test"
open -a Summonbar --args --query "new my-app"
open -a Summonbar --args --settings
```

These only work when Summonbar isn't already running.

## Settings

Open **Settings** with ⌘, in the launcher or from the menu bar. It covers:
- the hotkey (click and press a new shortcut)
- launch at login
- the workspaces folder
- terminal and editor
- the default agent
- per-agent arguments

Changes save to the config file and apply right away.

The file itself, `~/.config/summonbar/config.json`, is created on first launch:

```json
{
  "workspacesRoot": "~/Workspaces",
  "hotkey": "cmd+shift+space",
  "terminal": "ghostty",
  "editor": "Visual Studio Code",
  "defaultAgent": "claude",
  "gitInitNewProjects": true,
  "agents": {
    "claude": { "args": [], "headlessArgs": ["--permission-mode", "acceptEdits"] },
    "codex":  { "args": [], "headlessArgs": ["--sandbox", "workspace-write"] }
  }
}
```

- `terminal`: `ghostty`, `terminal`, `iterm`, or any app name that can open `.command` files.
- `headlessArgs` apply to inline runs. By default Claude Code can edit files but asks before running anything else, and Codex is sandboxed to the workspace. Set `"disabled": true` on an agent to hide it.
- `extensionDirectories` (optional): extra folders to load extensions from, e.g. a clone of [raycast/script-commands](https://github.com/raycast/script-commands).
- After you edit the file by hand, use **Reload Config & Hotkey** in the menu bar.

Projects are found by scanning `workspacesRoot`. If a top-level folder holds projects instead of being one (for example `~/Workspaces/acme/*`), its subfolders are listed as projects.

## Extensions

An extension is a script in `~/.config/summonbar/extensions/` (any language, with a shebang) whose header comments describe it. A few examples are created on first launch. Raycast Script Commands work as-is: `@raycast.*` keys are read too, and `@summonbar.*` keys win when both are present.

```bash
#!/bin/bash
# @summonbar.title Search GitHub
# @summonbar.mode silent
# @summonbar.icon 🔎
# @summonbar.argument1 { "type": "text", "placeholder": "Query", "percentEncoded": true }

open "https://github.com/search?q=$1"
```

| Key | Values |
|---|---|
| `title` | Required. Name in the list |
| `mode` | `fullOutput` (default, streams output into the launcher), `compact` (last line in the footer), `silent` (hide and run), `inline` (last line becomes the subtitle; re-runs every `refreshTime`), `terminal` (run interactively in your terminal), `agent` (send the script's output as a prompt to a coding agent) |
| `scope` | `project`: runs inside a project and shows in its ⌘K actions and prompt screen. Otherwise it's global and listed on the root screen |
| `argument1`…`argument3` | JSON: `type` (`text`, `password`, `dropdown` with `data: [{"title","value"}]`), `placeholder`, `optional`, `percentEncoded`. Asked for one at a time |
| `icon` | SF Symbol name, emoji, or an image path relative to the script |
| `description`, `packageName` | Subtitle and accessory |
| `needsConfirmation` | `true` asks before running |
| `currentDirectoryPath` | Working directory for global extensions (default: the script's folder) |
| `refreshTime` | For `inline`: `10s`, `5m`, `1h`, `1d` |
| `agent` | For `agent`: agent id such as `codex` (default: `defaultAgent`) |

Scripts get these environment variables:
- `SUMMONBAR_PROJECT_DIR` and `SUMMONBAR_PROJECT_NAME`: the project it ran on, or for global extensions the one you used last.
- `SUMMONBAR_WORKSPACES`.

Keys on an extension:
- ⌘↵ edits the script, and ⌘K offers running it in the terminal.
- In `fullOutput` mode, ↵ runs it again, ⌘↵ copies the output and ⌘. stops it.
- ⌘R picks up new or changed scripts.

## How it works

- **The panel** is a borderless, non-activating `NSPanel`. It takes keyboard focus without pulling your editor out of the foreground, the same way Spotlight does. Keys are routed in `sendEvent`, and input methods such as Vietnamese Telex can finish composing before ↵ or esc are handled.
- **The hotkey** uses Carbon's `RegisterEventHotKey`, so no Accessibility permission is needed.
- **Inline runs** start the agent headless and parse its event stream:
  - Claude Code: `claude -p --output-format stream-json`.
  - Codex: `codex exec --json`.
  - The session id is kept so follow-ups and ⌘T resume the same conversation.
- **Environment:** on launch Summonbar reads your login shell's environment once, so agents installed through nvm, Homebrew or `~/.local/bin` are found just as they are in your terminal.

## Development

```bash
swift build                       # debug build
./scripts/build-app.sh            # release .app in build/
./scripts/make-icon.sh            # re-render Resources/AppIcon.icns from assets/logo.svg (needs Google Chrome)
```

```
Sources/Summonbar/
  App.swift            app delegate, menu bar item, launch args
  Panel.swift          floating non-activating panel, key routing
  HotKey.swift         global hotkey (Carbon)
  LauncherModel.swift  screens, items, navigation, actions
  Views.swift          SwiftUI UI
  Settings.swift       Settings window (General, Agents)
  AgentRun.swift       headless agent process + stream-json / JSONL parsing
  Extensions.swift     script extensions: metadata parsing, catalog, runs
  Agents.swift         agent catalog and command lines
  Projects.swift       workspace scanner, fuzzy match
  Terminal.swift       terminal / editor launching
  Shell.swift          login-shell environment capture (PATH from nvm etc.)
  Config.swift, Store.swift
assets/                logo (SVG source + PNG) and README screenshots
```
