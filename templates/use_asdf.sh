# Helper for direnv to load asdf-managed environments
# This file is copied to ~/.config/direnv/lib/use_asdf.sh by `make direnv-setup`

use_asdf() {
  local envrc
  envrc="$(asdf direnv envrc "$PWD" 2>/dev/null || true)"
  if [ -n "$envrc" ] && [ -f "$envrc" ]; then
    source_env "$envrc"
  else
    # last resort: source asdf to expose shims
    if [ -n "${ASDF_DIR:-}" ] && [ -f "$ASDF_DIR/asdf.sh" ]; then . "$ASDF_DIR/asdf.sh"; fi
  fi
}
