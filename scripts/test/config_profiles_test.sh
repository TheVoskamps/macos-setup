#!/usr/bin/env bash

# Tests for the multiple-ordered-profiles config model (issue #150),
# the externalized host tier (issue #160), and the consolidated
# config.toml (issue #156).
#
# Covers:
#   - get_profiles(): ordered list from a config.toml `profiles` array,
#     zero-profile host, default-prepend, dedup-keeping-last
#   - resolve_file()/resolve_dir(): single-winner, highest tier wins
#     (host > reverse(profiles) > default)
#   - resolve_aggregate(): default -> profiles(order) -> host, skips
#     missing tiers
#   - install_filter.sh scope: an Install file is filtered against its
#     own tier and every higher-priority tier
#   - verify.sh: unknown profile name is a hard error
#   - seed_host_tier_if_absent(): seeds from template if absent, no-op
#     if present
#
# The HOST TIER now lives OUTSIDE the repo, at the path returned by
# host_tier_dir() (default ${XDG_CONFIG_HOME:-$HOME/.config}/macos-setup,
# overridable via MACOS_SETUP_HOST_DIR). Every block points
# MACOS_SETUP_HOST_DIR at a temp dir so the host tier is exercised
# without ever touching a real ~/.config path.
#
# The profile selector is now the `profiles` array in a per-tier
# config.toml, queried with `dasel`. These tests exercise the REAL dasel
# binary (no shim, no skip-guard); dasel is a hard dependency of the
# config layer (a guaranteed bootstrap primitive — see bootstrap.sh
# install_dasel).
#
# Each block builds a synthetic repo tree in a tmpdir, shadows
# get_hostname to a fixed value, points the host tier at a temp dir,
# and asserts the resolver/filter output.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_LIB="$REPO_ROOT/scripts/config_common.sh"

if ! command -v dasel >/dev/null 2>&1; then
  echo "FAIL: dasel not on PATH; config.toml tests require the real binary (bootstrap.sh install_dasel)." >&2
  exit 1
fi

# Write a config.toml `profiles = [...]` array into the given base dir.
# Args: base_dir, profile names...
write_profiles_toml() {
  local base="$1"; shift
  mkdir -p "$base"
  {
    echo "profiles = ["
    local n
    for n in "$@"; do echo "  \"$n\","; done
    echo "]"
  } > "$base/config.toml"
}

pass=0
fail=0
ok() {
  if [[ "$1" == "$2" ]]; then
    echo "PASS: $3"
    ((pass++))
  else
    echo "FAIL: $3 -- got [$1] want [$2]"
    ((fail++))
  fi
}
ok_rc() {
  # ok_rc <actual_rc> <want_rc> <label>
  if [[ "$1" == "$2" ]]; then echo "PASS: $3"; ((pass++)); else echo "FAIL: $3 (rc=$1 want $2)"; ((fail++)); fi
}

