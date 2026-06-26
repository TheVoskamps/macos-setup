# macOS Setup

A comprehensive, structured macOS development environment
setup using Homebrew bundles in `Install/` (formerly
`Brewfiles`), parallel `Uninstall/` and `RemoveAndPurge/`
frameworks, dynamic Makefile targets, and automated
configuration management.

## What This Repository Contains

- **Categorized Install files**: 19+ numbered files in
  `Install/` for different tool categories (core,
  security, development, AI, etc.)
- **Parallel Uninstall files**: every `Install/` slot
  has an `Uninstall/` slot used by `make uninstall`
  and by a smart filter on `make install`. Removes the
  binary; leaves user data on disk
- **Parallel RemoveAndPurge files**: every `Install/`
  slot also has a `RemoveAndPurge/` slot used by
  `make remove-and-purge`. Same idea as `Uninstall/`,
  but for casks the runner uses
  `brew uninstall --cask --zap` so user data is also
  removed
- **Dynamic Makefile**: Auto-generates targets from
  `Install/`, `Uninstall/`, and `RemoveAndPurge/`
  filenames with special post-install handling
- **Configuration Management**: Automated setup for
  VS Code, Claude, Hammerspoon, AWS CDK using layered
  resolution (default < the host's profiles in list
  order < host)
- **Version Management**: Full asdf + direnv integration
  with pinned versions in `.tool-versions`
- **Bootstrap Scripts**: Complete setup from scratch on
  any macOS machine
- **Layered Configuration**: a host opts into N ordered
  profiles —
  `default/` (in repo) <
  `profiles/{name}/` (host-declared order, in repo) <
  the **external host tier** on local disk
  (`${XDG_CONFIG_HOME:-~/.config}/macos-setup/`, outside
  the repo)
- **Claude Configuration**: Layered config for home
  directory and local repository configuration

## Quick Start (Recommended)

### Step 1: Bootstrap Your Machine

Download and run the bootstrap script from any location:

```bash
# Download bootstrap.sh from GitHub
curl -O https://raw.githubusercontent.com/TheVoskamps/macos-setup/main/bootstrap.sh

# Run it
bash ./bootstrap.sh
```

**What the bootstrap does:**

1. Installs **Homebrew**, **mas** (Mac App Store CLI), and
   **dasel** (the TOML query primitive `config.toml` relies
   on), then verifies the installed dasel is **exactly major
   version 3** — a non-v3 dasel fails this step loudly
2. Installs **Apple Command Line Tools** (git)
3. Clones this (public) repository to `./macos-setup` over
   **HTTPS** — no SSH key or 1Password SSH agent required
4. Provides next steps

> This repo is public, so the bootstrap clone needs no
> credentials. 1Password is no longer installed by the
> bootstrap itself (it still comes in via `make security`),
> and the 1Password SSH-agent setup the bootstrap used to walk
> you through now lives in
> [docs/1password-as-ssh-agent.md](docs/1password-as-ssh-agent.md)
> for when you *do* need SSH auth (pushing to this repo,
> cloning private repos).

### Step 2: Install Everything

```bash
cd macos-setup
make install
```

This applies all `Install/` files in order and configures
everything automatically.

> **Run `make install` in a fresh shell.** `bootstrap.sh`
> installs `dasel` (a hard dependency of every `config.toml`
> read) into Homebrew's bin and appends the `brew shellenv`
> line to your profile — but that line only puts Homebrew's
> bin on `PATH` for a *new* login shell. If you run
> `make install` in the *same* shell you bootstrapped in, the
> config-dependent targets (`install`, `update`, `verify`,
> `outdated`) abort up front with `Error: dasel not in PATH.`
> The fix is to start a fresh shell and re-run
> `cd macos-setup && make install`.

## Usage

### Essential Commands

```bash
# Install everything (applies all Install/ files,
# filtered against any in-scope Uninstall/ and
# RemoveAndPurge/ entries)
make install

# Update everything: Homebrew/packages/asdf,
# then apply Uninstall and RemoveAndPurge
make update

# Check for outdated packages
make outdated

# Install specific categories
make core             # Essential system tools
make security         # Security tools and VPN
make development      # Development tools + VS Code
make ai               # AI tools + Claude/Cursor
make aws              # AWS tools + CDK config

# Verify installations and check for
# same-tier Install/Uninstall+RemoveAndPurge
# collisions
make verify

# Resolve same-tier collisions by commenting
# out the offending Install line (writes .bak)
make sanitize

# System diagnostics
make diagnose
```

### Keeping the Repo Up To Date

To pull the latest `main` into this repo from any local
state, run:

```bash
make self-update
```

This is backed by `scripts/self_update.sh` and handles
the common cases automatically:

- If you're on a branch other than `main`, it switches
  to `main`.
- If the working tree is dirty (staged, unstaged, or
  untracked changes), it `git stash push --include-untracked`
  → pulls → `git stash pop`.
- If clean and on `main`, it just pulls.
- Prints the before/after SHA of `main` on success.

Rehearse with `DRY_RUN=1` to see what it would do
without making any changes:

```bash
make self-update DRY_RUN=1
```

It refuses (does nothing, exits non-zero) when:

- You're not inside this repo.
- You're inside a linked worktree (e.g. under
  `.claude/worktrees/`). Run from the main checkout
  instead — the worktree's branch is independent of
  `main`.
- You're in detached HEAD.
- A rebase, merge, cherry-pick, revert, or bisect is
  in progress.
- The pull fails (non-fast-forward, network error,
  etc.).
- `git stash pop` produces conflicts — your changes are
  left in `stash@{0}` for you to resolve manually.

