# Studio

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

**Studio MCP**: every Claude session Studio starts or resumes gets `--mcp-config` pointing at the bundled
`studio-mcp`, so its AI can drive the editor: `get_state`, `set_theme`, `set_font_size`, `new_session` (prompt, split),
`new_terminal` (command, split), `run_in_terminal` (plain terminals only), `split_tab`, `move_tab`, `focus_tab`,
`close_tab`, `open_palette`, `open_project`. The app listens on 127.0.0.1 only, with a random token in a 0600 file
(`~/Library/Application Support/Studio/control-<bundle id>.json`); sessions get `STUDIO_TAB` so the AI knows its tab.

Icon: `Resources/AppIcon.svg` → `scripts/make-icon.sh` regenerates `Resources/AppIcon.icns`.

## Build & run

    ./build-app.sh --open          # builds build/Studio.app (release) and opens it
    open build/Studio.app --args --new ~/code/foo      # start a session in a folder
    open build/Studio.app --args --resume <sessionId>  # resume a session

## Shortcuts

| Keys | Action |
|---|---|
| ⌘P | Go to session: search running and past sessions in every project (type `>` for commands) |
| ⇧⌘P | Command palette (incl. Preferences: Color Theme) |
| ⌘N | New Claude session in this window's folder |
| ⌃` | New terminal tab: your login shell in the folder, no Claude (closing it ends the shell) |
| ⇧⌘N | Open another project window |
| ⌘[ / ⌘] | Previous / next tab |
| ⌘1…⌘9 | Jump to tab |
| ⌘W | Close tab (session keeps running; click it in the sidebar to reopen) — closes the window if no tab is open |
| ⇧⌘W | Close window |
| ⌘+ / ⌘− / ⌘0 | Text size |

**Split panes** (like VS Code editor groups): drag a tab (or an in-app session from the sidebar) onto a pane —
the outer third of each side splits that way, the middle drops it in as a tab; a shaded preview shows where it'll land.
Right-click a tab for Split Right / Left / Down / Up (a group's only tab splits off a fresh session instead).
Drag the 1px dividers to resize. ⌘N, ⌘W, ⌘[ / ⌘] act on the focused group; clicking a pane focuses it.

Themes (via the palette): Clear Dark, Dark Modern, Dark+, Light+, Monokai, Solarized Dark, One Dark Pro, GitHub Dark, Dracula.
Each session tab has a status bar: git branch, uptime, model, tokens sent ↑ / received ↓, and its PRs.

**PR detection** (needs the `gh` CLI, logged in): PRs a session created are found from `gh pr create` output in its
transcript; otherwise the session's branch is looked up (long-lived branches like main/staging are skipped). State
(open/draft/merged/closed), CI checks and review are refreshed every minute. Set `STUDIO_DEBUG_LOG=/path` to trace lookups.

Built with SwiftUI + [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm).
