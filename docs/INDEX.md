# macos-setup Documentation Index

Welcome! This index ties together the key documents for
provisioning macOS with this repo.

## Start Here

- **[Makefile Usage](MAKEFILE.md):** How to run the setup
  end‑to‑end (`make install`) or by category.
- **[Install / Uninstall / RemoveAndPurge Index](INSTALL.md):**
  All category `Install/` files with descriptions and
  links, plus the parallel `Uninstall/` and
  `RemoveAndPurge/` frameworks.
- **[Version Management](VERSION_MANAGEMENT.md):**
  `asdf` + `direnv` flow and reproducible runtimes.

## Helpful Notes

- Run `make help` to see all available targets, including
  dynamic ones.
- Each Install target is generated from its filename,
  e.g. `make 02_Install_ui`.
- `04_Install_versionmanagers` also runs
  `asdf-plugins-init`, `asdf-pin-latest`, `asdf-install`,
  and `direnv-setup` automatically.

## Repository Layout

- `Install/` — categorized bundles (security, ui, shell,
  version managers, tools, databases, aws, etc.) —
  formerly `Brewfiles`.
- `Uninstall/` — parallel slots used by `make uninstall`
  and the smart filter on `make install`. Removes the
  binary; leaves user data on disk.
- `RemoveAndPurge/` — parallel slots used by
  `make remove-and-purge` and the smart filter on
  `make install`. Removes the binary AND the cask's
  declared user data via `--zap`.
- `docs/` — this documentation set.
- `scripts/` — helper scripts (e.g., `shell_setup.sh`,
  `install_filter.sh`, `remove_runner.sh`).

## Troubleshooting

- If a `brew bundle` fails, re-run that specific target
  after fixing the issue, or run `make install` again.
- If `asdf` can't resolve a version, run
  `make asdf-plugins-init` then `make asdf-pin-latest`
  and `make asdf-install`.

## Related

- [ChatGPT Session Prompt](./CHATGPT.md)
