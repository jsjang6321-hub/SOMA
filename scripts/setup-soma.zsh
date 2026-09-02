#!/bin/zsh
set -euo pipefail

soma_script_dir=${0:A:h}
soma_root=${soma_script_dir:h}
soma_lock="$soma_root/config/soma-dependencies.env"
soma_with_l05=0
soma_with_face_identity=0
soma_enable_motion=0
soma_full=0
soma_plan_only=0
soma_tool_path='/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin'
soma_env_stage=''

function soma_cleanup() {
  if [[ -n "$soma_env_stage" \
        && -f "$soma_env_stage" \
        && "${soma_env_stage:h}" == "$HOME/Library/Application Support/SOMA" \
        && "${soma_env_stage:t}" == .env.* ]]; then
    /bin/rm -f -- "$soma_env_stage"
  fi
}
trap soma_cleanup EXIT

function soma_usage() {
  print -r -- 'Usage: scripts/setup-soma.zsh [--full] [--with-l05] [--with-face-identity] [--enable-motion] [--plan]'
}

while (( $# > 0 )); do
  case "$1" in
    --with-l05)
      soma_with_l05=1
      shift
      ;;
    --with-face-identity)
      soma_with_face_identity=1
      shift
      ;;
    --enable-motion)
      soma_enable_motion=1
      shift
      ;;
    --full)
      soma_full=1
      soma_with_l05=1
      soma_with_face_identity=1
      soma_enable_motion=1
      shift
      ;;
    --plan)
      soma_plan_only=1
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

function soma_find_ollama() {
  local soma_candidate
  soma_candidate=$(PATH="$soma_tool_path" command -v ollama 2>/dev/null || true)
  if [[ -z "$soma_candidate" && -x /Applications/Ollama.app/Contents/Resources/ollama ]]; then
    soma_candidate=/Applications/Ollama.app/Contents/Resources/ollama
  fi
  print -r -- "$soma_candidate"
}

soma_bootstrap_arguments=()
if (( soma_with_l05 )); then
  soma_bootstrap_arguments+=(--with-l05)
fi
soma_cmake=$(PATH="$soma_tool_path" command -v cmake 2>/dev/null || true)
soma_opencv_ready=0
for soma_opencv_root in /opt/homebrew/opt/opencv /usr/local/opt/opencv; do
  if [[ -d "$soma_opencv_root/include/opencv5" ]]; then
    soma_opencv_ready=1
    break
  fi
done
soma_ollama=$(soma_find_ollama)
soma_python_ready=1
if (( soma_with_l05 || soma_with_face_identity )); then
  soma_python=$(PATH="$soma_tool_path" command -v python3.12 2>/dev/null || true)
  if [[ -z "$soma_python" && -x /opt/homebrew/opt/python@3.12/bin/python3.12 ]]; then
    soma_python=/opt/homebrew/opt/python@3.12/bin/python3.12
  fi
  [[ -n "$soma_python" && -x "$soma_python" ]] || soma_python_ready=0
fi
soma_skip_brew=0
if [[ -n "$soma_cmake" && -x "$soma_cmake" \
      && $soma_opencv_ready == 1 \
      && $soma_python_ready == 1 \
      && -n "$soma_ollama" && -x "$soma_ollama" ]]; then
  soma_skip_brew=1
  soma_bootstrap_arguments+=(--skip-brew)
fi

if (( soma_plan_only )); then
  print -r -- 'SOMA setup plan'
  print -r -- "  repository: $soma_root"
  print -r -- '  OBSBOT control: built-in open UVC/XU driver'
  print -r -- "  installation profile: $([[ $soma_full == 1 ]] && print full || print custom)"
  print -r -- "  L0.5 environment and pinned model: $([[ $soma_with_l05 == 1 ]] && print install || print preserve)"
  print -r -- "  ArcFace identity model: $([[ $soma_with_face_identity == 1 ]] && print install || print preserve)"
  print -r -- "  physical motion: $([[ $soma_enable_motion == 1 ]] && print enable || print preserve)"
  print -r -- "  Homebrew dependencies: $([[ $soma_skip_brew == 1 ]] && print already-present || print install)"
  print -r -- "  L1 model: $SOMA_DEFAULT_L1_MODEL"
  print -r -- "  signing identity: ensure $SOMA_CODESIGN_IDENTITY_NAME"
  if (( soma_full )); then
    print -r -- '  actions: guided preflight, bootstrap, local model provisioning, runtime configuration, L1 provisioning, tests, doctor, signed app installation, process verification'
  else
    print -r -- '  actions: bootstrap, selected model provisioning, runtime configuration, L1 provisioning, tests, doctor, signed app installation, process verification'
  fi
  exit 0
