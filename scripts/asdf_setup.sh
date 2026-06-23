#!/bin/bash

set -e

log()  { printf "\033[1;32m[ASDF-SETUP]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# Source three-tier config resolution library
# shellcheck source=config_common.sh
. "$SCRIPT_DIR/config_common.sh"

# Default plugins to install - can be overridden via environment
DEFAULT_PLUGINS="nodejs python pnpm awscli terraform java lua"
ASDF_PLUGINS="${ASDF_PLUGINS:-$DEFAULT_PLUGINS}"

# Pin LuaRocks version for lua builds. LuaRocks 3.13.0 has a broken
# rockspec (duplicate 'tag' key) that fails to parse on Lua 5.5+ and
# also fails during bootstrap on 5.4.x. Track removal of this pin in:
# https://github.com/TheVoskamps/macos-setup/issues/20
export ASDF_LUA_LUAROCKS_VERSION="${ASDF_LUA_LUAROCKS_VERSION:-3.12.2}"

# Ensure asdf is available.
# asdf 0.16+ is a single Go binary -- there is no libexec/asdf.sh to source
# anymore. Correctness now depends on the `asdf` binary being on PATH
# (Homebrew handles this via /opt/homebrew/bin/asdf).
if ! command -v asdf >/dev/null 2>&1; then
  warn "asdf not found on PATH. If asdf is already installed, open a new shell so the shims-on-PATH line from 'make shell' takes effect; otherwise install asdf via Homebrew first (e.g. 'brew install asdf')."
  exit 1
fi

# --- Plugin configuration (asdf-plugins.toml) ---

# Read all config values for a plugin from asdf-plugins.toml in a single pass.
# Uses three-tier resolution via resolve_file.
# Args: plugin_name
# Sets caller variables: _filter, _filter_exclude, _max_version
# (empty string if not found).
get_all_plugin_config() {
  local plugin="$1"

  # Clear output variables
  _filter=""
  _filter_exclude=""
  _max_version=""

  local config_file
  config_file=$(resolve_file "$REPO_ROOT" "asdf-plugins.toml")

  if [ -z "$config_file" ] || [ ! -f "$config_file" ]; then
    return 0
  fi

  # Simple TOML parser: find the [plugin] section, then extract known keys.
  # Key matching uses string comparison (not regex) for robustness.
  local in_section=0
  while IFS= read -r line; do
    # Skip comments and blank lines
    case "$line" in
      \#*|"") continue ;;
    esac

    # Check for section header
    if [[ "$line" =~ ^\[([a-zA-Z0-9_-]+)\]$ ]]; then
      if [ "${BASH_REMATCH[1]}" = "$plugin" ]; then
        in_section=1
      else
        # Exiting the target section
        if [ "$in_section" -eq 1 ]; then
          break
        fi
      fi
      continue
    fi

    # Inside the target section, extract key = "value" pairs
    if [ "$in_section" -eq 1 ]; then
      # Split on first '=' to get the key, then compare as a plain string
      local line_key line_rest
      line_key="${line%%=*}"
      line_rest="${line#*=}"

      # Trim leading/trailing whitespace from key
      line_key="${line_key#"${line_key%%[![:space:]]*}"}"
      line_key="${line_key%"${line_key##*[![:space:]]}"}"

      # Extract quoted value from the right side of '='
      local line_value=""
      if [[ "$line_rest" =~ [[:space:]]*\"([^\"]*)\" ]] ||
         [[ "$line_rest" =~ [[:space:]]*\'([^\']*)\' ]]; then
        line_value="${BASH_REMATCH[1]}"
      fi

      # Assign to the matching output variable using string comparison
      if [ "$line_key" = "filter" ]; then
        _filter="$line_value"
      elif [ "$line_key" = "filter_exclude" ]; then
        _filter_exclude="$line_value"
      elif [ "$line_key" = "max_version" ]; then
        _max_version="$line_value"
      fi
    fi
  done < "$config_file"
}

# Resolve the latest version for a plugin, respecting config-driven filtering
# and version ceiling from asdf-plugins.toml.
# Args: plugin_name
# Prints the resolved version string.
resolve_latest_version() {
  local plugin="$1"

  # Read all config values in a single pass (sets _filter, _filter_exclude, _max_version)
  get_all_plugin_config "$plugin"
  local filter="$_filter"
  local filter_exclude="$_filter_exclude"
  local max_version="$_max_version"

  local latest_version=""

  if [ -n "$filter" ]; then
    # Use filtered listing: asdf list all <plugin> | grep filter | tail -1
    latest_version=$(asdf list all "$plugin" 2>/dev/null | grep "$filter" || true)

    if [ -n "$filter_exclude" ] && [ -n "$latest_version" ]; then
      latest_version=$(echo "$latest_version" | grep -v "$filter_exclude" || true)
    fi

    if [ -n "$max_version" ] && [ -n "$latest_version" ]; then
      # Keep only versions <= max_version using sort -V.
      # Assumption: macOS sort -V (GNU-compatible via coreutils or native)
      # handles the version strings produced by asdf plugins. For non-semver
      # strings like "temurin-21.0.4+7.0.LTS", sort -V orders by splitting
      # on non-alphanumeric boundaries and comparing segments numerically
      # where possible. This works correctly for known asdf version formats
      # but may not suit exotic version schemes.
      # Approach: add max_version as a sentinel, sort, print lines
      # until we've seen the sentinel. If max_version was already in
      # the candidate list it appears naturally; if not, the sentinel
      # is removed afterwards.
      local candidates="$latest_version"
      local has_max_in_candidates
      has_max_in_candidates=$(echo "$candidates" | grep -cxF "$max_version" || true)

      # Sort with sentinel, then take up to and including max_version line
      local sorted
      sorted=$(printf "%s\n%s" "$candidates" "$max_version" | sort -V | uniq)
      latest_version=""
      while IFS= read -r ver; do
        latest_version=$(printf "%s\n%s" "$latest_version" "$ver")
        if [ "$ver" = "$max_version" ]; then
          break
        fi
      done <<< "$sorted"
      # Remove leading blank line from printf
      latest_version=$(echo "$latest_version" | sed '/^$/d')

      if [ "$has_max_in_candidates" -eq 0 ]; then
        # max_version was only a sentinel, remove it
        latest_version=$(echo "$latest_version" | grep -vxF "$max_version" || true)
      fi
    fi

    # Take the last (latest) line
    latest_version=$(echo "$latest_version" | tail -1)
  else
    # No filter configured, use asdf latest
    latest_version=$(asdf latest "$plugin" 2>/dev/null || echo "")

    if [ -n "$max_version" ] && [ -n "$latest_version" ]; then
      # Check if latest exceeds max_version using sort -V.
      # See the filtered branch above for sort -V assumptions.
      local higher
      higher=$(printf "%s\n%s" "$latest_version" "$max_version" | sort -V | tail -1)
      if [ "$higher" != "$max_version" ] && [ "$higher" = "$latest_version" ]; then
        # latest_version exceeds max_version, cap at max_version
        latest_version="$max_version"
      fi
    fi
  fi

  echo "$latest_version"
}

# Function to install a plugin if not already installed
install_plugin() {
  local plugin="$1"

  if asdf plugin list | grep -q "^${plugin}$"; then
    log "Plugin already installed: $plugin"
  else
    log "Installing asdf plugin: $plugin"
    case "$plugin" in
      python)
        asdf plugin add python https://github.com/asdf-community/asdf-python.git || true
        ;;
      nodejs)
        asdf plugin add nodejs https://github.com/asdf-vm/asdf-nodejs.git || true
        # Import Node.js release keys if available
        if [ -f "$HOME/.asdf/plugins/nodejs/bin/import-release-team-keyring" ]; then
          "$HOME/.asdf/plugins/nodejs/bin/import-release-team-keyring" || true
        fi
        ;;
      awscli)
        asdf plugin add awscli https://github.com/MetricMike/asdf-awscli.git || true
        ;;
      terraform)
        asdf plugin add terraform https://github.com/asdf-community/asdf-hashicorp.git || true
        ;;
      java)
        asdf plugin add java https://github.com/halcyon/asdf-java.git || true
        ;;
      *)
        asdf plugin add "$plugin" || true
        ;;
    esac
  fi
}

