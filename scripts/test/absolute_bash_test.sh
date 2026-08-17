#!/usr/bin/env bash

# Tests for the "no PATH-resolved bash" invariant (issue #37).
#
# WHY THIS EXISTS. Recipes used to invoke helper scripts as
# `bash scripts/foo.sh` — a bare name resolved through PATH. On a host whose
# PATH puts /opt/homebrew/bin first, the asdf -> mise cutover's slot-04
# RemoveAndPurge uninstalled asdf, `brew uninstall`'s automatic
# `brew autoremove` took Homebrew's `bash` formula with it as an unneeded
# dependency, and every LATER recipe line died with:
#
#   /bin/bash: /opt/homebrew/bin/bash: No such file or directory
#
# The casualty that mattered was `make update`'s ~/.zshrc strip: the run
# removed asdf and direnv but never removed their init lines, so the host
# errored on every shell startup afterwards. A run that deletes the
# interpreter its own later steps need cannot finish.
#
# Two independent defenses, one block each:
#
#   Block 1 (static): every bash invocation in the Makefile names
#   $(BASH_BIN), which is the absolute /bin/bash — the one bash no Homebrew
#   operation can remove. Same check for scripts/shell_setup.sh and
#   scripts/claude_repo_setup.sh, which re-invoke bash to run a helper
#   script. (scripts/ensure_mise_zshrc_lines.sh also re-invokes bash, for its
#   `/bin/bash -lc` reachability probe, and is not scanned here.)
#   The check is self-verifying: it is re-run against a
#   deliberately mutated copy that reintroduces a bare `bash`, and must FIRE
#   there, so a pattern that silently stops matching cannot pass.
#
#   Block 2 (static): scripts/remove_runner.sh — the ONE place both removal
#   trees actually call brew — exports HOMEBREW_NO_AUTOREMOVE=1, so an
#   uninstall never cascades into a shared dependency in the first place.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MAKEFILE="$REPO_ROOT/Makefile"

pass=0
fail=0
ok() {
  # ok <condition-rc> <label>
  if [[ "$1" == "0" ]]; then echo "PASS: $2"; ((pass++)); else echo "FAIL: $2"; ((fail++)); fi
}

# A bash COMMAND invocation: the word `bash` not preceded by a path
# character or word character (so `/bin/bash`, `$(BASH_BIN)` and the word
# "bash" inside a longer identifier do not match), followed by an argument.
# Comment lines are excluded — prose naming the hazard is not the hazard.
BARE_BASH_RE='^[^#]*(^|[^[:alnum:]_./$)-])bash[[:space:]]+[^[:space:]]'

bare_bash_hits() {
  # bare_bash_hits <file> -> prints offending lines (if any)
  grep -nE "$BARE_BASH_RE" "$1" | grep -vE '^[0-9]+:[[:space:]]*#'
}

no_bare_bash() {
  # no_bare_bash <file> <label>
  local hits
  hits="$(bare_bash_hits "$1")"
  if [[ -z "$hits" ]]; then
    echo "PASS: $2"; ((pass++))
  else
    echo "FAIL: $2 -- PATH-resolved bash at:"; echo "$hits"; ((fail++))
  fi
}

# ---------------------------------------------------------------------
# Block 1: no PATH-resolved bash anywhere that runs during make.
# ---------------------------------------------------------------------
absolute_bash_test() {
  ok "$(grep -qE '^BASH_BIN[[:space:]]*:=[[:space:]]*/bin/bash$' "$MAKEFILE" && echo 0 || echo 1)" \
    "Makefile defines BASH_BIN as the absolute /bin/bash"
  ok "$(grep -qE '^SHELL[[:space:]]*:=[[:space:]]*\$\(BASH_BIN\)$' "$MAKEFILE" && echo 0 || echo 1)" \
    "make's own recipe shell is BASH_BIN, so the path is stated once"

  no_bare_bash "$MAKEFILE" "no PATH-resolved bash in the Makefile"
  no_bare_bash "$REPO_ROOT/scripts/shell_setup.sh" \
    "no PATH-resolved bash in shell_setup.sh"
  no_bare_bash "$REPO_ROOT/scripts/claude_repo_setup.sh" \
    "no PATH-resolved bash in claude_repo_setup.sh"

  # Self-verification: the pattern must FIRE on a copy that reintroduces the
  # exact form this test exists to forbid.
  local mutated
  mutated="$(mktemp)"
  sed 's|\$(BASH_BIN) scripts/self_update.sh|bash scripts/self_update.sh|' \
    "$MAKEFILE" > "$mutated"
  ok "$([[ -n "$(bare_bash_hits "$mutated")" ]] && echo 0 || echo 1)" \
    "the bare-bash pattern fires on a mutated Makefile (self-check)"
  rm -f "$mutated"
}

# ---------------------------------------------------------------------
# Block 2: uninstalls do not cascade into shared dependencies.
# ---------------------------------------------------------------------
no_autoremove_test() {
  ok "$(grep -qE '^export HOMEBREW_NO_AUTOREMOVE=1$' "$REPO_ROOT/scripts/remove_runner.sh" \
    && echo 0 || echo 1)" \
    "remove_runner.sh exports HOMEBREW_NO_AUTOREMOVE=1"
}

echo "=== Block 1: no PATH-resolved bash ==="
absolute_bash_test
echo "=== Block 2: no cascading autoremove ==="
no_autoremove_test

echo
echo "---"
echo "pass=$pass fail=$fail"
if [[ $fail -eq 0 ]]; then
  echo "All absolute-bash tests passed."
  exit 0
fi
echo "Some absolute-bash tests FAILED."
exit 1