fi

if (( soma_full )); then
  "$soma_root/scripts/soma-install-preflight.zsh" --require-camera
fi

if (( soma_with_face_identity )); then
  soma_xcode_build=$(xcodebuild -version 2>/dev/null | awk '/Build version/ { print $3 }')
  if [[ "$soma_xcode_build" != "$SOMA_ARCFACE_XCODE_BUILD" ]]; then
    print -u2 -r -- "The full identity installation requires Xcode build $SOMA_ARCFACE_XCODE_BUILD; found ${soma_xcode_build:-unknown}."
    print -u2 -r -- 'Install and select that Xcode release, then rerun setup.'
    exit 2
  fi
fi

print -r -- '[1/9] Preparing locked dependencies'
"$soma_root/scripts/bootstrap-soma.zsh" "${soma_bootstrap_arguments[@]}"

print -r -- '[2/9] Ensuring the persistent local signing identity'
"$soma_root/scripts/ensure-soma-signing-identity.zsh"

print -r -- '[3/9] Provisioning optional local models'
if (( soma_with_l05 )); then
  "$soma_root/scripts/install-soma-l05-model.zsh"
fi
if (( soma_with_face_identity )); then
  "$soma_root/scripts/install-soma-face-identity-model.zsh"
fi

soma_env_file="$HOME/Library/Application Support/SOMA/.env"
function soma_set_env_value() {
  local soma_key="$1"
  local soma_value="$2"
  soma_env_stage=$(mktemp "${soma_env_file:h}/.env.XXXXXX")
  /usr/bin/awk -v key="$soma_key" -v value="$soma_value" '
    BEGIN { written = 0 }
    index($0, key "=") == 1 {
      if (!written) print key "=" value
      written = 1
      next
    }
    { print }
    END { if (!written) print key "=" value }
  ' "$soma_env_file" > "$soma_env_stage"
  chmod 600 "$soma_env_stage"
  /bin/mv -f "$soma_env_stage" "$soma_env_file"
  soma_env_stage=''
}

print -r -- '[4/9] Applying requested runtime capabilities'
if (( soma_enable_motion )); then
  soma_set_env_value SOMA_ENABLE_MOTION 1
fi
if (( soma_with_l05 )); then
  soma_set_env_value SOMA_ENABLE_L05_VLM 1
fi

print -r -- '[5/9] Ensuring the L1 model is available'
soma_ollama=$(soma_find_ollama)
[[ -n "$soma_ollama" && -x "$soma_ollama" ]] \
  || { print -u2 -r -- 'Ollama was not installed by bootstrap.'; exit 2; }
if ! "$soma_ollama" list >/dev/null 2>&1; then
  /usr/bin/open -gj /Applications/Ollama.app >/dev/null 2>&1 || true
  soma_ollama_ready=0
  for _ in {1..30}; do
    if "$soma_ollama" list >/dev/null 2>&1; then
      soma_ollama_ready=1
      break
    fi
    sleep 1
  done
  (( soma_ollama_ready == 1 )) \
    || { print -u2 -r -- 'Ollama did not become ready within 30 seconds.'; exit 2; }
fi
if ! "$soma_ollama" list | /usr/bin/awk 'NR > 1 {print $1}' \
    | /usr/bin/grep -Fxq "$SOMA_DEFAULT_L1_MODEL"; then
  "$soma_ollama" pull "$SOMA_DEFAULT_L1_MODEL"
fi

print -r -- '[6/9] Running the verification suite'
/usr/bin/env swift test --package-path "$soma_root"
/usr/bin/env swift run --package-path "$soma_root" soma-core-check

print -r -- '[7/9] Checking runtime prerequisites'
"$soma_root/scripts/soma-doctor.zsh" --runtime

print -r -- '[8/9] Installing the signed local application'
"$soma_root/scripts/install-soma-subconscious-app.zsh"

print -r -- '[9/9] Verifying the active runtime'
"$soma_root/scripts/soma.zsh" status
soma_app_binary="$HOME/Library/Application Support/SOMA/Applications/SOMA Subconscious.app/Contents/MacOS/soma-subconscious"
soma_runtime_pid=''
soma_runtime_command=''
function soma_read_runtime_process() {
  /bin/ps -axo pid=,command= | /usr/bin/awk -v binary="$soma_app_binary" '
    {
      pid = $1
      sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", $0)
      if (match_pid == "" && ($0 == binary || index($0, binary " ") == 1)) {
        match_pid = pid
        match_command = $0
      }
    }
    END { if (match_pid != "") print match_pid "\t" match_command }
  '
}

