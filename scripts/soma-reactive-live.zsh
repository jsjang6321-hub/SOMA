#!/bin/zsh
set -eu

soma_script_dir=${0:A:h}
soma_root=${SOMA_ROOT:-${soma_script_dir:h}}
soma_app_root=${SOMA_APP_ROOT:-"$HOME/Library/Application Support/SOMA/Applications/SOMA Subconscious.app"}
soma_binary="$soma_app_root/Contents/MacOS/soma-subconscious"
soma_native_helper="$soma_app_root/Contents/Helpers/soma-native-track"
soma_device_probe="$soma_app_root/Contents/Helpers/soma-obsbot-probe"
soma_child_guardian="$soma_app_root/Contents/Helpers/soma-child-guardian"
soma_calibration_selector="$soma_root/scripts/soma-select-gimbal-calibration.zsh"
soma_runtime_root="$soma_root/artifacts/subconscious/runtime"
soma_launcher_log="$soma_runtime_root/launcher/soma-reactive.log"

export SOMA_ROOT="$soma_root"
export SOMA_APP_ROOT="$soma_app_root"
export SOMA_RUNTIME_ROOT="$soma_runtime_root"
export SOMA_CHILD_GUARDIAN="$soma_child_guardian"

mkdir -p \
  "$soma_runtime_root/detail" \
  "$soma_runtime_root/important" \
  "$soma_runtime_root/actuator" \
  "$soma_runtime_root/ipc" \
  "$soma_runtime_root/views" \
  "$soma_runtime_root/host-screen" \
  "$soma_runtime_root/panorama" \
  "$soma_runtime_root/launcher"
chmod 700 "$soma_runtime_root/ipc"
chmod 700 "$soma_runtime_root/views"
chmod 700 "$soma_runtime_root/host-screen"