# ---------------------------------------------------------------------
# Block 1: resolver functions
# ---------------------------------------------------------------------
resolver_tests() {
  local ROOT HOST HOSTDIR
  ROOT="$(mktemp -d)"
  HOST="testhost"
  # External host tier: a temp dir, NOT a real ~/.config path.
  HOSTDIR="$(mktemp -d)"
  export MACOS_SETUP_HOST_DIR="$HOSTDIR"
  # shellcheck disable=SC1090
  source "$CONFIG_LIB"
  get_hostname() { echo "$HOST"; }

  ok "$(host_tier_dir)" "$HOSTDIR" "host_tier_dir: honors MACOS_SETUP_HOST_DIR"

  mkdir -p "$ROOT/default" \
           "$HOSTDIR" \
           "$ROOT/profiles/aws" \
           "$ROOT/profiles/edwin-dev"

  ok "$(get_profiles "$ROOT")" "" "get_profiles: zero-profile host (no config.toml)"

  write_profiles_toml "$HOSTDIR" aws edwin-dev
  ok "$(get_profiles "$ROOT" | paste -sd, -)" "aws,edwin-dev" \
    "get_profiles: ordered profiles array (external host tier config.toml)"

  echo D > "$ROOT/default/x"
  ok "$(resolve_file "$ROOT" x)" "$ROOT/default/x" \
    "resolve_file: default only"
  echo A > "$ROOT/profiles/aws/x"
  ok "$(resolve_file "$ROOT" x)" "$ROOT/profiles/aws/x" \
    "resolve_file: profile beats default"
  echo E > "$ROOT/profiles/edwin-dev/x"
  ok "$(resolve_file "$ROOT" x)" "$ROOT/profiles/edwin-dev/x" \
    "resolve_file: later profile beats earlier"
  echo H > "$HOSTDIR/x"
  ok "$(resolve_file "$ROOT" x)" "$HOSTDIR/x" \
    "resolve_file: external host beats all"

  mkdir -p "$ROOT/default/d" \
           "$ROOT/profiles/aws/d" \
           "$HOSTDIR/d"
  ok "$(resolve_dir "$ROOT" d)" "$HOSTDIR/d" \
    "resolve_dir: external host beats all"

  echo da > "$ROOT/default/aliases.zsh"
  echo aa > "$ROOT/profiles/aws/aliases.zsh"
  echo ea > "$ROOT/profiles/edwin-dev/aliases.zsh"
  echo ha > "$HOSTDIR/aliases.zsh"
  local got want
  got="$(resolve_aggregate "$ROOT" aliases.zsh \
    | sed "s#$ROOT/#REPO/#; s#$HOSTDIR/#HOST/#" | paste -sd, -)"
  want="REPO/default/aliases.zsh,REPO/profiles/aws/aliases.zsh,REPO/profiles/edwin-dev/aliases.zsh,HOST/aliases.zsh"
  ok "$got" "$want" "resolve_aggregate: default -> profiles(order) -> external host"

  rm "$ROOT/profiles/aws/aliases.zsh"
  got="$(resolve_aggregate "$ROOT" aliases.zsh \
    | sed "s#$ROOT/#REPO/#; s#$HOSTDIR/#HOST/#" | paste -sd, -)"
  want="REPO/default/aliases.zsh,REPO/profiles/edwin-dev/aliases.zsh,HOST/aliases.zsh"
  ok "$got" "$want" "resolve_aggregate: skips tiers without the file"

  rm "$HOSTDIR/config.toml"
  ok "$(resolve_file "$ROOT" x)" "$HOSTDIR/x" \
    "zero-profile: external host still wins"
  rm "$HOSTDIR/x"
  ok "$(resolve_file "$ROOT" x)" "$ROOT/default/x" \
    "zero-profile: falls back to default (profiles ignored)"

  if is_aggregate_file "aliases.zsh"; then echo "PASS: is_aggregate_file aliases.zsh"; ((pass++)); else echo "FAIL: aliases.zsh should be aggregate"; ((fail++)); fi
  if is_aggregate_file "config.toml"; then echo "FAIL: config.toml should NOT be aggregate"; ((fail++)); else echo "PASS: config.toml not aggregate"; ((pass++)); fi

  unset MACOS_SETUP_HOST_DIR
  rm -rf "$ROOT" "$HOSTDIR"
}

