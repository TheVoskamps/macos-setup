# Install model: tiers, Brewfiles, and removals

> This repository organizes macOS setup into **tiers**. Each tier
> contributes one unnumbered `Brewfile` plus a `[profile]` section in its
> `config.toml` declaring what else it does: `post_install` commands, and
> `uninstall` / `purge` package lists.
>
> The tiers, lowest priority to highest:
>
> ```text
> default/   (the CORE tier, in repo)
>   < profiles/{name}/    (each profile the host opts into, in list order)
>       < external host tier   (on local disk, outside the repo)
> ```
>
> `make install` applies every tier for this host, in that order.
> `make core` applies just the core tier. `make profile <name> [<name>...]`
> applies just the named profiles, in the order given. `make profiles`
> lists what is available.
>
> This replaced the `NN-Install.<slug>` slot convention (issue #33). The
> numbered prefix had three jobs and two were already dead: categorisation
> (profiles are the category axis now — `profiles/gemini/Install/17-Install.ai`
> named its category twice) and sequencing (no inter-profile dependency
> exists in this tree). The third, post-install hook dispatch, was a
> hardcoded `case` on the slot basename in the `Makefile`, so a new profile
> could not declare a hook without editing the Makefile. It is now a
> `post_install` array in each profile's own `config.toml`.

## Layout

```text
default/
  Brewfile          # the core tier's packages
  config.toml       # [profile] post_install / uninstall / purge, plus
                    # the [claude] / [mailer] / [cron] scalar sections
  aliases.zsh
  .hammerspoon/

profiles/<name>/
  Brewfile          # optional — the profile IS the category, so the file
                    # needs no number and no category in its name
  config.toml       # optional — [profile] post_install / uninstall / purge
  aliases.zsh       # optional (aggregate)

<external host tier>/
  Brewfile          # optional
  config.toml
  ...
```

The **Brewfile stays the package format**. `brew bundle` consumes it
natively and three scripts already parse it; moving `brew` / `cask` /
`mas` / `tap` lines into TOML would need a generator and a retrofit of
every consumer for no gain. The *structure* moved into `config.toml`, not
the packages.

## The `[profile]` section

```toml
[profile]
post_install = ["scripts/vscode_extensions.sh code", "scripts/vscode_setup.sh"]
uninstall = ["brew:asdf"]
purge = ["cask:qblocker", "mas:1365531024:1Blocker"]
```

`[profile]` is the one config.toml section that is **not resolved across
tiers**. `[claude]`, `[mailer]`, and `[cron]` answer "what is the value
for this host", so the highest tier with a value wins. `[profile]`
answers "what does *this* tier contribute", so every tier's section
applies on its own, in tier order.

### `post_install`

Commands run after this tier's Brewfile is applied, in declared order.
Each entry is a path relative to the repo root plus optional arguments;
they are word-split on whitespace, so a command needing quoting belongs in
a script of its own.

A missing or non-executable script, and a script that exits non-zero, are
each reported and tracked — never fatal. The run continues to the next
command and the next tier, and the caller's end-of-run summary names the
tier that failed.

### `uninstall` and `purge`

Entries are `"<kind>:<identifier>"` strings:

| Entry form          | Meaning                                     |
| ------------------- | ------------------------------------------- |
| `"brew:<formula>"`  | a Homebrew formula                          |
| `"cask:<token>"`    | a Homebrew cask                             |
| `"mas:<id>"`        | a Mac App Store app, addressed by id        |
| `"mas:<id>:<Name>"` | the same, with a label for the log line     |

A malformed entry is a hard error everywhere it is read — a silently
ignored removal is exactly what that check exists to prevent.

The arrays differ only for casks:

- `"cask:foo"` in `uninstall` → `brew uninstall --cask foo`
- `"cask:foo"` in `purge` → `brew uninstall --cask --zap foo`

`--zap` also removes the cask's declared user data (preferences, caches,
support files, login items). Use it for software you are done with
permanently. For formulae and MAS entries the two behave identically.

Both modes share `scripts/remove_runner.sh`, selected via
`--mode={uninstall|purge}`.

## How they interact

### `make install` smart filter

Whenever a tier's `Brewfile` is about to be fed to `brew bundle`, it is
pre-processed through `scripts/install_filter.sh`. The filter reads every
in-scope tier's `uninstall` *and* `purge` array and comments out any line
in the Brewfile whose package identifier (formula name, cask token, or
MAS id) appears in either. Each commented-out line is preceded by a marker
naming the tier and the array the removal came from:

