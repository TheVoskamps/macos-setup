#!/usr/bin/env bash
# asdf_to_mise_test.sh — behavioral tests for scripts/asdf_to_mise.sh.
#
# The migration target is purely additive and idempotent, and both of
# those are easy to break silently, so they are pinned here. `mise` itself
# is stubbed (via the MISE override that mise_common.sh honors) so the
# suite needs no real install and never touches the host.
#
# Run: bash scripts/test/asdf_to_mise_test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SUT="$REPO_ROOT/scripts/asdf_to_mise.sh"

pass=0
fail=0

ok()   { pass=$((pass+1)); printf 'PASS: %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf 'FAIL: %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

SANDBOX="$REPO_ROOT/.claude/tmp/issue-32-asdf-to-mise"
rm -rf "$SANDBOX"
mkdir -p "$SANDBOX"

# --- mise stub -------------------------------------------------------
# Implements only what asdf_to_mise.sh calls:
#   mise generate config -g -y [--tool-versions <file>]
#   mise generate config --tool-versions <file> -y
#   mise cfg | mise ls
# The .tool-versions -> [tools] conversion mirrors mise's own: `nodejs`
# maps to `node`, a single version token becomes a string, and MULTIPLE
# version tokens become a TOML array (the defect the SUT's pre-flight is
# supposed to reject before ever getting here).
STUB="$SANDBOX/bin/mise"
mkdir -p "$SANDBOX/bin"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
set -uo pipefail
convert() { # $1 = .tool-versions path, $2 = output path
  mkdir -p "$(dirname "$2")"
  {
    echo '[tools]'
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%%#*}"
      # shellcheck disable=SC2086
      set -- $line
      [ $# -ge 2 ] || continue
      tool="$1"; shift
      [ "$tool" = "nodejs" ] && tool="node"
      if [ $# -eq 1 ]; then
        printf '%s = "%s"\n' "$tool" "$1"
      else
        printf '%s = [' "$tool"
        sep=""
        for v in "$@"; do printf '%s"%s"' "$sep" "$v"; sep=", "; done
        printf ']\n'
      fi
    done < "$1"
  } > "$2"
}
case "${1:-}" in
  generate)
    global=0; tv=""
    shift 2   # drop "generate config"
    while [ $# -gt 0 ]; do
      case "$1" in
        -g) global=1 ;;
        --tool-versions) tv="$2"; shift ;;
        -y|-n) ;;
      esac
      shift
    done
    if [ "$global" -eq 1 ]; then
      out="${XDG_CONFIG_HOME:-$HOME/.config}/mise/config.toml"
    else
      out="$PWD/mise.toml"
    fi
    if [ -n "$tv" ]; then convert "$tv" "$out"; else mkdir -p "$(dirname "$out")"; : > "$out"; fi
    ;;
  cfg) echo "stub: mise cfg in $PWD" ;;
  ls)  echo "stub: mise ls in $PWD" ;;
  *)   echo "stub: unhandled: $*" >&2; exit 2 ;;
esac
STUBEOF
chmod +x "$STUB"

# Each case gets a pristine HOME + XDG_CONFIG_HOME so nothing leaks
# between cases and nothing touches the real host.
new_case() {
  CASE_DIR="$SANDBOX/$1"
  rm -rf "$CASE_DIR"
  mkdir -p "$CASE_DIR/home"
  export HOME="$CASE_DIR/home"
  export XDG_CONFIG_HOME="$CASE_DIR/home/.config"
  GLOBAL_CFG="$XDG_CONFIG_HOME/mise/config.toml"
}

make_repo() { # $1 = path
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" config user.email t@example.com
  git -C "$1" config user.name Test
}

run_sut() { # $1 = START_DIR ; captures OUT / RC
  # The sandbox lives inside this repo's own worktree, so without a
  # ceiling git's upward discovery walk would find macos-setup itself and
  # the "not a git repository" case could never be exercised. The ceiling
  # stops the walk at the sandbox root; the per-case repos below sit
  # under it and are still found normally.
  OUT="$(START_DIR="$1" MISE="$STUB" GIT_CEILING_DIRECTORIES="$SANDBOX" \
         bash "$SUT" 2>&1)"
  RC=$?
}

# === case 1: aborts when START_DIR is not a git repository ============
new_case case1
run_sut "$CASE_DIR/home"
[ "$RC" -ne 0 ] && ok "case 1: non-repo aborts non-zero" || bad "case 1: non-repo aborts non-zero"
case "$OUT" in *"not inside a git repository"*) ok "case 1: names the reason" ;;
  *) bad "case 1: names the reason (got: $OUT)" ;; esac

