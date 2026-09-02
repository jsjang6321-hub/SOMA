#!/bin/zsh
set -u

soma_script_dir=${0:A:h}
soma_root=${soma_script_dir:h}
soma_lock="$soma_root/config/soma-dependencies.env"
soma_require_camera=1
soma_blockers=0
soma_ready=0
soma_information=0
typeset -a soma_actions
soma_actions=()

function soma_usage() {
  print -r -- 'Usage: scripts/soma-install-preflight.zsh [--require-camera|--allow-no-camera]'
}

while (( $# > 0 )); do
  case "$1" in
    --require-camera)
      soma_require_camera=1
      shift
      ;;
    --allow-no-camera)
      soma_require_camera=0
      shift
      ;;
    -h|--help)
      soma_usage
      exit 0
      ;;
    *)
      soma_usage >&2
      exit 64
      ;;
  esac
done

[[ -f "$soma_lock" ]] || { print -u2 -r -- "Missing dependency contract: $soma_lock"; exit 2; }
source "$soma_lock"
source "$soma_root/scripts/lib/soma-codex-locator.zsh"
autoload -Uz is-at-least

function soma_row() {
  local soma_state="$1"
  local soma_title="$2"
  local soma_detail="$3"
  printf '%-8s %-24s %s\n' "[$soma_state]" "$soma_title" "$soma_detail"
}

function soma_pass() {
  soma_row READY "$1" "$2"
  (( soma_ready += 1 ))
}

function soma_info() {
  soma_row INFO "$1" "$2"
  (( soma_information += 1 ))
}

function soma_block() {
  soma_row BLOCK "$1" "$2"
  soma_actions+=("$3")
  (( soma_blockers += 1 ))
}

function soma_find_ollama() {
  local soma_candidate
  for soma_candidate in \
    /Applications/Ollama.app/Contents/Resources/ollama \
    /opt/homebrew/bin/ollama \
    /usr/local/bin/ollama \
    "$(command -v ollama 2>/dev/null || true)"; do
    if [[ -n "$soma_candidate" && -x "$soma_candidate" ]]; then
      print -r -- "$soma_candidate"
      return
    fi
  done
}

print -r -- ''
print -r -- 'SOMA INSTALL PREFLIGHT'
print -r -- '============================================================'
print -r -- 'OBSBOT Center is not required. SOMA uses its own open UVC/XU driver.'
print -r -- ''

if [[ "$(uname -s 2>/dev/null)" == Darwin && "$(uname -m 2>/dev/null)" == arm64 ]]; then
  soma_pass 'Host' 'Apple Silicon macOS'
else
  soma_block 'Host' 'Apple Silicon macOS is required' \
    'Run SOMA on an Apple Silicon Mac.'
fi

soma_macos_version=$(/usr/bin/sw_vers -productVersion 2>/dev/null || true)
if [[ -n "$soma_macos_version" ]] \
    && is-at-least "$SOMA_MIN_RUNTIME_MACOS_VERSION" "$soma_macos_version"; then
  soma_pass 'macOS' "$soma_macos_version"
else
  soma_block 'macOS' "${soma_macos_version:-not detected}; requires $SOMA_MIN_RUNTIME_MACOS_VERSION+" \
    "Update macOS to $SOMA_MIN_RUNTIME_MACOS_VERSION or newer."
fi

soma_xcode_version=$(/usr/bin/xcodebuild -version 2>/dev/null || true)
soma_xcode_build=$(print -r -- "$soma_xcode_version" | /usr/bin/awk '/Build version/ { print $3 }')
if [[ "$soma_xcode_build" == "$SOMA_ARCFACE_XCODE_BUILD" ]]; then
  soma_pass 'Xcode' "$(print -r -- "$soma_xcode_version" | /usr/bin/head -n 1); build $soma_xcode_build"
else
  soma_block 'Xcode' "build ${soma_xcode_build:-not detected}; requires $SOMA_ARCFACE_XCODE_BUILD" \
    "Install full Xcode 26.6 build $SOMA_ARCFACE_XCODE_BUILD from https://developer.apple.com/download/, then run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
fi

soma_brew=$(command -v brew 2>/dev/null || true)
[[ -z "$soma_brew" && -x /opt/homebrew/bin/brew ]] && soma_brew=/opt/homebrew/bin/brew
if [[ -n "$soma_brew" && -x "$soma_brew" ]]; then
  soma_pass 'Homebrew' "$soma_brew"
else
  soma_block 'Homebrew' 'not installed' \
    'Install Homebrew from https://brew.sh, then rerun this installer.'
fi

