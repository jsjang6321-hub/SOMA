# Shared Codex CLI discovery for installer and runtime diagnostics. Application
# display names are not part of the contract; any top-level macOS application
# bundle containing the embedded Codex executable is eligible.
function soma_find_codex() {
  local soma_candidate soma_application_root soma_application
  local -a soma_candidates
  soma_candidates=(
    "${SOMA_CODEX_BINARY:-}"
    "$(command -v codex 2>/dev/null || true)"
    "$HOME/.local/bin/codex"
    /opt/homebrew/bin/codex
    /usr/local/bin/codex
  )
  for soma_candidate in "${soma_candidates[@]}"; do
    if [[ -n "$soma_candidate" && -x "$soma_candidate" ]]; then
      print -r -- "$soma_candidate"
      return 0
    fi
  done

  setopt local_options null_glob
  for soma_application_root in /Applications "$HOME/Applications"; do
    for soma_application in "$soma_application_root"/*.app; do
      for soma_candidate in \
        "$soma_application/Contents/Resources/codex" \
        "$soma_application/Contents/MacOS/codex"; do
        if [[ -x "$soma_candidate" ]]; then
          print -r -- "$soma_candidate"
          return 0
        fi
      done
    done
  done
  return 1
}
