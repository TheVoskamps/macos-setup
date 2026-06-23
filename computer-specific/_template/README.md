# Host-tier template

This directory is the **template** for a machine's per-host config tier.
The host tier no longer lives inside the repo. It lives on local disk,
**outside** the repo, at:

```text
${XDG_CONFIG_HOME:-~/.config}/macos-setup/
```

(Override the base path with the `MACOS_SETUP_HOST_DIR` environment
variable — the test suite uses this to point the host tier at a temp
directory.)

`make install` copies this template into that external location **only
if it does not already exist**. It never overwrites your edits: once the
external directory is present, re-running `make install` is a no-op for
the host tier. Backing up / syncing that external directory is your
responsibility.

## Layout

The external host tier mirrors the layout this template ships:

| Path                    | Purpose                                       |
| ----------------------- | --------------------------------------------- |
| `config.toml`           | Scalar config: profiles array + sections.     |
| `aliases.zsh`           | Personal shell aliases (aggregate tier).      |
| `.vscode/settings.json` | VS Code settings override.                    |
| `.cdk.json`             | AWS CDK config override.                      |

The scalar knobs that used to live in separate files (`profiles`,
`config/mailer`, `config/claude`, `cron/mailto`) are now consolidated
into a single, hand-editable `config.toml`, queried with `dasel`
(which must be exactly major version 3 — bootstrap installs and
verifies it, and config reads hard-abort loudly on a non-v3 dasel).
See `config.toml` in this directory for the full set of documented
fields.

You may also add host-only `Install/`, `Uninstall/`, and
`RemoveAndPurge/` files here; they aggregate on top of the in-repo
`default` + `profiles` tiers exactly as the old in-repo host tier did.

## Resolution order (unchanged)

Only the host tier's **location** moved. The resolution **order** is
unchanged:

```text
default/   (in repo, lowest priority)
  < profiles/{name}/         (in repo, in host-declared order)
      < external host tier   (highest priority)
```

## `[cron] mailto`

The `[cron]` section ships commented out, so a fresh seed sends **no**
scheduled-job email. To enable email, uncomment the `[cron]` section in
`config.toml` and set `mailto` to a single recipient address.
