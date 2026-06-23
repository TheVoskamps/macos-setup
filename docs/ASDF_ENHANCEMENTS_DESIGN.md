# ASDF Version Management Enhancements - Design Document

## Executive Summary

This document outlines the design for enhancing asdf version management in the macOS setup repository. The design adds three new Makefile targets (`asdf-awscli`, `asdf-outdated`, `asdf-update`) to provide comprehensive management of asdf-managed tools, mirroring the pattern established for Homebrew package management.

## Architecture Overview

### Current State
- **asdf Management**: Currently handled through `scripts/asdf_setup.sh` with Makefile targets that delegate to the script
- **Plugin Management**: Individual targets for `asdf-node`, `asdf-python`, `asdf-pnpm` that ensure plugin installation, version pinning, and installation
- **Version Pinning**: Versions are pinned in `.tool-versions` file (currently not committed to repo)
- **Homebrew Integration**: Separate `outdated` and `update` targets for Homebrew packages

### Proposed Architecture
```
Makefile (orchestration layer)
├── asdf-awscli        → Direct implementation (mirrors asdf-node pattern)
├── asdf-outdated      → Delegates to asdf_setup.sh
├── asdf-update        → Delegates to asdf_setup.sh
└── Integration hooks  → outdated/update targets call asdf equivalents
```

## Target Specifications

### Part 1: `asdf-awscli` Target

**Purpose**: Ensure awscli is properly managed through asdf instead of/alongside Homebrew

**Implementation Pattern**: Mirror existing `asdf-node`, `asdf-python`, `asdf-pnpm` targets

**Specification**:
```makefile
asdf-awscli: ## Ensure awscli plugin/pin and install
	# Install awscli per .tool-versions (or latest if missing)
	$(WITH_ASDF)
		@asdf where awscli >/dev/null 2>&1 || asdf plugin add awscli https://github.com/MetricMike/asdf-awscli.git || true
		@if ! grep -q "^awscli " .tool-versions 2>/dev/null; then \
		  v=$$(asdf latest awscli); echo "awscli $$v" >> .tool-versions; \
		fi
		@asdf install awscli
```

**Considerations**:
- The awscli plugin is already referenced in `asdf_setup.sh` (line 50-51)
- This creates consistency with other tool-specific targets
- Allows for independent management of awscli versions

### Part 2: `asdf-outdated` Target

**Purpose**: Check all asdf-managed tools for available updates

**Specification**:
```makefile
asdf-outdated: ## Check for outdated asdf-managed tools
	@bash -lc 'if [ -x "scripts/asdf_setup.sh" ]; then scripts/asdf_setup.sh outdated; else echo "scripts/asdf_setup.sh not found"; fi'
```

**Script Implementation** (`asdf_setup.sh` additions):
```bash
check_outdated() {
  log "Checking for outdated asdf-managed tools..."

  # Get list of installed plugins
  local plugins
  plugins=$(asdf plugin list 2>/dev/null)

  if [ -z "$plugins" ]; then
    warn "No asdf plugins installed"
    return
  fi

  local has_outdated=0

  while IFS= read -r plugin; do
    [ -z "$plugin" ] && continue

    # Get all installed versions for this plugin
    local installed_versions
    installed_versions=$(asdf list "$plugin" 2>/dev/null | sed 's/^[[:space:]]*//' | grep -v '^$')

    if [ -z "$installed_versions" ]; then
      echo "  $plugin: no versions installed"
      continue
    fi

    # Get latest available version
    local latest_version
    latest_version=$(asdf latest "$plugin" 2>/dev/null || echo "")

    if [ -z "$latest_version" ]; then
      echo "  $plugin: installed (unable to check latest)"
      continue
    fi

    # Check if latest is already installed
    local latest_installed=false
    while IFS= read -r installed; do
      if [ "$installed" = "$latest_version" ]; then
        latest_installed=true
        break
      fi
    done <<< "$installed_versions"

    # Get the currently active version (if set)
    local current_version
    current_version=$(asdf current "$plugin" 2>/dev/null | awk '{print $1}' || echo "")

    if [ "$latest_installed" = true ]; then
      if [ -n "$current_version" ] && [ "$current_version" != "$latest_version" ]; then
        echo "  $plugin: $current_version (latest $latest_version installed but not active)"
      else
        echo "  $plugin: $latest_version (up to date)"
      fi
    else
      if [ -n "$current_version" ]; then
        echo "  $plugin: $current_version → $latest_version"
      else
        # Show first installed version
        local first_installed=$(echo "$installed_versions" | head -1)
        echo "  $plugin: $first_installed → $latest_version"
      fi
      has_outdated=1
    fi
  done <<< "$plugins"

  if [ $has_outdated -eq 1 ]; then
    echo ""
    echo "To update to latest versions, run: make asdf-update"
  else
    echo ""
    echo "All installed asdf tools are up to date"
  fi
}
```

