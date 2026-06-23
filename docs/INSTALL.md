# Install / Uninstall / RemoveAndPurge Index

> This repository organizes macOS setup into multiple `Install/` files
> (formerly `Brewfiles`), each grouped by purpose. They are applied in
> numeric order by `make install`, or individually via the auto-generated
> per-file targets (e.g. `make 01_Install_security` or `make security`).
>
> Each `Install/NN-Install.<suffix>` has two parallel removal slots:
> `Uninstall/NN-Uninstall.<suffix>` (binary-only removal) and
> `RemoveAndPurge/NN-RemoveAndPurge.<suffix>` (also removes the cask's
> declared user data via `--zap`). Entries listed in either tree are
> removed by `make uninstall` / `make remove-and-purge` and are filtered
> out of any matching `Install/` file at install time, so a single source
> of truth keeps a package out of a machine.
>
> Sections inside each `Install/`, `Uninstall/`, and `RemoveAndPurge/`
> file are consistently grouped into `brew` (formulae), `cask` (apps),
> and `mas` (Mac App Store) entries, followed by an `Other` section for
> comments and special cases.

## Install files

- [00-Install.core](../Install/00-Install.core) —
  Core Homebrew taps and essential system setup
- [01-Install.security](../Install/01-Install.security) —
  Security and privacy tools (1Password, VPNs,
  firewalls, etc.)
- [02-Install.ui](../Install/02-Install.ui) —
  User interface enhancements, Finder tweaks, and
  productivity tools
- [03-Install.shell](../Install/03-Install.shell) —
  Shell environment, terminal tools, and related
  utilities
- [04-Install.versionmanagers](../Install/04-Install.versionmanagers)
  — Version managers and environment tooling (asdf,
  direnv, etc.)
- [05-Install.tools](../Install/05-Install.tools) —
  General developer tools and utilities
- [06-Install.messaging](../Install/06-Install.messaging)
  — Messaging and communication apps
- [07-Install.browsers](../Install/07-Install.browsers) —
  Web browsers and related tools
- [08-Install.proton](../Install/08-Install.proton) —
  Proton and related software
- [09-Install.development](../Install/09-Install.development)
  — Developer IDEs, editors, and coding-related tools
- [10-Install.backups](../Install/10-Install.backups) —
  Backup and sync utilities
- [11-Install.aws](../Install/11-Install.aws) —
  Amazon Web Services CLI and related tools
- [12-Install.componentization](../Install/12-Install.componentization)
  — Componentization and containerization tools
- [13-Install.data](../Install/13-Install.data) —
  Data science, analysis, and visualization tools
- [14-Install.databases](../Install/14-Install.databases)
  — Database clients, servers, and admin tools
- [15-Install.ripping](../Install/15-Install.ripping) —
  Media ripping and transcoding tools
- [16-Install.sdcards](../Install/16-Install.sdcards) —
  SD card imaging and management tools
- [17-Install.ai](../Install/17-Install.ai) —
  Artificial intelligence, ML, and related utilities
- [18-Install.msoffice](../Install/18-Install.msoffice) —
  Microsoft Office via MAS (Word, Excel, PowerPoint).
  Outlook, OneNote, OneDrive are present but commented
  out.
- [19-Install.contentviewers](../Install/19-Install.contentviewers)
  — Content viewing and media applications

## Uninstall files

A parallel `Uninstall/NN-Uninstall.<suffix>` exists for every
`Install/NN-Install.<suffix>` slot. The repository ships them empty
(header comments only). Add entries when you want a package gone from
this machine.

`Uninstall/` removes the binary but **leaves user data**
(preferences, caches, login items in `~/Library`, etc.) on disk, so
reinstalling later picks up where you left off.

The Uninstall format mirrors a Brewfile:

```text
brew 'foo'
cask 'foo'
mas 'Name', id: NNNNN
```

`tap '...'` directives are ignored. Comments and blank lines are
ignored. Any other directive is an error.

## RemoveAndPurge files

A parallel `RemoveAndPurge/NN-RemoveAndPurge.<suffix>` also exists
for every `Install/NN-Install.<suffix>` slot, with the same format
and the same parser. The repository ships them empty (header comments
only). Profile and host tiers carry no pre-populated removal entries;
create them lazily when needed.

The only behavioral difference vs. `Uninstall/` is for casks:

- `cask 'foo'` in `Uninstall/`        -> `brew uninstall --cask foo`
- `cask 'foo'` in `RemoveAndPurge/`   -> `brew uninstall --cask --zap foo`

`--zap` also removes the cask's declared user data (preferences,
caches, support files, login items). Use this for software you're
done with permanently. For `brew '...'` formulae and `mas '...'`
entries the two trees behave identically.

Both trees share `scripts/remove_runner.sh`, which takes a
`--mode={uninstall|purge}` flag (defaults to `uninstall` for
backward compatibility). The Makefile passes the flag explicitly at
every call site.