function soma_wait_for_runtime() {
  local soma_required_argument=${1:-}
  local soma_runtime_record=''
  soma_runtime_pid=''
  soma_runtime_command=''
  for _ in {1..45}; do
    soma_runtime_record=$(soma_read_runtime_process)
    if [[ -n "$soma_runtime_record" ]]; then
      soma_runtime_pid=${soma_runtime_record%%$'\t'*}
      soma_runtime_command=${soma_runtime_record#*$'\t'}
      if [[ -z "$soma_required_argument" || "$soma_runtime_command" == *" $soma_required_argument "* || "$soma_runtime_command" == *" $soma_required_argument" ]]; then
        return 0
      fi
    fi
    sleep 1
  done
  return 1
}

function soma_native_bridge_state() {
  local soma_expected_pid=$1
  local soma_detail_root="$soma_root/artifacts/subconscious/runtime/detail"
  local -a soma_detail_files
  soma_detail_files=("$soma_detail_root"/*.jsonl(N))
  (( ${#soma_detail_files[@]} > 0 )) || return 0
  /usr/bin/awk -v marker="runtime_pid=$soma_expected_pid" '
    index($0, "\"source\":\"attention_gimbal_bridge\"") && index($0, marker) {
      if (index($0, "\"state\":\"ready\"")) state = "ready"
      if (index($0, "\"state\":\"fault\"") || index($0, "\"state\":\"stopped\"")) state = "failed"
    }
    END { if (state != "") print state }
  ' "${soma_detail_files[@]}"
}

function soma_wait_for_native_bridge() {
  local soma_expected_pid=$1
  local soma_bridge_state=''
  local soma_current_record=''
  for _ in {1..30}; do
    soma_bridge_state=$(soma_native_bridge_state "$soma_expected_pid")
    if [[ "$soma_bridge_state" == ready ]]; then
      sleep 2
      soma_bridge_state=$(soma_native_bridge_state "$soma_expected_pid")
      soma_current_record=$(soma_read_runtime_process)
      [[ "$soma_bridge_state" == ready \
          && "${soma_current_record%%$'\t'*}" == "$soma_expected_pid" ]] && return 0
      return 1
    fi
    [[ "$soma_bridge_state" == failed ]] && return 1
    sleep 1
  done
  return 1
}

if ! soma_wait_for_runtime; then
  print -u2 -r -- 'The LaunchAgent loaded, but the SOMA runtime process did not remain active.'
  exit 2
fi

if (( soma_enable_motion )); then
  soma_motion_verified=0
  soma_restart_attempted=0
  while (( soma_restart_attempted <= 1 )); do
    if [[ "$soma_runtime_command" == *' --allow-camera-motion '* ]] \
        && soma_wait_for_native_bridge "$soma_runtime_pid"; then
      soma_motion_verified=1
      break
    fi
    (( soma_restart_attempted == 1 )) && break
    print -r -- 'The installed runtime has not established its OBSBOT motor bridge; retrying once.'
    "$soma_root/scripts/soma.zsh" restart
    soma_restart_attempted=1
    soma_wait_for_runtime --allow-camera-motion || true
  done
  if (( soma_motion_verified == 0 )); then
    if /usr/sbin/system_profiler SPCameraDataType SPUSBDataType 2>/dev/null | /usr/bin/grep -Fqi 'OBSBOT'; then
      print -u2 -r -- 'A supported OBSBOT is connected, but the installed runtime did not establish its physical motor bridge.'
      print -u2 -r -- 'Inspect artifacts/subconscious/runtime/launcher/soma-reactive.log and the latest detail trace; setup is not complete.'
      exit 2
    fi
    print -r -- 'No connected OBSBOT was detected; physical motion verification is deferred until hardware is attached.'
  fi
fi

if [[ -n "$soma_runtime_pid" ]]; then
  print -r -- "SOMA setup complete (runtime pid $soma_runtime_pid)."
else
  print -r -- 'SOMA setup complete; hardware activation is deferred.'
fi
print -r -- 'If macOS prompts, grant Camera, Microphone, Speech Recognition, Accessibility, and Screen Recording access.'