### Part 3: `asdf-update` Target

**Purpose**: Update all asdf-managed tools to their latest versions (interactive)

**Specification**:
```makefile
asdf-update: ## Update all asdf plugins and optionally update pinned versions (interactive)
	@bash -lc 'if [ -x "scripts/asdf_setup.sh" ]; then scripts/asdf_setup.sh update-all; else echo "scripts/asdf_setup.sh not found"; fi'

asdf-update-auto: ## Update asdf plugins and install current versions (non-interactive)
	@bash -lc 'if [ -x "scripts/asdf_setup.sh" ]; then scripts/asdf_setup.sh update-auto; else echo "scripts/asdf_setup.sh not found"; fi'
```

**Script Implementation** (`asdf_setup.sh` additions):

```bash
# Interactive update - prompts user about version pinning
update_all_tools() {
  log "Updating all asdf-managed tools..."

  # First update all plugins
  log "Updating asdf plugins..."
  asdf plugin update --all

  # Check if we should update pinned versions
  read -p "Update pinned versions in .tool-versions to latest? [y/N] " -n 1 -r
  echo

  if [[ $REPLY =~ ^[Yy]$ ]]; then
    backup_file=".tool-versions.backup.$(date +%Y%m%d_%H%M%S)"
    cp .tool-versions "$backup_file" 2>/dev/null || true
    log "Backed up .tool-versions to $backup_file"

    # Update each tool to latest
    if [ -f .tool-versions ]; then
      while IFS=' ' read -r plugin current_version; do
        # Skip empty lines and comments
        [[ -z "$plugin" || "$plugin" =~ ^# ]] && continue

        if asdf plugin list | grep -q "^${plugin}$"; then
          local latest_version
          latest_version=$(asdf latest "$plugin" 2>/dev/null || echo "")

          if [ -n "$latest_version" ]; then
            # Update .tool-versions
            if command -v sed >/dev/null 2>&1; then
              sed -i.bak -E "s|^($plugin) .*|\1 $latest_version|" .tool-versions
              rm -f .tool-versions.bak 2>/dev/null || true
            fi

            # Install the new version
            log "Installing $plugin $latest_version..."
            asdf install "$plugin" "$latest_version"

            # Set as global default
            asdf global "$plugin" "$latest_version"

            log "Updated $plugin: $current_version → $latest_version"
          fi
        fi
      done < "$backup_file"
    fi

    log "All tools updated to latest versions"
  else
    log "Keeping current pinned versions"

    # Just install current versions if needed
    if [ -f .tool-versions ]; then
      asdf install
    fi
  fi
}

# Automatic update - just update plugins and install current versions
update_auto_tools() {
  log "Updating asdf plugins..."
  asdf plugin update --all

  log "Installing current pinned versions..."
  if [ -f .tool-versions ]; then
    asdf install
  fi

  log "asdf plugins updated and current versions installed"
}
```

## Integration Points

### Integration with Existing `outdated` Target

Modify the existing `outdated` target (lines 317-330) to include asdf tools:

```makefile
outdated: ## Check for outdated formulae, casks, MAS apps, and asdf tools
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
	@echo "==> Outdated asdf-managed tools:"
	@$(MAKE) -s asdf-outdated 2>/dev/null || echo "  (unable to check)"
	@echo
	@echo "To update all packages, run: make update"
```

### Integration with Existing `update` Target

Modify the existing `update` target (lines 176-186) to include asdf tools:

