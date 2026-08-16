# Makefile — dynamic, tailored to Install/ files named like "NN-Install.suffix"
# (formerly Brewfiles, "NN-Brewfile.suffix"). Parallel Uninstall/ and
# RemoveAndPurge/ trees drive `make uninstall` / `make remove-and-purge` and a
# smart filter on `make install`.

# Default target - show help when no target is specified
.DEFAULT_GOAL := help
# Special cases:
#   - 00-Install.core            : sets up computer names and /etc/hostname
#   - 02-Install.ui              : sets up Hammerspoon configuration and modules
#   - 03-Install.shell           : sets up shell and computer-specific aliases
#   - 04-Install.versionmanagers : sets up mise and installs pinned tool versions
#   - 06-Install.messaging       : sets up msmtp configuration
#   - 09-Install.development     : sets up VSCode extensions and configuration

SHELL := /bin/bash
START_DIR ?= $(CURDIR)
.ONESHELL:
.NOTPARALLEL:

# --- Config ---
BREW ?= $(shell command -v brew 2>/dev/null || echo /opt/homebrew/bin/brew)
INSTALL_DIR := Install
UNINSTALL_DIR := Uninstall
PURGE_DIR := RemoveAndPurge
ORDERED_INSTALL_FILES   := $(sort $(wildcard $(INSTALL_DIR)/*-Install.*))
INSTALL_BASENAMES       := $(notdir $(ORDERED_INSTALL_FILES))
ORDERED_UNINSTALL_FILES := $(sort $(wildcard $(UNINSTALL_DIR)/*-Uninstall.*))
UNINSTALL_BASENAMES     := $(notdir $(ORDERED_UNINSTALL_FILES))
ORDERED_PURGE_FILES     := $(sort $(wildcard $(PURGE_DIR)/*-RemoveAndPurge.*))
PURGE_BASENAMES         := $(notdir $(ORDERED_PURGE_FILES))
COMPUTER_NAME_LOWER := $(shell scutil --get LocalHostName 2>/dev/null | tr '[:upper:]' '[:lower:]' | sed 's/\.local$$//' || hostname -s | tr '[:upper:]' '[:lower:]')
# The per-host tier now lives OUTSIDE the repo (see host_tier_dir in
# scripts/config_common.sh). Resolve its base path once here so all the
# host-tier Install/Uninstall/RemoveAndPurge walks point at it. The path
# is overridable via the MACOS_SETUP_HOST_DIR env var (used by tests);
# the default is $${XDG_CONFIG_HOME:-$$HOME/.config}/macos-setup.
# Delegated to a script (rather than inlined) for the same reason as
# PROFILES below: keep host-path logic in one place (config_common.sh).
HOST_DIR := $(shell bash scripts/host_tier_dir.sh 2>/dev/null)
COMPUTER_SPECIFIC_DIR   := $(HOST_DIR)/$(INSTALL_DIR)
COMPUTER_UNINSTALL_DIR  := $(HOST_DIR)/$(UNINSTALL_DIR)
COMPUTER_PURGE_DIR      := $(HOST_DIR)/$(PURGE_DIR)
# Ordered profile list for this host (lowest priority first), read from
# the `profiles` array in the external host tier's `config.toml`
# (default-tier array prepended; dedup keeps last). A host with no
# `profiles` array yields an empty list (zero-profile host:
# default < host). Profile config dirs are derived per-profile inside
# the shell loops below, as `profiles/<name>/{Install,...}`.
# Parsing is delegated to scripts/list_profiles.sh (which reuses
# get_profiles in config_common.sh, querying config.toml via dasel)
# rather than inlined here.
PROFILES := $(shell bash scripts/list_profiles.sh 2>/dev/null)

INSTALL_FILTER := scripts/install_filter.sh
REMOVE_RUNNER  := scripts/remove_runner.sh

# Verbose-gated echo for the Install tier walk (issue #164). The per-slot
# tier loop probes every profile and the host tier for an Install file;
# in the common case most tiers contribute nothing, and echoing a
# "No ... Install found" line for each one buries the real signal under
# hundreds of noise lines on a host that opts into many profiles. Gate
# those negative-case lines behind VERBOSE: a default `make install`
# (VERBOSE unset/empty) stays quiet about non-contributing tiers, while
# `VERBOSE=1 make install` restores the per-tier "not found" detail for
# debugging "why didn't my profile apply?". The POSITIVE "Found ..."
# echoes always print regardless of VERBOSE.
#
# Shared by BOTH Install code paths — the APPLY_INSTALL_TIERS macro (used
# by every per-slot named target) and the `install` batch loop — so the
# two cannot drift. Expands to a shell `if` that takes one argument: the
# message to echo. `${VERBOSE:-}` supplies a default so the conditional
# is safe under the `set -u` both paths run with (an unset VERBOSE does
# not error).
VERBOSE_NOTE = if [ -n "$${VERBOSE:-}" ]; then echo

# Per-file dry-run plumbing. Setting `DRY_RUN=1` on the command line
# (e.g. `make 02_RemoveAndPurge_ui DRY_RUN=1`) expands to `--dry-run`
# and is forwarded to the runner by the per-file Uninstall/Purge
# targets via the GEN_*_TARGET generators below. Empty by default,
# so unset behavior is unchanged. The batch loops use their own
# UNINSTALL_DRY_RUN / PURGE_DRY_RUN variables driven by the
# `*-dry-run` targets and do not consult DRY_RUN.
DRY_RUN_FLAG := $(if $(DRY_RUN),--dry-run,)

# --- Version manager ---
# The `versions-*` targets are implementation-neutral by design: the tool
# they drive lives behind scripts/versions_setup.sh, so swapping it again
# leaves the public interface — target names, aliases, doc lines — alone.
# The swap is bounded, not one-file: the tool is also named directly in
# scripts/mise_common.sh, scripts/shell_setup.sh (the ~/.zshrc init lines),
# scripts/launchagent_runner.sh (the shims PATH) and scripts/diagnose.sh.
# Both the version-manager script and the migration script guard on
# `command -v mise` themselves, so there is no bootstrap macro here.
VERSIONS_SETUP := scripts/versions_setup.sh

# Helpers
CANON      = $(subst -,_,$(subst .,_,$(1)))
CANONLIST  = $(foreach x,$(1),$(call CANON,$(x)))

# Combined per-slot apply helper. Runs all THREE tiers for a single
# Install slot — default, then each profile in the host's order, then
# the computer-specific tier — inside ONE shell so a `brew bundle`
# failure on an earlier tier does NOT abort the later tiers. (This
# replaces three separate per-tier helpers that were each their own
# recipe line / shell; as separate lines, make stops the target after
# the first one that exits non-zero, skipping the rest. Keeping the
# whole slot in a single accumulator avoids that.) Failures across all
# three tiers are collected into `failed`; after every tier is
# attempted, if anything failed the macro prints an end-of-run summary
# naming each failed slot and exits non-zero. A clean slot exits 0 with
# no summary. Mirrors the per-slot body of the `install` batch loop.
# Caller passes the Install file BASENAME (e.g. "02-Install.ui").
define APPLY_INSTALL_TIERS
	@set -euo pipefail; \
	failed=""; \
	echo "==> Applying $(INSTALL_DIR)/$(1) (filtered)"; \
	tmp="$$($(INSTALL_FILTER) "$(INSTALL_DIR)/$(1)")"; \
	if $(BREW) bundle --file="$$tmp"; then :; else failed="$$failed $(INSTALL_DIR)/$(1)"; fi; \
	rm -f "$$tmp"; \
	for prof in $(PROFILES); do \
		pf="profiles/$$prof/$(INSTALL_DIR)/$(1)"; \
		if [ -f "$$pf" ]; then \
			echo "==> Found profile Install: $$pf"; \
			tmp="$$($(INSTALL_FILTER) "$$pf")"; \
			if $(BREW) bundle --file="$$tmp"; then :; else failed="$$failed $$pf"; fi; \
			rm -f "$$tmp"; \
		else \
			$(VERBOSE_NOTE) "==> No profile Install found at $$pf"; fi; \
		fi; \
	done; \
	computer_install="$(COMPUTER_SPECIFIC_DIR)/$(1)"; \
	if [ -f "$$computer_install" ]; then \
		echo "==> Found computer-specific Install: $$computer_install"; \
		tmp="$$($(INSTALL_FILTER) "$$computer_install")"; \
		if $(BREW) bundle --file="$$tmp"; then :; else failed="$$failed $$computer_install"; fi; \
		rm -f "$$tmp"; \
	else \
		$(VERBOSE_NOTE) "==> No computer-specific Install found at $$computer_install"; fi; \
	fi; \
	if [ -n "$$failed" ]; then \
		echo "==> The following Install slots failed (brew bundle returned non-zero):"; \
		for s in $$failed; do echo "  - $$s"; done; \
		echo "All other tiers for this slot were applied. Re-run after resolving the above."; \
		exit 1; \
	fi
endef

# Uninstall helpers — global, profile, computer. Each runs the runner only
# if a matching Uninstall file exists at that tier. The runner is the
# shared scripts/remove_runner.sh; --mode=uninstall preserves the
# previous behavior (no --zap on casks).
#
# The `==> Applying ...` banner is NOT echoed here anymore (issue #167);
# it is passed to the runner via --banner=<text> so the runner — the only
# code that reads the file — can suppress the banner together with its own
# Processing/Done lines for an empty slot (no active brew/cask/mas
# directive) when VERBOSE is unset. This keeps the banner and the runner
# lines in lockstep: a slot+tier prints all of them or none of them.
define RUN_GLOBAL_UNINSTALL
	@set -euo pipefail; \
	if [ -f "$(UNINSTALL_DIR)/$(1)" ]; then \
		bash $(REMOVE_RUNNER) "$(UNINSTALL_DIR)/$(1)" --mode=uninstall --banner="==> Applying global Uninstall: $(UNINSTALL_DIR)/$(1)" $(2); \
	fi
endef

define RUN_PROFILE_UNINSTALL
	@set -euo pipefail; \
	for prof in $(PROFILES); do \
		pf="profiles/$$prof/$(UNINSTALL_DIR)/$(1)"; \
		if [ -f "$$pf" ]; then \
			bash $(REMOVE_RUNNER) "$$pf" --mode=uninstall --banner="==> Applying profile Uninstall: $$pf" $(2); \
		fi; \
	done
endef

define RUN_COMPUTER_UNINSTALL
	@set -euo pipefail; \
	if [ -f "$(COMPUTER_UNINSTALL_DIR)/$(1)" ]; then \
		bash $(REMOVE_RUNNER) "$(COMPUTER_UNINSTALL_DIR)/$(1)" --mode=uninstall --banner="==> Applying computer-specific Uninstall: $(COMPUTER_UNINSTALL_DIR)/$(1)" $(2); \
	fi
endef

# RemoveAndPurge helpers — same shape as the Uninstall helpers but pass
# --mode=purge so casks are uninstalled with --zap (also removes the
# cask's declared user data: preferences, caches, login items). Banner is
# passed via --banner=<text> for the same issue #167 reason as above.
define RUN_GLOBAL_PURGE
	@set -euo pipefail; \
	if [ -f "$(PURGE_DIR)/$(1)" ]; then \
		bash $(REMOVE_RUNNER) "$(PURGE_DIR)/$(1)" --mode=purge --banner="==> Applying global RemoveAndPurge: $(PURGE_DIR)/$(1)" $(2); \
	fi
endef

define RUN_PROFILE_PURGE
	@set -euo pipefail; \
	for prof in $(PROFILES); do \
		pf="profiles/$$prof/$(PURGE_DIR)/$(1)"; \
		if [ -f "$$pf" ]; then \
			bash $(REMOVE_RUNNER) "$$pf" --mode=purge --banner="==> Applying profile RemoveAndPurge: $$pf" $(2); \
		fi; \
	done
endef

define RUN_COMPUTER_PURGE
	@set -euo pipefail; \
	if [ -f "$(COMPUTER_PURGE_DIR)/$(1)" ]; then \
		bash $(REMOVE_RUNNER) "$(COMPUTER_PURGE_DIR)/$(1)" --mode=purge --banner="==> Applying computer-specific RemoveAndPurge: $(COMPUTER_PURGE_DIR)/$(1)" $(2); \
	fi
endef

# Aliases (pure GNU Make)
SEQ_ALIASES := $(sort $(foreach b,$(INSTALL_BASENAMES),$(word 1,$(subst -, ,$(b)))))
SUF_ALIASES := $(sort $(foreach b,$(INSTALL_BASENAMES),$(patsubst .%,%,$(suffix $(b)))))

# --- Finder defaults (quiet, non-fatal) ---
.PHONY: finder_defaults
finder_defaults: ## Set Finder to List view & show hidden files; purge .DS_Store; relaunch Finder
	@set -euo pipefail
	defaults write com.apple.finder AppleShowAllFiles -bool true 2>/dev/null || true
	defaults write com.apple.finder FXPreferredViewStyle -string "Nlsv" 2>/dev/null || true
	find "$$HOME" -name ".DS_Store" -type f -delete 2>/dev/null || true
	# sudo find /Volumes -name ".DS_Store" -type f -delete 2>/dev/null || true
	killall Finder 2>/dev/null || true
	@echo "Finder defaults applied."

# --- Shell setup (runs after 03-Install.shell) ---
.PHONY: shell_setup
shell_setup: ## Configure zsh, Oh My Zsh, theme, plugins, aliases (idempotent)
	@set -euo pipefail
	bash scripts/shell_setup.sh

# --- Per-Install targets (auto-generated, excluding special-cased ones) ---
CORE_INSTALL  := 00-Install.core
UI_INSTALL    := 02-Install.ui
SHELL_INSTALL := 03-Install.shell
VM_INSTALL    := 04-Install.versionmanagers
DEV_INSTALL   := 09-Install.development
MSG_INSTALL   := 06-Install.messaging
AWS_INSTALL   := 11-Install.aws
AI_INSTALL    := 17-Install.ai
INSTALL_NO_SPECIAL := $(filter-out $(CORE_INSTALL) $(UI_INSTALL) $(SHELL_INSTALL) $(VM_INSTALL) $(MSG_INSTALL) $(DEV_INSTALL) $(AWS_INSTALL) $(AI_INSTALL),$(INSTALL_BASENAMES))

define GEN_INSTALL_TARGET
$(call CANON,$(1)): ## Apply $(INSTALL_DIR)/$(1) (filtered), profile and computer-specific versions if they exist
	$$(call APPLY_INSTALL_TIERS,$(1))
endef
$(foreach b,$(INSTALL_NO_SPECIAL),$(eval $(call GEN_INSTALL_TARGET,$(b))))

# Mark every auto-generated and special-cased per-Install target .PHONY.
# These targets share the name of an Install file but never produce a
# file artefact themselves; they always run.
.PHONY: $(call CANONLIST,$(INSTALL_BASENAMES))

# Special cases
00_Install_core: ## Apply $(INSTALL_DIR)/$(CORE_INSTALL) and setup computer names
	$(call APPLY_INSTALL_TIERS,$(CORE_INSTALL))
	@bash -lc 'if [ -x "scripts/core_setup.sh" ]; then scripts/core_setup.sh; else echo "[core] scripts/core_setup.sh not found or not executable"; fi'

02_Install_ui: ## Apply $(INSTALL_DIR)/$(UI_INSTALL) and setup Hammerspoon
	$(call APPLY_INSTALL_TIERS,$(UI_INSTALL))
	@bash -lc 'if [ -x "scripts/hammerspoon_setup.sh" ]; then scripts/hammerspoon_setup.sh; else echo "[hammerspoon] scripts/hammerspoon_setup.sh not found or not executable"; fi'

03_Install_shell: ## Apply $(INSTALL_DIR)/$(SHELL_INSTALL) and run shell setup
	$(call APPLY_INSTALL_TIERS,$(SHELL_INSTALL))
	@bash -lc 'if [ -x "scripts/shell_setup.sh" ]; then scripts/shell_setup.sh; else echo "[shell] scripts/shell_setup.sh not found or not executable"; fi'

06_Install_messaging: ## Apply $(INSTALL_DIR)/$(MSG_INSTALL) and setup msmtp config
	$(call APPLY_INSTALL_TIERS,$(MSG_INSTALL))
	@bash -lc 'if [ -x "scripts/msmtp_setup.sh" ]; then scripts/msmtp_setup.sh; else echo "[messaging] scripts/msmtp_setup.sh not found or not executable"; fi'

09_Install_development: ## Apply $(INSTALL_DIR)/$(DEV_INSTALL), install VSCode extensions, and setup VSCode config
	$(call APPLY_INSTALL_TIERS,$(DEV_INSTALL))
	@bash -lc 'if [ -x "scripts/vscode_extensions.sh" ]; then scripts/vscode_extensions.sh code; else echo "[development] scripts/vscode_extensions.sh not found or not executable"; fi' || true
	@bash -lc 'if [ -x "scripts/vscode_setup.sh" ]; then scripts/vscode_setup.sh; else echo "[development] scripts/vscode_setup.sh not found or not executable"; fi'

11_Install_aws: ## Apply $(INSTALL_DIR)/$(AWS_INSTALL) and setup CDK config
	$(call APPLY_INSTALL_TIERS,$(AWS_INSTALL))
	@bash -lc 'if [ -x "scripts/cdk_setup.sh" ]; then scripts/cdk_setup.sh; else echo "[aws] scripts/cdk_setup.sh not found or not executable"; fi'

17_Install_ai: ## Apply $(INSTALL_DIR)/$(AI_INSTALL), install Cursor extensions, disable auto-updates, and setup Claude config
	$(call APPLY_INSTALL_TIERS,$(AI_INSTALL))
	@bash -lc 'if [ -x "scripts/vscode_extensions.sh" ]; then scripts/vscode_extensions.sh cursor; else echo "[ai] scripts/vscode_extensions.sh not found or not executable"; fi' || true
	@claude config set -g autoUpdates false >/dev/null 2>&1 || true
	@bash -lc 'if [ -x "scripts/claude_disable_autoupdater.sh" ]; then scripts/claude_disable_autoupdater.sh; else echo "[ai] scripts/claude_disable_autoupdater.sh not found or not executable"; fi'
	@bash -lc 'if [ -x "scripts/claude_repo_setup.sh" ]; then scripts/claude_repo_setup.sh install; else echo "[ai] scripts/claude_repo_setup.sh not found or not executable"; fi'


# --- Per-Uninstall targets (auto-generated for every Uninstall/<NN-Uninstall.suffix>) ---
# Each target runs the remove runner with --mode=uninstall across the
# three tiers in order. Set DRY_RUN=1 on the command line to forward
# --dry-run to the runner (e.g. `make 03_Uninstall_shell DRY_RUN=1`).
define GEN_UNINSTALL_TARGET
$(call CANON,$(1)): ## Apply $(UNINSTALL_DIR)/$(1) across global, profile, and computer-specific tiers (set DRY_RUN=1 to rehearse)
	$$(call RUN_GLOBAL_UNINSTALL,$(1),$(DRY_RUN_FLAG))
	$$(call RUN_PROFILE_UNINSTALL,$(1),$(DRY_RUN_FLAG))
	$$(call RUN_COMPUTER_UNINSTALL,$(1),$(DRY_RUN_FLAG))
endef
$(foreach u,$(UNINSTALL_BASENAMES),$(eval $(call GEN_UNINSTALL_TARGET,$(u))))

# Mark every auto-generated per-Uninstall target .PHONY for the same
# reason as the per-Install ones above.
.PHONY: $(call CANONLIST,$(UNINSTALL_BASENAMES))


# --- Per-RemoveAndPurge targets (auto-generated for every RemoveAndPurge/<NN-RemoveAndPurge.suffix>) ---
# Each target runs the remove runner with --mode=purge across the three
# tiers in order. The purge mode adds --zap on cask uninstalls so the
# cask's declared user data is also removed. ALWAYS rehearse first by
# setting DRY_RUN=1 on the command line (e.g.
# `make 02_RemoveAndPurge_ui DRY_RUN=1`); these targets are destructive
# by design and will zap a cask's user data on a real run.
define GEN_PURGE_TARGET
$(call CANON,$(1)): ## Apply $(PURGE_DIR)/$(1) across global, profile, and computer-specific tiers (--zap casks; set DRY_RUN=1 to rehearse)
	$$(call RUN_GLOBAL_PURGE,$(1),$(DRY_RUN_FLAG))
	$$(call RUN_PROFILE_PURGE,$(1),$(DRY_RUN_FLAG))
	$$(call RUN_COMPUTER_PURGE,$(1),$(DRY_RUN_FLAG))
endef
$(foreach p,$(PURGE_BASENAMES),$(eval $(call GEN_PURGE_TARGET,$(p))))

.PHONY: $(call CANONLIST,$(PURGE_BASENAMES))


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
.PHONY: claude-install claude-update claude-outdated claude-plugins-install claude-plugins-update

claude-install: ## Install or migrate ~/.claude/ from the global Claude config repo
	@bash scripts/claude_repo_setup.sh install

claude-update: ## Update ~/.claude/ (errors if not yet installed via claude-install)
	@bash scripts/claude_repo_setup.sh update

claude-outdated: ## Show pending pulls/pushes and dirty files in ~/.claude/ (read-only)
	@bash scripts/claude_repo_setup.sh outdated

claude-plugins-install: ## Sync Claude plugins via the clone's own ~/.claude/plugins.sh --install
	@bash scripts/claude_repo_setup.sh plugins-install

claude-plugins-update: ## Update Claude plugins via the clone's own ~/.claude/plugins.sh --update
	@bash scripts/claude_repo_setup.sh plugins-update


# --- Host-tier seeding ---
# The per-host config tier lives OUTSIDE the repo (see host_tier_dir in
# scripts/config_common.sh). `make install` seeds it from the in-repo
# template ONLY if the external dir is absent; once present it is never
# overwritten. This target exposes the same step standalone.
.PHONY: seed-host-tier
seed-host-tier: ## Seed the external host tier from the template if absent (no-op if it already exists)
	@bash scripts/seed_host_tier.sh

# --- dasel reachability gate (issue #4) ---
# Every config.toml read in this repo invokes `dasel` by BARE NAME (the
# read layer in config_common.sh, and list_profiles.sh through it). On a
# fresh Apple Silicon Mac, dasel is installed into /opt/homebrew/bin by
# bootstrap.sh, but /opt/homebrew/bin is not on PATH until a NEW login
# shell sources the `brew shellenv` line bootstrap appended to the
# profile. A user who runs `./bootstrap.sh` then `make install` in the
# SAME shell therefore has dasel installed but unreachable by bare name,
# and the failure used to surface late and cryptically as a buried
# `dasel version exited 127` from require_dasel_v3 partway into
# 00-Install.core. This phony gate runs the up-front reachability check
# (scripts/require_dasel_on_path.sh) as a prerequisite, BEFORE host-tier
# seeding, the recipe-level config reads, and any install work, so a
# missing-on-PATH dasel aborts loudly with an actionable PATH remediation
# instead. It is a bare-name REACHABILITY check only; the exactly-v3
# version assertion stays the job of require_dasel_v3 at the first real
# read. Wired as a prerequisite on each config-dependent batch target
# below (install, update, verify, outdated); being .PHONY it always runs
# first, gating the target before any recipe config work begins.
#
# NB: the `PROFILES` variable below is read at make PARSE time, before any
# prerequisite (including this gate) runs. A prerequisite cannot gate a
# parse-time expansion, so list_profiles.sh guards itself: with dasel off
# PATH it short-circuits to an empty list rather than letting
# require_dasel_v3's `kill -s TERM "$$"` print a `Terminated: 15` line
# ahead of this gate's clean error. Gate + self-guard together make
# `Error: dasel not in PATH.` the sole output on a no-dasel run.
.PHONY: require-dasel
require-dasel:
	@bash scripts/require_dasel_on_path.sh

# --- Batch targets ---
.PHONY: install uninstall uninstall-dry-run remove-and-purge remove-and-purge-dry-run update help
install: require-dasel ## Apply all Install files in numeric order (filtered against in-scope Uninstall files); seeds the external host tier if absent
	@set -euo pipefail
	@$(MAKE) -s seed-host-tier
	@if [ -z "$(ORDERED_INSTALL_FILES)" ]; then echo "No Install files found in $(INSTALL_DIR)/"; exit 0; fi
	@failed=""; \
	for f in $(ORDERED_INSTALL_FILES); do \
		echo "==> Applying $$f (filtered)"; \
		tmp="$$($(INSTALL_FILTER) "$$f")"; \
		if $(BREW) bundle --file="$$tmp"; then :; else failed="$$failed $$f"; fi; \
		rm -f "$$tmp"; \
		bfbase="$$(basename $$f)"; \
		for prof in $(PROFILES); do \
			pf="profiles/$$prof/$(INSTALL_DIR)/$$bfbase"; \
			if [ -f "$$pf" ]; then \
				echo "==> Found profile Install: $$pf"; \
				tmp="$$($(INSTALL_FILTER) "$$pf")"; \
				if $(BREW) bundle --file="$$tmp"; then :; else failed="$$failed $$pf"; fi; \
				rm -f "$$tmp"; \
			else \
				$(VERBOSE_NOTE) "==> No profile Install found at $$pf"; fi; \
			fi; \
		done; \
		computer_install="$(COMPUTER_SPECIFIC_DIR)/$$bfbase"; \
		if [ -f "$$computer_install" ]; then \
			echo "==> Found computer-specific Install: $$computer_install"; \
			tmp="$$($(INSTALL_FILTER) "$$computer_install")"; \
			if $(BREW) bundle --file="$$tmp"; then :; else failed="$$failed $$computer_install"; fi; \
			rm -f "$$tmp"; \
		else \
			$(VERBOSE_NOTE) "==> No computer-specific Install found at $$computer_install"; fi; \
		fi; \
		case "$$bfbase" in \
			00-Install.core) \
				if [ -x "scripts/core_setup.sh" ]; then scripts/core_setup.sh; else echo "[core] scripts/core_setup.sh not found or not executable"; fi ;; \
			02-Install.ui) \
				if [ -x "scripts/hammerspoon_setup.sh" ]; then scripts/hammerspoon_setup.sh; else echo "[ui] scripts/hammerspoon_setup.sh not found or not executable"; fi ;; \
			03-Install.shell) \
				if [ -x "scripts/shell_setup.sh" ]; then scripts/shell_setup.sh; else echo "[shell] scripts/shell_setup.sh not found or not executable"; fi ;; \
			04-Install.versionmanagers) \
				if [ -x "$(VERSIONS_SETUP)" ]; then $(VERSIONS_SETUP) full; else echo "[versionmanagers] $(VERSIONS_SETUP) not found or not executable"; fi ;; \
			06-Install.messaging) \
				if [ -x "scripts/msmtp_setup.sh" ]; then scripts/msmtp_setup.sh; else echo "[messaging] scripts/msmtp_setup.sh not found or not executable"; fi ;; \
			09-Install.development) \
				if [ -x "scripts/vscode_extensions.sh" ]; then scripts/vscode_extensions.sh code; else echo "[development] scripts/vscode_extensions.sh not found or not executable"; fi || true; \
				if [ -x "scripts/vscode_setup.sh" ]; then scripts/vscode_setup.sh; else echo "[development] scripts/vscode_setup.sh not found or not executable"; fi ;; \
			11-Install.aws) \
				if [ -x "scripts/cdk_setup.sh" ]; then scripts/cdk_setup.sh; else echo "[aws] scripts/cdk_setup.sh not found or not executable"; fi ;; \
			17-Install.ai) \
				if [ -x "scripts/vscode_extensions.sh" ]; then scripts/vscode_extensions.sh cursor; else echo "[ai] scripts/vscode_extensions.sh not found or not executable"; fi || true; \
				claude config set -g autoUpdates false >/dev/null 2>&1 || true; \
				if [ -x "scripts/claude_disable_autoupdater.sh" ]; then scripts/claude_disable_autoupdater.sh; else echo "[ai] scripts/claude_disable_autoupdater.sh not found or not executable"; fi; \
				if [ -x "scripts/claude_repo_setup.sh" ]; then scripts/claude_repo_setup.sh install; else echo "[ai] scripts/claude_repo_setup.sh not found or not executable"; fi ;; \
			esac; \
		done; \
	if [ -n "$$failed" ]; then \
		echo "==> The following Install slots failed (brew bundle returned non-zero):"; \
		for s in $$failed; do echo "  - $$s"; done; \
		echo "All other Install files were applied. Re-run 'make install' after resolving the above."; \
		exit 1; \
	fi; \
	echo "All Install files applied."

# uninstall: walk every Uninstall file in numeric order across all tiers.
# Skips entries already absent. Uses --dry-run? See `make uninstall-dry-run`.
uninstall: ## Apply all Uninstall files in numeric order (global + profile + computer-specific)
	@set -euo pipefail
	@$(MAKE) -s _uninstall_loop UNINSTALL_DRY_RUN=

uninstall-dry-run: ## Print what `make uninstall` would do without making any changes
	@set -euo pipefail
	@$(MAKE) -s _uninstall_loop UNINSTALL_DRY_RUN=--dry-run

# Internal target: factored loop, parameterized by UNINSTALL_DRY_RUN.
.PHONY: _uninstall_loop
_uninstall_loop:
	@set -euo pipefail; \
	any=0; \
	for u in $(ORDERED_UNINSTALL_FILES); do \
		any=1; \
		ubase="$$(basename "$$u")"; \
		if [ -f "$$u" ]; then \
			bash $(REMOVE_RUNNER) "$$u" --mode=uninstall --banner="==> Applying global Uninstall: $$u" $(UNINSTALL_DRY_RUN); \
		fi; \
		for prof in $(PROFILES); do \
			pf="profiles/$$prof/$(UNINSTALL_DIR)/$$ubase"; \
			if [ -f "$$pf" ]; then \
				bash $(REMOVE_RUNNER) "$$pf" --mode=uninstall --banner="==> Applying profile Uninstall: $$pf" $(UNINSTALL_DRY_RUN); \
			fi; \
		done; \
		if [ -f "$(COMPUTER_UNINSTALL_DIR)/$$ubase" ]; then \
			bash $(REMOVE_RUNNER) "$(COMPUTER_UNINSTALL_DIR)/$$ubase" --mode=uninstall --banner="==> Applying computer-specific Uninstall: $(COMPUTER_UNINSTALL_DIR)/$$ubase" $(UNINSTALL_DRY_RUN); \
		fi; \
	done; \
	if [ $$any -eq 0 ]; then echo "No Uninstall files found in $(UNINSTALL_DIR)/"; fi; \
	echo "All Uninstall files processed."

# remove-and-purge: walk every RemoveAndPurge file in numeric order across
# all tiers. Same shape as `make uninstall`, but the runner is invoked
# with --mode=purge so casks are uninstalled with --zap.
remove-and-purge: ## Apply all RemoveAndPurge files in numeric order (global + profile + computer-specific; --zap casks)
	@set -euo pipefail
	@$(MAKE) -s _remove_and_purge_loop PURGE_DRY_RUN=

remove-and-purge-dry-run: ## Print what `make remove-and-purge` would do without making any changes
	@set -euo pipefail
	@$(MAKE) -s _remove_and_purge_loop PURGE_DRY_RUN=--dry-run

# Internal target: factored loop, parameterized by PURGE_DRY_RUN.
.PHONY: _remove_and_purge_loop
_remove_and_purge_loop:
	@set -euo pipefail; \
	any=0; \
	for u in $(ORDERED_PURGE_FILES); do \
		any=1; \
		ubase="$$(basename "$$u")"; \
		if [ -f "$$u" ]; then \
			bash $(REMOVE_RUNNER) "$$u" --mode=purge --banner="==> Applying global RemoveAndPurge: $$u" $(PURGE_DRY_RUN); \
		fi; \
		for prof in $(PROFILES); do \
			pf="profiles/$$prof/$(PURGE_DIR)/$$ubase"; \
			if [ -f "$$pf" ]; then \
				bash $(REMOVE_RUNNER) "$$pf" --mode=purge --banner="==> Applying profile RemoveAndPurge: $$pf" $(PURGE_DRY_RUN); \
			fi; \
		done; \
		if [ -f "$(COMPUTER_PURGE_DIR)/$$ubase" ]; then \
			bash $(REMOVE_RUNNER) "$(COMPUTER_PURGE_DIR)/$$ubase" --mode=purge --banner="==> Applying computer-specific RemoveAndPurge: $(COMPUTER_PURGE_DIR)/$$ubase" $(PURGE_DRY_RUN); \
		fi; \
	done; \
	if [ $$any -eq 0 ]; then echo "No RemoveAndPurge files found in $(PURGE_DIR)/"; fi; \
	echo "All RemoveAndPurge files processed."

# Note: the sed pattern extracting cask names from "already an App" errors depends on
# Homebrew's "Error: <cask>: ..." format. If it changes, unmatched errors safely fall
# through to the generic error check which sets FAIL=1.
update: require-dasel ## Update Homebrew, upgrade formulae/casks/MAS/managed tool versions, then apply Uninstall and RemoveAndPurge
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
	echo "==> Updating mise-managed tools..."; \
	$(MAKE) -s versions-update || FAIL=1; \
	echo "==> Pruning unused mise-managed versions..."; \
	$(MAKE) -s versions-cleanup || FAIL=1; \
	echo "==> Updating ~/.claude/ from the global Claude config repo..."; \
	if [ -x "scripts/claude_repo_setup.sh" ]; then bash scripts/claude_repo_setup.sh update || FAIL=1; else echo "scripts/claude_repo_setup.sh not found or not executable"; fi; \
	echo "==> Applying Uninstall/ files..."; \
	$(MAKE) -s uninstall || FAIL=1; \
	echo "==> Applying RemoveAndPurge/ files..."; \
	$(MAKE) -s remove-and-purge || FAIL=1; \
	echo "==> All packages updated."; \
	exit $$FAIL

# `DRY_RUN=1` expands to `--dry-run` via DRY_RUN_FLAG (defined at the
# top of this file) and is forwarded to scripts/self_update.sh so
# `make self-update DRY_RUN=1` rehearses without making changes.
self-update: ## Pull latest main; auto-stash if dirty (DRY_RUN=1 to rehearse)
	@bash scripts/self_update.sh $(DRY_RUN_FLAG)

# --- Help ---
help: ## Show help for available targets (documented + auto-detected Install/Uninstall/RemoveAndPurge + alias targets)
	@echo "Usage: make <target>"
	@echo
	@awk 'BEGIN {FS=":.*##"; print "Documented targets:"} /^[a-zA-Z0-9_.-]+:.*##/ {printf "  \033[36m%-32s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo
	@echo "Per-Install targets (apply individual Install files):"
	@printf "  %s\n" $(call CANONLIST,$(INSTALL_BASENAMES))
	@echo
	@echo "Per-Uninstall targets (apply individual Uninstall files across tiers; append DRY_RUN=1 to rehearse):"
	@printf "  %s\n" $(call CANONLIST,$(UNINSTALL_BASENAMES))
	@echo
	@echo "Per-RemoveAndPurge targets (apply individual RemoveAndPurge files across tiers; --zap casks; ALWAYS rehearse with DRY_RUN=1 first):"
	@printf "  %s\n" $(call CANONLIST,$(PURGE_BASENAMES))
	@echo
	@echo "Alias targets (shortcuts to Per-Install targets):"
	@echo "  Numeric aliases (e.g., '00', '01', '02'...): Run individual Install files by sequence number"
	@echo "  Suffix aliases (e.g., 'core', 'ui', 'shell'...): Run individual Install files by category name"

# --- Version management targets ---
# Named `versions-*`, not after the tool that implements them: the previous
# `asdf-*` names baked the implementation into the public interface, so
# swapping the implementation forced every caller, alias, and doc line to
# change. `tools-*` is ruled out because `make tools` already exists as the
# alias for the 05-Install.tools slot.
.PHONY: versions-install versions-update versions-outdated versions-cleanup versions-cleanup-dry-run asdf-to-mise

versions-install: ## Install the tool versions the resolved mise config declares
	@bash -lc 'if [ -x "$(VERSIONS_SETUP)" ]; then $(VERSIONS_SETUP) install; else echo "$(VERSIONS_SETUP) not found"; fi'

versions-update: ## Install latest tool versions and bump the config (mise up --bump)
	@bash -lc 'if [ -x "$(VERSIONS_SETUP)" ]; then $(VERSIONS_SETUP) update; else echo "$(VERSIONS_SETUP) not found"; fi'

versions-outdated: ## Check for outdated mise-managed tools
	@bash -lc 'if [ -x "$(VERSIONS_SETUP)" ]; then $(VERSIONS_SETUP) outdated; else echo "$(VERSIONS_SETUP) not found"; fi'

versions-cleanup: ## Prune unused installed tool versions (mise prune)
	@bash -lc 'if [ -x "$(VERSIONS_SETUP)" ]; then $(VERSIONS_SETUP) cleanup; else echo "$(VERSIONS_SETUP) not found"; fi'

versions-cleanup-dry-run: ## Show what versions-cleanup would remove
	@bash -lc 'if [ -x "$(VERSIONS_SETUP)" ]; then $(VERSIONS_SETUP) cleanup-dry-run; else echo "$(VERSIONS_SETUP) not found"; fi'

# One-shot migration verb. A deliberate exception to the
# implementation-neutral naming above: it names both endpoints on purpose,
# and it is deleted once every repo and host is over. Operates on the
# ORIGINAL call directory (START_DIR), not on macos-setup, so it can be run
# from any repo -- the same mechanism the outgoing direnv-enable /
# direnv-disable targets used. It is purely additive: it writes mise config
# and warns about leftovers, and deletes, moves, untracks, and commits
# nothing.
asdf-to-mise: ## Convert the calling repo from asdf+direnv to mise (additive; deletes nothing)
	@START_DIR="$(START_DIR)" bash scripts/asdf_to_mise.sh

04_Install_versionmanagers: ## Apply $(INSTALL_DIR)/$(VM_INSTALL) and set up mise
	$(call APPLY_INSTALL_TIERS,$(VM_INSTALL))
	@bash -lc 'if [ -x "$(VERSIONS_SETUP)" ]; then $(VERSIONS_SETUP) full; else echo "[versionmanagers] $(VERSIONS_SETUP) not found or not executable"; fi'

# Allows: `make 02`, `make ui`, `make shell`, `make versionmanagers`, etc.

# --- Alias targets (numeric and suffix) ---
# Allows: `make 02`, `make ui`, `make shell`, `make versionmanagers`, etc.

00: ; @$(MAKE) $(call CANON,00-Install.core)
01: ; @$(MAKE) $(call CANON,01-Install.security)
02: ; @$(MAKE) $(call CANON,02-Install.ui)
03: ; @$(MAKE) $(call CANON,03-Install.shell)
04: ; @$(MAKE) $(call CANON,04-Install.versionmanagers)
05: ; @$(MAKE) $(call CANON,05-Install.tools)
06: ; @$(MAKE) $(call CANON,06-Install.messaging)
07: ; @$(MAKE) $(call CANON,07-Install.browsers)
08: ; @$(MAKE) $(call CANON,08-Install.proton)
09: ; @$(MAKE) $(call CANON,09-Install.development)
10: ; @$(MAKE) $(call CANON,10-Install.backups)
11: ; @$(MAKE) $(call CANON,11-Install.aws)
12: ; @$(MAKE) $(call CANON,12-Install.componentization)
13: ; @$(MAKE) $(call CANON,13-Install.data)
14: ; @$(MAKE) $(call CANON,14-Install.databases)
15: ; @$(MAKE) $(call CANON,15-Install.ripping)
16: ; @$(MAKE) $(call CANON,16-Install.sdcards)
17: ; @$(MAKE) $(call CANON,17-Install.ai)
18: ; @$(MAKE) $(call CANON,18-Install.msoffice)
19: ; @$(MAKE) $(call CANON,19-Install.contentviewers)

core: ; @$(MAKE) $(call CANON,00-Install.core)
security: ; @$(MAKE) $(call CANON,01-Install.security)
ui: ; @$(MAKE) $(call CANON,02-Install.ui)
shell: ; @$(MAKE) $(call CANON,03-Install.shell)
versionmanagers: ; @$(MAKE) $(call CANON,04-Install.versionmanagers)
tools: ; @$(MAKE) $(call CANON,05-Install.tools)
messaging: ; @$(MAKE) $(call CANON,06-Install.messaging)
browsers: ; @$(MAKE) $(call CANON,07-Install.browsers)
proton: ; @$(MAKE) $(call CANON,08-Install.proton)
development: ; @$(MAKE) $(call CANON,09-Install.development)
backups: ; @$(MAKE) $(call CANON,10-Install.backups)
aws: ; @$(MAKE) $(call CANON,11-Install.aws)
componentization: ; @$(MAKE) $(call CANON,12-Install.componentization)
data: ; @$(MAKE) $(call CANON,13-Install.data)
databases: ; @$(MAKE) $(call CANON,14-Install.databases)
ripping: ; @$(MAKE) $(call CANON,15-Install.ripping)
sdcards: ; @$(MAKE) $(call CANON,16-Install.sdcards)
ai: ; @$(MAKE) $(call CANON,17-Install.ai)
msoffice: ; @$(MAKE) $(call CANON,18-Install.msoffice)
contentviewers: ; @$(MAKE) $(call CANON,19-Install.contentviewers)

.PHONY: 00 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 ai aws backups browsers componentization contentviewers core data databases development messaging msoffice proton ripping sdcards security shell tools ui versionmanagers

diagnose: ## Run system diagnostics and check installation status
	@bash ./scripts/diagnose.sh
.PHONY: diagnose

.PHONY: verify sanitize
verify: require-dasel ## Verify installations and check for same-tier Install/Uninstall+RemoveAndPurge collisions
	@set -uo pipefail; FAIL=0; \
	bash ./scripts/verify.sh || FAIL=1; \
	echo; \
	echo "=== same-tier collision check ==="; \
	bash ./scripts/collision_check.sh || FAIL=1; \
	exit $$FAIL

sanitize: ## Resolve same-tier Install/Uninstall+RemoveAndPurge collisions by commenting out the Install line (writes .bak)
	@bash ./scripts/collision_check.sh --fix

.PHONY: outdated
outdated: require-dasel ## Check for outdated formulae, casks, MAS apps, and managed tool versions
	@echo "==> Checking for outdated packages across all Install files..."
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
	@if [ -x "scripts/claude_repo_setup.sh" ]; then bash scripts/claude_repo_setup.sh outdated || true; else echo "  scripts/claude_repo_setup.sh not found or not executable"; fi
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
# `~/.zsh-shared` to be updated (which `make shell` already does),
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

# --- Dotted Install aliases (so `make 01-Install.security` is a direct
# equivalent to the canonical under_score target). Per-Uninstall and
# per-RemoveAndPurge targets are reachable via the canonical form only
# (e.g. `make 01_Uninstall_security`, `make 01_RemoveAndPurge_security`). ---
.PHONY: 00-Install.core
00-Install.core:
	@$(MAKE) 00_Install_core

.PHONY: 01-Install.security
01-Install.security:
	@$(MAKE) 01_Install_security

.PHONY: 02-Install.ui
02-Install.ui:
	@$(MAKE) 02_Install_ui

.PHONY: 03-Install.shell
03-Install.shell:
	@$(MAKE) 03_Install_shell

.PHONY: 04-Install.versionmanagers
04-Install.versionmanagers:
	@$(MAKE) 04_Install_versionmanagers

.PHONY: 05-Install.tools
05-Install.tools:
	@$(MAKE) 05_Install_tools

.PHONY: 06-Install.messaging
06-Install.messaging:
	@$(MAKE) 06_Install_messaging

.PHONY: 07-Install.browsers
07-Install.browsers:
	@$(MAKE) 07_Install_browsers

.PHONY: 08-Install.proton
08-Install.proton:
	@$(MAKE) 08_Install_proton

.PHONY: 09-Install.development
09-Install.development:
	@$(MAKE) 09_Install_development

.PHONY: 10-Install.backups
10-Install.backups:
	@$(MAKE) 10_Install_backups

.PHONY: 11-Install.aws
11-Install.aws:
	@$(MAKE) 11_Install_aws

.PHONY: 12-Install.componentization
12-Install.componentization:
	@$(MAKE) 12_Install_componentization

.PHONY: 13-Install.data
13-Install.data:
	@$(MAKE) 13_Install_data

.PHONY: 14-Install.databases
14-Install.databases:
	@$(MAKE) 14_Install_databases

.PHONY: 15-Install.ripping
15-Install.ripping:
	@$(MAKE) 15_Install_ripping

.PHONY: 16-Install.sdcards
16-Install.sdcards:
	@$(MAKE) 16_Install_sdcards

.PHONY: 17-Install.ai
17-Install.ai:
	@$(MAKE) 17_Install_ai

.PHONY: 18-Install.msoffice
18-Install.msoffice:
	@$(MAKE) 18_Install_msoffice

.PHONY: mas_search_msoffice
mas_search_msoffice: ## Search Mac App Store for Microsoft Office apps
	@echo "Searching MAS for Microsoft Office apps..."
	@mas search "Microsoft Word" | grep -i "microsoft word" || true
	@mas search "Microsoft Excel" | grep -i "microsoft excel" || true
	@mas search "Microsoft PowerPoint" | grep -i "microsoft powerpoint" || true
	@mas search "Microsoft Outlook" | grep -i "microsoft outlook" || true
	@mas search "Microsoft OneNote" | grep -i "microsoft onenote" || true

.PHONY: 19-Install.contentviewers
19-Install.contentviewers:
	@$(MAKE) 19_Install_contentviewers