# Function to update plugin to latest version
update_plugin_to_latest() {
  local plugin="$1"

  if ! asdf plugin list | grep -q "^${plugin}$"; then
    warn "Plugin not installed, skipping update: $plugin"
    return
  fi

  log "Updating $plugin to latest version..."
  local latest_version
  latest_version=$(resolve_latest_version "$plugin")

  if [ -n "$latest_version" ]; then
    asdf install "$plugin" "$latest_version" || true
    log "Updated $plugin to latest: $latest_version"
  else
    warn "Could not determine latest version for $plugin"
  fi
}

# Function to pin exact versions to .tool-versions
pin_latest_versions() {
  log "Pinning latest versions to .tool-versions..."

  for plugin in $ASDF_PLUGINS; do
    if asdf plugin list | grep -q "^${plugin}$"; then
      local latest_version
      latest_version=$(resolve_latest_version "$plugin")

      if [ -n "$latest_version" ]; then
        asdf set "$plugin" "$latest_version"
        log "Pinned $plugin $latest_version"
      else
        warn "Could not resolve latest version for $plugin"
      fi
    fi
  done
}

# Function to install versions from .tool-versions
install_pinned_versions() {
  if [ -f .tool-versions ]; then
    log "Installing versions from .tool-versions..."
    asdf install
  else
    warn "No .tool-versions file found"
  fi
}