# ---------------------------------------------------------------------
# Block 2: install_filter.sh scope (subshell so the shadowed
# get_hostname in block 1 does not leak)
# ---------------------------------------------------------------------
filter_scope_tests() {
  local ROOT HOST HOSTDIR
  ROOT="$(mktemp -d)"
  HOST="ftesthost"
  # External host tier: a temp dir, NOT a real ~/.config path. The
  # install_filter.sh under test resolves the host tier via
  # host_tier_dir(), which honors MACOS_SETUP_HOST_DIR.
  HOSTDIR="$(mktemp -d)"
  export MACOS_SETUP_HOST_DIR="$HOSTDIR"

  mkdir -p "$ROOT/scripts"
  cp "$REPO_ROOT/scripts/config_common.sh" \
     "$REPO_ROOT/scripts/install_filter.sh" \
     "$REPO_ROOT/scripts/list_profiles.sh" "$ROOT/scripts/"
  printf 'get_hostname() { echo "%s"; }\n' "$HOST" >> "$ROOT/scripts/config_common.sh"

  mkdir -p "$ROOT/Install" "$ROOT/Uninstall" \
    "$ROOT/profiles/aws/Install" "$ROOT/profiles/aws/Uninstall" \
    "$ROOT/profiles/edwin-dev/Install" "$ROOT/profiles/edwin-dev/Uninstall" \
    "$HOSTDIR/Install" "$HOSTDIR/Uninstall"

  write_profiles_toml "$HOSTDIR" aws edwin-dev

  cat > "$ROOT/Install/05-Install.tools" <<'EOF'
brew "pkg_default"
brew "pkg_aws"
brew "pkg_edwin"
brew "pkg_host"
brew "pkg_keep"
EOF
  echo 'brew "pkg_default"' > "$ROOT/Uninstall/05-Uninstall.tools"
  echo 'brew "pkg_aws"'     > "$ROOT/profiles/aws/Uninstall/05-Uninstall.tools"
  echo 'brew "pkg_edwin"'   > "$ROOT/profiles/edwin-dev/Uninstall/05-Uninstall.tools"
  echo 'brew "pkg_host"'    > "$HOSTDIR/Uninstall/05-Uninstall.tools"

  local out res
  filtered() { grep -q "$1" <<<"$2"; }

  # Default-tier Install: scope = default + all profiles + host.
  out=$(bash "$ROOT/scripts/install_filter.sh" "$ROOT/Install/05-Install.tools")
  res=$(cat "$out"); rm -f "$out"
  for pkg in pkg_default pkg_aws pkg_edwin pkg_host; do
    if grep -q "# brew \"$pkg\"" <<<"$res"; then echo "PASS: default Install filters $pkg"; ((pass++)); else echo "FAIL: default Install should filter $pkg"; ((fail++)); fi
  done
  if grep -q '^brew "pkg_keep"' <<<"$res"; then echo "PASS: default Install keeps pkg_keep"; ((pass++)); else echo "FAIL: pkg_keep should survive"; ((fail++)); fi

  # aws-tier Install: scope = aws + edwin-dev + host (NOT default).
  cat > "$ROOT/profiles/aws/Install/05-Install.tools" <<'EOF'
brew "pkg_default"
brew "pkg_aws"
brew "pkg_edwin"
brew "pkg_host"
EOF
  out=$(bash "$ROOT/scripts/install_filter.sh" "$ROOT/profiles/aws/Install/05-Install.tools")
  res=$(cat "$out"); rm -f "$out"
  if grep -q '^brew "pkg_default"' <<<"$res"; then echo "PASS: aws Install: default out of scope (survives)"; ((pass++)); else echo "FAIL: default should be out of scope for aws tier"; ((fail++)); fi
  for pkg in pkg_aws pkg_edwin pkg_host; do
    if grep -q "# brew \"$pkg\"" <<<"$res"; then echo "PASS: aws Install filters $pkg"; ((pass++)); else echo "FAIL: aws Install should filter $pkg"; ((fail++)); fi
  done

  # edwin-dev-tier Install: scope = edwin-dev + host (NOT aws).
  cat > "$ROOT/profiles/edwin-dev/Install/05-Install.tools" <<'EOF'
brew "pkg_aws"
brew "pkg_edwin"
brew "pkg_host"
EOF
  out=$(bash "$ROOT/scripts/install_filter.sh" "$ROOT/profiles/edwin-dev/Install/05-Install.tools")
  res=$(cat "$out"); rm -f "$out"
  if grep -q '^brew "pkg_aws"' <<<"$res"; then echo "PASS: edwin Install: aws out of scope (survives)"; ((pass++)); else echo "FAIL: aws should be out of scope for edwin tier"; ((fail++)); fi
  for pkg in pkg_edwin pkg_host; do
    if grep -q "# brew \"$pkg\"" <<<"$res"; then echo "PASS: edwin Install filters $pkg"; ((pass++)); else echo "FAIL: edwin Install should filter $pkg"; ((fail++)); fi
  done

  # host-tier Install (external dir): scope = host only.
  cat > "$HOSTDIR/Install/05-Install.tools" <<'EOF'
brew "pkg_edwin"
brew "pkg_host"
EOF
  out=$(bash "$ROOT/scripts/install_filter.sh" "$HOSTDIR/Install/05-Install.tools")
  res=$(cat "$out"); rm -f "$out"
  if grep -q '^brew "pkg_edwin"' <<<"$res"; then echo "PASS: external host Install: profile out of scope (survives)"; ((pass++)); else echo "FAIL: edwin should be out of scope for host tier"; ((fail++)); fi
  if grep -q '# brew "pkg_host"' <<<"$res"; then echo "PASS: external host Install filters pkg_host"; ((pass++)); else echo "FAIL: host Install should filter pkg_host"; ((fail++)); fi

  unset MACOS_SETUP_HOST_DIR
  rm -rf "$ROOT" "$HOSTDIR"
}

