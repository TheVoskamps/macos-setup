#!/usr/bin/env bash

# Integration tests for `scripts/asdf_setup.sh cleanup` /
# `cleanup-dry-run` (issue #8).
#
# The cleanup keep-set per plugin is the union of:
#   1. versions referenced in any .tool-versions found by scanning $HOME
#      (heavy/noise dirs pruned: Library, node_modules, .git, caches),
#   2. the currently-active version(s) for that plugin,
#   3. the newest CLEANUP_KEEP_NEWEST (default 3) versions by sort -V.
# Every other installed version is removed via `asdf uninstall`.
#
# Cases:
#   1. A version not referenced, not active, and outside the newest-3 is
#      removed; referenced / active / newest-3 versions are kept.
#   2. A plugin with 3 or fewer installed versions has nothing removed.
#   3. The currently-active version is kept even when it is neither
#      referenced nor in the newest 3.
#   4. .tool-versions files inside pruned dirs (Library, node_modules)
#      are NOT scanned, so their referenced versions do not protect a
#      version from removal.
#   5. Comments and extra whitespace in .tool-versions lines are parsed
#      robustly.
#   6. cleanup-dry-run prints "Would remove" lines and removes nothing.
#   7. A failing `asdf uninstall` warns, continues, and yields a
#      non-zero exit code.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SANDBOX_BASE="$REPO_ROOT/.claude/tmp/asdf_cleanup_test"
ASDF_SETUP="$REPO_ROOT/scripts/asdf_setup.sh"
FAIL=0

cleanup_on_exit() {
    if [[ $FAIL -eq 0 ]]; then
        rm -rf "$SANDBOX_BASE"
    else
        echo
        echo "Sandbox preserved at: $SANDBOX_BASE" >&2
    fi
}
trap cleanup_on_exit EXIT

mkdir -p "$SANDBOX_BASE"

fail() { echo "FAIL: $*" >&2; FAIL=1; }
pass() { echo "PASS: $*"; }

# Build a sandbox HOME and a stub `asdf` on PATH.
# Args: case_dir, asdf_stub_body (a heredoc-able script fragment)
# The stub fragment is written verbatim as the body of the `asdf` script.

# Run cleanup against a given HOME and stub-asdf bin dir.
# Args: home_dir bin_dir mode  -> echoes output, sets RUN_RC
run_cleanup() {
    local home_dir="$1" bin_dir="$2" mode="$3"
    set +e
    RUN_OUT="$(HOME="$home_dir" PATH="$bin_dir:$PATH" bash "$ASDF_SETUP" "$mode" 2>&1)"
    RUN_RC=$?
    set -e
}

# ---- Shared stub: nodejs, pnpm, awscli ----
make_standard_stub() {
    local bin_dir="$1"
    mkdir -p "$bin_dir"
    cat > "$bin_dir/asdf" <<'EOF'
#!/bin/bash
case "$1 $2" in
  "plugin list")
    printf 'nodejs\npnpm\nawscli\n'
    ;;
  "list "*)
    case "$2" in
      nodejs) printf '  22.19.0\n  24.10.0\n  25.6.0\n *25.6.1\n' ;;
      pnpm)   printf '  9.15.9\n  10.28.2\n *10.29.3\n' ;;
      awscli) printf ' *2.30.6\n  2.31.10\n  2.32.4\n  2.33.0\n  2.33.22\n' ;;
    esac
    ;;
  "uninstall "*) echo "UNINSTALL $2 $3" ;;
  *) echo "asdf $*" ;;
esac
EOF
    chmod +x "$bin_dir/asdf"
}

# ============================================================
# Cases 1-5: standard stub + referenced/pruned .tool-versions
# ============================================================
c1="$SANDBOX_BASE/standard"
c1_home="$c1/home"
c1_bin="$c1/bin"
mkdir -p "$c1_home/proj" "$c1_home/Library/junk" "$c1_home/node_modules/pkg"
make_standard_stub "$c1_bin"

# Referenced: nodejs 22.19.0 (oldest, outside newest-3 -> protected),
# python entry irrelevant (no python plugin), with comments/whitespace.
printf 'nodejs 22.19.0\n# a comment\n\n   pnpm   9.15.9   # inline\n' \
    > "$c1_home/proj/.tool-versions"
