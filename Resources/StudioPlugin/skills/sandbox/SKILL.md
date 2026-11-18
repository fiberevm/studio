---
name: sandbox
description: Run work in a remote sandbox (boat.dev Linux VM) via Studio's sandbox_* tools. Use when the user asks for a sandbox, or when this session already has one (sandbox_list).
---

Sandboxes are remote Linux VMs from Studio's `sandbox_*` MCP tools. Each session's sandboxes show in its status bar.

**When**
- This session has a sandbox (`sandbox_list`): run builds, tests, servers and risky commands there, not locally.
- Creating one: follow the `policy` that `sandbox_list` returns. Delete only when the user asks; sandboxes cost money.

**How**
1. `sandbox_create`: pushes the project to `/home/user/<project>` and returns its id.
2. `sandbox_exec`: `cwd` is relative to `/home/user`. Use `background: true` for servers and long jobs.
3. After local edits, `sandbox_push` again. Edit locally, run in the sandbox.
4. `sandbox_url`: an HTTPS link to a port. `sandbox_terminal`: a shell for the user.

`id` defaults to the session's latest sandbox. Report the sandbox id and any URLs you open.