```text
# filtered: also removed by profile web (purge)
# cask 'some-cask'
```

The temp file fed to `brew bundle` is the Brewfile with these edits
applied; the original file on disk is untouched.

If a package appears in both arrays at the same tier, the marker names
`purge` — the operationally more impactful action. Both still cause the
line to be filtered; only the marker text differs.

#### Third-party taps are auto-trusted

The filter has one side effect beyond the text transform: for every
`tap '<name>'` directive that survives filtering into the emitted file, it
runs `brew trust --tap '<name>'` before the caller runs `brew bundle`.
Homebrew 6.0 made `brew trust` required for third-party (non-official)
taps; until a tap is trusted, `brew bundle` silently skips its
formulae/casks and still exits 0, so the failure-tolerant install loop
would report success while nothing installs (issue #172). Because
`install_filter.sh` is the single chokepoint every `brew bundle`
invocation routes through, trusting taps here guarantees they are trusted
first.

`brew trust` on an already-trusted tap is a no-op, so this is idempotent
across re-runs. The trust is conservative: a tap whose only formula/cask
was commented out by a removal array is trusted **only if its own `tap`
line still emits**. The brew binary used is overridable via the `BREW`
env var (see "Overriding the package-manager binaries" below); a failed
`brew trust` prints a warning but does not abort the filter.

#### Tier scope: which removals apply to which Brewfile

A tier's Brewfile is filtered against the removal arrays of its own tier
and **every higher-priority tier**:

| Brewfile tier             | Filter against                                  |
| ------------------------- | ----------------------------------------------- |
| Core (`default/`)         | core + all profiles + host                      |
| Profile `profiles/{name}` | `{name}` + every profile listed after it + host |
| Host                      | host only                                       |

Read the inverse way: a removal entry shadows the package in its own tier
and every **lower-priority** tier. So a host-tier entry (highest priority)
shadows the package everywhere. A profile-tier entry shadows it in that
profile and in every lower-priority tier — earlier-listed profiles and
core. A core entry only shadows core, since nothing is below it. The host
tier's own Brewfile is filtered against host removals only, because
nothing outranks it.

This is what makes "I opted into `web` but I don't want its Firefox"
expressible: put `uninstall = ["cask:firefox"]` under `[profile]` in the
host tier's `config.toml`, keep the `web` profile, and Firefox is
commented out of `web`'s Brewfile before `brew bundle` ever sees it.

The scope rule is unchanged from the numbered-slot era. Only the key
changed, from a slot basename to a tier root, and only the source changed,
from a peer file to a `config.toml` array.

#### The one tier `make install` also removes

Filtering is normally the *whole* of `make install`'s relationship to the
removal arrays: it never runs the removal loops, so a package already
installed on the host stays installed even when a removal array lists it.
The `version-managers` profile is the one exception. Inside `make
install`'s tier loop — not in `make profile version-managers` — that
tier's `purge` array is applied inline, right after the tier itself. The
asdf → mise cutover cannot be half-applied (asdf and mise both provide
shims for the same tools, so a host carrying both is the failure mode the
cutover exists to prevent), and `make install` is the entry point a host
reaches after `git pull`. The inline call goes through
`scripts/remove_runner.sh` with a `--banner`, exactly like the loops, so
the quiet gating below applies to it unchanged. See
[Version Management](VERSION_MANAGEMENT.md).

### `make uninstall` and `make uninstall-dry-run`

`make uninstall` walks every tier for this host in tier order, running
`scripts/remove_runner.sh --mode=uninstall` against each. The runner:

- skips entries that aren't currently installed
- runs `brew uninstall --formula` for `brew:` entries
- runs `brew uninstall --cask` for `cask:` entries
- runs `sudo mas uninstall <id>` for `mas:` entries (best-effort; failure
  is logged as a warning, not fatal)
- aborts on a malformed entry

`make uninstall-dry-run` prints what `make uninstall` would do without
making any changes.

### `make remove-and-purge` and `make remove-and-purge-dry-run`

`make remove-and-purge` walks the same tiers with `--mode=purge`, reading
each tier's `purge` array instead. The only behavioral difference is that
for `cask:` entries it runs `brew uninstall --cask --zap`.

**These are destructive: `--zap` removes the cask's declared user data.
Rehearse with `make remove-and-purge-dry-run` first.**

Log lines are prefixed with the active mode (`[uninstall]` vs `[purge]`)
so combined runs are unambiguous.

#### Quiet by default for tiers that remove nothing

Nearly every tier removes nothing, so a `make update` (which runs both
removal loops) would otherwise print a `==> Applying ...` /
`Processing` / `Done:` trio per tier that carries no signal. Output is
therefore gated on whether the tier's array **for the active mode** has
any entry:

- **Default (non-VERBOSE):** a tier with an empty or absent array for that
  mode prints NOTHING — neither the `==> Applying ...` banner nor the
  runner's `Processing` / `Done` lines.
- A tier with at least one entry prints fully, **including**
  `skip: <pkg> not installed` lines — those are useful, so they stay
  visible.
- **`VERBOSE=1`** restores all lines for every tier, including empty ones,
  for debugging.

The gate is per mode, not per tier: a tier declaring only a `purge` array
stays silent during the uninstall pass.

The decision is made in one place (`scripts/remove_runner.sh`, the only
code that reads the array); the Makefile hands it the banner text via
`--banner=<text>`, so the banner and the runner's lines are always shown
or suppressed together. Malformed-entry aborts are unaffected — they still
print a visible error.

The install side has the matching gate in `scripts/apply_tier.sh`: a tier
with no Brewfile, and a tier with no `post_install` entries, say nothing
about it unless `VERBOSE` is set. The positive `==> Applying ...` lines
and every failure line always print.

### `make update` applies both removal arrays

`make update` runs `make uninstall` and `make remove-and-purge` *after*
its upgrade chain (Homebrew, casks, MAS, the version-managers tier when
the host opts into it, then the mise update and prune), so routine
maintenance keeps the in-scope
removals enforced even when `brew upgrade` resurrects a package via
dependency resolution. Adding a package to a removal array is enough — the
next `make update` will take it out without a separate command.

The one tier `make update` will hold back is `version-managers`. Its
`purge` array takes asdf and direnv out, and the mise that replaces them
is installed by that same tier earlier in the run. It is held back when:

- **The host did not opt into the profile** — `version-managers` is
  absent from its `profiles` array, which is what the `VM_OPTED_IN`
  Makefile variable tests. `update` skips the tier apply and both
  `~/.zshrc` rewrites, prints one line, and leaves the exit status alone.
  That is a normal configuration, not a failure. The removal loops need
  no skipping here: they walk the host's tiers, which do not include this
  one.
- **mise is still unreachable after the install step.** `update` skips
  that tier in both removal loops — via the `REMOVE_SKIP_TIERS` Makefile
  variable that `_uninstall_loop` and `_remove_and_purge_loop` honor —
  skips both `~/.zshrc` rewrites, warns, and exits non-zero.

Every other tier applies normally in both cases.
See [VERSION_MANAGEMENT.md](VERSION_MANAGEMENT.md).

See [Makefile Usage](MAKEFILE.md#common-targets) for the full
`make update` description.

### `make verify` and `make sanitize`

`make verify` verifies each tier's Brewfile and then runs a same-tier
collision check: any package listed in BOTH `<tier>/Brewfile` AND that
same tier's `[profile] uninstall` or `[profile] purge` array is reported,
and `make verify` exits non-zero. Cross-tier collisions are intentional
("opt out at a more-specific tier") and are not flagged.

The collision check scans **every** profile directory on disk, not just
the ones this host opts into: a same-tier collision inside a profile
nobody has opted into yet is still a bug in the repo.

`make verify` also fails loudly (hard error, before the per-tier checks)
if the host's external-host-tier `config.toml` `profiles` array lists a
profile with no matching `profiles/{name}/` directory. At install time the
same condition is a warning, and the missing tier is skipped.

`make sanitize` resolves each reported collision by commenting out the
offending line in the `Brewfile` (the removal array wins) with a marker
naming the array, and writes a `.bak` next to each edited file. Review the
diff, commit the change, and remove the `.bak` files when satisfied.

### Applying tiers by hand

```bash
make install                        # every tier for this host, in order
make core                           # the core tier only
make profile web                    # one profile
make profile web aws databases      # several, in the order given
make profiles                       # list every profile in the repo
```

`make profile` validates **every** name before applying **any**, so a typo
in the fifth name aborts with exit 2 rather than half-applying the first
four. It is failure-tolerant with an end-of-run summary: a mid-list
failure does not stop the later profiles, and the run exits non-zero
naming what failed.

Adding `profiles/brand-new/` requires no Makefile edit — the known-profile
list is a directory glob.

`make profile --name <foo>` is **not** achievable: make consumes
`--`-prefixed arguments as its own options before the Makefile sees them
(`make: unrecognized option '--name'`). The positional form covers it and
supports ordered multi-install.

Two accepted rough edges, both on already-failing paths:

- `make profile install` emits `warning: overriding commands for target
  'install'` (the argument-as-phony-no-op trick), then validation rejects
  `install` as an unknown profile and exits 2 before anything runs. Plain
  `make install` is unaffected.
- `make install profile web` — `profile` is not the first goal, so the
  argument list is empty and the usage error fires after `install` runs.

### Overriding the package-manager binaries

Every binary the install and removal paths shell out to is overridable
by an env var of the same name, all in one form
(`VAR="${VAR:-default}"`) and all defaulting to whatever is on `PATH`:

| Var    | Overrides                | Honored by                       |
| ------ | ------------------------ | -------------------------------- |
| `BREW` | the `brew` binary        | every script listed below        |
| `MAS`  | the `mas` binary         | `remove_runner.sh`               |
| `SUDO` | the `sudo` driving `mas` | `remove_runner.sh`               |

- `scripts/apply_tier.sh` — the `brew bundle` call.
- `scripts/install_filter.sh` — the `brew trust --tap` side effect
  described under
  [Third-party taps are auto-trusted](#third-party-taps-are-auto-trusted).
- `scripts/remove_runner.sh` — **every** shell-out, the
  `brew list` and `mas list` probes as well as the `brew uninstall` /
  `sudo mas uninstall` calls. The probe matters as much as the
  uninstall: a probe answered by the real binary is exactly what
  decides whether a real removal follows, so an override that covered
  only the uninstall would not make a test run safe.

`SUDO` exists because the mas removal is `sudo mas uninstall`, so the
override has to compose: stub only `MAS` and the real `sudo` still
runs it, stub only `SUDO` and the real `mas` is what gets run.

The Makefile exposes `BREW` as a make variable, and GNU make exports
command-line variables into every recipe's environment — so
`make remove-and-purge BREW=/path/to/stub MAS=/path/to/stub
SUDO=/path/to/stub` reaches `remove_runner.sh` for all three, not just
the `$(BREW)` references in the recipes. This is what lets the test
suite drive the removal loops without touching real Homebrew, the real
Mac App Store, or real `sudo`.
`scripts/test/remove_runner_brew_override_test.sh` fails if a bare
`brew`, `mas`, or `sudo` call is reintroduced into the runner.

### Removals never cascade, and never lose the interpreter

Two invariants keep a removal run from breaking its own later steps.

`scripts/remove_runner.sh` exports `HOMEBREW_NO_AUTOREMOVE=1`. By
default `brew uninstall` follows up with an automatic `brew autoremove`
that drops every formula nothing depends on any more — which is how
uninstalling `asdf` once took Homebrew's `bash` formula with it
mid-run. The runner is the one place both removal modes actually call
`brew`, so the export covers `make uninstall`, `make remove-and-purge`,
both of `make update`'s loops, and the version-managers purge
`make install` applies inline. Pruning genuinely unneeded dependencies
stays available as a deliberate, separate `brew autoremove`.

Every Makefile recipe names bash as `$(BASH_BIN)` — the absolute
`/bin/bash`, which is also `SHELL` — rather than a `PATH`-resolved bare
`bash`. On a host whose `PATH` prefers `/opt/homebrew/bin`, losing the
Homebrew bash mid-run made every later recipe line die with
`/bin/bash: /opt/homebrew/bin/bash: No such file or directory`, and the
casualty that mattered was `make update`'s `~/.zshrc` strip: asdf and
direnv were removed but their init lines stayed, erroring on every
shell startup. `/bin/bash` ships with macOS and no Homebrew operation
can remove it. The same holds for the scripts that re-invoke bash
themselves: `shell_setup.sh` and `claude_repo_setup.sh` run their
helper scripts under `/bin/bash`, and
`ensure_mise_zshrc_lines.sh` runs its reachability probe under
`/bin/bash -lc`. `scripts/test/absolute_bash_test.sh` fails if a bare
`bash` invocation is reintroduced into the Makefile, `shell_setup.sh`,
or `claude_repo_setup.sh`, or if the export above is dropped.

## See also

- [Makefile Usage](MAKEFILE.md)
- [Version Management](VERSION_MANAGEMENT.md)
