#!/usr/bin/env bash

# Tests for the consolidated config.toml read layer (issue #156).
#
# Covers the config_common.sh helpers that replace the old per-file
# key=value / line-oriented config (config/claude, config/mailer,
# cron/mailto, profiles):
#
#   - read_toml_value(): scalar reads, missing key -> empty, missing
#     file -> empty
#   - read_toml_array(): array reads, missing array -> empty
#   - resolve_config_value(): single-winner across tiers
#     (host > reverse(profiles) > default)
#   - get_profiles(): host array, default-prepend, dedup-keeping-last
#   - dedup_keep_last(): order-preserving dedup keeping the last
#     occurrence
#
# config.toml is queried with `dasel`, a guaranteed bootstrap primitive
# (bootstrap.sh install_dasel). These tests exercise the REAL dasel
# binary against the real v3 query contract — there is no shim and no
# skip-guard. If dasel is missing the tests fail loudly (as they should,
# since dasel is a hard dependency of the config layer).
#
# Every block points MACOS_SETUP_HOST_DIR at a temp dir so the host tier
# is exercised without ever touching a real ~/.config path.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_LIB="$REPO_ROOT/scripts/config_common.sh"

if ! command -v dasel >/dev/null 2>&1; then
  echo "FAIL: dasel not on PATH; config.toml tests require the real binary (bootstrap.sh install_dasel)." >&2
  exit 1
fi

pass=0
fail=0
ok() {
  if [[ "$1" == "$2" ]]; then
    echo "PASS: $3"; ((pass++))
  else
    echo "FAIL: $3 -- got [$1] want [$2]"; ((fail++))
  fi
}

# ---------------------------------------------------------------------
# Block 1: read_toml_value / read_toml_array primitives
# ---------------------------------------------------------------------
primitive_tests() {
  local TMP toml
  TMP="$(mktemp -d)"
  toml="$TMP/config.toml"
  # shellcheck disable=SC1090
  source "$CONFIG_LIB"

  # `profiles` is a bare top-level key, so it MUST precede the first
  # [section] table or TOML nests it under that table (issue #156 review).
  cat > "$toml" <<'EOF'
profiles = ["aws", "dev-core", "plex"]

[claude]
branch = "feature-x"
hostname = "github.com-edwin"

[mailer]
backend = "msmtp"
smtp_host = "smtp.example.com"
smtp_port = 587

[cron]
mailto = "ops@example.com"
EOF

  ok "$(read_toml_value "$toml" "claude.branch")" "feature-x" \
    "read_toml_value: section scalar (claude.branch)"
  ok "$(read_toml_value "$toml" "mailer.smtp_host")" "smtp.example.com" \
    "read_toml_value: section scalar (mailer.smtp_host)"
  ok "$(read_toml_value "$toml" "mailer.smtp_port")" "587" \
    "read_toml_value: numeric scalar (mailer.smtp_port)"
  ok "$(read_toml_value "$toml" "cron.mailto")" "ops@example.com" \
    "read_toml_value: section scalar (cron.mailto)"
  ok "$(read_toml_value "$toml" "mailer.nope")" "" \
    "read_toml_value: missing key -> empty"
  ok "$(read_toml_value "$toml" "absent.key")" "" \
    "read_toml_value: missing section -> empty"
  ok "$(read_toml_value "$TMP/does-not-exist.toml" "claude.branch")" "" \
    "read_toml_value: missing file -> empty"

  ok "$(read_toml_array "$toml" "profiles" | paste -sd, -)" "aws,dev-core,plex" \
    "read_toml_array: ordered array"
  ok "$(read_toml_array "$toml" "missing" | paste -sd, -)" "" \
    "read_toml_array: missing array -> empty"

  rm -rf "$TMP"
}

# ---------------------------------------------------------------------
# Block 2: dedup_keep_last
# ---------------------------------------------------------------------
dedup_tests() {
  # shellcheck disable=SC1090
  source "$CONFIG_LIB"

  ok "$(printf 'a\nb\nc\n' | dedup_keep_last | paste -sd, -)" "a,b,c" \
    "dedup_keep_last: no duplicates preserves order"
  ok "$(printf 'a\nb\na\nc\n' | dedup_keep_last | paste -sd, -)" "b,a,c" \
    "dedup_keep_last: keeps last occurrence (a moves later)"
  ok "$(printf 'a\n\nb\n\n' | dedup_keep_last | paste -sd, -)" "a,b" \
    "dedup_keep_last: drops blank lines"
}

