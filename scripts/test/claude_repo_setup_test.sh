#!/usr/bin/env bash

# Integration tests for `scripts/claude_repo_setup.sh`.
#
# Cases exercised:
#
#   1. Fresh clone (no $CLAUDE_DIR): clone + checkout configured branch.
#   2. Existing clone, same branch: re-run is a no-op pull.
#   3. Existing clone, switch branch: change config, re-run switches.
#   4. Existing clone, dirty working tree: edits survive a re-run via
#      stash/pop.
#   5. Mixed-content migration: a pre-existing `~/.claude/` containing
#      a regular file, a valid symlink, a broken symlink, and
#      kind-mismatched entries (file vs. directory in both directions)
#      against the fresh clone. Asserts every per-entry rule:
#        - regular file overwrites clone version (local wins);
#        - valid symlink carries forward as a symlink;
#        - broken symlink is skipped with a warning, clone file at the
#          same name survives, and the broken symlink stays in
#          `.claude.orig.<ts>/`;
#        - kind-mismatch directory replaces clone file (and vice versa).
#   6. Hand-fixed directory (no symlinks at all, not a clone): migrates
#      cleanly onto a fresh clone with local-wins overlay. This
#      previously errored out under the "legacy symlink layout" gate.
#   7. config.toml's `[claude]` section with `branch=` only selects that branch.
#   8. config.toml's `[claude]` section with both `branch=` and `hostname=`: branch
#      drives the integration install; hostname-driven URL rewrite is
#      unit-tested in case 11 below.
#   9. config.toml's `[claude]` section missing entirely: falls back to the remote
#      default branch.
#  10. Three-tier precedence: host-tier config.toml's `[claude]` section overrides
#      default-tier file (no per-key merge — host's `branch=` wins
#      and host's omitted `hostname` does NOT inherit from default).
#  11. Fresh clone uses the HTTPS URL: SSH URL points at a bogus path,
#      HTTPS URL at the working fake remote; clone must still succeed.
#  12. Existing SSH-origin clone: recognized as ours, synced in place,
#      SSH origin NOT rewritten to HTTPS, not migrated aside.
#  13. Existing HTTPS-origin clone: recognized as ours, synced in
#      place, origin untouched, not migrated aside.
#  14. Library unit tests: parser, URL re-derivation, origin reconcile.
#  15. Plugin sync, standalone `plugins-install` / `plugins-update`:
#      a fake `claude` CLI on PATH + a fake `~/.claude/plugins.sh` that
#      records its flag -> the script invokes plugins.sh with the right
#      flag and exits 0.
#  16. Plugin sync skip: `claude` CLI absent -> warn + skip, exit 0,
#      plugins.sh never called.
#  17. Plugin sync skip: `~/.claude/plugins.sh` absent (older clone) ->
#      warn + skip, exit 0.
#  18. Plugin sync failure surfaces: a failing plugins.sh makes the
#      standalone `plugins-install` exit non-zero.
#  19. Inline plugin sync on install is non-fatal: a failing plugins.sh
#      warns but the overall `install` still exits 0.
#
# The test redirects $HOME to a sandboxed temp directory, builds a fake
# global Claude config repo with two branches (`main` and `branch-x`),
# and points $CLAUDE_REPO_URL_SSH / $CLAUDE_REPO_URL_HTTPS at it via env
# override. Network access to GitHub is not required.
#
# Run from the repo root:
#
#   bash scripts/test/claude_repo_setup_test.sh
#
# The script exits 0 on success; on failure it prints which case
# failed and leaves the sandbox in place under `.claude/tmp/<slug>/`
# for inspection.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SANDBOX_BASE="$REPO_ROOT/.claude/tmp/claude_repo_setup_test"
FAIL=0

cleanup_on_success() {
    if [[ $FAIL -eq 0 ]]; then
        rm -rf "$SANDBOX_BASE"
    else
        echo
        echo "Sandbox preserved at: $SANDBOX_BASE" >&2
    fi
}
trap cleanup_on_success EXIT

mk_fake_remote() {
    local remote_dir="$1"
    rm -rf "$remote_dir"
    git init --quiet --bare "$remote_dir"

    local seed="${remote_dir%.git}.seed"
    rm -rf "$seed"
    git init --quiet "$seed"
    git -C "$seed" config user.email "test@example.com"
    git -C "$seed" config user.name "Test"
    git -C "$seed" checkout -q -b main
    echo "main file" > "$seed/main.txt"
    git -C "$seed" add main.txt
    git -C "$seed" commit -q -m "init main"
    git -C "$seed" checkout -q -b branch-x
    echo "branch-x file" > "$seed/branch-x.txt"
    git -C "$seed" add branch-x.txt
    git -C "$seed" commit -q -m "init branch-x"
    git -C "$seed" checkout -q main
    git -C "$seed" remote add origin "$remote_dir"
    git -C "$seed" push -q origin main branch-x
    git -C "$seed" remote set-head origin main >/dev/null
    rm -rf "$seed"
}

# The host tier lives OUTSIDE the repo now (issue #160). For a given
# sandbox repo clone, its external host tier is a sibling dir. Both
# `run_install` (which points the script at it via MACOS_SETUP_HOST_DIR)
# and `mk_config_host` (which writes the host-tier config there) use
# this single derivation so they agree on the path.
host_dir_for() {
    local repo_root="$1"
    echo "${repo_root}.host"
}

