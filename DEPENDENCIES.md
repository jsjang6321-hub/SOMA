# Reproducible setup

SOMA separates dependencies into four classes so a clean checkout never
silently relies on files from the development Mac.

| Class | Source of truth | Installation |
| --- | --- | --- |
| Host build tools | `Brewfile`, `Package.swift` | Homebrew Bundle and Xcode command-line tools |
| Bundled Core ML models | Git plus hashes in `config/bundled-models.sha256` | Present after clone; verified by `soma-doctor` |
| OBSBOT control transport | `Sources/SOMANativeTracking` | Built from source; uses macOS UVC/XU over IOKit |
| Runtime services/assets | `.env`, `MODELS.md`, optional Python lock | Ollama, Codex, ArcFace, and optional MLX-VLM setup |

## Supported host

- Apple Silicon Mac
- macOS 13 or newer for the Swift package
- macOS 26 or newer for the full runtime installed by `Brewfile` (current
  Homebrew OpenCV 5 bottle deployment target)
- Swift 6.0 or newer from Xcode command-line tools
- OpenCV 5 and CMake 3.16 or newer

`config/soma-dependencies.env` is the machine-readable compatibility contract.
It pins model artifacts by SHA-256 and records the known-good runtime versions.
`scripts/soma-doctor.zsh` enforces it.

Homebrew formulae and casks are compatibility-gated rather than byte-pinned:
a new Mac receives the current CMake, OpenCV 5, and Ollama releases, while an
existing Mac is not upgraded by bootstrap. The doctor then enforces minimums,
OpenCV major and deployment-target compatibility, followed by the project
build/tests. Bundled models, Python environments, and local model checkpoints
are the byte-pinned portion of this contract.

The source package's macOS 13 deployment target is not a claim that every
current Homebrew runtime dependency is available there. The bootstrap enforces
the stricter full-runtime minimum, and the doctor reads the installed OpenCV
dylib's deployment target so it cannot approve an unloadable local build.

## Clean-Mac installation

OBSBOT Center is not required; SOMA uses the repository's open UVC/XU driver.
If OBSBOT Center is installed, quit it before starting SOMA so it cannot retain
the camera's USB control endpoint.

Install full Xcode 26.6 build 17F113, Homebrew, and a signed-in current Codex
app first. Connect a Tiny 2 Lite or Tiny 3 Lite, then run:

```sh
xcode-select --install
git clone https://github.com/codeshark94/SOMA.git
cd SOMA

scripts/setup-soma.zsh --full
```

The full command begins with a compact preflight report. It checks the host,
exact Xcode build, Homebrew, Codex login and Realtime capability, connected
camera model, and OBSBOT Center contention. Every blocking row includes its
single next action; provisioning starts only after the report is ready.

The setup command is safe to rerun. It invokes the locked bootstrap, starts
Ollama and provisions
the L1 model when absent, runs the tests and runtime doctor, installs the signed
app, and verifies that the process remains active. `--full` also provisions
the pinned L0.5 model and ArcFace identity model and enables motion. Use
`--plan` for a read-only preview or select only `--with-l05`,
`--with-face-identity`, and `--enable-motion` as needed. Double-click
`Install SOMA.command` to run the same full profile from Finder.
`--enable-motion` enables the checked-in
device-profile calibration registry; the runtime then selects the matching
Tiny 2 Lite or Tiny 3 Lite profile after open USB detection and establishes
the session-specific attitude origin from live gimbal feedback.

The native OBSBOT helper and its profile packet tests are built entirely from
this repository and link only Apple system frameworks plus the C++ runtime. No
vendor archive, account-only download, Gatekeeper exception, or bundled
proprietary dylib is required. Installation constructs a fresh signed app
bundle and embeds the Core ML resources under `Contents/Resources`, so the
installed runtime does not depend on the checkout's `.build` directory.

Start Ollama and provision the default L1 model:

```sh
open -a Ollama
ollama pull gemma4:31b-cloud
```

