# Makefile Usage

This repository uses a `Makefile` to orchestrate applying each tier's
`Brewfile` and `[profile]` section, plus related setup tasks. The tiers
are the core tier (`default/`), each profile the host opts into
(`profiles/<name>/`, in the order of the `profiles` array in the host
tier's `config.toml`), and the external host tier. See
[the install model](INSTALL.md).

The Makefile has **no per-profile knowledge at all**. It does not
enumerate profiles, and post-install hooks are declared in each profile's
own `config.toml` rather than in a `case` statement here, so
`make profile brand-new` works the moment `profiles/brand-new/` exists —
no Makefile edit.

Every recipe runs under `BASH_BIN`, the absolute `/bin/bash`, which is
also what `SHELL` is set from. Wherever a recipe names an interpreter
for a helper script it writes `$(BASH_BIN) scripts/<name>.sh`, never a
`PATH`-resolved bare `bash`; scripts invoked directly (by their own
shebang, e.g. `scripts/resolve_mailto.sh`) name no interpreter at all.
A run that removes Homebrew's `bash` formula must not lose the
interpreter its own later steps need; see
[Removals never cascade, and never lose the interpreter](INSTALL.md#removals-never-cascade-and-never-lose-the-interpreter).

## Common Targets

- `make install`
  Applies every tier for this host, in order: the core tier, then each
  of the host's profiles in list order, then the host tier. The host
  tier lives OUTSIDE the repo at
  `${XDG_CONFIG_HOME:-~/.config}/macos-setup/` (seeded from
  `computer-specific/_template/` if absent); the host's profiles are
  read from the `profiles` array in its `config.toml` (lowest priority
  first). Each tier's `Brewfile` is run through the smart filter
  (`scripts/install_filter.sh`) before `brew bundle` consumes it, so any
  package listed in an in-scope `uninstall` or `purge` array is
  commented out for that run. Then that tier's `post_install` commands
  run, in declared order. This is the recommended way to set up a new
  machine.

  All three apply paths — `install`, `core`, and `profile` — route
  through `scripts/apply_tier.sh`, so "what applying a tier means" lives
  in exactly one place and they cannot drift.

  `install` does **not** run the removal loops in general — the smart
  filter is what keeps a removal-listed package from being installed.
  The one exception is the `version-managers` tier's `purge` array,
  applied inline right after that tier in this batch loop only
  (`make profile version-managers` stays install-only), because the
  asdf → mise cutover is hard by construction: asdf and mise both
  provide shims for the same tools, so leaving asdf installed
  alongside mise is the failure mode the cutover exists to prevent.
  That inline purge is gated on the `MISE_REACHABLE` Makefile macro —
  the same probe `update` uses, evaluated immediately before the
  removal. If mise is not reachable at that moment the purge is skipped
  entirely, the run warns, and `make install` exits non-zero, so a host
  is never left with asdf gone and no mise.
  See [Version Management](VERSION_MANAGEMENT.md).

  Up-front `dasel` gate: this target (and `core`, `profile`, `update`,
  `verify`, `outdated`) depends on the `.PHONY: require-dasel`
  prerequisite, which runs `scripts/require_dasel_on_path.sh` BEFORE any
  host-tier seeding or config read. `dasel` is invoked by bare name by
  every `config.toml` read; if it is not reachable on `PATH` (the common
  case of running `make install` in the same shell you ran
  `./bootstrap.sh` in — Homebrew's bin isn't on `PATH` until a new
  login shell), the gate aborts with `Error: dasel not in PATH.` and
  a new-shell remediation instead of failing late and cryptically
  partway into the first tier. It is a reachability check only and
  does not auto-install or self-heal `PATH`; the exactly-v3 version
  assertion remains the job of `require_dasel_v3` at the first read.

  The `PROFILES := $(shell ... list_profiles.sh ...)` variable is read
  at make *parse* time, before any prerequisite can run, so
  `list_profiles.sh` guards itself: with dasel off `PATH` it
  short-circuits to an empty list rather than emitting a
  `Terminated: 15` line ahead of the gate's clean error. The gate and
  that self-guard together make `Error: dasel not in PATH.` the sole
  output on a no-dasel run.

  Failure-tolerant: a `brew bundle` failure, or a failing `post_install`
  command, on one tier no longer aborts the run. The loop attempts every
  tier, accumulates the tiers that returned non-zero, and at the end
  prints a summary listing each. It exits non-zero if any tier failed
  (otherwise it exits 0 with `All tiers applied.`). This lets a single
  failing cask be left for later without blocking every later tier — fix
  the listed tiers and re-run `make install`. A version-managers purge
  that returned non-zero lands in that same summary; one that was *held
  back* by the `MISE_REACHABLE` guard is tracked separately and prints
  its own `==> Skipped the asdf/direnv removal ...` line after the
  summary. Either one suppresses `All tiers applied.` and makes the run
  exit non-zero.

  Quiet by default: most tiers carry no `Brewfile` and no `post_install`
  entries, so those negative-case lines (`==> No Brewfile found at ...`,
  `==> No post_install entries for ...`) are suppressed in a normal run
  and a host that opts into many profiles is not buried under noise. Set
  `VERBOSE=1` to restore them when debugging "why didn't my profile
  apply?". Any non-empty `VERBOSE` value enables them. The gate lives in
  `scripts/apply_tier.sh`, so it applies identically to `make install`,
  `make core`, and `make profile`.

- `make core`
  Applies just the core tier: `default/Brewfile` through the filter, then
  the `post_install` commands in `default/config.toml` (computer names,
  shell setup, the `~/.msmtprc` generator).

- `make profile <name> [<name>...]`
  Applies just the named profiles, in the order given — not sorted, not
  in the host's configured order.

  ```bash
  make profile web
  make profile web aws databases
  ```

  Validation runs **before** the apply loop, so a typo anywhere in the
  list aborts with exit 2 and applies nothing:

  ```console
  $ make profile web nonexistent
  make: unknown profile(s): nonexistent
  known profiles: aws dev-core web ...
  exit=2

  $ make profile
  usage: make profile <name> [<name>...]
  exit=2
  ```

  The apply loop is failure-tolerant with an end-of-run summary, matching
  `make install`: a mid-list failure does not stop the later profiles,
  and the run exits non-zero naming what failed. (A bare `for` loop would
  return only the last iteration's status, silently swallowing a mid-list
  failure — worse than the per-slot behavior this replaced.)

  `make profile --name <foo>` is **not** achievable: make consumes
  `--`-prefixed arguments as its own options before the Makefile sees
  them (`make: unrecognized option '--name'`). Two accepted rough edges
  follow from the `$(eval)` trick that makes the positional form work,
  both on already-failing paths: `make profile install` emits a
  `warning: overriding commands for target 'install'` before validation
  rejects `install` and exits 2 (plain `make install` is unaffected), and
  `make install profile web` fires the usage error after `install` runs
  because `profile` is not the first goal.

- `make profiles`
  Lists every profile in the repo, marking the ones this host opts into
  and printing the tier order the host actually applies.

- `make uninstall`
  Walks every tier for this host, in tier order, applying each tier's
  `[profile] uninstall` array. Skips entries that aren't installed.
  Removes the binary; leaves user data on disk.

  Quiet by default about tiers that remove nothing: a tier whose array
  for the active mode is empty or absent prints nothing — neither the
  `==> Applying Uninstall: <tier>` banner nor the runner's
  `[uninstall] Processing` / `Done:` lines. A tier with at least one
  entry prints fully, including `skip: <pkg> not installed` lines. Set
  `VERBOSE=1` to restore all lines for every tier when debugging.

  Both removal loops run through `scripts/remove_runner.sh`, which
  honors `BREW`, `MAS`, and `SUDO` overrides at **every** shell-out —
  the `brew list` / `mas list` probes as well as the uninstalls. GNU
  make exports command-line variables into every recipe's
  environment, so `make uninstall BREW=<stub> MAS=<stub> SUDO=<stub>`
  reaches the runner. This is how a test drives the removal loops
  without touching real Homebrew, the real Mac App Store, or real
  `sudo`; see
  [Overriding the package-manager binaries](INSTALL.md#overriding-the-package-manager-binaries).
  The runner also exports `HOMEBREW_NO_AUTOREMOVE=1`, so an uninstall
  never cascades into a shared dependency.

- `make uninstall-dry-run`
  Same as `make uninstall` but only prints what would happen. Safe to
  run on a fresh checkout; with no populated `uninstall` arrays it
  reports zero actions.

- `make remove-and-purge`
  Walks the same tiers applying each tier's `[profile] purge` array.
  Same shape as `make uninstall`, but for casks the runner uses
  `brew uninstall --cask --zap`, which also removes the cask's declared
  user data (preferences, caches, login items). The same
  quiet-by-default gating described under `make uninstall` applies
  (override with `VERBOSE=1`).

- `make remove-and-purge-dry-run`
  Same as `make remove-and-purge` but only prints what would happen.

- `make update`
  Runs `brew update`, upgrades all formulae and casks, upgrades MAS
  apps, applies the `version-managers` tier, updates and prunes
  mise-managed tool versions, then applies `make uninstall` and
  `make remove-and-purge`. Uninstall and purge run *after* the
  upgrade chain so "uninstall wins over install" is the end state:
  even if `brew upgrade` resurrects something via dependency
  resolution, the uninstall step removes it before the user sees the
  result. `version-managers` is the ONE tier `update` applies; no
  other tier's `Brewfile` is re-applied.

  That tier step is gated on the host opting into the profile, via the
  `VM_OPTED_IN` Makefile variable (`version-managers` present in the
  `profiles` array). `install` needs no such test — it reaches the tier
  only as one iteration of its tier walk — but `update` applies the tier
  explicitly, so without the gate it would install mise on a host that
  never asked for it. Not opted in means: no tier apply, no `~/.zshrc`
  rewrites, no asdf/direnv removal, one printed line, and the run's exit
  status untouched. The rest of this entry describes the opted-in host.

  It then rewrites `~/.zshrc` from both sides:
  `scripts/strip_asdf_zshrc_lines.sh` removes the asdf/direnv init
  lines, and `scripts/ensure_mise_zshrc_lines.sh` adds the mise shims
  `PATH` export and `eval "$(mise activate zsh)"` that replace them.
  The purge step uninstalls `asdf` and `direnv`, and `update` never
  runs `shell_setup.sh` — the only other caller of that pair — so
  without the strip it would leave the old init lines erroring on
  every shell startup, and without the add it would leave the host
  with no version manager wired into the interactive shell at all.
  Both scripts are grep-guarded no-ops once their work is done.

  The `version-managers` tier is applied first for the same reason:
  `brew upgrade` upgrades an installed formula but never installs an
  absent one, so on a host that never ran `make install` the purge would
  take asdf and direnv out with no mise to replace them. Install strictly
  precedes remove — and if the `MISE_REACHABLE` probe (the same macro
  `install` gates its inline purge on, so the two destructive paths
  cannot drift) still finds no mise after that step, `update` skips that
  tier in both removal loops (via `REMOVE_SKIP_TIERS`) and skips both
  `~/.zshrc` rewrites, warns, and exits non-zero, leaving every other
  tier to apply normally.

- `make self-update`
  Pulls the latest `main` into this repo via `scripts/self_update.sh`.
  If you're on a branch other than `main`, it switches to `main`. If
  the working tree is dirty, it auto-stashes (including untracked
  files), pulls, then pops the stash. Prints the before/after SHA of
  `main` on success.

  Refuses (does nothing, exits non-zero) if you're not inside the
  repo, inside a linked worktree (e.g. `.claude/worktrees/...` —
  run from the main checkout instead), in detached HEAD,
  mid-rebase/merge/cherry-pick/revert/bisect, the pull fails
  (non-fast-forward, network error), or `git stash pop` conflicts
  (the changes are left in `stash@{0}` for manual resolution).

  Append `DRY_RUN=1` to print what would happen without making any
  changes:

  ```bash
  make self-update DRY_RUN=1
  make self-update
  ```

  Out of scope: this only updates the working tree. Use `make update`
  to upgrade Homebrew/managed tool versions/installed software.

- `make verify`
  Runs `scripts/verify.sh` (per-tier Brewfile verification) and then
  `scripts/collision_check.sh` to detect **same-tier collisions**: a
  package listed in BOTH `<tier>/Brewfile` AND that same tier's
  `[profile] uninstall` or `[profile] purge` array. Same-tier collisions
  are bugs (`make update` would just undo the install); cross-tier
  collisions are intentional ("opt out at a more-specific tier") and are
  not reported. Exits non-zero if any Brewfile entries are missing OR any
  same-tier collisions are found.

- `make sanitize`
  Resolves the same-tier collisions reported by `make verify` by
  commenting out the offending lines in the `Brewfile` (the removal array
  wins per the conflict rule in `docs/INSTALL.md`). Writes a `.bak` next
  to each edited file and prints a summary. Review the diff (e.g.
  `git diff`), commit, and remove the `.bak` files when satisfied.

- `make claude-install`
  Clones the global Claude config repo
  (`https://github.com/TheVoskamps/claude-config.git`)
  into `~/.claude/`, switches to the branch named by the single-winner
  `[claude]` section of `config.toml` (external host > reverse(profiles) >
  default; `branch` key), and pulls `--ff-only`. Fresh clones use
  the HTTPS URL (most users won't have an SSH key on the org/repo); an
  existing clone whose `origin` is the SSH form is recognized as ours
  and its SSH origin is left intact (not rewritten to HTTPS). Missing
  or unknown branch falls back to the global repo's default branch
  (resolved at run time). The optional `hostname=` field rewrites
  the git remote URL to `git@<alias>:...` so `~/.ssh/config` can
  pick a per-machine IdentityFile; a non-default `hostname=` against
  an existing default-host clone is reconciled by rewriting `origin`
  on the next run (idempotent).

  If `~/.claude/` already exists and is not a clone of the target
  repo (legacy symlink tree, hand-fixed real files, stale clone of
  another repo, etc.), it is moved aside to
  `~/.claude.orig.<timestamp>/`, fresh-cloned, and the captured
  contents are overlaid back on top (local wins, broken symlinks
  skipped with a warning). Reached automatically by `make install` and
  `make profile claude` via the `claude` / `claude-latest` profiles'
  `post_install`.

  After the clone/migration completes, it syncs Claude plugins via
  `~/.claude/plugins.sh --install` (see `make claude-plugins-install`
  below). That step is non-fatal: a missing `claude` CLI, a missing
  `plugins.sh`, or a `plugins.sh` failure warns and is skipped rather
  than aborting the install.

- `make claude-update`
  Updates an existing `~/.claude/` clone (errors if missing — run
  `make claude-install` first), then syncs Claude plugins via
  `~/.claude/plugins.sh --update` (non-fatal, same as
  `claude-install`). Run as part of `make update`.

- `make claude-outdated`
  Read-only: reports pending pulls/pushes and dirty files in
  `~/.claude/`. Run as part of `make outdated`.

- `make claude-plugins-install`
  Syncs Claude plugins by invoking the clone's own
  `~/.claude/plugins.sh --install`, which registers the marketplaces
  in `extraKnownMarketplaces` and installs the plugins in
  `enabledPlugins` from `~/.claude/settings.json`. macos-setup only
  calls the script; the `settings.json` parsing and `claude plugin`
  invocations live in the claude-config repo. If the `claude` CLI is
  not on PATH or `~/.claude/plugins.sh` is missing (an older
  claude-config checkout), it warns and skips (exit 0). A non-zero
  `plugins.sh` exit is surfaced, so a directly-invoked run reports the
  failure. `make claude-install` runs this same step inline (but
  non-fatally).

- `make claude-plugins-update`
  Same as `make claude-plugins-install` but `--update`: updates the
  registered marketplaces and installed plugins. Run inline (non-fatally)
  by `make claude-update`.

- `make shell_setup`
  Runs `scripts/shell_setup.sh` standalone. Also reached as the core
  tier's second `post_install` action.

- `make help`
  Lists all documented targets plus every profile in the repo.

## Post-install actions

A tier declares what to run after its `Brewfile` in the `post_install`
array of its own `config.toml`:

```toml
[profile]
post_install = ["scripts/vscode_extensions.sh code", "scripts/vscode_setup.sh"]
```

Each entry is a path relative to the repo root plus optional arguments.
This is where the old Makefile `case` table went. Where each hook lives
now:

| Action | Tier |
| --- | --- |
| `core_setup.sh` (computer names, brew env) | core (`default/`) |
| `shell_setup.sh` | core (`default/`) |
| `msmtp_setup.sh` (generates `~/.msmtprc`) | core (`default/`) |
| `hammerspoon_setup.sh` | `desktop-ui` |
| `versions_setup.sh full` | `version-managers` |
| `vscode_extensions.sh code` + `vscode_setup.sh` | `visual-studio-code` |
| `vscode_extensions.sh cursor` | `cursor` |
| `cdk_setup.sh` | `aws` |
| `claude_disable_autoupdater.sh`, `claude_repo_setup.sh` | `claude`(-latest) |

Each hook moved to the tier that installs the software it configures, so
a host that does not opt into `desktop-ui` no longer runs the Hammerspoon
setup (which was previously unconditional, because the empty
`02-Install.ui` slot existed at the default tier).

A missing, non-executable, or failing `post_install` command is reported
and tracked, never fatal — the run continues to the next command and the
next tier, and the end-of-run summary names the tier.

## Version management

Additional targets exist to manage runtimes explicitly. They are named
`versions-*` rather than after the tool that implements them (mise),
so swapping the implementation leaves the target names, their callers,
and the doc lines that reference them alone — the change is bounded to
the scripts that name the tool directly
(`scripts/versions_setup.sh`, `scripts/mise_common.sh`, and the
shell/launchd `PATH` lines in `scripts/ensure_mise_zshrc_lines.sh`
and `scripts/launchagent_runner.sh`):

- `make versions-install` — install the versions the resolved mise
  config declares
- `make versions-update` — install latest versions AND bump the
  config (`mise up --bump`)
- `make versions-outdated` — report tools with a newer version
  available
- `make versions-cleanup` — remove unused installed versions
  (`mise prune`)
- `make versions-cleanup-dry-run` — show what cleanup would remove

`make update` runs `versions-update` then `versions-cleanup`;
`make outdated` runs `versions-outdated`.

---

## Directory Enablement

To convert a project directory from asdf + direnv to mise, run:

```bash
make asdf-to-mise
```

It operates on the directory you invoked it from (`START_DIR`), one
repo per run. It is **purely additive**: it generates `mise.toml` from
`.tool-versions`, writes a sentinel-guarded `.gitignore` block pinning
`mise.toml` as the one tracked config form, and warns about every
asdf/direnv leftover it finds — while deleting nothing, moving
nothing, untracking nothing, and committing nothing.

`make asdf-to-mise` is a deliberate exception to the
implementation-neutral naming above: it names both endpoints on
purpose because it is a migration verb, and it is deleted once every
repo and host is over.

See [Version Management](VERSION_MANAGEMENT.md) for the full runbook,
the multi-version-line pre-flight, and the manual cleanup checklist.

## Shell completion

`m` is the zsh wrapper that runs `make` in this repo from any cwd (see
[SHELL.md](SHELL.md)). Its completer, `_m`, is registered by
`shared/zsh/macos_setup.zsh`:

- `m <TAB>` offers the `##`-documented Makefile targets plus `profile`.
- `m profile <TAB>` offers the profile directory names, with the ones
  already on the command line filtered out.

It resolves the repo the same way `m()` does (via `_macos_setup_repo`), so
it works from any directory, and it reads profile candidates straight from
the directory glob — no `dasel` call per keystroke.