run_install() {
    local sandbox_home="$1"
    local remote_url="$2"
    local repo_root="$3"
    # Invoke the script from the sandboxed $repo_root (not from
    # the real $REPO_ROOT) so the script's REPO_ROOT computation
    # picks up the sandboxed default-tier config.toml's `[claude]` section file. The
    # host tier is pointed at a sandbox-local external dir via
    # MACOS_SETUP_HOST_DIR so we never touch a real ~/.config path.
    HOME="$sandbox_home" \
        MACOS_SETUP_HOST_DIR="$(host_dir_for "$repo_root")" \
        CLAUDE_REPO_URL_SSH="$remote_url" \
        CLAUDE_REPO_URL_HTTPS="$remote_url" \
        bash "$repo_root/scripts/claude_repo_setup.sh" install
}

# Variant of `run_install` that points the SSH and HTTPS URLs at
# DIFFERENT values. Used to prove that the clone/network paths use the
# HTTPS URL (the working fake remote) and never the SSH URL (a bogus,
# unclonable path). If the script were to clone via SSH, the clone
# would fail because `$ssh_url` does not exist.
run_install_split_urls() {
    local sandbox_home="$1"
    local ssh_url="$2"
    local https_url="$3"
    local repo_root="$4"
    HOME="$sandbox_home" \
        MACOS_SETUP_HOST_DIR="$(host_dir_for "$repo_root")" \
        CLAUDE_REPO_URL_SSH="$ssh_url" \
        CLAUDE_REPO_URL_HTTPS="$https_url" \
        bash "$repo_root/scripts/claude_repo_setup.sh" install
}

# Run a `plugins-install` / `plugins-update` sub-command against the
# sandbox. `cmd` is the sub-command name. The plugin-sync path needs no
# remote/clone, so we only set the env knobs the sync reads:
#
#   - CLAUDE_PLUGINS_SCRIPT  path to the fake plugins.sh under test;
#   - CLAUDE_CLI_BIN         name of the `claude` binary to look for;
#   - PATH                   prepended with a fake-bin dir so a stubbed
#                            `claude` (when present) is found.
#
# `fake_bin_dir` is prepended to PATH; pass an empty/absent dir to
# exercise the missing-binary guard. Extra trailing args after
# `fake_bin_dir` pass through unchanged (none needed today).
run_plugins_cmd() {
    local sandbox_home="$1"
    local repo_root="$2"
    local cmd="$3"
    local plugins_script="$4"
    local cli_bin="$5"
    local fake_bin_dir="$6"
    HOME="$sandbox_home" \
        MACOS_SETUP_HOST_DIR="$(host_dir_for "$repo_root")" \
        CLAUDE_PLUGINS_SCRIPT="$plugins_script" \
        CLAUDE_CLI_BIN="$cli_bin" \
        PATH="${fake_bin_dir:+$fake_bin_dir:}$PATH" \
        bash "$repo_root/scripts/claude_repo_setup.sh" "$cmd"
}

# Create a fake `claude` CLI stub in `$dir` so `command -v claude`
# succeeds. The stub does nothing (the real plugin work is done by
# plugins.sh, which this repo only calls).
mk_fake_claude_cli() {
    local dir="$1"
    local name="${2:-claude}"
    mkdir -p "$dir"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/$name"
    chmod +x "$dir/$name"
}

# Create a fake `plugins.sh` at `$path` that records the flag it was
# called with into `$path.flag` and exits with `$exit_code` (default 0).
mk_fake_plugins_script() {
    local path="$1"
    local exit_code="${2:-0}"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<EOF
#!/usr/bin/env bash
echo "\$1" > "$path.flag"
exit $exit_code
EOF
    chmod +x "$path"
}

