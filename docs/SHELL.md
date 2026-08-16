# Shell Configuration

This repo keeps zsh configuration under version control so your shortcuts
stay consistent across machines. The layers are:

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
    the `cr` Claude-CLI wrapper and its `cr-repo` companion live in
    `profiles/claude-code-aliases/aliases.zsh` (`cr` launches
    `claude --remote-control` from any cwd — inside an existing repo
    it `cd`s to the repo root and derives the session name from
    `origin`, and outside any repo it `git init`s a throwaway repo and
    tears down only the `.git` it created; `cr-repo` is the strict
    variant that requires an existing repo with an `origin` remote and
    errors otherwise). A profile may carry an `aliases.zsh` and nothing
    else (a "no-software" profile such as `claude-code-aliases`, which
    has no `Install/` files) — opting into it just contributes its
    aliases to the aggregate.
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

## mise init lines

`make shell` (via `scripts/shell_setup.sh`) idempotently appends the
following to `~/.zshrc` (each line at most once):

```zsh
export PATH="${XDG_DATA_HOME:-$HOME/.local/share}/mise/shims:$PATH"
eval "$(mise activate zsh)"
```

The activation line is written only once `mise` is on `PATH`; a
`make shell` that runs before `mise` is installed says so and adds
the line on the next run. The shims `PATH` export is written
unconditionally.

Both forms are emitted on purpose. `mise activate zsh` is mise's
preferred interactive form and is what makes `cd` into a project
switch tool versions (and, with `[settings] env_file`, load its
`.env`). The shims directory on `PATH` covers every non-interactive
context that never sources `~/.zshrc` at all.

Scheduled LaunchAgent jobs are one such context — launchd does not
source `~/.zshrc`, so neither line reaches them. `scripts/launchagent_runner.sh`
puts the same shims directory on `PATH` itself for exactly that
reason (the same pattern it uses for `HOMEBREW_NO_ASK`).

### Migrating off asdf + direnv

The `version-managers` profile moved from asdf + direnv to mise. The
next `make shell` after that change removes the `~/.zshrc` lines it
orphans:

- `. /opt/homebrew/opt/asdf/libexec/asdf.sh` — already dead before
  the migration (asdf 0.16+ is a single Go binary with no
  `libexec/asdf.sh` to source) and errors on every shell startup.
- `export PATH="${ASDF_DATA_DIR:-$HOME/.asdf}/shims:$PATH"`
- `eval "$(direnv hook zsh)"`

Each pattern is anchored to the exact active form this script wrote;
indented or commented-out variants are deliberately preserved. A
backup is written to `~/.zshrc.bak` only when this cleanup actually
fires, so a host that has already migrated is a clean no-op on
re-run.

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