# ---------------------------------------------------------------------
# Block 3: verify.sh hard-errors on an unknown profile name
# ---------------------------------------------------------------------
verify_unknown_profile_test() {
  local ROOT HOST HOSTDIR
  ROOT="$(mktemp -d)"
  HOST="vtesthost"
  # External host tier in a temp dir (verify.sh reads the profiles
  # selector from the host tier via get_profiles).
  HOSTDIR="$(mktemp -d)"
  export MACOS_SETUP_HOST_DIR="$HOSTDIR"

  mkdir -p "$ROOT/scripts" "$ROOT/Install" \
    "$ROOT/profiles/known/Install"
  cp "$REPO_ROOT/scripts/config_common.sh" \
     "$REPO_ROOT/scripts/verify.sh" "$ROOT/scripts/"
  printf 'get_hostname() { echo "%s"; }\n' "$HOST" >> "$ROOT/scripts/config_common.sh"

  # A minimal Install file so verify has something to scan past the
  # profile check.
  echo 'brew "ls"' > "$ROOT/Install/00-Install.core"

  # Known profile only -> profile check passes (verify may still exit
  # non-zero if a package is missing, but NOT 1 from the profile check;
  # we assert the error message is absent).
  write_profiles_toml "$HOSTDIR" known
  local err
  err="$(cd "$ROOT" && bash scripts/verify.sh 2>&1 >/dev/null)"
  if grep -q 'lists unknown profile' <<<"$err"; then echo "FAIL: known profile should not error"; ((fail++)); else echo "PASS: known profile passes profile check"; ((pass++)); fi

  # Unknown profile -> hard error, exit 1, message names the profile.
  write_profiles_toml "$HOSTDIR" known bogus
  err="$(cd "$ROOT" && bash scripts/verify.sh 2>&1 >/dev/null)"
  local rc
  ( cd "$ROOT" && bash scripts/verify.sh >/dev/null 2>&1 ); rc=$?
  ok_rc "$rc" 1 "verify: unknown profile exits 1"
  if grep -q "bogus" <<<"$err" && grep -q 'unknown profile' <<<"$err"; then echo "PASS: verify names the unknown profile"; ((pass++)); else echo "FAIL: verify error should name 'bogus'"; ((fail++)); fi

  unset MACOS_SETUP_HOST_DIR
  rm -rf "$ROOT" "$HOSTDIR"
}

# ---------------------------------------------------------------------
# Block 4: seed_host_tier_if_absent() — seeds from the in-repo template
# only when the external dir is absent; no-op when it already exists.
# ---------------------------------------------------------------------
seed_host_tier_test() {
  local ROOT HOSTDIR
  ROOT="$(mktemp -d)"

  # Build a minimal in-repo template tree. The template now ships a
  # single consolidated config.toml (issue #156) plus aliases.zsh.
  mkdir -p "$ROOT/computer-specific/_template"
  printf 'profiles = ["aws"]\n# [mailer] / [claude] / [cron] documented here\n' \
    > "$ROOT/computer-specific/_template/config.toml"
  printf '# personal aliases\n' > "$ROOT/computer-specific/_template/aliases.zsh"

  # Point the host tier at a path that does NOT exist yet.
  HOSTDIR="$(mktemp -d)/host"   # parent exists, $HOSTDIR itself does not
  export MACOS_SETUP_HOST_DIR="$HOSTDIR"
  # shellcheck disable=SC1090
  source "$CONFIG_LIB"

  # Absent -> seeds the template.
  seed_host_tier_if_absent "$ROOT" >/dev/null 2>&1
  ok_rc "$([[ -f "$HOSTDIR/config.toml" ]] && echo 0 || echo 1)" 0 \
    "seed: creates config.toml from template when absent"
  ok "$(get_profiles "$ROOT" | paste -sd, -)" "aws" \
    "seed: template config.toml profiles array resolves"
  ok_rc "$([[ -f "$HOSTDIR/aliases.zsh" ]] && echo 0 || echo 1)" 0 \
    "seed: aliases.zsh copied"

  # Present -> no-op (never overwrites a user edit).
  write_profiles_toml "$HOSTDIR" edited-by-user
  seed_host_tier_if_absent "$ROOT" >/dev/null 2>&1
  ok "$(get_profiles "$ROOT" | paste -sd, -)" "edited-by-user" \
    "seed: no-op when host dir already exists (user edit preserved)"

  unset MACOS_SETUP_HOST_DIR
  rm -rf "$ROOT" "$HOSTDIR"
}

# Run resolver_tests last: it sources config_common.sh and shadows
# get_hostname in this shell. The other blocks invoke scripts via
# external `bash`, so they are unaffected by ordering, but running them
# first keeps this shell's get_hostname pristine for them anyway.
echo "=== install_filter scope tests ==="
filter_scope_tests
echo "=== verify unknown-profile test ==="
verify_unknown_profile_test
echo "=== seed-host-tier tests ==="
seed_host_tier_test
echo "=== resolver tests ==="
resolver_tests

echo
echo "---"
echo "pass=$pass fail=$fail"
if [[ $fail -eq 0 ]]; then
  echo "All config-profiles tests passed."
  exit 0
fi
echo "Some config-profiles tests FAILED."
exit 1
