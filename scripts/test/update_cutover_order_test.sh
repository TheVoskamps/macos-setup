#!/usr/bin/env bash

# Tests for the asdf -> mise cutover as `make update` performs it.
#
# `make update` must do the WHOLE cutover, not two thirds of it: install
# mise, uninstall asdf + direnv, strip the orphaned ~/.zshrc lines. The
# install piece is what carries a host that never ran `make install` --
# `brew upgrade` upgrades an installed formula but never installs an absent
# one, so without an explicit slot-04 Install the removal loops would take
# asdf and direnv out and leave no replacement.
#
# Two invariants, tested in two blocks:
#
#   Block 1 (static): INSTALL BEFORE REMOVE. The slot-04 Install sub-make
#   appears in the `update` recipe ahead of `versions-update` (which needs a
#   mise to drive) and ahead of both removal loops, the removal loops are
#   handed REMOVE_SKIP_BASENAMES, and the ~/.zshrc strip is guarded on the
#   same skip decision.
#
#   Block 2 (behavioral): the batch removal loops honor
#   REMOVE_SKIP_BASENAMES -- the named slot is skipped at every tier while
#   every other slot still applies, and an unset variable leaves the loops
#   exactly as they were.
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

  # The recipe names the install target through $(call CANON,$(VM_INSTALL)),
  # so the needle is that unexpanded form; the two greps below pin the
  # expansion (VM_INSTALL's value, and the target that value canonicalizes
  # to) so a rename cannot leave this recipe calling a target that is gone.
  local vm_install='$(call CANON,$(VM_INSTALL))'
  ok_contains "$recipe" "$vm_install" \
    "update applies the slot-04 Install"
  ok "$(grep -q '^VM_INSTALL *:= *04-Install\.versionmanagers$' "$MAKEFILE" && echo 0 || echo 1)" \
    "VM_INSTALL names the version-manager Install slot"
  ok "$(grep -q '^04_Install_versionmanagers:' "$MAKEFILE" && echo 0 || echo 1)" \
    "the canonicalized slot-04 Install target exists"
  ok_contains "$recipe" 'strip_asdf_zshrc_lines.sh' \
    "update strips the orphaned ~/.zshrc lines"

  # Install before the mise-driven update, and before both removal loops.
  ok_before "$recipe" "$vm_install" 'versions-update' \
    "slot-04 Install precedes versions-update"
  ok_before "$recipe" "$vm_install" '-s uninstall' \
    "slot-04 Install precedes the Uninstall loop"
  ok_before "$recipe" "$vm_install" '-s remove-and-purge' \
    "slot-04 Install precedes the RemoveAndPurge loop"
  ok_before "$recipe" "$vm_install" 'strip_asdf_zshrc_lines.sh' \
    "slot-04 Install precedes the ~/.zshrc strip"

  # The removal loops are handed the skip list, and the strip is guarded on
  # the same decision, so a missing mise holds back all three.
  ok_contains "$recipe" '-s uninstall REMOVE_SKIP_BASENAMES=' \
    "Uninstall loop is handed REMOVE_SKIP_BASENAMES"
  ok_contains "$recipe" '-s remove-and-purge REMOVE_SKIP_BASENAMES=' \
    "RemoveAndPurge loop is handed REMOVE_SKIP_BASENAMES"
  ok_contains "$recipe" 'if [ -z "$$VM_SKIP" ]; then bash scripts/strip_asdf_zshrc_lines.sh' \
    "the ~/.zshrc strip is guarded on the same skip decision"

  # The skip list names slot 04 only.
  ok_contains "$recipe" 'VM_SKIP="$(VM_UNINSTALL) $(VM_PURGE)"' \
    "the skip list is the slot-04 removal slots"
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
# loops invoke, with two active slots: the version-manager slot (the one
# `update` holds back) and an unrelated slot (which must never be held
# back). The host tier is pointed at an empty temp dir by run_make.
make_repo() {
  local root; root="$(mktemp -d)"
  mkdir -p "$root/scripts" "$root/Install" "$root/Uninstall" "$root/RemoveAndPurge"
  cp "$MAKEFILE" "$root/Makefile"
  cp "$REPO_ROOT/scripts/remove_runner.sh" \
     "$REPO_ROOT/scripts/config_common.sh" \
     "$REPO_ROOT/scripts/list_profiles.sh" \
     "$REPO_ROOT/scripts/host_tier_dir.sh" \
     "$REPO_ROOT/scripts/seed_host_tier.sh" \
     "$REPO_ROOT/scripts/install_filter.sh" \
     "$root/scripts/"
  printf "# header\nbrew 'asdf'\n"       > "$root/Uninstall/04-Uninstall.versionmanagers"
  printf "# header\nbrew 'ripgrep'\n"    > "$root/Uninstall/05-Uninstall.tools"
  printf "# header\nbrew 'asdf'\n"       > "$root/RemoveAndPurge/04-RemoveAndPurge.versionmanagers"
  printf "# header\nbrew 'ripgrep'\n"    > "$root/RemoveAndPurge/05-RemoveAndPurge.tools"
  echo "$root"
}

