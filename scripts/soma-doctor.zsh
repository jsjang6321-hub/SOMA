#!/bin/zsh
set -u

soma_script_dir=${0:A:h}
soma_root=${soma_script_dir:h}
soma_mode=${1:---build}
soma_failures=0
soma_warnings=0
soma_lock="$soma_root/config/soma-dependencies.env"

if [[ "$soma_mode" != "--build" && "$soma_mode" != "--runtime" ]]; then
  print -u2 -r -- 'Usage: scripts/soma-doctor.zsh [--build|--runtime]'
  exit 64
fi

if [[ ! -f "$soma_lock" ]]; then
  print -u2 -r -- "fail missing dependency lock: $soma_lock"
  exit 1
fi
source "$soma_lock"
source "$soma_root/scripts/lib/soma-model-contracts.zsh"
source "$soma_root/scripts/lib/soma-codex-locator.zsh"
autoload -Uz is-at-least

soma_install_scripts=(
  "$soma_root/scripts/soma-install-preflight.zsh"
  "$soma_root/scripts/setup-soma.zsh"
  "$soma_root/scripts/bootstrap-soma.zsh"
  "$soma_root/scripts/install-soma-l05-model.zsh"
  "$soma_root/scripts/install-soma-face-identity-model.zsh"
  "$soma_root/scripts/ensure-soma-signing-identity.zsh"
  "$soma_root/scripts/generate-soma-brand-assets.zsh"
  "$soma_root/scripts/install-soma-subconscious-app.zsh"
  "$soma_root/Install SOMA.command"
)

function soma_ok() {
  print -r -- "ok   $1"
}

function soma_fail() {
  print -u2 -r -- "fail $1"
  (( soma_failures += 1 ))
}

function soma_warn() {
  print -r -- "warn $1"
  (( soma_warnings += 1 ))
}

function soma_valid_profile_gimbal_calibration() {
  local soma_profile=$1
  local soma_path="$soma_root/config/obsbot/${soma_profile//_/-}-gimbal.json"
  [[ -f "$soma_path" ]] || return 1
  [[ "$(/usr/bin/plutil -extract schemaVersion raw -o - "$soma_path" 2>/dev/null)" == 2 \
      && "$(/usr/bin/plutil -extract deviceIdentifier raw -o - "$soma_path" 2>/dev/null)" == "$soma_profile" ]]
}

function soma_check_minimum_version() {
  local soma_name="$1"
  local soma_actual="$2"
  local soma_minimum="$3"
  if [[ -n "$soma_actual" ]] && is-at-least "$soma_minimum" "$soma_actual"; then
    soma_ok "$soma_name $soma_actual"
  else
    soma_fail "$soma_name ${soma_actual:-unknown}; requires >= $soma_minimum"
  fi
}

soma_install_contract_valid=1
for soma_install_script in "${soma_install_scripts[@]}"; do
  if [[ ! -x "$soma_install_script" ]] || ! /bin/zsh -n "$soma_install_script"; then
    soma_install_contract_valid=0
  fi
done
soma_brand_mark="$soma_root/assets/branding/soma-mark.png"
soma_menu_brand_mark="$soma_root/Sources/SOMAMenuBar/Resources/SOMALogoMark.png"
soma_brand_generator="$soma_root/scripts/generate-soma-brand-assets.swift"
soma_brand_info="$soma_root/Sources/SOMASubconscious/Info.plist"
if [[ -x "$soma_brand_generator" \
      && -f "$soma_root/assets/branding/soma-original.png" \
      && -f "$soma_brand_mark" \
      && -f "$soma_root/assets/branding/soma-app-icon.png" \
      && -f "$soma_root/assets/branding/SOMA.icns" \
      && -f "$soma_menu_brand_mark" \
      && "$(/usr/bin/shasum -a 256 "$soma_brand_mark" | /usr/bin/awk '{ print $1 }')" \
        == "$(/usr/bin/shasum -a 256 "$soma_menu_brand_mark" | /usr/bin/awk '{ print $1 }')" \
      && "$(/usr/bin/plutil -extract CFBundleIconFile raw -o - "$soma_brand_info" 2>/dev/null)" \
        == 'SOMA.icns' ]] \
    && /usr/bin/xcrun swiftc -parse "$soma_brand_generator" \
    && "$soma_root/scripts/generate-soma-brand-assets.zsh" --check; then
  soma_ok 'canonical SOMA branding and packaged icon assets'
