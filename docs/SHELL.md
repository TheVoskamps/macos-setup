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
- During `make shell_setup`, `scripts/shell_setup.sh` will:
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
    has no `Brewfile`) — opting into it just contributes its
    aliases to the aggregate.
  - **host tier** — only genuinely host-specific entries (e.g. an
    `icloud` shortcut to a machine's iCloud Drive path).
- During setup (`make shell_setup`), `scripts/shell_setup.sh` will:
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

`scripts/ensure_mise_zshrc_lines.sh` idempotently appends the
following to `~/.zshrc` (each line at most once):

```zsh
export PATH="${XDG_DATA_HOME:-$HOME/.local/share}/mise/shims:$PATH"
eval "$(mise activate zsh)"
```

The activation line is written only once `mise` is on `PATH`; a run
before `mise` is installed says so and adds the line on the next one.
Pointing `~/.zshrc` at a mise that is not there would error on every
shell startup. The shims `PATH` export is written unconditionally — a
`PATH` entry naming a directory that does not exist yet is inert, and
it is correct the moment mise lands.

"On `PATH`" is decided in two steps: the calling shell's `PATH` first,
then a fallback to `/bin/bash -lc` — which is exactly what the
Makefile's `MISE_REACHABLE` macro is. The login-shell half matters
because a
mise installed moments earlier in the same run lands on a login shell's
`PATH`, not necessarily on make's — and `MISE_REACHABLE` is what lets
`make update` remove asdf and direnv. If this script checked only make's
`PATH`, the two gates could disagree within one run: the removal
happens, the activation line is withheld, and the host ends the cutover
with no version manager wired into the interactive shell — exactly the
failure issue #38 exists to fix.

Like the strip below, the script has more than one caller, and for the
same reason:

- `make shell_setup` / `make install`, via `scripts/shell_setup.sh`.
- `make update`, which calls it directly — it installs mise and
  uninstalls asdf and direnv but never runs `shell_setup.sh`, so
  without the direct call a host that goes through the cutover purely
  via `make update` would end it with no version manager wired into
  the interactive shell at all (issue #38).

`ZSHRC_PATH` overrides the file it edits and `MISE` overrides the
binary the reachability check looks for (both so the test suite can
drive the script against a fixture); the line written into `~/.zshrc`
always names bare `mise` regardless of `MISE`, because that is what
your interactive shell will find.

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
`~/.zshrc` half of that cutover is a pair of scripts — the strip below
and the add above — and every caller runs both, in that order, so the
two cutover paths leave `~/.zshrc` in the same state.

The strip lives in `scripts/strip_asdf_zshrc_lines.sh` and removes the
`~/.zshrc` lines that the change orphaned:

- `. /opt/homebrew/opt/asdf/libexec/asdf.sh` — already dead before
  the migration (asdf 0.16+ is a single Go binary with no
  `libexec/asdf.sh` to source) and errors on every shell startup.
- `export PATH="${ASDF_DATA_DIR:-$HOME/.asdf}/shims:$PATH"`
- `eval "$(direnv hook zsh)"`

Each pattern is anchored to the exact active form `shell_setup.sh`
wrote; indented or commented-out variants are deliberately preserved.
A backup is written to `~/.zshrc.bak` only when this cleanup actually
fires, so a host that has already migrated is a clean no-op on
re-run.

It has more than one caller, because the cutover reaches a host down
either of the paths below, and each must leave `~/.zshrc` clean:

- `make shell_setup` / `make install`, via `scripts/shell_setup.sh`.
- `make update`, which calls the script directly — it uninstalls asdf
  and direnv through the `RemoveAndPurge` loop but never runs
  `shell_setup.sh`, so without the direct call it would remove the
  binaries and leave their broken init lines behind.

On the `make update` path both rewrites sit behind the same guard as
the asdf/direnv removal: if mise is still not reachable after the
slot-04 install, `update` skips the removal and both `~/.zshrc`
rewrites, warns, and exits non-zero. See
[Version Management](VERSION_MANAGEMENT.md).

`ZSHRC_PATH` overrides the file it edits (the test suite points it at
a fixture); it defaults to `~/.zshrc`.

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
