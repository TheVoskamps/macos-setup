# macOS Setup

A comprehensive, structured macOS development environment
setup built from **profiles**: each contributes a Homebrew
`Brewfile` plus a `[profile]` section in its `config.toml`
declaring its post-install actions and the packages it
removes. A host composes the roles it wants by listing the
profiles it opts into.

## What This Repository Contains

- **Tiers, not numbered slots**: the core tier
  (`default/`), then each profile the host opts into
  (`profiles/<name>/`, in list order), then the external
  host tier. Each contributes one unnumbered `Brewfile`
- **~45 fine-grained profiles**: single-responsibility
  package sets (`dev-core`, `aws`, `web`, `databases`,
  `desktop-ui`, …). `make profiles` lists them
- **Declarative removals**: each tier's
  `[profile] uninstall` / `[profile] purge` arrays drive
  `make uninstall` / `make remove-and-purge` AND a smart
  filter on `make install`. `uninstall` removes the binary
  and leaves user data; `purge` adds `--zap` on casks so
  the cask's user data goes too
- **Declarative post-install hooks**: a tier's
  `post_install` array names the scripts to run after its
  Brewfile, so a new profile needs no Makefile edit
- **Configuration Management**: Automated setup for
  VS Code, Claude, Hammerspoon, AWS CDK using layered
  resolution (default < the host's profiles in list
  order < host)
- **Version Management**: Full mise integration with
  pinned versions in `mise.toml`
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

### Bootstrap Your Machine

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
> bootstrap itself (it still comes in via the `1password` profile),
> and the 1Password SSH-agent setup the bootstrap used to walk
> you through now lives in
> [docs/1password-as-ssh-agent.md](docs/1password-as-ssh-agent.md)
> for when you *do* need SSH auth (pushing to this repo,
> cloning private repos).

### Install Everything

```bash
cd macos-setup
make install
```

This applies every tier for this host, in order, and
configures everything automatically.

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
# Install everything: every tier this host opts into, in
# order, each Brewfile filtered against any in-scope
# uninstall/purge entries
make install

# Update everything: Homebrew/packages/tool versions,
# then apply every tier's uninstall and purge arrays
make update

# Check for outdated packages
make outdated

# See what profiles exist (* marks this host's, in order)
make profiles

# Apply specific tiers
make core                        # the core tier only
make profile dev-core            # one profile
make profile dev-core aws web    # several, in the order given

# Verify installations and check for same-tier
# Brewfile/uninstall+purge collisions
make verify

# Resolve same-tier collisions by commenting out the
# offending Brewfile line (writes .bak)
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
mise-managed tool versions, MAS apps, and apply every
tier's `uninstall` + `purge` arrays.

### Tier Overview

The setup is organized into tiers, applied lowest priority
to highest:

- **The core tier** (`default/Brewfile`): macos-setup's own
  runtime dependencies (`dasel`, `mas`, `git`, `msmtp`), the
  shell environment (zsh + plugins, iTerm2, fzf/bat/ripgrep
  and friends), universal CLI utilities, and Chrome. Its
  `post_install` sets the computer names, runs the zsh
  setup, and generates `~/.msmtprc`. Deliberately lean: a
  package belongs here only if macos-setup depends on it or
  it is genuinely universal.
- **Each profile the host opts into** (`profiles/<name>/`),
  in the order of the `profiles` array in the host tier's
  `config.toml`. Roughly 45 of them, each
  single-responsibility: `dev-core`, `dev-python`, `dev-go`,
  `aws`, `gcp`, `databases`, `containers`, `web`,
  `desktop-ui`, `version-managers`, `visual-studio-code`,
  `claude`, `1password`, `yubikey`, `plex`, … Run
  `make profiles` for the full list.
- **The external host tier**, on local disk outside the
  repo. Highest priority: its Brewfile applies last and its
  removal arrays outrank every other tier's.

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
  shortcuts configured via `spaces_shortcuts_setup.sh`.
  If Hammerspoon is already running, the setup reloads
  it: it tries the IPC reload first and, if that fails
  (e.g. a stale `init.lua` symlink left the `hs.ipc`
  message port down), falls back to relaunching the app
  so init.lua re-loads from the corrected symlink. If
  the reload still can't be confirmed it prints a loud
  warning telling you to reload manually from the
  menubar (Hammerspoon icon → Reload Config) and the
  `desktop-ui` tier is reported as failed (so
  `make profile desktop-ui` / `make install` exit
  non-zero) rather than silently leaving your hotkeys
  dead
- **AWS CDK**: Config via `resolve_file` for `.cdk.json`
- **Shell Environment**: Oh My Zsh themes and plugins;
  `aliases.zsh` aggregated across all tiers (default +
  profiles in list order + host) via `resolve_aggregate`
