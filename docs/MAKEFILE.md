# Makefile Usage

This repository uses a dynamic `Makefile` to orchestrate applying
`Install/` files (formerly `Brewfiles`) and the parallel `Uninstall/`
and `RemoveAndPurge/` frameworks, plus related setup tasks.

## Common Targets

- `make install`
  Applies all `Install/` files in numeric order (00 → 19), at every
  configured tier (default, then each of the host's profiles in list
  order, then host). The host tier lives OUTSIDE the repo at
  `${XDG_CONFIG_HOME:-~/.config}/macos-setup/` (seeded from
  `computer-specific/_template/` if absent); the host's profiles are
  read from the `profiles` array in its `config.toml` (lowest priority
  first). Each file is run through the smart filter
  (`scripts/install_filter.sh`) before `brew bundle` consumes it, so
  any package listed in an in-scope `Uninstall/` or `RemoveAndPurge/`
  slot is commented out for that run. This is the recommended way to
  set up a new machine.

  `install` does **not** run the removal loops in general — the smart
  filter is what keeps a removal-listed package from being installed.
  The one exception is slot 04's `RemoveAndPurge`, applied inline by
  the `04-Install.versionmanagers` post-install action in this batch
  loop only (the per-slot `make versionmanagers` stays install-only),
  because the asdf → mise cutover is hard by construction: asdf and mise both
  provide shims for the same tools, so leaving asdf installed
  alongside mise is the failure mode the cutover exists to prevent.
  That inline purge is gated on the `MISE_REACHABLE` Makefile macro —
  the same probe `update` uses, evaluated immediately before the
  removal rather than left to the surrounding `set -e`. If mise is not
  reachable at that moment the purge is skipped entirely, the run
  warns, and `make install` exits non-zero, so a host is never left
  with asdf gone and no mise.
  See [Version Management](VERSION_MANAGEMENT.md).

  Up-front `dasel` gate: this target (and `update`, `verify`,
  `outdated`) depends on the `.PHONY: require-dasel` prerequisite,
  which runs `scripts/require_dasel_on_path.sh` BEFORE any host-tier
  seeding or config read. `dasel` is invoked by bare name by every
  `config.toml` read; if it is not reachable on `PATH` (the common
  case of running `make install` in the same shell you ran
  `./bootstrap.sh` in — Homebrew's bin isn't on `PATH` until a new
  login shell), the gate aborts with `Error: dasel not in PATH.` and
  a new-shell remediation instead of failing late and cryptically
  partway into `00-Install.core`. It is a reachability check only and
  does not auto-install or self-heal `PATH`; the exactly-v3 version
  assertion remains the job of `require_dasel_v3` at the first read.

  The `PROFILES := $(shell ... list_profiles.sh ...)` variable is read
  at make *parse* time, before any prerequisite can run, so
  `list_profiles.sh` guards itself: with dasel off `PATH` it
  short-circuits to an empty list rather than emitting a
  `Terminated: 15` line ahead of the gate's clean error. The gate and
  that self-guard together make `Error: dasel not in PATH.` the sole
  output on a no-dasel run.

  Failure-tolerant: a `brew bundle` failure on one slot no longer
  aborts the run. The loop attempts every slot, accumulates the slots
  whose `brew bundle` returned non-zero, and at the end prints a
  summary listing each failed slot. It exits non-zero if any slot
  failed (otherwise it exits 0 with `All Install files applied.`). This
  lets a single failing cask be left for later without blocking every
  later slot — fix the listed slots and re-run `make install`. A
  slot-04 `RemoveAndPurge` that returned non-zero lands in that same
  summary; one that was *held back* by the `MISE_REACHABLE` guard is
  tracked separately and prints its own
  `==> Skipped the asdf/direnv removal ...` line after the summary.
  Either one suppresses `All Install files applied.` and makes the run
  exit non-zero.

  Quiet by default: the tier walk probes every profile and the host
  tier for each Install slot, but only contributing tiers print output
  (the `==> Found ... Install` and `==> Applying ...` lines). The
  per-tier "not found" lines (`==> No profile Install found at ...`,
  `==> No computer-specific Install found at ...`) are suppressed in a
  normal run, so a host that opts into many profiles is not buried under
  hundreds of noise lines. Set `VERBOSE=1` (e.g. `VERBOSE=1 make
  install`) to restore those per-tier "not found" lines when debugging
  "why didn't my profile's Install apply?". Any non-empty `VERBOSE`
  value enables them; unset/empty keeps the run quiet. This gating
  applies identically to `make install` and to every per-slot install
  target (`make ui`, `make core`, `make 16`, etc.).

