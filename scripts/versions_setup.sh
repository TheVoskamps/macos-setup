#!/usr/bin/env bash
# versions_setup.sh — drive mise for the `versions-*` Makefile targets and
# the `version-managers` profile's `post_install` action.
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
