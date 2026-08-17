#!/usr/bin/env bash

# Tests for the asdf -> mise cutover as `make update` performs it.
#
# `make update` must do the WHOLE cutover, not two thirds of it: install
# mise, uninstall asdf + direnv, strip the orphaned ~/.zshrc lines. The
# install piece is what carries a host that never ran `make install` --
# `brew upgrade` upgrades an installed formula but never installs an absent
# one, so without explicitly applying the version-managers tier the removal
# loops would take asdf and direnv out and leave no replacement.
#
# Two invariants, tested in two blocks:
#
#   Block 1 (static): INSTALL BEFORE REMOVE. The version-managers tier
#   apply appears in the `update` recipe ahead of `versions-update` (which
#   needs a mise to drive) and ahead of both removal loops, the removal
#   loops are handed REMOVE_SKIP_TIERS, and the ~/.zshrc strip is guarded
#   on the same skip decision.
#
#   Block 2 (behavioral): the batch removal loops honor REMOVE_SKIP_TIERS
#   -- the named tier is skipped while every other tier still applies, and
#   an unset variable leaves the loops exactly as they were.
#
# Block 1 reads the recipe text out of the Makefile rather than running
# `make -n update` ON PURPOSE. GNU make executes a recipe line containing
# $(MAKE) even under -n (it only propagates -n to the sub-make), and the
# whole `update` recipe is one such line -- so `make -n update` really runs
# `brew update`, `brew upgrade`, `mas upgrade` and the ~/.zshrc strip on the
# host. A static read of the recipe is the only side-effect-free way to
# assert its ordering.

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
ok_contains() {
  # ok_contains <haystack> <needle> <label>
  if grep -qF -- "$2" <<<"$1"; then echo "PASS: $3"; ((pass++)); else echo "FAIL: $3 -- output missing [$2]"; ((fail++)); fi
}
ok_absent() {
  # ok_absent <haystack> <needle> <label>
  if grep -qF -- "$2" <<<"$1"; then echo "FAIL: $3 -- output unexpectedly contains [$2]"; ((fail++)); else echo "PASS: $3"; ((pass++)); fi
}
ok_before() {
  # ok_before <text> <needle-a> <needle-b> <label>: a must appear before b
  local a b
  a="$(grep -nF -- "$2" <<<"$1" | head -1 | cut -d: -f1)"
  b="$(grep -nF -- "$3" <<<"$1" | head -1 | cut -d: -f1)"
  if [[ -n "$a" && -n "$b" && "$a" -lt "$b" ]]; then
    echo "PASS: $4"; ((pass++))
  else
    echo "FAIL: $4 -- [$2]@${a:-none} is not before [$3]@${b:-none}"; ((fail++))
  fi
}

# ---------------------------------------------------------------------
# Block 1: the `update` recipe, read statically.
# ---------------------------------------------------------------------
update_recipe() {
  # Print the recipe body of the `update:` target (the tab-indented lines
  # following it), stopping at the first line that is not part of it.
  awk '
    /^update:/ { inr = 1; next }
    inr && /^\t/ { print; next }
    inr { exit }
  ' "$MAKEFILE"
}