# Function to setup direnv integration
setup_direnv() {
  log "Setting up direnv integration..."

  mkdir -p "$HOME/.config/direnv/lib"

  # Ensure direnv hook is in .zshrc
  local zshrc="$HOME/.zshrc"
  if [ -f "$zshrc" ]; then
    if ! grep -qF 'eval "$(direnv hook zsh)"' "$zshrc"; then
      echo 'eval "$(direnv hook zsh)"' >> "$zshrc"
      log "Added direnv hook to $zshrc"
    fi
  fi

  # Install direnv plugin for asdf
  if ! asdf plugin list | grep -q "^direnv$"; then
    asdf plugin add direnv || true
    log "Added direnv plugin to asdf"
  fi

  # Install use_asdf helper
  local use_asdf_helper="$HOME/.config/direnv/lib/use_asdf.sh"
  local template_helper="$REPO_ROOT/templates/use_asdf.sh"
  if [ -f "$template_helper" ]; then
    install -m 0644 "$template_helper" "$use_asdf_helper"
    log "Installed use_asdf helper at $use_asdf_helper"
  else
    warn "Template use_asdf.sh not found at $template_helper"
  fi
}

check_outdated() {
  log "Checking for outdated asdf-managed tools..."

  # Get list of installed plugins
  local plugins
  plugins=$(asdf plugin list 2>/dev/null || true)

  if [ -z "$plugins" ]; then
    warn "No asdf plugins installed"
    return 0
  fi

  local has_outdated=0

  echo "$plugins" | while IFS= read -r plugin; do
    [ -z "$plugin" ] && continue

    # Get all installed versions for this plugin
    local installed_versions
    installed_versions=$(asdf list "$plugin" 2>/dev/null | sed -E 's/^[[:space:]]*\*?[[:space:]]*//' | grep -v '^$' || true)

    if [ -z "$installed_versions" ]; then
      echo "  $plugin: no versions installed"
      continue
    fi

    # Get latest available version (respects plugin config filtering)
    local latest_version
    latest_version=$(resolve_latest_version "$plugin")

    if [ -z "$latest_version" ]; then
      echo "  $plugin: (unable to check latest)"
      continue
    fi

    # Get the newest installed version (last in the list)
    local newest_installed
    newest_installed=$(echo "$installed_versions" | tail -1)

    # Check if latest is already installed
    if echo "$installed_versions" | grep -q "^${latest_version}$"; then
      echo "  $plugin: $newest_installed (up to date)"
    else
      echo "  $plugin: $newest_installed → $latest_version"
      has_outdated=1
    fi
  done

  # Note: has_outdated won't persist due to subshell, but that's OK for display purposes
  echo ""
  echo "Run 'make asdf-update' to install newer versions"
}

# Update all tools - non-interactive, always installs latest versions
update_all_tools() {
  log "Updating all asdf-managed tools..."

  # First update all plugins
  log "Updating asdf plugins..."
  asdf plugin update --all

  log "Installing latest versions of all tools..."

  # Get list of plugins
  local plugins
  plugins=$(asdf plugin list 2>/dev/null || true)

  if [ -n "$plugins" ]; then
    # Use here-string to avoid subshell issues with pipes
    while IFS= read -r plugin; do
      [ -z "$plugin" ] && continue

      local latest_version
      latest_version=$(resolve_latest_version "$plugin")

      if [ -n "$latest_version" ]; then
        # Check if already installed
        if asdf list "$plugin" 2>/dev/null | sed -E 's/^[[:space:]]*\*?[[:space:]]*//' | grep -q "^${latest_version}$"; then
          log "$plugin $latest_version already installed"
        else
          log "Installing $plugin $latest_version..."
          asdf install "$plugin" "$latest_version" || warn "Failed to install $plugin $latest_version"
        fi
      else
        warn "Unable to determine latest version for $plugin"
      fi
    done <<< "$plugins"

    log "Latest versions installed (use 'asdf set <plugin> <version> -u' for home or '-p' for parent .tool-versions)"
  fi
}

