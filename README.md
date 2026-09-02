<p align="center">
  <img src="assets/branding/soma-mark.png" width="236" alt="SOMA mark">
</p>

<h1 align="center">SOMA</h1>

<p align="center">
  <strong>An embodied-AI research interface for attention, memory, and human-like interaction.</strong>
</p>

<p align="center">
  <a href="https://www.obsbot.com/obsbot-tiny-2-lite-4k-webcam">OBSBOT Tiny 2 Lite</a> ·
  <a href="https://www.obsbot.com/obsbot-tiny-3-lite">OBSBOT Tiny 3 Lite</a> ·
  macOS 13+ · Swift · Core ML · Model Context Protocol · Codex Live Voice
</p>

<p align="center">
  <img alt="Platform macOS 13+" src="https://img.shields.io/badge/platform-macOS%2013%2B-111827?style=flat-square&amp;logo=apple&amp;logoColor=white">
  <img alt="Runtime local first" src="https://img.shields.io/badge/runtime-local--first-0f766e?style=flat-square">
  <img alt="Embodiment semantic leases" src="https://img.shields.io/badge/embodiment-semantic--leases-7c2d12?style=flat-square">
</p>

<p align="center">
  <a href="#why-soma">Why SOMA</a> ·
  <a href="#the-cognitive-architecture">Architecture</a> ·
  <a href="#the-embodiment-interface">Embodiment MCP</a> ·
  <a href="#run-a-safe-probe-first">Getting started</a> ·
  <a href="COGNITIVE_ARCHITECTURE.md">Technical architecture</a>
</p>

> [!NOTE]
> SOMA is not a “camera assistant” or a general-purpose autonomous agent. It is a
> research system for building an interface through which artificial
> intelligence can perceive, attend to, remember, and interact with people in
> a way that feels situated rather than merely reactive.

## Why SOMA

Most assistants begin after a user has typed or spoken a command. Human
interaction begins much earlier: someone enters a room, glances over, pauses,
speaks, changes posture, or returns after an earlier conversation. Those events
occur on different time scales and they call for different kinds of cognition.

SOMA investigates how to connect them without pretending that a single model
should do everything:

- **Perception must react in milliseconds.** A moving face, an interrupted
  voice, or a lost target cannot wait for a long reasoning cycle.
- **Interpretation needs continuity.** A familiar person, a room, a prior
  conversation, and an unfinished question only make sense across time.
- **Interaction needs embodiment.** Where the camera looks, how it pauses, and
  an indicator light are part of the social signal—not decorative output.
- **Deliberation must remain accountable.** Higher-level models may decide what
  deserves attention, but a local physical boundary still owns the final motor
  command, joint envelope, watchdog, and stale-evidence veto.

The resulting system is an **embodied interaction interface**: a platform for
studying how an AI can share attention with a person, develop contextual memory,
and choose when to speak, stay quiet, look again, or express readiness.

## The body: OBSBOT Tiny

