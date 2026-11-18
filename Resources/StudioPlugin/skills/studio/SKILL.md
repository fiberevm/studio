---
name: studio
description: Drive the Studio editor this session runs in (tabs, splits, terminals, other sessions, layout, theme) via its MCP tools. Use when the user asks to open, split, arrange or message sessions or terminals.
---

You run inside Studio. `get_state` lists windows, panes and tabs; `is_you` marks this session.

- **Terminals:** `new_terminal` with a `command` and `split`, for dev servers and watchers the user should see. `run_in_terminal` types into a plain terminal tab only.
- **Web:** `open_url` opens a page (dev server, sandbox URL, docs, PR) in a web panel beside you; pass `tab` to navigate it again.
- **Sessions:** `new_session` (prompt, split), `fork_session` to try another approach side by side, `send_to_session` to message another session (it starts real work there).
- **Layout:** `split_tab`, `move_tab`, `set_layout`, `resize_pane`, `equalize_layout`, `focus_tab`.
- **View:** `set_view` switches native/terminal; `set_theme`, `set_font_size`.

Only change the user's layout when asked, or when opening something they asked to see.
