# How to Add/Remove Apps with MAS & Homebrew

## Prereqs

```bash
# Install Homebrew (if needed) then:
brew install mas
mas account
mas signin "you@example.com"   # interactive prompt
```

## Add an App to a tier's Brewfile

Pick the tier that should own the package — a profile under `profiles/`,
the core tier (`default/`), or your external host tier — and add a line
to its `Brewfile`:

- **Homebrew formula:** `brew "formula-name"`
- **Homebrew cask:** `cask "app-name"`
- **App Store app:** `mas "App Name", id: 123456789`

Then apply that tier:

```bash
make profile web        # a profile
make core               # the core tier
make install            # every tier for this host
```

Those go through the smart filter, so any in-scope `uninstall` / `purge`
entry gets commented out first. To bypass the filter for a quick one-off:

```bash
brew bundle --file=./profiles/web/Brewfile
```

## Remove an App

Declarative options, plus an ad-hoc fallback.

1. **Uninstall (binary only) — recommended for "I might want this back":**
   add the package to the `[profile] uninstall` array in the
   `config.toml` of the appropriate tier (the core tier, a profile, or
   your host tier). `make uninstall` removes it; `make install` filters
   it out from then on. User data (preferences, caches, login items) is
   left on disk.

   ```toml
   [profile]
   uninstall = ["cask:firefox"]
   ```

2. **Purge (binary + user data) — recommended for "I'm done
   with this permanently":** add it to that tier's `[profile] purge`
   array instead. `make remove-and-purge` removes it; `make install`
   filters it out from then on. For casks the runner uses
   `brew uninstall --cask --zap`, which also removes the cask's
   declared user data. For formulae and MAS entries, behavior is
   identical to `uninstall`.

   ```toml
   [profile]
   purge = ["cask:qblocker", "mas:1365531024:1Blocker"]
   ```

   Entry grammar: `"brew:<formula>"`, `"cask:<token>"`, `"mas:<id>"`, or
   `"mas:<id>:<Name>"` (the name is only a log label).

   **Which tier?** A removal entry shadows the package in its own tier and
   every lower-priority tier. Put it in your host tier to opt out of a
   package a profile you otherwise want would install.

3. **Ad-hoc:** delete the corresponding line from the tier's Brewfile and
   then run:

   ```bash
   brew bundle cleanup --file=./profiles/web/Brewfile --force
   ```

   (You can omit `--force` to preview first.)

See [INSTALL.md](INSTALL.md) for the full reference on how the removal
arrays, the smart filter, and the per-tier scope rules interact.

`make update` applies `make uninstall` and `make remove-and-purge`
after its upgrade chain, so routine maintenance enforces the removal
arrays automatically — adding a package to one is enough; no separate
command is required.

## Find MAS App IDs

```bash
mas search "App Name"
mas list              # show installed MAS apps with IDs
```

## Tips

- `brew bundle dump --file=./.snapshot` creates a snapshot of your
  current machine.
- `scripts/mas_export.sh` covers the MAS half separately: it runs
  `mas list` and writes ready-to-paste `mas "<Name>", id: <id>` lines to
  `./MAS-from-this-Mac.snippet` (override the path with `BUNDLE_FILE`).
  It does not call `brew bundle dump`, so it reports no formulae or
  casks.
- Keep each profile small and single-responsibility. A host composes the
  roles it wants by listing several in its `profiles` array, and
  `make profiles` shows what is available.
