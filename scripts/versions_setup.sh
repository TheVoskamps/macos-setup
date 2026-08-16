#!/usr/bin/env bash
# versions_setup.sh — drive mise for the `versions-*` Makefile targets and
# the `04-Install.versionmanagers` post-install action.
#
# The target names are deliberately implementation-neutral (`versions-*`,
# not `mise-*`): swapping the version manager again should be a change to
# this one file, not to every caller, alias, and doc line.
#
# Nearly everything this script used to do by hand — plugin registration,
# version resolution, outdated checking, pruning — is a native mise
# subcommand, so the script is a thin dispatcher.

set -e

MISE_LOG_TAG="VERSIONS-SETUP"
export MISE_LOG_TAG

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=mise_common.sh
. "$SCRIPT_DIR/mise_common.sh"

# LuaRocks pin for lua builds. LuaRocks 3.13.0 ships a rockspec with a
# duplicate 'tag' key; under asdf's lua plugin that broke the build, so this
# repo pinned 3.12.2. ASDF_LUA_LUAROCKS_VERSION is the variable name that
# plugin reads.
#
# On mise it is currently INERT, and deliberately kept anyway. Verified
# against mise 2026.8.6 on 2026-08-16: `mise registry` resolves lua through
# `vfox:mise-plugins/vfox-lua` FIRST, not the asdf plugin, and a sandboxed
# `mise install lua@5.4` built 5.4.8 and bootstrapped LuaRocks *3.13.0*
# successfully with this export set. So the variable neither took effect nor
# needed to. It stays because it costs nothing and still applies to anyone
# who pins lua to the asdf backend explicitly (`asdf:mise-plugins/mise-lua`),
# where the original breakage is unchanged: upstream luarocks/luarocks#1851
# was closed by a fix to the *release tooling* (luarocks/luarocks#1885), and
# the shipped 3.13.0 tarball is PGP-signed with a pinned source_digest and
# was never re-rolled. Tracked in:
# https://github.com/TheVoskamps/macos-setup/issues/6
export ASDF_LUA_LUAROCKS_VERSION="${ASDF_LUA_LUAROCKS_VERSION:-3.12.2}"

require_mise || exit 1

MODE="${1:-full}"

case "$MODE" in
  "install")
    mise_log "Installing tool versions from the resolved mise config..."
    "$MISE" install
    ;;
  "update")
    # One verb: install the latest versions AND write them back into the
    # config that declared them. This collapses the old deliberate split
    # between `asdf-pin-latest` (wrote .tool-versions) and `asdf-update`
    # (did not) — the newly installed version is the one that is active.
    mise_log "Updating tools to their latest versions (and bumping the config)..."
    "$MISE" up --bump
    ;;
  "outdated")
    mise_log "Checking for outdated mise-managed tools..."
    "$MISE" outdated
    ;;
  "cleanup")
    mise_log "Pruning unused tool versions..."
    "$MISE" prune
    ;;
  "cleanup-dry-run")
    mise_log "Pruning unused tool versions (DRY RUN -- nothing will be removed)..."
    "$MISE" prune --dry-run
    ;;
  "full")
    mise_log "Running full version-manager setup..."
    ensure_global_mise_config
    ensure_mise_env_file_setting
    "$MISE" install
    ;;
  *)
    echo "Usage: $0 [install|update|outdated|cleanup|cleanup-dry-run|full]"
    echo "  install          - Install the versions the resolved mise config declares"
    echo "  update           - Install latest versions and bump the config (mise up --bump)"
    echo "  outdated         - Report tools with a newer version available"
    echo "  cleanup          - Remove unused installed versions (mise prune)"
    echo "  cleanup-dry-run  - Show what cleanup would remove without removing"
    echo "  full             - Ensure the global config, then install (default)"
    exit 1
    ;;
esac

mise_log "Version-manager setup complete!"
