<div align="center">

<img src="Resources/AppIcon.svg" width="128" height="128" alt="Studio icon">

# Studio

**A native macOS workspace for running many Claude Code sessions at once.**

Tabs, split panes and a command palette, like VS Code, except every pane is a live Claude Code session or terminal.
Studio tells you which session needs you next, so you can keep six agents busy without losing your place.

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)](#install)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](Package.swift)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![Built with SwiftTerm](https://img.shields.io/badge/terminal-SwiftTerm-555)](https://github.com/migueldeicaza/SwiftTerm)

[Features](#features) · [Install](#install) · [Shortcuts](#keyboard-shortcuts) · [Studio MCP](#studio-mcp) · [How it works](#how-it-works) · [Contributing](#contributing)

<img src="docs/screenshot.png" alt="Studio: two Claude Code sessions side by side and a terminal, in split panes" width="900">

</div>

---

## Why Studio?

Running several Claude Code sessions in parallel is powerful but noisy: terminal windows pile up, you forget which
agent is waiting on a permission prompt, and every check-in means scanning tabs and scrolling back to see what
happened. Studio is built around one idea: **you should only look at a session when it needs you.**

- **One window per project.** Open `~/code/api` and `~/code/web` side by side; each window holds that repo's sessions and worktrees.
- **Know who's waiting.** Tabs show a working indicator, a pulsing red dot when Claude is blocked on you, and an unread dot when it finished while you were elsewhere.
- **Jump, don't scan.** <kbd>⌘J</kbd> takes you to the session that has waited longest; press it again for the next one. It's inbox zero for agents.
- **Talk without switching.** <kbd>⌘K</kbd> sends a message to any session, or to several at once, without leaving the pane you're in.

## Features

### Sessions
- **Embedded Claude Code** in real terminals ([SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)): it's the real `claude` CLI, so slash commands, hooks, MCP servers and settings all work unchanged.
- **Imports what's already running.** Studio reads Claude Code's own session files, so sessions started in other terminals show up too.
- **Closing a tab never loses a conversation.** It ends the session; <kbd>⌘P</kbd> resumes it any time, right where it left off.
- **Restores your workspace.** Tabs, splits, pane sizes and terminal tabs come back after a restart (Claude sessions are resumed with `claude --resume`).
- **Plain terminals** with <kbd>⌃`</kbd>, next to your sessions, just like VS Code.
- **Drag and drop** files or images onto a session to paste their paths.

### Productivity features

Everything here is about one thing: spending your attention only where a session needs it.

| | Feature | What it does for you |
|---|---|---|
| ⏭ | **Next up** <kbd>⌘J</kbd> | Jumps to the session that has waited longest for you. Sessions blocked on a permission prompt or question come first, across every project window. Press it again for the next one; you'll see *All caught up* when the queue is empty. |
| 👀 | **Hover peek** | Rest on a tab for half a second to see the session's status, how long it's been in that state, Claude's last message and your last prompt, without switching to it. |
| 🔴 | **Needs-you badge** | A pulsing red dot means Claude is blocked on you (permission, question). A blue dot means it finished while you were looking elsewhere. A walking pane-grid means it's working. Idle sessions stay quiet. |
| 💬 | **Quick prompt** <kbd>⌘K</kbd> | Type a message and send it to any session without leaving the pane you're in. ↑↓ picks the session; the current one is first. |
| 📣 | **Broadcast** | In <kbd>⌘K</kbd>, press <kbd>⇥</kbd> to tick several sessions and send them all the same message (*"rebase on main"*, *"run the tests"*). |
| 🖋 | **Native view** <kbd>⌘/</kbd> | Swap any session from Claude Code's terminal UI to Studio's own rendering (`claude -p` streaming JSON), styled after T3 Code: your messages as bubbles, Claude's answer full width with real markdown (headings, lists, code blocks), and the tool calls folded into a work log that collapses to *Worked for 14s · 6 steps* once the answer is in. Approvals sit inline with **Decline / Approve**; a rounded composer shows the model, a permission-mode picker (Supervised, Auto-accept edits, Plan, Full access), elapsed time, and Send that turns into Stop. Same conversation, one process, same permission mode as the terminal; remembered per session. |
| 🍴 | **Fork** <kbd>⌘E</kbd> | Copy the current conversation into a new session in a split beside it, then take it a different direction. The original keeps going untouched. Also in the tab right-click menu (right or below). |
| ✨ | **Start from a prompt** | <kbd>⌘↵</kbd> in <kbd>⌘K</kbd> starts a new session with your message already sent. |
| 🧩 | **Snippets** | Reusable prompts: type `#` in <kbd>⌘K</kbd> (`#tests`, `#review`, `#pr`, `#rebase`, `#summary`, `#continue`), pick one in <kbd>⌘P</kbd> to send it to the current session, or press <kbd>⌘S</kbd> to save what you typed. Stored as plain JSON you can edit. |
| 🔔 | **Notifications that matter** | Only while you're in another app, only when a session is blocked on you or finished 30+ seconds of work, never for the one you're watching. Each shows Claude's last words; clicking it opens the session. |
| 🔍 | **Go to anything** <kbd>⌘P</kbd> | Fuzzy-search every running and past session in every project, plus all commands. Picking a session in another project opens that project's window. |
| 🧷 | **Nothing is ever lost** | Closing a tab ends the session, but the conversation is one <kbd>⌘P</kbd> away and resumes where it left off. Right-click → *Close Tab, Keep Session Running* to leave it working in the background. Emptied panes stay put with a quiet *New Session* action. |
| 💾 | **Layout survives restarts** | Tabs, splits, pane sizes and terminal tabs come back exactly where they were; Claude sessions are resumed with `claude --resume`. |
| 🌿 | **Context at a glance** | Each session's status bar shows its git branch, model and tokens in/out, and Studio finds the PR it opened, with CI and review state. |
| 🖼 | **Drop to paste** | Drag files or screenshots onto a session to paste their paths into the prompt. |
| 🤖 | **Agents drive the editor** | Through the Studio MCP, Claude can open splits, start helper sessions, run commands in a terminal next to it, and rearrange your layout. |

### Workspace
- **Split panes** with drag-to-snap: drop a tab on any edge of a pane to split it, or right-click for Split Right / Left / Up / Down.
- **Command palette** (<kbd>⌘P</kbd> / <kbd>⇧⌘P</kbd>): fuzzy-search running and past sessions in every project, plus every command.
- **Themes** with live preview: Clear Dark, Dark Modern, Dark+, Light+, Monokai, Solarized Dark, One Dark Pro, GitHub Dark, Dracula.
- **Status bar per session:** git branch, model, and tokens in/out.
- **PR detection:** finds the PR each session opened (or its branch's PR) through the `gh` CLI, with state, CI checks and review status.

### Built for agents, too
- **Studio MCP:** every session Studio starts can drive the editor itself: open splits, start sessions, run commands in terminals, rearrange the layout, change themes. [See the tools ↓](#studio-mcp)

## Install

Requirements: **macOS 14+**, **Xcode 16+ / Swift 6 toolchain**, and [Claude Code](https://docs.claude.com/en/docs/claude-code) installed and logged in. The [`gh` CLI](https://cli.github.com) is optional, for PR detection.

```bash
git clone https://github.com/fiberevm/studio.git
cd studio
./build-app.sh --open      # builds build/Studio.app (release) and launches it
```

Copy `build/Studio.app` to `/Applications` if you like. It's signed ad hoc for local use.

Launch options:

```bash
open build/Studio.app --args --new ~/code/my-project      # open a project with a new session
open build/Studio.app --args --resume <session-id>        # resume a specific session
```

## Keyboard shortcuts

| Keys | Action |
|---|---|
| <kbd>⌘P</kbd> | Go to session: search running and past sessions in every project (type `>` for commands) |
| <kbd>⇧⌘P</kbd> | Command palette, including Color Theme |
| <kbd>⌘J</kbd> | Next up: the session that has waited longest for you |
| <kbd>⌘K</kbd> | Quick prompt: message any session (or several) without switching |
| <kbd>⌘E</kbd> | Fork the current session into a new pane to the right |
| <kbd>⌘/</kbd> | Toggle native view (Studio renders the session) / terminal view |
| <kbd>⌘T</kbd> or <kbd>⌘N</kbd> | New tab with a Claude session in this project |
| <kbd>⌃`</kbd> | New terminal tab |
| <kbd>⇧⌘N</kbd> | Open another project window |
| <kbd>⌘[</kbd> / <kbd>⌘]</kbd> | Previous / next tab |
| <kbd>⌘1</kbd>…<kbd>⌘9</kbd> | Jump to tab |
| <kbd>⌘W</kbd> | Close tab and end its session (resume it any time from <kbd>⌘P</kbd>); in an empty pane, close the pane |
| <kbd>⇧⌘W</kbd> | Close window |
| <kbd>⌘B</kbd> | Toggle the session sidebar |
| <kbd>⌘+</kbd> / <kbd>⌘−</kbd> / <kbd>⌘0</kbd> | Text size |

## Studio MCP

Every Claude session Studio starts or resumes is launched with an MCP server, `studio-mcp`, that talks to the app.
That lets the agent in any pane drive the editor. For example: *"split a terminal to the right and run the test
watcher"*, or *"lay these out as a 2×2 grid"*.

| Area | Tools |
|---|---|
| Inspect | `get_state`, `list_themes` |
| Sessions & terminals | `new_session` (prompt, split, folder), `fork_session`, `set_view` (native / terminal), `new_terminal` (command, split), `run_in_terminal`, `send_to_session` |
| Tabs | `split_tab`, `move_tab`, `focus_tab`, `close_tab`, `reorder_tab` |
| Layout | `set_layout` (single / columns / rows / grid), `resize_pane`, `set_split_sizes`, `equalize_layout`, `merge_pane`, `focus_pane`, `set_sidebar` |
| Appearance & navigation | `set_theme`, `set_font_size`, `open_palette`, `open_project` |

**Security:** the control server listens on `127.0.0.1` only and requires a random token stored in a `0600` file
(`~/Library/Application Support/Studio/control-<bundle-id>.json`). `run_in_terminal` only works on plain terminal tabs.
Each session gets `STUDIO_TAB`, so the agent knows which tab is its own.

## How it works

```
┌──────────────────────────── Studio.app (SwiftUI + AppKit) ────────────────────────────┐
│  ProjectModel (one per window)  ── tabs, split tree, focus, saved layout               │
│  SessionStore (shared)          ── sessions, live status, transcripts, PRs, attention  │
│  TerminalSession                ── SwiftTerm view running `claude` / your shell         │
│  StudioControl                  ── localhost JSON control server  ◄──┐                 │
└──────────────────────────────────────────────────────────────────────┼─────────────────┘
        reads ▲                                                         │ JSON lines + token
              │                                                         │
  ~/.claude/sessions/<pid>.json   (live status: busy / idle / waiting)  │
  ~/.claude/projects/**/<id>.jsonl (titles, prompts, replies, tokens)   │
                                                                        │
  claude --resume … --mcp-config studio.json  ──►  studio-mcp (stdio MCP server) ──┘
```

- **No API keys, no proxy.** Studio runs the `claude` binary you already use, in a real PTY, through your login shell.
- **Read-only on Claude's data.** Session status and transcripts are read from `~/.claude`; Studio never writes there.
- **State** (open tabs, layouts, theme) lives in the app's `UserDefaults`; snippets live in `~/Library/Application Support/Studio/snippets.json`.

### Project layout

```
Sources/Studio/          the app
  StudioApp.swift          scenes, menus and shortcuts
  ProjectModel.swift       per-window tabs, splits, focus, layout persistence
  SessionStore.swift       shared session state, live status, notifications, next up
  Views.swift              window, tab strip, panes, peek card, status bar
  CommandPalette.swift     ⌘P / ⇧⌘P
  QuickPrompt.swift        ⌘K and snippets
  StudioControl.swift      control server behind the MCP tools
  TranscriptScanner.swift  reads titles, prompts and replies from transcripts
Sources/StudioMCP/       the stdio MCP server bundled next to the app
Resources/               app icon (SVG source + generated .icns)
scripts/make-icon.sh     regenerates AppIcon.icns from AppIcon.svg
```

## Roadmap

- [ ] Sessions that survive app restarts (a small background host owns the processes)
- [ ] Changes pane: a live git diff of what the session is editing
- [ ] Worktree-per-session with one click
- [ ] Search across every transcript
- [ ] Usage and cost overview per session and project

## Contributing

Issues and pull requests are welcome. To hack on Studio:

```bash
swift build                 # debug build
./build-app.sh              # release .app bundle in build/
STUDIO_DEBUG_LOG=/tmp/studio.log open build/Studio.app   # trace PR lookups and palette actions
```

Keep the UI flat and quiet (straight lines, no shadows on chrome, VS Code-like density), and keep Claude Code itself
unmodified: Studio should work with whatever version of `claude` is on your PATH.

## License

[MIT](LICENSE)

<sub>Studio is an independent project and is not affiliated with or endorsed by Anthropic. Claude and Claude Code are trademarks of Anthropic.</sub>
