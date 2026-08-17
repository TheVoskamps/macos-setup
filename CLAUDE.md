# CLAUDE.md - macOS Setup

This file provides project-specific guidance for the
macOS setup repository.

## Repository Overview

This is a comprehensive macOS development environment
setup repository. Every TIER — the core tier, each
profile the host opts into, and the external host tier —
contributes one unnumbered Homebrew `Brewfile` plus a
`[profile]` section in its `config.toml` declaring its
`post_install` commands and its `uninstall` / `purge`
package lists. Those removal arrays drive cleanup AND a
smart filter on `make install`: `uninstall` removes the
binary, `purge` also removes the cask's declared user data
via `--zap`.

### Key Architecture Concepts

1. **One Brewfile per tier**, unnumbered and unprefixed:
   `default/Brewfile` (core), `profiles/<name>/Brewfile`,
   `<host-tier>/Brewfile`. The profile IS the category
2. **A profile-driven Makefile with no per-profile
   knowledge**: `make install` (every tier), `make core`
   (the core tier), `make profile <name> [<name>...]`
   (named profiles, in the order given), `make profiles`
   (list). Adding `profiles/brand-new/` needs no Makefile
   edit
3. **Layered configuration**: a host opts into N
   ordered profiles. Priority, lowest to highest:
   `default/` (global, in repo) <
   `profiles/{name}/` (in host-declared order, in repo) <
   the **external host tier** on local disk. The repo
   tracks only `default/` and
   `profiles/`; the per-host tier lives OUTSIDE the repo
   at `${XDG_CONFIG_HOME:-~/.config}/macos-setup/`
   (overridable via `MACOS_SETUP_HOST_DIR`). See
   `host_tier_dir` in `scripts/config_common.sh`.
4. **Version pinning** via `mise.toml` ensures
   reproducible environments
5. **Post-install automation** for UI, shell, VS Code,
   Claude, AWS CDK, and Hammerspoon
6. **Workspace management** via Hammerspoon (window
   sorting, workspace launching, and monitor management)
7. **Modular Hammerspoon architecture** with shared
   modules (`modules/config`, `modules/monitors`,
   `modules/positions`, `modules/screen_focus`,
   `modules/spaces`, `modules/launcher`,
   `modules/sorter`, `modules/windows`,
   `modules/utils`) and app
   launcher modules (`modules/apps/iterm`,
   `modules/apps/vscode`, `modules/apps/finder`,
   `modules/apps/safari`) under
   `default/.hammerspoon/modules/`

### Configuration Hierarchy

A host opts into **N ordered profiles**. The resolution
order, lowest to highest priority:

```text
default/   (global base, in repo)
  < profiles/{name}/         (each profile, in host-declared order, in repo)
      < external host tier    (on local disk, OUTSIDE the repo)
```

The in-repo tree keeps only `default/`
and `profiles/`. The per-host tier lives OUTSIDE the
repo at the path returned by `host_tier_dir` in
`scripts/config_common.sh` — by default
`${XDG_CONFIG_HOME:-~/.config}/macos-setup/`, overridable
via the `MACOS_SETUP_HOST_DIR` environment variable (the
test suite uses this to point the host tier at a temp
dir). Only the host tier's **location** moved out of the
repo; the resolution **order** is unchanged.

`make install` seeds the external host tier from the
in-repo template (`computer-specific/_template/`) **only
if the external dir is absent** — it never overwrites
your edits, and re-running after it exists is a no-op.
Backing up / syncing that external directory is your
responsibility. The external tier carries `config.toml`
(the consolidated scalar config — `profiles` array plus
`[claude]`, `[mailer]`, `[cron]` sections), `aliases.zsh`,
`.hammerspoon/*`, `.vscode/settings.json`, an optional
`Brewfile`, `.cdk.json`.

The per-host selector is the `profiles` array in the
external host tier's `config.toml` — an ordered list,
lowest priority first (last entry wins). A host with no
`profiles` array collapses to `default < host`. The
`profiles` array is the one aggregate scalar key: a
default-tier array is prepended to the host's, deduped
keeping the last occurrence. `config.toml` is queried with
`dasel`, a hard runtime dependency that must be **exactly
major version 3** (the v2->v3 jump was a total breaking
change and a future v3->v4 break would be too). `bootstrap.sh`
installs and version-verifies dasel; the read layer in
`scripts/config_common.sh` re-asserts v3 at runtime
(`require_dasel_v3`, memoized once per process), so a non-v3
dasel — v2, v4+, missing binary, or unparseable `dasel
version` output — hard-aborts the whole `make`/config read
loudly rather than silently yielding empty values.

How a file resolves depends on its **kind** (declared
centrally in `scripts/config_common.sh`):

- **Single-winner** (the highest tier that has the file
  wins): `.vscode/settings.json`, `.hammerspoon/*`, and
  each scalar section of `config.toml` (`[claude]`,
  `[mailer]`, `[cron]`). `config.toml` sections resolve
  via `resolve_config_value`; other single-winner files
  via `resolve_file` / `resolve_dir` (external host >
  reverse(profiles) > default).
- **Aggregate** (every tier contributes, concatenated
  in `default -> profiles(order) -> host`):
  `aliases.zsh`, plus each tier's `Brewfile` and
  `[profile]` section. `aliases.zsh` uses
  `resolve_aggregate`; the Brewfiles and `[profile]`
  sections aggregate via the Makefile /
  `scripts/apply_tier.sh` / `install_filter.sh` tier
  walk.

- **Brewfile**: Additive across all tiers (core + every
  profile in order + host), but each layer is filtered
  against the in-scope `[profile] uninstall` AND
  `[profile] purge` arrays before `brew bundle` consumes
  it
- **`[profile]`**: the one config.toml section that is
  NEVER resolved across tiers. `[claude]`/`[mailer]`/
  `[cron]` answer "what is the value for this host", so
  the highest tier with a value wins; `[profile]` answers
  "what does THIS tier contribute", so every tier's
  section applies on its own, in tier order. Read with
  `read_post_install` / `read_removals`, not
  `resolve_config_value`
- **`uninstall`**: entries shadow that package for their
  own tier's Brewfile and every lower-priority tier's
  Brewfile (see `docs/INSTALL.md`). Removes the binary;
  leaves user data (preferences, caches, login items) on
  disk
- **`purge`**: same shape and tier rules as `uninstall`,
  but for casks the runner uses
  `brew uninstall --cask --zap`, which also removes
  the cask's declared user data. For formulae and MAS
  items, behavior is identical. Both modes share
  `scripts/remove_runner.sh` (selected via
  `--mode={uninstall|purge}`)
- **Config files**: single-winner (most-specific tier
  wins) unless listed as aggregate above
- **Profile selection**: the `profiles` array in the
  external host tier's `config.toml` (lowest priority
  first)

## Essential Commands Reference

### Initial Setup

```bash
./bootstrap.sh        # Install Homebrew, mas, dasel; HTTPS-clone the (public) repo
make install          # Apply every tier for this host, in order
```

`bootstrap.sh` also installs **dasel** (the `config.toml`
query primitive) and verifies it is **exactly major
version 3** — a non-v3 dasel fails the bootstrap step
loudly (the old `|| true` that swallowed install failures
is gone). v3 is a hard requirement of every config.toml
read: the v2->v3 jump was a total breaking change and a
future v3->v4 break would be too, so both v2 and v4+ are
rejected. The same v3 assertion is enforced at runtime by
`require_dasel_v3` in `scripts/config_common.sh` before
the first config.toml read, so essentially every `make`
target hard-aborts on a non-v3 dasel instead of breaking
silently.

