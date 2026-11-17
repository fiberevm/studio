# AICode

A native macOS app for working with many Claude Code sessions at once, laid out like VS Code:
a session sidebar on the left and the selected session's live terminal on the right.

- **Active**: every running `claude` process on this machine (read from `~/.claude/sessions/<pid>.json`),
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
| ⌘N / ⇧⌘N | New session (pick folder) / in same folder |
| ⌘1…⌘9 | Jump to active session |
| ⇧⌘[ / ⇧⌘] | Previous / next active session |
| ⇧⌘R | Resume selected |
| ⌥⌘W | Close terminal |

Built with SwiftUI + [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm).
