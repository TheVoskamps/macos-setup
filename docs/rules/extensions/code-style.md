# Code Style — this repo

## For Authors

## For Authors and Checkers

### Every bash invocation the diff adds names `/bin/bash`

Every command the diff adds that runs a script or a command string
under bash names `/bin/bash`, or `$(BASH_BIN)` in the Makefile, and
never a bare `bash`. A removal run can take Homebrew's `bash` formula
out mid-run, and a `PATH`-resolved `bash` then fails every later step.
A script's own shebang line is not an invocation.

### Every binary override the diff adds takes one form

Every environment override the diff adds for a binary a script shells
out to is written exactly `VAR="${VAR:-default}"`, with `default` the
bare name `PATH` resolves.

### A git network call where `git_in_safe_cwd` is sourced uses it

In a script that sources `scripts/claude_repo_common.sh`, every
`git ls-remote`, `clone`, `fetch`, or `pull` the diff adds runs through
that file's `git_in_safe_cwd`, which runs git from a fresh temp
directory. On macOS those operations
can hang for about two minutes when the working directory has a
descendant that another symlink on disk targets.
