#!/usr/bin/env bash
# ensure_mise_zshrc_lines_test.sh — tests for the ADD half of the asdf -> mise
# cutover's ~/.zshrc work (issue #38).
#
# The bug this pins: `make update` stripped the asdf/direnv init lines but
# never added the mise ones, because only shell_setup.sh wrote them and
# `update` deliberately never runs shell_setup.sh. A host that went through
# the cutover purely via `make update` ended with mise installed, the old
# version manager gone, and no version manager wired into the interactive
# shell — observed on a real host, whose ~/.zshrc had zero `mise` lines until
# a manual `make shell_setup`.
#
# Block 1 (behavioral): the script itself — writes both lines, is idempotent,
# and holds the activation line back when mise is unreachable.
#
# Block 2 (static): BOTH writers reach it. `update`'s recipe calls it, under
# the same `VM_SKIP` guard as the strip and after it; shell_setup.sh calls it
# instead of inlining the lines, so the two paths cannot drift.
#
# Run: /bin/bash scripts/test/ensure_mise_zshrc_lines_test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SUT="$REPO_ROOT/scripts/ensure_mise_zshrc_lines.sh"
MAKEFILE="$REPO_ROOT/Makefile"

pass=0
fail=0
ok()   { pass=$((pass+1)); printf 'PASS: %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf 'FAIL: %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

SANDBOX="$REPO_ROOT/.claude/tmp/issue-38-mise-activation"
rm -rf "$SANDBOX"
mkdir -p "$SANDBOX"

SHIMS_LINE='mise/shims:$PATH'
ACTIVATE_LINE='eval "$(mise activate zsh)"'

# A stub that makes `command -v "$MISE"` succeed without a real mise.
MISE_STUB="$SANDBOX/mise"
printf '#!/bin/bash\nexit 0\n' > "$MISE_STUB"
chmod +x "$MISE_STUB"

run_sut() { # $1 = zshrc path, $2 = MISE value
  OUT="$(ZSHRC_PATH="$1" MISE="$2" /bin/bash "$SUT" 2>&1)"
  RC=$?
}

echo "=== Block 1: the script ==="

# === case 1: fresh ~/.zshrc, mise reachable ===========================
Z="$SANDBOX/case1-zshrc"
: > "$Z"
run_sut "$Z" "$MISE_STUB"
check "case 1: exits zero" "$RC" "0"
check "case 1: shims PATH export added" "$(grep -cF "$SHIMS_LINE" "$Z")" "1"
check "case 1: activation line added"   "$(grep -cFx "$ACTIVATE_LINE" "$Z")" "1"

# === case 2: re-run is a no-op (idempotent) ============================
BEFORE="$(cat "$Z")"
run_sut "$Z" "$MISE_STUB"
check "case 2: exits zero" "$RC" "0"
check "case 2: file unchanged" "$(cat "$Z")" "$BEFORE"
check "case 2: no duplicate shims line" "$(grep -cF "$SHIMS_LINE" "$Z")" "1"
check "case 2: no duplicate activation line" "$(grep -cFx "$ACTIVATE_LINE" "$Z")" "1"

# === case 3: mise unreachable -> shims yes, activation no ==============
Z3="$SANDBOX/case3-zshrc"
: > "$Z3"
run_sut "$Z3" "$SANDBOX/definitely-not-a-real-mise"
check "case 3: exits zero" "$RC" "0"
check "case 3: shims PATH export still added" "$(grep -cF "$SHIMS_LINE" "$Z3")" "1"
check "case 3: activation line held back" "$(grep -cFx "$ACTIVATE_LINE" "$Z3")" "0"
case "$OUT" in *"mise not yet installed"*) ok "case 3: says why" ;;
  *) bad "case 3: says why (got: $OUT)" ;; esac

# === case 4: an absent ~/.zshrc is created, not errored on =============
Z4="$SANDBOX/case4-does-not-exist-yet"
run_sut "$Z4" "$MISE_STUB"
check "case 4: exits zero" "$RC" "0"
[ -f "$Z4" ] && ok "case 4: created the file" || bad "case 4: created the file"
check "case 4: shims PATH export added" "$(grep -cF "$SHIMS_LINE" "$Z4")" "1"

# === case 5: existing content is preserved =============================
Z5="$SANDBOX/case5-zshrc"
printf '# my own line\nexport FOO=1\n' > "$Z5"
run_sut "$Z5" "$MISE_STUB"
check "case 5: existing comment kept" "$(grep -c 'my own line' "$Z5")" "1"
check "case 5: existing export kept"  "$(grep -c 'export FOO=1' "$Z5")" "1"
check "case 5: shims PATH export added" "$(grep -cF "$SHIMS_LINE" "$Z5")" "1"