run_make() {
  # run_make <target> <skip-value> -> sets RUN_OUT / RUN_RC
  local target="$1" skip="$2"
  local root host_dir brew_stub
  root="$(make_repo)"
  host_dir="$(mktemp -d)"
  mkdir -p "$root/bin"
  brew_stub="$root/bin/brew"
  write_stub_brew "$brew_stub"
  RUN_OUT="$(cd "$root" && PATH="$root/bin:$PATH" MACOS_SETUP_HOST_DIR="$host_dir" \
    make "$target" BREW="$brew_stub" REMOVE_SKIP_BASENAMES="$skip" 2>&1)"; RUN_RC=$?
  rm -rf "$root" "$host_dir"
}

VM_BANNER_U="==> Applying global Uninstall: Uninstall/04-Uninstall.versionmanagers"
TOOLS_BANNER_U="==> Applying global Uninstall: Uninstall/05-Uninstall.tools"
VM_BANNER_P="==> Applying global RemoveAndPurge: RemoveAndPurge/04-RemoveAndPurge.versionmanagers"
TOOLS_BANNER_P="==> Applying global RemoveAndPurge: RemoveAndPurge/05-RemoveAndPurge.tools"

skip_test() {
  # Unset (empty) -> both slots apply, exactly as before this knob existed.
  run_make "uninstall" ""
  ok "$RUN_RC" "make uninstall with an empty skip list exits 0"
  ok_contains "$RUN_OUT" "$VM_BANNER_U"    "empty skip list: slot 04 Uninstall applies"
  ok_contains "$RUN_OUT" "$TOOLS_BANNER_U" "empty skip list: slot 05 Uninstall applies"

  run_make "remove-and-purge" ""
  ok "$RUN_RC" "make remove-and-purge with an empty skip list exits 0"
  ok_contains "$RUN_OUT" "$VM_BANNER_P"    "empty skip list: slot 04 RemoveAndPurge applies"
  ok_contains "$RUN_OUT" "$TOOLS_BANNER_P" "empty skip list: slot 05 RemoveAndPurge applies"

  # Slot 04 named -> slot 04 skipped, slot 05 untouched.
  run_make "uninstall" "04-Uninstall.versionmanagers 04-RemoveAndPurge.versionmanagers"
  ok "$RUN_RC" "make uninstall with slot 04 skipped exits 0"
  ok_absent   "$RUN_OUT" "$VM_BANNER_U"    "skip list: slot 04 Uninstall is held back"
  ok_contains "$RUN_OUT" "$TOOLS_BANNER_U" "skip list: slot 05 Uninstall still applies"

  run_make "remove-and-purge" "04-Uninstall.versionmanagers 04-RemoveAndPurge.versionmanagers"
  ok "$RUN_RC" "make remove-and-purge with slot 04 skipped exits 0"
  ok_absent   "$RUN_OUT" "$VM_BANNER_P"    "skip list: slot 04 RemoveAndPurge is held back"
  ok_contains "$RUN_OUT" "$TOOLS_BANNER_P" "skip list: slot 05 RemoveAndPurge still applies"

  # The dry-run companions honor it too.
  run_make "remove-and-purge-dry-run" "04-RemoveAndPurge.versionmanagers"
  ok "$RUN_RC" "make remove-and-purge-dry-run with slot 04 skipped exits 0"
  ok_absent   "$RUN_OUT" "$VM_BANNER_P"    "dry-run: slot 04 RemoveAndPurge is held back"
  ok_contains "$RUN_OUT" "$TOOLS_BANNER_P" "dry-run: slot 05 RemoveAndPurge still applies"
}

echo "=== Block 1: update recipe ordering ==="
order_test
echo "=== Block 2: REMOVE_SKIP_BASENAMES in the removal loops ==="
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