Out of scope: `make self-update` only updates the
working tree. Use `make update` to upgrade Homebrew,
asdf-managed tools, MAS apps, and apply
`Uninstall/` + `RemoveAndPurge/`.

### Category Overview

The setup is organized into numbered `Install/` files:

- **00-core**: Essential system utilities
- **01-security**: Security tools, VPNs, 1Password
- **02-ui**: UI tools with Finder, Hammerspoon
- **03-shell**: Shell tools with automated zsh setup
- **04-versionmanagers**: asdf + direnv with full bootstrap
- **05-08**: Tools, messaging, browsers, Proton tools
- **09-development**: Development tools + VS Code extensions
- **10-14**: Backups, AWS, componentization, data, databases
- **15-19**: Ripping, SD cards, AI, MS Office, viewers

### Automatic Configuration Setup

Special post-install handling automatically configures
tools using layered resolution (external host > the
host's profiles in reverse list order > default; a host
opts into N ordered profiles via the `profiles` array in
its consolidated `config.toml` in the external host tier,
`${XDG_CONFIG_HOME:-~/.config}/macos-setup/config.toml`):

- **VS Code**: Settings symlinked via `resolve_file`
- **Claude**: `~/.claude/` is cloned from the global
  Claude config repo by `claude_repo_setup.sh`; the
  active branch and SSH host alias are selected from the
  single-winner `[claude]` section of `config.toml`
  (`branch` and `hostname` keys)
- **Hammerspoon**: `init.lua`, `monitors.json`,
  `workspaces.json` symlinked via `resolve_file`;
  `modules/` directory (including `apps/` launchers)
  symlinked via `resolve_dir`; desktop switching
  shortcuts configured via `spaces_shortcuts_setup.sh`
- **AWS CDK**: Config via `resolve_file` for `.cdk.json`
- **Shell Environment**: Oh My Zsh themes and plugins;
  `aliases.zsh` aggregated across all tiers (default +
  profiles in list order + host) via `resolve_aggregate`
- **Version Managers**: asdf plugins and pinned versions

### Uninstalling and purging packages

Every `Install/NN-Install.<suffix>` slot has two
parallel removal slots: `Uninstall/NN-Uninstall.<suffix>`
and `RemoveAndPurge/NN-RemoveAndPurge.<suffix>`.

Pick the right one for your goal:

- **Uninstall** removes the app but leaves your
  settings, login data, and caches in `~/Library` etc.,
  so reinstalling later picks up where you left off.
  Use this when you might want the app back, or when
  you're temporarily disabling it on a machine.
- **RemoveAndPurge** removes the app *and* all data the
  cask declares — preferences, caches, support files,
  login items. Reinstalling starts fresh. Use this for
  software you're done with permanently (e.g.
  unsupported casks, or apps you want completely gone
  from the machine).

For formulae (`brew '...'`) and Mac App Store entries
(`mas '...'`) the two trees behave identically — the
`--zap` distinction only applies to casks
(`cask '...'`).

Add a package to the matching file at the default,
profile, or host tier and:

- `make uninstall` removes everything in `Uninstall/`
  (skipping anything not currently installed).
  `make uninstall-dry-run` prints actions without
  executing.
- `make remove-and-purge` removes everything in
  `RemoveAndPurge/`, passing `--zap` to cask
  uninstalls. `make remove-and-purge-dry-run` prints
  actions without executing.
- `make install` (and the per-`Install/` targets)
  filters packages listed in *either* tree out of the
  matching Install file before `brew bundle` consumes
  it. The temp file fed to `brew bundle` shows each
  filtered line as one of:

  ```text
  # filtered: also listed in Uninstall/07-Uninstall.browsers
  # cask 'some-cask'
  ```

  ```text
  # filtered: also listed in RemoveAndPurge/07-RemoveAndPurge.browsers
  # cask 'some-cask'
  ```

  The filter also auto-trusts third-party taps: for each
  `tap '<name>'` directive that survives filtering into
  the file it feeds `brew bundle`, it runs
  `brew trust --tap '<name>'` first. Homebrew 6.0 made
  this required for non-official taps — without it,
  `brew bundle` silently skips a tap's packages and still
  exits 0. The trust is idempotent and only applies to
  taps whose `tap` line is actually installed (not
  filtered out).

The "in-scope" set of removal files used by the filter
depends on which Install tier is being applied: an
Install file is filtered against its own tier and every
higher-priority tier. The tier order, lowest to highest,
is default < the host's profiles in list order < host.
Both peer trees (`Uninstall/` and `RemoveAndPurge/`) are
scanned at each in-scope tier:

| Install tier              | Filter against                                  |
| ------------------------- | ----------------------------------------------- |
| Default (`Install/`)      | default + all profiles + host                   |
| Profile `profiles/{name}` | `{name}` + every profile listed after it + host |
| Host                      | host only                                       |

Per-slot targets are auto-generated for both trees:

```bash
make 07_Uninstall_browsers
make 07_RemoveAndPurge_browsers
make uninstall-dry-run
make remove-and-purge-dry-run
```

Both trees share `scripts/remove_runner.sh`. The runner
takes a `--mode={uninstall|purge}` flag (defaults to
`uninstall` for backward compatibility); the Makefile
passes the flag explicitly at every call site.

See [docs/INSTALL.md](docs/INSTALL.md) for the full
reference.

`make update` runs `make uninstall` and
`make remove-and-purge` *after* the upgrade chain
(Homebrew, casks, MAS, asdf, then `make asdf-cleanup`
to prune old asdf versions), so even if `brew upgrade`
resurrects something via dependency resolution the
removal step takes it out before the run completes.

### Detecting and fixing collisions