A separate, earlier guard handles the **dasel-not-on-PATH**
case (issue #4). `dasel` is invoked by **bare name** by every
config read, but `bootstrap.sh` installs it into Homebrew's
bin and only appends the `brew shellenv` line to the profile —
that line takes effect in a NEW login shell. A user who runs
`./bootstrap.sh` then `make install` in the SAME shell has
dasel installed but unreachable by bare name, which used to
surface late and cryptically as a buried `dasel version exited
127` from `require_dasel_v3` partway into the first tier.
The `.PHONY: require-dasel` Makefile target (wired as a
prerequisite on the config-dependent batch targets `install`,
`update`, `verify`, `outdated`) runs
`scripts/require_dasel_on_path.sh` BEFORE host-tier seeding,
the recipe-level config reads, and any install work. On a miss
it prints `dasel not in PATH` plus new-shell remediation and
aborts up front. It is a **reachability** check only — it
honors the same `DASEL` override `config_common.sh` uses, does
NOT auto-install, and does NOT self-heal PATH; the exactly-v3
version assertion stays the job of `require_dasel_v3` at the
first real read.

One config read runs even before the prerequisite: the
`PROFILES := $(shell ... list_profiles.sh ...)` variable, which
make expands at **parse time**. A prerequisite can't gate a
parse-time expansion, so `list_profiles.sh` guards itself —
with dasel off PATH it mirrors the gate's reachability check
and short-circuits to an empty list, rather than letting
`require_dasel_v3`'s `kill -s TERM "$$"` print a `Terminated:
15` line ahead of the gate's clean error. The prerequisite plus
that self-guard make `Error: dasel not in PATH.` the sole
output on a no-dasel run.

### Development Workflow

```bash
# Apply tiers
make install                # every tier for this host
make core                   # the core tier only
make profiles               # list profiles (* = this host's)
make profile dev-core aws   # named profiles, in the order given

# Version management (mise). Targets are named
# `versions-*`, not after the tool, so swapping the
# implementation leaves target names and doc lines alone.
make profile version-managers  # Install mise + the global
                            # config (install ONLY -- see
                            # "Tool Version Configuration"
                            # for the full cutover)
make versions-install       # Install declared versions
make versions-outdated      # Check for newer versions
make versions-update        # Install latest AND bump the
                            # config (mise up --bump) --
                            # one verb, so the version it
                            # installs is the one active

# Prune unused installed versions (mise prune).
make versions-cleanup-dry-run # Show what would be removed
make versions-cleanup         # Remove them
# Note: versions-cleanup also runs automatically after
# versions-update as part of 'make update'.

# One-shot migration verb (deliberate exception to the
# implementation-neutral naming): convert the CALLING
# repo from asdf+direnv to mise. Purely additive --
# deletes, moves, untracks, and commits nothing.
make asdf-to-mise
```

### Workspace Management

```bash
# Unified ws dispatcher (via Hammerspoon IPC)
ws macos-setup            # Launch workspace
ws lg-left                # Launch a monitor's app set
ws left                   # Launch monitor at position "left"
ws                        # Inline help: workspaces + monitors
ws close <name>           # Close (workspace | monitor | position)
ws restart <name>         # Close + relaunch
ws screens                # List connected screens
ws fix                    # Re-sort all windows

# Reserved words (cannot be used as workspace/monitor/position names):
#   close, restart, screens, fix, (empty string)
# Validation runs on Hammerspoon load; collisions show a blocking dialog
# and disable the dispatcher globals until resolved.

# Launch via URL handler
open "hammerspoon://launchWorkspace?name=macos-setup"

# Window management (via Hammerspoon)
# Ctrl+Alt+Cmd+R          Re-sort all windows
# Ctrl+Alt+Cmd+1/2/3      Switch workspace Space
# Ctrl+Alt+Cmd+Shift+L    List connected screens
# Ctrl+Alt+Cmd+Shift+R    Reload Hammerspoon config

# Monitor switching
# Ctrl+Alt+Cmd+Tab         Cycle through monitors
# Ctrl+Alt+Cmd+Left/Right/Up/Down
#                          Focus monitor by `position`
#                          field in monitors.json

# IPC commands (from terminal)
# hs -c "listScreens()"         List monitors
# hs -c "resortAllWindows()"    Re-sort windows
# hs -c "launchWorkspace('x')"  Launch workspace
# hs -c "closeWorkspace('x')"   Close workspace windows
# hs -c "restartWorkspace('x')" Close + relaunch a workspace
# hs -c "listWorkspaces()"      Inline ws help (workspaces + monitors)
```

### Claude Configuration Management

`~/.claude/` is a real git checkout of
`https://github.com/TheVoskamps/claude-config.git`,
not a tree of symlinks into `macos-setup`. Fresh clones use the
HTTPS URL (most users won't have an SSH key registered on the
org/repo); an existing clone whose `origin` is the SSH form is
recognized as ours and its SSH origin is left intact (not
rewritten to HTTPS). The active branch and
the SSH host alias used in the git remote URL are selected from the
single-winner `[claude]` section of `config.toml` (host >
the host's profiles in reverse list order > default; the
highest tier with a non-empty value for a key wins, no per-key
merge). The `[claude]` section accepts these optional keys:

- `branch = "<name>"` -- git branch to check out in `~/.claude/`.
  Missing or unknown branch falls back to the global repo's
  default branch (resolved dynamically via
  `git ls-remote --symref origin HEAD`).
- `hostname = "<ssh-alias>"` -- SSH host alias used when deriving the
  git remote URL (`git@<alias>:TheVoskamps/claude-config.git`).
  Lets `~/.ssh/config` pick a per-machine IdentityFile. Defaults
  to `github.com`.

The default-tier file lives at
`default/config.toml` (all `[claude]` fields
commented out as in-place documentation).

```bash
make claude-install   # Clone (or migrate from old layout); switch to
                      # the [claude]-resolved branch; pull --ff-only;
                      # then sync plugins (plugins.sh --install)
make claude-update    # Update an existing clone (errors if missing);
                      # then sync plugins (plugins.sh --update)
make claude-outdated  # Read-only: show pending pulls/pushes + dirty
                      # files in ~/.claude/
make claude-plugins-install  # Sync plugins only: ~/.claude/plugins.sh
                             # --install
make claude-plugins-update   # Sync plugins only: ~/.claude/plugins.sh
                             # --update
```

`make install` and `make profile claude` call `claude-install`
automatically
as part of the `claude` / `claude-latest` profiles'
`post_install`.
`make update` runs `claude-update` and `make outdated` runs
`claude-outdated` alongside the existing brew/tool-version checks.

**Plugin sync:** the global Claude config repo ships its own
`plugins.sh` at the repo root (`~/.claude/plugins.sh` once cloned),
which registers the marketplaces in `extraKnownMarketplaces` and
installs/updates the plugins in `enabledPlugins` from the clone's
`settings.json`. macos-setup only **calls** that script; the
`settings.json` parsing and `claude plugin ...` invocations live in
the claude-config repo. After the clone/migration completes,
`claude-install` runs `~/.claude/plugins.sh --install` and
`claude-update` runs `~/.claude/plugins.sh --update`. Both inline
calls are **non-fatal**: if the `claude` CLI is not on PATH, if
`~/.claude/plugins.sh` is missing (an older claude-config checkout
predating the plugins refactor), or if `plugins.sh` exits non-zero,
the sync prints a warning and is skipped/ignored rather than aborting
`make install` / `make update` (same posture as the
`git pull` step). The two standalone targets `claude-plugins-install`
/ `claude-plugins-update` drive the same code path directly and DO
surface a `plugins.sh` non-zero exit (the missing-binary /
missing-script guards still warn-and-skip with success). Both the
inline calls and the standalone targets route through a single
`claude_repo_setup.sh` sub-command (`plugins-install` /
`plugins-update`) so "how we locate and invoke `plugins.sh`" lives in
one place.

**macOS quirk (issue #122):** `git` network ops
(`ls-remote`, `clone`, `fetch`, `pull`) can hang ~2 minutes on
macOS when the shell's cwd has any descendant path that's the
absolute target of a symlink elsewhere on disk and macOS has
metadata for that target. The mechanism is undocumented (likely
something path-keyed inside Spotlight, APFS snapshots, fseventsd,
or an EDR/MDM agent). `claude_repo_setup.sh` and
`claude_repo_common.sh` sidestep the trigger by running each
network op from a fresh `mktemp -d` cwd via the `git_in_safe_cwd`
helper, leaving the caller's cwd untouched.

### Maintenance

```bash
make outdated  # Check outdated packages/tools
make update    # Update Homebrew/packages/tool versions,
               # prune unused versions (versions-cleanup),
               # then apply every tier's uninstall + purge
make verify    # Verify installations + check for
               # same-tier Brewfile/uninstall+purge
               # collisions
make sanitize  # Resolve same-tier collisions by commenting
               # out the offending Brewfile line (writes .bak)
make diagnose  # Run system diagnostics
```

## Special Behaviors to Know

### Automatic Post-Install Actions

- **core tier** -> Runs `scripts/core_setup.sh`:
  sets computer/host names, and appends two grep-guarded
  exports to `~/.zshrc` — `HOMEBREW_NO_AUTO_UPDATE=1`
  and `HOMEBREW_NO_ASK=1` (the latter disables Homebrew
  6.0+ interactive ask-mode so `make update` / `make
  install` don't hang on a `[y/n]` prompt — issue #20)
- **core tier** -> Runs `scripts/shell_setup.sh`
- **core tier** -> Runs `scripts/msmtp_setup.sh`, which
  generates `~/.msmtprc` from `config.toml` `[mailer]`
- **`desktop-ui` profile** -> Runs
  `scripts/hammerspoon_setup.sh`
- **`version-managers` profile** -> Runs
  `scripts/versions_setup.sh full`: ensures the global
  mise config (importing `~/.tool-versions` when
  present) plus `[settings] env_file = ".env"`, then
  installs the declared tool versions. Under
  `make install` (NOT under
  `make profile version-managers`) that tier's `purge`
  array is then applied inline, so
  the asdf -> mise cutover cannot land half-applied —
  but only if the shared `MISE_REACHABLE` probe finds a
  reachable mise at that moment; otherwise the purge is
  skipped, the run warns, and `make install` exits
  non-zero — see "Tool Version Configuration"
- **`visual-studio-code` profile** -> Installs VS Code
  extensions, then symlinks `.vscode/settings.json`
- **`cursor` profile** -> Installs the same extension set
  into Cursor
- **`aws` profile** -> Runs `scripts/cdk_setup.sh`
- **`claude` / `claude-latest` profiles** -> Run
  `claude_disable_autoupdater.sh` (which turns off both
  the CLI's `autoUpdates` setting and sets
  `DISABLE_AUTOUPDATER=1` in `~/.zshrc`), then
  `claude_repo_setup.sh install` to clone or update
  `~/.claude/` from the global Claude config repo and
  sync Claude plugins via `~/.claude/plugins.sh
  --install` (non-fatal; skipped with a warning if the
  `claude` CLI or `plugins.sh` is absent)

Each hook lives with the tier that installs the software
it configures. A host that does not opt into `desktop-ui`
therefore no longer runs the Hammerspoon setup, which used
to be unconditional, because an empty `02-Install.ui`
slot existed at the default tier under the old
convention. A missing, non-executable, or
failing `post_install` command is reported and tracked,
never fatal — the run continues and the end-of-run summary
names the tier.

### Layered Configuration Resolution

All configuration uses `scripts/config_common.sh` for
consistent resolution. The tier order, lowest to
highest priority:

1. **default/**: global base for all
   machines, in repo (lowest priority)
2. **profiles/{name}/**: each profile the host opts
   into, applied in host-declared order, in repo (a
   later profile in the list outranks an earlier one)
3. **external host tier**: machine-specific overrides on
   local disk, OUTSIDE the repo (highest priority), at
   `${XDG_CONFIG_HOME:-~/.config}/macos-setup/` (override
   with `MACOS_SETUP_HOST_DIR`). See `host_tier_dir` in
   `scripts/config_common.sh`.

The per-host profile list lives in the `profiles` array
of the external host tier's `config.toml` (lowest priority
first).

**Single-winner files** (`.vscode/settings.json`,
`.hammerspoon/*`) resolve via `resolve_file` /
`resolve_dir`: the highest tier that has the file wins
(host > reverse(profiles) > default). The scalar config
sections (`[claude]`, `[mailer]`, `[cron]`) in
`config.toml` resolve single-winner per key via
`resolve_config_value` (same precedence), queried with
`dasel`. Every dasel read first runs `require_dasel_v3`,
which asserts the dasel on PATH is exactly major v3 and
hard-aborts loudly otherwise (see the "Initial Setup"
note on dasel).

**Brewfiles** aggregate across every tier — core,
each profile in order, then host. Each layer is run
through the smart filter (`scripts/install_filter.sh`)
before `brew bundle` consumes it, so any package listed
in an in-scope `[profile] uninstall` or `[profile] purge`
array is commented out. The filter also has one side effect:
for every `tap '<name>'` directive that survives
filtering into the emitted file it runs
`brew trust --tap '<name>'` first (Homebrew 6.0 requires
trusting third-party taps, else `brew bundle` silently
skips their packages and exits 0 — issue #172). The
trust is idempotent and conservative — a tap is trusted
only if its own `tap` line still emits.

Every binary these paths shell out to is overridable by
an env var of the same name, all in the one form
`VAR="${VAR:-default}"`, all defaulting to whatever is
on PATH: `BREW` (the brew binary, honored by
`apply_tier.sh`'s `brew bundle` call,
`install_filter.sh`'s `brew trust` call and by
`remove_runner.sh`), `MAS` (the mas binary) and `SUDO`
(the sudo that drives it), both honored by
`remove_runner.sh`. In `remove_runner.sh` that means
EVERY call — the `brew list` / `mas list` probes as well
as the `brew uninstall`/`--zap` and `sudo mas uninstall`
calls, since a probe answered by the real binary is what
decides whether a real removal follows. `SUDO` is
overridable alongside `MAS` because the mas removal is
`sudo mas uninstall`: stubbing one half still runs the
other for real. The Makefile exposes `BREW` as a make
variable, and GNU make exports command-line variables
into every recipe's environment, so
`make remove-and-purge BREW=<stub> MAS=<stub>
SUDO=<stub>` reaches the runner for all three.
`scripts/test/remove_runner_brew_override_test.sh`
fails if a bare `brew`, `mas`, or `sudo` call is
reintroduced into the runner. See `docs/INSTALL.md`.

Two further invariants stop a removal run from
breaking its own later steps (issue #37).
`remove_runner.sh` exports `HOMEBREW_NO_AUTOREMOVE=1`,
so `brew uninstall`'s automatic `brew autoremove`
never cascades into a shared dependency — that
cascade is how uninstalling `asdf` once removed
Homebrew's `bash` formula mid-run. And every
Makefile recipe names bash as `$(BASH_BIN)`, the
absolute `/bin/bash` that `SHELL` is also set from,
rather than a PATH-resolved bare `bash` that would
die with `/bin/bash: /opt/homebrew/bin/bash: No such
file or directory` once that formula was gone. Every
script that re-invokes bash itself names `/bin/bash`
for the same reason: `shell_setup.sh` and
`claude_repo_setup.sh`, which run helper scripts, and
`ensure_mise_zshrc_lines.sh`, whose reachability probe
runs `/bin/bash -lc`.
`scripts/test/absolute_bash_test.sh` fails if either
invariant is dropped — it pins the
`HOMEBREW_NO_AUTOREMOVE` export and scans the Makefile,
`shell_setup.sh`, and `claude_repo_setup.sh` for a bare
`bash`.

A second Homebrew 6.0 quirk is **interactive ask-mode**
(issue #20): 6.0 made a `Do you want to proceed? [y/n]`
prompt the default for `install`/`upgrade`/`reinstall`
(and, via `brew bundle`'s default upgrade, for `bundle`
too), so an unattended `make update` / `make install`
hangs forever with no TTY. `HOMEBREW_NO_ASK=1` disables
it for every brew call with one lever. It is set in each
of the scopes below, because each has a distinct
environment that the others don't reach:

- **Interactive shell** — `scripts/core_setup.sh` (the
  core tier's first `post_install` action) appends a
  grep-guarded `export HOMEBREW_NO_ASK=1` to `~/.zshrc`,
  alongside the existing `HOMEBREW_NO_AUTO_UPDATE` export.
- **Scheduled jobs** — `scripts/launchagent_runner.sh`
  exports `HOMEBREW_NO_ASK=1` near the top. launchd does
  NOT source `~/.zshrc`, so the interactive export never
  reaches a LaunchAgent. Exporting it in the runner (not
  the plist's `EnvironmentVariables`) means existing
  schedules self-heal on the next repo pull with no
  `make schedule-*` re-run, and it covers every job
  routed through that single entry point.
- **Bootstrap** — `bootstrap.sh` prefixes `HOMEBREW_NO_ASK=1`
  onto its `mas` and `dasel` `brew install`/`upgrade`
  lines, because bootstrap runs before `~/.zshrc` gains
  the export.

The **`uninstall`** and **`purge`** arrays also aggregate
across tiers, but with a narrower filter scope (see
`docs/INSTALL.md`). A Brewfile is filtered against the
removal arrays of its own tier and every higher-priority
tier:

- `default/Brewfile` filtered against core + all
  profiles + host
- `profiles/{name}/Brewfile` against `{name}` + every
  profile listed after it + host
- `<host-tier>/Brewfile` against host only

Read inversely: a removal entry shadows the package in its
own tier and every LOWER-priority tier. That is what makes
"I opted into `web` but I don't want its Firefox"
expressible — put `uninstall = ["cask:firefox"]` under
`[profile]` in the host tier's `config.toml`.

**`aliases.zsh`** is an aggregate file: every tier that
has one is concatenated in `default -> profiles(order)
-> host` order, so zsh "last definition wins" lets a
higher tier override an earlier one. (Note: defining a
function whose name is an active alias from a lower tier
fails in zsh — `unalias <name>` first, e.g. for a `gbc`
function shadowing a `gbc` alias.)

### Profile Selection

Each machine opts into an ordered list of profiles via
the `profiles` array in the external host tier's
`config.toml`, lowest priority first (the last entry sits
just under the host tier):

```toml
# Profiles for this host, lowest priority first (last entry wins).
# Host-specific config always overrides everything listed here.
profiles = [
  "version-managers",
  "desktop-ui",
  "dev-core",
  "visual-studio-code",
  "aws",
  "databases",
]
```

Profiles are fine-grained and single-responsibility, so a
host composes the roles it wants by listing several (e.g.
`dev-core` + `dev-python` + `aws` + `databases`). Each name
must match a `profiles/{name}/` directory; an unknown name
is a hard error in `make verify` and a warning at install
time. A default-tier `profiles` array (if present) is
prepended to the host's array, deduped keeping the last
occurrence.

Machines with no `profiles` array skip the profile tier
entirely and fall back directly from the external host
tier to default (two-tier behavior, fully backward
compatible).

### Tier Execution Order

`make install` applies every tier for this host, in this
order:

1. `default/` — the core tier
2. `profiles/{name}/` for each profile in the host's
   `profiles` array, in list order
3. the external host tier

Applying a tier means: filter its `Brewfile` against the
in-scope removal arrays (per the tier rule above), feed the
result to `brew bundle`, then run its `[profile]
post_install` commands in declared order. All three apply
paths — `make install`, `make core`, and
`make profile <name>...` — route through
`scripts/apply_tier.sh`, so what "applying a tier" means
lives in exactly one place and they cannot drift.

`make install` and `make profile` are **failure-tolerant**:
a `brew bundle` failure, or a failing/missing `post_install`
command, on one tier does not abort the run. Both attempt
every tier, accumulate the ones that returned non-zero,
print an end-of-run summary listing each, and exit non-zero
if any failed. In the `install` loop that same accumulator
also takes a non-zero exit from the `version-managers`
purge applied inline, so such a failure lands in the summary
too. A purge that was HELD BACK by the `MISE_REACHABLE`
guard is tracked separately: it prints its own
`Skipped the asdf/direnv removal ...` line after that
summary, suppresses the success message, and also makes
the run exit non-zero. A clean `make install` exits 0 with
`All tiers applied.`; a clean `make profile` exits 0 with no
summary. `make update` was already failure-tolerant.

`make profile <name> [<name>...]` validates EVERY name
before applying ANY, so a typo in the fifth name aborts with
exit 2 rather than half-applying the first four. The
known-profile list is a directory glob, so adding
`profiles/brand-new/` needs no Makefile edit.

All apply paths are **quiet by default** about
non-contributing tiers: most tiers carry no `Brewfile` and
no `post_install` entries, and those negative-case lines
(`==> No Brewfile found at ...`, `==> No post_install
entries for ...`) are gated behind a `VERBOSE` env var so a
host that opts into many profiles is not buried under noise.
`VERBOSE=1 make install` restores them for debugging "why
didn't my profile apply?". The positive `==> Applying ...`
lines and every failure line always print. The gate lives in
`scripts/apply_tier.sh`, the single chokepoint, so the three
paths cannot drift.

`make uninstall` walks every tier in tier order applying
each tier's `[profile] uninstall` array. The companion
`make uninstall-dry-run` prints actions without executing.

`make remove-and-purge` walks the same tiers applying each
tier's `[profile] purge` array, invoking the shared
`scripts/remove_runner.sh` with `--mode=purge`, so casks are
uninstalled with `--zap` (also removes the cask's declared
user data). `make remove-and-purge-dry-run` is the dry-run
companion.

The removal paths are also **quiet by default about tiers
that remove nothing** (mirroring the install gating above).
Nearly every tier removes nothing, so a `make update` (which
runs both loops) used to print ~80 noise lines. The gate
keys on whether the tier's array FOR THE ACTIVE MODE has any
entry:

- Default (non-VERBOSE): a tier with an empty or absent
  array for that mode prints NOTHING — neither the
  Makefile's `==> Applying Uninstall|RemoveAndPurge: <tier>`
  banner, nor the runner's `[uninstall]/[purge] Processing
  <tier>` / `Done: <tier>` lines.
- A tier with at least one entry prints fully, INCLUDING
  `skip: <pkg> not installed` lines (those are genuinely
  useful).
- `VERBOSE=1` restores ALL lines for EVERY tier, including
  empty ones, for debugging.

The gate is per MODE, not per tier: a tier declaring only a
`purge` array stays silent during the uninstall pass.

This applies across ALL tiers, and therefore to every target
that invokes the removal loops: `make update` (whose
`% m update` output prompted issue #167), `make uninstall`,
`make remove-and-purge`, and their dry-run companions.
(`make install` does not run the removal loops in general,
so it is almost unaffected — its one exception, the
`version-managers` purge it applies inline, goes through the
same runner with the same `--banner`, so the gate covers it
too. See "Tool Version Configuration".)
The "does this tier remove anything?" decision lives in ONE
place — `scripts/remove_runner.sh`, the only code that reads
the array. The Makefile passes the banner text it would
otherwise have echoed itself via `--banner=<text>`, so the
banner and the runner's `Processing`/`Done` lines are
suppressed or shown together and can never disagree. Real
errors (malformed entries) still abort with a visible
message regardless of the quiet gate.

### Tool Version Configuration

Runtimes are managed by **mise**, installed by the
`version-managers` profile. The profile keeps its name:
`version-managers` is the role, not the implementation.

The cutover is hard, not staged: the same profile that
installs `mise` in its `Brewfile` removes `asdf` and
`direnv` in the `[profile] purge` array of its
`config.toml`, because asdf and mise both provide shims
for the same tools. Only the binaries go — `~/.asdf/`,
`~/.tool-versions`, `~/.config/direnv/lib/use_asdf.sh`
and every repo's `.envrc` / `.tool-versions` survive, and
`make asdf-to-mise` warns about each rather than deleting
it. The `~/.zshrc` work is a PAIR of scripts, so both
cutover paths do identical work:
`scripts/strip_asdf_zshrc_lines.sh` removes the
asdf/direnv init lines this repo once wrote, and
`scripts/ensure_mise_zshrc_lines.sh` adds
`export PATH="${XDG_DATA_HOME:-$HOME/.local/share}/mise/shims:$PATH"`
plus `eval "$(mise activate zsh)"` (the activation line
only when mise is reachable — this shell's `PATH`
first, then a fallback to the `/bin/bash -lc`
login-shell probe the `MISE_REACHABLE` Makefile macro
is, so the gate that removes asdf and the gate that
writes the activation line cannot disagree within one
run). `make shell_setup`
(`scripts/shell_setup.sh`) calls both, in that order, and
so does `make update` — which never runs
`shell_setup.sh`, so before issue #38 it stripped without
adding and left the host with no version manager wired
into the interactive shell.
`scripts/launchagent_runner.sh` puts the same shims
directory on `PATH` itself, because launchd never sources
`~/.zshrc`.

The cutover breaks into distinct pieces -- install mise,
uninstall asdf + direnv, strip the old `~/.zshrc` lines,
add the mise `~/.zshrc` lines -- each owned by a
different mechanism. `make install` and
`make update` each do all of them: `install` runs the
`version-managers` purge inline (a deliberate one-tier
exception to "install does not run the removal loops")
and reaches both `~/.zshrc` rewrites via the core tier's
`shell_setup.sh` action, while
`update` applies the `version-managers` tier itself
before the removal loops and calls
`strip_asdf_zshrc_lines.sh` and then
`ensure_mise_zshrc_lines.sh` directly because it never
runs `shell_setup.sh`. `update` needs that explicit
install step because `brew upgrade` upgrades an
installed formula but never installs an absent one, so a
host that never ran `make install` would otherwise lose
asdf and direnv and gain no mise. Install strictly
precedes remove, and BOTH paths gate the removal on the
same explicit probe -- the `MISE_REACHABLE` Makefile
macro, evaluated immediately before the destructive call
rather than left to the surrounding `set -e`. If mise is
still unreachable after the install step, `update` skips
the `version-managers` tier in both removal loops (via the
`REMOVE_SKIP_TIERS` Makefile variable, which the
batch removal loops honor) and skips both `~/.zshrc`
rewrites, while
`install` skips its inline `version-managers` purge;
both warn and exit non-zero, and every other tier
still applies. `scripts/test/install_cutover_guard_test.sh`
fails if the `install`-side guard is removed.
`make profile version-managers` does ONLY the install
piece -- per-profile application installs, it does not
remove. Driving it by hand is
`make profile version-managers`, `make remove-and-purge`,
`make shell_setup`.
See `docs/VERSION_MANAGEMENT.md`.

Per-project config is `mise.toml` -- the **one tracked
config form**. mise reads several other forms as well
(`mise.local.toml`, `mise/config.toml`,
`.mise/config.toml`, `.config/mise.toml`,
`.config/mise/config.toml`, `.config/mise/conf.d/*.toml`),
all merged with top winning, and the directory walk
recurses upward to the filesystem root WITHOUT stopping
at a git boundary -- so a stray `mise.toml` in a parent
directory silently applies to every repo beneath it.
The `.gitignore` block `make asdf-to-mise` writes ignores
every non-canonical form to keep that from happening.
The block's authoritative text is the heredoc in
`scripts/asdf_to_mise.sh`; this repo's own `.gitignore`
and the copy in `docs/VERSION_MANAGEMENT.md` reproduce
it verbatim. The paragraph here only describes it.
`mise cfg` is the diagnostic for "which files actually
loaded here".

The global config lives at mise's own default path,
`${XDG_CONFIG_HOME:-~/.config}/mise/config.toml`, and
carries `[settings] env_file = ".env"` -- the true
`dotenv_if_exists` analogue. (The alternative,
`[env] _.file`, resolves relative to the config file
that declares it, so in the global config it would look
for `~/.env`.) Accepted trade-off: the global setting
fires on mise's directory-change hook, so a new terminal
tab opened already inside the directory does not load
the `.env`.

mise's native version-prefix matching replaces the old
bespoke `filter` / `filter_exclude` DSL
(`java = "temurin"` selects the newest Temurin JDK; jre
builds are named `temurin-jre-*` and are not selected).
There is no native equivalent of a `max_version`
ceiling, and none is needed: the one ceiling this repo
carried was lua's, whose recorded intent was "stay below
Lua 5.5", so `lua = "5.4"` is the faithful translation.

**The LuaRocks pin.** LuaRocks 3.13.0 ships a rockspec
with a duplicate `tag` key. Under asdf's lua plugin that
broke the build, so this repo pinned 3.12.2 via
`ASDF_LUA_LUAROCKS_VERSION` -- the variable name that
plugin reads. `scripts/versions_setup.sh` still exports
`ASDF_LUA_LUAROCKS_VERSION=3.12.2` so every
`make versions-*` invocation carries it. On mise it is
currently INERT: verified against mise 2026.8.6 on
2026-08-16, `mise registry` resolves `lua` through
`vfox:mise-plugins/vfox-lua` first, not the asdf plugin,
and a sandboxed `mise install lua@5.4` built 5.4.8 and
bootstrapped LuaRocks 3.13.0 successfully with the
export set. It is kept because it costs nothing and
still applies to an explicit asdf-backend pin, where the
breakage is unchanged -- upstream
`luarocks/luarocks#1851` was closed by a fix to the
release tooling, and the shipped 3.13.0 tarball is
PGP-signed with a pinned `source_digest` and was never
re-rolled. Tracked in issue #6.

**`make asdf-to-mise`** is the one-shot migration verb
and a deliberate exception to the
implementation-neutral naming (it names both endpoints
on purpose, and is deleted once every repo and host is
over). It operates on the CALLING directory
(`START_DIR`), one repo per run, and is purely
additive: it ensures the global config, generates
`mise.toml` from `.tool-versions`, writes the
`.gitignore` block, and warns about every asdf/direnv
leftover -- while deleting, moving, untracking, and
committing nothing. It aborts if the target is not a
git repository root, and aborts (quoting the offending
line, writing no `mise.toml`) on a multi-version
`.tool-versions` line such as `java temurin 26.0.1+8`,
which mise's converter turns into a TOML array that
resolves as two separate installs. See
`docs/VERSION_MANAGEMENT.md` for the full runbook and
the manual cleanup checklist.

### Mailer Configuration

Email sending uses **msmtp**, a generic SMTP relay client.
There is one provider-agnostic backend: each user points
msmtp at their own relay (Gmail app-password, Fastmail,
their ISP, their own AWS SES SMTP credentials, etc.) via
the `[mailer]` section of `config.toml` (single-winner per
key: the highest tier with a value wins: host > the host's
profiles in reverse list order > default). Default config
lives in `default/config.toml`.

Keys under `[mailer]`:

- `backend` -- `msmtp` (default; the only supported value)
- `smtp_host` -- relay submission host
- `smtp_port` -- relay port (default `587`)
- `smtp_from` -- From address
- `smtp_user` -- relay username (also the Keychain
  account name)
- `keychain_service` -- Keychain service name for
  the relay password (default `msmtp`)

The dead `SES_*` fields from the removed SES backend are
gone, not migrated.

`make messaging` (`scripts/msmtp_setup.sh`) generates
`~/.msmtprc` (mode 0600) from the resolved `[mailer]`
values — it no longer symlinks a committed per-host file.
The relay **password is never committed** and never written
to `~/.msmtprc`; msmtp reads it from the login Keychain at
send time via a `passwordeval` line. The generated
`passwordeval` line, the `config.toml` template's
documented Keychain step, and the README
`security add-generic-password` example all reference the
SAME service name (`keychain_service`) and username
(`smtp_user`), so they stay in sync. `msmtp_setup.sh` warns
(does not fail) if the Keychain entry is missing.

To configure a machine, edit the `[mailer]` section of the
`config.toml` in your external host tier
(`${XDG_CONFIG_HOME:-~/.config}/macos-setup/config.toml`):

```toml
[mailer]
smtp_host = "smtp.example.com"
smtp_port = 587
smtp_from = "you@example.com"
smtp_user = "you@example.com"
```

then store the relay password in the Keychain (same
service + username) and run `make messaging`. See README.md
"Email Notifications" for the full setup and common-provider
examples.

All email paths (`mail_wrapper.sh`, `make email-test`,
LaunchAgent scheduled jobs via
`scripts/launchagent_runner.sh --mail`) route through
`scripts/send_mail.sh`, which reads this config. The
From address is resolved by `scripts/resolve_from.sh`
(prefers `[mailer] smtp_from`, else the `from` line in `~/.msmtprc`).

Scheduled LaunchAgents write their (non-emailed) output
to `~/Library/Logs/macos-setup/<job>.log` (e.g.
`daily-update.log`, `weekly-update.log`,
`now-update.log`, `email-test.log`) instead of the
former in-repo `logs/` directory. This is macOS-native
(Console.app surfaces these) and survives repo moves.

### Configuration Symlink System

**Shared zsh helpers (`~/.zsh-shared`)**:

- `shared/zsh/` holds system-level zsh helpers
  (`m`, `ws`, `iterm_tab_count`, `set_title`) that
  define how macos-setup itself works
- `scripts/shell_setup.sh` symlinks `shared/zsh/` to
  `~/.zsh-shared` and adds a single line to `~/.zshrc`:
  `for f in ~/.zsh-shared/*.zsh; do source "$f"; done`
- **NOT three-tier resolved** — single source of
  truth, direct symlink to `$REPO_ROOT/shared/zsh`
- `m()` and the LaunchAgent runner both resolve the
  repo root at runtime via `scripts/resolve_repo_root.sh`,
  which reads `readlink ~/.zsh-shared`. Single source
  of truth for runtime path resolution; no hardcoded
  paths in either caller. `m()` keeps an inline
  fallback for checkouts predating `resolve_repo_root.sh`.
- `shared/zsh/launchagent_runner` is a committed
  relative symlink to `../../scripts/launchagent_runner.sh`.
  Generated LaunchAgent plists embed
  `$HOME/.zsh-shared/launchagent_runner` as
  `ProgramArguments[0]`; the two-symlink chain
  (`~/.zsh-shared` -> `<repo>/shared/zsh`, then
  `launchagent_runner` -> `../../scripts/...`)
  resolves into the current checkout without baking
  the repo path into the plist. See Makefile
  `LAUNCHAGENT_RUNNER` for why a single
  `~/.zsh-shared/../scripts/...` form would not work
  (POSIX resolves `..` lexically against the symlink
  path).
- `aliases.zsh` is an **aggregate** file:
  `shell_setup.sh` concatenates default + each profile
  (list order) + host into a generated `~/.aliases.zsh`
  (a real file, not a symlink), so later tiers override
  earlier ones via zsh "last definition wins". Each tier
  carries the aliases that belong to it:
  - **`default/aliases.zsh`** — only
    truly universal shortcuts (navigation, `ll`, the
    `rm/cp/mv -i` safety aliases, `8601`) plus helpers
    for tools the default tier itself installs
    (fzf/zoxide/bat: `cdz`, `cdi`, `fe`, etc.). It is
    deliberately minimal so a non-development machine
    never inherits tool-specific aliases.
  - **`profiles/<name>/aliases.zsh`** — aliases for the
    tool that profile adopts. The git shortcuts, log
    variants, `*h` help-greppers, and the `gbc`/`gbd`/
    `gsr` functions live in `profiles/dev-core/aliases.zsh`
    (dev-core also re-asserts `brew 'git'` in its
    own `Brewfile`, even though the git binary
    is already installed by the default tier for
    bootstrap). The `cr` Claude-CLI wrapper and its
    `cr-repo` companion live in
    `profiles/claude-code-aliases/aliases.zsh` — a
    no-software profile that exists only to carry those
    functions, opted into alongside a `claude`/`claude-latest`
    profile. `cr` works from any cwd: when the cwd is inside an
    existing repo (root OR a subdirectory) it `cd`s to the repo
    root and derives the session name from `origin`; when the cwd
    is outside any repo it `git init`s a throwaway repo, runs
    claude, and removes only the `.git` it created via a
    function-local trap (EXIT plus INT/TERM) on every return path.
    `cr-repo` is the strict variant: it requires an existing repo
    with an `origin` remote (deriving the session name from it) and
    errors otherwise.
  - **Per-machine host `aliases.zsh`** — only genuinely
    host-specific entries (e.g. an `icloud` shortcut to a
    machine's iCloud Drive path, or a host-only workspace
    helper).

**Home Directory (`~/.claude/`)**:

- `make install` (and `make profile claude`, via the
  `claude` / `claude-latest` profiles' `post_install`)
  clones
  `https://github.com/TheVoskamps/claude-config.git`
  into `~/.claude/`, then switches to the branch named by
  the single-winner `[claude]` section of `config.toml`
  (host > the host's profiles in reverse list order >
  default; `branch` key). Fresh clones use the HTTPS URL
  (most users won't have an SSH key on the org/repo); an
  existing SSH-origin clone is recognized as ours and its
  SSH origin is left intact.
- Missing or unknown branch falls back to the global
  repo's default branch (resolved at run time via
  `git ls-remote --symref origin HEAD`).
- The default-tier config file lives at
  `default/config.toml` and ships
  with both `[claude]` keys commented out as in-place
  documentation. Override per-host by editing the
  `[claude]` section of `config.toml` in your external
  host tier
  (`${XDG_CONFIG_HOME:-~/.config}/macos-setup/config.toml`,
  seeded from the template), or per-profile at
  `profiles/<profile>/config.toml`. Resolution is
  per-key single-winner (highest tier with a value wins,
  no per-key merge across tiers).
- Optional `hostname = "<ssh-alias>"` key rewrites the git
  remote URL to `git@<alias>:...` so `~/.ssh/config` can
  pick a per-machine IdentityFile. Defaults to
  `github.com`. A non-default `hostname` against an
  existing default-host clone is reconciled by
  rewriting `origin` on the next `make claude-install`
  / `make claude-update` run (idempotent).
- Any existing `~/.claude/` that isn't a clone of the
  target repo is migrated in place: the directory is
  moved aside as `~/.claude.orig.<ts>`, the global
  repo is cloned in fresh, and the captured contents
  are overlaid back on top (excluding `.git`, local
  wins). Per-entry rules: regular files overwrite the
  clone; valid symlinks carry forward as symlinks;
  broken symlinks are skipped with a warning (the
  clone's file at the same name survives, and the
  broken symlink stays in `.claude.orig.<ts>/`);
  directories deep-merge with local wins. Overlaid
  files appear as dirty in `git status` so the user
  can decide to commit, branch, or discard.
- After the clone/migration completes, the install /
  update flow syncs Claude plugins by invoking the
  clone's own `~/.claude/plugins.sh` (`--install` on
  install, `--update` on update). That script registers
  the marketplaces in `extraKnownMarketplaces` and
  installs/updates the plugins in `enabledPlugins` from
  the clone's `settings.json`; macos-setup only calls
  it. The inline sync is non-fatal — a missing `claude`
  CLI, a missing `plugins.sh` (older checkout), or a
  `plugins.sh` failure warns and skips rather than
  aborting the run.
- See `make claude-install` / `make claude-update` /
  `make claude-outdated` /
  `make claude-plugins-install` /
  `make claude-plugins-update`.

**Claude Code Hooks (`~/.claude/hooks/`)**:

- Hook scripts ship with the global Claude config
  repo (`https://github.com/TheVoskamps/claude-config.git`),
  which is cloned into `~/.claude/` by
  `make claude-install`. Settings under
  `~/.claude/settings.json` register them with
  Claude Code.
- `auto-approve-compound-commands.sh` registered
  on `PermissionRequest` and `PreToolUse` for Bash
- On `PreToolUse`, returns a `deny` verdict for the
  forbidden command shapes below (anywhere in a compound,
  anchored to start-of-string or an operator
  boundary `&&`, `||`, `;`, `|`):
  - `cd <path> && <command>` — the
    CVE-2025-59536 hardcoded harness gate prompts
    on this regardless of hook approvals
  - `git -C <abs-path> <subcommand>` — the harness
    prompts on these even when the hook returns
    `allow` (cause not yet diagnosed; see #78)
  The deny message names the correct two-call
  form (`cd <path>`, then the bare command) so
  the agent self-corrects. See the
  `git-workflow.md` rule in the global repo.
- Splits compound commands (`&&`, `||`, `;`, `|`)
  and checks each part against the `settings.json`
  allow-list
- Strips trailing `/dev/null` redirections (e.g.
  `2>/dev/null`) before matching; redirections to
  real files require manual approval
- Auto-approves `cd` to paths under the repo root
  (absolute paths without `..` pass the prefix
  check even if the directory doesn't exist yet,
  supporting worktree and new-directory paths)
- Falls through to normal approval for unrecognized
  commands
- `claude-island-state.py` sends session state to
  ClaudeIsland.app via Unix socket at
  `/tmp/claude-island.sock`. Registered on
  `SessionStart`, `UserPromptSubmit`, `Stop`,
  `Notification`, `PreCompact`, and `SessionEnd`;
  for `PermissionRequest` it blocks up to 5 minutes
  waiting for the app's allow/deny decision and
  returns the verdict to Claude Code

**Per-repo config for `/issue:address`
(`.claude/rules/repo-config.md`)**:

- The only file under `.claude/` that is tracked
  in git (via a `.gitignore` negation). Everything
  else under `.claude/` remains ignored.
- Read by `/issue:address` and the issue-*
  subagents (`issue-developer`, `issue-fixer`,
  `doc-updater`, `pr-reviewer`) at the start of
  every run; each aborts if the file is missing.
- Front-matter selects VCS (`source-control`),
  issue tracker (`issues`), issue link prefix
  (`issue-link-prefix`), source/target branches
  (`default-issue-source-branch`,
  `default-pr-target-branch`), and branch-name
  style (`issue-branch-naming-prefix`).
- Alternate examples (e.g. a CodeCommit + Jira repo
  on `integ` with initials branch prefix) live in
  the global Claude config repo under
  `repo-examples/<repo-name>/rules/repo-config.md`.

**Subagent scratch sandboxes (`.claude/tmp/`)**:

- `issue-developer` and `issue-fixer` subagents
  must put all scratch work, test fixtures, and
  throwaway artifacts under
  `.claude/tmp/<task-slug>/` (e.g.,
  `.claude/tmp/issue-67-self-update/`).
- `.claude/` is gitignored except for the
  whitelisted entries in the repo-root
  `.gitignore` (e.g. `.claude/rules/repo-config.md`,
  shareable `agents/`, `commands/`, `hooks/`,
  `rules/`, `skills/`, etc.); `tmp/` stays ignored,
  so artifacts won't get committed.
  `Read`/`Edit`/`Write` of `.claude/tmp/**` is
  allow-listed in the global Claude config repo's
  `settings.json` (cloned into `~/.claude/`).
- Never use `/tmp/`, `/var/tmp/`, the user's home
  directory, or any path outside the repository.
- Clean up the sandbox after the task succeeds;
  leave it in place if the task fails so it can
  be examined.

**Local Repository (`./.claude/`)**:

- `./.claude/` is gitignored except for the
  whitelisted entries listed in `.gitignore`. The
  most important tracked file is
  `.claude/rules/repo-config.md` (the per-repo
  config consumed by `/issue:address`).
- This directory is for repo-scoped Claude config,
  separate from `~/.claude/` (the global repo
  clone). Don't confuse the two.

**Hammerspoon (`~/.hammerspoon/`)**:

- The `desktop-ui` profile's `hammerspoon_setup.sh`
  post-install action symlinks init.lua, monitors.json,
  workspaces.json, and the `modules/` directory
  (which includes `modules/apps/` app launchers)
- Uses single-winner resolution (including
  `resolve_dir` for the modules directory): host > the
  host's profiles in reverse list order > default
- Backs up existing files before symlinking
- Also configures Ctrl+1-9 desktop switching
  shortcuts via `spaces_shortcuts_setup.sh`
- After re-pointing the symlinks, if Hammerspoon is
  running (gated on `pgrep`), `hammerspoon_setup.sh`
  reloads it via the `reload_hammerspoon` function
  (issue #18). It is robust against an IPC
  chicken-and-egg: `hs.ipc`'s message port is brought
  up by `require("hs.ipc")` INSIDE init.lua, so when
  init.lua is broken or has never loaded from the
  current checkout (e.g. a stale symlink) the IPC port
  is down — yet `hs -c "hs.reload()"` IS the IPC path.
  `reload_hammerspoon` tries IPC first (surfacing the
  real error, not swallowing stderr); on failure it
  falls back to an IPC-independent app relaunch
  (`killall Hammerspoon` + `open -a Hammerspoon`),
  which re-execs init.lua from the now-correct symlink
  and brings IPC back up, then confirms with a
  read-only liveness probe (`hs -c "true"`, NOT a second
  `hs.reload()`). The confirmation is a probe-with-retry
  loop, not a single fixed sleep: it polls every
  `HS_RELAUNCH_INTERVAL` seconds (default 1s) for up to a
  bounded `HS_RELAUNCH_TIMEOUT` total (default 15s),
  succeeding as soon as a probe passes, so a slow cold
  launch no longer false-negatives. If neither path
  works it prints a loud, multi-line stderr WARNING
  naming the menubar "Reload Config" manual step and
  the run exits non-zero (it no longer claims success
  with a soft `Note:`). The command names it drives
  (`hs`, `pgrep`, `killall`, `open`) and the retry-loop
  timing (`HS_RELAUNCH_INTERVAL` / `HS_RELAUNCH_TIMEOUT`;
  the legacy `HS_RELAUNCH_SETTLE` is still honored as an
  alias for the interval) are env-overridable so
  `scripts/test/hammerspoon_reload_test.sh` can stub
  them; sourcing the script (rather than executing it)
  returns early before the symlink work, exposing only
  those vars and `reload_hammerspoon`

## Key Scripts

| Script | Purpose |
| ------ | ------- |
| `config_common.sh` | Layered resolution; tier list; `[profile]` reads |
| `apply_tier.sh` | Apply ONE tier: filtered Brewfile + its `post_install` |
| `require_dasel_on_path.sh` | Up-front bare-name `dasel`-on-PATH gate |
| `list_profiles.sh` | Print this host's ordered profile list (one per line) |
| `host_tier_dir.sh` | Print external host-tier base path (Makefile helper) |
| `seed_host_tier.sh` | Seed external host tier from template if absent |
| `shell_setup.sh` | Configures zsh, Oh My Zsh; aggregates `aliases.zsh` |
| `mise_common.sh` | Global mise config helpers, sourced by the mise scripts |
| `versions_setup.sh` | Drives mise for `versions-*` and its own tier |
| `asdf_to_mise.sh` | One-shot additive asdf+direnv -> mise repo migration |
| `strip_asdf_zshrc_lines.sh` | Strips the ~/.zshrc lines the cutover orphans |
| `ensure_mise_zshrc_lines.sh` | Adds the mise ~/.zshrc shims/activate lines |
| `vscode_extensions.sh` | Installs VS Code extensions |
| `vscode_setup.sh` | Symlinks VS Code `settings.json` (single-winner) |
| `hammerspoon_setup.sh` | Symlinks HS config; robust reload (IPC + relaunch) |
| `spaces_shortcuts_setup.sh` | Configures Ctrl+1-9 desktop shortcuts |
| `msmtp_setup.sh` | Generates ~/.msmtprc from config.toml [mailer] values |
| `claude_repo_setup.sh` | Clone/update ~/.claude/; sync plugins.sh |
| `claude_repo_common.sh` | Branch resolution + stash helpers |
| `claude_disable_autoupdater.sh` | Turn off Claude self-update (CLI + zshrc) |
| `resolve_mailto.sh` | Resolves recipient, validates mailer |
| `mail_wrapper.sh` | Wraps command output into email |
| `send_mail.sh` | Central mail dispatch (msmtp) |
| `resolve_from.sh` | Resolves From address from config |
| `resolve_repo_root.sh` | Runtime repo-root resolver via `~/.zsh-shared` |
| `launchagent_runner.sh` | LaunchAgent entry point; per-job log file |
| `verify.sh` | Verifies each tier's Brewfile installations |
| `collision_check.sh` | Reports/fixes same-tier Brewfile/removal collisions |
| `install_filter.sh` | Filters a Brewfile vs in-scope removal arrays |
| `remove_runner.sh` | Runs one tier's uninstall/purge array (`--mode=...`) |
| `self_update.sh` | Safely pulls latest `main` (auto-stashes if dirty) |
| `diagnose.sh` | Runs system diagnostics |

All scripts are in the `scripts/` directory.

## Checking Installed Versions

To see what versions are currently installed and active:

```bash
mise ls              # All installed versions
mise ls <tool>       # Versions for a specific tool
mise ls --current    # Currently active versions
mise cfg             # Which config files loaded here
cat mise.toml        # Pinned versions for project
```

## Working with This Repository

1. All operations are **idempotent** - safe to re-run
2. The Makefile has no per-profile knowledge. Profiles are
   discovered from the `profiles/` directory glob, and what
   each one does beyond its `Brewfile` is declared in its
   own `config.toml` `[profile]` section. Adding a profile
   never requires a Makefile edit
3. MAS (Mac App Store) integration requires being
   signed in
4. Per-machine configuration changes should be made in
   the **external host tier** on local disk
   (`${XDG_CONFIG_HOME:-~/.config}/macos-setup/`, seeded
   from `computer-specific/_template/` by `make install`).
   Shared changes go in `profiles/{name}/` or
   `default/` in the repo.
5. The `.claude/` directory is gitignored to prevent
   accidental commits of local configs (except
   `.claude/rules/repo-config.md`, the per-repo
   config consumed by `/issue:address`)
6. A host opts into N ordered profiles via the `profiles`
   array in the external host tier's `config.toml` (lowest
   priority first). Machines with no `profiles` array fall
   back to the two-tier model (external host > default),
   unchanged