SOMA recognizes connected OBSBOT hardware from exact USB VID/PID identity,
not from a UVC display name. It was developed around the
[OBSBOT Tiny 2 Lite](https://www.obsbot.com/obsbot-tiny-2-lite-4k-webcam), and
also has a guarded profile for the
[OBSBOT Tiny 3 Lite](https://www.obsbot.com/obsbot-tiny-3-lite). Both are
treated as sensorimotor bodies rather than passive webcams:

| Hardware affordance | Role in SOMA |
| --- | --- |
| UVC video | Low-latency visual evidence, face/person/object observations, scene change, and spherical mapping |
| USB audio | On-device voice-activity evidence and live conversation audio |
| 2-axis gimbal | Fixation, re-acquisition, active exploration, and compact nonverbal expressions |
| Firmware LED feedback | A nearby person can see the state the connected model can physically express |

The camera is controlled by a separately enabled open macOS UVC/XU bridge. The
raw transport does not become a direct model tool or a free-form velocity
interface.
The [device adapter contract](docs/OBSBOT_DEVICE_ADAPTER.md) carries the
connected product's verified control surface from that bridge to the launcher
and runtime. An unfamiliar OBSBOT remains a perception-and-conversation body
until it has both an adapter and a matching calibration; replacing hardware
does not silently borrow another camera's motor or LED assumptions.

| Device profile | Available without new calibration | Intentionally withheld |
| --- | --- | --- |
| `tiny_2_lite` | Video, USB audio, calibrated gimbal control, firmware indicator palette | — |
| `tiny_3_lite` | Video, USB audio, selectable microphone modes, profile-calibrated L0 gimbal control, native human tracking, firmware status LED, and Live Voice | Tiny 2 motor calibration, unverified firmware sound following, host-readable sound bearing, and camera-tuning controls not yet migrated to the open bridge |

This is a physical boundary, not a feature downgrade: calibration signs,
motion envelopes, sound-localization semantics, and LED state IDs are
device-specific observations. A Tiny 3 Lite therefore uses its own measured
attitude frame and native tracker configuration; it never inherits Tiny 2 Lite
motion or indicator assumptions. Each profile requires independent calibration
and physical LED validation before a capability is exposed as available.

## The cognitive architecture

SOMA organizes cognition by **latency, context horizon, and authority**. The
layers are connected, but they are not interchangeable.

| Layer | Time scale | What it does | What it may control |
| --- | --- | --- | --- |
| **L0 · subconscious** | Video/audio cadence | Captures sensor evidence, follows a verified face, keeps target continuity, estimates voice activity, maintains spatial coverage, and executes the final motor policy | The only path to physical motion, stabilization, limits, watchdogs, and immediate stops |
| **L0.5 · local semantic helper** | Sparse asynchronous inference and temporal evidence integration | Produces evidence deltas for L1 without blocking L0; it does not call the language model directly | No independent motor, speech, identity, memory, or wake authority |
| **L1a · persistent thought stream** | Event-driven plus an adaptive stochastic clock | Maintains hypotheses, curiosity, goal-linked thought episodes, self-correction, and a probabilistically selected foreground thought in one persistent mental workspace | May form an abstract intention and request bounded visual evidence; cannot speak or move hardware |
| **L1b · executive judgment** | Only when an L1a intention creates action pressure | Chooses one currently available social or attention action against a frozen workspace revision | Semantic attention, labels, tracking goals, exploration policy, view requests, and expressions through existing leased MCP/L0 goals |
| **L2 · conversation and executive reasoning** | Human turn time | Conducts account-backed live conversation, high-order reasoning, goal-directed tool use, and explicit delegation of longer external work | The same semantic embodiment interface as L1 plus an administrator-only asynchronous Hermes task queue; never raw device velocity |

L2 may inspect perception or memory and may request reversible attention actions
without waiting for a literal tool command when that action advances the current
conversational goal. This initiative is enforced by the MCP server, not only by
the model prompt: every call carries a stable goal episode and an authorization
basis. Participant-coupled operations also require a server-issued grant for the
current spoken turn. Unknown tools fail closed, durable memory requires a grounded statement,
identity enrollment requires consent, and device configuration requires an
explicit request. Tool results return to the mental workspace as bounded
evidence, with semantic request fingerprints preventing paraphrased duplicate
calls without retaining raw result payloads.

Issuing an action is not treated as satisfying its goal. Dispatch is recorded
first; the linked thought and intention remain active until later evidence meets
their observable completion condition, makes the goal impossible, or causes L1a
to revise it. This keeps tool use inside the same perception-thought-action-
verification loop as embodied behavior.

Visual inspection closes that loop without requiring a conversation. When L1a
has a concrete uncertainty about the currently grounded attention target, L1b
may authorize one active inspection. L0 centres the verified scene entity,
waits for stable pose, captures one short-lived view, and returns the image as
new workspace evidence. L1a must then evaluate that image and resolve, revise,
or abandon the goal. Equivalent unresolved target intentions collapse into one
semantic episode even if the model emits a fresh UUID, so the same view cannot
become a polling loop. The valid JPEG is copied only into the pending inference
request before its file lease expires; that copy survives queue delay but is
excluded from every encoded packet and mental checkpoint. Stopping the stream
cancels the capture wait and removes its temporary motor target.

L0.5 is intentionally a supporting process inside the L1 path, not a fourth
mind. Its job is to make slow contextual reasoning more perceptive without
weakening the real-time loop. Every cue is reduced into the same workspace as
face, gaze, voice, memory, conversation, and elapsed-time evidence. Only a
meaningful workspace transition may wake L1a; repeated equivalent cues merely
support an existing hypothesis. Neither path controls movement or conversation
directly.

This loop lets a high-level model influence *why* SOMA looks somewhere, which
object matters, how long attention should persist, or whether a gesture would
be appropriate—while L0 remains responsible for *how* the hardware gets there
safely and continuously.

## From sensing to social interaction

### 1. Notice

L0 treats visual and auditory evidence as separate but converging signals.
Core ML face/person/object observations, landmark confirmation, target
continuity, on-device VAD, and gimbal pose are combined into a current belief
about what is present and what deserves immediate attention.

### 2. Maintain shared attention

The gimbal is not only a tracker. It can hold a face, recover a briefly lost
person, inspect uncertain space, and explore unobserved but reachable regions.
A spherical scene field and rolling panoramic map allow past observations to
remain spatially meaningful as the camera moves.

### 3. Interpret the situation

L1 receives bounded, policy-filtered context rather than a permanent raw video
stream. It can combine a current scene, a person's relationship history,
explicit preferences, open information needs, place memory, and previous
thought state. It may decide to remain silent, make a nonverbal invitation, or
open a conversation with a concrete purpose.

### 4. Converse without losing the body

An authorized direct human contact can open an L2 Live Voice session, while L1
can also initiate a conversation when it has a concrete purpose. L2 receives
the private conversational objective and relevant memory context, then responds
to the person's actual words. During a conversation it can proactively use the
narrowest permitted SOMA MCP tool when doing so materially reduces uncertainty
or advances the active goal. Perception and memory reads are autonomous;
durable identity or person-memory changes still require a grounded statement or
consent, and every motor request remains leased through L0.

Camera imagery is not streamed into conversation as a running caption feed.
When visual evidence is genuinely useful, L2 can decide to call
`capture_view` through MCP and inspect that bounded, current resource itself.
This keeps a conversation from turning into unsolicited image description.
Each goal-directed call carries a stable cognitive goal identifier. Its raw
result stays in the current interaction, while only a bounded outcome summary
and result fingerprint return to the mental workspace. That closes the
perception–thought–action loop without duplicating successful equivalent calls
or persisting raw tool payloads.

The host display is a separate sensor from the OBSBOT camera. After an explicit
administrator request, L2 can acquire one short-lived main-display image and
perform a bounded foreground UI action, one pointer, scroll, text, or
supported-key action per call. These are
two high-level MCP tools rather than separate mouse and keyboard tool families.
They require the current administrator capability and a fresh participant turn;
screen pixels and typed text are not written to the cognitive trace. Multi-step
computer work, shell access, files, repositories, services, and research remain
Hermes tasks so the live conversation does not become an unbounded desktop
automation loop. This channel remains available when gimbal motion is disabled;
physical camera authority is negotiated separately.

Hermes is the worker for external jobs that can proceed independently of the
spoken exchange. When delegation is enabled, L2 separates direct conversation
and SOMA embodiment from explicit administrator work involving the host Mac,
files, repositories, coding, services, or research; the administrator does not
need to name Hermes. L2 submits one bounded objective, receives a durable task
ID immediately, acknowledges the accepted handoff aloud, and continues the
spoken conversation without waiting. The acknowledgement never reads the
internal task ID. If the model finishes the successful tool turn silently, the
Live Voice controller emits the same one-time acknowledgement in the person's
preferred language; an acknowledgement already spoken by the model is not
duplicated. The owner-only SOMA runtime starts a Hermes Agent session,
stores the task state and result in an encrypted bounded checkpoint, and
retrieves the real completion event. If the same L2 conversation is still open,
the result is returned as trusted controller context and L2 reports it in the
participant's language. If that conversation has ended, the result stays
private until the recognized administrator is present; SOMA asks once whether
to report it, discloses it only after acceptance, and records either decision so
the offer cannot loop. Continuations resume the same Hermes session; cancel and
new work require an explicit administrator request. Participant sessions cannot
submit, inspect, resolve report offers, or cancel external tasks.

SOMA uses Hermes's authenticated loopback worker WebSocket, which preserves
tool events and stored-session identity and makes the worker session visible in
Hermes Desktop. The separate **Messaging → API server** toggle exposes an
OpenAI-compatible endpoint for generic frontends; it is not required for the
SOMA worker connection. Delegation is explicitly bound to Hermes's primary
(`default`) computer-supervisor profile. Before accepting completion, SOMA also
anchors the stored worker session to its selected workspace so it remains under
the correct project instead of falling into Hermes Desktop's synthetic Home
bucket.

### Discord and `@Labmanager`

The Control Center can connect an existing Discord bot to one explicitly
allowlisted channel or thread. After L0 has attributed a finalized spoken turn
to the enrolled administrator, SOMA posts that transcript to the configured
channel and mentions only the configured Labmanager bot user or managed role.
A reply is accepted only when its channel ID and bot author ID both match the saved
allowlist and it echoes the request's one-time `voice-corr` marker. The existing
Labmanager deployment uses a direct bot-user mention; a managed-role mention is
also selectable for other deployments. When the originating Live Voice session
is still active, SOMA lets its primary local response and playback finish first.
The reply is then bound to the originating user turn together with the first
local answer and returned as a controller envelope. L2 stays silent when the
reply is merely redundant; otherwise it gives one concise follow-up that adds
new information, explicitly corrects the earlier answer, or reports the actual
accepted, completed, or failed mission state. Discord text is never treated as
participant authorization and cannot authorize tools or external work.

The Discord bot token is sealed with ChaChaPoly in SOMA's owner-only local
credential store rather than `settings.json`, the repository, process arguments,
environment variables, or runtime traces. This follows the same unattended-worker
boundary as SOMA's other encrypted local stores and avoids GUI authorization
prompts during LaunchAgent startup. Enable Discord's Message Content Intent for
the SOMA bot and grant only View Channel, Send Messages, and Read Message
History in the selected channel. HTTP rate-limit responses are retried from
Discord's returned delay instead of using a hard-coded request quota. Configure
the bridge under **Control Center → Experience → Discord · @Labmanager**.

## Memory as continuity, not a transcript dump

SOMA keeps several different forms of memory because an interaction has more
than one useful duration:

| Horizon | Examples | Role |
| --- | --- | --- |
| **Short-term** | Active tracks, current conversation turns, transient hypotheses | Supports the present interaction and bounded recovery |
| **Medium-term** | Recent episodes, open questions, current tasks, daily public-world brief | Gives L1 an evolving situation rather than a fresh start every cycle |
| **Long-term** | Explicitly confirmed preferences, rapport, familiar-place references, consolidated facts | Supports continuity across encounters without treating every observation as permanent truth |

Raw conversation turns remain in the encrypted local short-term journal before
L1 consolidates an allowed, typed memory. Identity and person-context changes
require explicit confirmation. A model may propose a memory update; it does
not get to invent one from tone or camera appearance.

## The embodiment interface

L1 and L2 use one local [Model Context Protocol](https://modelcontextprotocol.io/)
surface, `soma-embodiment`. The interface lets cognition customize nearly the
whole attention policy while keeping the physical executor local.

| Read and understand | Guide embodied behavior |
| --- | --- |
| Current attention and uncertainty | Register or revise a semantic target label |
| Stable scene entities, bearings, freshness, and action eligibility | Set probabilistic attention priors and tracking commitment |
| Spherical map, coverage, place familiarity, and available bearings | Track a grounded target or orient to a bearing |
| A fresh `capture_view` image or selected panorama data | Shape exploration regions, direction distributions, dwell, and tempo |
| Hardware capability report | Set a verified camera observation control or native human-track response policy |

The public model supplies semantic intent, not its own authority. The trusted
local MCP gateway derives the L2 owner, evidence references, fixed priority,
and bounded lease from the active cognitive goal before forwarding a request.
This keeps repeated authorization fields out of the model-facing tool schemas
and prevents the model from self-assigning motor priority. L0 then rejects stale
or ambiguous targets, expires finished goals, and resolves competing requests
before anything reaches the USB control plane.

## Presence is a communication channel

SOMA treats motion and light as part of interaction design:

- **Fixation** says “I am attending here.”
- **A bounded thinking glance** can communicate attentional intent without
  taking over a conversation.
- **Exploration** is driven by coverage, novelty, place uncertainty, and
  remembered bearings—not a fixed left-right sweep.
- **LED state** is semantic: it can make human presence, interaction readiness,
  active conversation, and cognitive work legible from across the room.

The Tiny 2 Lite exposes a firmware-defined RGB palette and pattern states—not
arbitrary 24-bit color. Tiny 3 Lite uses its firmware status machine: persistent
`SYSTEM_READY(3)` plus `NORMAL_WORKMODE(54)` is green exploration, work state
`57` is blue human presence and contact cadence, and state `16` provides the
yellow active-conversation presentation. The bridge restores `3 + 54` whenever
a temporary state ends. Its experimental direct-RGB packet route was invalid
and has been removed. During an active voice session, yellow remains the session
colour; verified eye contact changes only its cadence from steady to blink.

## Privacy and physical boundaries

SOMA is designed around the fact that a socially responsive camera is sensitive
by default.

- Scalar runtime traces do not contain raw camera frames, PCM, biometric
  templates, or direct device-control payloads.
- Face templates and raw conversation turns are encrypted local records; they
  are not placed in L1 prompts or normal diagnostic traces.
- Visual capture for a reasoning turn is bounded and short-lived rather than a
  rolling remote camera feed.
- Identity enrollment, persistent personal facts, and preference changes are
  explicit actions with confirmation.
- L1 and L2 can express high-level embodied intent, but only L0 owns final
  motion safety and the physical stop path.
- Discord forwarding is off by default and is restricted to finalized
  administrator speech, one channel, and one response bot. Controller envelopes
  are excluded from re-forwarding so two bots cannot create a response loop.

See [COGNITIVE_ARCHITECTURE.md](COGNITIVE_ARCHITECTURE.md) for the detailed
authority, memory, and privacy contracts.

## Requirements

SOMA's Swift package has no remote SwiftPM dependencies. A full runtime uses:

- Apple Silicon Mac running macOS 13 or newer for the Swift package; macOS 26
  or newer for the full runtime installed by the current Brewfile
- Xcode command-line tools with a Swift 6 toolchain
- Homebrew OpenCV 5 for the Swift/C++ vision bridge
- CMake for the native open UVC/XU gimbal, tracking, audio, and LED bridge
- Ollama with the configured L1 model
- A compatible signed-in Codex installation when L2 Live Voice is enabled
- Optional Hermes CLI for administrator-only asynchronous agent work

On a clean Apple Silicon Mac with Xcode and Homebrew, clone the repository and
run the idempotent full setup command:

```sh
scripts/setup-soma.zsh --full
```

The installer first shows a guided readiness report for Xcode, Homebrew,
Codex Live Voice, the connected camera, and possible OBSBOT Center contention.
OBSBOT Center is not a dependency and should be closed if present.
Codex discovery does not depend on the application display name: SOMA checks an
explicit `SOMA_CODEX_BINARY`, the executable `PATH`, common CLI locations, and
installed application bundles that embed `Contents/Resources/codex`. This covers
both Codex- and ChatGPT-named desktop installations.

`--full` provisions the optional L0.5 semantic helper and ArcFace identity
model, enables the supported gimbal profiles, creates a machine-local persistent
code-signing identity when needed, verifies the complete runtime, installs the
apps, and starts SOMA. The same flow is available by double-clicking
[`Install SOMA.command`](Install%20SOMA.command).
Use `--with-l05`, `--with-face-identity`, and `--enable-motion` to select
individual capabilities instead.
`--enable-motion` activates the bundled Tiny 2 Lite and Tiny 3 Lite gimbal
profiles; without it, an existing motion setting is preserved and a fresh
installation remains perception-only.
The command reuses the lower-level bootstrap, doctor, test, signing, and
LaunchAgent installation boundaries rather than duplicating them.

At runtime the launcher probes the exact USB product before granting physical
authority. Tiny 2 Lite and Tiny 3 Lite share one open macOS IOKit UVC/XU
control process, while their packet layouts, motion limits, tracking modes,
indicator pulse transports, and audio capabilities remain isolated in device
profiles. The installed bundle neither contains nor links a proprietary OBSBOT
library.

`soma-doctor` verifies tool versions, bundled-model hashes, the native helper
build, Ollama/model availability, conditional Codex support, and optional
MLX/ArcFace assets. The installed Control Center exposes the same runtime audit
under **System → External dependencies**, with failures and warnings surfaced
before the complete check list. See
[`DEPENDENCIES.md`](DEPENDENCIES.md) for the full clean-Mac procedure and
supported overrides.

## Run a safe probe first

SOMA is a research prototype with real hardware. Start with a non-actuating
probe before enabling any camera motion.

```sh
swift build
swift test

# Inspect connected capture devices and formats; this does not move the camera.
swift run soma-probe --list-formats

# Replace these values with the OBSBOT IDs reported above.
swift run soma-probe --duration 60 \
  --video-id '<OBSBOT video unique ID>' \
  --audio-id '<OBSBOT microphone unique ID>'
```

The probe writes health-only scalar JSONL. It does not record media or issue a
gimbal command.

For the native macOS control surface:

```sh
swift run soma-menu-bar
```

The menu bar application is where a local operator configures voice, indicator
semantics, attention policy, and explicit identity enrollment. A new Live Voice
session requires current eye contact, voice activity, and affirmative
audiovisual evidence that the tracked person is speaking. Once open, conversation remains gaze-independent
by default; an optional setting can require current eye contact for every spoken
turn. Quiet admitted speech is levelled with a bounded VAD-driven gain stage and
the initiating utterance is replayed after transport startup so session latency
does not discard the first words. Review the scripts and hardware flags before
enabling physical camera control.

<details>
<summary><strong>Local companion installation</strong></summary>

<br>

```sh
scripts/setup-soma.zsh --full
```

The full setup command installs locked dependencies, downloads the pinned L0.5
checkpoint, builds the pinned ArcFace model, provisions the L1 model, runs the
full verification suite, then
rebuilds the Swift and native helpers, signs a local app bundle,
writes `com.soma.menu-bar` and `com.soma.reactive-l0` LaunchAgents, and starts or
restarts them. macOS may then request Camera, Microphone, Speech Recognition,
Accessibility, and Screen Recording permissions. Screen Recording is used only
for an explicitly requested host-screen observation; Accessibility is used for
an explicitly requested pointer or keyboard action. The installed runtime is intended for a local
macOS user with the connected camera and—when Live Voice is enabled—a signed-in
Codex installation. Motion stays disabled until `.env` explicitly enables it
and the connected device has a valid calibration. Use `scripts/soma.zsh stop`,
`start`, `restart`, or `status` for subsequent service control.

Administrator enrollment captures the display name and face together, persists
their shared entity ID, and restarts L0 so the encrypted profile is loaded
immediately. If the lens is mounted above or below the participant's eyes, set
**Camera height** under **L0 — Perception & attention** before judging eye-contact
accuracy; the correction shifts the expected vertical eye ray while preserving
the downward-gaze rejection boundary.
</details>

## Repository map

| Path | Responsibility |
| --- | --- |
| [`Sources/SOMACore`](Sources/SOMACore) | Cognition contracts, memory, identity, semantic embodiment leases, attention, and spatial models |
| [`Sources/SOMASubconscious`](Sources/SOMASubconscious) | L0 capture/perception runtime, panorama worker, L1 situation stream, and local safety integration |
| [`Sources/SOMANativeTracking`](Sources/SOMANativeTracking) | Product-gated open macOS UVC/XU control, native tracking, audio, and indicator bridge |
| [`Sources/SOMAEmbodimentMCP`](Sources/SOMAEmbodimentMCP) | MCP gateway for embodiment, person context, bounded host-screen observation, and immediate host input |
| [`Sources/SOMALiveVoice`](Sources/SOMALiveVoice) | Account-backed Codex app-server Live Voice helper |
| [`Sources/SOMAMenuBar`](Sources/SOMAMenuBar) | Native local settings, status, and diagnostics interface |
| [`Tests/SOMACoreTests`](Tests/SOMACoreTests) | Contract and regression tests for cognition, memory, embodiment, and spatial behavior |

## Research status

SOMA is actively developed hardware-facing research software, not a finished
consumer assistant. The project already contains the real-time L0 loop,
semantic embodiment contracts, identity and memory infrastructure, rolling
spatial mapping, LED presence semantics, and an account-backed Live Voice
route. The important remaining work is empirical: evaluate perception and
interaction in real rooms, measure long-horizon memory quality, characterize
physical LED behavior, and test whether the resulting behavior is actually
experienced as attentive and appropriate by people.

Detailed implementation status and open acceptance work live in
[PLAN.md](PLAN.md), [MODELS.md](MODELS.md), and
[COGNITIVE_ARCHITECTURE.md](COGNITIVE_ARCHITECTURE.md).

## Project notes

- SOMA is an independent research project and is not affiliated with OBSBOT.
- OBSBOT and Tiny 2 Lite are trademarks of their respective owners.
- SOMA source code is licensed under [AGPL-3.0](LICENSE).
- Third-party model terms are documented in [MODELS.md](MODELS.md) and
  [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). The bundled YOLO11n package
  is AGPL-3.0; its terms apply to that asset.

## Artwork

[`assets/branding/soma-original.png`](assets/branding/soma-original.png) is
the canonical identity board. Its derived transparent mark replaces the former
mascot throughout the README, settings interface, status menu, and macOS menu
bar; the matching black-tile variant is packaged as the application icon.
