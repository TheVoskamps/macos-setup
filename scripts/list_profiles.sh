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

get_profiles "$REPO_ROOT"
