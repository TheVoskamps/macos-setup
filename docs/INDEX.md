# macos-setup Documentation Index

Welcome! This index ties together the key documents for
provisioning macOS with this repo.

## Start Here

- **[Makefile Usage](MAKEFILE.md):** How to run the setup
  end‑to‑end (`make install`) or one profile at a time.
- **[The install model](INSTALL.md):** Tiers, `Brewfile`s,
  the `[profile]` section (`post_install` / `uninstall` /
  `purge`), the smart filter, and the tier-scope rules.
- **[Version Management](VERSION_MANAGEMENT.md):**
  `mise` flow, reproducible runtimes, and the
  `make asdf-to-mise` migration runbook.

## Helpful Notes

- Run `make help` to see all documented targets plus every
  profile in the repo; `make profiles` marks the ones this
  host opts into.
- Apply one or more profiles by name, in the order given:
  `make profile web aws`.
- `make profile version-managers` also ensures the global
  `mise` config and installs the declared tool versions
  automatically. It does **not** uninstall `asdf`/`direnv`
  or clean `~/.zshrc` — `make install` and `make update` do
  that, and only on a host whose `profiles` array lists
  `version-managers`; see
  [Version Management](VERSION_MANAGEMENT.md).

## Repository Layout

- `default/` — the **core tier**: its `Brewfile` holds the
  packages every machine gets, and its `config.toml`
  carries the scalar config plus the core tier's
  `[profile]` section.
- `profiles/<name>/` — one directory per profile, each
  with an optional `Brewfile`, `config.toml`, and
  `aliases.zsh`. The profile IS the category, so nothing
  is numbered.
- The **external host tier**, outside the repo at
  `${XDG_CONFIG_HOME:-~/.config}/macos-setup/`, is the
  highest-priority tier and has the same shape.
- `docs/` — this documentation set.
- `scripts/` — helper scripts (e.g., `apply_tier.sh`,
  `shell_setup.sh`, `install_filter.sh`,
  `remove_runner.sh`).

## Troubleshooting

- If a `brew bundle` fails, re-run that specific target
  after fixing the issue, or run `make install` again.
- If a tool version isn't resolving, run `mise cfg` to see
  which config files actually loaded in that directory,
  then `make versions-install`.

## SSH / Credentials (Reference)

The repo is public and `bootstrap.sh` clones it over HTTPS, so SSH is
optional. These docs cover SSH auth for when you need it (pushing to
this repo, cloning private repos):

- **[Using 1Password as Your SSH Agent](1password-as-ssh-agent.md):**
  Base setup — enable the agent, `agent.toml`, the `~/.ssh/config`
  socket, and verification.
- **[1Password SSH Agent for Multiple GitHub Accounts](CONFIGURING_1PASSWORD_SSH_AGENT_FOR_MULTIPLE_GITHUB_ACCOUNTS_ON_MACOS.md):**
  The host-alias / bookmark layer for two-or-more accounts on
  `github.com`.
- **[Bootstrapping Alternatives](BOOTSTRAP.md):** Manual SSH-key clone,
  fresh key generation, and HTTPS + PAT.

## Related

- [ChatGPT Session Prompt](./CHATGPT.md)
