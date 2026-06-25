#!/usr/bin/env bash
# scripts/list_profiles.sh — print this host's ordered profile list,
# one profile name per line, lowest priority first.
#
# Thin wrapper around get_profiles() in config_common.sh so the Makefile
# (and anything else) can read the ordered list without re-implementing
# the parse. Reading the selector file directly from a Makefile
# `$(shell ...)` is awkward because GNU make strips `#` as a comment
# even inside `$(shell ...)`, which mangles any awk/sed program that
# needs to recognize `#`-comment lines. Delegating to this script
# sidesteps that entirely.
#
# Usage: scripts/list_profiles.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/config_common.sh"

# Quietly short-circuit when dasel is unreachable (issue #4). The Makefile
# evaluates `PROFILES := $(shell bash scripts/list_profiles.sh ...)` at
# PARSE time, before any target's prerequisite runs — including the
# up-front require-dasel gate. With dasel off PATH, get_profiles ->
# require_dasel_v3 -> __dasel_die would `kill -s TERM "$$"`, and make's
# parent shell would print a `Terminated: 15` line ahead of the gate's
# clean `Error: dasel not in PATH.` (the whole symptom issue #4 exists to
# eliminate). So before doing any config read, mirror the gate's own
# reachability check (`command -v $DASEL`, honoring the same DASEL
# override config_common.sh uses) and exit 0 with an EMPTY list when
# dasel is not reachable. An empty profile list is the right degraded
# value at parse time: the require-dasel prerequisite then produces the
# single actionable error when the config-dependent target actually runs.
# This is a reachability short-circuit only; a reachable-but-wrong-version
# dasel still trips require_dasel_v3 at the first real read, unchanged.
if ! command -v "${DASEL:-dasel}" >/dev/null 2>&1; then
    exit 0
fi

get_profiles "$REPO_ROOT"
