#!/usr/bin/env bash
# mise_common.sh — shared mise helpers.
#
# Sourced (never executed) by `scripts/versions_setup.sh` (the
# `04-Install.versionmanagers` post-install action and the `versions-*`
# Makefile targets) and by `scripts/asdf_to_mise.sh` (the one-shot
# `make asdf-to-mise` migration). Both need to bring the global mise
# config up to the state this repo expects, so that logic lives here once
# rather than in each caller.

# Guard against double-sourcing.
if [ -n "${_MISE_COMMON_SOURCED:-}" ]; then
  return 0
fi
_MISE_COMMON_SOURCED=1

mise_log()  { printf "\033[1;32m[%s]\033[0m %s\n" "${MISE_LOG_TAG:-MISE}" "$*"; }
mise_warn() { printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }

# The mise binary. Overridable (MISE=/path/to/mise) so the test suite can
# stub it without a real install.
MISE="${MISE:-mise}"

# Abort unless mise is reachable by the configured name.
require_mise() {
  if ! command -v "$MISE" >/dev/null 2>&1; then
    mise_warn "mise not found on PATH. If mise is already installed, open a new shell so the shims/activation line from 'make shell' takes effect; otherwise install it first (e.g. 'brew install mise')."
    return 1
  fi
}

# Path of mise's own global config. mise reads this location by default,
# so the repo does not have to point it anywhere.
mise_global_config_path() {
  printf '%s/mise/config.toml\n' "${XDG_CONFIG_HOME:-$HOME/.config}"
}

# Directory mise installs its shims into — mise's own default location.
# This is the canonical statement of that path, but it is not the only
# one: shell_setup.sh and launchagent_runner.sh each repeat the literal,
# and neither calls this function. They cannot. shell_setup.sh writes the
# expression into ~/.zshrc, which must not depend on this repo being
# present; launchagent_runner.sh needs it on PATH before the repo root is
# resolved, so it has nothing to source. Keep all three in sync by hand.
mise_shims_dir() {
  printf '%s/mise/shims\n' "${XDG_DATA_HOME:-$HOME/.local/share}"
}

# Create the global config if it is absent, importing a global
# `~/.tool-versions` when the host has one (mise, unlike asdf, does not
# treat `~/.tool-versions` as a global config, so this import is what
# carries a host's global pins across).
#
# Never touches an existing config.
ensure_global_mise_config() {
  local cfg
  cfg="$(mise_global_config_path)"

  if [ -f "$cfg" ]; then
    mise_log "Global mise config already present at $cfg (left as-is)"
    return 0
  fi

  mkdir -p "$(dirname "$cfg")"

  if [ -f "$HOME/.tool-versions" ]; then
    mise_log "Generating $cfg from \$HOME/.tool-versions"
    "$MISE" generate config -g -y --tool-versions "$HOME/.tool-versions"
  else
    mise_log "Generating $cfg (no \$HOME/.tool-versions to import)"
    "$MISE" generate config -g -y
  fi

  # `mise generate config` writes the file only when it has tools to
  # write; guarantee it exists so the env_file step below has somewhere
  # to append.
  [ -f "$cfg" ] || : > "$cfg"
}

# Ensure `[settings] env_file = ".env"` is set in the global config.
#
# This is the true `dotenv_if_exists` analogue direnv provided: unlike
# `[env] _.file`, which resolves relative to the config file that declares
# it (i.e. `~/.env` from the global config), the `[settings]` form
# searches the cwd and its parents.
#
# Deliberately a grep-guarded edit rather than `mise use -g` or a
# regenerate: it is not documented whether those preserve an existing
# `[settings]` block, and clobbering the user's global config is not an
# acceptable failure mode. Idempotent — a second run adds nothing.
ensure_mise_env_file_setting() {
  local cfg
  cfg="$(mise_global_config_path)"
  [ -f "$cfg" ] || : > "$cfg"

  if grep -Eq '^[[:space:]]*env_file[[:space:]]*=' "$cfg"; then
    mise_log "env_file already configured in $cfg"
    return 0
  fi

  # The header regex tolerates a trailing TOML comment (`[settings] # mine`),
  # because a hand-written config commonly carries one and TOML allows it.
  # An anchored bare-header-only match would miss such a line, fall through
  # to the append branch, and leave the file with TWO [settings] tables --
  # invalid TOML that mise cannot parse.
  local settings_re='^[[:space:]]*\[settings\][[:space:]]*(#.*)?$'
  if grep -Eq "$settings_re" "$cfg"; then
    # A [settings] table already exists. Appending a second one at EOF
    # would be a duplicate-table TOML error, so insert the key directly
    # under the existing header instead.
    local tmp
    tmp="$(mktemp)"
    # Handed to awk through the environment, not `-v`: `-v` runs escape
    # processing over the value, which mangles the regex's `\[` into a bare
    # `[` and turns `\[settings\]` into a character class that matches
    # nothing here. ENVIRON passes the string through untouched.
    MS_SETTINGS_RE="$settings_re" awk '
      BEGIN { re = ENVIRON["MS_SETTINGS_RE"] }
      { print }
      !done && $0 ~ re {
        print "env_file = \".env\""
        done = 1
      }
    ' "$cfg" > "$tmp" && mv "$tmp" "$cfg"
    mise_log "Added env_file to the existing [settings] block in $cfg"
  else
    printf '\n[settings]\nenv_file = ".env"\n' >> "$cfg"
    mise_log "Added [settings] env_file to $cfg"
  fi
}