else
  soma_fail 'SOMA branding assets are missing, divergent, or not reproducible'
fi
soma_full_plan=$(/bin/zsh "$soma_root/scripts/setup-soma.zsh" --full --plan 2>/dev/null || true)
soma_custom_plan=$(/bin/zsh "$soma_root/scripts/setup-soma.zsh" --with-l05 --plan 2>/dev/null || true)
soma_setup_source=$(/bin/cat "$soma_root/scripts/setup-soma.zsh")
soma_preflight_line=$(print -r -- "$soma_setup_source" \
  | /usr/bin/grep -nF '"$soma_root/scripts/soma-install-preflight.zsh" --require-camera' \
  | /usr/bin/head -n 1 \
  | /usr/bin/cut -d: -f1)
soma_bootstrap_line=$(print -r -- "$soma_setup_source" \
  | /usr/bin/grep -nF '"$soma_root/scripts/bootstrap-soma.zsh"' \
  | /usr/bin/head -n 1 \
  | /usr/bin/cut -d: -f1)
if (( soma_install_contract_valid == 1 )) \
    && [[ "$soma_full_plan" == *'installation profile: full'* \
          && "$soma_full_plan" == *'L0.5 environment and pinned model: install'* \
          && "$soma_full_plan" == *'ArcFace identity model: install'* \
          && "$soma_full_plan" == *'physical motion: enable'* \
          && "$soma_full_plan" == *'actions: guided preflight, bootstrap'* \
          && "$soma_custom_plan" != *'guided preflight'* \
          && "$soma_setup_source" == *'if (( soma_full )); then
  "$soma_root/scripts/soma-install-preflight.zsh" --require-camera
fi'* \
          && -n "$soma_preflight_line" \
          && -n "$soma_bootstrap_line" ]] \
    && (( soma_preflight_line < soma_bootstrap_line )); then
  soma_ok 'idempotent full-install orchestration contract'
else
  soma_fail 'full-install scripts are missing, non-executable, invalid, or incomplete'
fi

if [[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]]; then
  soma_ok 'Apple Silicon macOS'
else
  soma_fail 'Apple Silicon macOS is required by the native SOMA runtime'
fi

soma_macos_version=$(/usr/bin/sw_vers -productVersion 2>/dev/null || true)
soma_check_minimum_version 'macOS' "$soma_macos_version" "$SOMA_MIN_MACOS_VERSION"

if command -v swift >/dev/null 2>&1; then
  soma_swift_line=$(swift --version 2>/dev/null | head -n 1)
  soma_swift_version=$(print -r -- "$soma_swift_line" | sed -nE 's/.*Apple Swift version ([0-9]+(\.[0-9]+){1,2}).*/\1/p')
  soma_check_minimum_version 'Swift' "$soma_swift_version" "$SOMA_MIN_SWIFT_VERSION"
else
  soma_fail 'Swift is unavailable; install current Xcode command-line tools'
fi

if /usr/bin/xcrun --find clang >/dev/null 2>&1; then
  soma_ok 'Xcode command-line tools'
else
  soma_fail 'Xcode command-line tools are unavailable'
fi

soma_opencv_prefix=${SOMA_OPENCV_PREFIX:-}
if [[ -z "$soma_opencv_prefix" ]] && command -v brew >/dev/null 2>&1; then
  soma_opencv_prefix=$(brew --prefix opencv 2>/dev/null || true)
fi
if [[ -z "$soma_opencv_prefix" ]]; then
  for soma_candidate in /opt/homebrew/opt/opencv /usr/local/opt/opencv; do
    if [[ -d "$soma_candidate" ]]; then
      soma_opencv_prefix="$soma_candidate"
      break
    fi
  done
fi
soma_opencv_version=''
soma_opencv_core=''
soma_opencv_minos=''
if [[ -n "$soma_opencv_prefix" && -x "$soma_opencv_prefix/bin/opencv_version" ]]; then
  soma_opencv_version=$("$soma_opencv_prefix/bin/opencv_version" 2>/dev/null || true)
fi
if [[ -n "$soma_opencv_prefix" && -d "$soma_opencv_prefix/lib" ]]; then
  soma_opencv_core=$(find "$soma_opencv_prefix/lib" -maxdepth 1 -name 'libopencv_core*.dylib' -print -quit 2>/dev/null || true)
fi
if [[ -n "$soma_opencv_core" ]]; then
  soma_opencv_minos=$(/usr/bin/otool -l "$soma_opencv_core" 2>/dev/null | awk '
    $1 == "cmd" && $2 == "LC_BUILD_VERSION" { in_build = 1; next }
    in_build && $1 == "minos" { print $2; exit }
  ')
fi
if [[ -n "$soma_opencv_prefix" \
      && -d "$soma_opencv_prefix/include/opencv5" \
      && -n "$soma_opencv_core" \
      && "${soma_opencv_version%%.*}" == "$SOMA_OPENCV_MAJOR_VERSION" ]]; then
  soma_ok "OpenCV $soma_opencv_version at $soma_opencv_prefix"
  if [[ -n "$soma_opencv_minos" ]] && is-at-least "$soma_opencv_minos" "$soma_macos_version"; then
    soma_ok "OpenCV host compatibility (dylib min macOS $soma_opencv_minos)"
  else
    soma_fail "OpenCV dylib requires macOS ${soma_opencv_minos:-unknown}; host is $soma_macos_version"
  fi
else
  soma_fail "OpenCV $SOMA_OPENCV_MAJOR_VERSION is unavailable; run brew bundle or set SOMA_OPENCV_PREFIX"
fi

if (cd "$soma_root" && shasum -a 256 -c config/bundled-models.sha256 >/dev/null 2>&1); then
  soma_ok 'complete bundled Core ML model manifests'
else
  soma_fail 'bundled Core ML files differ from config/bundled-models.sha256'
fi

soma_cmake=${SOMA_CMAKE:-$(command -v cmake 2>/dev/null || true)}
if [[ -z "$soma_cmake" ]]; then
  for soma_candidate in /opt/homebrew/bin/cmake /usr/local/bin/cmake; do
    if [[ -x "$soma_candidate" ]]; then
      soma_cmake="$soma_candidate"
      break
    fi
  done
fi
if [[ -n "$soma_cmake" && -x "$soma_cmake" ]]; then
  soma_native_check_root="$soma_root/.build/soma-doctor-native"
  if "$soma_cmake" -S "$soma_root/Sources/SOMANativeTracking" -B "$soma_native_check_root" \
      -DCMAKE_BUILD_TYPE=Release >/dev/null \
      && "$soma_cmake" --build "$soma_native_check_root" --parallel >/dev/null \
      && [[ -x "$soma_native_check_root/soma-native-track" \
            && -x "$soma_native_check_root/soma-obsbot-probe" ]] \
      && "$soma_cmake" --build "$soma_native_check_root" --target test >/dev/null \
      && ! /usr/bin/otool -L \
          "$soma_native_check_root/soma-native-track" \
          "$soma_native_check_root/soma-obsbot-probe" \
          | /usr/bin/grep -Fq 'libdev'; then
    soma_ok 'open OBSBOT UVC/XU helpers and profile protocol tests (no proprietary runtime linkage)'
  else
    soma_fail 'open OBSBOT UVC/XU helper build or linkage validation failed'
  fi
else
  soma_fail 'CMake is unavailable; run brew bundle or set SOMA_CMAKE'
fi

if [[ "$soma_mode" == "--runtime" ]]; then
  soma_check_minimum_version 'full-runtime macOS' "$soma_macos_version" "$SOMA_MIN_RUNTIME_MACOS_VERSION"
  soma_requested_codesign_identity=${SOMA_CODESIGN_IDENTITY:-$SOMA_CODESIGN_IDENTITY_NAME}

  if [[ -n "$soma_cmake" && -x "$soma_cmake" ]]; then
    soma_cmake_version=$("$soma_cmake" --version 2>/dev/null | sed -nE '1s/.* ([0-9]+(\.[0-9]+){1,2}).*/\1/p')
    soma_check_minimum_version 'CMake' "$soma_cmake_version" "$SOMA_MIN_CMAKE_VERSION"
  else
    soma_fail 'CMake is unavailable; run brew bundle or set SOMA_CMAKE'
  fi

  if /usr/bin/security find-identity -v -p codesigning \
      | /usr/bin/grep -Fq \"$soma_requested_codesign_identity\"; then
    soma_ok "persistent local code-signing identity $soma_requested_codesign_identity"
  else
    soma_fail "missing usable code-signing identity: $soma_requested_codesign_identity"
  fi

  soma_env_file=${SOMA_ENV_FILE:-"$HOME/Library/Application Support/SOMA/.env"}
  SOMA_ENABLE_L2_LIVE_VOICE=1
  SOMA_ENABLE_L05_VLM=0
  SOMA_L1_MODEL="$SOMA_DEFAULT_L1_MODEL"
  OLLAMA_HOST=http://127.0.0.1:11434
  if [[ -f "$soma_env_file" ]]; then
    soma_env_mode=$(stat -f '%Lp' "$soma_env_file" 2>/dev/null || true)
    soma_env_uid=$(stat -f '%u' "$soma_env_file" 2>/dev/null || true)
    soma_env_parent=${soma_env_file:h}
    soma_env_parent_mode=$(stat -f '%Lp' "$soma_env_parent" 2>/dev/null || true)
    soma_env_parent_uid=$(stat -f '%u' "$soma_env_parent" 2>/dev/null || true)
    if [[ "$soma_env_mode" == 600 \
          && "$soma_env_uid" == "$(id -u)" \
          && "$soma_env_parent_mode" == 700 \
          && "$soma_env_parent_uid" == "$(id -u)" ]]; then
      soma_ok "$soma_env_file (owner-only)"
      set -a
      source "$soma_env_file"
      set +a
    else
      soma_fail 'runtime configuration must be user-owned mode 0600 inside a user-owned mode 0700 directory'
    fi
  else
    soma_fail "runtime configuration is missing: $soma_env_file"
  fi

  if [[ -n "${SOMA_CAMERA_GEOMETRY_CALIBRATION:-}" ]]; then
    if [[ -f "$SOMA_CAMERA_GEOMETRY_CALIBRATION" ]]; then
      soma_ok 'camera geometry calibration'
    else
      soma_fail "camera geometry calibration is missing: $SOMA_CAMERA_GEOMETRY_CALIBRATION"
    fi
  fi
  if [[ "${SOMA_ENABLE_MOTION:-0}" == 1 ]]; then
    if [[ -n "${SOMA_EXTERNAL_GIMBAL_CALIBRATION:-}" \
          && -f "$SOMA_EXTERNAL_GIMBAL_CALIBRATION" ]]; then
      soma_ok 'explicit external gimbal calibration for enabled motion'
    elif soma_valid_profile_gimbal_calibration tiny_2_lite \
        && soma_valid_profile_gimbal_calibration tiny_3_lite; then
      soma_ok 'bundled device-profile gimbal calibrations for enabled motion'
    else
      soma_fail 'SOMA_ENABLE_MOTION=1 requires an explicit or bundled device-profile gimbal calibration'
    fi
  else
    soma_ok 'physical motion disabled by configuration'
  fi

  soma_ollama=$(command -v ollama 2>/dev/null || true)
  if [[ -z "$soma_ollama" && -x /Applications/Ollama.app/Contents/Resources/ollama ]]; then
    soma_ollama=/Applications/Ollama.app/Contents/Resources/ollama
  fi
  if [[ -n "$soma_ollama" && -x "$soma_ollama" ]]; then
    soma_ollama_version=$("$soma_ollama" --version 2>/dev/null | sed -nE 's/.* ([0-9]+(\.[0-9]+){1,2}).*/\1/p')
    soma_check_minimum_version 'Ollama' "$soma_ollama_version" "$SOMA_MIN_OLLAMA_VERSION"
    soma_ollama_list=$("$soma_ollama" list 2>/dev/null || true)
    if print -r -- "$soma_ollama_list" | awk 'NR > 1 {print $1}' | grep -Fxq "${SOMA_L1_MODEL:-$SOMA_DEFAULT_L1_MODEL}"; then
      soma_ok "Ollama model ${SOMA_L1_MODEL:-$SOMA_DEFAULT_L1_MODEL} at ${OLLAMA_HOST:-http://127.0.0.1:11434}"
    else
      soma_fail "Ollama server/model unavailable: ${SOMA_L1_MODEL:-$SOMA_DEFAULT_L1_MODEL}"
    fi
  else
    soma_fail 'Ollama is unavailable; install it from Brewfile and start its local server'
  fi

  soma_hermes=${SOMA_HERMES_BINARY:-}
  if [[ -n "$soma_hermes" && ! -x "$soma_hermes" ]]; then
    soma_fail "configured Hermes Agent executable is unavailable: $soma_hermes"
  else
    if [[ -z "$soma_hermes" && -x "$HOME/.local/bin/hermes" ]]; then
      soma_hermes="$HOME/.local/bin/hermes"
    fi
    if [[ -z "$soma_hermes" ]]; then
      soma_hermes=$(command -v hermes 2>/dev/null || true)
    fi
    if [[ -n "$soma_hermes" && -x "$soma_hermes" ]]; then
      soma_hermes_version=$("$soma_hermes" --version 2>/dev/null | head -n 1)
      soma_ok "${soma_hermes_version:-Hermes Agent} at $soma_hermes"
    else
      soma_warn 'optional Hermes Agent is unavailable; L2 task delegation is disabled'
    fi
  fi

  if [[ "${SOMA_ENABLE_L2_LIVE_VOICE:-1}" == 1 ]]; then
    soma_codex=$(soma_find_codex 2>/dev/null || true)
    soma_codex_login=''
    if [[ -n "$soma_codex" && -x "$soma_codex" ]]; then
      soma_codex_login=$("$soma_codex" login status 2>&1 || true)
    fi
    if [[ -n "$soma_codex" \
          && -x "$soma_codex" \
          && "$soma_codex_login" == 'Logged in'* \
          && "$("$soma_codex" app-server --help 2>/dev/null)" == *'--listen <URL>'* \
          && "$("$soma_codex" features list 2>/dev/null)" == *realtime_conversation* ]]; then
      soma_ok "Codex Live Voice capability at $soma_codex"
    else
      soma_fail 'L2 Live Voice is enabled but a compatible signed-in Codex installation is unavailable'
    fi
  else
    soma_ok 'L2 Live Voice disabled by configuration'
  fi

  if [[ "${SOMA_ENABLE_L05_VLM:-0}" == 1 ]]; then
    soma_check_minimum_version 'L0.5 macOS' "$soma_macos_version" "$SOMA_MIN_L05_MACOS_VERSION"
    soma_l05_python=${SOMA_L05_VLM_PYTHON:-"$HOME/Library/Application Support/SOMA/venvs/l05/bin/python"}
    soma_l05_model=${SOMA_L05_VLM_MODEL:-"$HOME/Library/Application Support/SOMA/models/$SOMA_L05_MODEL_DIRECTORY"}
    if [[ -x "$soma_l05_python" ]]; then
      soma_python_version=$("$soma_l05_python" --version 2>&1 | sed -nE 's/Python ([0-9]+(\.[0-9]+){1,2}).*/\1/p')
      if [[ "$soma_python_version" == "$SOMA_L05_PYTHON_VERSION"* ]]; then
        soma_ok "L0.5 Python $soma_python_version"
      else
        soma_fail "L0.5 Python $soma_python_version; expected $SOMA_L05_PYTHON_VERSION.x"
      fi
      soma_l05_pip_version=$("$soma_l05_python" -m pip --version 2>/dev/null | sed -nE 's/^pip ([0-9]+(\.[0-9]+){1,2}).*/\1/p')
      if [[ "$soma_l05_pip_version" == "$SOMA_L05_PIP_VERSION" ]]; then
        soma_ok "L0.5 pip $soma_l05_pip_version"
      else
        soma_fail "L0.5 pip ${soma_l05_pip_version:-unknown}; expected $SOMA_L05_PIP_VERSION"
      fi
      soma_l05_expected=$(sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$soma_root/requirements-l05.lock.txt" | LC_ALL=C sort -f)
      soma_l05_actual=$("$soma_l05_python" -m pip freeze --exclude-editable 2>/dev/null | LC_ALL=C sort -f)
      if [[ -n "$soma_l05_actual" && "$soma_l05_actual" == "$soma_l05_expected" ]]; then
        soma_ok 'L0.5 Python environment matches requirements-l05.lock.txt'
      else
        soma_fail 'L0.5 Python environment differs from requirements-l05.lock.txt'
      fi
    else
      soma_fail "L0.5 is enabled but Python is unavailable: $soma_l05_python"
    fi
    if [[ "${soma_l05_model:t}" == "$SOMA_L05_MODEL_DIRECTORY" \
          && -d "$soma_l05_model" ]] \
        && (cd "$soma_l05_model" && shasum -a 256 -c "$soma_root/config/l05-model.sha256" >/dev/null 2>&1); then
      soma_ok "L0.5 model $soma_l05_model"
    else
      soma_fail 'L0.5 model files differ from the locked Gemma E2B checkpoint'
    fi
  else
    soma_ok 'optional L0.5 MLX-VLM disabled'
  fi

  soma_arcface_root="$HOME/Library/Application Support/SOMA/models/arcface-r50-v1/ArcFaceR50.mlmodelc"
  if [[ -f "$soma_arcface_root/model.mil" \
        && -f "$soma_arcface_root/weights/weight.bin" \
        && -f "$soma_arcface_root/coremldata.bin" \
        && -f "$soma_arcface_root/analytics/coremldata.bin" \
        && -f "$soma_arcface_root/metadata.json" ]]; then
    soma_arcface_model_hash=$(shasum -a 256 "$soma_arcface_root/model.mil" | awk '{print $1}')
    soma_arcface_weights_hash=$(shasum -a 256 "$soma_arcface_root/weights/weight.bin" | awk '{print $1}')
    if [[ "$soma_arcface_model_hash" == "$SOMA_ARCFACE_MODEL_SHA256" \
          && "$soma_arcface_weights_hash" == "$SOMA_ARCFACE_WEIGHTS_SHA256" ]] \
        && soma_arcface_metadata_contract_is_valid "$soma_arcface_root/metadata.json" current; then
      soma_ok 'optional ArcFace identity model'
    elif [[ "$soma_arcface_model_hash" == "$SOMA_ARCFACE_LEGACY_MODEL_SHA256" \
            && "$soma_arcface_weights_hash" == "$SOMA_ARCFACE_LEGACY_WEIGHTS_SHA256" ]] \
        && soma_arcface_metadata_contract_is_valid "$soma_arcface_root/metadata.json" legacy; then
      soma_warn 'optional ArcFace identity model uses the previous verified conversion; rerun its installer to converge'
    else
      soma_fail 'installed ArcFace identity model differs from MODELS.md'
    fi
    if xcrun swift -e \
        'import CoreML; import Foundation; _ = try MLModel(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))' \
        "$soma_arcface_root" >/dev/null 2>&1; then
      soma_ok 'optional ArcFace Core ML load validation'
    else
      soma_fail 'installed ArcFace identity model cannot be loaded by Core ML'
    fi
  else
    soma_warn 'optional ArcFace identity model is not installed'
  fi

  if system_profiler SPCameraDataType SPAudioDataType SPUSBDataType 2>/dev/null | grep -Fqi 'OBSBOT'; then
    soma_ok 'connected OBSBOT USB device'
  else
    soma_warn 'no connected OBSBOT USB device; hardware acceptance cannot run'
  fi
fi

if (( soma_failures > 0 )); then
  print -u2 -r -- "SOMA preflight failed with $soma_failures blocking issue(s) and $soma_warnings warning(s)."
  exit 1
fi

print -r -- "SOMA ${soma_mode#--} prerequisites are ready with $soma_warnings warning(s)."
