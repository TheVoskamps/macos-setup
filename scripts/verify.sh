#!/usr/bin/env bash
# scripts/verify.sh — verify each tier's Brewfile installations, in tier
# order (core -> each opted-in profile, in list order -> host).
# - prints one line per entry (installed/missing/skipped + version if available)
# - supports single or double quotes and trailing options
# - shows full report; exits non-zero only if missing > 0
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/config_common.sh"

COMPUTER_NAME_LOWER="$(get_hostname)"

# Ordered profile list for this host (lowest priority first), read in the
# tagged form "<config.toml path>\t<profile name>" so every diagnostic
# below can name the file that declares the offending entry. Either tier
# can contribute a name — the host tier's config.toml or the
# repo-tracked default/config.toml — so a fixed filename in the message
# would send the user to the wrong file. Split on the FIRST tab only: a
# rejected name may itself contain one.
tagged_profiles=()
while IFS= read -r _line; do
  [[ -n "$_line" ]] || continue
  tagged_profiles+=("$_line")
done < <(get_profiles_tagged "$REPO_ROOT")

# Hard error: a profile name that get_profiles had to drop. Those names
# only warn on the apply paths (an abort would fire at Makefile parse
# time, before any prerequisite could report it), so verify is where the
# rejection becomes fatal.
invalid_profiles=()
while IFS= read -r _line; do
  [[ -n "$_line" ]] && invalid_profiles+=("$_line")
done < <(get_invalid_profiles_tagged "$REPO_ROOT")
if [[ ${#invalid_profiles[@]} -gt 0 ]]; then
  echo "[verify] ERROR: host '$COMPUTER_NAME_LOWER' has unusable profile name(s) in a 'profiles' array; each is shown below with the config.toml that declares it." >&2
  echo "[verify] A profile name may contain only letters, digits, '.', '_' and '-': it is both a directory name and a whitespace-delimited word in the Makefile's tier list." >&2
  for _line in "${invalid_profiles[@]}"; do
    echo "[verify]   - [${_line#*$'\t'}]  (in ${_line%%$'\t'*})" >&2
  done
  exit 1
fi

# Hard error: every profile named in the host's `profiles` array must
# have a matching profiles/<name>/ directory. An unknown profile name
# is a configuration bug — verify fails loudly rather than silently
# falling back. (install_filter.sh warns at install time instead.)
unknown_profiles=()
for _line in ${tagged_profiles[@]+"${tagged_profiles[@]}"}; do
  if [[ ! -d "$REPO_ROOT/profiles/${_line#*$'\t'}" ]]; then
    unknown_profiles+=("$_line")
  fi
done
if [[ ${#unknown_profiles[@]} -gt 0 ]]; then
  echo "[verify] ERROR: host '$COMPUTER_NAME_LOWER' names unknown profile(s) in a 'profiles' array; each is shown below with the config.toml that declares it:" >&2
  for _line in "${unknown_profiles[@]}"; do
    _p="${_line#*$'\t'}"
    echo "[verify]   - $_p  (no profiles/$_p/ directory; in ${_line%%$'\t'*})" >&2
  done
  exit 1
fi

section() { echo "=== $1 ==="; }

_title_case() {
  awk 'BEGIN{ for(i=1;i<ARGC;i++){ s=ARGV[i]; ARGV[i]=""; printf toupper(substr(s,1,1)) substr(s,2) (i<ARGC-1?" ":"") } }' "$@"
}

_cask_to_app() {
  local cask="$1"
  case "$cask" in
    zoom) echo "zoom.us";;
    visual-studio-code) echo "Visual Studio Code";;
    google-chrome) echo "Google Chrome";;
    firefox) echo "Firefox";;
    slack) echo "Slack";;
    discord) echo "Discord";;
    iterm2) echo "iTerm";;
    raycast) echo "Raycast";;
    telegram|telegram-desktop) echo "Telegram";;
    protonmail-bridge) echo "Proton Mail Bridge";;
    signal) echo "Signal";;
    whatsapp) echo "WhatsApp";;
    *)
      _title_case "$cask"
      ;;
  esac
}

print_line() {
  local typ="$1" name="$2" status="$3" extra="${4:-}"
  if [[ -n "$extra" ]]; then
    echo "${typ}:${name} (${status}) - ${extra}"
  else
    echo "${typ}:${name} (${status})"
  fi
}

