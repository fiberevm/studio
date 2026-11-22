---
name: studio
description: Drive the Studio editor this session runs in (tabs, splits, terminals, web panels, other sessions, workers, layout, theme) via its MCP tools. Use when the user asks to open, split, arrange or message sessions or terminals, whenever you need a browser, and to hand work to sub-agents on the user's other machines (workers).
---

You run inside Studio. `get_state` lists windows, panes and tabs; `is_you` marks this session.

**Browser: use Studio's web panel by default.** It opens next to you, where the user can watch, instead of Chrome, computer-use or other browser tools. Use it to open, check or click through a page: your dev server, a sandbox URL, a PR, docs, a login flow. Use WebFetch only for a quick read the user doesn't need to see.

- **Terminals:** `new_terminal` with a `command` and `split`, for dev servers and watchers the user should see. `run_in_terminal` types into a plain terminal tab only.
- **Files:** `open_file` opens a file in Studio's editor in the user's window (to show them what you changed or where to look; relative paths are from the project; pass `line` to jump to a line).
- **Web:** `open_url` opens a page (dev server, sandbox URL, docs, PR) in a web panel beside you; pass `tab` to navigate it again. Drive it: `web_read` (text + numbered elements), `web_click` / `web_type` by `ref`, `web_wait`, `web_screenshot` (then Read the PNG to see it), `web_eval`.
- **Sessions:** `new_session` (prompt, split), `fork_session` to try another approach side by side, `send_to_session` to message another session (it starts real work there).
- **Layout:** `split_tab`, `move_tab`, `set_layout`, `resize_pane`, `equalize_layout`, `focus_tab`.
- **View:** `set_view` switches native/terminal; `set_theme`, `set_font_size`.

Only change the user's layout when asked, or when opening something they asked to see.

## Workers: sub-agents on other machines

Workers are the user's other machines (usually always-on Linux boxes on their VPN) running `studio-worker`. You can start agent sessions there and hand them work. Each runs in tmux on the worker, keeps going if Studio or the network goes away, and opens in a tab beside you so the user can watch.

**When to delegate.** Use a worker when a task is independent of what you're doing and benefits from running elsewhere: long builds or test suites, work that needs the worker's hardware or network (GPUs, a database only it can reach), or several independent tasks in parallel (one session each). Keep work here when it's quick, needs this conversation's context, or touches files only on this Mac. If the user names a machine, use it.

1. `list_workers`: see which workers are online, their agents, default folder and existing sessions. Don't start a session on an offline worker.
2. Pick the folder on the worker: `worker_list_dirs` (git repos are marked). The worker has its own checkouts; the code there is not your working tree. If the task needs your local changes, push a branch first and tell the sub-agent to fetch it.
3. `worker_start_session` with a **self-contained prompt**: the sub-agent knows nothing of this conversation. State the goal, the repo and branch, constraints (don't push to main, which files to leave alone), how to verify, and exactly what to report back when done. Ask it to work on its own branch when it edits code.
4. Follow up with `worker_session`: `working` means let it run; `waiting` means it's blocked on a permission or question (read `waiting_for` and the screen, then answer with `worker_send` or ask the user); `idle` means it finished its turn, and `last_reply` holds its report. Check every minute or two rather than in a tight loop; do your own work in between.
5. Report the result to the user in your own words: what it did, where (worker, folder, branch or PR), and anything left for them.
6. `worker_stop_session` when a session's work is done and the user doesn't need it anymore. Leave it if they may want to look.

Never send secrets in prompts. Several sessions on one worker are fine; mention them when you start more than two.