# Emit a `[claude]` section into the given config.toml from the given
# `key=value` args (e.g. `branch=branch-x`, `hostname=github.com-edwin`).
# Each value is quoted as a TOML string. Args that are blank, start with
# `#`, or contain no `=` are skipped (these stand in for the comment /
# blank / junk lines the old key=value files tolerated; they carry no
# [claude] value). Whitespace around the key and value is trimmed so the
# emitted TOML is well-formed regardless of messy input.
write_claude_toml() {
    local cfg="$1"; shift
    : > "$cfg"
    echo "[claude]" >> "$cfg"
    local kv key value
    for kv in "$@"; do
        [[ -z "$kv" ]] && continue
        [[ "$kv" == \#* ]] && continue
        [[ "$kv" != *=* ]] && continue
        key="${kv%%=*}"
        value="${kv#*=}"
        # Trim surrounding whitespace from key and value.
        key="${key#"${key%%[![:space:]]*}"}"; key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"; value="${value%"${value##*[![:space:]]}"}"
        echo "${key} = \"${value}\"" >> "$cfg"
    done
}

# Write a default-tier `config.toml` (with a `[claude]` section) from the
# given `key=value` pairs. Removes any pre-existing default-tier
# config.toml. The scalar claude knobs now live in config.toml's
# `[claude]` section (issue #156), read via dasel.
mk_config_default() {
    local repo_root="$1"; shift
    local cfg="$repo_root/default/config.toml"
    mkdir -p "$repo_root/default"
    write_claude_toml "$cfg" "$@"
}

# Write a host-tier `config.toml` into the EXTERNAL host tier (issue
# #160). The host tier lives at the path returned by `host_tier_dir`,
# which `run_install` overrides to `host_dir_for "$repo_root"` via
# MACOS_SETUP_HOST_DIR.
mk_config_host() {
    local repo_root="$1"; shift
    local host_dir
    host_dir="$(host_dir_for "$repo_root")"
    local cfg="$host_dir/config.toml"
    mkdir -p "$host_dir"
    write_claude_toml "$cfg" "$@"
}

assert_branch() {
    local claude_dir="$1"
    local expect="$2"
    local actual
    actual=$(git -C "$claude_dir" symbolic-ref --short HEAD)
    if [[ "$actual" != "$expect" ]]; then
        echo "  FAIL: expected branch '$expect', got '$actual'" >&2
        FAIL=1
        return 1
    fi
}

assert_file_eq() {
    local path="$1"
    local expect="$2"
    if [[ ! -f "$path" ]]; then
        echo "  FAIL: missing file: $path" >&2
        FAIL=1
        return 1
    fi
    local actual
    actual=$(cat "$path")
    if [[ "$actual" != "$expect" ]]; then
        echo "  FAIL: $path: expected '$expect', got '$actual'" >&2
        FAIL=1
        return 1
    fi
}

assert_origin() {
    local claude_dir="$1"
    local expect="$2"
    local actual
    actual=$(git -C "$claude_dir" config --get remote.origin.url)
    if [[ "$actual" != "$expect" ]]; then
        echo "  FAIL: expected origin '$expect', got '$actual'" >&2
        FAIL=1
        return 1
    fi
}

run_case() {
    local name="$1"; shift
    echo "[case] $name"
    local case_dir="$SANDBOX_BASE/$name"
    rm -rf "$case_dir"
    mkdir -p "$case_dir"

    # Each case gets its own fake remote and HOME.
    local remote_dir="$case_dir/remote.git"
    local home_dir="$case_dir/home"
    local repo_clone="$case_dir/repo"
    mk_fake_remote "$remote_dir"
    mkdir -p "$home_dir"

    # Mirror only the bits of the repo the script reads. Each case
    # writes its own config.toml's `[claude]` section (or none) under
    # `computer-specific/`; nothing carries over from the host repo.
    mkdir -p "$repo_clone/scripts" "$repo_clone/default"
    cp "$REPO_ROOT/scripts/claude_repo_setup.sh" "$repo_clone/scripts/"
    cp "$REPO_ROOT/scripts/claude_repo_common.sh" "$repo_clone/scripts/"
    cp "$REPO_ROOT/scripts/config_common.sh" "$repo_clone/scripts/"

    "$@" "$home_dir" "$remote_dir" "$repo_clone"
}

# --- Cases -----------------------------------------------------------------

case_fresh_clone() {
    local home_dir="$1" remote="$2" repo="$3"
    # No config.toml's `[claude]` section: falls back to remote default branch (main).
    run_install "$home_dir" "$remote" "$repo" >/dev/null
    assert_branch "$home_dir/.claude" main
    assert_file_eq "$home_dir/.claude/main.txt" "main file"
}

case_existing_same_branch() {
    local home_dir="$1" remote="$2" repo="$3"
    run_install "$home_dir" "$remote" "$repo" >/dev/null
    # Re-run with same config. Should still be on main.
    run_install "$home_dir" "$remote" "$repo" >/dev/null
    assert_branch "$home_dir/.claude" main
}

case_existing_switch_branch() {
    local home_dir="$1" remote="$2" repo="$3"
    # First run: no config -> defaults to main.
    run_install "$home_dir" "$remote" "$repo" >/dev/null
    # Second run: config selects branch-x. The install must switch.
    mk_config_default "$repo" "branch=branch-x"
    run_install "$home_dir" "$remote" "$repo" >/dev/null
    assert_branch "$home_dir/.claude" branch-x
    assert_file_eq "$home_dir/.claude/branch-x.txt" "branch-x file"
}

case_dirty_working_tree() {
    local home_dir="$1" remote="$2" repo="$3"
    run_install "$home_dir" "$remote" "$repo" >/dev/null
    echo "local edit" > "$home_dir/.claude/main.txt"
    run_install "$home_dir" "$remote" "$repo" >/dev/null
    # The dirty edit should survive via stash/pop on the same branch.
    assert_file_eq "$home_dir/.claude/main.txt" "local edit"
}

# Consolidated mixed-content migration test.
#
# Builds a pre-existing `~/.claude/` that exercises every per-entry
# overlay rule in one run:
#
#   - `regular.txt`           regular file collides with clone file
#                             (local wins);
#   - `valid_link`            valid symlink to content outside the
#                             tree, must carry forward as a symlink;
#   - `CLAUDE.md`             dangling symlink whose target was moved
#                             into the global repo. The clone has a
#                             real file at this path; the dangling
#                             symlink must be skipped with a warning
#                             and the clone file must survive;
#   - `file_in_clone_dir_in_legacy`
#                             clone has a regular FILE; legacy has a
#                             DIRECTORY (kind mismatch, dir wins);
#   - `dir_in_clone_file_in_legacy`
#                             clone has a DIRECTORY; legacy has a
#                             regular FILE (kind mismatch, file wins);
#   - `subdir/`               directory overlay deep-merges with
#                             local wins.
#
# Mirrors the bug from issue #113: a dangling symlink in legacy
# `~/.claude/` previously replaced the clone's real file at the same
# path with a broken pointer.
case_mixed_content_migration() {
    local home_dir="$1" remote="$2" repo="$3"

    # Push extra entries onto the per-case fake remote so the fresh
    # clone has known content at the collision paths.
    local seed="${remote%.git}.mixedseed"
    rm -rf "$seed"
    git clone --quiet "$remote" "$seed"
    git -C "$seed" config user.email "test@example.com"
    git -C "$seed" config user.name "Test"
    git -C "$seed" checkout -q main
    echo "clone regular content" > "$seed/regular.txt"
    echo "clone CLAUDE.md content" > "$seed/CLAUDE.md"
    echo "clone file content" > "$seed/file_in_clone_dir_in_legacy"
    mkdir -p "$seed/dir_in_clone_file_in_legacy"
    echo "clone dir content" \
        > "$seed/dir_in_clone_file_in_legacy/inner.txt"
    mkdir -p "$seed/subdir"
    echo "clone subdir content" > "$seed/subdir/clone_only.txt"
    echo "clone shared content" > "$seed/subdir/shared.txt"
    git -C "$seed" add regular.txt CLAUDE.md \
        file_in_clone_dir_in_legacy \
        dir_in_clone_file_in_legacy \
        subdir/clone_only.txt subdir/shared.txt
    git -C "$seed" commit -q -m "add mixed-content collision entries"
    git -C "$seed" push -q origin main
    rm -rf "$seed"

    # Build the pre-existing ~/.claude/ with mixed content.
    mkdir -p "$home_dir/.claude" "$repo/legacy_src/dir"
    echo "legacy regular content" > "$home_dir/.claude/regular.txt"

    # Valid symlink: target is a real file inside `$repo` (outside the
    # `~/.claude/` tree itself).
    echo "legacy linked content" > "$repo/legacy_src/linked.txt"
    ln -s "$repo/legacy_src/linked.txt" "$home_dir/.claude/valid_link"

    # Dangling symlink at a name the clone has a real file for. This
    # is the bug-reproducer from issue #113: previously this would
    # replace the clone's real `CLAUDE.md` with a dead pointer.
    ln -s "$repo/legacy_src/does-not-exist" "$home_dir/.claude/CLAUDE.md"

    # Kind-mismatch entries (legacy has the OPPOSITE kind from clone).
    mkdir -p "$home_dir/.claude/file_in_clone_dir_in_legacy"
    echo "legacy dir content" \
        > "$home_dir/.claude/file_in_clone_dir_in_legacy/inner.txt"
    echo "legacy file content" \
        > "$home_dir/.claude/dir_in_clone_file_in_legacy"

    # Directory deep-merge: legacy has a different file at the same
    # name as the clone (local wins) and one new file the clone
    # doesn't have.
    mkdir -p "$home_dir/.claude/subdir"
    echo "legacy shared content" > "$home_dir/.claude/subdir/shared.txt"
    echo "legacy only content" > "$home_dir/.claude/subdir/legacy_only.txt"

    # Capture stderr so we can assert the broken-symlink warning.
    local stderr_log="$home_dir/.install_stderr.log"
    run_install "$home_dir" "$remote" "$repo" >/dev/null 2>"$stderr_log"

    assert_branch "$home_dir/.claude" main

    # Untouched clone file from outside the migration set.
    assert_file_eq "$home_dir/.claude/main.txt" "main file"

    # Rule: regular file (local wins).
    assert_file_eq "$home_dir/.claude/regular.txt" "legacy regular content"

    # Rule: valid symlink carries forward as a symlink.
    if [[ ! -L "$home_dir/.claude/valid_link" ]]; then
        echo "  FAIL: expected valid_link to be a symlink in clone" >&2
        FAIL=1
    fi
    assert_file_eq "$home_dir/.claude/valid_link" "legacy linked content"

    # Rule: broken symlink skipped; clone file at same name survives.
    if [[ -L "$home_dir/.claude/CLAUDE.md" ]]; then
        echo "  FAIL: clone CLAUDE.md was replaced by broken symlink" >&2
        FAIL=1
    fi
    assert_file_eq "$home_dir/.claude/CLAUDE.md" "clone CLAUDE.md content"

    # Warning was emitted with source path + dead target.
    if ! grep -q "skipping broken symlink" "$stderr_log"; then
        echo "  FAIL: expected 'skipping broken symlink' warning on stderr" >&2
        FAIL=1
    fi
    if ! grep -q "does-not-exist" "$stderr_log"; then
        echo "  FAIL: expected dead target in warning" >&2
        FAIL=1
    fi

    # Rule: kind-mismatch file -> directory.
    if [[ ! -d "$home_dir/.claude/file_in_clone_dir_in_legacy" ]]; then
        echo "  FAIL: expected directory at file_in_clone_dir_in_legacy" >&2
        FAIL=1
    fi
    assert_file_eq \
        "$home_dir/.claude/file_in_clone_dir_in_legacy/inner.txt" \
        "legacy dir content"

    # Rule: kind-mismatch directory -> file.
    if [[ -d "$home_dir/.claude/dir_in_clone_file_in_legacy" ]]; then
        echo "  FAIL: expected regular file at dir_in_clone_file_in_legacy" >&2
        FAIL=1
    fi
    assert_file_eq \
        "$home_dir/.claude/dir_in_clone_file_in_legacy" \
        "legacy file content"

    # Rule: directory deep-merge (local wins on shared, clone files
    # under the same dir are preserved, legacy-only files added).
    assert_file_eq "$home_dir/.claude/subdir/shared.txt" \
        "legacy shared content"
    assert_file_eq "$home_dir/.claude/subdir/clone_only.txt" \
        "clone subdir content"
    assert_file_eq "$home_dir/.claude/subdir/legacy_only.txt" \
        "legacy only content"

    # `.claude.orig.<ts>/` exists and the broken symlink survives in
    # it (not in the clone).
    local orig
    orig=$(find "$home_dir" -maxdepth 1 -name ".claude.orig.*" \
        -print -quit)
    if [[ -z "$orig" ]]; then
        echo "  FAIL: missing .claude.orig.<ts>/" >&2
        FAIL=1
        return 1
    fi
    if [[ ! -L "$orig/CLAUDE.md" ]]; then
        echo "  FAIL: expected dangling symlink preserved under .claude.orig.<ts>" >&2
        FAIL=1
    fi
}

# Hand-fixed directory: a `~/.claude/` containing only regular files
# (no symlinks at all, no `.git`) that previously errored out under
# the "is not the legacy symlink layout" gate. After issue #113 it
# must migrate cleanly the same way any other non-clone state does.
case_hand_fixed_dir() {
    local home_dir="$1" remote="$2" repo="$3"
    mkdir -p "$home_dir/.claude"
    echo "user content" > "$home_dir/.claude/random.txt"

    run_install "$home_dir" "$remote" "$repo" >/dev/null

    assert_branch "$home_dir/.claude" main
    # Clone file from main is present.
    assert_file_eq "$home_dir/.claude/main.txt" "main file"
    # User's file was overlaid onto the clone.
    assert_file_eq "$home_dir/.claude/random.txt" "user content"
    # Pre-existing dir was moved aside, not deleted.
    local orig
    orig=$(find "$home_dir" -maxdepth 1 -name ".claude.orig.*" \
        -print -quit)
    if [[ -z "$orig" ]]; then
        echo "  FAIL: missing .claude.orig.<ts>/" >&2
        FAIL=1
        return 1
    fi
    assert_file_eq "$orig/random.txt" "user content"
}

# config.toml's `[claude]` section with `branch=` only selects that branch. Verifies
# the resolver picks `branch=` from the default-tier config file.
case_config_branch_only() {
    local home_dir="$1" remote="$2" repo="$3"
    mk_config_default "$repo" "branch=branch-x"
    run_install "$home_dir" "$remote" "$repo" >/dev/null
    assert_branch "$home_dir/.claude" branch-x
    assert_file_eq "$home_dir/.claude/branch-x.txt" "branch-x file"
}

# config.toml's `[claude]` section with both `branch=` and `hostname=` set. Branch
# selects via `branch=`. Hostname is parsed and applied to module
# state but URL derivation is suppressed by the env override
# (`CLAUDE_REPO_URL_SSH` set by `run_install`), so the integration
# install still talks to the sandbox bare repo. Hostname-driven URL
# rewrite is unit-tested separately below.
case_config_branch_and_hostname() {
    local home_dir="$1" remote="$2" repo="$3"
    mk_config_default "$repo" \
        "branch=branch-x" \
        "hostname=github.com-edwin"
    run_install "$home_dir" "$remote" "$repo" >/dev/null
    assert_branch "$home_dir/.claude" branch-x
}

# config.toml missing entirely: falls back to the remote default
# branch (`main`).
case_config_missing_falls_back_to_default() {
    local home_dir="$1" remote="$2" repo="$3"
    # Make sure no config exists in the sandbox repo or the host tier.
    rm -f "$repo/default/config.toml"
    rm -f "$(host_dir_for "$repo")/config.toml"
    run_install "$home_dir" "$remote" "$repo" >/dev/null
    assert_branch "$home_dir/.claude" main
    assert_file_eq "$home_dir/.claude/main.txt" "main file"
}

# Three-tier precedence: host-tier config.toml's `[claude]` section overrides default-
# tier file. No per-key merge — the host's `branch=branch-x` wins
# even when the default tier has `branch=main`.
case_config_three_tier_precedence() {
    local home_dir="$1" remote="$2" repo="$3"
    mk_config_default "$repo" "branch=main"
    mk_config_host    "$repo" "branch=branch-x"
    run_install "$home_dir" "$remote" "$repo" >/dev/null
    assert_branch "$home_dir/.claude" branch-x
}

# Fresh clone uses the HTTPS URL, not the SSH URL. Point the SSH URL
# at a bogus, unclonable path and the HTTPS URL at the working fake
# remote. If the script cloned via SSH the clone would fail; success
# (clone present, on main) proves the fresh-clone path uses HTTPS.
case_fresh_clone_uses_https() {
    local home_dir="$1" remote="$2" repo="$3"
    local bogus_ssh="git@github.invalid:nonexistent/does-not-exist.git"
    run_install_split_urls "$home_dir" "$bogus_ssh" "$remote" "$repo" >/dev/null
    assert_branch "$home_dir/.claude" main
    assert_file_eq "$home_dir/.claude/main.txt" "main file"
}

# An existing clone whose `origin` is the SSH form is recognized as
# ours, synced in place, and its SSH origin is NOT rewritten to HTTPS.
# We seed a clone manually with an SSH-form origin and assert the
# origin URL is untouched after a re-run.
#
# The SSH and HTTPS env URLs are DISTINCT here (via run_install_split_urls)
# so the assertion has teeth: if the install path ever rewrote the SSH
# origin to the HTTPS URL, `assert_origin == $ssh_url` would fail
# because `$ssh_url != $https_url`. (Under the same-value `run_install`
# helper the two strings would be identical and the assertion could not
# distinguish "left intact" from "rewritten to HTTPS".)
#
# Both URLs still point at the same fake remote so the sync (fetch/pull)
# succeeds regardless of which arm git uses: the SSH value is the
# `file://` form of the remote, the HTTPS value is the plain path form.
# These are textually distinct but functionally equivalent, so the seed
# clone is recognized as ours (origin == CLAUDE_REPO_URL_SSH) and the
# fetch works.
case_existing_ssh_origin_preserved() {
    local home_dir="$1" remote="$2" repo="$3"
    local ssh_url="file://$remote"
    local https_url="$remote"

    # Seed ~/.claude as a real clone of the fake remote, then rewrite
    # its origin to the SSH-form URL that `claude_repo_is_our_clone`
    # accepts (the env-overridden CLAUDE_REPO_URL_SSH = "$ssh_url").
    git clone --quiet "$remote" "$home_dir/.claude"
    git -C "$home_dir/.claude" checkout -q main
    git -C "$home_dir/.claude" remote set-url origin "$ssh_url"

    # CLAUDE_REPO_URL_SSH == "$ssh_url" (set by run_install_split_urls),
    # so the existing origin "$ssh_url" is recognized as ours. The
    # reconcile path is a no-op (no `hostname=` configured), so origin
    # must be left exactly as-is — NOT rewritten to the (distinct) HTTPS
    # URL.
    run_install_split_urls "$home_dir" "$ssh_url" "$https_url" "$repo" >/dev/null

    assert_branch "$home_dir/.claude" main
    # Asserting the origin is still the SSH form (not the HTTPS form)
    # is meaningful precisely because the two URLs are distinct.
    assert_origin "$home_dir/.claude" "$ssh_url"
    # No migration happened (existing clone recognized, not moved aside).
    local orig
    orig=$(find "$home_dir" -maxdepth 1 -name ".claude.orig.*" -print -quit)
    if [[ -n "$orig" ]]; then
        echo "  FAIL: existing SSH-origin clone was migrated aside ($orig)" >&2
        FAIL=1
    fi
}

# An existing clone whose `origin` is the HTTPS form is recognized as
# ours and synced in place (no migration, origin untouched).
case_existing_https_origin_recognized() {
    local home_dir="$1" remote="$2" repo="$3"

    git clone --quiet "$remote" "$home_dir/.claude"
    git -C "$home_dir/.claude" checkout -q main
    # Leave origin == "$remote", which run_install also passes as
    # CLAUDE_REPO_URL_HTTPS, so it's recognized via the HTTPS arm.
    run_install "$home_dir" "$remote" "$repo" >/dev/null

    assert_branch "$home_dir/.claude" main
    assert_origin "$home_dir/.claude" "$remote"
    local orig
    orig=$(find "$home_dir" -maxdepth 1 -name ".claude.orig.*" -print -quit)
    if [[ -n "$orig" ]]; then
        echo "  FAIL: existing HTTPS-origin clone was migrated aside ($orig)" >&2
        FAIL=1
    fi
}

# Unit tests for `claude_repo_common.sh` library functions that are
# hard to exercise through the full install path:
#
#   - `claude_repo_load_config` parses `branch=` and `hostname=` and
#     ignores comments / blank lines / unknown keys / unparseable
#     lines.
#   - `claude_repo_apply_config` re-derives `CLAUDE_REPO_URL_SSH` from
#     a non-default `hostname=` when no env override is in effect.
#   - `claude_repo_reconcile_origin_hostname` rewrites a clone's
#     `origin` from the default-hostname canonical URL to the
#     configured-hostname canonical URL, and is idempotent and a
#     no-op when the configured hostname is the default.
#   - `claude_repo_is_our_clone` accepts a clone whose `origin` is the
#     default-hostname canonical URL even when a non-default hostname
#     is configured.
#
# Runs in a subshell so the sourced module state (CLAUDE_REPO_*
# globals, the once-only load guard) can't leak into other cases.
# The subshell exits non-zero on any local assertion failure; the
# parent shell mirrors that into the outer FAIL flag.
case_unit_lib_helpers() {
    local home_dir="$1" remote="$2" repo="$3"
    if ! (
        # Subshell-local fail flag (no `local` keyword: not a function).
        local_fail=0
        # Drive the library directly with a sandbox `repo_root` and a
        # default hostname / path so URL derivation results in
        # predictable values.
        export CLAUDE_REPO_DEFAULT_HOSTNAME="github.com"
        export CLAUDE_REPO_PATH="TheVoskamps/claude-config.git"
        # Don't pre-set CLAUDE_REPO_URL_SSH; let `apply_config` derive
        # it from the parsed hostname.
        unset CLAUDE_REPO_URL_SSH
        unset CLAUDE_REPO_URL_HTTPS
        # Sandbox HOME for `claude_repo_origin_url` lookups.
        export HOME="$home_dir"

        # Source the library fresh.
        # shellcheck disable=SC1091
        source "$repo/scripts/claude_repo_common.sh"

        # --- 1. Parser: branch + hostname + comments + unknowns. -----
        mk_config_default "$repo" \
            "# leading comment" \
            "" \
            "branch=branch-x" \
            "  hostname  =  github.com-edwin  " \
            "unknown_key=ignored" \
            "no_equals_so_skipped"
        claude_repo_load_config "$repo"
        if [[ "$CLAUDE_REPO_CONFIG_BRANCH" != "branch-x" ]]; then
            echo "  FAIL: parser branch: expected 'branch-x', got '$CLAUDE_REPO_CONFIG_BRANCH'" >&2
            local_fail=1
        fi
        if [[ "$CLAUDE_REPO_CONFIG_HOSTNAME" != "github.com-edwin" ]]; then
            echo "  FAIL: parser hostname: expected 'github.com-edwin', got '$CLAUDE_REPO_CONFIG_HOSTNAME'" >&2
            local_fail=1
        fi

        # --- 2. apply_config re-derives URLs from hostname. ----------
        claude_repo_apply_config "$repo"
        local expected_ssh="git@github.com-edwin:TheVoskamps/claude-config.git"
        if [[ "$CLAUDE_REPO_URL_SSH" != "$expected_ssh" ]]; then
            echo "  FAIL: derived SSH URL: expected '$expected_ssh', got '$CLAUDE_REPO_URL_SSH'" >&2
            local_fail=1
        fi
        # HTTPS always uses the real github.com host (SSH aliases
        # aren't valid HTTPS hosts).
        local expected_https="https://github.com/TheVoskamps/claude-config.git"
        if [[ "$CLAUDE_REPO_URL_HTTPS" != "$expected_https" ]]; then
            echo "  FAIL: derived HTTPS URL: expected '$expected_https', got '$CLAUDE_REPO_URL_HTTPS'" >&2
            local_fail=1
        fi

        # --- 3. claude_repo_is_our_clone recognizes a clone whose
        # origin is the default-hostname canonical URL even when
        # apply_config set CLAUDE_REPO_URL_SSH to a non-default form.
        rm -rf "$home_dir/.claude"
        mkdir -p "$home_dir/.claude"
        git -C "$home_dir/.claude" init --quiet
        git -C "$home_dir/.claude" remote add origin \
            "git@github.com:TheVoskamps/claude-config.git"
        if ! claude_repo_is_our_clone; then
            echo "  FAIL: is_our_clone should accept default-hostname URL with non-default hostname configured" >&2
            local_fail=1
        fi

        # --- 4. reconcile_origin_hostname rewrites default->configured.
        claude_repo_reconcile_origin_hostname >/dev/null
        local post
        post=$(git -C "$home_dir/.claude" config --get remote.origin.url)
        if [[ "$post" != "$expected_ssh" ]]; then
            echo "  FAIL: reconcile rewrite: expected '$expected_ssh', got '$post'" >&2
            local_fail=1
        fi

        # --- 5. reconcile is idempotent on second call. --------------
        claude_repo_reconcile_origin_hostname >/dev/null
        post=$(git -C "$home_dir/.claude" config --get remote.origin.url)
        if [[ "$post" != "$expected_ssh" ]]; then
            echo "  FAIL: reconcile idempotence: expected '$expected_ssh', got '$post'" >&2
            local_fail=1
        fi

        # --- 6. reconcile is a no-op when configured hostname is the
        # default. Reset config to no `hostname=` and re-apply.
        mk_config_default "$repo" "branch=main"
        claude_repo_apply_config "$repo"
        # Set origin to a deliberately unrelated URL; reconcile must
        # NOT touch it.
        git -C "$home_dir/.claude" remote set-url origin \
            "git@some-other-host:foo/bar.git"
        claude_repo_reconcile_origin_hostname >/dev/null
        post=$(git -C "$home_dir/.claude" config --get remote.origin.url)
        if [[ "$post" != "git@some-other-host:foo/bar.git" ]]; then
            echo "  FAIL: reconcile should be a no-op when hostname is default; got '$post'" >&2
            local_fail=1
        fi

        exit $local_fail
    ); then
        FAIL=1
    fi
}

# Standalone `plugins-install` / `plugins-update`: a fake `claude` CLI
# on PATH plus a fake `plugins.sh` that records its flag. The script
# must invoke plugins.sh with `--install` / `--update` respectively and
# exit 0. Proves the standalone targets route through plugins.sh with
# the right flag.
case_plugins_standalone_invokes_script() {
    local home_dir="$1" remote="$2" repo="$3"
    local fake_bin="$home_dir/fakebin"
    local plugins_script="$home_dir/.claude/plugins.sh"
    mk_fake_claude_cli "$fake_bin"

    # install -> --install
    mk_fake_plugins_script "$plugins_script" 0
    run_plugins_cmd "$home_dir" "$repo" plugins-install \
        "$plugins_script" claude "$fake_bin" >/dev/null
    assert_file_eq "$plugins_script.flag" "--install"

    # update -> --update
    rm -f "$plugins_script.flag"
    run_plugins_cmd "$home_dir" "$repo" plugins-update \
        "$plugins_script" claude "$fake_bin" >/dev/null
    assert_file_eq "$plugins_script.flag" "--update"
}

# Skip when the `claude` CLI is absent: point CLAUDE_CLI_BIN at a name
# that is not on PATH. The sync must warn, skip, and exit 0 WITHOUT
# calling plugins.sh (so no `.flag` file appears).
case_plugins_skip_when_cli_absent() {
    local home_dir="$1" remote="$2" repo="$3"
    local plugins_script="$home_dir/.claude/plugins.sh"
    mk_fake_plugins_script "$plugins_script" 0
    rm -f "$plugins_script.flag"

    local stderr_log="$home_dir/.plugins_skip_cli.log"
    # No fake-bin dir; CLI name is guaranteed-absent.
    if ! run_plugins_cmd "$home_dir" "$repo" plugins-install \
        "$plugins_script" claude-definitely-not-on-path "" \
        >/dev/null 2>"$stderr_log"; then
        echo "  FAIL: plugins-install should exit 0 when CLI is absent" >&2
        FAIL=1
    fi
    if [[ -f "$plugins_script.flag" ]]; then
        echo "  FAIL: plugins.sh was called despite missing CLI" >&2
        FAIL=1
    fi
    if ! grep -q "not on PATH; skipping plugin sync" "$stderr_log"; then
        echo "  FAIL: expected missing-CLI warning on stderr" >&2
        FAIL=1
    fi
}

# Skip when `plugins.sh` is absent (older claude-config checkout): the
# CLI is present but the script path doesn't exist. Warn, skip, exit 0.
case_plugins_skip_when_script_absent() {
    local home_dir="$1" remote="$2" repo="$3"
    local fake_bin="$home_dir/fakebin"
    local plugins_script="$home_dir/.claude/plugins.sh"
    mk_fake_claude_cli "$fake_bin"
    rm -f "$plugins_script"

    local stderr_log="$home_dir/.plugins_skip_script.log"
    if ! run_plugins_cmd "$home_dir" "$repo" plugins-install \
        "$plugins_script" claude "$fake_bin" \
        >/dev/null 2>"$stderr_log"; then
        echo "  FAIL: plugins-install should exit 0 when plugins.sh is absent" >&2
        FAIL=1
    fi
    if ! grep -q "not found; skipping plugin sync" "$stderr_log"; then
        echo "  FAIL: expected missing-script warning on stderr" >&2
        FAIL=1
    fi
}

# A failing plugins.sh surfaces through the standalone sub-command: the
# CLI and script both exist, but plugins.sh exits non-zero. The
# standalone `plugins-install` must propagate that non-zero exit.
case_plugins_standalone_surfaces_failure() {
    local home_dir="$1" remote="$2" repo="$3"
    local fake_bin="$home_dir/fakebin"
    local plugins_script="$home_dir/.claude/plugins.sh"
    mk_fake_claude_cli "$fake_bin"
    mk_fake_plugins_script "$plugins_script" 3

    if run_plugins_cmd "$home_dir" "$repo" plugins-install \
        "$plugins_script" claude "$fake_bin" >/dev/null 2>&1; then
        echo "  FAIL: standalone plugins-install should propagate plugins.sh non-zero exit" >&2
        FAIL=1
    fi
    # plugins.sh was actually invoked (records its flag).
    assert_file_eq "$plugins_script.flag" "--install"
}

# Inline plugin sync on `install` is non-fatal: a failing plugins.sh
# warns but the overall install still exits 0. Drives the full
# `cmd_install` path (clone) plus a fake claude CLI and a failing
# plugins.sh seeded at the clone path. The fake remote ships no
# plugins.sh, so we seed our failing stub at $CLAUDE_PLUGINS_SCRIPT
# (which defaults into ~/.claude and is where sync_claude_plugins_nonfatal
# looks) AFTER pointing the env there.
case_plugins_inline_nonfatal_on_install() {
    local home_dir="$1" remote="$2" repo="$3"
    local fake_bin="$home_dir/fakebin"
    local plugins_script="$home_dir/.claude/plugins.sh"
    mk_fake_claude_cli "$fake_bin"

    local stderr_log="$home_dir/.plugins_inline.log"
    # Pre-seed a failing plugins.sh under ~/.claude. Because ~/.claude
    # now exists and is not a clone of the fake remote, install takes
    # the migrate path: move aside -> fresh clone -> overlay (local
    # wins), which restores our plugins.sh onto the clone. The inline
    # sync then runs it AFTER the clone and gets a non-zero exit.
    mk_fake_plugins_script "$plugins_script" 4

    if ! HOME="$home_dir" \
        MACOS_SETUP_HOST_DIR="$(host_dir_for "$repo")" \
        CLAUDE_REPO_URL_SSH="$remote" \
        CLAUDE_REPO_URL_HTTPS="$remote" \
        CLAUDE_PLUGINS_SCRIPT="$plugins_script" \
        CLAUDE_CLI_BIN=claude \
        PATH="$fake_bin:$PATH" \
        bash "$repo/scripts/claude_repo_setup.sh" install \
        >/dev/null 2>"$stderr_log"; then
        echo "  FAIL: install should exit 0 even when inline plugin sync fails" >&2
        FAIL=1
    fi
    assert_branch "$home_dir/.claude" main
    if ! grep -q "plugin sync (--install) failed" "$stderr_log"; then
        echo "  FAIL: expected non-fatal plugin-sync failure warning on stderr" >&2
        FAIL=1
    fi
}

# --- Run -------------------------------------------------------------------

mkdir -p "$SANDBOX_BASE"
run_case "01_fresh_clone"                       case_fresh_clone
run_case "02_existing_same_branch"              case_existing_same_branch
run_case "03_existing_switch"                   case_existing_switch_branch
run_case "04_dirty_tree"                        case_dirty_working_tree
run_case "05_mixed_content"                     case_mixed_content_migration
run_case "06_hand_fixed_dir"                    case_hand_fixed_dir
run_case "07_config_branch_only"                case_config_branch_only
run_case "08_config_branch_and_hostname"        case_config_branch_and_hostname
run_case "09_config_missing_default_branch"     case_config_missing_falls_back_to_default
run_case "10_config_three_tier_precedence"      case_config_three_tier_precedence
run_case "11_fresh_clone_uses_https"            case_fresh_clone_uses_https
run_case "12_existing_ssh_origin_preserved"     case_existing_ssh_origin_preserved
run_case "13_existing_https_origin_recognized"  case_existing_https_origin_recognized
run_case "14_unit_lib_helpers"                  case_unit_lib_helpers
run_case "15_plugins_standalone_invokes"        case_plugins_standalone_invokes_script
run_case "16_plugins_skip_cli_absent"           case_plugins_skip_when_cli_absent
run_case "17_plugins_skip_script_absent"        case_plugins_skip_when_script_absent
run_case "18_plugins_standalone_failure"        case_plugins_standalone_surfaces_failure
run_case "19_plugins_inline_nonfatal_install"   case_plugins_inline_nonfatal_on_install

if [[ $FAIL -ne 0 ]]; then
    echo
    echo "FAIL"
    exit 1
fi
echo
echo "OK"