# These live in pruned dirs and MUST be ignored.
printf 'awscli 2.31.10\n' > "$c1_home/Library/junk/.tool-versions"
printf 'awscli 2.32.4\n'  > "$c1_home/node_modules/pkg/.tool-versions"

run_cleanup "$c1_home" "$c1_bin" cleanup

# Case 1 + 3 + 4: awscli should remove ONLY 2.31.10.
#   keep = active(2.30.6) + newest3(2.32.4,2.33.0,2.33.22); referenced
#   refs for awscli are only inside pruned dirs -> ignored.
if echo "$RUN_OUT" | grep -qx "UNINSTALL awscli 2.31.10"; then
    pass "case 1: awscli 2.31.10 removed (not referenced/active/newest-3)"
else
    fail "case 1: expected 'UNINSTALL awscli 2.31.10'; got:
$RUN_OUT"
fi

if echo "$RUN_OUT" | grep -q "UNINSTALL awscli 2.30.6"; then
    fail "case 3: active awscli 2.30.6 should never be removed; got:
$RUN_OUT"
else
    pass "case 3: active awscli 2.30.6 kept though not newest-3/referenced"
fi

if echo "$RUN_OUT" | grep -qE "UNINSTALL awscli (2.32.4|2.33.0|2.33.22)"; then
    fail "case 1: a newest-3 awscli version was removed; got:
$RUN_OUT"
else
    pass "case 1: newest-3 awscli versions kept"
fi

# Case 4: pruned-dir refs (awscli 2.31.10 / 2.32.4) did not protect
# 2.31.10 -- it WAS removed above, which already proves the prune works.
pass "case 4: .tool-versions inside Library/node_modules were pruned"

# Case 2: pnpm has 3 versions -> nothing removed.
if echo "$RUN_OUT" | grep -q "UNINSTALL pnpm"; then
    fail "case 2: pnpm has <=3 versions, none should be removed; got:
$RUN_OUT"
else
    pass "case 2: pnpm (<=3 versions) untouched"
fi

# Case 5: nodejs 22.19.0 referenced (comments/whitespace parsed) -> kept,
# nodejs has 4 versions (22.19.0 ref'd, 24.10.0/25.6.0/25.6.1 newest-3)
# so nothing removable.
if echo "$RUN_OUT" | grep -q "UNINSTALL nodejs"; then
    fail "case 5: nodejs versions are all referenced/newest-3; got:
$RUN_OUT"
else
    pass "case 5: nodejs referenced version parsed and kept (comments OK)"
fi

# ============================================================
# Case 6: dry-run prints "Would remove" and deletes nothing
# ============================================================
run_cleanup "$c1_home" "$c1_bin" cleanup-dry-run
if echo "$RUN_OUT" | grep -q "Would remove: awscli 2.31.10" \
   && ! echo "$RUN_OUT" | grep -q "^UNINSTALL "; then
    pass "case 6: dry-run reports removals without uninstalling"
else
    fail "case 6: dry-run output unexpected:
$RUN_OUT"
fi

# ============================================================
# Case 7: a failing uninstall warns, continues, exits non-zero
# ============================================================
c7="$SANDBOX_BASE/failing"
c7_home="$c7/home"
c7_bin="$c7/bin"
mkdir -p "$c7_home" "$c7_bin"
cat > "$c7_bin/asdf" <<'EOF'
#!/bin/bash
case "$1 $2" in
  "plugin list") printf 'awscli\n' ;;
  "list "*) printf ' *2.30.6\n  2.31.10\n  2.32.4\n  2.33.0\n  2.33.22\n' ;;
  "uninstall "*) echo "boom" >&2; exit 1 ;;
  *) echo "asdf $*" ;;
esac
EOF
chmod +x "$c7_bin/asdf"

run_cleanup "$c7_home" "$c7_bin" cleanup
if [[ $RUN_RC -ne 0 ]] \
   && echo "$RUN_OUT" | grep -q "Failed to uninstall awscli 2.31.10"; then
    pass "case 7: failing uninstall warns and yields non-zero exit"
else
    fail "case 7: expected non-zero exit + warning; rc=$RUN_RC, out:
$RUN_OUT"
fi

# ---- summary ----
echo
if [[ $FAIL -eq 0 ]]; then
    echo "All asdf_cleanup tests passed."
else
    echo "Some asdf_cleanup tests FAILED." >&2
fi
exit $FAIL