order_test() {
  local recipe
  recipe="$(update_recipe)"

  ok "$([[ -n "$recipe" ]] && echo 0 || echo 1)" "update recipe is non-empty"

  # The recipe applies the version-managers TIER through
  # `$(APPLY_TIER) "$(VM_TIER)"`, so the needle is that unexpanded form;
  # the greps below pin the expansion so a rename cannot leave this recipe
  # pointing at a tier that is gone.
  local vm_apply='$(APPLY_TIER) "$(VM_TIER)"'
  ok_contains "$recipe" "$vm_apply" \
    "update applies the version-managers tier"
  ok "$(grep -q '^VM_PROFILE  *:= *version-managers$' "$MAKEFILE" && echo 0 || echo 1)" \
    "VM_PROFILE names the version-managers profile"
  ok "$(grep -q '^VM_TIER  *:= *profiles/\$(VM_PROFILE)$' "$MAKEFILE" && echo 0 || echo 1)" \
    "VM_TIER derives the tier root from VM_PROFILE"
  ok "$(grep -q '^APPLY_TIER  *:= *scripts/apply_tier\.sh$' "$MAKEFILE" && echo 0 || echo 1)" \
    "APPLY_TIER names the tier-apply script"
  ok_contains "$recipe" 'strip_asdf_zshrc_lines.sh' \
    "update strips the orphaned ~/.zshrc lines"

  # Install before the mise-driven update, and before both removal loops.
  ok_before "$recipe" "$vm_apply" 'versions-update' \
    "the version-managers tier precedes versions-update"
  ok_before "$recipe" "$vm_apply" '-s uninstall' \
    "the version-managers tier precedes the uninstall loop"
  ok_before "$recipe" "$vm_apply" '-s remove-and-purge' \
    "the version-managers tier precedes the purge loop"
  ok_before "$recipe" "$vm_apply" 'strip_asdf_zshrc_lines.sh' \
    "the version-managers tier precedes the ~/.zshrc strip"

  # The removal loops are handed the skip list, and the strip is guarded on
  # the same decision, so a missing mise holds back all three.
  ok_contains "$recipe" '-s uninstall REMOVE_SKIP_TIERS=' \
    "uninstall loop is handed REMOVE_SKIP_TIERS"
  ok_contains "$recipe" '-s remove-and-purge REMOVE_SKIP_TIERS=' \
    "purge loop is handed REMOVE_SKIP_TIERS"
  # The guard opens a block carrying BOTH ~/.zshrc rewrites -- the strip and
  # the mise-lines add (issue #38) -- so a held-back cutover performs neither.
  # scripts/test/ensure_mise_zshrc_lines_test.sh pins the containment; here we
  # pin that the guard is still the same VM_SKIP decision and still precedes
  # the strip.
  ok_contains "$recipe" 'if [ -z "$$VM_SKIP" ]; then' \
    "the ~/.zshrc rewrites are guarded on the same skip decision"
  ok_before "$recipe" 'if [ -z "$$VM_SKIP" ]; then' 'strip_asdf_zshrc_lines.sh' \
    "the guard precedes the ~/.zshrc strip"
  ok_contains "$recipe" '$(BASH_BIN) scripts/strip_asdf_zshrc_lines.sh' \
    "the strip is invoked through the absolute bash"

  # The skip list names the version-managers tier only.
  ok_contains "$recipe" 'VM_SKIP="$(VM_TIER)"' \
    "the skip list is the version-managers tier"
}

# ---------------------------------------------------------------------
# Block 2: REMOVE_SKIP_BASENAMES in the real removal loops.
# ---------------------------------------------------------------------

# A stub `brew` that reports nothing installed, so the runner only ever
# emits `skip: <pkg> not installed` and never uninstalls anything.
#
# It is passed as the BREW make variable AND shimmed onto PATH as `brew`.
# The BREW variable is what scripts/remove_runner.sh now honors (GNU make
# exports command-line variables into every recipe's environment, and the
# runner resolves `BREW="${BREW:-brew}"` -- see
# scripts/test/remove_runner_brew_override_test.sh, which fails if a bare
# `brew` call is reintroduced there). The PATH shim is kept as defence in
# depth: these fixtures name the host's REAL asdf and direnv, a `make`
# run reaches more scripts than the runner alone, and the cost of one
# extra stub is nothing against the cost of being wrong -- an earlier
# round of this test really did uninstall a host formula.
write_stub_brew() {
  cat > "$1" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$1"
}

# Synthetic repo carrying the real Makefile plus the scripts its removal
# loops invoke, with two tiers that remove something: the version-managers
# profile (the one `update` holds back) and an unrelated profile (which
# must never be held back).
make_repo() {
  local root; root="$(mktemp -d)"
  mkdir -p "$root/scripts" "$root/default" \
           "$root/profiles/version-managers" "$root/profiles/tools"
  cp "$MAKEFILE" "$root/Makefile"
  cp "$REPO_ROOT/scripts/remove_runner.sh" \
     "$REPO_ROOT/scripts/config_common.sh" \
     "$REPO_ROOT/scripts/apply_tier.sh" \
     "$REPO_ROOT/scripts/list_profiles.sh" \
     "$REPO_ROOT/scripts/host_tier_dir.sh" \
     "$REPO_ROOT/scripts/seed_host_tier.sh" \
     "$REPO_ROOT/scripts/install_filter.sh" \
     "$root/scripts/"
  printf '[profile]\nuninstall = ["brew:asdf"]\npurge = ["brew:asdf"]\n' \
    > "$root/profiles/version-managers/config.toml"
  printf '[profile]\nuninstall = ["brew:ripgrep"]\npurge = ["brew:ripgrep"]\n' \
    > "$root/profiles/tools/config.toml"
  echo "$root"
}