# ---------------------------------------------------------------------
# Block 3: resolve_config_value single-winner across tiers
# ---------------------------------------------------------------------
resolve_value_tests() {
  local ROOT HOSTDIR
  ROOT="$(mktemp -d)"
  HOSTDIR="$(mktemp -d)"
  export MACOS_SETUP_HOST_DIR="$HOSTDIR"
  # shellcheck disable=SC1090
  source "$CONFIG_LIB"
  get_hostname() { echo "ctesthost"; }

  mkdir -p "$ROOT/default" \
           "$ROOT/profiles/aws" "$ROOT/profiles/dev-core"

  # Default tier defines claude.branch and a profiles array selecting
  # aws then dev-core.
  cat > "$ROOT/default/config.toml" <<'EOF'
[claude]
branch = "default-branch"
EOF
  # Host selects the profiles (host array is base; default has none).
  printf 'profiles = ["aws", "dev-core"]\n' > "$HOSTDIR/config.toml"

  ok "$(resolve_config_value "$ROOT" "claude.branch")" "default-branch" \
    "resolve_config_value: default tier wins when only it defines the key"

  # A profile overrides default.
  printf '[claude]\nbranch = "aws-branch"\n' > "$ROOT/profiles/aws/config.toml"
  ok "$(resolve_config_value "$ROOT" "claude.branch")" "aws-branch" \
    "resolve_config_value: profile beats default"

  # A later profile (dev-core) beats an earlier one (aws).
  printf '[claude]\nbranch = "dev-branch"\n' > "$ROOT/profiles/dev-core/config.toml"
  ok "$(resolve_config_value "$ROOT" "claude.branch")" "dev-branch" \
    "resolve_config_value: later profile beats earlier"

  # Host beats all. (Re-write host config.toml with both the profiles
  # array AND the claude.branch override.)
  cat > "$HOSTDIR/config.toml" <<'EOF'
profiles = ["aws", "dev-core"]

[claude]
branch = "host-branch"
EOF
  ok "$(resolve_config_value "$ROOT" "claude.branch")" "host-branch" \
    "resolve_config_value: external host beats all"

  ok "$(resolve_config_value "$ROOT" "claude.hostname")" "" \
    "resolve_config_value: unset key -> empty across all tiers"

  unset MACOS_SETUP_HOST_DIR
  rm -rf "$ROOT" "$HOSTDIR"
}

# ---------------------------------------------------------------------
# Block 4: get_profiles — host array, default-prepend, dedup-keeping-last
# ---------------------------------------------------------------------
get_profiles_tests() {
  local ROOT HOSTDIR
  ROOT="$(mktemp -d)"
  HOSTDIR="$(mktemp -d)"
  export MACOS_SETUP_HOST_DIR="$HOSTDIR"
  # shellcheck disable=SC1090
  source "$CONFIG_LIB"
  get_hostname() { echo "ptesthost"; }

  mkdir -p "$ROOT/default"

  # Zero-profile host: no config.toml in either tier.
  ok "$(get_profiles "$ROOT")" "" "get_profiles: zero-profile (no config.toml)"

  # Host-only array.
  printf 'profiles = ["aws", "dev-core", "plex"]\n' > "$HOSTDIR/config.toml"
  ok "$(get_profiles "$ROOT" | paste -sd, -)" "aws,dev-core,plex" \
    "get_profiles: host array, in order"

  # Default-prepend: a default profiles array is prepended (default-first).
  printf 'profiles = ["version-managers", "desktop-ui"]\n' \
    > "$ROOT/default/config.toml"
  ok "$(get_profiles "$ROOT" | paste -sd, -)" \
    "version-managers,desktop-ui,aws,dev-core,plex" \
    "get_profiles: default array prepended to host array"

  # Dedup-keeping-last: host re-lists a default profile -> it moves to
  # the host position (later), default copy is dropped.
  printf 'profiles = ["version-managers", "desktop-ui"]\n' \
    > "$ROOT/default/config.toml"
  printf 'profiles = ["aws", "desktop-ui", "plex"]\n' > "$HOSTDIR/config.toml"
  ok "$(get_profiles "$ROOT" | paste -sd, -)" \
    "version-managers,aws,desktop-ui,plex" \
    "get_profiles: dedup keeps last (desktop-ui moves to host position)"

  # Default-only array (host has none).
  rm -f "$HOSTDIR/config.toml"
  printf 'profiles = ["version-managers", "desktop-ui"]\n' \
    > "$ROOT/default/config.toml"
  ok "$(get_profiles "$ROOT" | paste -sd, -)" "version-managers,desktop-ui" \
    "get_profiles: default-only array (no host)"

  unset MACOS_SETUP_HOST_DIR
  rm -rf "$ROOT" "$HOSTDIR"
}

echo "=== primitive (read_toml_value/array) tests ==="
primitive_tests
echo "=== dedup_keep_last tests ==="
dedup_tests
echo "=== resolve_config_value tests ==="
resolve_value_tests
echo "=== get_profiles tests ==="
get_profiles_tests

echo
echo "---"
echo "pass=$pass fail=$fail"
if [[ $fail -eq 0 ]]; then
  echo "All config.toml tests passed."
  exit 0
fi
echo "Some config.toml tests FAILED."
exit 1
