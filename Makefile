# Makefile — profile-driven. Every tier (the core tier, each profile the
# host opts into, and the external host tier) contributes ONE unnumbered
# `Brewfile` plus a `[profile]` section in its `config.toml` declaring what
# else it does: `post_install` commands, and `uninstall` / `purge` package
# lists that drive `make uninstall` / `make remove-and-purge` and the smart
# filter on `make install`.
#
# This replaced the `NN-Install.<slug>` slot convention (issue #33). The
# numbered prefix had three jobs and two were already dead: categorisation
# (profiles do that now) and sequencing (no inter-profile dependency
# exists). The third — post-install hook dispatch — was a hardcoded `case`
# on the slot basename right here in this file, which meant a new profile
# could not declare a hook without editing the Makefile. It now lives in
# each profile's own `config.toml`, and this file has no per-profile
# knowledge at all: `make profile brand-new` works the moment
# `profiles/brand-new/` exists, with no Makefile edit.

# Default target - show help when no target is specified
.DEFAULT_GOAL := help

# The bash EVERY recipe uses -- both as make's own recipe shell and as the
# interpreter every `$(BASH_BIN) scripts/foo.sh` invocation names (issue #37).
# It is an ABSOLUTE path on purpose: a bare `bash` is resolved through PATH,
# and on a host whose PATH puts /opt/homebrew/bin first, a removal that takes
# Homebrew's bash formula out mid-run -- directly, or via the `brew autoremove`
# that `brew uninstall` triggers -- makes every LATER recipe line die with
# `/bin/bash: /opt/homebrew/bin/bash: No such file or directory`. That is not
# hypothetical: it happened during the asdf -> mise cutover and cost the
# `update` target its ~/.zshrc strip, leaving the host with dead direnv/asdf
# init lines erroring on every shell startup. /bin/bash ships with macOS and
# no Homebrew operation can remove it.
#
# /bin/bash is bash 3.2. Every script in scripts/ is already written to 3.2
# (see the mapfile note in scripts/test/hammerspoon_reload_test.sh), so
# naming it here changes no script's behavior.
BASH_BIN := /bin/bash
SHELL := $(BASH_BIN)
START_DIR ?= $(CURDIR)
.ONESHELL:
.NOTPARALLEL:

# --- Config ---
BREW ?= $(shell command -v brew 2>/dev/null || echo /opt/homebrew/bin/brew)

# The per-host tier lives OUTSIDE the repo (see host_tier_dir in
# scripts/config_common.sh). Resolve its base path once here so every tier
# walk points at it. The path is overridable via the MACOS_SETUP_HOST_DIR
# env var (used by tests); the default is
# $${XDG_CONFIG_HOME:-$$HOME/.config}/macos-setup. Delegated to a script
# (rather than inlined) for the same reason as PROFILES below: keep
# host-path logic in one place (config_common.sh).
HOST_DIR := $(shell $(BASH_BIN) scripts/host_tier_dir.sh 2>/dev/null)

# The core tier: the lowest-priority tier, applied to every machine before
# any profile.
CORE_TIER := default

# Ordered profile list for THIS host (lowest priority first), read from the
# `profiles` array in the external host tier's `config.toml` (default-tier
# array prepended; dedup keeps last). A host with no `profiles` array yields
# an empty list (zero-profile host: core < host). Parsing is delegated to
# scripts/list_profiles.sh (which reuses get_profiles in config_common.sh,
# querying config.toml via dasel) rather than inlined here.
PROFILES := $(shell $(BASH_BIN) scripts/list_profiles.sh 2>/dev/null)