_check_cask_installed() {
  local cask="$1"
  local app="$(_cask_to_app "$cask")"
  if [[ -d "/Applications/$app.app" || -d "$HOME/Applications/$app.app" ]]; then
    print_line "cask" "$cask" "installed" "$app"
    return 0
  fi
  if brew list --cask --versions "$cask" >/dev/null 2>&1; then
    print_line "cask" "$cask" "installed" "present in brew list"
    return 0
  fi
  print_line "cask" "$cask" "missing" ""
  return 1
}

_version_of() {
  local name="$1"
  "$name" --version 2>/dev/null && return 0
  "$name" version 2>/dev/null && return 0
  "$name" -V 2>/dev/null && return 0
  "$name" -v 2>/dev/null && return 0
  return 1
}

_check_brew_cli() {
  local name="$1"
  if command -v "$name" >/dev/null 2>&1; then
    local v=""; v="$(_version_of "$name")" || true
    if [[ -n "$v" ]]; then
      v="$(echo "$v" | head -n1)"
      print_line "brew" "$name" "installed" "$v"
    else
      print_line "brew" "$name" "installed" "on PATH"
    fi
    return 0
  fi
  if brew list --versions "$name" >/dev/null 2>&1; then
    print_line "brew" "$name" "installed" "in brew list (not on PATH?)"
    return 0
  fi
  print_line "brew" "$name" "missing" ""
  return 1
}

_check_tap() {
  local tap="$1"
  if brew tap | grep -qx "$tap"; then
    print_line "tap" "$tap" "present" ""
    return 0
  fi
  print_line "tap" "$tap" "missing" ""
  return 1
}

_check_mas() {
  local name="$1" id="$2"
  if ! command -v mas >/dev/null 2>&1; then
    print_line "mas" "$name" "skipped" "mas CLI not installed"
    return 2
  fi
  if mas list | awk '{print $1}' | grep -qx "$id"; then
    print_line "mas" "$name" "installed" "id $id"
    return 0
  fi
  if [[ -n "$name" ]] && { ls /Applications 2>/dev/null | grep -qi "^${name}\.app$"; }; then
    print_line "mas" "$name" "installed" "bundle present; mas not listing"
    return 0
  fi
  print_line "mas" "$name" "missing" "id $id"
  return 1
}

installed=0
missing=0
skipped=0

counting_wrapper() {
  local cmd="$1"; shift
  "$cmd" "$@"
  rc=$?
  case "$rc" in
    0) ((installed++)) ;;
    2) ((skipped++)) ;;
    *) ((missing++)) ;;
  esac
  return 0
}

process_brewfile() {
  local f="$1"
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    line="${raw%%#*}"
    line="$(echo "$line" | sed -E 's/^\s+|\s+$//g')"
    [[ -z "$line" ]] && continue

    if [[ "$line" =~ ^tap[[:space:]]+[\"\']([^\"\']+)[\"\'] ]]; then
      counting_wrapper _check_tap "${BASH_REMATCH[1]}"; continue
    fi

    if [[ "$line" =~ ^cask[[:space:]]+[\"\']([^\"\']+)[\"\'] ]]; then
      counting_wrapper _check_cask_installed "${BASH_REMATCH[1]}"; continue
    fi

    if [[ "$line" =~ ^brew[[:space:]]+[\"\']([^\"\']+)[\"\'] ]]; then
      counting_wrapper _check_brew_cli "${BASH_REMATCH[1]}"; continue
    fi

    if [[ "$line" =~ ^mas[[:space:]]+[\"\']([^\"\']+)[\"\'][[:space:]]*,[[:space:]]*id[:=][[:space:]]*([0-9]+) ]]; then
      counting_wrapper _check_mas "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"; continue
    fi
  done < "$f"
}

any_tier=0
while IFS= read -r tier; do
  brewfile="$tier/Brewfile"
  [[ -f "$brewfile" ]] || continue
  any_tier=1
  section "$(tier_label "$REPO_ROOT" "$tier")"
  process_brewfile "$brewfile"
done < <(tier_roots "$REPO_ROOT")

if [[ $any_tier -eq 0 ]]; then
  echo "[verify] No Brewfile found in any tier (core, profiles, host)" >&2
  exit 0
fi

section "summary"
echo "installed: $installed"
echo "missing:   $missing"
echo "skipped:   $skipped"
[[ $missing -gt 0 ]] && exit 1 || exit 0