# --- Version cleanup (prune old, unused installed versions) ---

# Number of newest versions to keep per plugin regardless of usage.
CLEANUP_KEEP_NEWEST="${CLEANUP_KEEP_NEWEST:-3}"

# Directory names to prune while scanning $HOME for .tool-versions files.
# These are heavy/noise directories that would slow the scan and can
# trigger permission errors. Kept as a single -prune set passed to find.
CLEANUP_PRUNE_DIRS="Library node_modules .git .cache Caches .Trash .npm .cargo .rustup .gradle .m2 go/pkg .vscode-server"

# Scan $HOME for .tool-versions files and print every "<plugin> <version>"
# pair found, one per line ("<plugin> <version>"). Comment lines (starting
# with '#'), blank lines, and extra whitespace are handled robustly. A
# single .tool-versions line is "<tool> <version>"; only the first two
# whitespace-delimited fields are used.
scan_tool_versions_pairs() {
  # Build the -prune expression dynamically from CLEANUP_PRUNE_DIRS.
  local prune_args=()
  local first=1
  local d
  for d in $CLEANUP_PRUNE_DIRS; do
    if [ "$first" -eq 1 ]; then
      first=0
    else
      prune_args+=("-o")
    fi
    prune_args+=("-name" "$d")
  done

  # find: prune the noise dirs, otherwise match files named .tool-versions.
  # 2>/dev/null suppresses permission-denied noise on unreadable subtrees.
  local files
  files=$(find "$HOME" \( "${prune_args[@]}" \) -prune -o \
    -type f -name '.tool-versions' -print 2>/dev/null || true)

  [ -z "$files" ] && return 0

  while IFS= read -r f; do
    [ -z "$f" ] && continue
    [ -r "$f" ] || continue
    # Parse each line: skip comments/blank, emit "<plugin> <version>".
    while IFS= read -r line || [ -n "$line" ]; do
      # Strip a trailing comment, then trim whitespace.
      line="${line%%#*}"
      # Read first two fields.
      local tool version
      tool=$(printf '%s\n' "$line" | awk '{print $1}')
      version=$(printf '%s\n' "$line" | awk '{print $2}')
      if [ -n "$tool" ] && [ -n "$version" ]; then
        printf '%s %s\n' "$tool" "$version"
      fi
    done < "$f"
  done <<< "$files"
}

