# Version Management with asdf

This repo standardizes runtime versions via [asdf](https://asdf-vm.com/).

## Quick Start

1. Install Homebrew bundles (including `asdf`, `direnv`).
2. Initialize plugins: `make asdf-plugins-init`
3. Pin exact versions: `make asdf-pin-latest` (writes to `.tool-versions`)
4. Install runtimes: `make asdf-install`
5. Optional: per-language targets
   - `make asdf-node`
   - `make asdf-python`
   - `make asdf-pnpm`
   - `make asdf-lua`

## Plugin Configuration

Per-plugin filtering and version ceilings are configured in
`asdf-plugins.toml`, a single-winner file: the highest-priority
tier that has it wins (host > the host's profiles in reverse list
order > default). The default file lives at
`default/asdf-plugins.toml`.

### Available Keys

Each `[plugin]` section can contain:

| Key | Description |
| --- | ----------- |
| `filter` | Grep pattern applied to `asdf list all <plugin>` output |
| `filter_exclude` | Grep `-v` pattern to remove unwanted matches |
| `max_version` | Version ceiling (versions must be `<=` this via `sort -V`) |

### Example

```toml
[java]
filter = "^temurin-"
filter_exclude = "jre"
# max_version = "temurin-25.0.2+10.0.LTS"
```

This replaces the previously hardcoded Java/Temurin filter
with a config-driven approach. Any plugin can now have its
own filtering rules.

Plugins without a section in `asdf-plugins.toml` default to
`asdf latest <plugin>` with no filtering.

### Override per Machine

To use a different filter on a specific machine, create
`asdf-plugins.toml` in the external host tier
(`${XDG_CONFIG_HOME:-~/.config}/macos-setup/asdf-plugins.toml`)
with the desired `[plugin]` section. The most-specific
file wins.

## direnv Integration

- Add to your `~/.zshrc`:

  ```sh
  eval "$(direnv hook zsh)"
  ```

- Then run:

  ```sh
  make direnv-setup
  ```

## CI Notes

- Commit `.tool-versions` to ensure reproducible builds in CI and on new machines.