`make verify` runs the per-Install verification and then
a **same-tier collision check**: any package listed in
BOTH `<tier>/Install/NN-Install.suffix` AND that same
tier's `Uninstall/NN-Uninstall.suffix` (or
`RemoveAndPurge/NN-RemoveAndPurge.suffix`) is reported,
and `make verify` exits non-zero. Cross-tier collisions
are intentional ("opt out at a more-specific tier") and
are not flagged.

Sample report:

```text
WARN: same-tier collision in 07-browsers
  Install/07-Install.browsers:8       cask 'some-cask'
  RemoveAndPurge/07-RemoveAndPurge.browsers:5  cask 'some-cask'
  fix: make sanitize    (will remove the Install line)
```

`make sanitize` resolves each collision by commenting
out the `Install/` line (the `Uninstall/` or
`RemoveAndPurge/` peer wins per the conflict rule in
[docs/INSTALL.md](docs/INSTALL.md)) with a marker:

```text
# sanitized 2026-04-29: also listed in RemoveAndPurge/07-RemoveAndPurge.browsers
# cask 'some-cask'
```

A `.bak` is written next to each edited file. Review
the diff (e.g. `git diff`), commit the change, and
remove the `.bak` files when satisfied.

### Automated Updates

Set up automatic system updates using LaunchAgents:

```bash
# Daily updates at 4am
make schedule-daily

# Weekly updates on Sundays at 11am
make schedule-weekly

# Remove automatic updates
make unschedule-daily
make unschedule-weekly
```

LaunchAgents run in the user's login session, providing
access to the macOS Keychain for email credentials.

#### Email Notifications