- **Version Managers**: mise with pinned tool versions

### Uninstalling and purging packages

Each tier's `config.toml` can carry removal arrays
under `[profile]`: `uninstall` and `purge`.

Pick the right one for your goal:

- **`uninstall`** removes the app but leaves your
  settings, login data, and caches in `~/Library` etc.,
  so reinstalling later picks up where you left off.
  Use this when you might want the app back, or when
  you're temporarily disabling it on a machine.
- **`purge`** removes the app *and* all data the
  cask declares — preferences, caches, support files,
  login items. Reinstalling starts fresh. Use this for
  software you're done with permanently (e.g.
  unsupported casks, or apps you want completely gone
  from the machine).

For formulae and Mac App Store entries the two behave
identically — the `--zap` distinction only applies to
casks.

Entries are `"<kind>:<identifier>"` strings:
`"brew:<formula>"`, `"cask:<token>"`, `"mas:<id>"`, or
`"mas:<id>:<Name>"` (the name is only a log label). A
malformed entry is a hard error, never a silently ignored
removal.

Add a package to the array at the core, profile, or host
tier and:

```toml
[profile]
uninstall = ["cask:firefox"]
purge = ["cask:qblocker", "mas:1365531024:1Blocker"]
```

- `make uninstall` applies every tier's `uninstall` array
  (skipping anything not currently installed).
  `make uninstall-dry-run` prints actions without
  executing.
- `make remove-and-purge` applies every tier's `purge`
  array, passing `--zap` to cask uninstalls.
  `make remove-and-purge-dry-run` prints actions without
  executing.
- `make install` (and `make core` / `make profile`)
  filters packages listed in *either* array out of the
  Brewfile before `brew bundle` consumes it. The temp file
  fed to `brew bundle` shows each filtered line as:

  ```text
  # filtered: also removed by profile web (purge)
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

The "in-scope" set of removal arrays used by the filter
depends on which tier's Brewfile is being applied: a
Brewfile is filtered against its own tier and every
higher-priority tier. The tier order, lowest to highest,
is core < the host's profiles in list order < host. Both
arrays are read at each in-scope tier:

| Brewfile tier             | Filter against                                  |
| ------------------------- | ----------------------------------------------- |
| Core (`default/`)         | core + all profiles + host                      |
| Profile `profiles/{name}` | `{name}` + every profile listed after it + host |
| Host                      | host only                                       |

That is what makes "I opted into `web` but I don't want
its Firefox" expressible: put `uninstall = ["cask:firefox"]`
in your host tier's `config.toml`, keep the `web` profile,
and Firefox is commented out of `web`'s Brewfile before
`brew bundle` ever sees it.

```bash
make uninstall-dry-run
make remove-and-purge-dry-run
```

Both modes share `scripts/remove_runner.sh`. The runner
takes a `--mode={uninstall|purge}` flag (defaults to
`uninstall`); the Makefile passes the flag explicitly at
every call site.

The runner also exports `HOMEBREW_NO_AUTOREMOVE=1`, so a
removal never cascades: `brew uninstall` normally follows
up with an automatic `brew autoremove` that drops every
formula nothing depends on any more, which is how
uninstalling `asdf` once took Homebrew's `bash` formula
with it mid-run. Pruning genuinely unneeded dependencies
stays available as a deliberate, separate
`brew autoremove`.

See [docs/INSTALL.md](docs/INSTALL.md) for the full
reference.

`make update` runs `make uninstall` and
`make remove-and-purge` *after* the upgrade chain
(Homebrew, casks, MAS, the `version-managers` tier,
`make versions-update`, then
`make versions-cleanup` to prune unused tool versions),
so even if `brew upgrade`
resurrects something via dependency resolution the
removal step takes it out before the run completes.
Applying the `version-managers` tier before the removal
loops is what keeps the asdf -> mise cutover safe on a host
that never ran `make install`. That step only happens when
the host lists `version-managers` in its `profiles` array;
a host that never opted in gets no mise install, no
`~/.zshrc` rewrite, and no asdf/direnv removal from an
update run. See
[docs/VERSION_MANAGEMENT.md](docs/VERSION_MANAGEMENT.md).

### Detecting and fixing collisions

`make verify` runs the per-tier Brewfile verification and
then a **same-tier collision check**: any package listed in
BOTH `<tier>/Brewfile` AND that same tier's
`[profile] uninstall` or `[profile] purge` array is
reported, and `make verify` exits non-zero. Cross-tier
collisions are intentional ("opt out at a more-specific
tier") and are not flagged. The check scans every profile
directory on disk, not just the ones this host opts into.

Sample report:

```text
WARN: same-tier collision in profile web
  profiles/web/Brewfile:6       cask 'some-cask'
  config.toml [profile] purge   "cask:some-cask"
  fix: make sanitize    (will comment out the Brewfile line)
