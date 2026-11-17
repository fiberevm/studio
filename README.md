# AICode

A native macOS app for working with many Claude Code sessions at once, laid out like VS Code:
a session sidebar on the left and the selected session's live terminal on the right.

- **One window per project folder**; the sidebar lists sessions running in that folder (and its worktrees).
- **Sessions**: every running `claude` process (read from `~/.claude/sessions/<pid>.json`),
  with live status (Working / Idle / Shell / Needs input), plus terminals opened in the app.
  Sessions running elsewhere are tagged `terminal` / `desktop`.
- **History**: every transcript in `~/.claude/projects`, grouped by project. Double-click (or Return) to
  `claude --resume` it in an embedded terminal.
- Terminals stay alive while you switch between them. When a session finishes working while you're looking
  elsewhere, it gets a blue dot, a Dock badge, and a notification.

## Build & run

    ./build-app.sh --open          # builds build/AICode.app (release) and opens it
    open build/AICode.app --args --new ~/code/foo      # start a session in a folder
    open build/AICode.app --args --resume <sessionId>  # resume a session

## Shortcuts

| Keys | Action |
|---|---|
| ⌘N | New Claude session in this window's folder |
| ⇧⌘N | Open another project window |
| ⌘[ / ⌘] | Previous / next tab |
| ⌘1…⌘9 | Jump to tab |
| ⌘W | Close tab (session keeps running; click it in the sidebar to reopen) — closes the window if no tab is open |
| ⇧⌘W | Close window |
| ⌘+ / ⌘− / ⌘0 | Text size |

Built with SwiftUI + [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm).