## How they interact

### `make install` smart filter

Whenever `make install` (or a per-`Install/` target) is about to feed a
file to `brew bundle`, it pre-processes the file through
`scripts/install_filter.sh`. The filter looks at every in-scope
`Uninstall/` *and* `RemoveAndPurge/` file of the same numbered slot
and comments out any line in the Install file whose package
identifier (formula name, cask name, or MAS id) is listed in either
tree. Each commented-out line is preceded by a marker that names the
file the entry came from:

```text
# filtered: also listed in Uninstall/07-Uninstall.browsers
# cask 'some-cask'
```

```text
# filtered: also listed in RemoveAndPurge/07-RemoveAndPurge.browsers
# cask 'some-cask'
```

The temp file fed to `brew bundle` is the Install file with these
edits applied; the original file on disk is untouched.

#### Third-party taps are auto-trusted

The filter has one side effect beyond the text transform: for every
`tap '<name>'` directive that survives filtering into the emitted
file, it runs `brew trust --tap '<name>'` before the caller runs
`brew bundle`. Homebrew 6.0 made `brew trust` required for
third-party (non-official) taps; until a tap is trusted,
`brew bundle` silently skips its formulae/casks and still exits 0, so
the failure-tolerant install loop would report success while nothing
installs (issue #172). Because `install_filter.sh` is the single
chokepoint every `brew bundle` invocation routes through, trusting
taps here guarantees they are trusted first.

`brew trust` on an already-trusted tap is a no-op, so this is
idempotent across re-runs. The trust is conservative: a tap whose
only formula/cask was commented out by the `Uninstall/` or
`RemoveAndPurge/` filter is trusted **only if its own `tap` line
still emits**. The brew binary used is overridable via the `BREW`
env var (the same knob the Makefile exposes); a failed
`brew trust` prints a warning but does not abort the filter.

If a package appears in both `Uninstall/` and `RemoveAndPurge/` at
the same tier, the filter marker names `RemoveAndPurge/` — the
operationally more impactful action. Both still cause the line to
be filtered; only the marker text differs.

The "in-scope" set depends on which tier of the Install file is being
applied. The tier order, lowest to highest priority, is:

```text
default  <  profile[0]  <  profile[1]  <  ...  <  profile[n]  <  host
```

…where `profile[0..n]` are the host's profiles in the order they are
listed in the `profiles` array of the **external host tier**'s
`config.toml` (lowest priority first). The host tier lives OUTSIDE the
repo, at `${XDG_CONFIG_HOME:-~/.config}/macos-setup/` (override with
`MACOS_SETUP_HOST_DIR`); the repo keeps only `default` and `profiles`.
An Install file is filtered against the `Uninstall/` and
`RemoveAndPurge/` slots of its own tier and **every higher-priority
tier**. Both peer trees are scanned at each in-scope tier:

| Install tier              | Filter against                                  |
| ------------------------- | ----------------------------------------------- |
| Default (`Install/`)      | default + all profiles + host                   |
| Profile `profiles/{name}` | `{name}` + every profile listed after it + host |
| Host                      | host only                                       |

Read the inverse way: a removal entry shadows the package in its own
Install tier and every **lower-priority** Install tier. So a host-tier
`Uninstall/` or `RemoveAndPurge/` entry (highest priority) shadows the
package in every Install tier. A profile-tier entry shadows the
package in that profile's Install and in every lower-priority Install
(earlier-listed profiles and default) — the tiers that profile
outranks. A default entry only shadows the default Install, since
nothing is below it. A host-tier Install file is only filtered against
host removals, because nothing outranks it.

### `make uninstall` and `make uninstall-dry-run`

`make uninstall` walks every `Uninstall/` file in numeric order. For
each file it runs `scripts/remove_runner.sh --mode=uninstall` against
the default tier, then each of the host's profiles in list order, then
the host tier (whichever exist) in that order. The runner:

- skips entries that aren't currently installed
- runs `brew uninstall --formula` for `brew '...'` lines
- runs `brew uninstall --cask` for `cask '...'` lines
- runs `sudo mas uninstall <id>` for `mas '...'` lines (best-effort;
  failure is logged as a warning, not fatal)
- ignores `tap '...'` directives
- aborts on a malformed line or unknown directive

`make uninstall-dry-run` prints what `make uninstall` would do without
making any changes.

You can also target a single Uninstall slot. These targets execute
real uninstall operations; rehearse with `DRY_RUN=1` first to confirm
what will happen:

```bash
make 07_Uninstall_browsers DRY_RUN=1   # rehearsal: prints actions, no changes
make 07_Uninstall_browsers             # real run
```

### `make remove-and-purge` and `make remove-and-purge-dry-run`

`make remove-and-purge` walks every `RemoveAndPurge/` file in numeric
order. For each file it runs `scripts/remove_runner.sh --mode=purge`
across the default tier, then each of the host's profiles in list
order, then the host tier (whichever exist) in that order. The runner
is the same shared script as for `make uninstall`;
the only behavioral difference is that for `cask '...'` lines it
runs `brew uninstall --cask --zap`, which also removes the cask's
declared user data (preferences, caches, support files, login items).
For `brew '...'` formulae and `mas '...'` entries the behavior is
identical to `make uninstall`.

`make remove-and-purge-dry-run` prints what `make remove-and-purge`
would do without making any changes.

You can also target a single RemoveAndPurge slot. **These targets are
destructive: they pass `--zap` to cask uninstalls, which removes the
cask's declared user data (preferences, caches, support files, login
items). ALWAYS rehearse with `DRY_RUN=1` first** to confirm what will
happen:

