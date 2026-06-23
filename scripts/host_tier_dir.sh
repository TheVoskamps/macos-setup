#!/usr/bin/env bash
# scripts/host_tier_dir.sh — print the external host-tier base path.
#
# Thin wrapper around host_tier_dir() in config_common.sh so the
# Makefile (and anything else) can read the external host-tier path
# without re-implementing the XDG/env-override logic. Single source of
# truth lives in config_common.sh; this script just exposes it.
#
# Honors the MACOS_SETUP_HOST_DIR env override; otherwise defaults to
# ${XDG_CONFIG_HOME:-$HOME/.config}/macos-setup.
#
# Usage: scripts/host_tier_dir.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/config_common.sh"

host_tier_dir