# === case 6: a bare-name mise on this shell's PATH is reachable =========
# The fast path of the two-step gate: no login shell needed when make's own
# PATH already has it.
Z6="$SANDBOX/case6-zshrc"
: > "$Z6"
OUT="$(ZSHRC_PATH="$Z6" MISE="mise" PATH="$SANDBOX:$PATH" /bin/bash "$SUT" 2>&1)"; RC=$?
check "case 6: exits zero" "$RC" "0"
check "case 6: activation line added" "$(grep -cFx "$ACTIVATE_LINE" "$Z6")" "1"

# === case 7: the gate matches the Makefile's MISE_REACHABLE probe ========
# `update` decides to remove asdf and direnv with MISE_REACHABLE, which runs
# under a LOGIN shell because a mise installed moments earlier in the same run
# lands on a login shell's PATH, not necessarily on make's. If this script
# checked only make's PATH the two gates could disagree within one run — the
# removal happens, the activation line is withheld. So the script must fall
# back to the same login-shell probe.
if grep -qE '/bin/bash -lc .*command -v' "$SUT"; then
  ok "case 7: the gate falls back to a login-shell probe"
else
  bad "case 7: the gate falls back to a login-shell probe"
fi
if grep -qE '^MISE_REACHABLE = .*-lc' "$MAKEFILE"; then
  ok "case 7: MISE_REACHABLE still probes under a login shell"
else
  bad "case 7: MISE_REACHABLE still probes under a login shell"
fi

echo "=== Block 2: both writers reach it ==="

update_recipe() {
  awk '
    /^update:/ { inr = 1; next }
    inr && /^\t/ { print; next }
    inr { exit }
  ' "$MAKEFILE"
}
RECIPE="$(update_recipe)"

if grep -qF 'ensure_mise_zshrc_lines.sh' <<<"$RECIPE"; then
  ok "update adds the mise activation lines"
else
  bad "update adds the mise activation lines"
fi

# Guarded on the same VM_SKIP decision as the strip: a run that held the
# asdf/direnv removal back must not point ~/.zshrc at a mise that is absent.
GUARD_LINE="$(grep -nF 'VM_SKIP' <<<"$RECIPE" | grep -F 'if [ -z' | head -1 | cut -d: -f1)"
STRIP_LINE="$(grep -nF 'strip_asdf_zshrc_lines.sh' <<<"$RECIPE" | head -1 | cut -d: -f1)"
ENSURE_LINE="$(grep -nF 'ensure_mise_zshrc_lines.sh' <<<"$RECIPE" | head -1 | cut -d: -f1)"
FI_LINE="$(awk 'NR>'"${GUARD_LINE:-0}"' && /^\t*fi; \\$/ { print NR; exit }' <<<"$RECIPE")"

if [ -n "$GUARD_LINE" ] && [ -n "$ENSURE_LINE" ] && [ -n "$FI_LINE" ] \
  && [ "$GUARD_LINE" -lt "$ENSURE_LINE" ] && [ "$ENSURE_LINE" -lt "$FI_LINE" ]; then
  ok "the mise-lines call sits inside the VM_SKIP guard"
else
  bad "the mise-lines call sits inside the VM_SKIP guard (guard@${GUARD_LINE:-none} ensure@${ENSURE_LINE:-none} fi@${FI_LINE:-none})"
fi

if [ -n "$STRIP_LINE" ] && [ -n "$ENSURE_LINE" ] && [ "$STRIP_LINE" -lt "$ENSURE_LINE" ]; then
  ok "the strip runs before the add"
else
  bad "the strip runs before the add (strip@${STRIP_LINE:-none} ensure@${ENSURE_LINE:-none})"
fi

# shell_setup.sh delegates rather than inlining, so the two paths agree.
SHELL_SETUP="$REPO_ROOT/scripts/shell_setup.sh"
if grep -qF 'ensure_mise_zshrc_lines.sh' "$SHELL_SETUP"; then
  ok "shell_setup.sh calls the shared script"
else
  bad "shell_setup.sh calls the shared script"
fi
if grep -qF 'mise activate zsh' "$SHELL_SETUP"; then
  bad "shell_setup.sh no longer inlines the activation line"
else
  ok "shell_setup.sh no longer inlines the activation line"
fi

rm -rf "$SANDBOX"

echo
echo "---"
echo "pass=$pass fail=$fail"
if [ "$fail" -eq 0 ]; then
  echo "All ensure-mise-zshrc-lines tests passed."
  exit 0
fi
echo "Some ensure-mise-zshrc-lines tests FAILED."
exit 1