# A crash can orphan the per-runtime App Server and its MCP children. They
# retain stale session capabilities and contend for the same local embodiment
# socket, so a fresh runtime must reclaim only these exact SOMA-owned children
# before it creates its own generation.
function soma_reclaim_orphaned_children() {
  local soma_pid soma_parent soma_command
  local -a soma_stale_pids
  soma_stale_pids=()
  while read -r soma_pid soma_parent soma_command; do
    [[ "$soma_pid" == <-> ]] || continue
    if [[ "$soma_command" == *"/codex app-server --listen ws://127.0.0.1:"* ]] \
      && [[ "$soma_command" == *" --enable realtime_conversation "* ]] \
      && [[ "$soma_command" == *"mcp_servers.soma_embodiment.env"* ]]; then
      soma_stale_pids+=("$soma_pid")
    elif [[ "$soma_command" == "$soma_app_root/Contents/Helpers/soma-embodiment --socket $soma_runtime_root/ipc/embodiment-shadow.sock"* ]]; then
      soma_stale_pids+=("$soma_pid")
    fi
  done < <(/bin/ps -axo pid=,ppid=,command=)

  (( ${#soma_stale_pids[@]} == 0 )) && return
  for soma_pid in "${soma_stale_pids[@]}"; do
    /bin/kill -TERM "$soma_pid" 2>/dev/null || true
  done
  sleep 0.25
  for soma_pid in "${soma_stale_pids[@]}"; do
    /bin/kill -0 "$soma_pid" 2>/dev/null && /bin/kill -KILL "$soma_pid" 2>/dev/null || true
  done
}

soma_reclaim_orphaned_children

# Startup and crash output is normally quiet. Rotate it before each launch so
# failures that occur before the JSONL writers start remain bounded.
soma_launcher_max_bytes=1048576
soma_launcher_retained_files=4
if [[ -f "$soma_launcher_log" ]] && (( $(stat -f %z "$soma_launcher_log") >= soma_launcher_max_bytes )); then
  for ((soma_index = soma_launcher_retained_files - 2; soma_index >= 1; soma_index--)); do
    if [[ -f "$soma_launcher_log.$soma_index" ]]; then
      mv "$soma_launcher_log.$soma_index" "$soma_launcher_log.$((soma_index + 1))"
    fi
  done
  mv "$soma_launcher_log" "$soma_launcher_log.1"
fi
exec >>"$soma_launcher_log" 2>&1

# Load the SOMA layer (.env) configuration managed by the Control Center. It
# is sourced so OLLAMA_API_KEY and the layer toggles become process env for the
# runtime below. Owner-only perms are enforced by the Control Center on save.
soma_env_file="$HOME/Library/Application Support/SOMA/.env"
if [[ -f "$soma_env_file" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$soma_env_file"
  set +a
fi
soma_l1_aux_python=${SOMA_L05_VLM_PYTHON:-"$HOME/Library/Application Support/SOMA/venvs/l05/bin/python"}
soma_l1_aux_model=${SOMA_L05_VLM_MODEL:-"$HOME/Library/Application Support/SOMA/models/gemma-4-e2b-it-4bit"}
# The Control Center owns the layer configuration file and intentionally does
# not persist hardware identifiers.  `auto` selects the connected OBSBOT by
# name in the runtime; explicit IDs remain an override for multi-camera setups.
soma_video_id=${SOMA_VIDEO_ID:-auto}
soma_audio_id=${SOMA_AUDIO_ID:-auto}

# Deployment owns installation and signing. The runtime launcher must only
# execute that installed bundle: reinstalling from here would make a service
# restart recursively rebuild and restart itself.
if [[ ! -x "$soma_binary" ]]; then
  print -u2 -r -- "SOMA application is not installed. Run $soma_root/scripts/install-soma-subconscious-app.zsh first."
  exit 64
fi
if [[ ! -x "$soma_native_helper" || ! -x "$soma_device_probe" \
      || ! -x "$soma_child_guardian" || ! -x "$soma_calibration_selector" ]]; then
  print -u2 -r -- 'SOMA native device helpers are unavailable.'
  exit 64
fi

soma_selected_native_helper="$soma_native_helper"
soma_control_backend=open_uvc_xu
soma_device_probe_output=''
soma_device_contract=''
soma_device_probe_max_attempts=12
for ((soma_device_probe_attempt = 1; soma_device_probe_attempt <= soma_device_probe_max_attempts; soma_device_probe_attempt++)); do
  soma_device_probe_output=$("$soma_device_probe" --contract 2>&1 || true)
  print -r -- "$soma_device_probe_output"
  soma_device_contract=$(print -r -- "$soma_device_probe_output" | /usr/bin/sed -n 's/^SOMA_OBSBOT_CAPABILITY //p' | /usr/bin/tail -n 1)
  [[ -n "$soma_device_contract" ]] && break
  if (( soma_device_probe_attempt < soma_device_probe_max_attempts )); then
    print -r -- "OBSBOT capability probe attempt $soma_device_probe_attempt/$soma_device_probe_max_attempts did not acquire the USB control endpoint; retrying."
    sleep 0.5
  fi
done
soma_device_profile=$(print -r -- "$soma_device_contract" | /usr/bin/sed -n 's/.* profile=\([^ ]*\).*/\1/p')
: "${soma_device_profile:=unknown}"
if [[ -z "$soma_device_contract" ]]; then
  print -u2 -r -- "Unable to obtain an OBSBOT capability contract after $soma_device_probe_max_attempts attempts; starting perception without physical actuation."
fi
export SOMA_OBSBOT_CAPABILITY_CONTRACT="$soma_device_contract"
print -r -- "SOMA device profile: $soma_device_profile"
print -r -- "SOMA control backend: $soma_control_backend"

# Derive the L1 /api/chat endpoint from the configured host unless it was set
# explicitly (SOMA_L1_OLLAMA_ENDPOINT already resolves in the binary too).
if [[ -n "${OLLAMA_HOST:-}" && -z "${SOMA_L1_OLLAMA_ENDPOINT:-}" ]]; then
  export SOMA_L1_OLLAMA_ENDPOINT="${OLLAMA_HOST%/}/api/chat"
fi

# The local E2B worker is a visual audit tool. It is intentionally opt-in:
# continuous inference adds multi-gigabyte unified-memory pressure without
# participating in L0 fixation, social decisions, or the L2 conversation path.
soma_l05_vlm_args=()
if [[ "${SOMA_ENABLE_L05_VLM:-0}" == "1" ]]; then
  soma_l05_vlm_args=(
    --l1-auxiliary-vlm-python "$soma_l1_aux_python"
    --l1-auxiliary-vlm-worker "$soma_root/scripts/soma_l1_auxiliary_vlm_worker.py"
    --l1-auxiliary-vlm-model "$soma_l1_aux_model"
  )
fi

soma_geometry_args=()
if [[ -n "${SOMA_CAMERA_GEOMETRY_CALIBRATION:-}" ]]; then
  if [[ ! -f "$SOMA_CAMERA_GEOMETRY_CALIBRATION" ]]; then
    print -u2 -r -- 'SOMA_CAMERA_GEOMETRY_CALIBRATION does not exist.'
    exit 64
  fi
  soma_geometry_args=(--camera-geometry-calibration "$SOMA_CAMERA_GEOMETRY_CALIBRATION")
fi

soma_live_voice_args=()
if [[ "${SOMA_ENABLE_L2_LIVE_VOICE:-1}" == "1" ]]; then
  soma_live_voice_args=(
    --l2-live-voice
  )
fi

soma_panorama_args=()
# The OBSBOT UVC stream has shown unbounded IOSurface allocation under
# continuous panorama sampling. Keep the autonomous runtime stable by default;
# enable this experimental path only for an explicitly supervised sweep.
if [[ "${SOMA_ENABLE_PANORAMA:-0}" == "1" ]]; then
  soma_panorama_args=(
    --panorama-output "$soma_runtime_root/panorama/panorama-latest.jpg"
    --panorama-place-memory "$soma_runtime_root/panorama/place-memory.json"
  )
fi

soma_motion_args=()
if [[ "${SOMA_ENABLE_MOTION:-0}" == "1" ]]; then
  soma_native_bridge=$(print -r -- "$soma_device_contract" | /usr/bin/sed -n 's/.* native_bridge=\([^ ]*\).*/\1/p')
  soma_native_human_tracking=$(print -r -- "$soma_device_contract" | /usr/bin/sed -n 's/.* native_human_tracking=\([^ ]*\).*/\1/p')
  if [[ "$soma_native_bridge" == "true" && "$soma_device_profile" != "unknown" ]]; then
    if ! soma_external_calibration=$("$soma_calibration_selector" "$soma_root" "$soma_device_profile"); then
      print -u2 -r -- "SOMA_ENABLE_MOTION=1 requires a calibration created for $soma_device_profile."
      exit 64
    fi
    soma_motion_args=(
      --allow-embodiment-motor-control
      --embodiment-view-directory "$soma_runtime_root/views"
      --allow-camera-motion
      --native-gimbal-helper "$soma_selected_native_helper"
      --gimbal-output "$soma_runtime_root/actuator/gimbal.jsonl"
      --gimbal-trace-max-megabytes 32
      --gimbal-trace-retained-files 4
      --allow-external-gimbal-control
      --external-gimbal-calibration "$soma_external_calibration"
      --allow-autonomous-scan
    )
    soma_motion_args+=(--native-gimbal-shutdown-helper "$soma_native_helper")
    if [[ "$soma_native_human_tracking" == "true" ]]; then
      soma_motion_args+=(--allow-native-human-tracking)
    fi
  else
    print -r -- "SOMA physical actuation withheld for profile=$soma_device_profile until a native adapter and matching gimbal calibration are available."
  fi
fi

exec "$soma_binary" \
  --duration 0 \
  --video-id "$soma_video_id" \
  --audio-id "$soma_audio_id" \
  --output "$soma_runtime_root/detail/subconscious.jsonl" \
  --trace-max-megabytes 128 \
  --trace-retained-files 8 \
  --important-output "$soma_runtime_root/important/subconscious-important.jsonl" \
  --important-max-megabytes 16 \
  --important-retained-files 8 \
  "${soma_l05_vlm_args[@]}" \
  "${soma_geometry_args[@]}" \
  "${soma_live_voice_args[@]}" \
  "${soma_panorama_args[@]}" \
  --embodiment-shadow-socket "$soma_runtime_root/ipc/embodiment-shadow.sock" \
  --soma-settings "$HOME/Library/Application Support/SOMA/settings.json" \
  "${soma_motion_args[@]}"