# === case 2: aborts when START_DIR is a repo SUBDIRECTORY =============
new_case case2
make_repo "$CASE_DIR/repo"
mkdir -p "$CASE_DIR/repo/sub"
run_sut "$CASE_DIR/repo/sub"
[ "$RC" -ne 0 ] && ok "case 2: subdirectory aborts non-zero" || bad "case 2: subdirectory aborts non-zero"
case "$OUT" in *"not the root of its git repository"*) ok "case 2: names the reason" ;;
  *) bad "case 2: names the reason (got: $OUT)" ;; esac
[ ! -f "$CASE_DIR/repo/sub/.gitignore" ] && ok "case 2: wrote no .gitignore" || bad "case 2: wrote no .gitignore"

# === case 3: multi-version line aborts, quoted, with no mise.toml =====
new_case case3
make_repo "$CASE_DIR/repo"
printf 'java temurin 26.0.1+8\nnodejs 24.5.0\n' > "$CASE_DIR/repo/.tool-versions"
run_sut "$CASE_DIR/repo"
[ "$RC" -ne 0 ] && ok "case 3: multi-version line aborts non-zero" || bad "case 3: multi-version line aborts non-zero"
case "$OUT" in *"java temurin 26.0.1+8"*) ok "case 3: quotes the offending line" ;;
  *) bad "case 3: quotes the offending line (got: $OUT)" ;; esac
[ ! -f "$CASE_DIR/repo/mise.toml" ] && ok "case 3: wrote no mise.toml" || bad "case 3: wrote no mise.toml"
[ -f "$CASE_DIR/repo/.tool-versions" ] && ok "case 3: left .tool-versions in place" || bad "case 3: left .tool-versions in place"

# === case 4: happy path — global config, mise.toml, .gitignore ========
new_case case4
make_repo "$CASE_DIR/repo"
printf 'awscli 2.31.11\n' > "$HOME/.tool-versions"
mkdir -p "$HOME/.asdf" "$HOME/.config/direnv/lib"
: > "$HOME/.config/direnv/lib/use_asdf.sh"
printf 'nodejs 24.5.0\njava temurin-26.0.1+8\n' > "$CASE_DIR/repo/.tool-versions"
printf 'use asdf\ndotenv_if_exists\n' > "$CASE_DIR/repo/.envrc"
printf '*.log\n' > "$CASE_DIR/repo/.gitignore"
git -C "$CASE_DIR/repo" add -A >/dev/null 2>&1
git -C "$CASE_DIR/repo" commit -qm init >/dev/null 2>&1
run_sut "$CASE_DIR/repo"
check "case 4: exits zero" "$RC" "0"

grep -q 'awscli = "2.31.11"' "$GLOBAL_CFG" \
  && ok "case 4: global config carries \$HOME/.tool-versions tools" \
  || bad "case 4: global config carries \$HOME/.tool-versions tools"
grep -q 'env_file = ".env"' "$GLOBAL_CFG" \
  && ok "case 4: global config carries env_file" \
  || bad "case 4: global config carries env_file"

# nodejs -> node, and the hyphenated java form stays a single exact pin
grep -q 'node = "24.5.0"' "$CASE_DIR/repo/mise.toml" \
  && ok "case 4: mise.toml has equivalent [tools]" \
  || bad "case 4: mise.toml has equivalent [tools]"
grep -q 'java = "temurin-26.0.1+8"' "$CASE_DIR/repo/mise.toml" \
  && ok "case 4: java temurin-<v> is a single exact pin, not an array" \
  || bad "case 4: java temurin-<v> is a single exact pin, not an array"

grep -q '^/mise.local.toml$' "$CASE_DIR/repo/.gitignore" \
  && ok "case 4: .gitignore block written" || bad "case 4: .gitignore block written"
grep -q '^\*\.log$' "$CASE_DIR/repo/.gitignore" \
  && ok "case 4: pre-existing .gitignore content preserved" \
  || bad "case 4: pre-existing .gitignore content preserved"
grep -q '^mise.toml$' "$CASE_DIR/repo/.gitignore" \
  && bad "case 4: mise.toml must NOT be ignored" \
  || ok "case 4: mise.toml is not ignored"

# Deletes nothing.
for leftover in "$HOME/.asdf" "$HOME/.tool-versions" \
                "$HOME/.config/direnv/lib/use_asdf.sh" \
                "$CASE_DIR/repo/.envrc" "$CASE_DIR/repo/.tool-versions"; do
  [ -e "$leftover" ] && ok "case 4: left $(basename "$leftover") on disk" \
                     || bad "case 4: left $(basename "$leftover") on disk"
