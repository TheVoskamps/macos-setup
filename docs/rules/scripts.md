# Scripts

## Each script under `scripts/` owns one job

| Script                          | Job                                       |
| ------------------------------- | ----------------------------------------- |
| `config_common.sh`              | Tier resolution; tier list; config reads  |
| `apply_tier.sh`                 | Apply one tier: Brewfile + post_install   |
| `install_filter.sh`             | Filter a Brewfile against removals        |
| `remove_runner.sh`              | Run one tier's uninstall or purge array   |
| `verify.sh`                     | Verify each tier's Brewfile installs      |
| `collision_check.sh`            | Report or fix same-tier collisions        |
| `require_dasel_on_path.sh`      | Up-front `dasel`-on-PATH gate             |
| `list_profiles.sh`              | Print this host's ordered profile list    |
| `host_tier_dir.sh`              | Print the host tier path for the Makefile |
| `seed_host_tier.sh`             | Seed an absent host tier from template    |
| `core_setup.sh`                 | Computer names; `HOMEBREW_NO_*` exports   |
| `shell_setup.sh`                | zsh setup; aggregates `aliases.zsh`       |
| `mise_common.sh`                | Global mise config helpers                |
| `versions_setup.sh`             | Drive mise for the `versions-*` targets   |
| `asdf_to_mise.sh`               | One-shot asdf+direnv to mise migration    |
| `strip_asdf_zshrc_lines.sh`     | Strip orphaned asdf/direnv zshrc lines    |
| `ensure_mise_zshrc_lines.sh`    | Add the mise shims/activate zshrc lines   |
| `vscode_extensions.sh`          | Install VS Code or Cursor extensions      |
| `vscode_setup.sh`               | Symlink the single-winner settings.json   |
| `cdk_setup.sh`                  | Symlink the single-winner `.cdk.json`     |
| `hammerspoon_setup.sh`          | Symlink Hammerspoon config; reload it     |
| `spaces_shortcuts_setup.sh`     | Configure Ctrl+1-9 desktop shortcuts      |
| `msmtp_setup.sh`                | Generate `~/.msmtprc` from `[mailer]`     |
| `claude_repo_setup.sh`          | Clone/update `~/.claude/`; sync plugins   |
| `claude_repo_common.sh`         | `~/.claude/` branch and stash helpers     |
| `claude_disable_autoupdater.sh` | Turn off Claude self-update               |
| `resolve_mailto.sh`             | Resolve the recipient; validate mailer    |
| `resolve_from.sh`               | Resolve the From address                  |
| `mail_wrapper.sh`               | Wrap command output into an email         |
| `send_mail.sh`                  | Send one email through msmtp              |
| `resolve_repo_root.sh`          | Resolve the repo root via `~/.zsh-shared` |
| `launchagent_runner.sh`         | LaunchAgent entry point; per-job log      |
| `self_update.sh`                | Pull latest `main`; auto-stash if dirty   |
| `mas_export.sh`                 | Emit Brewfile `mas` lines for this Mac    |
| `diagnose.sh`                   | Run system diagnostics                    |
