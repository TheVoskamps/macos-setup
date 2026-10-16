# Claude config

## `~/.claude/` is another repository

`~/.claude/` is a clone of `TheVoskamps/claude-config`, and its hooks,
settings, and `plugins.sh` live there. This repo only clones, updates,
and calls into it, so a change to any of those belongs in that repo,
never here.

## `plugins.sh` is located and invoked in two places

Every plugin sync calls one of the two functions that locate and run
`plugins.sh`:

- `sync_claude_plugins` in `scripts/claude_repo_setup.sh`, for a sync
  inline in the install and update flows, or through the standalone
  `plugins-install` / `plugins-update` sub-commands.
- `update-claude-plugins` in `profiles/claude-code-aliases/aliases.zsh`,
  for a sync run from an interactive shell.

## Scratch work lives under `.claude/tmp/<task-slug>/`

Scratch files, fixtures, and throwaway artifacts go under
`.claude/tmp/<task-slug>/`, never under `/tmp/`, `/var/tmp/`, or the
home directory. Remove the sandbox once the task succeeds; leave it in
place when the task fails so the failure can be examined.
