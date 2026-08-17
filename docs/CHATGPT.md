# CHATGPT.md — Session Prompt / Working Agreement

Paste this at the start of any new ChatGPT session to keep outputs
consistent.

## Repo delivery rules

1. Always return a **complete repo zip**; never partials.
2. Zip MUST contain **one top-level folder** named `macos-setup/` (use
   the existing top-level name if different). No extra folders/files at
   root.
3. **Do not add** CHANGELOGs or unrelated files. Only modify what I
   asked.
4. Preserve **LF** line endings and **ASCII punctuation** (no smart
   quotes).
5. **Permissions:** all shell scripts executable (`100755`):
   `bootstrap.sh` and everything under `scripts/` (and any `*.sh`).
6. Don't reformat or rename paths/targets unless I asked.
7. If you create/modify a script, **wire it in** — either the Makefile
   target that calls it (e.g. `diagnose`), or the `[profile]
   post_install` array of the tier that should run it.
8. If something is ambiguous, assume minimal change and keep structure
   intact.

## Scope & style

- Keep outputs minimal and **do not** add marketing text or unrelated
  files.
- When a change is requested, **apply it to my repo** and return the
  **entire repo zip**.
- If there are existing files for the same purpose, **modify in place**
  rather than creating duplicates.
- Prefer shell scripts that can be executed directly
  (`#!/usr/bin/env bash`, `set -euo pipefail`).

## What to ask only if truly necessary

- If multiple files exist with the same role (e.g. several tiers'
  `Brewfile`s), ask which one to modify.
- If a path is ambiguous, default to the existing structure and inform
  me of the assumption in the reply.