- `make uninstall`
  Applies all `Uninstall/` files in numeric order across the default
  tier, each of the host's profiles in list order, then host. Skips
  entries that aren't installed. Removes the binary; leaves user data
  on disk.

  Quiet by default about empty slots: nearly every numbered slot file
  is just a comment header with no package to remove, so a slot+tier
  whose file has zero active `brew`/`cask`/`mas` directives prints
  nothing — neither the `==> Applying ... Uninstall: <file>` banner
  nor the runner's `[uninstall] Processing` / `Done:` lines. A slot
  with at least one active directive prints fully, including
  `skip: <pkg> not installed` lines. Set `VERBOSE=1` to restore all
  lines for every slot, including empty ones, when debugging.

  Both removal loops run through `scripts/remove_runner.sh`, which
  honors `BREW`, `MAS`, and `SUDO` overrides at **every** shell-out —
  the `brew list` / `mas list` probes as well as the uninstalls. GNU
  make exports command-line variables into every recipe's
  environment, so `make uninstall BREW=<stub> MAS=<stub> SUDO=<stub>`
  reaches the runner. This is how a test drives the removal loops
  without touching real Homebrew, the real Mac App Store, or real
  `sudo`; see
  [Overriding the package-manager binaries](INSTALL.md#overriding-the-package-manager-binaries).

- `make uninstall-dry-run`
  Same as `make uninstall` but only prints what would happen. Safe to
  run on a fresh checkout; with empty `Uninstall/` seed files it
  reports zero actions.

- `make remove-and-purge`
  Applies all `RemoveAndPurge/` files in numeric order across all
  tiers. Same shape as `make uninstall`, but for casks the runner
  uses `brew uninstall --cask --zap`, which also removes the cask's
  declared user data (preferences, caches, login items). The same
  empty-slot quiet-by-default gating described under `make uninstall`
  applies (override with `VERBOSE=1`).

- `make remove-and-purge-dry-run`
  Same as `make remove-and-purge` but only prints what would happen.
  Safe to run on a fresh checkout; with empty `RemoveAndPurge/` seed
  files it reports zero actions.

- `make update`
  Runs `brew update`, upgrades all formulae and casks, upgrades MAS
  apps, applies the slot-04 (`versionmanagers`) `Install` tiers,
  updates and prunes mise-managed tool versions, then applies
  `make uninstall` and
  `make remove-and-purge`. Uninstall and purge run *after* the
  upgrade chain so "uninstall wins over install" is the end state:
  even if `brew upgrade` resurrects something via dependency
  resolution, the uninstall step removes it before the user sees the
  result. Slot 04 is the ONE `Install/` slot `update` applies; no
  other `Install/` file is re-applied.

  It then calls `scripts/strip_asdf_zshrc_lines.sh`. The purge step
  uninstalls `asdf` and `direnv`, and `update` never runs
  `shell_setup.sh`, so without this call it would remove the binaries
  and leave their `~/.zshrc` init lines erroring on every shell
  startup. The script is a no-op once the lines are gone.

  Slot 04's `Install` runs first for the same reason: `brew upgrade`
  upgrades an installed formula but never installs an absent one, so
  on a host that never ran `make install` the purge would take asdf
  and direnv out with no mise to replace them. Install strictly
  precedes remove — and if the `MISE_REACHABLE` probe (the same macro
  `install` gates its inline purge on, so the two destructive paths
  cannot drift) still finds no mise after that install step, `update`
  skips slot 04 in both removal loops and skips the strip, warns, and
  exits non-zero, leaving every other removal slot to apply normally.

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
  Runs `scripts/verify.sh` (per-Install-file verification) and then
  `scripts/collision_check.sh` to detect **same-tier collisions**: a
  package listed in BOTH `<tier>/Install/NN-Install.suffix` AND
  `<tier>/Uninstall/NN-Uninstall.suffix` (or
  `<tier>/RemoveAndPurge/NN-RemoveAndPurge.suffix`) at the same tier.
  Same-tier collisions are bugs (`make update` would just undo the
  install); cross-tier collisions are intentional ("opt out at a
  more-specific tier") and are not reported. Exits non-zero if any
  Install entries are missing OR any same-tier collisions are found.

- `make sanitize`
  Resolves the same-tier collisions reported by `make verify` by
  commenting out the offending lines in the `Install/` files (the
  `Uninstall/` or `RemoveAndPurge/` peer wins per the conflict rule
  in `docs/INSTALL.md`). Writes a `.bak` next to each edited file
  and prints a summary. Review the diff (e.g. `git diff`), commit,
  and remove the `.bak` files when satisfied.

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
  skipped with a warning). Called automatically by `make ai` and the
  `make install` per-target dispatcher for `17-Install.ai`.

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

- `make help`
  Lists all available targets, including dynamically generated ones.

## Per-Install Targets

Each `Install/NN-Install.<suffix>` has its own make target, named after
its filename. For example:

```bash
make 01_Install_security
make 03_Install_shell
make 04_Install_versionmanagers
```

Both the canonical underscore form (`01_Install_security`) and the
dotted basename (`01-Install.security`) work. There are also short
suffix and numeric aliases:

```bash
make security        # same as 01_Install_security
make 01              # same as 01_Install_security
```

These let you apply only a subset of the environment.

Each per-Install target is failure-tolerant across all three tiers,
the same way `make install` is: it applies the slot at the default
tier, then each of the host's profiles in list order, then the host
tier, attempting every tier even if an earlier one's `brew bundle`
fails. Failed tiers are accumulated and reported in an end-of-run
summary, and the target exits non-zero if any tier failed (otherwise
it exits 0 with no summary). A failing cask in one tier therefore
never silently skips the other tiers of the same slot. The slot's
post-install setup action (e.g. Hammerspoon for `ui`, mise for
`versionmanagers`) runs only when the brew-bundle tiers all succeed,
unchanged from before. Per-slot targets honour `VERBOSE=1` the same
way `make install` does — the per-tier "not found" lines are quiet by
default and restored with `VERBOSE=1` (see `make install` above).

## Per-Uninstall Targets

Symmetrically, each `Uninstall/NN-Uninstall.<suffix>` has its own
target. These targets execute real uninstall operations; rehearse
with `DRY_RUN=1` first to confirm what will happen:

```bash
make 01_Uninstall_security DRY_RUN=1   # rehearsal: prints actions, no changes
make 01_Uninstall_security             # real run
make 07_Uninstall_browsers DRY_RUN=1   # rehearsal
make 07_Uninstall_browsers             # real run
```

Each per-Uninstall target walks the default → profiles (list order) →
host tiers and runs `scripts/remove_runner.sh --mode=uninstall`
against whichever tiers contain the matching slot. Setting `DRY_RUN=1`
on the command line forwards `--dry-run` to the runner. A slot+tier
whose file has no active `brew`/`cask`/`mas` directive prints nothing
by default (see the empty-slot gating under `make uninstall` above);
`VERBOSE=1` restores its banner and `Processing`/`Done` lines.

## Per-RemoveAndPurge Targets

Each `RemoveAndPurge/NN-RemoveAndPurge.<suffix>` likewise has its
own target. **These targets are destructive: they pass `--zap` to
cask uninstalls, which also removes the cask's declared user data
(preferences, caches, support files, login items). ALWAYS rehearse
with `DRY_RUN=1` first** to confirm what will happen:

```bash
make 07_RemoveAndPurge_browsers DRY_RUN=1   # rehearsal: prints actions, no changes
make 07_RemoveAndPurge_browsers             # real run; --zap on casks
```

Each per-RemoveAndPurge target walks default → profiles (list order)
→ host and
runs `scripts/remove_runner.sh --mode=purge` against whichever tiers
contain the matching slot. The `--mode=purge` flag adds `--zap` to
cask uninstalls so the cask's declared user data is also removed.
Setting `DRY_RUN=1` on the command line forwards `--dry-run` to the
runner; this is the supported safe-rehearsal pattern for per-file
RemoveAndPurge targets. A slot+tier whose file has no active
`brew`/`cask`/`mas` directive prints nothing by default (see the
empty-slot gating under `make uninstall` above); `VERBOSE=1` restores
its banner and `Processing`/`Done` lines.

The runner is shared with the per-Uninstall targets. It accepts
`--mode={uninstall|purge}` (default `uninstall` for backward
compatibility); the Makefile passes the flag explicitly at every
call site so no caller relies on the default.

## Special Cases

These per-Install targets also run a follow-up setup script:

- `make 02_Install_ui`
  Applies UI tools and then sets up Hammerspoon configuration.

- `make 03_Install_shell`
  Applies shell tools and then runs `scripts/shell_setup.sh`.

- `make 04_Install_versionmanagers`
  Applies version managers and then runs `scripts/versions_setup.sh
  full`: ensures the global mise config exists (importing
  `~/.tool-versions` when the host has one), ensures
  `[settings] env_file = ".env"` in it, then installs the tool
  versions the resolved config declares.

- `make 06_Install_messaging`
  Applies messaging tools and then generates `~/.msmtprc` from the
  resolved `config.toml` `[mailer]` values.

- `make 09_Install_development`
  Applies dev tools, installs VS Code extensions, and symlinks VS Code
  config.

- `make 11_Install_aws`
  Applies AWS tools and runs CDK setup.

- `make 17_Install_ai`
  Applies AI tools, installs Cursor extensions, disables Claude
  auto-updates (`scripts/claude_disable_autoupdater.sh`), and runs
  `scripts/claude_repo_setup.sh install` to clone or update
  `~/.claude/` from the global Claude config repo and sync Claude
  plugins via `~/.claude/plugins.sh --install` (same as
  `make claude-install`).

## Version management

Additional targets exist to manage runtimes explicitly. They are named
`versions-*` rather than after the tool that implements them (mise),
so swapping the implementation leaves the target names, their callers,
and the doc lines that reference them alone — the change is bounded to
the scripts that name the tool directly
(`scripts/versions_setup.sh`, `scripts/mise_common.sh`, and the
shell/launchd `PATH` lines in `scripts/shell_setup.sh` and
`scripts/launchagent_runner.sh`):

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
