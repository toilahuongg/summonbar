# Contributing to Summonbar

Thanks for wanting to help. Bug reports, fixes, new agent integrations, extensions and docs are all welcome.

## Before you start

- **Small fixes** (typos, obvious bugs, docs): open a pull request directly.
- **Bigger changes** (a new feature, a new screen, a new agent, anything that changes key bindings or the config format): open an issue first so we can agree on the approach before you spend time on it.
- Check the [open issues](https://github.com/toilahuongg/summonbar/issues) to avoid duplicate work. Issues labelled `good first issue` are a good place to start.

## Set up

You need macOS 14+ and a Swift 5.10 toolchain. The Xcode Command Line Tools are enough.

```bash
git clone https://github.com/<you>/summonbar.git
cd summonbar
swift build                         # debug build
./scripts/build-app.sh --install    # release .app, installed to ~/Applications and launched
```

The global hotkey and the non-activating panel only behave properly inside the `.app` bundle, so test UI changes with `./scripts/build-app.sh --install` rather than `swift run`. The README's **Development** section has a map of the source files.

Your real config lives in `~/.config/summonbar/config.json` and run history in `~/Library/Application Support/Summonbar/runs.json`. Back them up if you're testing changes to how they're read or written.

## Guidelines

- **No dependencies.** Summonbar is plain Swift + AppKit/SwiftUI on purpose. Please don't add Swift packages; if you think one is really needed, raise it in an issue first.
- **No Accessibility permission.** Features must work without it (that's why the hotkey uses Carbon and the panel routes its own keys). The one exception is pasting from Clipboard History, which falls back to copying when the permission is missing.
- **Match the surrounding code.** Same naming, same comment density, same file layout. Put new code in the file that already owns that area; add a new file only for a new area, and list it in the README's source map.
- **Keyboard first.** Every new action needs a key path, should show in the footer or ⌘K, and must not break input methods (Vietnamese Telex, Japanese IME, …) that compose text before ↵ / esc.
- **Keep the README in sync.** If you add a key binding, config key, command or agent, update the matching table or section in the README in the same pull request.
- **Privacy.** Anything that sends user text off the machine (like Translate) must be opt-in or clearly documented.

## Adding an agent

Agents are defined in `Sources/Summonbar/Agents.swift`. A new agent needs at least a command line for opening it in the terminal. For streamed inline runs it also needs a headless mode with a machine-readable event stream, parsed in `AgentRun.swift`. Add a row to the **Supported agents** table in the README.

## Pull requests

1. Fork, then branch from `main` (`fix/…`, `feat/…`).
2. Keep each PR to one change. Unrelated cleanups go in their own PR.
3. Make sure `swift build -c release` passes with no new warnings. CI runs it on every PR.
4. Describe what changed and how you tested it. For UI changes, add a screenshot or a short screen recording.
5. Write commit messages in the imperative, describing the user-visible effect: "Scroll results back to the top when the search changes", not "fix scroll".

By contributing you agree that your work is released under the [MIT License](LICENSE).

## Reporting bugs

Use the [bug report template](https://github.com/toilahuongg/summonbar/issues/new/choose). Include your macOS version, how you installed Summonbar, which agent and version you used, and the steps to reproduce. Strip anything private (paths, prompts, tokens) from logs and config before pasting them.

For security issues, see [SECURITY.md](SECURITY.md) instead of opening a public issue.

## Code of conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md). Be kind and assume good intent.
