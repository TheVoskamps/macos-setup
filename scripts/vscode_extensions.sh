#!/usr/bin/env bash
# Install VS Code / Cursor extensions into a single target editor.
# Usage: ./scripts/vscode_extensions.sh <code|cursor>
# - Never fails the build: always exits 0 (unless CLI missing).
# - Logs per-extension status: OK / SKIP (Cursor registry) / FAIL.

set -u

if (( $# != 1 )); then
  echo "Usage: $0 <code|cursor>" >&2
  exit 2
fi

target="$1"
if [[ "$target" != "code" && "$target" != "cursor" ]]; then
  echo "Invalid target: $target (expected 'code' or 'cursor')" >&2
  exit 2
fi

extensions=(
  aaron-bond.better-comments
  amazonwebservices.aws-toolkit-vscode
  antfu.pnpm-catalog-lens
  atlassian.atlascode
  christian-kohler.path-intellisense
  codezombiech.gitignore
  davidanson.vscode-markdownlint
  dbaeumer.vscode-eslint
  eamodio.gitlens
  esbenp.prettier-vscode
  formulahendry.auto-rename-tag
  GitHub.vscode-pull-request-github
  mhutchie.git-graph
  ms-python.debugpy
  ms-python.python
  redhat.vscode-xml
  redhat.vscode-yaml
  shd101wyy.markdown-preview-enhanced
  t-nano.markdown-to-confluence-vscode
  vikyd.vscode-fold-level
  Vue.volar
  yzane.markdown-pdf
)

if ! command -v "$target" >/dev/null 2>&1; then
  echo "WARN: $target CLI not found; skipping installs" >&2
  exit 0
fi

ok=0 skip=0 fail=0

install_one() {
  local bin="$1" ext="$2"
  local out rc

  # Do NOT use set -e; capture rc ourselves.
  out="$("$bin" --install-extension "$ext" 2>&1)"; rc=$?

  if (( rc == 0 )); then
    echo "$bin: OK    $ext"
    return 0
  fi

  # Cursor sometimes lacks marketplace entries
  if [[ "$bin" == "cursor" ]] && [[ "$out" =~ [Nn]ot[[:space:]]+found|No[[:space:]]+matching[[:space:]]+extension ]]; then
    echo "$bin: SKIP  $ext (not in Cursor registry)"
    return 10
  fi

  # VS Code may return non-zero for “already installed” on some versions; treat that as OK.
  if [[ "$bin" == "code" ]] && [[ "$out" =~ [Aa]lready[[:space:]]+installed ]]; then
    echo "$bin: OK    $ext (already installed)"
    return 0
  fi

  echo "$bin: FAIL  $ext"
  echo "$out" >&2
  return 1
}

for ext in "${extensions[@]}"; do
  if install_one "$target" "$ext"; then
    ((ok++))
  else
    rc=$?
    if (( rc == 10 )); then
      ((skip++))
    else
      ((fail++))
    fi
  fi
done

echo "Summary for $target: OK=$ok SKIP=$skip FAIL=$fail"
# **Always succeed** so 'make 09' doesn't stop on extension issues.
exit 0