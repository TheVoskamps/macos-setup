# Tier execution

## Every Homebrew install or upgrade runs with `HOMEBREW_NO_ASK=1` set

Homebrew 6.0 prompts `Do you want to proceed? [y/n]` before `install`,
`upgrade`, `reinstall`, and `brew bundle`, so an unattended run with no
TTY hangs forever. Three scopes each set the variable, because none
reaches the others:

- the interactive shell, through the `~/.zshrc` export
  `scripts/core_setup.sh` appends;
- scheduled jobs, through the export in `scripts/launchagent_runner.sh`,
  since launchd never sources `~/.zshrc`;
- `bootstrap.sh`, which prefixes the variable onto its `brew install` and
  `brew upgrade` lines because it runs before `~/.zshrc` carries the
  export.

A new entry point that runs Homebrew outside all three sets the variable
itself.