run_make() {
  # run_make <target> <skip-value> -> sets RUN_OUT / RUN_RC
  local target="$1" skip="$2"
  local root host_dir brew_stub
  root="$(make_repo)"
  host_dir="$(mktemp -d)"
  # The host opts into both profiles, so both tiers are in the removal
  # loops' walk and the skip list has something to hold back.
  printf 'profiles = ["version-managers", "tools"]\n' > "$host_dir/config.toml"
  mkdir -p "$root/bin"
  brew_stub="$root/bin/brew"
  write_stub_brew "$brew_stub"
  RUN_OUT="$(cd "$root" && PATH="$root/bin:$PATH" MACOS_SETUP_HOST_DIR="$host_dir" \
    make "$target" BREW="$brew_stub" REMOVE_SKIP_TIERS="$skip" 2>&1)"; RUN_RC=$?
  rm -rf "$root" "$host_dir"
}

VM_BANNER_U="==> Applying Uninstall: profiles/version-managers"
TOOLS_BANNER_U="==> Applying Uninstall: profiles/tools"
VM_BANNER_P="==> Applying RemoveAndPurge: profiles/version-managers"
TOOLS_BANNER_P="==> Applying RemoveAndPurge: profiles/tools"

skip_test() {
  # Unset (empty) -> both tiers apply, exactly as before this knob existed.
  run_make "uninstall" ""
  ok "$RUN_RC" "make uninstall with an empty skip list exits 0"
  ok_contains "$RUN_OUT" "$VM_BANNER_U"    "empty skip list: version-managers uninstall applies"
  ok_contains "$RUN_OUT" "$TOOLS_BANNER_U" "empty skip list: tools uninstall applies"

  run_make "remove-and-purge" ""
  ok "$RUN_RC" "make remove-and-purge with an empty skip list exits 0"
  ok_contains "$RUN_OUT" "$VM_BANNER_P"    "empty skip list: version-managers purge applies"
  ok_contains "$RUN_OUT" "$TOOLS_BANNER_P" "empty skip list: tools purge applies"

  # version-managers named -> that tier skipped, the other untouched.
  run_make "uninstall" "profiles/version-managers"
  ok "$RUN_RC" "make uninstall with version-managers skipped exits 0"
  ok_absent   "$RUN_OUT" "$VM_BANNER_U"    "skip list: version-managers uninstall is held back"
  ok_contains "$RUN_OUT" "$TOOLS_BANNER_U" "skip list: tools uninstall still applies"

  run_make "remove-and-purge" "profiles/version-managers"
  ok "$RUN_RC" "make remove-and-purge with version-managers skipped exits 0"
  ok_absent   "$RUN_OUT" "$VM_BANNER_P"    "skip list: version-managers purge is held back"
  ok_contains "$RUN_OUT" "$TOOLS_BANNER_P" "skip list: tools purge still applies"

  # The dry-run companions honor it too.
  run_make "remove-and-purge-dry-run" "profiles/version-managers"
  ok "$RUN_RC" "make remove-and-purge-dry-run with version-managers skipped exits 0"
  ok_absent   "$RUN_OUT" "$VM_BANNER_P"    "dry-run: version-managers purge is held back"
  ok_contains "$RUN_OUT" "$TOOLS_BANNER_P" "dry-run: tools purge still applies"
}

echo "=== Block 1: update recipe ordering ==="
order_test
echo "=== Block 2: REMOVE_SKIP_TIERS in the removal loops ==="
skip_test

echo
echo "---"
echo "pass=$pass fail=$fail"
if [[ $fail -eq 0 ]]; then
  echo "All update-cutover tests passed."
  exit 0
fi
echo "Some update-cutover tests FAILED."
exit 1
