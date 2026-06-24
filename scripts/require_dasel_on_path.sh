#!/usr/bin/env bash

# Up-front bare-name reachability gate for `dasel` (issue #4).
#
# Every config.toml read in this repo invokes `dasel` by BARE NAME (the
# read layer in config_common.sh, and list_profiles.sh through it). On a
# fresh Apple Silicon Mac, `bootstrap.sh` installs dasel into
# /opt/homebrew/bin and appends the `eval "$(/opt/homebrew/bin/brew
# shellenv)"` line to the user's profile, but that line only takes effect
# in a NEW login shell. A user who runs `./bootstrap.sh` and then, in the
# SAME shell, `cd macos-setup && make install`, has dasel installed but
# /opt/homebrew/bin still off PATH — so every bare-name `dasel` call
# fails with command-not-found (exit 127).
#
# Without this gate, that failure surfaces LATE and CRYPTICALLY: after
# host-tier seeding and partway into 00-Install.core, as a buried
# `dasel version exited 127` from require_dasel_v3 (plus `Terminated: 15`
# noise from list_profiles.sh subshells getting killed). This script is a
# single up-front hard gate the config-dependent `make` targets run
# BEFORE any seeding, any list_profiles.sh, or any config read: it checks
# that dasel is reachable as a bare command and aborts loudly with an
# actionable remediation if not.
#
# This is deliberately a REACHABILITY check, not a version check. The
# major-version assertion (exactly v3) is the separate concern of
# require_dasel_v3 in config_common.sh, which still runs at the first
# real read. The two complement each other: this gate catches "dasel not
# on PATH at all" up front with a PATH-specific message; require_dasel_v3
# catches "dasel present but wrong major version" at read time. Per the
# issue, this gate does NOT auto-install dasel and does NOT self-heal
# PATH — it reports and aborts.

set -euo pipefail

# The $DASEL indirection mirrors config_common.sh / the test suite: the
# read layer honors a DASEL override, so the reachability gate must check
# the SAME binary the reads will use. Default to the bare name `dasel`.
DASEL="${DASEL:-dasel}"

if command -v "$DASEL" >/dev/null 2>&1; then
  exit 0
fi

cat >&2 <<EOF
Error: dasel not in PATH.

\`dasel\` is a hard dependency of every config.toml read in this repo, and
it is invoked by bare name. It is not reachable on PATH right now.

If you just ran ./bootstrap.sh in this same shell: bootstrap installs
dasel (into Homebrew's bin) and appends the \`brew shellenv\` line to your
profile, but that only puts Homebrew's bin on PATH for a NEW shell. Start
a fresh shell and re-run:

    cd macos-setup && make install

If dasel is genuinely not installed, run ./bootstrap.sh first (it
installs and version-verifies dasel via install_dasel).
EOF
exit 1