# Prune old, unused installed versions per plugin.
# Keep-set per plugin = union of:
#   1. versions referenced in any discovered .tool-versions,
#   2. currently-active version(s) for the plugin,
#   3. the top CLEANUP_KEEP_NEWEST newest versions (sort -V).
# Every other installed version is removed via `asdf uninstall`.
# Args: dry_run ("1" => print only, don't delete)
# Returns: non-zero if any uninstall failed (when not dry-run).
cleanup_versions() {
  local dry_run="${1:-0}"

  if [ "$dry_run" = "1" ]; then
    log "Cleaning up old asdf versions (DRY RUN -- nothing will be removed)..."
  else
    log "Cleaning up old asdf versions..."
  fi

  local plugins
  plugins=$(asdf plugin list 2>/dev/null || true)

  if [ -z "$plugins" ]; then
    warn "No asdf plugins installed"
    return 0
  fi

  # Gather all "<plugin> <version>" pairs referenced across the machine.
  log "Scanning \$HOME for .tool-versions files..."
  local referenced
  referenced=$(scan_tool_versions_pairs)

  local overall_rc=0
  local removed_any=0

  while IFS= read -r plugin; do
    [ -z "$plugin" ] && continue

    # Installed versions, stripped of the leading '*' active marker and
    # surrounding whitespace.
    local installed
    installed=$(asdf list "$plugin" 2>/dev/null \
      | sed -E 's/^[[:space:]]*\*?[[:space:]]*//' \
      | grep -v '^$' || true)

    [ -z "$installed" ] && continue

    local install_count
    install_count=$(printf '%s\n' "$installed" | grep -c '^' || true)
    if [ "$install_count" -le "$CLEANUP_KEEP_NEWEST" ]; then
      # Nothing can be removed: at or below the keep-newest floor.
      continue
    fi

    # --- Build the keep-set ---

    # 1. Versions referenced in any .tool-versions for THIS plugin.
    local referenced_for_plugin=""
    if [ -n "$referenced" ]; then
      referenced_for_plugin=$(printf '%s\n' "$referenced" \
        | awk -v p="$plugin" '$1 == p {print $2}' || true)
    fi

    # 2. Currently-active version(s) for this plugin. The lines from
    #    `asdf list` that begin with '*' are the active versions.
    local active_for_plugin
    active_for_plugin=$(asdf list "$plugin" 2>/dev/null \
      | grep -E '^[[:space:]]*\*' \
      | sed -E 's/^[[:space:]]*\*?[[:space:]]*//' \
      | grep -v '^$' || true)

    # 3. The top CLEANUP_KEEP_NEWEST newest versions by sort -V.
    local newest
    newest=$(printf '%s\n' "$installed" | sort -V | tail -n "$CLEANUP_KEEP_NEWEST")

    # Union of the three keep-sets, de-duplicated.
    local keep_set
    keep_set=$(printf '%s\n%s\n%s\n' \
      "$referenced_for_plugin" "$active_for_plugin" "$newest" \
      | grep -v '^$' | sort -u || true)

    # Anything installed but not in the keep-set is removed.
    while IFS= read -r version; do
      [ -z "$version" ] && continue
      if printf '%s\n' "$keep_set" | grep -qxF "$version"; then
        continue
      fi
      removed_any=1
      if [ "$dry_run" = "1" ]; then
        log "Would remove: $plugin $version"
      else
        log "Removing: $plugin $version"
        if ! asdf uninstall "$plugin" "$version"; then
          warn "Failed to uninstall $plugin $version"
          overall_rc=1
        fi
      fi
    done <<< "$installed"
  done <<< "$plugins"

  if [ "$removed_any" -eq 0 ]; then
    log "Nothing to clean up; all installed versions are in use or recent."
  elif [ "$dry_run" = "1" ]; then
    log "Dry run complete. Re-run 'make asdf-cleanup' to remove the versions above."
  fi

  return "$overall_rc"
}

# Main execution logic
MODE="${1:-full}"

case "$MODE" in
  "plugins-init")
    log "Installing asdf plugins: $ASDF_PLUGINS"
    for plugin in $ASDF_PLUGINS; do
      install_plugin "$plugin"
    done
    ;;
  "pin-latest")
    pin_latest_versions
    ;;
  "install")
    install_pinned_versions
    ;;
  "update-latest")
    log "Updating all installed plugins to latest versions"
    for plugin in $ASDF_PLUGINS; do
      update_plugin_to_latest "$plugin"
    done
    ;;
  "direnv-setup")
    setup_direnv
    ;;
  "outdated")
    check_outdated
    ;;
  "update-all")
    update_all_tools
    ;;
  "cleanup")
    # A failed uninstall must surface in the exit code, but should not
    # abort the script under `set -e` before the trailing log line.
    cleanup_versions 0 || CLEANUP_RC=1
    ;;
  "cleanup-dry-run")
    cleanup_versions 1
    ;;
  "full")
    log "Running full asdf setup..."
    for plugin in $ASDF_PLUGINS; do
      install_plugin "$plugin"
    done
    pin_latest_versions
    install_pinned_versions
    setup_direnv
    ;;
  *)
    echo "Usage: $0 [plugins-init|pin-latest|install|update-latest|direnv-setup|outdated|update-all|cleanup|cleanup-dry-run|full]"
    echo "  plugins-init     - Install plugins only"
    echo "  pin-latest       - Pin latest versions to .tool-versions"
    echo "  install          - Install versions from .tool-versions"
    echo "  update-latest    - Update all plugins to latest versions"
    echo "  direnv-setup     - Setup direnv integration"
    echo "  outdated         - Check for outdated tools"
    echo "  update-all       - Update plugins and install latest versions (non-interactive)"
    echo "  cleanup          - Prune old, unused versions (keep .tool-versions refs, active, newest 3)"
    echo "  cleanup-dry-run  - Show what cleanup would remove without removing"
    echo "  full             - Complete setup (default)"
    exit 1
    ;;
esac

log "asdf setup complete!"

# Surface a non-zero exit from cleanup (a failed uninstall) without
# aborting the trailing completion log above.
exit "${CLEANUP_RC:-0}"