```bash
make 07_RemoveAndPurge_browsers DRY_RUN=1   # rehearsal: prints actions, no changes
make 07_RemoveAndPurge_browsers             # real run; --zap on casks
```

Log lines are prefixed with the active mode (`[uninstall]` vs
`[purge]`) so combined runs are unambiguous.

#### Quiet by default for empty slots

Nearly every numbered slot file is just a comment header with no actual
package to remove, so a `make update` (which runs both removal loops)
would otherwise print dozens of `==> Applying ...` /
`[uninstall] Processing` / `Done:` lines that carry no signal. Output
is therefore gated on whether the slot file has any **active directive**
— an uncommented, non-blank `brew '...'`, `cask '...'`, or `mas '...'`
line:

- **Default (non-VERBOSE):** a slot file with ZERO active directives
  prints NOTHING — neither the `==> Applying global/profile/
  computer-specific Uninstall|RemoveAndPurge: <file>` banner nor the
  runner's `[uninstall]/[purge] Processing <file>` / `Done: <file>`
  lines.
- A slot file with at least one active directive prints fully,
  **including** `skip: <pkg> not installed` lines — those are useful, so
  they stay visible.
- **`VERBOSE=1`** restores all lines for every slot, including empty
  ones, for debugging.

This applies to both the `Uninstall/` and `RemoveAndPurge/` trees across
all tiers (global + profile + computer-specific), and so to
`make uninstall`, `make remove-and-purge`, `make update`, the per-slot
`NN_Uninstall_*` / `NN_RemoveAndPurge_*` targets, and the dry-run
companions. The active-directive decision is made in one place
(`scripts/remove_runner.sh`); the Makefile hands it the banner text via
`--banner=<text>`, so the banner and the runner's lines are always shown
or suppressed together. Malformed-directive aborts are unaffected — they
still print a visible error.

### `make update` applies both removal trees

`make update` runs `make uninstall` and `make remove-and-purge` *after*
its upgrade chain (Homebrew, casks, MAS, asdf), so routine maintenance
keeps the in-scope `Uninstall/` and `RemoveAndPurge/` entries enforced
even when `brew upgrade` resurrects a package via dependency
resolution. Adding a package to either removal tree is enough — the
next `make update` will take it out without a separate command.

See [Makefile Usage](MAKEFILE.md#common-targets) for the full
`make update` description.

### `make verify` and `make sanitize`

`make verify` runs the per-Install verification and then a same-tier
collision check: any package listed in BOTH
`<tier>/Install/NN-Install.suffix` AND that same tier's
`Uninstall/NN-Uninstall.suffix` (or
`RemoveAndPurge/NN-RemoveAndPurge.suffix`) is reported, and
`make verify` exits non-zero. Cross-tier collisions are intentional
("opt out at a more-specific tier") and are not flagged.

`make verify` also fails loudly (hard error, before the per-Install
checks) if the host's external-host-tier `config.toml` `profiles` array
lists a profile with no matching `profiles/{name}/` directory. At install time
the same condition is a warning, and the missing tier is skipped.

`make sanitize` resolves each reported collision by commenting out
the offending line in the `Install/` file (the removal-tree peer wins
per the conflict rule above) with a marker that names the peer file,
and writes a `.bak` next to each edited file. Review the diff, commit
the change, and remove the `.bak` files when satisfied. See
[Makefile Usage](MAKEFILE.md#common-targets) for full details.

### Per-`Install/` Make targets

Every `Install/NN-Install.<suffix>` gets an auto-generated target. Both
the canonical underscore form and the original dotted basename are
recognised:

```bash
make 01_Install_security
make 01-Install.security
make security                    # suffix alias
make 01                          # numeric alias
```

## See also

- [Makefile Usage](MAKEFILE.md)
- The triad `Install/` ↔ `Uninstall/` ↔ `RemoveAndPurge/` is now in
  place. Pick `Uninstall/` to remove the binary (leaves
  caches/preferences/data on disk) or `RemoveAndPurge/` for a clean
  wipe (uses `brew uninstall --cask --zap`).
