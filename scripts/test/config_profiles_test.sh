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
#   - install_filter.sh scope: a tier's Brewfile is filtered against its
#     own tier and every higher-priority tier (issue #33 moved the removal
#     identifiers from peer Uninstall/RemoveAndPurge slot files into each
#     tier's `[profile] uninstall` / `[profile] purge` arrays; the scope
#     rule itself is unchanged)
#   - the [profile] read layer: parse_removal_entry, tier_label,
#     tier_roots, read_post_install, read_removals
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
# Block 2: install_filter.sh scope
#
# Since issue #33 the filter keys on TIER ROOTS carrying an unnumbered
# `Brewfile`, and reads its removal identifiers from that tier's
# `config.toml` `[profile] uninstall` / `[profile] purge` arrays. The SCOPE
# RULE is unchanged from the numbered-slot era, and is what this block
# pins: a tier's Brewfile is filtered against its OWN tier and every
# HIGHER-priority tier, and against nothing below it.
# ---------------------------------------------------------------------

# Write a config.toml carrying a `[profile] uninstall` array.
# Args: base_dir, entries...
write_uninstall_toml() {
  local base="$1"; shift
  mkdir -p "$base"
  {
    echo "[profile]"
    echo -n "uninstall = ["
    local e first=1
    for e in "$@"; do
      [[ $first -eq 1 ]] || echo -n ", "
      echo -n "\"$e\""
      first=0
    done
    echo "]"
  } > "$base/config.toml"
}

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

  mkdir -p "$ROOT/default" "$ROOT/profiles/aws" "$ROOT/profiles/edwin-dev" "$HOSTDIR"

  # The host tier's config.toml carries BOTH the `profiles` array (which
  # selects the profile stack) and its own `[profile] uninstall`. The bare
  # `profiles` key must precede the first table.
  {
    printf 'profiles = ["aws", "edwin-dev"]\n'
    printf '[profile]\nuninstall = ["brew:pkg_host"]\n'
  } > "$HOSTDIR/config.toml"

  write_uninstall_toml "$ROOT/default"            "brew:pkg_default"
  write_uninstall_toml "$ROOT/profiles/aws"       "brew:pkg_aws"
  write_uninstall_toml "$ROOT/profiles/edwin-dev" "brew:pkg_edwin"

  cat > "$ROOT/default/Brewfile" <<'EOF'
brew "pkg_default"
brew "pkg_aws"
brew "pkg_edwin"
brew "pkg_host"
brew "pkg_keep"
EOF

  local out res

  # Core-tier Brewfile: scope = core + all profiles + host.
  out=$(bash "$ROOT/scripts/install_filter.sh" "$ROOT/default/Brewfile")
  res=$(cat "$out"); rm -f "$out"
  for pkg in pkg_default pkg_aws pkg_edwin pkg_host; do
    if grep -q "# brew \"$pkg\"" <<<"$res"; then echo "PASS: core Brewfile filters $pkg"; ((pass++)); else echo "FAIL: core Brewfile should filter $pkg"; ((fail++)); fi
  done
  if grep -q '^brew "pkg_keep"' <<<"$res"; then echo "PASS: core Brewfile keeps pkg_keep"; ((pass++)); else echo "FAIL: pkg_keep should survive"; ((fail++)); fi

  # aws-tier Brewfile: scope = aws + edwin-dev + host (NOT core).
  cat > "$ROOT/profiles/aws/Brewfile" <<'EOF'
brew "pkg_default"
brew "pkg_aws"
brew "pkg_edwin"
brew "pkg_host"
EOF
  out=$(bash "$ROOT/scripts/install_filter.sh" "$ROOT/profiles/aws/Brewfile")
  res=$(cat "$out"); rm -f "$out"
  if grep -q '^brew "pkg_default"' <<<"$res"; then echo "PASS: aws Brewfile: core out of scope (survives)"; ((pass++)); else echo "FAIL: core should be out of scope for aws tier"; ((fail++)); fi
  for pkg in pkg_aws pkg_edwin pkg_host; do
    if grep -q "# brew \"$pkg\"" <<<"$res"; then echo "PASS: aws Brewfile filters $pkg"; ((pass++)); else echo "FAIL: aws Brewfile should filter $pkg"; ((fail++)); fi
  done

  # edwin-dev-tier Brewfile: scope = edwin-dev + host (NOT aws).
  cat > "$ROOT/profiles/edwin-dev/Brewfile" <<'EOF'