```

`make sanitize` resolves each collision by commenting out
the `Brewfile` line (the removal array wins per the
conflict rule in [docs/INSTALL.md](docs/INSTALL.md)) with a
marker:

```text
# sanitized 2026-04-29: also in this tier's [profile] purge array
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

# Remove every macos-setup LaunchAgent (daily, weekly,
# one-time, email-test)
make unschedule-all
```

LaunchAgents run in the user's login session, providing
access to the macOS Keychain for email credentials.

Scheduled jobs set `HOMEBREW_NO_ASK=1` so an unattended
`make update` never hangs on Homebrew 6.0's interactive
`Do you want to proceed? [y/n]` ask-mode prompt. The
runner (`scripts/launchagent_runner.sh`) exports it
directly, because launchd does not source `~/.zshrc`
where the interactive export lives; existing schedules
pick this up on the next repo pull with no
`make schedule-*` re-run.

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
repo only requires re-running `make shell_setup` to repoint
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

# 3. Install msmtp and generate ~/.msmtprc from config.toml.
#    msmtp is a core-tier package and msmtp_setup.sh is a core-tier
#    post_install action, so applying the core tier does both.
make core

# 4. Set [cron] mailto in config.toml with your recipient address

# 5. Test the configuration
make email-test

# 6. Install scheduled jobs to pick up email config
make schedule-daily    # or make schedule-weekly
```

The core tier's `msmtp_setup.sh` post-install action
generates `~/.msmtprc` (mode 0600) from your resolved
`[mailer]` values. The relay password is
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
Each tier's `Brewfile` and `[profile]` section are
**additive** (all tiers applied, in tier order; each
Brewfile filtered against the in-scope `uninstall` +
`purge` arrays).
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
│   ├── Brewfile                # This profile's packages. Unnumbered
│   │                           # and unprefixed: the profile IS the
│   │                           # category
│   ├── aliases.zsh             # Optional: aliases for the tool this
│   │                           # profile adopts (aggregate tier; git
│   │                           # shortcuts + gbc/gbd/gsr live here)
│   └── config.toml             # Optional. [profile] post_install /
│                               # uninstall / purge (per-tier), plus any
│                               # [claude]/[mailer]/[cron] overrides
│                               # (single-winner per section)
├── claude-code-aliases/        # Mostly an aliases.zsh: the cr +
│   ├── aliases.zsh             # cr-repo Claude wrappers and the
│   └── Brewfile                # save/load_claude_auth account
│                               # switchers, plus the jq those need
├── aws/                        # …40 more single-purpose profiles
└── …                           #   (databases, web, plex, yubikey, …)

default/                            # The CORE tier (lowest), in repo root
├── Brewfile                    # Core packages: macos-setup's own
│                               # dependencies + the universal set
├── aliases.zsh
├── config.toml                 # Core scalar config: [claude]
│                               # (branch/hostname), [mailer], [cron],
│                               # and the profiles array. [mailer] ships
│                               # with active shared relay defaults (the
│                               # default tier resolves at runtime);
│                               # [claude], [cron], and profiles stay
│                               # commented out as in-place docs. Also
│                               # carries the core tier's [profile]
│                               # section (post_install / uninstall /
│                               # purge).
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
└── Brewfile                    # Machine-only packages (optional)
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

A profile name may contain only letters, digits, `.`, `_`
and `-`. The name is both a directory component and a
whitespace-delimited word in the Makefile's tier list, so a
name carrying a space would be applied as two phantom tiers
by `make install` while the shell-side tier walk resolved
the real one. A name that fails the pattern is dropped with
a warning at install time and is a hard error in
`make verify`. Every one of these messages — the unusable
name, the unknown name — quotes the offending name next to
the `config.toml` that declares it, since either your host
tier's file or the repo's `default/config.toml` can
contribute one.

## Advanced Usage

### Version Management with mise

