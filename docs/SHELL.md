# Shell Configuration

This repo keeps zsh configuration under version control so your shortcuts
stay consistent across machines. There are two layers:

1. **Shared system helpers** in `shared/zsh/` — single source of truth,
   used identically on every machine. NOT three-tier resolved.
2. **Aliases** in `aliases.zsh`, an **aggregate** file: every tier that
   has one (default + each profile in list order + host) is
   concatenated, so later tiers override earlier ones via zsh "last
   definition wins." Each tier carries the aliases that belong to it:
   the default tier holds only universal shortcuts, each profile carries
   the aliases for the tool it adopts (e.g. the git shortcuts live in
   `profiles/dev-core/aliases.zsh`), and the external host tier
   (`${XDG_CONFIG_HOME:-~/.config}/macos-setup/aliases.zsh`) holds only
   genuinely host-specific entries.

## Shared zsh helpers (`shared/zsh/`)

- Directory: `shared/zsh/`
- Contents: flat `.zsh` snippets, each defining one cohesive set of
  helpers, plus one non-zsh symlink. Currently:
  - `macos_setup.zsh` — `m()` (run `make` in macos-setup from anywhere)
    and `_macos_setup_repo` (delegates to
    `scripts/resolve_repo_root.sh`)
  - `iterm.zsh` — `iterm_tab_count`, `set_title`
  - `ws.zsh` — `ws()` unified dispatcher for workspaces, monitors,
    and monitor positions, plus `ws screens` / `ws fix` subcommands
    (Hammerspoon IPC)
  - `launchagent_runner` — symlink to
    `../../scripts/launchagent_runner.sh`, the LaunchAgent entry
    point. Generated plists embed
    `$HOME/.zsh-shared/launchagent_runner` as `ProgramArguments[0]`
    so the runner is reachable through the same symlink chain
    `m()` already uses, with no repo path baked into the plist.
- During `make shell`, `scripts/shell_setup.sh` will:
  - symlink `shared/zsh/` to `~/.zsh-shared`
  - ensure `~/.zshrc` contains a single line that sources every snippet:

    ```zsh
    for f in ~/.zsh-shared/*.zsh; do source "$f"; done
    ```

`m()` locates the macos-setup repo at runtime via
`scripts/resolve_repo_root.sh`, which reads `~/.zsh-shared`, so it
works on any machine regardless of where the repo lives. The same
resolver is used by `scripts/launchagent_runner.sh` so scheduled
jobs and `m()` always agree on the repo root.

## Aliases (`aliases.zsh`)

- Files: `default/aliases.zsh` (in repo, lowest
  tier), each `profiles/{name}/aliases.zsh` the host opts into (in
  repo, in list order; see the `profiles` array in the external host
  tier's `config.toml`), and `aliases.zsh` in the external host tier
  (`${XDG_CONFIG_HOME:-~/.config}/macos-setup/aliases.zsh`, highest
  tier).
- `aliases.zsh` is an **aggregate** file: shell_setup.sh concatenates
  the tiers in `default -> profiles(list order) -> host` order, so a
  higher tier redefining an alias overrides the lower tier (zsh "last
  definition wins").
- Each tier carries only the aliases that belong to it:
  - **default tier** — only truly universal shortcuts (navigation,
    `ll`, the `rm/cp/mv -i` safety aliases, `8601`) plus helpers for
    tools the default tier itself installs (fzf/zoxide/bat). It stays
    minimal so a non-development machine never inherits tool-specific
    aliases.
  - **profile tier** — aliases for the tool that profile adopts. The
    git shortcuts, log variants, `*h` help-greppers, and the
    `gbc`/`gbd`/`gsr` functions live in `profiles/dev-core/aliases.zsh`;
    the `cr` Claude-CLI wrapper and its `cr-anywhere` companion live in
    `profiles/claude-code-aliases/aliases.zsh` (`cr` launches
    `claude --remote-control` from inside a git repo; `cr-anywhere`
    works from any cwd — inside an existing repo it `cd`s to the repo
    root and behaves like `cr`, and outside any repo it `git init`s a
    throwaway repo and tears down only the `.git` it created). A profile
    may carry an
    `aliases.zsh` and nothing else (a "no-software" profile such as
    `claude-code-aliases`, which has no `Install/` files) — opting into
    it just contributes its aliases to the aggregate.
  - **host tier** — only genuinely host-specific entries (e.g. an
    `icloud` shortcut to a machine's iCloud Drive path).
- During setup (`make shell`), `scripts/shell_setup.sh` will:
  - generate `~/.aliases.zsh` as a real file (a concatenation of all
    contributing tiers, not a symlink, since multiple sources combine)
  - ensure your `~/.zshrc` contains: `source ~/.aliases.zsh`
- **zsh gotcha:** you cannot define a function whose name is an active
  alias from a lower tier — zsh errors with "defining function based
  on alias." If a higher tier replaces a lower-tier alias with a
  function of the same name, `unalias <name>` first (e.g. a `gbc`
  function shadowing a `gbc` alias).

You can safely edit per-machine aliases in the external host tier; that
file lives OUTSIDE the repo, so backing it up is your responsibility (the
default- and profile-tier `aliases.zsh` files remain in the repo and are
committed normally). Keep system-level helpers (functions used by
macos-setup itself) in `shared/zsh/` instead.

## asdf and direnv init lines

`make shell` (via `scripts/shell_setup.sh`) idempotently appends the
following to `~/.zshrc` (each line at most once):

```zsh
export PATH="${ASDF_DATA_DIR:-$HOME/.asdf}/shims:$PATH"
eval "$(direnv hook zsh)"
```

asdf 0.16+ is a single Go binary; there is no longer a
`libexec/asdf.sh` to source. The new init pattern (per upstream docs)
is to put the shims directory on `PATH` directly.

If a previous run of this script wrote the legacy
`. /opt/homebrew/opt/asdf/libexec/asdf.sh` line into your `~/.zshrc`,
the next `make shell` removes it (the line now errors on every shell
startup because the file no longer exists). A backup is written to
`~/.zshrc.bak` only when this cleanup actually fires.

## Common Aliases (quick reference)

| Alias  | Command                                          |
| ------ | ------------------------------------------------ |
| `fsf`  | `fzf`                                            |
| `cat`  | `bat --paging=never`                             |
| `grep` | `rg`                                             |
| `find` | `fd`                                             |
| `gss`  | `git status -s`                                  |
| `gd`   | `git diff`                                       |
| `ga`   | `git add`                                        |
| `gc`   | `git commit -v`                                  |
| `gp`   | `git push`                                       |
| `gl`   | `git log --oneline --graph --decorate`           |
| `..`   | `cd ..`                                          |
| `...`  | `cd ../..`                                       |
| `....` | `cd ../../..`                                    |
| `rm`   | `rm -i`                                          |
| `cp`   | `cp -i`                                          |
| `mv`   | `mv -i`                                          |
| `ll`   | `ls -la`                                         |
| `cdz`  | `z` (jump to dirs via zoxide)                    |
| `cdi`  | `zi` (interactive cd via zoxide + fzf)           |
| `cdf`  | `cd "$(fd -td -H . \| fzf)"` (interactive cd)    |
| `fh`   | `history \| fzf` (fuzzy history search)          |
| `fe`   | `fzf --preview "bat ..."` (preview files)        |