done

# ...and names each of them in the warning output.
for name in ".asdf" ".tool-versions" "use_asdf.sh" ".envrc"; do
  case "$OUT" in *"$name"*) ok "case 4: warning names $name" ;;
    *) bad "case 4: warning names $name" ;; esac
done

# Commits nothing, untracks nothing.
check "case 4: made no commit" \
  "$(git -C "$CASE_DIR/repo" rev-list --count HEAD)" "1"
git -C "$CASE_DIR/repo" ls-files --error-unmatch .tool-versions >/dev/null 2>&1 \
  && ok "case 4: .tool-versions still tracked" || bad "case 4: .tool-versions still tracked"

# === case 5: second run is a clean no-op ==============================
GLOBAL_BEFORE="$(cat "$GLOBAL_CFG")"
MISE_TOML_BEFORE="$(cat "$CASE_DIR/repo/mise.toml")"
printf 'node = "hand-edited"\n' >> "$CASE_DIR/repo/mise.toml"
MISE_TOML_MARKED="$(cat "$CASE_DIR/repo/mise.toml")"
run_sut "$CASE_DIR/repo"
check "case 5: re-run exits zero" "$RC" "0"
check "case 5: global config unmodified" "$(cat "$GLOBAL_CFG")" "$GLOBAL_BEFORE"
check "case 5: env_file not duplicated" \
  "$(grep -c 'env_file' "$GLOBAL_CFG")" "1"
check "case 5: existing mise.toml not clobbered" \
  "$(cat "$CASE_DIR/repo/mise.toml")" "$MISE_TOML_MARKED"
check "case 5: .gitignore block not duplicated" \
  "$(grep -c '^/mise.local.toml$' "$CASE_DIR/repo/.gitignore")" "1"
check "case 5: made no commit" \
  "$(git -C "$CASE_DIR/repo" rev-list --count HEAD)" "1"
: "$MISE_TOML_BEFORE"

# === case 6: a hand-written [settings] block survives intact ==========
new_case case6
make_repo "$CASE_DIR/repo"
mkdir -p "$(dirname "$GLOBAL_CFG")"
cat > "$GLOBAL_CFG" <<'EOF'
[tools]
node = "24.5.0"

[settings]
experimental = true
EOF
run_sut "$CASE_DIR/repo"
check "case 6: exits zero" "$RC" "0"
grep -q 'experimental = true' "$GLOBAL_CFG" \
  && ok "case 6: hand-written [settings] key survives" \
  || bad "case 6: hand-written [settings] key survives"
grep -q 'node = "24.5.0"' "$GLOBAL_CFG" \
  && ok "case 6: hand-written [tools] survives" || bad "case 6: hand-written [tools] survives"
check "case 6: exactly one [settings] table" \
  "$(grep -c '^\[settings\]$' "$GLOBAL_CFG")" "1"
check "case 6: env_file added exactly once" \
  "$(grep -c 'env_file' "$GLOBAL_CFG")" "1"
# The key must land INSIDE [settings], not after a later table.
awk '/^\[settings\]$/{s=1;next} /^\[/{s=0} s && /env_file/{found=1} END{exit !found}' "$GLOBAL_CFG" \
  && ok "case 6: env_file landed inside the [settings] table" \
  || bad "case 6: env_file landed inside the [settings] table"

# === case 6b: a [settings] header with a TRAILING COMMENT =============
# TOML allows `[settings] # note`. A bare-header-only regex misses it, falls
# through to the append branch, and leaves the file with TWO [settings]
# tables — invalid TOML that mise cannot parse.
new_case case6b
make_repo "$CASE_DIR/repo"
mkdir -p "$(dirname "$GLOBAL_CFG")"
cat > "$GLOBAL_CFG" <<'EOF'
[tools]
node = "24.5.0"

[settings] # user comment
experimental = true
EOF
run_sut "$CASE_DIR/repo"
check "case 6b: exits zero" "$RC" "0"
check "case 6b: exactly one [settings] table" \
  "$(grep -c '^\[settings\]' "$GLOBAL_CFG")" "1"
check "case 6b: env_file added exactly once" \
  "$(grep -c 'env_file' "$GLOBAL_CFG")" "1"
grep -q 'experimental = true' "$GLOBAL_CFG" \
  && ok "case 6b: hand-written [settings] key survives" \
  || bad "case 6b: hand-written [settings] key survives"