The repository uses [mise](https://mise.jdx.dev/) for
reproducible runtime environments. mise subsumes both a
version manager and a directory-scoped environment
loader — the jobs asdf and direnv used to split between
them.

The Makefile targets are named `versions-*`, not after
the tool that implements them, so swapping the
implementation again leaves the public interface — target
names, aliases, and doc lines — alone. The change is
bounded to the scripts that name the tool directly:
`scripts/versions_setup.sh` and `scripts/mise_common.sh`
drive it, `scripts/diagnose.sh` reports on it,
`scripts/asdf_to_mise.sh` migrates a repo onto it, and
`scripts/ensure_mise_zshrc_lines.sh` (called by
`scripts/shell_setup.sh` and by `make update`) /
`scripts/launchagent_runner.sh` put its shims on `PATH`.

```bash
# Install mise and its global config (included in make install).
# This is the INSTALL piece of the asdf -> mise cutover only; it does
# not uninstall asdf/direnv or clean ~/.zshrc. `make install` and
# `make update` do the whole cutover, on a host that lists
# version-managers in its profiles array. See docs/VERSION_MANAGEMENT.md.
make profile version-managers

# Install the versions the resolved config declares
make versions-install

# Check for updates
make versions-outdated

# Install latest versions AND bump the config
# (mise up --bump) — one verb, unlike the old
# pin-then-update split
make versions-update

# Prune unused installed versions (mise prune)
make versions-cleanup-dry-run # Show what would be removed
make versions-cleanup         # Remove them
# (versions-cleanup also runs automatically after
#  versions-update as part of `make update`)

# Add a tool to the current project (writes mise.toml)
mise use node@latest
mise use java@temurin

# See what is active here and which file set it
mise ls --current
```

#### Config files

`mise.toml` is the **one tracked config form**. mise
reads several other forms too (`mise.local.toml`,
`.config/mise/config.toml`, …), all merged, and its
directory walk recurses upward past the git boundary —
so a stray variant applies silently to every repo
beneath it. The `.gitignore` block
`make asdf-to-mise` writes ignores every other form to
keep that from happening.

The global config lives at
`${XDG_CONFIG_HOME:-~/.config}/mise/config.toml` and
carries `[settings] env_file = ".env"`, the true
`dotenv_if_exists` analogue.

#### Migrating a repo from asdf + direnv

```bash
make asdf-to-mise
```

A one-shot, idempotent, **purely additive** converter,
operating on the directory you invoke it from, one repo
per run. It generates `mise.toml` from `.tool-versions`,
writes the `.gitignore` block, and warns about every
asdf/direnv leftover it finds — deleting nothing, moving
nothing, untracking nothing, and committing nothing.

See
[docs/VERSION_MANAGEMENT.md](docs/VERSION_MANAGEMENT.md)
for the full runbook, the multi-version-line pre-flight,
the LuaRocks pin, and the manual cleanup checklist.

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

**Tool versions** are pinned per project in `mise.toml`
and per host in the global mise config
(`${XDG_CONFIG_HOME:-~/.config}/mise/config.toml`). This
repo declares no `mise.toml` of its own, and the global
config lives outside the repo; run `mise ls --current` to
see what is active and which file set it.

### Per-repo config for `/issue:address`

`.claude/rules/repo-config.md` at the repo root tells the
`/issue:address` orchestrator and its subagents
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

`make install` and `make profile claude` (via the
`claude` / `claude-latest` profiles' `post_install`) call
`claude-install` automatically. `make update` runs
`claude-update` as part of its overall update sweep,
and `make outdated` runs `claude-outdated` alongside
the brew/tool-version checks.

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
is skipped/ignored rather than aborting
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
- Optional keys (queried with `dasel`):
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
# The core tier
make core

# One or more profiles, in the order given
make profile dev-core
make profile dev-core visual-studio-code aws

# See what is available (* marks this host's, in order)
make profiles

# Removals: every tier's uninstall / purge array
make uninstall-dry-run
make uninstall
make remove-and-purge-dry-run
make remove-and-purge          # --zap on casks
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
  and clones over HTTPS), but installed by the `1password`
  profile. Set
  it up as your SSH agent when you need SSH auth — see
  [docs/1password-as-ssh-agent.md](docs/1password-as-ssh-agent.md)

## Documentation

- [Shell Configuration & Aliases](docs/SHELL.md)
- [Bootstrap Alternatives](docs/BOOTSTRAP.md)
- [Changelog](docs/CHANGELOG.md)
- [Version Management](docs/VERSION_MANAGEMENT.md)
- [Makefile Usage](docs/MAKEFILE.md)
- [The install model: tiers, Brewfiles, removals](docs/INSTALL.md)
- [Documentation Index](docs/INDEX.md)

## Key Features

### Profile-driven Makefile

- Needs no per-profile knowledge: `make profile
  brand-new` works the moment `profiles/brand-new/` exists
- `make profile <name> [<name>...]` applies profiles in
  the order given, validating every name before applying
  any, and is failure-tolerant with an end-of-run summary
- Post-install actions are declared in each tier's
  `[profile] post_install`, not in the Makefile
- Layered `Brewfile` and `[profile]` support across all
  tiers: default,
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
- Version Management: mise
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
- `make versions-update` installs the latest versions AND
  writes them into the config that declared them
  (`mise up --bump`), so the version it installs is the
  version that becomes active

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