brew "pkg_aws"
brew "pkg_edwin"
brew "pkg_host"
EOF
  out=$(bash "$ROOT/scripts/install_filter.sh" "$ROOT/profiles/edwin-dev/Brewfile")
  res=$(cat "$out"); rm -f "$out"
  if grep -q '^brew "pkg_aws"' <<<"$res"; then echo "PASS: edwin Brewfile: aws out of scope (survives)"; ((pass++)); else echo "FAIL: aws should be out of scope for edwin tier"; ((fail++)); fi
  for pkg in pkg_edwin pkg_host; do
    if grep -q "# brew \"$pkg\"" <<<"$res"; then echo "PASS: edwin Brewfile filters $pkg"; ((pass++)); else echo "FAIL: edwin Brewfile should filter $pkg"; ((fail++)); fi
  done

  # host-tier Brewfile (external dir): scope = host only.
  cat > "$HOSTDIR/Brewfile" <<'EOF'
brew "pkg_edwin"
brew "pkg_host"
EOF
  out=$(bash "$ROOT/scripts/install_filter.sh" "$HOSTDIR/Brewfile")
  res=$(cat "$out"); rm -f "$out"
  if grep -q '^brew "pkg_edwin"' <<<"$res"; then echo "PASS: external host Brewfile: profile out of scope (survives)"; ((pass++)); else echo "FAIL: edwin should be out of scope for host tier"; ((fail++)); fi
  if grep -q '# brew "pkg_host"' <<<"$res"; then echo "PASS: external host Brewfile filters pkg_host"; ((pass++)); else echo "FAIL: host Brewfile should filter pkg_host"; ((fail++)); fi

  # `purge` suppresses exactly as `uninstall` does, across every entry
  # kind. This is the "I opted into `web` but I don't want its Chrome"
  # case the tier-suppression semantics exist for.
  {
    printf 'profiles = ["aws", "edwin-dev"]\n'
    printf '[profile]\npurge = ["cask:pkg_cask", "mas:12345"]\n'
  } > "$HOSTDIR/config.toml"
  cat > "$ROOT/default/Brewfile" <<'EOF'
cask "pkg_cask"
mas "Some App", id: 12345
mas "Other App", id: 99999
EOF
  out=$(bash "$ROOT/scripts/install_filter.sh" "$ROOT/default/Brewfile")
  res=$(cat "$out"); rm -f "$out"
  if grep -q '# cask "pkg_cask"' <<<"$res"; then echo "PASS: purge array filters a cask"; ((pass++)); else echo "FAIL: purge array should filter cask pkg_cask"; ((fail++)); fi
  if grep -q '# mas "Some App", id: 12345' <<<"$res"; then echo "PASS: purge array filters a mas entry by id"; ((pass++)); else echo "FAIL: purge array should filter mas id 12345"; ((fail++)); fi
  if grep -q '^mas "Other App", id: 99999' <<<"$res"; then echo "PASS: unlisted mas entry survives"; ((pass++)); else echo "FAIL: mas id 99999 should survive"; ((fail++)); fi

  # A malformed removal entry is a hard error, never a silently ignored
  # removal.
  printf '[profile]\nuninstall = ["notakind:foo"]\n' > "$ROOT/default/config.toml"
  printf 'brew "pkg_keep"\n' > "$ROOT/default/Brewfile"
  local rc
  bash "$ROOT/scripts/install_filter.sh" "$ROOT/default/Brewfile" >/dev/null 2>&1; rc=$?
  ok_rc "$rc" 2 "install_filter: malformed removal entry exits 2"

  unset MACOS_SETUP_HOST_DIR
  rm -rf "$ROOT" "$HOSTDIR"
}