soma_codex=$(soma_find_codex)
if [[ -z "$soma_codex" ]]; then
  soma_block 'Codex Live Voice' 'Codex is not installed' \
    'Install Codex from https://openai.com/codex/, open it, and sign in with the ChatGPT account that will run Live Voice.'
else
  soma_codex_login=$("$soma_codex" login status 2>&1 || true)
  soma_codex_server_help=$("$soma_codex" app-server --help 2>/dev/null || true)
  soma_codex_features=$("$soma_codex" features list 2>/dev/null || true)
  if [[ "$soma_codex_login" == 'Logged in'* \
        && "$soma_codex_server_help" == *'--listen <URL>'* \
        && "$soma_codex_features" == *realtime_conversation* ]]; then
    soma_pass 'Codex Live Voice' 'installed, signed in, realtime capability available'
  elif [[ "$soma_codex_login" != 'Logged in'* ]]; then
    soma_block 'Codex Live Voice' 'installed but not signed in' \
      'Open Codex and sign in with the ChatGPT account that will run Live Voice, then rerun this installer.'
  else
    soma_block 'Codex Live Voice' 'installed version lacks the required App Server capability' \
      'Update Codex from https://openai.com/codex/, then rerun this installer.'
  fi
fi

soma_ollama=$(soma_find_ollama)
if [[ -z "$soma_ollama" ]]; then
  soma_info 'Ollama / L1' "will be installed; $SOMA_DEFAULT_L1_MODEL will be provisioned"
else
  soma_ollama_list=$("$soma_ollama" list 2>/dev/null || true)
  if [[ -z "$soma_ollama_list" ]]; then
    soma_info 'Ollama / L1' "installed; setup will launch it and provision $SOMA_DEFAULT_L1_MODEL"
  elif print -r -- "$soma_ollama_list" \
      | /usr/bin/awk 'NR > 1 { print $1 }' \
      | /usr/bin/grep -Fxq "$SOMA_DEFAULT_L1_MODEL"; then
    soma_pass 'Ollama / L1' "$SOMA_DEFAULT_L1_MODEL is ready"
  else
    soma_info 'Ollama / L1' "responding; setup will provision $SOMA_DEFAULT_L1_MODEL"
  fi
fi

soma_usb_tree=$(/usr/sbin/ioreg -p IOUSB -l -w 0 2>/dev/null || true)
if [[ "$soma_usb_tree" == *'OBSBOT Tiny 2 Lite'* ]]; then
  soma_pass 'Camera' 'OBSBOT Tiny 2 Lite detected'
elif [[ "$soma_usb_tree" == *'OBSBOT Tiny 3 Lite'* ]]; then
  soma_pass 'Camera' 'OBSBOT Tiny 3 Lite detected'
elif [[ "$soma_usb_tree" == *OBSBOT* ]]; then
  soma_block 'Camera' 'an unsupported OBSBOT model is connected' \
    'Connect an OBSBOT Tiny 2 Lite or Tiny 3 Lite.'
elif (( soma_require_camera )); then
  soma_block 'Camera' 'no supported OBSBOT detected' \
    'Connect and power on an OBSBOT Tiny 2 Lite or Tiny 3 Lite, then rerun this installer.'
else
  soma_info 'Camera' 'not connected; physical acceptance will be deferred'
fi

soma_processes=$(/bin/ps -axo command= 2>/dev/null || true)
if print -r -- "$soma_processes" \
    | /usr/bin/grep -Eiq '/(OBSBOT[ _]Center|Obsbot Center)\.app/'; then
  soma_block 'OBSBOT Center' 'running and may own the USB control endpoint' \
    'Quit OBSBOT Center completely. It is not needed by SOMA.'
else
  soma_pass 'OBSBOT Center' 'not running; installation is not required'
fi

soma_info 'Local models' 'pinned Gemma L0.5 and ArcFace assets will be verified before activation'
soma_info 'Code signing' 'a machine-local persistent identity will be created when absent'
soma_info 'macOS permissions' 'Camera, Microphone, Speech Recognition, Accessibility, and Screen Recording prompts appear after installation'

print -r -- ''
print -r -- '------------------------------------------------------------'
if (( soma_blockers == 0 )); then
  print -r -- "READY: $soma_ready checks passed. The full installer can continue."
  print -r -- 'Large model downloads and the first ArcFace conversion can take time.'
  exit 0
fi

print -r -- "NOT READY: $soma_blockers blocking item(s)."
print -r -- ''
print -r -- 'NEXT ACTIONS'
local_index=1
for soma_action in "${soma_actions[@]}"; do
  print -r -- "  $local_index. $soma_action"
  (( local_index += 1 ))
done
print -r -- ''
print -r -- 'Resolve the items above and run Install SOMA.command again.'
exit 2
