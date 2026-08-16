# CLAUDE.md - macOS Setup

This file provides project-specific guidance for the
macOS setup repository.

## Repository Overview

This is a comprehensive macOS development environment
setup repository using Homebrew bundles (in `Install/`,
formerly `Brewfiles`) and a dynamic Makefile to
provision a macOS machine with development tools,
applications, and configurations. Two parallel removal
trees drive cleanup and a smart filter on `make install`:
`Uninstall/` (binary-only removal) and `RemoveAndPurge/`
(also removes the cask's declared user data via `--zap`).

### Key Architecture Concepts

1. **Numbered Install files** (`Install/00-19-Install.*`)
   organize packages by category. Parallel
   `Uninstall/NN-Uninstall.<suffix>` and
   `RemoveAndPurge/NN-RemoveAndPurge.<suffix>` slots
   exist for each
2. **Dynamic Makefile** auto-generates targets from
   Install/Uninstall/RemoveAndPurge names
   (e.g., `make 02`, `make ui`,
   `make 07_Uninstall_browsers`,
   `make 07_RemoveAndPurge_browsers`)
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
`.hammerspoon/*`, `.vscode/settings.json`, `Install/*`,
`.cdk.json`.

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
  `aliases.zsh`, plus the Install/Uninstall/
  RemoveAndPurge trees. `aliases.zsh` uses
  `resolve_aggregate`; the Install trees aggregate via
  the Makefile / `install_filter.sh` tier walk.

- **Install/**: Additive across all tiers (default +
  every profile in order + host), but each layer is
  filtered against in-scope `Uninstall/` AND
  `RemoveAndPurge/` slots before `brew bundle` consumes
  it
- **Uninstall/**: Additive across tiers; each tier's
  entries shadow that package for that tier's Install
  and any narrower (more specific) tier's Install (see
  `docs/INSTALL.md`). Removes the binary; leaves user
  data (preferences, caches, login items) on disk
- **RemoveAndPurge/**: Same shape and tier rules as
  `Uninstall/`, but for casks the runner uses
  `brew uninstall --cask --zap`, which also removes
  the cask's declared user data. For formulae and MAS
  items, behavior is identical to `Uninstall/`. Both
  trees share `scripts/remove_runner.sh` (selected
  via `--mode={uninstall|purge}`)
- **Config files**: single-winner (most-specific tier
  wins) unless listed as aggregate above
- **Profile selection**: the `profiles` array in the
  external host tier's `config.toml` (lowest priority
  first)

## Essential Commands Reference

### Initial Setup

```bash
./bootstrap.sh        # Install Homebrew, mas, dasel; HTTPS-clone the (public) repo
make install          # Apply all Install/ files in order
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
127` from `require_dasel_v3` partway into `00-Install.core`.
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
# Install by category
make core security ui shell versionmanagers
make development ai aws

# Version management (mise). Targets are named
# `versions-*`, not after the tool, so swapping the
# implementation leaves target names, aliases, and doc
# lines alone.
make versionmanagers        # Full mise setup
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

`make ai` and `make install` call `claude-install` automatically
as part of the post-install action for `17-Install.ai`.
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
`make ai` / `make install` / `make update` (same posture as the
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
               # then apply Uninstall and RemoveAndPurge
make verify    # Verify installations + check for
               # same-tier Install/Uninstall+RemoveAndPurge
               # collisions
make sanitize  # Resolve same-tier collisions by commenting
               # out the offending Install line (writes .bak)
make diagnose  # Run system diagnostics
```

## Special Behaviors to Know

### Automatic Post-Install Actions

- `00-Install.core` -> Runs `scripts/core_setup.sh`:
  sets computer/host names, and appends two grep-guarded
  exports to `~/.zshrc` — `HOMEBREW_NO_AUTO_UPDATE=1`
  and `HOMEBREW_NO_ASK=1` (the latter disables Homebrew
  6.0+ interactive ask-mode so `make update` / `make
  install` don't hang on a `[y/n]` prompt — issue #20)
- `02-Install.ui` -> Runs Finder config and
  Hammerspoon setup
- `03-Install.shell` -> Runs `scripts/shell_setup.sh`
- `04-Install.versionmanagers` -> Runs
  `scripts/versions_setup.sh full`: ensures the global
  mise config (importing `~/.tool-versions` when
  present) plus `[settings] env_file = ".env"`, then
  installs the declared tool versions
- `06-Install.messaging` -> Generates `~/.msmtprc` from `config.toml` `[mailer]`
- `09-Install.development` -> Installs VS Code extensions
- `17-Install.ai` -> Installs Cursor extensions,
  disables Claude auto-updates, runs
  `claude_disable_autoupdater.sh`, then runs
  `claude_repo_setup.sh install` to clone or update
  `~/.claude/` from the global Claude config repo and
  sync Claude plugins via `~/.claude/plugins.sh
  --install` (non-fatal; skipped with a warning if the
  `claude` CLI or `plugins.sh` is absent)

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

**Install/** files aggregate across every tier — default,
each profile in order, then host. Each layer is run
through the smart filter (`scripts/install_filter.sh`)
before `brew bundle` consumes it, so any package listed
in an in-scope `Uninstall/` or `RemoveAndPurge/` slot
is commented out. The filter also has one side effect:
for every `tap '<name>'` directive that survives
filtering into the emitted file it runs
`brew trust --tap '<name>'` first (Homebrew 6.0 requires
trusting third-party taps, else `brew bundle` silently
skips their packages and exits 0 — issue #172). The
trust is idempotent and conservative — a tap is trusted
only if its own `tap` line still emits; the `BREW` env
var overrides the brew binary used. See `docs/INSTALL.md`.

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
  `00-Install.core` post-install action) appends a
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

**Uninstall/** and **RemoveAndPurge/** files also
aggregate across tiers, but with a narrower filter scope
(see `docs/INSTALL.md`). An Install file is filtered
against the Uninstall + RemoveAndPurge slots of its own
tier and every higher-priority tier:

- Default `Install/<file>` filtered against default +
  all profiles + host `Uninstall/` and `RemoveAndPurge/`
- Profile `profiles/{name}/Install/<file>` against
  `{name}` + every profile listed after it + host
- Host `Install/<file>` against host only

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

### Install/Uninstall/RemoveAndPurge Execution Order

For each numbered Install slot
(e.g., `05-Install.tools`):

1. `Install/05-Install.tools` (default)
2. `profiles/{name}/Install/05-Install.tools` for each
   profile in the host's list order (if the file exists)
3. `<external-host-tier>/Install/05-Install.tools`
   (if file exists)

Each is filtered against the in-scope
`Uninstall/05-Uninstall.tools` AND
`RemoveAndPurge/05-RemoveAndPurge.tools` files (per
the tier rule above) before `brew bundle` runs.

`make install` and every per-slot install target
(`make ui`, `make 16`, `make core`, the generated
`NN_Install_*` targets, etc.) are **failure-tolerant**
across all three tiers: a `brew bundle` failure on one
tier or slot does not abort the run. The `install` batch
loop attempts every slot; each per-slot target attempts
its default + every profile (in order) + host tier via
the single-shell `APPLY_INSTALL_TIERS` helper. Both
accumulate the slots whose `brew bundle` returned
non-zero, print an end-of-run summary listing each
failed slot, and exit non-zero if any failed. (The
per-slot helper is a single shell precisely so an
earlier tier's failure cannot make `make` skip the
later tiers — three separate recipe lines would abort
the target on the first non-zero exit.) A clean
`make install` exits 0 with `All Install files
applied.`; a clean per-slot target exits 0 with no
summary. Per-slot post-install setup actions
(hammerspoon, mise, claude, etc.) are unchanged.
`make update` was already failure-tolerant.

Both code paths are **quiet by default** about
non-contributing tiers: the tier walk probes every
profile and the host tier for each slot, but the
negative-case lines (`==> No profile Install found
at ...`, `==> No computer-specific Install found
at ...`) are gated behind a `VERBOSE` env var so a host
that opts into many profiles is not buried under
hundreds of noise lines. A normal `make install` (or
per-slot target) suppresses them; `VERBOSE=1 make
install` restores them for debugging "why didn't my
profile's Install apply?". The positive `Found ...` /
`Applying ...` lines and the failure summary always
print. The gating is a single shared Makefile macro
(`VERBOSE_NOTE`) used by both the batch loop and the
`APPLY_INSTALL_TIERS` per-slot helper, so the two
cannot drift.

`make uninstall` walks `Uninstall/` slots in numeric
order and applies default → profiles (list order) →
host within each. The companion `make uninstall-dry-run`
prints actions without executing.

`make remove-and-purge` walks `RemoveAndPurge/` slots
the same way but invokes the shared
`scripts/remove_runner.sh` with `--mode=purge`, so
casks are uninstalled with `--zap` (also removes the
cask's declared user data). `make remove-and-purge-dry-run`
is the dry-run companion.

The `Uninstall/` and `RemoveAndPurge/` paths are also
**quiet by default about empty slots** (mirroring the
Install tier-walk gating above). Nearly every numbered
slot file is just a comment header with no actual package
to remove, so a `make update` (which runs both loops)
used to print ~80 noise lines. The fix gates a slot+tier's
output on whether the slot file has any **active directive**
— an uncommented, non-blank `brew "..."`, `cask "..."`, or
`mas "..."` line:

- Default (non-VERBOSE): a slot file with ZERO active
  directives prints NOTHING — neither the Makefile's
  `==> Applying global/profile/computer-specific
  Uninstall|RemoveAndPurge: <file>` banner, nor the
  runner's `[uninstall]/[purge] Processing <file>` /
  `Done: <file>` lines.
- A slot file with at least one active directive prints
  fully, INCLUDING `skip: <pkg> not installed` lines
  (those are genuinely useful — e.g. the `17-ai` slot's
  `cask "vibe-notch"` prints `Processing` + `skip` +
  `Done`).
- `VERBOSE=1` restores ALL lines for EVERY slot, including
  empty ones, for debugging.

This applies to BOTH the `Uninstall/` and `RemoveAndPurge/`
trees across ALL tiers, and therefore to every target that
invokes the removal loops: `make update` (whose `% m update`
output prompted issue #167), `make uninstall`,
`make remove-and-purge`, and their dry-run companions.
(`make install` does NOT run the removal loops, so it is
unaffected by this gating.) The "does this file have an active
directive?" decision lives in ONE place —
`scripts/remove_runner.sh`, the only code that reads the
file. The Makefile passes the banner text it would
otherwise have echoed itself via `--banner=<text>`, so the
banner and the runner's `Processing`/`Done` lines are
suppressed or shown together and can never disagree. Real
errors (malformed directives) still abort with a visible
message regardless of the quiet gate.

### Tool Version Configuration

Runtimes are managed by **mise**, installed by the
`version-managers` profile. The profile keeps its name:
`version-managers` is the role, not the implementation.

The cutover is hard, not staged: the same profile that
installs `mise` in
`Install/04-Install.versionmanagers` removes `asdf` and
`direnv` in
`RemoveAndPurge/04-RemoveAndPurge.versionmanagers`,
because asdf and mise both provide shims for the same
tools. Only the binaries go — `~/.asdf/`,
`~/.tool-versions`, `~/.config/direnv/lib/use_asdf.sh`
and every repo's `.envrc` / `.tool-versions` survive, and
`make asdf-to-mise` warns about each rather than deleting
it. `make shell` (`scripts/shell_setup.sh`) strips the
asdf/direnv `~/.zshrc` init lines it once wrote and adds
`export PATH="${XDG_DATA_HOME:-$HOME/.local/share}/mise/shims:$PATH"`
plus `eval "$(mise activate zsh)"`;
`scripts/launchagent_runner.sh` puts the same shims
directory on `PATH` itself, because launchd never sources
`~/.zshrc`.

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

**The LuaRocks pin.** lua builds must use LuaRocks
3.12.2 -- 3.13.0 ships a broken rockspec (duplicate
`tag` key) that fails to parse on Lua 5.5+ and also
fails during bootstrap on 5.4.x.
`scripts/versions_setup.sh` exports
`ASDF_LUA_LUAROCKS_VERSION=3.12.2` so every
`make versions-*` invocation carries it. Upstream
`luarocks/luarocks#1851` being closed is NOT license to
drop the pin -- it was closed by a fix to the release
tooling, and the shipped 3.13.0 tarball is PGP-signed
with a pinned `source_digest` and was never re-rolled.
Dropping the pin needs a 3.13.1 release; tracked in
issue #6.

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
    `Install/05-Install.tools`, even though the git binary
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

- `make ai` (and `make install` via the `17-Install.ai`
  post-install action) clones
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

- `make ui` symlinks init.lua, monitors.json,
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
  `make ui` exits non-zero (it no longer claims success
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
| `config_common.sh` | Layered resolution lib; host-tier path + seeding |
| `require_dasel_on_path.sh` | Up-front bare-name `dasel`-on-PATH gate |
| `list_profiles.sh` | Print this host's ordered profile list (one per line) |
| `host_tier_dir.sh` | Print external host-tier base path (Makefile helper) |
| `seed_host_tier.sh` | Seed external host tier from template if absent |
| `shell_setup.sh` | Configures zsh, Oh My Zsh; aggregates `aliases.zsh` |
| `mise_common.sh` | Global mise config helpers (shared by the two below) |
| `versions_setup.sh` | Drives mise for the `versions-*` targets and slot 04 |
| `asdf_to_mise.sh` | One-shot additive asdf+direnv -> mise repo migration |
| `vscode_extensions.sh` | Installs VS Code extensions |
| `vscode_setup.sh` | Symlinks VS Code `settings.json` (single-winner) |
| `hammerspoon_setup.sh` | Symlinks HS config; robust reload (IPC + relaunch) |
| `spaces_shortcuts_setup.sh` | Configures Ctrl+1-9 desktop shortcuts |
| `msmtp_setup.sh` | Generates ~/.msmtprc from config.toml [mailer] values |
| `claude_repo_setup.sh` | Clone/update ~/.claude/; sync plugins.sh |
| `claude_repo_common.sh` | Branch resolution + stash helpers |
| `claude_disable_autoupdater.sh` | Inject DISABLE_AUTOUPDATER=1 into ~/.zshrc |
| `resolve_mailto.sh` | Resolves recipient, validates mailer |
| `mail_wrapper.sh` | Wraps command output into email |
| `send_mail.sh` | Central mail dispatch (msmtp) |
| `resolve_from.sh` | Resolves From address from config |
| `resolve_repo_root.sh` | Runtime repo-root resolver via `~/.zsh-shared` |
| `launchagent_runner.sh` | LaunchAgent entry point; per-job log file |
| `verify.sh` | Verifies Install/ installations |
| `collision_check.sh` | Reports/fixes same-tier Install/removal collisions |
| `install_filter.sh` | Filters Install vs in-scope Uninstall + RemoveAndPurge |
| `remove_runner.sh` | Runs one Uninstall/RemoveAndPurge file (`--mode=...`) |
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
2. Makefile targets are dynamically generated from
   `Install/`, `Uninstall/`, and `RemoveAndPurge/`
   filenames
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