# ---------------------------------------------------------------------
# Block 2b: the [profile] section read layer in config_common.sh —
# parse_removal_entry's grammar and rejections, tier_label's three
# shapes, and the per-tier (never resolved) reads.
# ---------------------------------------------------------------------
profile_section_tests() {
  local ROOT HOSTDIR
  ROOT="$(mktemp -d)"
  HOSTDIR="$(mktemp -d)"
  export MACOS_SETUP_HOST_DIR="$HOSTDIR"
  # shellcheck disable=SC1090
  source "$CONFIG_LIB"

  mkdir -p "$ROOT/default" "$ROOT/profiles/alpha" "$HOSTDIR"

  ok "$(parse_removal_entry 'brew:asdf' | tr '\t' '|')" "brew|asdf|asdf" \
    "parse_removal_entry: brew"
  ok "$(parse_removal_entry 'cask:qblocker' | tr '\t' '|')" "cask|qblocker|qblocker" \
    "parse_removal_entry: cask"
  ok "$(parse_removal_entry 'mas:1365531024' | tr '\t' '|')" "mas|1365531024|1365531024" \
    "parse_removal_entry: mas without a label"
  ok "$(parse_removal_entry 'mas:1365531024:1Blocker' | tr '\t' '|')" "mas|1365531024|1Blocker" \
    "parse_removal_entry: mas with a label"

  local rc
  parse_removal_entry 'asdf' >/dev/null 2>&1; rc=$?
  ok_rc "$rc" 2 "parse_removal_entry: rejects a bare identifier (no kind)"
  parse_removal_entry 'wat:asdf' >/dev/null 2>&1; rc=$?
  ok_rc "$rc" 2 "parse_removal_entry: rejects an unknown kind"
  parse_removal_entry 'mas:notanumber' >/dev/null 2>&1; rc=$?
  ok_rc "$rc" 2 "parse_removal_entry: rejects a non-numeric mas id"
  parse_removal_entry 'brew:foo:bar' >/dev/null 2>&1; rc=$?
  ok_rc "$rc" 2 "parse_removal_entry: rejects a label on a brew entry"

  ok "$(tier_label "$ROOT" "$ROOT/default")" "core" "tier_label: core tier"
  ok "$(tier_label "$ROOT" "$ROOT/profiles/alpha")" "profile alpha" "tier_label: profile tier"
  ok "$(tier_label "$ROOT" "$HOSTDIR")" "host" "tier_label: host tier"
  # A RELATIVE tier root must label the same as its absolute form: the
  # Makefile's tier list mixes relative in-repo roots with the absolute
  # host dir, and a relative `default` that fell through to the host label
  # would mislabel every in-repo tier.
  ok "$(cd "$ROOT" && tier_label "$ROOT" "default")" "core" \
    "tier_label: relative core tier root"
  ok "$(cd "$ROOT" && tier_label "$ROOT" "profiles/alpha")" "profile alpha" \
    "tier_label: relative profile tier root"

  {
    printf '[profile]\n'
    printf 'post_install = ["scripts/a.sh", "scripts/b.sh --flag"]\n'
    printf 'uninstall = ["brew:one"]\n'
    printf 'purge = ["cask:two"]\n'
  } > "$ROOT/default/config.toml"
  ok "$(read_post_install "$ROOT/default" | paste -sd, -)" "scripts/a.sh,scripts/b.sh --flag" \
    "read_post_install: ordered, arguments preserved"
  ok "$(read_removals "$ROOT/default" uninstall | paste -sd, -)" "brew:one" \
    "read_removals: uninstall array"
  ok "$(read_removals "$ROOT/default" purge | paste -sd, -)" "cask:two" \
    "read_removals: purge array"

  # A tier with no [profile] section, and a tier with no config.toml at
  # all, both read as empty rather than erroring.
  printf '[mailer]\nbackend = "msmtp"\n' > "$ROOT/profiles/alpha/config.toml"
  ok "$(read_post_install "$ROOT/profiles/alpha")" "" "read_post_install: absent section is empty"
  ok "$(read_removals "$ROOT/profiles/alpha" purge)" "" "read_removals: absent section is empty"
  ok "$(read_post_install "$HOSTDIR")" "" "read_post_install: absent config.toml is empty"

  # [profile] is PER-TIER, never resolved across tiers: the core tier's
  # post_install must not leak into a profile that declares none.
  ok "$(read_post_install "$ROOT/profiles/alpha")" "" \
    "[profile] is per-tier: core's post_install does not leak into a profile"

  # tier_roots(): core -> profiles in list order -> host.
  printf 'profiles = ["alpha"]\n' > "$HOSTDIR/config.toml"
  ok "$(tier_roots "$ROOT" | sed "s#$ROOT/#REPO/#; s#^$HOSTDIR\$#HOST#" | paste -sd, -)" \
    "REPO/default,REPO/profiles/alpha,HOST" \
    "tier_roots: core -> profiles(order) -> host"

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

  mkdir -p "$ROOT/scripts" "$ROOT/default" "$ROOT/profiles/known"
  cp "$REPO_ROOT/scripts/config_common.sh" \
     "$REPO_ROOT/scripts/verify.sh" "$ROOT/scripts/"
  printf 'get_hostname() { echo "%s"; }\n' "$HOST" >> "$ROOT/scripts/config_common.sh"

  # A minimal core Brewfile so verify has something to scan past the
  # profile check.
  echo 'brew "ls"' > "$ROOT/default/Brewfile"

  # Known profile only -> profile check passes (verify may still exit
  # non-zero if a package is missing, but NOT 1 from the profile check;
  # we assert the error message is absent).
  write_profiles_toml "$HOSTDIR" known
  local err
  err="$(cd "$ROOT" && bash scripts/verify.sh 2>&1 >/dev/null)"
  if grep -q 'unknown profile' <<<"$err"; then echo "FAIL: known profile should not error"; ((fail++)); else echo "PASS: known profile passes profile check"; ((pass++)); fi

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
echo "=== [profile] section read tests ==="
profile_section_tests
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
