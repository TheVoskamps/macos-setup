# Version Management with mise

This repo standardizes runtime versions via
[mise](https://mise.jdx.dev/), which subsumes both a version manager
and a directory-scoped environment loader — the jobs asdf and direnv
used to split between them.

The `version-managers` profile installs it. That profile keeps its
name: `version-managers` is the role, not the implementation.

## Quick Start

1. Install Homebrew bundles (including `mise`): `make versionmanagers`.
2. Install the versions the resolved config declares:
   `make versions-install`.
3. Add a tool to the current project: `mise use <tool>@latest`
   (writes `mise.toml`).

The Makefile targets are named `versions-*`, not after the tool that
implements them, so swapping the implementation again is a change to
`scripts/versions_setup.sh` rather than to every caller, alias, and
doc line.

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

lua builds must use LuaRocks 3.12.2: LuaRocks 3.13.0 ships a broken
rockspec (duplicate `tag` key) that fails to parse on Lua 5.5+ and
also fails during bootstrap on 5.4.x.
`scripts/versions_setup.sh` exports
`ASDF_LUA_LUAROCKS_VERSION=3.12.2` for this reason, so every
`make versions-*` invocation carries it. If you run `mise install
lua@...` by hand outside `make`, export it yourself.

Upstream `luarocks/luarocks#1851` being closed is **not** license to
drop the pin: it was closed by a fix to the *release tooling*
(`luarocks/luarocks#1885`). The shipped 3.13.0 tarball is PGP-signed
with a pinned `source_digest` and was never re-rolled, so it is still
broken. Dropping the pin needs a 3.13.1 release. Tracked in
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
- Warns about per-repo leftovers.
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
