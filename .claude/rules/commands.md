# Commands

## Target lookup

`make help` lists every documented target and every profile.
`make profiles` marks the profiles this host opts into and prints the
tier order it applies.

## Only a read-only target runs unasked

Every other target installs, removes, or rewrites something on this
machine. Without a task that asks for that change here, run only
`make help`, `make profiles`, `make verify`, `make outdated`, and the
`*-dry-run` targets.

## Tests run one file at a time

There is no aggregate runner. Run each `scripts/test/*_test.sh` under
`/bin/bash` and each `scripts/test/*_test.zsh` under `zsh`; each exits
non-zero on failure.

## A test never touches the real host

A test points every path it writes at a temp dir — the host tier through
`MACOS_SETUP_HOST_DIR`, `~/.zshrc` through `ZSHRC_PATH`, or `HOME`
itself — and replaces every binary that changes the machine with a
stub.
