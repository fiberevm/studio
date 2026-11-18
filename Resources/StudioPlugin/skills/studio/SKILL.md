---
name: studio
description: Drive the Studio editor this session runs in (tabs, splits, terminals, web panels, other sessions, layout, theme) via its MCP tools. Use when the user asks to open, split, arrange or message sessions or terminals, and whenever you need a browser.
---

You run inside Studio. `get_state` lists windows, panes and tabs; `is_you` marks this session.

**Browser: use Studio's web panel by default.** It opens next to you, where the user can watch, instead of Chrome, computer-use or other browser tools. Use it to open, check or click through a page: your dev server, a sandbox URL, a PR, docs, a login flow. Use WebFetch only for a quick read the user doesn't need to see.

- **Terminals:** `new_terminal` with a `command` and `split`, for dev servers and watchers the user should see. `run_in_terminal` types into a plain terminal tab only.
- **Web:** `open_url` opens a page (dev server, sandbox URL, docs, PR) in a web panel beside you; pass `tab` to navigate it again. Drive it: `web_read` (text + numbered elements), `web_click` / `web_type` by `ref`, `web_wait`, `web_screenshot` (then Read the PNG to see it), `web_eval`.
- **Sessions:** `new_session` (prompt, split), `fork_session` to try another approach side by side, `send_to_session` to message another session (it starts real work there).
- **Layout:** `split_tab`, `move_tab`, `set_layout`, `resize_pane`, `equalize_layout`, `focus_tab`.
- **View:** `set_view` switches native/terminal; `set_theme`, `set_font_size`.

Only change the user's layout when asked, or when opening something they asked to see.
