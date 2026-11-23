---
name: secrets
description: Use API keys, tokens and passwords through Studio's secret_* tools without ever seeing their values. Use whenever a task needs a credential, or when you are about to ask the user to paste one.
---

Studio keeps secrets (API keys, tokens, passwords) for the user. You work with them by **name**; you never see a value, and values must never appear in this conversation.

**Rules**
- Never ask the user to paste a secret into the chat, and never print, echo, log or write one to a file you will read. If you need a credential, use `secret_request`.
- Refer to a secret only as `$NAME` inside a `secret_run` command.

**Tools**
- `secret_list`: the secrets that exist (names, what they're for, expiry). Check here first.
- `secret_request(name, reason, expires_in?)`: Studio asks the user to type the value into a dialog. You get "saved" or "declined", not the value. `name` is an environment variable name, e.g. `GITHUB_TOKEN`. Suggest a short `expires_in` (`1h`, `7d`) for temporary credentials.
- `secret_run(command, secrets: [names])`: runs a shell command with those secrets in its environment and returns its output with every secret scrubbed (`[secret NAME]`). Example: `secret_run(command: "curl -sH \"Authorization: Bearer $GITHUB_TOKEN\" https://api.github.com/user", secrets: ["GITHUB_TOKEN"])`.
- `secret_capture(name, command, expires_in?)`: runs a command and stores what it prints as a new secret, without showing it to you. Use it for tokens a command generates (`gh auth token`, `aws sts ...`, `openssl rand -hex 32`).

A scrubbed value in output means the command printed a secret: don't try to work around it.
