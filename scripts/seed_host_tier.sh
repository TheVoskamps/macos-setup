#!/usr/bin/env bash
# scripts/seed_host_tier.sh — seed the external host tier from the
# in-repo template, but only if the external dir does not already exist.
#
# The host tier lives OUTSIDE the repo (see host_tier_dir in
# config_common.sh). This script is a thin entry point for the
# `seed_host_tier_if_absent` library function, called by `make install`
# (and reachable standalone via `make seed-host-tier`).
#
# Behavior:
#   - external host dir absent  -> create it, copy the template tree in
#   - external host dir present -> no-op (never overwrite user edits)
#
# Override the destination with MACOS_SETUP_HOST_DIR (used by tests).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/config_common.sh"

seed_host_tier_if_absent "$REPO_ROOT"