Scheduled jobs can optionally send email reports instead
of logging output to a file. Email is sent via **msmtp**,
a lightweight generic SMTP relay client. Each user points
it at their own relay (Gmail app-password, Fastmail, their
ISP, their own AWS SES SMTP credentials, etc.) by editing
the `[mailer]` section of their `config.toml` (single-winner:
the highest-priority tier with a value wins — host > the
host's profiles in reverse list order > default).

Note: msmtp is a relay client, not a mail server — a relay
account is required. Any provider that offers SMTP
submission works; setup is a few keys under `[mailer]` in
`config.toml` plus one Keychain entry for the password.

This requires:

1. **`[cron] mailto`** configured at any tier with a
   recipient email address. The external host tier's
   template ships the `[cron]` section commented out (so a
   fresh machine sends no scheduled-job email until you add
   a recipient). Uncomment `[cron]` and set `mailto` in
   `${XDG_CONFIG_HOME:-~/.config}/macos-setup/config.toml`
   to enable email.
2. A working mailer backend (see below)

When `[cron] mailto` resolves (single-winner; highest-priority
tier wins), scheduled jobs pipe through `mail_wrapper.sh` to email
output (with success/failure in the subject line).
Without it, output goes to
`~/Library/Logs/macos-setup/<job>.log` (e.g.
`daily-update.log`, `weekly-update.log`,
`now-update.log`, `email-test.log`); Console.app
surfaces these.

Generated plists embed no repo-specific absolute paths.
The single entry point is
`$HOME/.zsh-shared/launchagent_runner` (a symlink chain
into the current checkout), so moving or renaming the
repo only requires re-running `make shell` to repoint
`~/.zsh-shared`; no `make schedule-*` re-run is needed.

**Setup:**

```bash
# 1. Edit the external host tier's config.toml
#    (${XDG_CONFIG_HOME:-~/.config}/macos-setup/config.toml)
#    with your relay's SMTP details under [mailer]:
[mailer]
smtp_host = "smtp.example.com"
smtp_port = 587
smtp_from = "you@example.com"
smtp_user = "you@example.com"
# Optional — Keychain service name (defaults to "msmtp"):
# keychain_service = "msmtp"

# 2. Store the relay password in the macOS Keychain. Use the SAME
#    service name (keychain_service, default "msmtp") and username
#    (smtp_user) you set under [mailer] above:
security add-generic-password -s msmtp \
  -a you@example.com -w 'YOUR_SMTP_PASSWORD'

# 3. Install msmtp and generate ~/.msmtprc from config.toml
make messaging

# 4. Set [cron] mailto in config.toml with your recipient address

# 5. Test the configuration
make email-test

# 6. Install scheduled jobs to pick up email config
make schedule-daily    # or make schedule-weekly
```

`make messaging` generates `~/.msmtprc` (mode 0600) from
your resolved `[mailer]` values. The relay password is
never written to `config.toml` or `~/.msmtprc`; msmtp
reads it from your login Keychain at send time via
`passwordeval`. The generated `passwordeval` line, the
`config.toml` template, and the `security
add-generic-password` example above all reference the same
service name (`keychain_service`) and username
(`smtp_user`), so they stay in sync.

#### Common relay providers

Any provider that offers SMTP submission works. A few
examples (`smtp_host` / `smtp_port`):

- **Gmail** -- `smtp.gmail.com` / `587`, with an
  [app password](https://support.google.com/accounts/answer/185833)
  as the Keychain password (not your account password).
- **Fastmail** -- `smtp.fastmail.com` / `587`, with an
  app-specific password.
- **AWS SES SMTP** -- `email-smtp.<region>.amazonaws.com`
  / `587`, using SES **SMTP credentials** (generated in the
  SES console — these are distinct from IAM access keys).
- **Your ISP / mail host** -- use the SMTP submission host
  and credentials they provide.

`smtp_user` and the Keychain password are whatever your
chosen provider issues for SMTP submission.

## Layered Configuration System

A host opts into **N ordered profiles**. Configuration
resolves in priority order, lowest to highest:
`default/` (in repo) < `profiles/{name}/`
(each profile in the host's list order, in repo) < the
**external host tier** on local disk. The repo keeps only
`default/` and `profiles/`; the per-host
tier lives OUTSIDE the repo at
`${XDG_CONFIG_HOME:-~/.config}/macos-setup/` (override with
`MACOS_SETUP_HOST_DIR`). `make install` seeds it from
`computer-specific/_template/` only if absent, and never
overwrites your edits. The per-host profile list lives in
the `profiles` array of that external host tier's
`config.toml` (lowest priority first).
`Install/`, `Uninstall/`, and `RemoveAndPurge/` are
**additive** (all tiers applied; `Install/` filtered
against in-scope `Uninstall/` + `RemoveAndPurge/`).
`aliases.zsh` is **aggregated** (every tier concatenated
in `default -> profiles(order) -> host` order). The scalar
config knobs (`[claude]`, `[mailer]`, `[cron]`) live in a
single per-tier `config.toml`, queried with `dasel` (a hard
runtime dependency that must be **exactly major version 3**;
the read layer asserts this and hard-aborts loudly on a
non-v3 dasel), and resolve **single-winner** per section. The `profiles`
array in `config.toml` is the one aggregate key (a
default-tier array is prepended to the host's). All other
config files use **single-winner** (highest-priority tier
that has the file wins).

### Directory Structure

```text
shared/
└── zsh/                        # Shared zsh helpers (NOT three-tier)
    ├── macos_setup.zsh         # m() and repo locator
    ├── iterm.zsh               # iterm_tab_count, set_title
    ├── ws.zsh                  # ws() workspace launcher + aliases
    └── launchagent_runner      # Symlink -> ../../scripts/launchagent_runner.sh
                                # (LaunchAgent entry point; embedded in
                                # generated plists as $HOME/.zsh-shared/...)
profiles/
├── dev-core/                   # A fine-grained, single-
│   │                           # responsibility profile (a host
│   │                           # opts into N of these, in order)
│   ├── Install/                # Profile Install files
│   │   ├── 05-Install.tools
│   │   ├── 09-Install.development
│   │   └── ...
│   ├── Uninstall/              # Profile Uninstall files (lazy)
│   ├── RemoveAndPurge/         # Profile RemoveAndPurge files (lazy)
│   ├── aliases.zsh             # Optional: aliases for the tool this
│   │                           # profile adopts (aggregate tier; git
│   │                           # shortcuts + gbc/gbd/gsr live here)
│   └── config.toml             # Optional per-profile [claude]/[mailer]/
│                               # [cron] overrides (single-winner per
│                               # section; overrides default)
├── claude-code-aliases/        # A "no-software" profile: only an
│   └── aliases.zsh             # aliases.zsh (the cr + cr-repo Claude wrappers),
│                               # no Install/ — opting in just adds
│                               # its aliases to the aggregate
├── aws/                        # …40 more single-purpose profiles
└── …                           #   (databases, web, plex, yubikey, …)

default/                            # Global base (lowest tier), in repo root
├── aliases.zsh
├── asdf-plugins.toml
├── config.toml                 # Default scalar config: [claude]
│                               # (branch/hostname), [mailer], [cron],
│                               # and the profiles array. [mailer] ships
│                               # with active shared relay defaults (the
│                               # default tier resolves at runtime);
│                               # [claude], [cron], and profiles stay
│                               # commented out as in-place docs.
└── .hammerspoon/
    ├── init.lua
    ├── monitors.json
    ├── workspaces.json
    └── modules/                # Shared Lua modules
        ├── config.lua
        ├── monitors.lua
        ├── positions.lua
        ├── screen_focus.lua
        ├── spaces.lua
        ├── launcher.lua        # Workspace launch orchestrator
        ├── sorter.lua          # Position-aware window re-sorting
        ├── windows.lua         # Cross-Space window enumeration
        ├── utils.lua           # Shared helpers (AppleScript escape)
        └── apps/               # App launcher modules
            ├── iterm.lua
            ├── vscode.lua
            ├── finder.lua
            └── safari.lua

computer-specific/                  # IN REPO: only _template/
└── _template/                  # Seed for the EXTERNAL host tier
    ├── README.md               # Documents the host tier
    ├── config.toml             # profiles array + [claude]/[mailer]/
    │                           # [cron] (all commented out)
    ├── aliases.zsh
    ├── .vscode/settings.json
    └── .cdk.json

# The HOST TIER lives OUTSIDE the repo (highest priority), seeded
# from computer-specific/_template/ by `make install` if absent:
${XDG_CONFIG_HOME:-~/.config}/macos-setup/   # override: MACOS_SETUP_HOST_DIR
├── config.toml                 # Consolidated scalar config: the
│                               # profiles array (lowest first) plus
│                               # [claude], [mailer], [cron] sections
├── .vscode/settings.json
├── .hammerspoon/
│   ├── init.lua
│   ├── monitors.json
│   └── workspaces.json
├── aliases.zsh
├── Install/                    # Machine Install files
├── Uninstall/                  # Machine Uninstall files (lazy)
└── RemoveAndPurge/             # Machine RemoveAndPurge files (lazy)
```

### Profile Selection

Each machine opts into an ordered list of profiles via
the `profiles` array in the external host tier's
`config.toml`
(`${XDG_CONFIG_HOME:-~/.config}/macos-setup/config.toml`),
lowest priority first (the last entry sits just under the
host tier):

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
prepended to the host's, deduped keeping the last
occurrence. Machines with no `profiles` array fall back to
two-tier resolution (external host > default).

## Advanced Usage

### Version Management with asdf

The repository uses asdf for reproducible runtime
environments:

```bash
# Setup version managers (included in make install)
make versionmanagers

# Manage asdf plugins
make asdf-plugins-init    # Add nodejs, python, etc.
make asdf-pin-latest      # Pin latest versions
make asdf-install         # Install pinned versions

# Check for updates
make asdf-outdated        # Check for newer versions

# Update asdf-managed tools
make asdf-update          # Update and install latest

# Prune old, unused versions (keeps versions referenced
# by any .tool-versions on the machine, currently-active
# versions, and the newest 3 per plugin)
make asdf-cleanup-dry-run # Show what would be removed
make asdf-cleanup         # Remove the old versions
# (asdf-cleanup also runs automatically after asdf-update
#  as part of `make update`)

# Note: Installing latest does NOT activate them
# Use 'asdf set <plugin> <version> -u' to activate

# Setup specific tools via asdf
make asdf-awscli          # Setup awscli via asdf
make asdf-lua             # Setup lua via asdf
make asdf-terraform       # Setup terraform via asdf

# Setup direnv integration
make direnv-setup         # Configure direnv
make direnv-enable        # Enable in current directory
```

#### Plugin Filtering

Per-plugin version resolution can be customized via
`asdf-plugins.toml` (a single-winner file: the
highest-priority tier with it wins). Each `[plugin]`
section supports `filter`,
`filter_exclude`, and `max_version` keys to control
which versions are considered "latest". See
[docs/VERSION_MANAGEMENT.md](docs/VERSION_MANAGEMENT.md)
for details.

### Workspace Management (Multi-Monitor Setup)

For machines with multiple monitors, this repository
provides automated workspace and window management
through Hammerspoon.

#### Architecture

- **Hammerspoon**: Manages window positioning across
  monitors with automatic sorting after reconnection.
  Uses a modular Lua architecture with shared modules
  for config loading, monitor detection, positions,
  Spaces management, window re-sorting, and workspace
  launching
- **Workspace Launching**: The `launcher` module
  orchestrates app launching via per-app modules
  (`modules/apps/`), handling iTerm, VS Code, Finder,
  and Safari with position presets and Space navigation
- **Window Re-sorting**: The `sorter` module provides
  position-aware window re-sorting, moving windows to
  correct monitors and Spaces based on config
- **Configuration**: JSON-based monitor assignments
  (role-based schema) and workspace definitions
  (with `positions` presets and `launch` configs)
  resolved single-winner (highest-priority tier wins)

#### Hotkeys

**Monitor Switching:**

- `Ctrl+Alt+Cmd+Tab` - Cycle through all monitors
- `Ctrl+Alt+Cmd+Up` - Focus primary monitor
- `Ctrl+Alt+Cmd+Left` - Focus left monitor
- `Ctrl+Alt+Cmd+Right` - Focus right monitor
- `Ctrl+Alt+Cmd+Down` - Cycle secondary monitors

**Workspace Management:**

- `Ctrl+Alt+Cmd+R` - Re-sort windows to correct monitors
- `Ctrl+Alt+Cmd+Shift+R` - Reload Hammerspoon config
- `Ctrl+Alt+Cmd+Shift+L` - List connected screens
  (shows names, resolutions, UUIDs)
- `Ctrl+Alt+Cmd+1/2/3` - Switch to workspace Space

#### Launching Workspaces

Workspaces can be launched via Hammerspoon IPC shell
aliases or URL handler. Launching opens apps (iTerm,
VS Code, Finder, Safari), positions windows using
presets from `workspaces.json`, and navigates to the
correct Space.

```bash
# Unified ws dispatcher (Hammerspoon IPC)
ws macos-setup            # Launch a workspace
ws lg-left                # Launch the apps assigned to a monitor
ws left                   # Launch monitor at position "left"
ws                        # Inline help: usage, workspaces
                          # (with launched markers), monitors
                          # (with position annotations)
ws close <name>           # Close (workspace | monitor | position)
ws restart <name>         # Close + relaunch
ws screens                # List connected screens
ws fix                    # Re-sort all windows

# Launch via URL handler
open "hammerspoon://launchWorkspace?name=macos-setup"
```

`ws` is a single dispatcher across three namespaces:
workspace names (from `workspaces.json`), monitor names
(from `monitors.json`), and monitor `position` values
(`left`/`right`/`up`/`down`). Names must be unique
across all three namespaces and must not collide with
the reserved words `close`, `restart`, `screens`,
`fix`, or the empty string. Hammerspoon validates this
on load and pops a blocking dialog (and disables the
dispatcher globals) if any collision is detected.

#### Configuration Files

**Monitor Assignments** (`monitors.json`):

- Uses role-based schema: each monitor has a `pattern`
  (substring match against screen name) and a `role`
  (`primary` or `secondary`)
- `primary` role falls back to largest screen if
  pattern does not match
- Optional per-monitor fields: `apps` (list of apps to
  assign), `fullscreen` (boolean), `description`,
  `position` (`left`|`right`|`up`|`down`) for
  directional focus via `Ctrl+Alt+Cmd+Arrow`
- Two or more entries MAY share the same `pattern`
  (e.g. two identical external displays) as long as
  every entry with that pattern also has a distinct
  `position`. Resolution then picks the physical
  screen whose frame is most extreme along that axis
  (`left`=min x, `right`=max x, `up`=min y,
  `down`=max y). `validateMonitors` enforces this
  rule at Hammerspoon load time: a shared pattern
  with a missing or duplicate `position` aborts the
  load with an error alert.
- Example: two identical `16MR70` displays flanking
  a primary can both use `"pattern": "16MR70"` with
  one entry setting `"position": "left"` and the
  other `"position": "right"`.
- Top-level `titleAssignments` array routes app
  windows to a monitor when `matchAll: true`. Workspace
  patterns in `workspaces.json` take precedence: a
  window whose title matches a workspace pattern is
  routed to that workspace's Space, even if its app
  also has a `titleAssignments` entry.
- Use `Ctrl+Alt+Cmd+Shift+L` or
  `hs -c "listScreens()"` to discover screen names
  for `pattern` values

**Workspace Definitions** (`workspaces.json`):

- Top-level `positions` block defines named position
  presets as unit rects (`x`, `y`, `w`, `h` from
  0.0-1.0) or arrays of rects for staggered windows
- Top-level `workspaces` object is keyed by workspace
  name; each entry defines `spaceIndex`, `homeDir`,
  `patterns`, and a `launch` block (the key is the
  workspace name; no `name` field inside the entry)
- The `launch` block configures per-app launching:
  `iterm` (count, position), `vscode` (workspaceFile
  or folder, position), `finder` (array of path +
  position + index), `safari` (urls array)
- Maps window title patterns to primary monitor Spaces
- Enables automatic window sorting by project context

#### Hammerspoon Modules

Shared Lua modules live in
`default/.hammerspoon/modules/`
and are symlinked to `~/.hammerspoon/modules/`:

- **config.lua** - JSON config loading, path expansion,
  schema validation for monitors.json and
  workspaces.json
- **monitors.lua** - Monitor detection by pattern,
  role-based lookup (primary/secondary), and the
  `listScreens()` discovery function
- **positions.lua** - Unit-rect to pixel-frame
  conversion for window positioning; supports single
  rects and arrays (staggered windows)
- **screen_focus.lua** - Shared screen focus utility
  (moves mouse to screen center and clicks to focus)
- **spaces.lua** - Space creation, navigation, and
  title-bar-drag workaround for macOS 15+ (Sequoia)
- **launcher.lua** - Workspace launch orchestrator;
  coordinates Space navigation, app launching via
  `modules/apps/`, window positioning, and final focus
- **sorter.lua** - Position-aware window re-sorting;
  moves windows to correct monitors and Spaces based
  on monitor assignments and workspace title patterns,
  applies position presets from workspace launch configs
- **windows.lua** - Cross-Space window enumeration
  via `hs.application.runningApplications()` (skips
  WebKit XPC bundles that stall AX queries for 6s
  each) plus a per-app fallback that survives
  fullscreen-in-other-Space cases (`mainWindow` ->
  `focusedWindow` -> `visibleWindows` -> `allWindows`)
- **utils.lua** - Shared helpers; currently
  `escapeAppleScript()` for safe string interpolation
  into AppleScript double-quoted strings
- **apps/iterm.lua** - Launches iTerm2 windows via
  AppleScript with configurable count and working
  directory
- **apps/vscode.lua** - Launches VS Code via CLI with
  workspace file or folder, polls for new window
- **apps/finder.lua** - Opens Finder windows at
  specified paths via AppleScript
- **apps/safari.lua** - Opens Safari window with
  multiple URL tabs via AppleScript

#### IPC Commands

Hammerspoon exposes global functions accessible from
the terminal via IPC (`hs` command):

```bash
# List all connected screens with names and UUIDs
hs -c "listScreens()"

# Re-sort all windows to configured monitors/spaces
hs -c "resortAllWindows()"

# Launch a workspace (opens apps, positions windows)
hs -c "launchWorkspace('macos-setup')"

# Close a workspace (closes standard windows whose
# titles match the workspace's patterns; never quits
# whole apps)
hs -c "closeWorkspace('macos-setup')"

# Restart a workspace (close + relaunch; bypasses the
# 'already launched' guard)
hs -c "restartWorkspace('macos-setup')"

# Inline help (workspaces, monitors, positions) -
# same output as running `ws` with no arguments
hs -c "listWorkspaces()"

# Unified dispatcher used by the `ws` shell function.
# Classifies the name as workspace | monitor | position
# and routes to the right launcher/closer.
hs -c 'wsDispatch("macos-setup")'
hs -c 'wsCloseDispatch("lg-left")'
hs -c 'wsRestartDispatch("left")'
```

Note: `wsDispatch` / `wsCloseDispatch` /
`wsRestartDispatch` are only defined when
`validateNamespaces` passes on Hammerspoon load.
If names collide across workspaces, monitors, and
positions, these globals are left undefined and
`ws <anything>` fails fast until the config is fixed.

A URL handler is also registered for workspace
launching:

```bash
open "hammerspoon://launchWorkspace?name=macos-setup"
```

#### Features

- **Workspace launching** via IPC or URL handler:
  opens iTerm, VS Code, Finder, Safari with
  configured positions and Space navigation
- **Window re-sorting** via `sorter` module: moves
  windows to correct monitors and Spaces, applies
  position presets from workspace launch configs
- **Position presets** in `workspaces.json` define
  window layouts as unit rects (single or staggered
  arrays)
- **Automatic sorting** when monitors reconnect
  (e.g., after KVM switch)
- **Fullscreen management** for secondary monitors
  (enables Ctrl+Left/Right cycling)
- **Title-based routing** moves windows to correct Space
  based on project context
- **Configuration-driven** via JSON files
- **Monitor discovery** via hotkey or IPC for easy
  configuration of new monitors
- **Desktop switching shortcuts** (Ctrl+1-9)
  automatically configured via
  `spaces_shortcuts_setup.sh`

**Current pinned versions** (see `.tool-versions`):

- awscli 2.31.11
- nodejs, python, pnpm, terraform (managed via asdf)

### Per-repo config for `/issue:address`

`.claude/rules/repo-config.md` at the repo root tells the
`/issue:address` orchestrator and its four subagents
(`issue-developer`, `issue-fixer`, `doc-updater`,
`pr-reviewer`) which VCS, issue tracker, and branching
strategy this repo uses. Every run re-reads this file at
the start; the orchestrator and each subagent abort if
it's missing.

The file used by `macos-setup` itself is the reference
example (GitHub + GitHub issues + `main` source/target +
no branch-name prefix). Alternate examples (e.g. a repo
on CodeCommit + Jira + `integ` source/target + initials
branch prefix) live in the global Claude config repo at
`repo-examples/<repo-name>/rules/repo-config.md`.

To onboard another repo, copy one of those files into
that repo's `.claude/rules/repo-config.md` and edit the
front-matter values. The orchestrator and subagents do
the rest.

### Claude Configuration Management

`~/.claude/` is provisioned as a real git checkout of
`https://github.com/TheVoskamps/claude-config.git`,
not a tree of symlinks into this repo. Fresh clones use
the HTTPS URL (most users won't have an SSH key
registered on the org/repo); an existing clone whose
`origin` is the SSH form is recognized as ours and its
SSH origin is left intact (not rewritten to HTTPS). The
active branch and the SSH host alias used in the git
remote URL are selected from the single-winner `[claude]`
section of `config.toml` (host > the host's profiles in
reverse list order > default; the highest tier with a
non-empty value for a key wins, no per-key merge across
tiers). Missing or unknown branch falls back to the
global repo's default branch (resolved at run time via
`git ls-remote --symref origin HEAD`); missing
hostname defaults to `github.com`.

#### Home Directory Configuration (`~/.claude/`)

Make targets manage the clone:

```bash
# Clone or migrate the home directory; switch to the
# [claude]-resolved branch; pull --ff-only; then sync
# Claude plugins (~/.claude/plugins.sh --install).
make claude-install

# Update an existing clone. Errors loudly if ~/.claude/
# is missing or isn't the global Claude config repo;
# then sync plugins (~/.claude/plugins.sh --update).
make claude-update

# Read-only: show pending pulls/pushes and dirty
# files in ~/.claude/.
make claude-outdated

# Sync Claude plugins only (no clone/pull):
# invoke ~/.claude/plugins.sh --install / --update.
make claude-plugins-install
make claude-plugins-update
```

`make ai` and `make install` (via the
`17-Install.ai` post-install action) call
`claude-install` automatically. `make update` runs
`claude-update` as part of its overall update sweep,
and `make outdated` runs `claude-outdated` alongside
the brew/asdf checks.

**Plugin sync.** The global Claude config repo ships its
own `plugins.sh` at the repo root (`~/.claude/plugins.sh`
once cloned), which registers the marketplaces in
`extraKnownMarketplaces` and installs/updates the plugins
in `enabledPlugins` from the clone's `settings.json`.
macos-setup only **calls** that script; the
`settings.json` parsing and the `claude plugin ...`
invocations stay in the claude-config repo. After the
clone/migration finishes, `claude-install` runs
`~/.claude/plugins.sh --install` and `claude-update` runs
`~/.claude/plugins.sh --update`. Those inline calls are
**non-fatal**: if the `claude` CLI is not on PATH, if
`~/.claude/plugins.sh` is missing (an older claude-config
checkout predating the plugins refactor), or if
`plugins.sh` exits non-zero, the sync prints a warning and
is skipped/ignored rather than aborting `make ai` /
`make install` / `make update`. The standalone
`make claude-plugins-install` / `make claude-plugins-update`
targets drive the same code path directly and surface a
`plugins.sh` non-zero exit (the missing-binary /
missing-script guards still warn-and-skip with success).

**Branch and hostname selection (single-winner
`[claude]` section of `config.toml`):**

- Default-tier file lives at
  `default/config.toml` and ships
  with both `[claude]` keys commented out as in-place
  documentation.
- Override per-host: the `[claude]` section of
  `config.toml` in the external host tier
  (`${XDG_CONFIG_HOME:-~/.config}/macos-setup/config.toml`).
- Override per-profile:
  `profiles/<profile>/config.toml`.
- Resolution order: host > the host's profiles in
  reverse list order > default. Resolved per-key
  single-winner; no per-key merge beyond that (a
  host-tier file with only `branch` does NOT inherit a
  default-tier `hostname`).
- Two optional keys (queried with `dasel`):
  - `branch = "<name>"` -- branch to check out in
    `~/.claude/`. Missing / empty / unknown branch
    falls back to the global repo's default branch.
  - `hostname = "<ssh-alias>"` -- SSH host alias used in
    the derived git remote URL
    (`git@<alias>:TheVoskamps/claude-config.git`).
    Lets `~/.ssh/config` pick a per-machine
    IdentityFile. Defaults to `github.com`. A
    non-default `hostname` against an existing
    default-host clone is reconciled by rewriting
    `origin` on the next `make claude-install` /
    `make claude-update` run (idempotent).

**Migration from any pre-existing `~/.claude/`:**

If `~/.claude/` exists and is not already a clone of
the global Claude config repo (legacy symlink tree,
hand-fixed real files, stale clone of another repo,
partial state from an aborted run, etc.), it is
migrated in place: the directory is moved aside as
`~/.claude.orig.<timestamp>`, the global repo is
cloned in fresh, and the captured contents are
overlaid back on top (excluding `.git`, local wins).
Per-entry rules apply during the overlay:

- **Regular files** overwrite the clone's version
  at the same path.
- **Valid symlinks** carry forward as symlinks.
- **Broken (dangling) symlinks** are skipped with a
  stderr warning naming the source path and dead
  target. The clone's real file at the same name
  survives, and the broken symlink stays in
  `~/.claude.orig.<timestamp>/` so you can
  investigate.
- **Directories** deep-merge with local wins
  (existing files in the clone are preserved unless
  the captured tree has its own entry at the same
  path).
- **Kind mismatches** (file in one tree, directory
  at the same path in the other) resolve in favor
  of the captured `~/.claude/` version, in either
  direction.

Overlaid files appear as dirty in
`git -C ~/.claude status` so you can decide to
commit, branch, or discard. The
`~/.claude.orig.<timestamp>/` directory is left in
place for inspection.

**macOS quirk (issue #122):** `git` network ops
(`ls-remote`, `clone`, `fetch`, `pull`) can hang
~2 minutes on macOS when the shell's cwd has any
descendant path that's the absolute target of a
symlink elsewhere on disk and macOS has metadata
for that target. The mechanism is undocumented
(likely something path-keyed inside Spotlight,
APFS snapshots, fseventsd, or an EDR/MDM agent).
`claude_repo_setup.sh` and `claude_repo_common.sh`
sidestep the trigger by running each network op
from a fresh `mktemp -d` cwd via the
`git_in_safe_cwd` helper, leaving the caller's
cwd untouched.

#### Local Repository Configuration (`./.claude/`)

`./.claude/` is gitignored except for the whitelisted
entries listed in `.gitignore`. The most important
tracked file is `.claude/rules/repo-config.md` (the
per-repo config consumed by `/issue:address`). Use
this directory for repo-scoped Claude state
(memory, plans, sandboxes); don't confuse it with
`~/.claude/`, which is the global config clone.

### Individual Install Targets

```bash
# By number
make 00               # Core tools
make 09               # Development tools
make 17               # AI tools

# By name
make core             # Same as make 00
make development      # Same as make 09
make ai               # Same as make 17

# Per-Install canonical form
make 00_Install_core
make 09_Install_development

# Per-Uninstall canonical form
make 07_Uninstall_browsers

# Per-RemoveAndPurge canonical form (--zap on casks)
make 07_RemoveAndPurge_browsers
```

## Alternative Bootstrap Methods

See **[docs/BOOTSTRAP.md](docs/BOOTSTRAP.md)** for
alternative setup methods including:

- Manual SSH key setup via AirDrop
- Fresh SSH key generation
- HTTPS clone with personal access tokens

## Requirements

- **macOS** (tested on macOS 14+)
- **Internet connection** for downloads
- **Apple ID** signed into Mac App Store (for MAS apps)
- **dasel v3** — the `config.toml` query primitive; installed
  and version-verified automatically by bootstrap. Must be
  exactly major version 3 (v2 and v4+ are rejected); a non-v3
  dasel hard-aborts `make`/config reads loudly
- **1Password** — not required to bootstrap (the repo is public
  and clones over HTTPS), but installed by `make security`. Set
  it up as your SSH agent when you need SSH auth — see
  [docs/1password-as-ssh-agent.md](docs/1password-as-ssh-agent.md)

## Documentation

- [Shell Configuration & Aliases](docs/SHELL.md)
- [Bootstrap Alternatives](docs/BOOTSTRAP.md)
- [Changelog](docs/CHANGELOG.md)
- [Version Management](docs/VERSION_MANAGEMENT.md)
- [Makefile Usage](docs/MAKEFILE.md)
- [Install / Uninstall / RemoveAndPurge Index](docs/INSTALL.md)
- [Documentation Index](docs/INDEX.md)

## Key Features

### Dynamic Makefile System

- Auto-generates targets from `Install/`, `Uninstall/`,
  and `RemoveAndPurge/` filenames
- Supports numeric aliases (`make 00`, `make 09`) and
  named aliases (`make core`, `make development`)
- Special post-install handling for UI, shell,
  development, AWS, and AI categories
- Layered `Install/`, `Uninstall/`, and
  `RemoveAndPurge/` support across all tiers: default,
  each of the host's profiles in list order, and the
  external host tier (on local disk, outside the repo)
- Shared removal runner (`scripts/remove_runner.sh`)
  with `--mode={uninstall|purge}` selecting cask
  behavior

### Idempotent Operations

- All operations are safe to re-run
- Plugin installation checks prevent duplicates
- Configuration symlinks back up existing files
- Version pinning ensures reproducible environments

### Comprehensive Tool Coverage

- Development: VS Code, Cursor, git, Docker
- Shell: zsh, Oh My Zsh, custom aliases
- Security: 1Password, VPNs, security tools
- Cloud: AWS CLI, AWS CDK
- AI: Claude, Cursor
- Version Management: asdf, direnv
- And many more...

## Notes

- All operations are **idempotent** - safe to re-run
- MAS integration requires being signed in to the App
  Store
- Special handling for UI (Finder defaults, Hammerspoon),
  shell (Oh My Zsh), development tools, and AI tools
- Version management uses exact pinning for reproducible
  environments
- The `.claude/` directory is gitignored to prevent
  accidental commits of local configuration, with one
  tracked exception: `.claude/rules/repo-config.md`
  (the per-repo config consumed by `/issue:address`)
- asdf updates install latest versions but do NOT activate
  them (use `asdf global` or `asdf local` to activate)

## License

This repository is for personal use. Feel free to fork
and adapt for your own needs.

## Contributing

This is a public repository. Contributions are welcome:

- **Fork** the repository and create a feature branch from the default
  branch.
- **Open a pull request** from your fork. PRs require a passing CI run,
  code-owner review (`@evoskamp`), and all review conversations
  resolved before they can merge.
- **File an issue** to report a bug or propose a change. Any logged-in
  GitHub user can open and comment on issues.

Outside contributors have read access: you can fork, open PRs from your
fork, and file/comment on issues. Push access, merging, and issue
triage are reserved for maintainers.