awk '/^\[settings\]/{s=1;next} /^\[/{s=0} s && /env_file/{found=1} END{exit !found}' "$GLOBAL_CFG" \
  && ok "case 6b: env_file landed inside the [settings] table" \
  || bad "case 6b: env_file landed inside the [settings] table"

# === case 7: no .tool-versions — still writes the .gitignore block ====
new_case case7
make_repo "$CASE_DIR/repo"
run_sut "$CASE_DIR/repo"
check "case 7: exits zero" "$RC" "0"
[ ! -f "$CASE_DIR/repo/mise.toml" ] \
  && ok "case 7: no .tool-versions means no mise.toml" \
  || bad "case 7: no .tool-versions means no mise.toml"
grep -q '^/mise.local.toml$' "$CASE_DIR/repo/.gitignore" \
  && ok "case 7: .gitignore created from scratch" || bad "case 7: .gitignore created from scratch"

# === case 8: the three leftover conditions, reported independently ====
# (a) on disk, (b) matched by an ignore rule, (c) tracked in git. They occur
# in ANY combination and each has its own remedy, so each must be reported
# on its own. Here .envrc has all three; .tool-versions has only (a).
new_case case8
make_repo "$CASE_DIR/repo"
printf 'use asdf\n' > "$CASE_DIR/repo/.envrc"
printf 'nodejs 24.5.0\n' > "$CASE_DIR/repo/.tool-versions"
printf '.envrc\n' > "$CASE_DIR/repo/.gitignore"
# -f, because .envrc is ignored by the rule we just wrote and must still
# reach the index for condition (c) to be exercised.
git -C "$CASE_DIR/repo" add -f .envrc .tool-versions .gitignore >/dev/null 2>&1
git -C "$CASE_DIR/repo" commit -qm init >/dev/null 2>&1
run_sut "$CASE_DIR/repo"
check "case 8: exits zero" "$RC" "0"
case "$OUT" in *"(a) present on disk"*) ok "case 8: reports condition (a)" ;;
  *) bad "case 8: reports condition (a) (got: $OUT)" ;; esac
case "$OUT" in *"(b) matched by an ignore rule"*) ok "case 8: reports condition (b)" ;;
  *) bad "case 8: reports condition (b) (got: $OUT)" ;; esac
case "$OUT" in *"(c) tracked in git"*) ok "case 8: reports condition (c)" ;;
  *) bad "case 8: reports condition (c) (got: $OUT)" ;; esac
case "$OUT" in *"git rm .envrc"*) ok "case 8: (c) remedy is git rm, not an ignore rule" ;;
  *) bad "case 8: (c) remedy is git rm, not an ignore rule (got: $OUT)" ;; esac
case "$OUT" in *".gitignore:1:.envrc"*) ok "case 8: (b) names the rule's source and line" ;;
  *) bad "case 8: (b) names the rule's source and line (got: $OUT)" ;; esac
# .tool-versions is on disk and tracked, but carries NO ignore rule here.
check "case 8: only .envrc reports (b); .tool-versions has no ignore rule" \
  "$(printf '%s\n' "$OUT" | grep -c '(b) matched by an ignore rule')" "1"
# Still deletes and untracks nothing.
[ -f "$CASE_DIR/repo/.envrc" ] && ok "case 8: left .envrc on disk" || bad "case 8: left .envrc on disk"
git -C "$CASE_DIR/repo" ls-files --error-unmatch .envrc >/dev/null 2>&1 \
  && ok "case 8: .envrc still tracked" || bad "case 8: .envrc still tracked"

# === case 9: an ignore rule ALONE still warns =========================
# The file is gone but the rule survives it — a rule left behind silently
# hides a re-created file, so its own remedy must still be printed.
new_case case9
make_repo "$CASE_DIR/repo"
printf '.envrc\n/.tool-versions\n' > "$CASE_DIR/repo/.gitignore"
run_sut "$CASE_DIR/repo"
check "case 9: exits zero" "$RC" "0"
case "$OUT" in *"(a) present on disk"*) bad "case 9: must not claim the file is on disk" ;;
  *) ok "case 9: does not claim the file is on disk" ;; esac
check "case 9: both leftovers report condition (b)" \
  "$(printf '%s\n' "$OUT" | grep -c '(b) matched by an ignore rule')" "2"

echo "---"
echo "pass=$pass fail=$fail"
if [ "$fail" -eq 0 ]; then
  rm -rf "$SANDBOX"
  echo "All asdf-to-mise tests passed."
  exit 0
fi
echo "Sandbox left at $SANDBOX for inspection."
exit 1
