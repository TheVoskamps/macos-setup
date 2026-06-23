# How to Add/Remove Apps with MAS & Homebrew

## Prereqs

```bash
# Install Homebrew (if needed) then:
brew install mas
mas account
mas signin "you@example.com"   # interactive prompt
```

## Add an App to an Install file

- **Homebrew formula:** add `brew "formula-name"`
- **Homebrew cask:** add `cask "app-name"`
- **App Store app:** add `mas "App Name", id: 123456789`

Then apply:

```bash
brew bundle --file=./Install/01-Install.security   # or any chunk
```

To run with the smart filter applied (so any in-scope `Uninstall/` or
`RemoveAndPurge/` entries get commented out), use the Makefile:

```bash
make 01_Install_security
```

## Remove an App

Two declarative options plus an ad-hoc fallback.

1. **Uninstall (binary only) — recommended for "I might want this back":**
   add the package to the matching
   `Uninstall/NN-Uninstall.<suffix>` slot at the appropriate tier
   (default, one of the host's profiles, or host). `make uninstall`
   removes it; `make install` filters it out from then on. User data
   (preferences, caches, login items) is left on disk.

2. **RemoveAndPurge (binary + user data) — recommended for "I'm done
   with this permanently":** add the package to the matching
   `RemoveAndPurge/NN-RemoveAndPurge.<suffix>` slot at the appropriate
   tier. `make remove-and-purge` removes it; `make install` filters it
   out from then on. For casks the runner uses
   `brew uninstall --cask --zap`, which also removes the cask's
   declared user data. For `brew '...'` formulae and `mas '...'`
   entries, behavior is identical to `Uninstall/`.

3. **Ad-hoc:** delete the corresponding line from the Install file and
   then run:

   ```bash
   brew bundle cleanup --file=./Install/01-Install.security --force
   ```

   (You can omit `--force` to preview first.)

See [INSTALL.md](INSTALL.md) for the full reference on how the two
removal trees, the smart filter, and the per-tier scope rules
interact.

`make update` applies `make uninstall` and `make remove-and-purge`
after its upgrade chain, so routine maintenance enforces removal-tree
entries automatically — adding a package to `Uninstall/` or
`RemoveAndPurge/` is enough; no separate command is required.

## Find MAS App IDs

```bash
mas search "App Name"
mas list              # show installed MAS apps with IDs
```

## Tips

- `brew bundle dump --file=./Install/.snapshot` creates a snapshot of
  your current machine.
- Keep category Install files small and focused to speed up installs
  and reduce conflicts.