```makefile
update: ## Update Homebrew, upgrade all formulae/casks, MAS apps, and asdf tools
	@set -euo pipefail
	@echo "==> Updating Homebrew..."
	$(BREW) update
	@echo "==> Upgrading Homebrew formulae..."
	$(BREW) upgrade --formula
	@echo "==> Upgrading Homebrew casks (including greedy)..."
	$(BREW) upgrade --cask --greedy
	@echo "==> Upgrading Mac App Store apps..."
	@command -v mas >/dev/null 2>&1 && mas upgrade || true
	@echo "==> Updating asdf-managed tools..."
	@if [ -f .tool-versions ]; then \
		$(MAKE) -s asdf-update-auto || true; \
	else \
		echo "No .tool-versions file found"; \
	fi
	@echo "==> All packages updated."
```

## Implementation Approach

### User Interaction

**Two Update Modes**:

1. **`make update`** (non-interactive):
   - Calls `make asdf-update-auto` internally
   - Updates all asdf plugins to latest
   - Installs currently-pinned versions from `.tool-versions`
   - Does NOT change pinned versions
   - Fully automated, no prompts

2. **`make asdf-update`** (interactive):
   - Updates all asdf plugins to latest
   - Prompts user: "Update pinned versions in `.tool-versions` to latest?"
   - If yes: Creates backup, updates `.tool-versions`, installs new versions
   - If no: Just installs currently-pinned versions
   - Use this when you want to upgrade to newer versions of tools

This dual approach ensures `make update` is fully automated while still providing an interactive option for version upgrades.

### 1. Script vs Makefile Implementation

**Decision**: Hybrid approach
- **Simple operations** (like `asdf-awscli`): Implement directly in Makefile for consistency with existing patterns
- **Complex operations** (like `asdf-outdated`, `asdf-update`): Delegate to `asdf_setup.sh` for better maintainability

**Rationale**:
- Makefile targets remain simple and readable
- Complex logic is centralized in the script
- Easier to test and debug script functions
- Maintains consistency with existing patterns

### 2. Plugin Discovery

**Approach**: Query installed plugins directly
- Use `asdf plugin list` to discover all installed plugins
- Use `asdf list <plugin>` to find installed versions
- Use `asdf current <plugin>` to find the active version
- This checks actual installed state, not just what's in `.tool-versions`
- Falls back gracefully when no plugins are installed

### 3. Version Comparison

**Method**: Direct string comparison
- Use `asdf latest <plugin>` to get the latest version
- Compare with current version from `.tool-versions`
- No need for complex version parsing as asdf handles semver internally

### 4. Update Strategy

**Interactive Approach**:
- Prompt user to confirm updating pinned versions
- Create backup of `.tool-versions` before modifications
- Option to just update plugins without changing pinned versions

## Edge Cases and Considerations

### 1. No Plugins Installed
- **Behavior**: Gracefully report "No asdf plugins installed"
- **Recovery**: User can run `make asdf-plugins-init` or `make versionmanagers`

### 2. Plugin Not Installed
- **Detection**: Check `asdf plugin list` before operations
- **Recovery**: Suggest running `make asdf-plugins-init`

### 3. Network Failures
- **Handling**: Use `|| true` to prevent target failure
- **Reporting**: Show clear error messages when latest version can't be fetched

### 4. Version Resolution Failures
- **Cause**: Some plugins may not support `asdf latest`
- **Handling**: Report "unable to check latest" and continue

### 5. Conflicting Installations
- **Issue**: Tool installed via both Homebrew and asdf (e.g., awscli)
- **Resolution**: asdf shims take precedence in PATH
- **Documentation**: Add notes about migration from Homebrew to asdf

### 6. Plugin Update Failures
- **Handling**: Continue with other plugins even if one fails
- **Reporting**: Show which plugins failed to update

## Makefile Code Additions

Add these targets after line 235 in the Makefile:

```makefile
asdf-awscli: ## Ensure awscli plugin/pin and install
	# Install awscli per .tool-versions (or latest if missing)
	$(WITH_ASDF)
		@asdf where awscli >/dev/null 2>&1 || asdf plugin add awscli https://github.com/MetricMike/asdf-awscli.git || true
		@if ! grep -q "^awscli " .tool-versions 2>/dev/null; then \
		  v=$$(asdf latest awscli); echo "awscli $$v" >> .tool-versions; \
		fi
		@asdf install awscli

asdf-outdated: ## Check for outdated asdf-managed tools
	@bash -lc 'if [ -x "scripts/asdf_setup.sh" ]; then scripts/asdf_setup.sh outdated; else echo "scripts/asdf_setup.sh not found"; fi'

asdf-update: ## Update all asdf plugins and optionally update pinned versions (interactive)
	@bash -lc 'if [ -x "scripts/asdf_setup.sh" ]; then scripts/asdf_setup.sh update-all; else echo "scripts/asdf_setup.sh not found"; fi'

asdf-update-auto: ## Update asdf plugins and install current versions (non-interactive)
	@bash -lc 'if [ -x "scripts/asdf_setup.sh" ]; then scripts/asdf_setup.sh update-auto; else echo "scripts/asdf_setup.sh not found"; fi'
```