# Every profile that EXISTS in the repo, whether this host opts into it or
# not. This is what `make profile <name>` validates against and what
# `make profiles` lists — a directory glob, so adding profiles/brand-new/
# needs no edit here.
KNOWN_PROFILES := $(sort $(notdir $(wildcard profiles/*)))

# The full tier stack for this host, in APPLY order (lowest priority first).
# Mirrors tier_roots() in scripts/config_common.sh.
TIERS := $(CORE_TIER) $(addprefix profiles/,$(PROFILES)) $(HOST_DIR)

APPLY_TIER     := scripts/apply_tier.sh
INSTALL_FILTER := scripts/install_filter.sh
REMOVE_RUNNER  := scripts/remove_runner.sh

# Per-run dry-run plumbing. Setting `DRY_RUN=1` on the command line
# expands to `--dry-run` and is forwarded to the runner / self_update.sh.
# Empty by default, so unset behavior is unchanged. The batch removal loops
# use their own UNINSTALL_DRY_RUN / PURGE_DRY_RUN variables driven by the
# `*-dry-run` targets and do not consult DRY_RUN.
DRY_RUN_FLAG := $(if $(DRY_RUN),--dry-run,)

# Space-separated list of TIER ROOTS the batch removal loops
# (`_uninstall_loop` / `_remove_and_purge_loop`) must skip. Empty by
# default, so `make uninstall` / `make remove-and-purge` are unchanged.
# `update` sets it — as a command-line variable on its sub-make, which make
# propagates down through the internal loop targets — for exactly one case:
# the version-managers tier, when the mise install that must precede the
# asdf/direnv removal did not leave a usable mise behind. Skipping only the
# named tier keeps every unrelated removal in that run applying normally.
REMOVE_SKIP_TIERS ?=

# --- Version manager ---
# The `versions-*` targets are implementation-neutral by design: the tool
# they drive lives behind scripts/versions_setup.sh, so swapping it again
# leaves the public interface — target names and doc lines — alone.
# The swap is bounded, not one-file: the tool is also named directly in
# scripts/mise_common.sh, scripts/shell_setup.sh (the ~/.zshrc init lines),
# scripts/launchagent_runner.sh (the shims PATH) and scripts/diagnose.sh.
# Both the version-manager script and the migration script guard on
# `command -v mise` themselves, so nothing here needs to bootstrap mise.
VERSIONS_SETUP := scripts/versions_setup.sh

# The profile that owns BOTH halves of the asdf -> mise cutover: its
# Brewfile installs mise, and its `[profile] purge` array removes asdf and
# direnv. Named here so the two code paths that must gate that removal
# (`install` and `update`) address the same tier and cannot drift.
VM_PROFILE := version-managers
VM_TIER    := profiles/$(VM_PROFILE)

# The mise-reachability probe that gates the DESTRUCTIVE half of the
# asdf -> mise cutover. Removing the old version manager on a host where
# the replacement is not in place leaves that host with NO version
# manager at all, which is strictly worse than leaving both installed --
# so every code path that removes asdf/direnv must run this probe
# immediately before it removes anything, and hold the removal back when
# the probe fails. Both such paths use it: `install` (which applies the
# version-managers tier's purge inline) and `update` (which drives the
# batch removal loops via REMOVE_SKIP_TIERS).
#
# It is a macro, not two hand-written `command -v` calls, so the two
# paths cannot drift and neither can lose the guard silently.
#
# `$(BASH_BIN) -lc` because a mise installed moments earlier in the same run
# lands on a login shell's PATH, not necessarily on make's. `$${MISE:-mise}`
# honors the same override scripts/mise_common.sh reads, which is also
# what lets scripts/test/install_cutover_guard_test.sh point it at an
# absent binary.
MISE_REACHABLE = $(BASH_BIN) -lc 'command -v "$${MISE:-mise}" >/dev/null 2>&1'

# --- Finder defaults (quiet, non-fatal) ---
.PHONY: finder_defaults
finder_defaults: ## Set Finder to List view & show hidden files; purge .DS_Store; relaunch Finder
	@set -uo pipefail
	defaults write com.apple.finder AppleShowAllFiles -bool true 2>/dev/null || true
	defaults write com.apple.finder FXPreferredViewStyle -string "Nlsv" 2>/dev/null || true
	find "$$HOME" -name ".DS_Store" -type f -delete 2>/dev/null || true
	killall Finder 2>/dev/null || true
	@echo "Finder defaults applied."

# --- Shell setup ---
# Also reachable as the core tier's `post_install` first-class action; this
# target drives it standalone.
.PHONY: shell_setup
shell_setup: ## Configure zsh, Oh My Zsh, theme, plugins, aliases (idempotent)
	@set -euo pipefail
	$(BASH_BIN) scripts/shell_setup.sh

# --- Claude global config repo management ---
# `~/.claude/` is a real git checkout of the global Claude config repo
# (https://github.com/TheVoskamps/claude-config.git). Fresh
# clones use the HTTPS URL (most users won't have an SSH key on the
# org/repo); an existing SSH-origin clone is recognized as ours and its
# SSH origin is left intact.
# The active branch and the SSH host alias used in the git remote URL
# are selected from the `[claude]` section of `config.toml`
# (host > reverse(profiles) > default) with optional `branch` and
# `hostname` keys. Missing/unknown branch falls back to the
# remote's default branch; missing hostname defaults to `github.com`.
#
# The `claude` / `claude-latest` profiles name claude_repo_setup.sh in
# their `[profile] post_install`, so `make install` reaches this work too.
.PHONY: claude-install claude-update claude-outdated claude-plugins-install claude-plugins-update

claude-install: ## Install or migrate ~/.claude/ from the global Claude config repo
	@$(BASH_BIN) scripts/claude_repo_setup.sh install

claude-update: ## Update ~/.claude/ (errors if not yet installed via claude-install)
	@$(BASH_BIN) scripts/claude_repo_setup.sh update

claude-outdated: ## Show pending pulls/pushes and dirty files in ~/.claude/ (read-only)
	@$(BASH_BIN) scripts/claude_repo_setup.sh outdated

claude-plugins-install: ## Sync Claude plugins via the clone's own ~/.claude/plugins.sh --install
	@$(BASH_BIN) scripts/claude_repo_setup.sh plugins-install

claude-plugins-update: ## Update Claude plugins via the clone's own ~/.claude/plugins.sh --update
	@$(BASH_BIN) scripts/claude_repo_setup.sh plugins-update


# --- Host-tier seeding ---
# The per-host config tier lives OUTSIDE the repo (see host_tier_dir in
# scripts/config_common.sh). `make install` seeds it from the in-repo
# template ONLY if the external dir is absent; once present it is never
# overwritten. This target exposes the same step standalone.
.PHONY: seed-host-tier
seed-host-tier: ## Seed the external host tier from the template if absent (no-op if it already exists)
	@$(BASH_BIN) scripts/seed_host_tier.sh

# --- dasel reachability gate (issue #4) ---
# Every config.toml read in this repo invokes `dasel` by BARE NAME (the
# read layer in config_common.sh, and list_profiles.sh through it). On a
# fresh Apple Silicon Mac, dasel is installed into /opt/homebrew/bin by
# bootstrap.sh, but /opt/homebrew/bin is not on PATH until a NEW login
# shell sources the `brew shellenv` line bootstrap appended to the
# profile. A user who runs `./bootstrap.sh` then `make install` in the
# SAME shell therefore has dasel installed but unreachable by bare name,
# and the failure used to surface late and cryptically as a buried
# `dasel version exited 127` from require_dasel_v3 partway into the first
# tier's config read. This phony gate runs the up-front reachability check
# (scripts/require_dasel_on_path.sh) as a prerequisite, BEFORE host-tier
# seeding, the recipe-level config reads, and any install work, so a
# missing-on-PATH dasel aborts loudly with an actionable PATH remediation
# instead. It is a bare-name REACHABILITY check only; the exactly-v3
# version assertion stays the job of require_dasel_v3 at the first real
# read. Wired as a prerequisite on each config-dependent batch target
# below (install, profile, core, update, verify, outdated); being .PHONY it
# always runs first, gating the target before any recipe config work begins.
#
# NB: the `PROFILES` variable above is read at make PARSE time, before any
# prerequisite (including this gate) runs. A prerequisite cannot gate a
# parse-time expansion, so list_profiles.sh guards itself: with dasel off
# PATH it short-circuits to an empty list rather than letting
# require_dasel_v3's `kill -s TERM "$$"` print a `Terminated: 15` line
# ahead of this gate's clean error. Gate + self-guard together make
# `Error: dasel not in PATH.` the sole output on a no-dasel run.
.PHONY: require-dasel
require-dasel:
	@$(BASH_BIN) scripts/require_dasel_on_path.sh

# --- Tier application targets ---
#
# `make install`     every tier for this host, in order
# `make core`        the core tier only
# `make profile X Y` the named profiles only, in the order given
#
# All three route through scripts/apply_tier.sh, so "what applying a tier
# means" (filter the Brewfile, brew bundle it, run the post_install list)
# lives in exactly one place.
#
# `install` does NOT run the removal loops in general -- the smart filter is
# what keeps a removal-listed package from being installed. The ONE
# exception is the version-managers tier's `purge` array, applied inline
# right after that tier. The asdf -> mise cutover is hard by construction
# (asdf and mise both provide shims for the same tools, so a host carrying
# both is the classic failure mode), and `make install` is the entry point a
# host reaches after `git pull`. Without the inline purge, `make install`
# would install mise and leave asdf and direnv installed alongside it.
# Per-profile `make profile version-managers` deliberately does NOT do this
# -- see docs/VERSION_MANAGEMENT.md for the sequence a per-profile driver
# runs by hand.
#
# That inline purge is gated on $(MISE_REACHABLE), evaluated immediately
# before it and after the version-managers tier is applied, exactly as
# `update` gates its removal loops: if mise is not reachable at that moment
# the purge is skipped entirely, the run warns, and it exits non-zero. The
# guard is explicit on purpose -- removing a host's only version manager is
# not a hazard to leave resting on an accident. It is pinned by
# scripts/test/install_cutover_guard_test.sh.
.PHONY: install core profile profiles uninstall uninstall-dry-run remove-and-purge remove-and-purge-dry-run update help

install: require-dasel ## Apply every tier for this host, in order (core -> profiles -> host); seeds the external host tier if absent
	@set -uo pipefail
	@$(MAKE) -s seed-host-tier
	@failed=""; \
	vm_purge_skipped=""; \
	for tier in $(TIERS); do \
		if $(BASH_BIN) $(APPLY_TIER) "$$tier"; then :; else failed="$$failed $$tier"; fi; \
		if [ "$$tier" = "$(VM_TIER)" ]; then \
			if $(MISE_REACHABLE); then \
				$(BASH_BIN) $(REMOVE_RUNNER) "$(VM_TIER)" --mode=purge \
					--banner="==> Applying RemoveAndPurge: $(VM_TIER)" \
					|| failed="$$failed $(VM_TIER)(purge)"; \
			else \
				vm_purge_skipped="$(VM_TIER)"; \
				echo "WARNING: mise is not reachable after the $(VM_PROFILE) tier was applied." >&2; \
				echo "         Skipping the asdf/direnv removal ($(VM_TIER) purge), so this host is" >&2; \
				echo "         not left with no version manager at all." >&2; \
				echo "         Every other tier still applies. Fix the mise install" >&2; \
				echo "         and re-run 'make install'." >&2; \
			fi; \
		fi; \
	done; \
	rc=0; \
	if [ -n "$$failed" ]; then \
		echo "==> The following tiers failed (brew bundle or a post_install action returned non-zero):"; \
		for s in $$failed; do echo "  - $$s"; done; \
		echo "All other tiers were applied. Re-run 'make install' after resolving the above."; \
		rc=1; \
	fi; \
	if [ -n "$$vm_purge_skipped" ]; then \
		echo "==> Skipped the asdf/direnv removal ($$vm_purge_skipped): mise was not reachable."; \
		echo "Fix the mise install and re-run 'make install' to complete the cutover."; \
		rc=1; \
	fi; \
	if [ $$rc -eq 0 ]; then echo "All tiers applied."; fi; \
	exit $$rc

core: require-dasel ## Apply the core tier only (default/Brewfile + its post_install actions)
	@set -uo pipefail
	@$(BASH_BIN) $(APPLY_TIER) "$(CORE_TIER)"

# `make profile <name> [<name>...]` — ordered, multi-profile, validated.
#
# Make consumes `--`-prefixed arguments as its own options before the
# Makefile ever sees them, so a `make profile --name web` form is not
# achievable (`make: unrecognized option '--name'`). The positional form
# covers it and supports ordered multi-install.
#
# The `$(eval)` below declares each trailing argument as a phony no-op so
# make does not then try to build it as a target of its own. Two accepted
# rough edges follow from that, both on already-failing paths:
#   - `make profile install` emits `warning: overriding commands for target
#     'install'`, then validation rejects `install` as an unknown profile
#     and exits 2 before anything runs. Plain `make install` is unaffected.
#   - `make install profile web` — `profile` is not the first goal, so
#     PROFILE_ARGS is empty and the usage error fires after `install` runs.
ifeq (profile,$(firstword $(MAKECMDGOALS)))
  PROFILE_ARGS := $(wordlist 2,$(words $(MAKECMDGOALS)),$(MAKECMDGOALS))
  $(foreach a,$(PROFILE_ARGS),$(eval $(a):;@:))
endif

profile: require-dasel ## Apply one or more profiles, in the order given: make profile <name> [<name>...]
	@set -uo pipefail
	@if [ -z "$(PROFILE_ARGS)" ]; then \
		echo "usage: make profile <name> [<name>...]" >&2; \
		echo "known profiles: $(KNOWN_PROFILES)" >&2; \
		exit 2; \
	fi
	@BAD=""; \
	for a in $(PROFILE_ARGS); do \
		case " $(KNOWN_PROFILES) " in *" $$a "*) ;; *) BAD="$$BAD $$a";; esac; \
	done; \
	if [ -n "$$BAD" ]; then \
		echo "make: unknown profile(s):$$BAD" >&2; \
		echo "known profiles: $(KNOWN_PROFILES)" >&2; \
		exit 2; \
	fi
	@set -uo pipefail; \
	failed=""; \
	for a in $(PROFILE_ARGS); do \
		$(BASH_BIN) $(APPLY_TIER) "profiles/$$a" || failed="$$failed $$a"; \
	done; \
	if [ -n "$$failed" ]; then \
		echo; \
		echo "==> The following profiles failed (brew bundle or a post_install action returned non-zero):" >&2; \
		for s in $$failed; do echo "  - $$s" >&2; done; \
		exit 1; \
	fi

profiles: ## List every profile in the repo, marking the ones this host opts into
	@echo "Profiles in this repo (* = in this host's profiles array, in order):"
	@for p in $(KNOWN_PROFILES); do \
		mark="  "; \
		case " $(PROFILES) " in *" $$p "*) mark=" *";; esac; \
		echo "$$mark $$p"; \
	done
	@echo
	@echo "This host applies, in order: $(CORE_TIER) $(addprefix profiles/,$(PROFILES)) <host tier>"
	@echo "Apply some by hand with: make profile <name> [<name>...]"

# --- Removal loops ---
#
# Each walks every tier for this host, in tier order, invoking the shared
# scripts/remove_runner.sh once per tier. The runner reads that tier's
# `[profile] uninstall` (--mode=uninstall) or `[profile] purge`
# (--mode=purge) array. Purge mode adds --zap on cask uninstalls, so the
# cask's declared user data goes too.
#
# The `==> Applying ...` banner is passed to the runner via --banner=<text>
# rather than echoed here (issue #167), so the runner — the only code that
# reads the array — can suppress the banner together with its own
# Processing/Done lines for a tier that removes nothing, when VERBOSE is
# unset. Banner and runner lines stay in lockstep: a tier prints all of them
# or none of them.

uninstall: ## Apply every tier's [profile] uninstall array, in tier order
	@set -euo pipefail
	@$(MAKE) -s _uninstall_loop UNINSTALL_DRY_RUN=

uninstall-dry-run: ## Print what `make uninstall` would do without making any changes
	@set -euo pipefail
	@$(MAKE) -s _uninstall_loop UNINSTALL_DRY_RUN=--dry-run

.PHONY: _uninstall_loop
_uninstall_loop:
	@set -uo pipefail; \
	for tier in $(TIERS); do \
		case " $(REMOVE_SKIP_TIERS) " in *" $$tier "*) continue;; esac; \
		$(BASH_BIN) $(REMOVE_RUNNER) "$$tier" --mode=uninstall \
			--banner="==> Applying Uninstall: $$tier" $(UNINSTALL_DRY_RUN); \
	done; \
	echo "All tiers' uninstall arrays processed."

remove-and-purge: ## Apply every tier's [profile] purge array, in tier order (--zap casks)
	@set -euo pipefail
	@$(MAKE) -s _remove_and_purge_loop PURGE_DRY_RUN=

remove-and-purge-dry-run: ## Print what `make remove-and-purge` would do without making any changes
	@set -euo pipefail
	@$(MAKE) -s _remove_and_purge_loop PURGE_DRY_RUN=--dry-run

.PHONY: _remove_and_purge_loop
_remove_and_purge_loop:
	@set -uo pipefail; \
	for tier in $(TIERS); do \
		case " $(REMOVE_SKIP_TIERS) " in *" $$tier "*) continue;; esac; \
		$(BASH_BIN) $(REMOVE_RUNNER) "$$tier" --mode=purge \
			--banner="==> Applying RemoveAndPurge: $$tier" $(PURGE_DRY_RUN); \
	done; \
	echo "All tiers' purge arrays processed."

# Note: the sed pattern extracting cask names from "already an App" errors depends on
# Homebrew's "Error: <cask>: ..." format. If it changes, unmatched errors safely fall
# through to the generic error check which sets FAIL=1.
#
# `update` also completes the asdf -> mise cutover end to end: it applies the
# version-managers tier (which is what puts `mise` on a host that has never
# run `make install` -- `brew upgrade` upgrades an installed formula but never
# installs an absent one), then the purge loop uninstalls asdf and
# direnv, then it rewrites ~/.zshrc from both sides --
# strip_asdf_zshrc_lines.sh removes the asdf/direnv init lines that would
# otherwise error on every shell startup, and ensure_mise_zshrc_lines.sh adds
# the mise shims PATH export and `mise activate zsh` that replace them.
#
# Both ~/.zshrc calls are here because `update` never runs shell_setup.sh, the
# only other writer of those lines. Without the strip the binaries would go
# while their broken init lines stayed; without the ensure (issue #38) a host
# that reaches the cutover purely via `make update` would end it with mise
# installed, asdf and direnv gone, and NO version manager wired into the
# interactive shell at all.
#
# Order is load-bearing: INSTALL BEFORE REMOVE. The install step also runs
# ahead of `versions-update`, which needs a mise to drive. If mise is still
# not reachable after the install step -- brew bundle failed, the profile is
# absent, the binary is off PATH -- the removal of asdf and direnv is skipped
# via REMOVE_SKIP_TIERS (the version-managers tier only; every other tier
# still applies) and so are BOTH ~/.zshrc rewrites, because removing the old
# version manager without a working replacement is strictly worse than
# leaving both in place -- and pointing ~/.zshrc at a mise that is not there
# would error on every shell startup, which is the failure the strip exists
# to prevent. That path warns and sets FAIL, so the run exits non-zero.
update: require-dasel ## Update Homebrew, upgrade formulae/casks/MAS/managed tool versions, then apply every tier's uninstall and purge arrays
	@FAIL=0; \
	echo "==> Updating Homebrew..."; \
	$(BREW) update || FAIL=1; \
	echo "==> Upgrading Homebrew formulae..."; \
	$(BREW) upgrade --formula || FAIL=1; \
	echo "==> Upgrading Homebrew casks (including greedy)..."; \
	CASK_OUTPUT=$$($(BREW) upgrade --cask --greedy 2>&1); CASK_EXIT=$$?; \
	echo "$$CASK_OUTPUT"; \
	if [ $$CASK_EXIT -ne 0 ]; then \
		ALREADY_APP_CASKS=$$(echo "$$CASK_OUTPUT" | grep "^Error:" | grep "already an App" | sed 's/^Error: \([^:]*\):.*/\1/'); \
		if [ -n "$$ALREADY_APP_CASKS" ]; then \
			for cask in $$ALREADY_APP_CASKS; do \
				echo "==> Retrying $$cask with reinstall (had 'already an App' conflict)..."; \
				$(BREW) reinstall --cask "$$cask" || FAIL=1; \
			done; \
		fi; \
		if echo "$$CASK_OUTPUT" | grep "^Error:" | grep -v "already an App" | grep -qv "installer manual"; then \
			FAIL=1; \
		fi; \
	fi; \
	echo "==> Upgrading Mac App Store apps..."; \
	if command -v mas >/dev/null 2>&1; then mas upgrade || FAIL=1; fi; \
	echo "==> Applying the $(VM_PROFILE) tier ($(VM_TIER))..."; \
	$(BASH_BIN) $(APPLY_TIER) "$(VM_TIER)" || FAIL=1; \
	if $(MISE_REACHABLE); then \
		VM_SKIP=""; \
	else \
		VM_SKIP="$(VM_TIER)"; \
		echo "WARNING: mise is not reachable after the install step." >&2; \
		echo "         Skipping the asdf/direnv removal ($(VM_TIER)) and the ~/.zshrc rewrites," >&2; \
		echo "         so this host is not left with no version manager at all." >&2; \
		echo "         Every other tier still applies. Fix the mise install and re-run 'make update'." >&2; \
		FAIL=1; \
	fi; \
	echo "==> Updating mise-managed tools..."; \
	$(MAKE) -s versions-update || FAIL=1; \
	echo "==> Pruning unused mise-managed versions..."; \
	$(MAKE) -s versions-cleanup || FAIL=1; \
	echo "==> Updating ~/.claude/ from the global Claude config repo..."; \
	if [ -x "scripts/claude_repo_setup.sh" ]; then $(BASH_BIN) scripts/claude_repo_setup.sh update || FAIL=1; else echo "scripts/claude_repo_setup.sh not found or not executable"; fi; \
	echo "==> Applying every tier's uninstall array..."; \
	$(MAKE) -s uninstall REMOVE_SKIP_TIERS="$$VM_SKIP" || FAIL=1; \
	echo "==> Applying every tier's purge array..."; \
	$(MAKE) -s remove-and-purge REMOVE_SKIP_TIERS="$$VM_SKIP" || FAIL=1; \
	if [ -z "$$VM_SKIP" ]; then \
		$(BASH_BIN) scripts/strip_asdf_zshrc_lines.sh || FAIL=1; \
		$(BASH_BIN) scripts/ensure_mise_zshrc_lines.sh || FAIL=1; \
	fi; \
	echo "==> All packages updated."; \
	exit $$FAIL

# `DRY_RUN=1` expands to `--dry-run` via DRY_RUN_FLAG (defined at the
# top of this file) and is forwarded to scripts/self_update.sh so
# `make self-update DRY_RUN=1` rehearses without making changes.
self-update: ## Pull latest main; auto-stash if dirty (DRY_RUN=1 to rehearse)
	@$(BASH_BIN) scripts/self_update.sh $(DRY_RUN_FLAG)

# --- Help ---
help: ## Show help for available targets
	@echo "Usage: make <target>"
	@echo
	@awk 'BEGIN {FS=":.*##"; print "Documented targets:"} /^[a-zA-Z0-9_.-]+:.*##/ {printf "  \033[36m%-32s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo
	@echo "Profiles (apply with 'make profile <name> [<name>...]'; list with 'make profiles'):"
	@printf "  %s\n" $(KNOWN_PROFILES)

# --- Version management targets ---
# Named `versions-*`, not after the tool that implements them: the previous
# `asdf-*` names baked the implementation into the public interface, so
# swapping the implementation forced every caller and doc line to change.
.PHONY: versions-install versions-update versions-outdated versions-cleanup versions-cleanup-dry-run asdf-to-mise

versions-install: ## Install the tool versions the resolved mise config declares
	@$(BASH_BIN) -lc 'if [ -x "$(VERSIONS_SETUP)" ]; then $(VERSIONS_SETUP) install; else echo "$(VERSIONS_SETUP) not found"; fi'

versions-update: ## Install latest tool versions and bump the config (mise up --bump)
	@$(BASH_BIN) -lc 'if [ -x "$(VERSIONS_SETUP)" ]; then $(VERSIONS_SETUP) update; else echo "$(VERSIONS_SETUP) not found"; fi'

versions-outdated: ## Check for outdated mise-managed tools
	@$(BASH_BIN) -lc 'if [ -x "$(VERSIONS_SETUP)" ]; then $(VERSIONS_SETUP) outdated; else echo "$(VERSIONS_SETUP) not found"; fi'

versions-cleanup: ## Prune unused installed tool versions (mise prune)
	@$(BASH_BIN) -lc 'if [ -x "$(VERSIONS_SETUP)" ]; then $(VERSIONS_SETUP) cleanup; else echo "$(VERSIONS_SETUP) not found"; fi'

versions-cleanup-dry-run: ## Show what versions-cleanup would remove
	@$(BASH_BIN) -lc 'if [ -x "$(VERSIONS_SETUP)" ]; then $(VERSIONS_SETUP) cleanup-dry-run; else echo "$(VERSIONS_SETUP) not found"; fi'

# One-shot migration verb. A deliberate exception to the
# implementation-neutral naming above: it names both endpoints on purpose,
# and it is deleted once every repo and host is over. Operates on the
# ORIGINAL call directory (START_DIR), not on macos-setup, so it can be run
# from any repo. It is purely additive: it writes mise config and warns
# about leftovers, and deletes, moves, untracks, and commits nothing.
asdf-to-mise: ## Convert the calling repo from asdf+direnv to mise (additive; deletes nothing)
	@START_DIR="$(START_DIR)" $(BASH_BIN) scripts/asdf_to_mise.sh

diagnose: ## Run system diagnostics and check installation status
	@$(BASH_BIN) ./scripts/diagnose.sh
.PHONY: diagnose

.PHONY: verify sanitize
verify: require-dasel ## Verify installations and check for same-tier Brewfile/uninstall+purge collisions
	@set -uo pipefail; FAIL=0; \
	$(BASH_BIN) ./scripts/verify.sh || FAIL=1; \
	echo; \
	echo "=== same-tier collision check ==="; \
	$(BASH_BIN) ./scripts/collision_check.sh || FAIL=1; \
	exit $$FAIL

sanitize: ## Resolve same-tier Brewfile/uninstall+purge collisions by commenting out the Brewfile line (writes .bak)
	@$(BASH_BIN) ./scripts/collision_check.sh --fix

.PHONY: outdated
outdated: require-dasel ## Check for outdated formulae, casks, MAS apps, and managed tool versions
	@echo "==> Checking for outdated packages..."
	@echo
	@echo "==> Outdated Homebrew formulae:"
	@brew outdated --formula --quiet 2>/dev/null || echo "  (none)"
	@echo
	@echo "==> Outdated Homebrew casks:"
	@brew outdated --cask --greedy --quiet 2>/dev/null || echo "  (none)"
	@echo
	@echo "==> Outdated Mac App Store apps:"
	@command -v mas >/dev/null 2>&1 && mas outdated || echo "  mas not installed"
	@echo
	@echo "==> Outdated mise-managed tools:"
	@$(MAKE) -s versions-outdated 2>/dev/null || echo "  (unable to check)"
	@echo
	@echo "==> Pending updates in ~/.claude/ (global Claude config repo):"
	@if [ -x "scripts/claude_repo_setup.sh" ]; then $(BASH_BIN) scripts/claude_repo_setup.sh outdated || true; else echo "  scripts/claude_repo_setup.sh not found or not executable"; fi
	@echo
	@echo "To update all packages, run: make update"

# --- Schedule automation targets (LaunchAgent) ---
LAUNCH_AGENTS_DIR := $(HOME)/Library/LaunchAgents
DAILY_PLIST := com.macos-setup.daily-update.plist
WEEKLY_PLIST := com.macos-setup.weekly-update.plist
EMAIL_TEST_PLIST := com.macos-setup.email-test.plist
# LaunchAgent runner location. The plist embeds this absolute path
# as ProgramArguments[0].
#
# Path chain at fire time:
#   $(HOME)/.zsh-shared             [symlink, managed by shell_setup.sh]
#       -> <repo>/shared/zsh
#   $(HOME)/.zsh-shared/launchagent_runner    [symlink, committed]
#       -> ../../scripts/launchagent_runner.sh
#       =  <repo>/scripts/launchagent_runner.sh
#
# Why two symlinks instead of `~/.zsh-shared/../scripts/...`: macOS
# (and POSIX more generally) resolves `..` *lexically* against the
# symlink path, not against the symlink target. So
# `~/.zsh-shared/../scripts/foo` resolves to `~/scripts/foo`, not
# `<repo>/scripts/foo`. A relative-target symlink inside
# `shared/zsh/` sidesteps that by giving the kernel a path it can
# resolve fully through the filesystem.
#
# Why this matters (issue #133): future repo moves only require
# `~/.zsh-shared` to be updated (which `make shell_setup` already does),
# with no re-run of `make schedule-*` needed.
LAUNCHAGENT_RUNNER := $(HOME)/.zsh-shared/launchagent_runner
LAUNCHAGENT_LOG_DIR := $(HOME)/Library/Logs/macos-setup

.PHONY: schedule-daily schedule-weekly schedule-now unschedule-all schedule-list email-test schedule-email-test

schedule-list: ## Show currently installed update LaunchAgents and their status
	@for PLIST_NAME in "$(DAILY_PLIST)" "$(WEEKLY_PLIST)" "com.macos-setup.now-update.plist" "$(EMAIL_TEST_PLIST)"; do \
		LABEL="$${PLIST_NAME%.plist}"; \
		PLIST_PATH="$(LAUNCH_AGENTS_DIR)/$$PLIST_NAME"; \
		if [ -f "$$PLIST_PATH" ]; then \
			if launchctl list "$$LABEL" >/dev/null 2>&1; then \
				STATUS="loaded"; \
			else \
				STATUS="installed but not loaded"; \
			fi; \
			HOUR=$$(/usr/libexec/PlistBuddy -c "Print :StartCalendarInterval:Hour" "$$PLIST_PATH" 2>/dev/null); \
			MINUTE=$$(/usr/libexec/PlistBuddy -c "Print :StartCalendarInterval:Minute" "$$PLIST_PATH" 2>/dev/null); \
			WEEKDAY=$$(/usr/libexec/PlistBuddy -c "Print :StartCalendarInterval:Weekday" "$$PLIST_PATH" 2>/dev/null); \
			if [ -n "$$WEEKDAY" ]; then \
				SCHEDULE="Sundays at $$(printf '%02d:%02d' "$$HOUR" "$$MINUTE")"; \
			else \
				SCHEDULE="Daily at $$(printf '%02d:%02d' "$$HOUR" "$$MINUTE")"; \
			fi; \
			PROG=$$(/usr/libexec/PlistBuddy -c "Print :ProgramArguments:0" "$$PLIST_PATH" 2>/dev/null); \
			if echo "$$PROG" | grep -q launchagent_runner; then \
				MODE_ARG=$$(/usr/libexec/PlistBuddy -c "Print :ProgramArguments:2" "$$PLIST_PATH" 2>/dev/null); \
				if [ "$$MODE_ARG" = "--mail" ]; then \
					MAILTO=$$(/usr/libexec/PlistBuddy -c "Print :ProgramArguments:3" "$$PLIST_PATH" 2>/dev/null); \
					EMAIL="email to $$MAILTO"; \
				else \
					EMAIL="no email (log only)"; \
				fi; \
			elif echo "$$PROG" | grep -q mail_wrapper; then \
				MAILTO=$$(/usr/libexec/PlistBuddy -c "Print :ProgramArguments:1" "$$PLIST_PATH" 2>/dev/null); \
				EMAIL="email to $$MAILTO (legacy plist; re-run schedule-* to upgrade)"; \
			else \
				EMAIL="no email (log only)"; \
			fi; \
			echo "  $$LABEL: $$STATUS | $$SCHEDULE | $$EMAIL"; \
		else \
			echo "  $${PLIST_NAME%.plist}: not installed"; \
		fi; \
	done
schedule-daily: ## Schedule daily automatic update at 4am via LaunchAgent (email if [cron] mailto configured)
	@echo "Setting up daily LaunchAgent for make update at 4am..."
	@MAILTO=$$(scripts/resolve_mailto.sh) || exit 1; \
	PLIST="$(LAUNCH_AGENTS_DIR)/$(DAILY_PLIST)"; \
	mkdir -p "$(LAUNCH_AGENTS_DIR)"; \
	mkdir -p "$(LAUNCHAGENT_LOG_DIR)"; \
	launchctl bootout gui/$$(id -u) "$$PLIST" 2>/dev/null || true; \
	rm -f "$$PLIST"; \
	/usr/libexec/PlistBuddy -c "Clear dict" "$$PLIST"; \
	/usr/libexec/PlistBuddy -c "Add :Label string com.macos-setup.daily-update" "$$PLIST"; \
	/usr/libexec/PlistBuddy -c "Add :ProgramArguments array" "$$PLIST"; \
	/usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string $(LAUNCHAGENT_RUNNER)" "$$PLIST"; \
	/usr/libexec/PlistBuddy -c "Add :ProgramArguments:1 string daily-update" "$$PLIST"; \
	if [ -n "$$MAILTO" ]; then \
		echo "Email notifications enabled: $$MAILTO"; \
		/usr/libexec/PlistBuddy -c "Add :ProgramArguments:2 string --mail" "$$PLIST"; \
		/usr/libexec/PlistBuddy -c "Add :ProgramArguments:3 string $$MAILTO" "$$PLIST"; \
		/usr/libexec/PlistBuddy -c "Add :ProgramArguments:4 string macos-setup daily update" "$$PLIST"; \
		/usr/libexec/PlistBuddy -c "Add :ProgramArguments:5 string --" "$$PLIST"; \
		/usr/libexec/PlistBuddy -c "Add :ProgramArguments:6 string make" "$$PLIST"; \
		/usr/libexec/PlistBuddy -c "Add :ProgramArguments:7 string update" "$$PLIST"; \
	else \
		echo "No mailto configured — output to log only"; \
		/usr/libexec/PlistBuddy -c "Add :ProgramArguments:2 string --" "$$PLIST"; \
		/usr/libexec/PlistBuddy -c "Add :ProgramArguments:3 string make" "$$PLIST"; \
		/usr/libexec/PlistBuddy -c "Add :ProgramArguments:4 string update" "$$PLIST"; \
	fi; \
	/usr/libexec/PlistBuddy -c "Add :StartCalendarInterval dict" "$$PLIST"; \
	/usr/libexec/PlistBuddy -c "Add :StartCalendarInterval:Hour integer 4" "$$PLIST"; \
	/usr/libexec/PlistBuddy -c "Add :StartCalendarInterval:Minute integer 0" "$$PLIST"; \
	/usr/libexec/PlistBuddy -c "Add :EnvironmentVariables dict" "$$PLIST"; \
	/usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:PATH string /opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" "$$PLIST"; \
	launchctl bootstrap gui/$$(id -u) "$$PLIST"; \
	echo "Daily LaunchAgent installed and loaded: $$PLIST"; \
	echo "Logs: $(LAUNCHAGENT_LOG_DIR)/daily-update.log"

schedule-weekly: ## Schedule weekly automatic update on Sundays at 11am via LaunchAgent (email if [cron] mailto configured)
	@echo "Setting up weekly LaunchAgent for make update on Sundays at 11am..."
	@MAILTO=$$(scripts/resolve_mailto.sh) || exit 1; \
	PLIST="$(LAUNCH_AGENTS_DIR)/$(WEEKLY_PLIST)"; \
	mkdir -p "$(LAUNCH_AGENTS_DIR)"; \
	mkdir -p "$(LAUNCHAGENT_LOG_DIR)"; \
	launchctl bootout gui/$$(id -u) "$$PLIST" 2>/dev/null || true; \
	rm -f "$$PLIST"; \
	/usr/libexec/PlistBuddy -c "Clear dict" "$$PLIST"; \
	/usr/libexec/PlistBuddy -c "Add :Label string com.macos-setup.weekly-update" "$$PLIST"; \
	/usr/libexec/PlistBuddy -c "Add :ProgramArguments array" "$$PLIST"; \
	/usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string $(LAUNCHAGENT_RUNNER)" "$$PLIST"; \
	/usr/libexec/PlistBuddy -c "Add :ProgramArguments:1 string weekly-update" "$$PLIST"; \
	if [ -n "$$MAILTO" ]; then \
		echo "Email notifications enabled: $$MAILTO"; \
		/usr/libexec/PlistBuddy -c "Add :ProgramArguments:2 string --mail" "$$PLIST"; \
		/usr/libexec/PlistBuddy -c "Add :ProgramArguments:3 string $$MAILTO" "$$PLIST"; \
		/usr/libexec/PlistBuddy -c "Add :ProgramArguments:4 string macos-setup weekly update" "$$PLIST"; \
		/usr/libexec/PlistBuddy -c "Add :ProgramArguments:5 string --" "$$PLIST"; \
		/usr/libexec/PlistBuddy -c "Add :ProgramArguments:6 string make" "$$PLIST"; \
		/usr/libexec/PlistBuddy -c "Add :ProgramArguments:7 string update" "$$PLIST"; \
	else \
		echo "No mailto configured — output to log only"; \
		/usr/libexec/PlistBuddy -c "Add :ProgramArguments:2 string --" "$$PLIST"; \
		/usr/libexec/PlistBuddy -c "Add :ProgramArguments:3 string make" "$$PLIST"; \
		/usr/libexec/PlistBuddy -c "Add :ProgramArguments:4 string update" "$$PLIST"; \
	fi; \
	/usr/libexec/PlistBuddy -c "Add :StartCalendarInterval dict" "$$PLIST"; \
	/usr/libexec/PlistBuddy -c "Add :StartCalendarInterval:Weekday integer 0" "$$PLIST"; \
	/usr/libexec/PlistBuddy -c "Add :StartCalendarInterval:Hour integer 11" "$$PLIST"; \
	/usr/libexec/PlistBuddy -c "Add :StartCalendarInterval:Minute integer 0" "$$PLIST"; \
	/usr/libexec/PlistBuddy -c "Add :EnvironmentVariables dict" "$$PLIST"; \
	/usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:PATH string /opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" "$$PLIST"; \
	launchctl bootstrap gui/$$(id -u) "$$PLIST"; \
	echo "Weekly LaunchAgent installed and loaded: $$PLIST"; \
	echo "Logs: $(LAUNCHAGENT_LOG_DIR)/weekly-update.log"

unschedule-all: ## Remove all macos-setup LaunchAgents (daily, weekly, one-time)
	@for PLIST_NAME in "$(DAILY_PLIST)" "$(WEEKLY_PLIST)" "com.macos-setup.now-update.plist" "$(EMAIL_TEST_PLIST)"; do \
		PLIST_PATH="$(LAUNCH_AGENTS_DIR)/$$PLIST_NAME"; \
		LABEL="$${PLIST_NAME%.plist}"; \
		if [ -f "$$PLIST_PATH" ]; then \
			launchctl bootout gui/$$(id -u) "$$PLIST_PATH" 2>/dev/null || true; \
			/bin/rm -f "$$PLIST_PATH"; \
			echo "Removed $$LABEL"; \
		fi; \
	done; \
	echo "All macos-setup LaunchAgents removed"

schedule-now: ## Schedule a one-time update to run in 2 minutes (for debugging)
	@MAILTO=$$(scripts/resolve_mailto.sh) || exit 1; \
	PLIST="$(LAUNCH_AGENTS_DIR)/com.macos-setup.now-update.plist"; \
	mkdir -p "$(LAUNCH_AGENTS_DIR)"; \
	mkdir -p "$(LAUNCHAGENT_LOG_DIR)"; \
	launchctl bootout gui/$$(id -u) "$$PLIST" 2>/dev/null || true; \
	/bin/rm -f "$$PLIST"; \
	TARGET_MIN=$$(date -v+2M +%M); \
	TARGET_HOUR=$$(date -v+2M +%H); \
	/usr/libexec/PlistBuddy -c "Clear dict" "$$PLIST"; \
	/usr/libexec/PlistBuddy -c "Add :Label string com.macos-setup.now-update" "$$PLIST"; \
	/usr/libexec/PlistBuddy -c "Add :ProgramArguments array" "$$PLIST"; \
	/usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string $(LAUNCHAGENT_RUNNER)" "$$PLIST"; \
	/usr/libexec/PlistBuddy -c "Add :ProgramArguments:1 string now-update" "$$PLIST"; \
	if [ -n "$$MAILTO" ]; then \
		echo "Email notifications enabled: $$MAILTO"; \
		/usr/libexec/PlistBuddy -c "Add :ProgramArguments:2 string --mail" "$$PLIST"; \
		/usr/libexec/PlistBuddy -c "Add :ProgramArguments:3 string $$MAILTO" "$$PLIST"; \
		/usr/libexec/PlistBuddy -c "Add :ProgramArguments:4 string macos-setup now update" "$$PLIST"; \
		/usr/libexec/PlistBuddy -c "Add :ProgramArguments:5 string --" "$$PLIST"; \
		/usr/libexec/PlistBuddy -c "Add :ProgramArguments:6 string make" "$$PLIST"; \
		/usr/libexec/PlistBuddy -c "Add :ProgramArguments:7 string update" "$$PLIST"; \
	else \
		echo "No mailto configured — output to log only"; \
		/usr/libexec/PlistBuddy -c "Add :ProgramArguments:2 string --" "$$PLIST"; \
		/usr/libexec/PlistBuddy -c "Add :ProgramArguments:3 string make" "$$PLIST"; \
		/usr/libexec/PlistBuddy -c "Add :ProgramArguments:4 string update" "$$PLIST"; \
	fi; \
	/usr/libexec/PlistBuddy -c "Add :StartCalendarInterval dict" "$$PLIST"; \
	/usr/libexec/PlistBuddy -c "Add :StartCalendarInterval:Hour integer $$TARGET_HOUR" "$$PLIST"; \
	/usr/libexec/PlistBuddy -c "Add :StartCalendarInterval:Minute integer $$TARGET_MIN" "$$PLIST"; \
	/usr/libexec/PlistBuddy -c "Add :EnvironmentVariables dict" "$$PLIST"; \
	/usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:PATH string /opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" "$$PLIST"; \
	launchctl bootstrap gui/$$(id -u) "$$PLIST"; \
	echo "One-time update scheduled at $$(printf '%d:%02d' $$TARGET_HOUR $$TARGET_MIN) — remove with: make unschedule-all"; \
	echo "Logs: $(LAUNCHAGENT_LOG_DIR)/now-update.log"

email-test: ## Send a test email to verify email configuration works
	@MAILTO=$$(scripts/resolve_mailto.sh) || exit 1; \
	if [ -z "$$MAILTO" ]; then \
		echo "Error: No [cron] mailto configured. Set mailto under [cron] in your config.toml (host or profile tier)." >&2; \
		exit 1; \
	fi; \
	HOSTNAME=$$(hostname -s); \
	FROM=$$(scripts/resolve_from.sh) || true; \
	echo "Sending test email to $$MAILTO..."; \
	{ \
		echo "From: $${FROM:-noreply@localhost}"; \
		echo "To: $$MAILTO"; \
		echo "Subject: macos-setup email test from $$HOSTNAME [OK]"; \
		echo "Date: $$(date -R 2>/dev/null || date '+%a, %d %b %Y %H:%M:%S %z')"; \
		echo "Content-Type: text/plain; charset=UTF-8"; \
		echo "X-Mailer: macos-setup email-test"; \
		echo ""; \
		echo "This is a test email from macos-setup on $$HOSTNAME."; \
		echo "Timestamp: $$(date '+%Y-%m-%d %H:%M:%S %Z')"; \
		echo ""; \
		echo "If you received this, your email configuration is working correctly."; \
	} | scripts/send_mail.sh "$$MAILTO" || { echo "Failed to send test email" >&2; exit 1; }; \
	echo "Test email sent successfully to $$MAILTO"

schedule-email-test: ## Schedule a test email to send in 2 minutes via LaunchAgent (tests full pipeline)
	@MAILTO=$$(scripts/resolve_mailto.sh) || exit 1; \
	if [ -z "$$MAILTO" ]; then \
		echo "Error: No [cron] mailto configured. Set mailto under [cron] in your config.toml (host or profile tier)." >&2; \
		exit 1; \
	fi; \
	PLIST="$(LAUNCH_AGENTS_DIR)/$(EMAIL_TEST_PLIST)"; \
	mkdir -p "$(LAUNCH_AGENTS_DIR)"; \
	mkdir -p "$(LAUNCHAGENT_LOG_DIR)"; \
	launchctl bootout gui/$$(id -u) "$$PLIST" 2>/dev/null || true; \
	/bin/rm -f "$$PLIST"; \
	TARGET_MIN=$$(date -v+2M +%M); \
	TARGET_HOUR=$$(date -v+2M +%H); \
	/usr/libexec/PlistBuddy -c "Clear dict" "$$PLIST"; \
	/usr/libexec/PlistBuddy -c "Add :Label string com.macos-setup.email-test" "$$PLIST"; \
	/usr/libexec/PlistBuddy -c "Add :ProgramArguments array" "$$PLIST"; \
	/usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string $(LAUNCHAGENT_RUNNER)" "$$PLIST"; \
	/usr/libexec/PlistBuddy -c "Add :ProgramArguments:1 string email-test" "$$PLIST"; \
	/usr/libexec/PlistBuddy -c "Add :ProgramArguments:2 string --mail" "$$PLIST"; \
	/usr/libexec/PlistBuddy -c "Add :ProgramArguments:3 string $$MAILTO" "$$PLIST"; \
	/usr/libexec/PlistBuddy -c "Add :ProgramArguments:4 string macos-setup email test" "$$PLIST"; \
	/usr/libexec/PlistBuddy -c "Add :ProgramArguments:5 string --" "$$PLIST"; \
	/usr/libexec/PlistBuddy -c "Add :ProgramArguments:6 string echo" "$$PLIST"; \
	/usr/libexec/PlistBuddy -c "Add :ProgramArguments:7 string Email pipeline test successful" "$$PLIST"; \
	/usr/libexec/PlistBuddy -c "Add :StartCalendarInterval dict" "$$PLIST"; \
	/usr/libexec/PlistBuddy -c "Add :StartCalendarInterval:Hour integer $$TARGET_HOUR" "$$PLIST"; \
	/usr/libexec/PlistBuddy -c "Add :StartCalendarInterval:Minute integer $$TARGET_MIN" "$$PLIST"; \
	/usr/libexec/PlistBuddy -c "Add :EnvironmentVariables dict" "$$PLIST"; \
	/usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:PATH string /opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" "$$PLIST"; \
	launchctl bootstrap gui/$$(id -u) "$$PLIST"; \
	echo "Test email scheduled at $$(printf '%d:%02d' $$TARGET_HOUR $$TARGET_MIN) to $$MAILTO"; \
	echo "Check $(LAUNCHAGENT_LOG_DIR)/email-test.log after it fires to verify it worked"; \
	echo "Remove with: make unschedule-all"

.PHONY: mas_search_msoffice
mas_search_msoffice: ## Search Mac App Store for Microsoft Office apps
	@echo "Searching MAS for Microsoft Office apps..."
	@mas search "Microsoft Word" | grep -i "microsoft word" || true
	@mas search "Microsoft Excel" | grep -i "microsoft excel" || true
	@mas search "Microsoft PowerPoint" | grep -i "microsoft powerpoint" || true
	@mas search "Microsoft Outlook" | grep -i "microsoft outlook" || true
	@mas search "Microsoft OneNote" | grep -i "microsoft onenote" || true
