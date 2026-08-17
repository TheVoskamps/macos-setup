# Version Management with mise

This repo standardizes runtime versions via
[mise](https://mise.jdx.dev/), which subsumes both a version manager
and a directory-scoped environment loader — the jobs asdf and direnv
used to split between them.

The `version-managers` profile installs it. That profile keeps its
name: `version-managers` is the role, not the implementation.

## Quick Start

1. Install Homebrew bundles (including `mise`): `make versionmanagers`.
   This installs only — it does not uninstall `asdf`/`direnv` or touch
   `~/.zshrc`. See "The host-side cutover is hard, not staged" below
   for the full by-hand sequence, or just run `make install`.
2. Install the versions the resolved config declares:
   `make versions-install`.
3. Add a tool to the current project: `mise use <tool>@latest`
   (writes `mise.toml`).

The Makefile targets are named `versions-*`, not after the tool that
implements them, so swapping the implementation again leaves the
public interface — target names, aliases, and doc lines — alone. The
change is bounded to the places that name the tool directly:
`scripts/versions_setup.sh`, `scripts/mise_common.sh`, the `~/.zshrc`
init lines in `scripts/shell_setup.sh`, the shims `PATH` export in
`scripts/launchagent_runner.sh`, `scripts/diagnose.sh`, and the
`version-managers` profile's `Install/04-Install.versionmanagers`.

| Target | What it does |
| --- | --- |
| `make versions-install` | Install the versions the resolved config declares |
| `make versions-update` | Install latest, bump config (`mise up --bump`) |
| `make versions-outdated` | Report tools with a newer version available |
| `make versions-cleanup` | Remove unused installed versions (`mise prune`) |
| `make versions-cleanup-dry-run` | Show what cleanup would remove |

`make update` runs `versions-update` then `versions-cleanup`;
`make outdated` runs `versions-outdated`.

Unlike the old `asdf-pin-latest` / `asdf-update` split, `make
versions-update` is one verb: it installs the latest version and
writes it into the config that declared it, so the version you just
installed is the version that is active.

## Configuring tools

Per-project, `mise.toml` is the config file. Add tools with
`mise use <tool>@<version>`, e.g.:

```toml
[tools]
node = "24.5.0"
python = "3.13.2"
java = "temurin-26.0.1+8"
lua = "5.4"
```

mise's prefix matching covers most of what the old
`asdf-plugins.toml` DSL did — `java = "temurin"` selects the newest
Temurin JDK (jre builds are named `temurin-jre-*` and are not
selected), so the old `filter` / `filter_exclude` keys have native
equivalents.

There is no native equivalent of the old `max_version` **ceiling**:
`mise latest lua@5.4` returns the newest 5.4.x, which may be above a
declared ceiling. That turned out not to matter here. The one ceiling
the repo carried was `lua max_version = "5.4.7"`, whose recorded
intent was "stay below Lua 5.5" — 5.4.7 was just the newest 5.4.x
when it was written. `lua = "5.4"` is the faithful translation. If
you ever need a true ceiling, use an exact pin.

### The LuaRocks pin

LuaRocks 3.13.0 ships a rockspec with a duplicate `tag` key. Under
asdf's lua plugin that broke the build, so this repo pinned 3.12.2 via
`ASDF_LUA_LUAROCKS_VERSION` — the variable name that plugin reads.
`scripts/versions_setup.sh` still exports
`ASDF_LUA_LUAROCKS_VERSION=3.12.2`, so every `make versions-*`
invocation carries it.

**On mise the export is currently inert.** Verified against mise
2026.8.6 on 2026-08-16: `mise registry` resolves `lua` through
`vfox:mise-plugins/vfox-lua` first, not the asdf plugin, and a
sandboxed `mise install lua@5.4` built 5.4.8 and bootstrapped LuaRocks
**3.13.0** successfully with the export set. The variable neither took
effect nor was needed.

It is kept anyway, because it costs nothing and still applies if you
pin lua to the asdf backend explicitly
(`lua = "asdf:mise-plugins/mise-lua@5.4"`), where the original breakage
is unchanged: upstream `luarocks/luarocks#1851` was closed by a fix to
the *release tooling* (`luarocks/luarocks#1885`), and the shipped
3.13.0 tarball is PGP-signed with a pinned `source_digest` and was
never re-rolled. Tracked in
[issue #6](https://github.com/TheVoskamps/macos-setup/issues/6).

## `.env` loading

The global config sets:

```toml
# ${XDG_CONFIG_HOME:-~/.config}/mise/config.toml
[settings]
env_file = ".env"
```

This is the true `dotenv_if_exists` analogue. The alternative,
`[env] _.file = ".env"` inside a `mise.toml`, resolves the path
relative to the config file that declares it — in the global config
that would look for `~/.env`, not the project's — so it is per-repo
only.

Accepted trade-off: the global setting fires on mise's
directory-change hook, so opening a new terminal tab already sitting
in the directory does not load the `.env`
([jdx/mise#5119](https://github.com/jdx/mise/discussions/5119)). In
exchange the behavior is on everywhere, once, and every per-repo
`mise.toml` stays a pure `[tools]` file. If the new-tab hole bites in
practice, the fallback is a per-repo `[env] _.file`.

## House rule: `mise.toml` is the only tracked config form

mise reads **every** one of these per directory, merged, top wins:

1. `mise.local.toml`
2. `mise.toml`
3. `mise/config.toml`
4. `.mise/config.toml`
5. `.config/mise.toml`
6. `.config/mise/config.toml`
7. `.config/mise/conf.d/*.toml`

They are not alternatives — all present forms load. Worse, the
directory walk recurses upward to the filesystem root and does **not**
stop at a git boundary, so a stray `mise.toml` in `~/Workspaces/`
would silently apply to every repo beneath it. (direnv did not behave
this way: it loaded the nearest `.envrc` only, unless a `source_up`
was explicit.)

So: `mise.toml` is the one tracked config form. Every other form is
gitignored, both to keep machine-local config out of commits and to
signal that the alternative locations are not to be used. The
`.gitignore` block `make asdf-to-mise` writes enforces the signal:

```gitignore
# --- mise (managed by macos-setup `make asdf-to-mise`) ---
# mise.toml is the ONE tracked config form; it is deliberately NOT
# ignored. Everything below is either machine-local or a
# non-canonical location we do not use.
/mise.local.toml
/mise/config.toml
/.mise/config.toml
/.config/mise.toml
/.config/mise/config.toml
/.config/mise/conf.d/
# --- end mise ---
```

Patterns are root-anchored with a leading `/`, so a repo that
legitimately uses `.config/` or a nested `mise/` directory for
unrelated purposes is unaffected.

`.gitignore` is a *signal*, not enforcement — it prevents committing
a stray variant, not creating one. `mise cfg` remains the diagnostic
for "which files actually loaded here".

`.envrc` and `.tool-versions` are deliberately **absent** from the
block. The converter leaves both files in place and warns about them,
so adding an ignore rule would be misleading (they are not
machine-local strays) and, for a tracked file, ineffective. That is a
statement about what the block **writes into other repos**; a repo
that already carried such rules keeps them until its own migration
finishes, and the converter reports them as condition (b) below.

## The host-side cutover is hard, not staged

The `version-managers` profile installs `mise` in its
`Install/04-Install.versionmanagers` and removes `asdf` and `direnv`
in its `RemoveAndPurge/04-RemoveAndPurge.versionmanagers`, in the same
change. Running asdf and mise side by side is the classic failure mode
— both provide shims for the same tools.

### What the cutover consists of

Separate pieces of work, each owned by a different mechanism:

| Piece | Owner |
| --- | --- |
| Install `mise` | slot 04's `Install` + `versions_setup.sh full` |
| Uninstall `asdf` + `direnv` | slot 04's `RemoveAndPurge` |
| Strip orphaned `~/.zshrc` lines | `strip_asdf_zshrc_lines.sh` |
| Add the mise `~/.zshrc` lines | `ensure_mise_zshrc_lines.sh` |

The last two are a pair, and both are their own script for the same
reason: the cutover reaches a host down either of two paths, and each
must leave `~/.zshrc` in the same state. Stripping without adding is
what left a real host with mise installed, asdf and direnv gone, and
no version manager wired into the interactive shell at all.

**`make install` and `make update` each do all of it.** `make install`
runs the slot-04 install and, as a deliberate one-slot exception to
"install does not run the removal loops", the slot-04 RemoveAndPurge
alongside it; the `03-Install.shell` action rewrites `~/.zshrc` from
both sides. `make update` applies the slot-04 `Install` tiers itself
before it reaches the removal loops, then runs those loops and calls
the strip and the add directly, in that order (it never runs
`shell_setup.sh`). The explicit install
step is what carries a host that has never run `make install`:
`brew upgrade` upgrades a formula that is already installed but never
installs an absent one, so without it `update` would remove asdf and
direnv and put nothing in their place.

**Install strictly precedes remove, and the removal is guarded.**
Both paths probe for a reachable mise immediately before they remove
anything, through one shared Makefile macro (`MISE_REACHABLE`), and
hold the removal back when the probe fails — `brew bundle` failed,
the host never opted into the `version-managers` profile, the binary
is off `PATH`. `make update` skips slot 04's `Uninstall` and
`RemoveAndPurge` and skips both `~/.zshrc` rewrites — pointing
`~/.zshrc` at a mise that is not there would error on every shell
startup, which is exactly what the strip exists to prevent;
`make install` skips
its inline slot-04 `RemoveAndPurge`. Both warn and exit non-zero.
Every other slot still applies; only slot 04 is held back. A host is
never left with the old version manager gone and no replacement.

The guard is written out at each destructive call rather than
inferred from the surrounding `set -e`, and
`scripts/test/install_cutover_guard_test.sh` fails if it is removed:
losing a host's only version manager is the failure this whole
section exists to prevent, so it does not rest on a side effect of
some other file's error handling.

**`make versionmanagers` does only the install piece.** It is a
per-slot target, and per-slot targets install; they do not remove.
Driving the cutover by hand therefore takes the sequence:

```bash
make versionmanagers                       # install mise
make 04_RemoveAndPurge_versionmanagers     # uninstall asdf + direnv
make shell                                 # rewrite the ~/.zshrc lines
```

Removing the binaries touches none of the data they left behind:
`~/.asdf/`, `~/.tool-versions`, `~/.config/direnv/lib/use_asdf.sh`,
and every repo's `.envrc` / `.tool-versions` all survive. The
"Manual cleanup checklist" below is what removes those, and it is
yours to run.

See [Shell](SHELL.md) for the exact `~/.zshrc` lines added and removed.

## Migrating a repo from asdf + direnv: `make asdf-to-mise`

`make asdf-to-mise` is a one-shot, idempotent, **purely additive**
converter. It writes mise config and warns about leftovers. It
deletes nothing, moves nothing, untracks nothing, and commits
nothing.

It operates on the directory you invoke it from, one repo per run —
it does not walk `~/Workspaces` hunting for `.envrc` or
`.tool-versions` files.

```bash
cd ~/Workspaces/some-repo
make -C ~/Workspaces/TheVoskamps/macos-setup asdf-to-mise START_DIR="$PWD"
```

(Or just `m asdf-to-mise` if you use the `m` helper, which passes
`START_DIR` for you.)

What it does:

**Globally, on every invocation:**

- Creates `${XDG_CONFIG_HOME:-~/.config}/mise/config.toml` if it is
  absent, importing `~/.tool-versions` when the host has one. (mise
  does not treat `~/.tool-versions` as a global config the way asdf
  did, so this import is what carries a host's global pins across.)
  An existing config is left alone.
- Ensures `[settings] env_file = ".env"` in that file, via a
  grep-guarded edit. A hand-written `[settings]` block survives
  intact; a second run adds nothing.
- Warns about global leftovers.

**Per repo:**

- Aborts unless the target directory is a git repository **root** —
  it writes `.gitignore`, so a subdirectory is almost certainly a
  mistake.
- Converts `.tool-versions` into `mise.toml` via `mise generate
  config`. An existing `mise.toml` is reported and skipped, never
  clobbered.
- Writes the `.gitignore` block above, sentinel-guarded so a re-run
  is a no-op.
- Warns about per-repo leftovers — for `.envrc` and `.tool-versions`,
  reporting each of the independent conditions below (on disk,
  ignore-ruled, tracked) with its own remedy.
- Runs `mise cfg` and `mise ls` so you can see what actually
  resolved before trusting it.

### Pre-flight: multi-version lines abort the run

asdf reads `<tool> <v1> <v2>` as a fallback list. `mise generate
config` turns that into a TOML array, which mise then resolves as
**two tools to install** — silently replacing the pinned build with
the newest prefix match and adding a spurious second version:

```text
java temurin 26.0.1+8     ->  java = ["temurin", "26.0.1+8"]
                          ->  java  temurin-26.0.2+10   (LATEST, not the pin)
                              java  26.0.1+8            (spurious second install)
```

The hyphenated form round-trips exactly:

```text
java temurin-26.0.1+8     ->  java = "temurin-26.0.1+8"
```

So the converter scans `.tool-versions` first and aborts with the
offending line quoted, writing no `mise.toml`. Fix the source line
and re-run. (This is a pre-existing defect in the source file, not a
mise bug — today's asdf is unlikely to be resolving such a line as
intended either.)

## Manual cleanup checklist

`make asdf-to-mise` deliberately deletes nothing. Once you are
satisfied with the conversion, these are yours to remove:

- `~/.asdf/` (or `$ASDF_DATA_DIR` / `~/.local/share/asdf`) — asdf
  plugins, installs, downloads and shims. Typically the multi-GB item.
- `~/.config/direnv/lib/use_asdf.sh` — its only function shells out to
  the now-absent `asdf` binary.
- `~/.tool-versions` — superseded by the global mise config once the
  import ran.
- `<repo>/.envrc` — inert once direnv is uninstalled. If it holds more
  than `use asdf` / `dotenv_if_exists`, those lines have no automatic
  mise equivalent and need a manual `[env] _.path` / `_.source`
  decision.
- `<repo>/.tool-versions` — **check before deleting**; see below.

### Independent conditions per repo leftover

For `.envrc` and `.tool-versions`, "clean up" is not one action.
`make asdf-to-mise` reports the conditions below, which occur in
**any combination**, each with its own remedy:

| Condition | What it means | Remedy |
| --- | --- | --- |
| (a) present on disk | the file is still there | delete it |
| (b) ignore-ruled | a `.gitignore` line hides it | delete that rule |
| (c) tracked in git | the path is in the index | `git rm` it |

They are genuinely independent. Deleting the file leaves the ignore
rule and the index entry. Adding an ignore rule does not delete the
file — and it does **nothing at all** for (c), because `.gitignore`
has no effect on a path already tracked; only `git rm` clears that.
Leaving a rule behind after the file is gone is its own trap: a
re-created `.envrc` is then invisible to `git status`.

This repo's own `.gitignore` still carries `.envrc` and
`/.tool-versions` for exactly this reason — macos-setup has not been
run through `make asdf-to-mise` yet, and dropping the rules ahead of
the files only makes `git status` dirty, which
`scripts/self_update.sh` reads as a reason to stash and pop on every
run. Removing them is an **output** of running the migration against
this repo, not a hand-edit ahead of it.

### The `.tool-versions` drift hazard

A repo's `.tool-versions` is still **loaded** by mise, and it still
works. The two files merge per tool: a tool defined in both resolves
from `mise.toml`, but a tool present **only** in `.tool-versions`
stays active from there.

So anything the conversion missed keeps working invisibly — until
someone deletes `.tool-versions`, at which point it vanishes. Before
deleting it:

```bash
mise ls   # the 'Config Source' column names which file each tool came from
```

Any tool still sourced from `.tool-versions` is one `mise.toml` does
not cover. Only delete the old file once that list is empty.

## CI Notes

- Commit `mise.toml` to ensure reproducible builds in CI and on new
  machines.
