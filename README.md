# Summonbar

A Raycast-style launcher for macOS with coding agents built in. Press a hotkey, pick a project in `~/Workspaces`, type a task, and the agent's answer streams into the launcher. You can also open the agent in your terminal, or move an inline conversation into the terminal and keep going.

Supported agents (whichever are on your `PATH`): **Claude Code**, **Codex**, Gemini CLI, Cursor Agent, opencode, Aider.

## Install

```bash
./scripts/build-app.sh --install   # builds build/Summonbar.app → ~/Applications and launches it
```

Requires macOS 14+ and the Swift toolchain (the Xcode Command Line Tools are enough).

## Use

Default hotkey: **⌘⇧Space** (change it in the config).

| Where | Key | Action |
|---|---|---|
| Anywhere | ↑ ↓ | Move selection |
| | ↵ / ⌘↵ | Primary / secondary action (shown in the footer) |
| | ⌘K | More actions for the selected item |
| | esc, or ⌫ on an empty field | Back / hide |
| | ⌘R · ⌘, | Reload projects & config · edit config |
| Project | ↵ or Tab | Ask an agent in this project |
| | ⌘↵ | Open the default agent in the terminal |
| Root search | type anything | "Ask Claude Code: …" runs it in the project you used last |
| | `new my-app` | Create `~/Workspaces/my-app` (with `git init`) |
| | `new my-app: build a todo app` | Create it and pre-fill the prompt |
| | `new misoapps/foo` | Create it inside a group folder |
| Agent run | ↵ | Send a follow-up (resumes the same agent session) |
| | ⌘T | Continue this conversation in the terminal (`claude --resume` / `codex resume`) |
| | ⌘. | Stop the run |

Runs keep going after you hide the launcher; the menu bar icon shows how many are running. History is saved in `~/Library/Application Support/Summonbar/runs.json`.

Scripting:

```bash
open -a Summonbar --args --ask claude ~/Workspaces/foo "fix the failing test"
open -a Summonbar --args --query "new my-app"
```

These only work when Summonbar isn't already running.

## Config

`~/.config/summonbar/config.json` is created on first launch:

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
- After you edit the file, use **Reload Config & Hotkey** in the menu bar.

Projects are found by scanning `workspacesRoot`. If a top-level folder holds projects instead of being one (for example `~/Workspaces/misoapps/*`), its subfolders are listed as projects.

## Layout

```
Sources/Summonbar/
  App.swift            app delegate, menu bar item, launch args
  Panel.swift          floating non-activating panel, key routing
  HotKey.swift         global hotkey (Carbon)
  LauncherModel.swift  screens, items, navigation, actions
  Views.swift          SwiftUI UI
  AgentRun.swift       headless agent process + stream-json / JSONL parsing
  Agents.swift         agent catalog and command lines
  Projects.swift       workspace scanner, fuzzy match
  Terminal.swift       terminal / editor launching
  Shell.swift          login-shell environment capture (PATH from nvm etc.)
  Config.swift, Store.swift
```
