#!/usr/bin/env bash
# strip_asdf_zshrc_lines_test.sh — behavioral tests for
# scripts/strip_asdf_zshrc_lines.sh.
#
# The strip exists for exactly one host shape: one that still carries the
# asdf/direnv init lines. That is also the shape that used to break it — the
# patterns contain literal `/`, which is sed's own address delimiter, so the
# sed invocation aborted with "invalid command code o" and, under `set -e`,
# took the caller down with it while leaving the orphan lines in place. Every
# case below therefore runs with orphans actually present.
#
# Run: bash scripts/test/strip_asdf_zshrc_lines_test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SUT="$REPO_ROOT/scripts/strip_asdf_zshrc_lines.sh"

pass=0
fail=0
ok()   { pass=$((pass+1)); printf 'PASS: %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf 'FAIL: %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

SANDBOX="$REPO_ROOT/.claude/tmp/issue-32-zshrc-strip"
rm -rf "$SANDBOX"
mkdir -p "$SANDBOX"

run_sut() { # $1 = zshrc path
  OUT="$(ZSHRC_PATH="$1" bash "$SUT" 2>&1)"
  RC=$?
}

# === case 1: all three orphan lines present ===========================
Z="$SANDBOX/case1-zshrc"
cat > "$Z" <<'EOF'
# leading comment
. /opt/homebrew/opt/asdf/libexec/asdf.sh
export PATH="${ASDF_DATA_DIR:-$HOME/.asdf}/shims:$PATH"
eval "$(direnv hook zsh)"
export PATH="${XDG_DATA_HOME:-$HOME/.local/share}/mise/shims:$PATH"
eval "$(mise activate zsh)"
EOF
run_sut "$Z"
check "case 1: exits zero with orphans present" "$RC" "0"
check "case 1: asdf.sh source line removed" "$(grep -c 'libexec/asdf.sh' "$Z")" "0"
check "case 1: asdf shims PATH line removed" "$(grep -c 'ASDF_DATA_DIR' "$Z")" "0"
check "case 1: direnv hook line removed" "$(grep -c 'direnv hook zsh' "$Z")" "0"
check "case 1: mise shims line kept" "$(grep -c 'mise/shims' "$Z")" "1"
check "case 1: mise activate line kept" "$(grep -c 'mise activate zsh' "$Z")" "1"
check "case 1: unrelated line kept" "$(grep -c 'leading comment' "$Z")" "1"
[ -f "$Z.bak" ] && ok "case 1: wrote a .bak backup" || bad "case 1: wrote a .bak backup"
case "$OUT" in *"Removed orphaned asdf/direnv init lines"*) ok "case 1: reports what it did" ;;
  *) bad "case 1: reports what it did (got: $OUT)" ;; esac

# === case 2: re-run on the cleaned file is a no-op =====================
rm -f "$Z.bak"
BEFORE="$(cat "$Z")"
run_sut "$Z"
check "case 2: re-run exits zero" "$RC" "0"
check "case 2: file unchanged" "$(cat "$Z")" "$BEFORE"
[ ! -f "$Z.bak" ] && ok "case 2: no stray .bak on a no-op run" \
                  || bad "case 2: no stray .bak on a no-op run"

# === case 3: a file that is NOTHING BUT orphan lines ===================
# The degenerate case the `grep -Ev` pipeline form would have failed on
# (empty output => exit 1 => caller aborts under `set -e`).
Z3="$SANDBOX/case3-zshrc"
cat > "$Z3" <<'EOF'
. /opt/homebrew/opt/asdf/libexec/asdf.sh
export PATH="${ASDF_DATA_DIR:-$HOME/.asdf}/shims:$PATH"
eval "$(direnv hook zsh)"
EOF
run_sut "$Z3"
check "case 3: exits zero" "$RC" "0"
check "case 3: file is now empty" "$(wc -l < "$Z3" | tr -d ' ')" "0"

# === case 4: indented / commented variants are preserved ===============
Z4="$SANDBOX/case4-zshrc"
cat > "$Z4" <<'EOF'
    . /opt/homebrew/opt/asdf/libexec/asdf.sh
# eval "$(direnv hook zsh)"
eval "$(direnv hook zsh)"
EOF
run_sut "$Z4"
check "case 4: exits zero" "$RC" "0"
check "case 4: indented variant preserved" "$(grep -c '^    \. ' "$Z4")" "1"
check "case 4: commented variant preserved" "$(grep -c '^# eval' "$Z4")" "1"
check "case 4: active direnv hook removed" "$(grep -c '^eval "\$(direnv hook zsh)"' "$Z4")" "0"

# === case 5: absent ~/.zshrc is a clean no-op ==========================
run_sut "$SANDBOX/does-not-exist"
check "case 5: absent file exits zero" "$RC" "0"
[ ! -f "$SANDBOX/does-not-exist" ] && ok "case 5: created no file" \
                                   || bad "case 5: created no file"

echo "---"
echo "pass=$pass fail=$fail"
if [ "$fail" -eq 0 ]; then
  rm -rf "$SANDBOX"
  echo "All strip_asdf_zshrc_lines tests passed."
  exit 0
fi
echo "Sandbox left at $SANDBOX for inspection."
exit 1
