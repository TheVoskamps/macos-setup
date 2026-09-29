# CLAUDE.md - macOS Setup

- `.claude/rules/repository.md` — loaded at launch; reread when deciding
  where a change lands. Kernel: a change lands in the tier whose machines
  need it, and a change for one machine belongs in its host tier outside
  the repo.
- `.claude/rules/commands.md` — loaded at launch; reread before running a
  `make` target or a test. Kernel: without a task that asks for a change
  on this machine, run only the read-only targets and the tests.
- `docs/rules/tiers.md` — read before a script reads `config.toml` or
  resolves a file across tiers, or before changing a file's resolution
  kind. Kernel: every config read goes through the readers in
  `scripts/config_common.sh`, never through a direct `dasel` call.
- `docs/rules/tier-execution.md` — read before adding an entry point that
  installs or upgrades Homebrew packages. Kernel: every Homebrew install
  or upgrade runs with `HOMEBREW_NO_ASK=1` set, or an unattended run
  hangs on a prompt.
- `docs/rules/version-management.md` — read before changing the mise
  `.gitignore` block that `make asdf-to-mise` writes. Kernel: the heredoc
  in `scripts/asdf_to_mise.sh` is authoritative, and both verbatim copies
  change with it.
- `docs/rules/mailer.md` — read before writing code that sends mail.
  Kernel: mail goes out only through `scripts/send_mail.sh`.
- `docs/rules/shell.md` — read before writing a path that reaches the
  repo through `~/.zsh-shared`, such as one a LaunchAgent plist embeds.
  Kernel: what such a path runs is a committed symlink inside
  `shared/zsh/`, never `~/.zsh-shared/..`.
- `docs/rules/claude-config.md` — read before touching Claude hooks,
  settings, or plugin sync, or before creating scratch files. Kernel:
  `~/.claude/` is a separate repository, so its hooks, settings, and
  `plugins.sh` are never changed from here.
- `docs/rules/hammerspoon.md` — read before changing how
  `scripts/hammerspoon_setup.sh` reloads Hammerspoon. Kernel: a reload
  falls back to relaunching the app, because IPC is down whenever
  `init.lua` has not loaded.
- `docs/rules/scripts.md` — read when locating the script that owns a
  job. Kernel: each script under `scripts/` owns one job, so work on that
  job goes in that script.