## Script Modifications

Add these case handlers to `asdf_setup.sh` (after line 172):

```bash
  "outdated")
    check_outdated
    ;;
  "update-all")
    update_all_tools
    ;;
  "update-auto")
    update_auto_tools
    ;;
```

Update the usage message (line 186-192):

```bash
    echo "Usage: $0 [plugins-init|pin-latest|install|update-latest|direnv-setup|outdated|update-all|update-auto|full]"
    echo "  plugins-init   - Install plugins only"
    echo "  pin-latest     - Pin latest versions to .tool-versions"
    echo "  install        - Install versions from .tool-versions"
    echo "  update-latest  - Update all plugins to latest versions"
    echo "  direnv-setup   - Setup direnv integration"
    echo "  outdated       - Check for outdated tools"
    echo "  update-all     - Update all tools with optional version updates (interactive)"
    echo "  update-auto    - Update plugins and install current versions (non-interactive)"
    echo "  full           - Complete setup (default)"
```

## Testing Strategy

### 1. Unit Testing
- Test `asdf-awscli` with and without existing `.tool-versions`
- Test `asdf-outdated` with various states (up-to-date, outdated, missing)
- Test `asdf-update` with user confirmation scenarios

### 2. Integration Testing
- Verify `make outdated` includes asdf information
- Verify `make update` suggests asdf updates
- Test migration from Homebrew-managed to asdf-managed awscli

### 3. Edge Case Testing
- Test with network disconnected
- Test with corrupted `.tool-versions`
- Test with missing plugins

## Migration Path

### For awscli Users
1. If awscli is installed via Homebrew, it will continue to work
2. Running `make asdf-awscli` will set up asdf-managed version
3. asdf shims will take precedence once installed
4. Users can optionally remove Homebrew version: `brew uninstall awscli`

## Documentation Updates

### CLAUDE.md Updates
Add to the Development Commands section:

```markdown
# asdf version checking and updates
make asdf-outdated    # Check for newer versions of asdf-managed tools
make asdf-update      # Update all asdf tools (interactive - prompts for version upgrades)
make asdf-update-auto # Update asdf plugins and install current versions (non-interactive)
make asdf-awscli      # Setup awscli via asdf (alternative to Homebrew)

# Note: 'make update' automatically calls 'make asdf-update-auto' to update
# asdf plugins while keeping pinned versions unchanged
```

### README Updates
Document the dual management approach for tools that can be installed via both Homebrew and asdf.

## Security Considerations

1. **Plugin Sources**: All plugin URLs use official repositories
2. **Version Pinning**: Exact versions prevent unexpected updates
3. **Backup Strategy**: `.tool-versions` backed up before modifications
4. **GPG Keys**: Node.js plugin imports release team keys for verification

## Performance Considerations

1. **Parallel Execution**: Not applicable due to sequential nature of version management
2. **Caching**: asdf caches downloaded versions automatically
3. **Network Calls**: Minimize by checking current state before operations

## Future Enhancements

1. **Automated Testing**: Add GitHub Actions workflow for testing asdf operations
2. **Version Constraints**: Support version ranges (e.g., "python ~> 3.13")
3. **Dependency Management**: Handle tool dependencies (e.g., poetry requires python)
4. **Rollback Capability**: Easy rollback to previous `.tool-versions` state
5. **Selective Updates**: Update specific tools rather than all-or-nothing

## Conclusion

This design provides a comprehensive asdf version management system that:
- Maintains consistency with existing Makefile patterns
- Provides feature parity with Homebrew package management
- Handles edge cases gracefully
- Integrates seamlessly with existing targets
- Remains idempotent and safe to re-run

The implementation is straightforward, following established patterns in the repository while adding powerful new capabilities for managing development tool versions.