The cloud model may require the operator to sign in to Ollama. Set
`OLLAMA_API_KEY` only if hosted web search/fetch is desired; it is not stored in
Git. L2 Live Voice additionally requires the Codex app, a signed-in account,
and the `realtime_conversation` App Server capability. Set
`SOMA_ENABLE_L2_LIVE_VOICE=0` when that component is intentionally absent.
If the Hermes CLI is installed, SOMA auto-detects it at
`$HOME/.local/bin/hermes` or on `PATH`; `SOMA_HERMES_BINARY` overrides
discovery. The agent runtime can then execute explicit administrator-delegated
jobs through its authenticated loopback protocol. Only administrator Live Voice
threads receive the task capability, and Hermes remains optional for every
other runtime feature.

Before the first local app installation,
`scripts/ensure-soma-signing-identity.zsh` creates a ten-year machine-local
self-signed code-signing root in the current user's default keychain when the
named identity is absent. Its temporary export password and files are destroyed
after import, and the private key never leaves that Mac. The doctor and
installer require the resulting usable persistent identity and never fall back
to ad-hoc signing, so macOS TCC permissions remain attached to a stable
installed application identity across rebuilds. Keychain may request explicit
user approval while importing or trusting the identity.

For debugging an individual setup stage, the lower-level commands remain
available:

```sh
scripts/soma-doctor.zsh --build
swift build
swift test
scripts/soma-doctor.zsh --runtime
```

Only after all blocking checks pass, install the local app and LaunchAgents:

```sh
scripts/install-soma-subconscious-app.zsh
scripts/soma.zsh status
```

The installer rebuilds from source, signs the local bundle, writes two
LaunchAgents, and starts or restarts SOMA. Camera, Microphone, Speech
Recognition, Accessibility, and Screen Recording permissions remain explicit
per-Mac user actions and cannot be made portable through the repository.
Screen Recording is needed only for an administrator-requested current-display
capture; Accessibility is needed only for administrator-requested pointer or
keyboard input.

## Optional L0.5 MLX-VLM

The optional helper is off by default. To reproduce its known-good Python
environment, including the pinned pip and full transitive package set:

```sh
scripts/bootstrap-soma.zsh --with-l05
```

This locked MLX 0.32 environment requires macOS 26 or newer; the published
Apple Silicon wheels themselves carry that deployment target. Only the Swift
package without the current Homebrew runtime retains the macOS 13 minimum.

The full setup and `--with-l05` route download
`mlx-community/gemma-4-e2b-it-4bit` revision
`238767527555cb75a05732a84dff5d6ba0dd6809` into an isolated staging directory,
verify every runtime file, atomically install it at
`~/Library/Application Support/SOMA/models/gemma-4-e2b-it-4bit`, and enable
`SOMA_ENABLE_L05_VLM=1`. If the repository requires authentication, accept
its terms and run `hf auth login` before rerunning setup. The locked
`model.safetensors` SHA-256 is
`038e39a37a7667373d2c3991375446b10c96ae1d717a68674870343db376b76e`;
`config/l05-model.sha256` verifies the complete runtime checkpoint manifest,
including tokenizer, processor, generation, and chat-template files.

## Optional face identity

ArcFace weights are not redistributable as a general product dependency. For
the research-only identity path, use `--with-face-identity`, `--full`, or run:

```sh
brew install python@3.12
scripts/install-soma-face-identity-model.zsh
```

That installer requires Python 3.12 and full Xcode 26.6 build 17F113 selected
with `xcode-select`, installs the full
conversion dependency lock from `requirements-arcface.lock.txt`, verifies the
source download and all compiled model files, and installs the result with
owner-only permissions. See `MODELS.md` for licensing and provenance.

## Overrides

Use these only for deliberate nonstandard locations:

- `SOMA_OPENCV_PREFIX`
- `SOMA_CMAKE`
- `SOMA_CODEX_BINARY`
- `SOMA_CODESIGN_IDENTITY`
- `SOMA_ARCFACE_PYTHON`
- `SOMA_ENV_FILE` for doctor-only configuration validation

The repository has no remote SwiftPM dependencies, so there is no
`Package.resolved`. Python dependencies for the optional MLX helper and
ArcFace conversion are pinned in `requirements-l05.lock.txt` and
`requirements-arcface.lock.txt`.
