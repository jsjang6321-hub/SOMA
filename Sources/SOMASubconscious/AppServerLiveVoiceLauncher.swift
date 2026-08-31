import Foundation
import SOMACore

enum AppServerLiveVoiceEvent: Sendable {
    case launchRequested(authorization: String, personEntityID: UUID?)
    case active(threadID: String?, personEntityID: UUID?)
    case inputTransportStarted
    case inputBootstrapReplayed(durationMilliseconds: Double, peakDBFS: Double, maximumGainDB: Double)
    case outputPlaybackReady
    case naturalTurnTakingConfirmed
    case responseInterrupted
    case interruptedAudioCleared
    case proactiveOpeningTriggered
    case proactiveOpeningExtraOutputSuppressed
    case hermesReportOfferStarted(taskID: UUID)
    case hearingUser
    case visualContextAttached
    case visualContextRejected(reason: String)
    case embodimentMCPReady
    case embodimentMCPUnavailable(reason: String)
    case hermesTaskResultAccepted(taskID: UUID)
    case hermesTaskResultRejected(taskID: UUID?, reason: String)
    case discordReplyAccepted
    case discordReplyRejected(reason: String)
    case personContextReady
    case personContextUnavailable(reason: String)
    case embodimentMCPCall(tool: String, status: String, error: String?)
    case inputAccepted(characters: Int)
    case transcriptFinalized(threadID: String?, role: ConversationParticipantRole, text: String)
    case preparingResponse
    case responseStarted(latencyMilliseconds: Double)
    case assistantSpeechStarted
    case assistantSpeechEnded
    case assistantOutputReferenceReady(sampleRate: Int, samples: Int)
    case microphoneCaptureSuppressed
    case playbackEchoAssessed(relationship: LiveVoiceEchoRelationship, correlation: Double)
    case participantBargeInAdmitted(bufferedMilliseconds: Double)
    case acousticEchoDiscarded
    case responding
    case responseCompleted
    case ended(threadID: String?, personEntityID: UUID?, reason: String)
    case failed(threadID: String?, personEntityID: UUID?, reason: String)
}

private struct LiveVoiceHelperEvent: Decodable, Sendable {
    let event: String
    let threadID: String?
    let reason: String?
    let characters: Int?
    let role: String?
    let text: String?
    let tool: String?
    let status: String?
    let error: String?
    let taskID: String?
    let data: String?
    let sampleRate: Int?
    let samplesPerChannel: Int?
    let numChannels: Int?
    let resetReference: Bool?

    enum CodingKeys: String, CodingKey {
        case event
        case threadID = "thread_id"
        case reason
        case characters
        case role
        case text
        case tool
        case status
        case error
        case taskID = "task_id"
        case data
        case sampleRate = "sample_rate"
        case samplesPerChannel = "samples_per_channel"
        case numChannels = "num_channels"
        case resetReference = "reset_reference"
    }
}

private struct BufferedLiveAudio: Sendable {
    let data: String
    let sampleRate: Int
    let samplesPerChannel: Int
    let durationNS: UInt64
    let inputPeakDBFS: Double
    let appliedGainDB: Double
}

private struct CapturedLiveAudio: Sendable {
    let samples: [Float]
    let sampleRate: Int
    let captureNS: UInt64
    let durationNS: UInt64
}

private enum LiveVoiceSessionTerminationError: LocalizedError {
    case noActiveSession
    case capabilityMismatch

    var errorDescription: String? {
        switch self {
        case .noActiveSession: "No active Live Voice session is available to end"
        case .capabilityMismatch: "The Live Voice capability does not own the active session"
        }
    }
}

final class AppServerLiveVoiceLauncher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "soma.live-voice.app-server", qos: .userInitiated)
    private let projectDirectory: String
    private let voice: SOMARealtimeVoice
    private let currentCameraImageDataURI: (@Sendable () -> String?)?
    private let embodimentSocketURL: URL?
    private let persistentAppServer: PersistentAppServerBroker?
    private let persistentSessionAuthorizer: (@Sendable (
        String,
        SOMASessionCapabilityScope,
        UInt64
    ) -> Result<Void, SOMASessionCapabilityError>)?
    private let cameraContextAutoInjection: Bool
    private let requireVerifiedSpeakerForEveryTurn: Bool
    private let hermesAgentDelegationEnabled: Bool
    private let onEvent: @Sendable (AppServerLiveVoiceEvent) -> Void
    private var gate = LiveVoiceLaunchGate()
    private var inactivityGate = LiveVoiceSessionInactivityGate()
    private var inactivityTimer: DispatchWorkItem?
    private var initialTranscriptTimer: DispatchWorkItem?
    private var process: Process?
    private var input: FileHandle?
    private var outputBuffer = Data()
    private var speakerEpisodeAudio = LiveVoiceTimestampedEpisodeBuffer<CapturedLiveAudio>(
        detectorHistoryNS: 2_000_000_000,
        maximumEpisodeDurationNS: 12_000_000_000
    )
    private var speakerEpisodeInProgress = false
    private var initiatingTurn: [BufferedLiveAudio] = []
    private var capturingInitiatingTurn = false
    private var inputLeveler = LiveVoiceInputLeveler()
    private var duplexCaptureGate = LiveVoiceDuplexCaptureGate()
    private var echoReferenceMatcher = LiveVoiceEchoReferenceMatcher()
    private var lastEchoRelationship: LiveVoiceEchoRelationship?
    private var outputReferenceReported = false
    private var duplexEpisodeInProgress = false
    private var duplexEpisodeAdmitted = false
    private var inputTransportReported = false
    private var active = false
    private var activeTurnAudioAdmitted = false
    private var stopped = false
    private var generation: UInt64 = 0
    private var activePersonEntityID: UUID?
    private var activeThreadID: String?
    /// This stays only with the corresponding helper process. It prevents an
    /// older local MCP child from ending a newer participant's conversation.
    private var activeSessionCapability: String?
    private var openingVisualContextAttached = false
    private var awaitingAssistantResponse = false
    private var latestUserTranscriptNS: UInt64?
    private var initialTurnValidation: LiveVoiceInitialTurnValidation
    private var proactiveOpeningAwaitingParticipant = false
    private var proactiveOpeningDelivered = false
    private var pendingHermesReportOfferTaskID: UUID?
    private var hermesResultAwaitingConfirmation = Set<UUID>()

    init(
        projectDirectory: String? = nil,
        voice: SOMARealtimeVoice = .maple,
        currentCameraImageDataURI: (@Sendable () -> String?)? = nil,
        embodimentSocketURL: URL? = nil,
        requireVerifiedSpeakerForEveryTurn: Bool = false,
        hermesAgentDelegationEnabled: Bool = true,
        inactivityTimeoutMilliseconds: UInt64 = 60_000,
        initialParticipantTranscriptTimeoutMilliseconds: UInt64 = 3_500,
        persistentAppServer: PersistentAppServerBroker? = nil,
        persistentSessionAuthorizer: (@Sendable (
            String,
            SOMASessionCapabilityScope,
            UInt64
        ) -> Result<Void, SOMASessionCapabilityError>)? = nil,
        onEvent: @escaping @Sendable (AppServerLiveVoiceEvent) -> Void
    ) {
        self.projectDirectory = projectDirectory
            ?? ProcessInfo.processInfo.environment["SOMA_ROOT"]
            ?? FileManager.default.currentDirectoryPath
        self.voice = voice
        self.currentCameraImageDataURI = currentCameraImageDataURI
        self.embodimentSocketURL = embodimentSocketURL
        self.requireVerifiedSpeakerForEveryTurn = requireVerifiedSpeakerForEveryTurn
        self.hermesAgentDelegationEnabled = hermesAgentDelegationEnabled
        inactivityGate = LiveVoiceSessionInactivityGate(
            timeoutMilliseconds: inactivityTimeoutMilliseconds
        )
        initialTurnValidation = LiveVoiceInitialTurnValidation(
            transcriptTimeoutMilliseconds: initialParticipantTranscriptTimeoutMilliseconds
        )
        self.persistentAppServer = persistentAppServer
        self.persistentSessionAuthorizer = persistentSessionAuthorizer
        cameraContextAutoInjection = somaEnvBool("SOMA_L2_AUTO_INJECT_CAMERA", default: true)
        self.onEvent = onEvent
    }

    func canStartHermesReportOffer(at monotonicNS: UInt64) -> Bool {
        queue.sync {
            !stopped
                && !active
                && gate.phase == .inactive
                && monotonicNS >= gate.retryAfterNS
        }
    }

    func startIfNeeded(
        authorization: String,
        context: CodexInteractionContext?,
        personEntityID: UUID? = nil,
        at monotonicNS: UInt64
    ) {
        queue.async { [weak self] in
            guard let self, !stopped else { return }
            if active {
                return
            }
            guard gate.beginLaunch(at: monotonicNS) else { return }
            launch(
                authorization: String(authorization.prefix(64)),
                initialContext: context.map(Self.contextText) ?? "",
                sessionCapability: context?.sessionCapability,
                preferredLanguageTag: context?.preferredLanguageTag,
                languageStartInstruction: context?.languageStartInstruction,
                proactiveOpeningText: nil,
                personEntityID: personEntityID,
                personContextReference: context?.personContextAvailable == true ? context?.personEntityID : nil,
                interactionAuthority: context?.interactionAuthority,
                at: monotonicNS
            )
        }
    }

    /// Starts the same account-backed Live session for an L1-authorized social
    /// opening. The directive is short-lived session context, not a stored
    /// transcript or a substitute for the normal conversation gate.
    func startProactiveOpening(
        context: CodexInteractionContext?,
        opening: L1PurposefulOpening,
        personEntityID: UUID,
        at monotonicNS: UInt64
    ) {
        queue.async { [weak self] in
            guard let self, !stopped else { return }
            guard gate.beginLaunch(at: monotonicNS) else { return }
            let base = context.map(Self.contextText) ?? ""
            let exactOpening = opening.question.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !exactOpening.isEmpty else {
                gate.fail(at: monotonicNS)
                resetSessionEphemera(keepingAudioCapacity: false)
                return
            }
            let directive = "This is a closed-purpose L1-initiated interaction. The supplied objective and completion condition are private conversational orientation, never text to recite or a checklist to expose. L1 has already selected the one natural opening in the participant's preferred language. Deliver that exact opening once, then listen. After each reply, respond to what the participant actually said; let their answer determine the next conversational step. Surface a relevant information need only when it naturally fits the evolving conversation, and stop pursuing the objective once it is answered or declined. Do not dump multiple questions, narrate a plan, replace the opening with a generic greeting or offer of help, or invent another motive. If the purpose cannot be preserved, remain silent."
            launch(
                authorization: "l1_social_opening",
                initialContext: String([base, directive].filter { !$0.isEmpty }.joined(separator: "\n\n").prefix(24_000)),
                sessionCapability: context?.sessionCapability,
                preferredLanguageTag: context?.preferredLanguageTag,
                languageStartInstruction: context?.languageStartInstruction,
                proactiveOpeningText: String(exactOpening.prefix(1_024)),
                personEntityID: personEntityID,
                personContextReference: context?.personContextAvailable == true ? context?.personEntityID : nil,
                interactionAuthority: context?.interactionAuthority,
                at: monotonicNS
            )
        }
    }

    /// A completed external task is a durable controller event, not synthetic
    /// participant speech. Offer it once to the currently recognized
    /// administrator and let L2 resolve the explicit yes/no answer through the
    /// task MCP before any result is disclosed.
    func startHermesReportOffer(
        context: CodexInteractionContext,
        task: HermesAgentTask,
        personEntityID: UUID,
        at monotonicNS: UInt64
    ) {
        queue.async { [weak self] in
            guard let self, !stopped,
                  task.status == .completed,
                  task.reportedAt == nil,
                  task.reportOfferAt == nil,
                  gate.beginLaunch(at: monotonicNS) else { return }
            let base = Self.contextText(context)
            let directive = """
            This is a controller-authorized offer to report one completed Hermes task, not participant speech.
            pending_hermes_report_task_id: \(task.id.uuidString.lowercased())
            Ask the exact supplied opening once, then listen. Do not expose, summarize, or fetch the result before the administrator answers. After a clear acceptance, call resolve_hermes_report_offer once with this task ID and wants_report=true, then report only the returned actual result. After a clear decline, call it once with wants_report=false, acknowledge briefly, and do not reveal the result. If the answer is ambiguous, ask one concise clarification without calling the tool. Never delegate a new task for this offer.
            """
            pendingHermesReportOfferTaskID = task.id
            launch(
                authorization: "hermes_report_offer",
                initialContext: String([base, directive].filter { !$0.isEmpty }.joined(separator: "\n\n").prefix(24_000)),
                sessionCapability: context.sessionCapability,
                preferredLanguageTag: context.preferredLanguageTag,
                languageStartInstruction: context.languageStartInstruction,
                proactiveOpeningText: HermesReportOfferPrompt.question(
                    languageTag: context.preferredLanguageTag
                ),
                personEntityID: personEntityID,
                personContextReference: context.personContextAvailable ? context.personEntityID : nil,
                interactionAuthority: context.interactionAuthority,
                at: monotonicNS
            )
        }
    }

    /// Cancels only a participant-contact opening whose visual authorization
    /// was disproved before any usable participant input reached the realtime
    /// session. Once input is confirmed, gaze is no longer a session-lifetime
    /// requirement. L1-authorized proactive openings are unaffected.
    func revokeProvisionalParticipantOpening(reason: String) {
        queue.async { [weak self] in
            guard let self,
                  !stopped,
                  initialTurnValidation.shouldCloseWhenContactIsRevoked,
                  active || gate.phase == .starting else {
                return
            }
            _ = closeSession(reason: String(reason.prefix(128)))
        }
    }

    func ingestAudio(
        samples: [Float],
        sampleRateHz: Double,
        captureNS: UInt64,
        durationNS: UInt64
    ) {
        guard !samples.isEmpty,
              sampleRateHz.isFinite,
              sampleRateHz >= 8_000,
              sampleRateHz <= 96_000,
              durationNS > 0 else { return }
        queue.async { [weak self] in
            guard let self, !stopped else { return }
            routeAudioChunk(CapturedLiveAudio(
                samples: samples,
                sampleRate: Int(sampleRateHz.rounded()),
                captureNS: captureNS,
                durationNS: durationNS
            ))
        }
    }

    /// Preserves the single utterance that caused this session to open.  The
    /// live transport can take longer to establish than an ordinary sentence,
    /// so replaying an undifferentiated rolling buffer would either lose its
    /// beginning or submit ambient silence as the first turn.
    func observeVoiceActivity(
        _ active: Bool,
        admitted: Bool = true,
        duplexSpeakerVerified: Bool = false,
        discardBufferedEpisode: Bool = false,
        onsetCaptureNS: UInt64? = nil,
        assessedThroughCaptureNS: UInt64? = nil,
        preserveDetectorHistoryFromCaptureNS: UInt64? = nil,
        at monotonicNS: UInt64
    ) {
        queue.async { [weak self] in
            guard let self, !stopped else { return }
            // VAD drives conditioning; speaker attribution controls only
            // transport. This preserves a quiet first utterance while the
            // bounded audiovisual attribution window is still pending.
            inputLeveler.observeVoiceActivity(active)
            let duplexVerificationRequired = self.active
                && duplexCaptureGate.requiresParticipantVerification(at: monotonicNS)
            if active,
               let onsetCaptureNS,
               (!self.active || requireVerifiedSpeakerForEveryTurn || duplexVerificationRequired) {
                speakerEpisodeAudio.begin(
                    at: onsetCaptureNS,
                    splitting: Self.splitCapturedAudio
                )
                speakerEpisodeInProgress = true
                if duplexVerificationRequired {
                    duplexEpisodeInProgress = true
                    duplexEpisodeAdmitted = false
                }
            }
            let wasDuplexQuarantined = duplexCaptureGate.quarantinesMicrophone(at: monotonicNS)
            let echoAssessment = duplexVerificationRequired
                ? echoReferenceMatcher.assess()
                : nil
            if let echoAssessment,
               echoAssessment.relationship != lastEchoRelationship {
                lastEchoRelationship = echoAssessment.relationship
                onEvent(.playbackEchoAssessed(
                    relationship: echoAssessment.relationship,
                    correlation: echoAssessment.maximumCorrelation
                ))
            }
            let acousticallyIndependent = !duplexVerificationRequired
                || echoAssessment?.permitsBargeIn == true
            let effectiveDuplexSpeakerVerification = duplexSpeakerVerified
                && acousticallyIndependent
                && !discardBufferedEpisode
            duplexCaptureGate.observeParticipantSpeech(
                active: active,
                verified: effectiveDuplexSpeakerVerification,
                at: monotonicNS
            )
            if self.active,
               active,
               effectiveDuplexSpeakerVerification,
               wasDuplexQuarantined,
               let assessedThroughCaptureNS {
                let captured = speakerEpisodeAudio.take(
                    throughCaptureNS: assessedThroughCaptureNS,
                    splitting: Self.splitCapturedAudio
                )
                let durationMilliseconds = Double(captured.reduce(0) { $0 &+ $1.durationNS })
                    / 1_000_000
                for chunk in captured.map(makeBufferedAudio) { send(chunk) }
                duplexEpisodeAdmitted = true
                activeTurnAudioAdmitted = true
                onEvent(.participantBargeInAdmitted(
                    bufferedMilliseconds: durationMilliseconds
                ))
            }
            if active, admitted {
                activeTurnAudioAdmitted = true
            } else if !active {
                activeTurnAudioAdmitted = false
            }
            if discardBufferedEpisode {
                if let preserveDetectorHistoryFromCaptureNS {
                    speakerEpisodeAudio.end(
                        preservingDetectorHistoryFrom: preserveDetectorHistoryFromCaptureNS
                    )
                } else {
                    speakerEpisodeAudio.end()
                }
                speakerEpisodeInProgress = false
                if duplexEpisodeInProgress, !duplexEpisodeAdmitted {
                    onEvent(.acousticEchoDiscarded)
                }
                duplexEpisodeInProgress = false
                duplexEpisodeAdmitted = false
                initiatingTurn.removeAll(keepingCapacity: true)
                capturingInitiatingTurn = false
                activeTurnAudioAdmitted = false
            }
            if !active, !discardBufferedEpisode {
                if let preserveDetectorHistoryFromCaptureNS {
                    speakerEpisodeAudio.end(
                        preservingDetectorHistoryFrom: preserveDetectorHistoryFromCaptureNS
                    )
                } else {
                    speakerEpisodeAudio.end()
                }
                speakerEpisodeInProgress = false
                if duplexEpisodeInProgress, !duplexEpisodeAdmitted {
                    onEvent(.acousticEchoDiscarded)
                }
                duplexEpisodeInProgress = false
                duplexEpisodeAdmitted = false
            }
            if self.active,
               duplexCaptureGate.quarantinesMicrophone(at: monotonicNS) {
                return
            }
            if self.active, requireVerifiedSpeakerForEveryTurn {
                if active, admitted, let assessedThroughCaptureNS {
                    let buffered = speakerEpisodeAudio
                        .take(
                            throughCaptureNS: assessedThroughCaptureNS,
                            splitting: Self.splitCapturedAudio
                        )
                        .map(makeBufferedAudio)
                    for chunk in buffered { send(chunk) }
                }
                return
            }
            guard gate.phase == .starting else { return }
            if active, admitted {
                if requireVerifiedSpeakerForEveryTurn {
                    guard let assessedThroughCaptureNS else { return }
                    initiatingTurn += speakerEpisodeAudio
                        .take(
                            throughCaptureNS: assessedThroughCaptureNS,
                            splitting: Self.splitCapturedAudio
                        )
                        .map(makeBufferedAudio)
                } else {
                    guard !capturingInitiatingTurn else { return }
                    capturingInitiatingTurn = true
                    initiatingTurn = speakerEpisodeAudio.take().map(makeBufferedAudio)
                }
            } else {
                capturingInitiatingTurn = false
            }
        }
    }

    private func routeAudioChunk(_ captured: CapturedLiveAudio) {
        echoReferenceMatcher.appendMicrophone(
            captured.samples,
            sampleRate: captured.sampleRate
        )
        if duplexCaptureGate.quarantinesMicrophone(at: captured.captureNS) {
            speakerEpisodeAudio.ingest(
                captured,
                captureNS: captured.captureNS,
                durationNS: captured.durationNS
            )
        } else if LiveVoiceAudioRoutingPolicy.forwards(
            sessionActive: active,
            requiresVerifiedSpeakerForEveryTurn: requireVerifiedSpeakerForEveryTurn,
            currentTurnAdmitted: activeTurnAudioAdmitted
        ), !requireVerifiedSpeakerForEveryTurn {
            send(makeBufferedAudio(captured))
        } else if capturingInitiatingTurn {
            initiatingTurn.append(makeBufferedAudio(captured))
        } else {
            speakerEpisodeAudio.ingest(
                captured,
                captureNS: captured.captureNS,
                durationNS: captured.durationNS
            )
        }
    }

    private func makeBufferedAudio(_ captured: CapturedLiveAudio) -> BufferedLiveAudio {
        let conditioned = inputLeveler.process(captured.samples)
        return BufferedLiveAudio(
            data: Self.pcm16Data(conditioned.samples).base64EncodedString(),
            sampleRate: captured.sampleRate,
            samplesPerChannel: captured.samples.count,
            durationNS: captured.durationNS,
            inputPeakDBFS: conditioned.inputPeakDBFS,
            appliedGainDB: conditioned.appliedGainDB
        )
    }

    private func resetDuplexCaptureState() {
        duplexCaptureGate.reset()
        duplexEpisodeInProgress = false
        duplexEpisodeAdmitted = false
    }

    private func resetSessionEphemera(keepingAudioCapacity: Bool) {
        activeTurnAudioAdmitted = false
        awaitingAssistantResponse = false
        latestUserTranscriptNS = nil
        initialTurnValidation.reset()
        speakerEpisodeAudio.end(keepingCapacity: keepingAudioCapacity)
        speakerEpisodeInProgress = false
        initiatingTurn.removeAll(keepingCapacity: keepingAudioCapacity)
        capturingInitiatingTurn = false
        inputLeveler.reset()
        resetDuplexCaptureState()
        inactivityTimer?.cancel()
        inactivityTimer = nil
        initialTranscriptTimer?.cancel()
        initialTranscriptTimer = nil
        inactivityGate.close()
        proactiveOpeningAwaitingParticipant = false
        proactiveOpeningDelivered = false
        pendingHermesReportOfferTaskID = nil
    }

    private static func splitCapturedAudio(
        _ captured: CapturedLiveAudio,
        prefixDurationNS: UInt64
    ) -> (prefix: CapturedLiveAudio, suffix: CapturedLiveAudio)? {
        guard prefixDurationNS > 0,
              prefixDurationNS < captured.durationNS,
              captured.samples.count > 1 else { return nil }
        let requestedFraction = Double(prefixDurationNS) / Double(captured.durationNS)
        let prefixCount = min(
            captured.samples.count - 1,
            max(1, Int((Double(captured.samples.count) * requestedFraction).rounded()))
        )
        let suffixDurationNS = captured.durationNS - prefixDurationNS
        return (
            prefix: CapturedLiveAudio(
                samples: Array(captured.samples[..<prefixCount]),
                sampleRate: captured.sampleRate,
                captureNS: captured.captureNS - suffixDurationNS,
                durationNS: prefixDurationNS
            ),
            suffix: CapturedLiveAudio(
                samples: Array(captured.samples[prefixCount...]),
                sampleRate: captured.sampleRate,
                captureNS: captured.captureNS,
                durationNS: suffixDurationNS
            )
        )
    }

    func stop() {
        queue.sync {
            guard !stopped else { return }
            let lifecycle: (threadID: String?, personEntityID: UUID?)? =
                active || activeThreadID != nil || activePersonEntityID != nil
                ? (activeThreadID, activePersonEntityID)
                : nil
            stopped = true
            generation &+= 1
            _ = send(["type": "stop"], reportFailure: false)
            input = nil
            if let process, process.isRunning { process.terminate() }
            self.process = nil
            active = false
            activeThreadID = nil
            activePersonEntityID = nil
            activeSessionCapability = nil
            resetSessionEphemera(keepingAudioCapacity: false)
            if let lifecycle {
                onEvent(.failed(
                    threadID: lifecycle.threadID,
                    personEntityID: lifecycle.personEntityID,
                    reason: "service_shutdown"
                ))
            }
        }
    }

    /// The local MCP endpoint has already validated the capability's general
    /// scope. Match it to this particular helper before ending the session so
    /// a capability from an earlier conversation cannot affect a later one.
    func endCurrentSession(authorizedBy sessionCapability: String?) -> Result<Void, Error> {
        queue.sync {
            guard active else { return .failure(LiveVoiceSessionTerminationError.noActiveSession) }
            guard let activeSessionCapability,
                  let sessionCapability,
                  activeSessionCapability == sessionCapability
                    || persistentAppServer?.capability == sessionCapability else {
                return .failure(LiveVoiceSessionTerminationError.capabilityMismatch)
            }
            _ = closeActiveSession(reason: "participant_requested_end")
            return .success(())
        }
    }

    /// Delivers a completed background result into an already active L2
    /// conversation. It never opens a conversation on its own; otherwise the
    /// durable task remains pending for retrieval in a later session.
    func deliverHermesTaskResult(_ task: HermesAgentTask) -> Bool {
        queue.sync {
            sendHermesTaskResult(task)
        }
    }

    /// Routes one allowlisted Discord bot reply into the active realtime
    /// conversation. The envelope is controller input, never participant
    /// speech or authorization, and it cannot open a session on its own.
    func deliverDiscordReply(_ rawText: String, messageID: String) -> Bool {
        queue.sync {
            guard active else { return false }
            let reply = SOMADiscordConversationClient.spokenReply(from: rawText)
            guard !reply.isEmpty else { return false }
            let safeMessageID = String(messageID.filter(\.isNumber).prefix(24))
            let envelope = """
            SOMA_DISCORD_LABMANAGER_REPLY
            message_id: \(safeMessageID)
            reply:
            \(reply)
            """
            return send([
                "type": "append_controller_text",
                "data": envelope,
            ])
        }
    }

    private func sendHermesTaskResult(_ task: HermesAgentTask) -> Bool {
        guard active,
              task.status == .completed,
              let result = task.result,
              hermesResultAwaitingConfirmation.insert(task.id).inserted else { return false }
        let envelope = """
        SOMA_HERMES_TASK_RESULT
        task_id: \(task.id.uuidString.lowercased())
        title: \(task.title)
        status: completed
        result:
        \(String(result.prefix(90_000)))
        """
        let sent = send([
            "type": "append_text",
            "taskID": task.id.uuidString.lowercased(),
            "data": envelope,
        ])
        if !sent { hermesResultAwaitingConfirmation.remove(task.id) }
        return sent
    }

    /// A dedicated persistent App Server owns one opaque boot capability. It
    /// never becomes an interaction grant by itself: each call is projected
    /// through the active session's short-lived grant while the Live helper is
    /// active, and returns nil for ordinary per-session tokens.
    func authorizePersistentBroker(
        token: String?,
        scope: SOMASessionCapabilityScope,
        at monotonicNS: UInt64
    ) -> Result<Void, SOMASessionCapabilityError>? {
        queue.sync {
            guard let persistentAppServer,
                  token == persistentAppServer.capability,
                  (active || gate.phase == .starting),
                  let activeSessionCapability,
                  let persistentSessionAuthorizer else {
                return nil
            }
            return persistentSessionAuthorizer(activeSessionCapability, scope, monotonicNS)
        }
    }

    private func launch(
        authorization: String,
        initialContext: String,
        sessionCapability: String?,
        preferredLanguageTag: String?,
        languageStartInstruction: String?,
        proactiveOpeningText: String?,
        personEntityID: UUID?,
        personContextReference: UUID?,
        interactionAuthority: SOMAInteractionAuthority?,
        at monotonicNS: UInt64
    ) {
        inputTransportReported = false
        openingVisualContextAttached = false
        awaitingAssistantResponse = false
        latestUserTranscriptNS = nil
        inputLeveler.reset()
        resetDuplexCaptureState()
        activeTurnAudioAdmitted = false
        initialTranscriptTimer?.cancel()
        initialTranscriptTimer = nil
        initialTurnValidation.begin(
            origin: proactiveOpeningText?.isEmpty == false ? .proactive : .participantContact
        )
        proactiveOpeningAwaitingParticipant = proactiveOpeningText?.isEmpty == false
        proactiveOpeningDelivered = false
        let persistentEndpoint: URL?
        if let persistentAppServer {
            switch persistentAppServer.ensureReady() {
            case let .success(endpoint):
                persistentEndpoint = endpoint
            case let .failure(error):
                gate.fail(at: monotonicNS)
                resetSessionEphemera(keepingAudioCapacity: false)
                onEvent(.failed(
                    threadID: nil,
                    personEntityID: personEntityID,
                    reason: String(error.localizedDescription.prefix(192))
                ))
                return
            }
        } else {
            persistentEndpoint = nil
        }
        guard let helperURL = helperURL() else {
            gate.fail(at: monotonicNS)
            resetSessionEphemera(keepingAudioCapacity: false)
            onEvent(.failed(
                threadID: nil,
                personEntityID: personEntityID,
                reason: "live_voice_helper_not_found"
            ))
            return
        }
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = helperURL
        process.arguments = ["--cwd", projectDirectory, "--voice", voice.rawValue]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            queue.async { self.consume(data) }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            queue.async {
                guard self.process === process, !self.stopped else { return }
                self.process = nil
                self.input = nil
                self.active = false
                self.gate.fail(at: DispatchTime.now().uptimeNanoseconds)
                let threadID = self.activeThreadID
                let personEntityID = self.activePersonEntityID
                self.activeThreadID = nil
                self.activePersonEntityID = nil
                self.activeSessionCapability = nil
                self.resetSessionEphemera(keepingAudioCapacity: false)
                self.onEvent(.failed(
                    threadID: threadID,
                    personEntityID: personEntityID,
                    reason: "live_voice_helper_exited_\(process.terminationStatus)"
                ))
            }
        }
        do {
            try process.run()
        } catch {
            gate.fail(at: monotonicNS)
            resetSessionEphemera(keepingAudioCapacity: false)
            onEvent(.failed(
                threadID: nil,
                personEntityID: personEntityID,
                reason: String(error.localizedDescription.prefix(192))
            ))
            return
        }
        self.process = process
        input = inputPipe.fileHandleForWriting
        activePersonEntityID = personEntityID
        activeSessionCapability = sessionCapability
        generation &+= 1
        let launchGeneration = generation
        guard send([
            "type": "start",
            "initialContext": String(initialContext.prefix(24_000)),
            "sessionCapability": sessionCapability ?? "",
            "embodimentSocketPath": embodimentSocketURL?.path ?? "",
            "appServerURL": persistentEndpoint?.absoluteString ?? "",
            "preferredLanguageTag": preferredLanguageTag ?? "",
            "languageStartInstruction": languageStartInstruction ?? "",
            "proactiveOpeningText": proactiveOpeningText ?? "",
            "interactionAuthority": interactionAuthority?.rawValue ?? "",
            "personContextReference": personContextReference?.uuidString.lowercased() ?? "",
            "cameraContextAutoInjected": cameraContextAutoInjection,
            "codexSandbox": somaEnvString("SOMA_L2_CODEX_SANDBOX", default: "danger-full-access"),
            "codexAdminOnly": somaEnvBool("SOMA_L2_CODEX_ADMIN_ONLY", default: false),
            "hermesAgentDelegationEnabled": hermesAgentDelegationEnabled,
        ], reportFailure: false) else {
            failCurrent(reason: "live_voice_start_transport_failed")
            return
        }
        onEvent(.launchRequested(authorization: authorization, personEntityID: personEntityID))
        if let taskID = pendingHermesReportOfferTaskID {
            onEvent(.hermesReportOfferStarted(taskID: taskID))
        }
        queue.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self,
                  generation == launchGeneration,
                  gate.phase == .starting else { return }
            failCurrent(reason: "live_voice_start_timeout")
        }
    }

    private func consume(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let event = try? JSONDecoder().decode(LiveVoiceHelperEvent.self, from: line) else {
                continue
            }
            switch event.event {
            case "active":
                guard !active else { continue }
                active = true
                if !requireVerifiedSpeakerForEveryTurn {
                    activeTurnAudioAdmitted = true
                }
                activeThreadID = event.threadID
                gate.observeActive()
                let activeNS = DispatchTime.now().uptimeNanoseconds
                armInactivityTimeout(at: activeNS)
                armInitialTranscriptTimeout(at: activeNS)
                let buffered = initiatingTurn
                if !requireVerifiedSpeakerForEveryTurn || !speakerEpisodeInProgress {
                    speakerEpisodeAudio.end()
                }
                initiatingTurn.removeAll(keepingCapacity: true)
                capturingInitiatingTurn = false
                // A direct first-turn visual question needs the current frame
                // before its audio is interpreted, not after transcription has
                // already begun.
                if !buffered.isEmpty {
                    enqueueOpeningCameraImageIfEnabled()
                    let durationMilliseconds = Double(buffered.reduce(0) { $0 &+ $1.durationNS }) / 1_000_000
                    let peakDBFS = buffered.map(\.inputPeakDBFS).max() ?? -.infinity
                    let maximumGainDB = buffered.map(\.appliedGainDB).max() ?? 0
                    onEvent(.inputBootstrapReplayed(
                        durationMilliseconds: durationMilliseconds,
                        peakDBFS: peakDBFS,
                        maximumGainDB: maximumGainDB
                    ))
                }
                var submittedOpeningAudio = false
                for chunk in buffered {
                    submittedOpeningAudio = send(chunk) || submittedOpeningAudio
                }
                if submittedOpeningAudio {
                    initialTurnValidation.observeInitialAudioSubmitted()
                }
                onEvent(.active(threadID: event.threadID, personEntityID: activePersonEntityID))
            case "audio_input_progress":
                initialTurnValidation.observeInitialAudioTransportProgress()
                if initialTurnValidation.permitsAssistantResponse {
                    initialTranscriptTimer?.cancel()
                    initialTranscriptTimer = nil
                }
                guard !inputTransportReported else { continue }
                inputTransportReported = true
                onEvent(.inputTransportStarted)
            case "output_playback_ready":
                onEvent(.outputPlaybackReady)
            case "natural_turn_taking_confirmed":
                onEvent(.naturalTurnTakingConfirmed)
            case "response_interrupted":
                onEvent(.responseInterrupted)
            case "interrupted_audio_cleared":
                onEvent(.interruptedAudioCleared)
            case "proactive_opening_triggered":
                onEvent(.proactiveOpeningTriggered)
            case "input_speech_started":
                // Speech onset is enough to establish a participant turn for
                // the proactive-opening guard. The final transcript remains
                // the durable record, but an overlapping answer must not be
                // mistaken for unsolicited extra model speech.
                proactiveOpeningAwaitingParticipant = false
                onEvent(.hearingUser)
            case "visual_context_attached":
                onEvent(.visualContextAttached)
            case "visual_context_rejected":
                onEvent(.visualContextRejected(reason: String((event.reason ?? "unknown").prefix(192))))
            case "embodiment_mcp_ready":
                onEvent(.embodimentMCPReady)
            case "embodiment_mcp_unavailable":
                onEvent(.embodimentMCPUnavailable(reason: String((event.reason ?? "unknown").prefix(192))))
            case "hermes_task_result_accepted":
                if let rawID = event.taskID, let taskID = UUID(uuidString: rawID) {
                    hermesResultAwaitingConfirmation.remove(taskID)
                    onEvent(.hermesTaskResultAccepted(taskID: taskID))
                }
            case "hermes_task_result_rejected":
                if let rawID = event.taskID, let taskID = UUID(uuidString: rawID) {
                    hermesResultAwaitingConfirmation.remove(taskID)
                }
                onEvent(.hermesTaskResultRejected(
                    taskID: event.taskID.flatMap(UUID.init(uuidString:)),
                    reason: String((event.reason ?? "unknown").prefix(192))
                ))
            case "discord_reply_accepted":
                onEvent(.discordReplyAccepted)
            case "discord_reply_rejected":
                onEvent(.discordReplyRejected(
                    reason: String((event.reason ?? "unknown").prefix(192))
                ))
            case "person_context_ready":
                onEvent(.personContextReady)
            case "person_context_unavailable":
                onEvent(.personContextUnavailable(reason: String((event.reason ?? "unknown").prefix(192))))
            case "embodiment_mcp_call":
                let tool = String((event.tool ?? "unknown").prefix(96))
                let status = String((event.status ?? "unknown").prefix(48))
                let error = event.error?.trimmingCharacters(in: .whitespacesAndNewlines)
                onEvent(.embodimentMCPCall(
                    tool: tool,
                    status: status,
                    error: error?.isEmpty == false ? String(error!.prefix(192)) : nil
                ))
            case "input_transcript_ready":
                if (event.characters ?? 0) > 0 {
                    confirmInitialParticipantInput()
                }
                onEvent(.inputAccepted(characters: max(0, event.characters ?? 0)))
            case "transcript_finalized":
                guard let rawRole = event.role,
                      let role = ConversationParticipantRole(rawValue: rawRole),
                      let text = event.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { continue }
                if role == .assistant {
                    if proactiveOpeningAwaitingParticipant {
                        if proactiveOpeningDelivered {
                            onEvent(.proactiveOpeningExtraOutputSuppressed)
                            _ = closeActiveSession(reason: "proactive_opening_extra_output")
                            continue
                        }
                        proactiveOpeningDelivered = true
                    }
                } else {
                    confirmInitialParticipantInput()
                    proactiveOpeningAwaitingParticipant = false
                    let now = DispatchTime.now().uptimeNanoseconds
                    awaitingAssistantResponse = true
                    latestUserTranscriptNS = now
                    recordUserActivity(at: now)
                    onEvent(.inputAccepted(characters: text.count))
                }
                onEvent(.transcriptFinalized(
                    threadID: event.threadID,
                    role: role,
                    text: String(text.prefix(8_192))
                ))
            case "response_preparing":
                if !initialTurnValidation.permitsAssistantResponse {
                    _ = closeSession(reason: "participant_input_unconfirmed_before_response")
                    continue
                }
                onEvent(.preparingResponse)
            case "output_speech_started":
                if !initialTurnValidation.permitsAssistantResponse {
                    _ = closeSession(reason: "participant_input_unconfirmed_before_output")
                    continue
                }
                echoReferenceMatcher.reset()
                lastEchoRelationship = nil
                outputReferenceReported = false
                duplexCaptureGate.beginAssistantOutput(at: DispatchTime.now().uptimeNanoseconds)
                onEvent(.microphoneCaptureSuppressed)
                onEvent(.assistantSpeechStarted)
                if let latestUserTranscriptNS {
                    let now = DispatchTime.now().uptimeNanoseconds
                    onEvent(.responseStarted(
                        latencyMilliseconds: elapsedMilliseconds(
                            from: latestUserTranscriptNS,
                            to: now
                        )
                    ))
                    self.latestUserTranscriptNS = nil
                }
                onEvent(.responding)
            case "output_speech_ended":
                duplexCaptureGate.endAssistantOutput(at: DispatchTime.now().uptimeNanoseconds)
                onEvent(.assistantSpeechEnded)
            case "assistant_output_reference":
                guard let data = event.data,
                      let sampleRate = event.sampleRate,
                      let channels = event.numChannels,
                      let expectedSamples = event.samplesPerChannel,
                      let samples = Self.decodePCM16(
                        data,
                        channels: channels,
                        expectedSamplesPerChannel: expectedSamples
                      ) else { continue }
                if event.resetReference == true {
                    echoReferenceMatcher.reset()
                    lastEchoRelationship = nil
                    outputReferenceReported = false
                }
                echoReferenceMatcher.appendReference(
                    samples,
                    sampleRate: sampleRate,
                    channels: channels
                )
                if !outputReferenceReported {
                    outputReferenceReported = true
                    onEvent(.assistantOutputReferenceReady(
                        sampleRate: sampleRate,
                        samples: expectedSamples
                    ))
                }
            case "response_completed":
                // Generation can complete before the remote playback buffer
                // drains, so microphone capture resumes only when playback
                // reports output_speech_ended.
                finishAssistantResponseIfNeeded()
                onEvent(.responseCompleted)
            case "ended":
                guard active || gate.phase == .starting else { continue }
                let threadID = event.threadID ?? activeThreadID
                let personEntityID = activePersonEntityID
                active = false
                gate.observeEnded()
                process = nil
                input = nil
                activeThreadID = nil
                activePersonEntityID = nil
                activeSessionCapability = nil
                resetSessionEphemera(keepingAudioCapacity: false)
                onEvent(.ended(
                    threadID: threadID,
                    personEntityID: personEntityID,
                    reason: String((event.reason ?? "session_ended").prefix(128))
                ))
            case "failed", "audio_rejected":
                failCurrent(reason: event.reason ?? event.event)
            default:
                break
            }
        }
    }

    private func failCurrent(reason: String) {
        let threadID = activeThreadID
        let personEntityID = activePersonEntityID
        generation &+= 1
        active = false
        gate.fail(at: DispatchTime.now().uptimeNanoseconds)
        _ = send(["type": "stop"], reportFailure: false)
        if let process, process.isRunning { process.terminate() }
        self.process = nil
        input = nil
        activeThreadID = nil
        activePersonEntityID = nil
        activeSessionCapability = nil
        resetSessionEphemera(keepingAudioCapacity: false)
        onEvent(.failed(
            threadID: threadID,
            personEntityID: personEntityID,
            reason: String(reason.prefix(192))
        ))
    }

    private func confirmInitialParticipantInput() {
        initialTurnValidation.confirmParticipantInput()
        initialTranscriptTimer?.cancel()
        initialTranscriptTimer = nil
    }

    private func armInitialTranscriptTimeout(at monotonicNS: UInt64) {
        initialTranscriptTimer?.cancel()
        initialTranscriptTimer = nil
        guard let deadline = initialTurnValidation.observeTransportActive(at: monotonicNS) else {
            return
        }
        let remainingNS = deadline > monotonicNS ? deadline - monotonicNS : 0
        let work = DispatchWorkItem { [weak self] in
            self?.closeForMissingInitialTranscript(at: DispatchTime.now().uptimeNanoseconds)
        }
        initialTranscriptTimer = work
        queue.asyncAfter(
            deadline: .now() + .nanoseconds(Int(min(remainingNS, UInt64(Int.max)))),
            execute: work
        )
    }

    private func closeForMissingInitialTranscript(at monotonicNS: UInt64) {
        guard initialTurnValidation.shouldCloseForMissingTranscript(at: monotonicNS) else {
            return
        }
        _ = closeSession(reason: "initial_participant_transcript_timeout")
    }

    private func recordUserActivity(at monotonicNS: UInt64) {
        guard active, inactivityGate.recordUserActivity(at: monotonicNS) != nil else { return }
        armInactivityTimeout(at: monotonicNS)
    }

    private func finishAssistantResponseIfNeeded() {
        guard awaitingAssistantResponse else { return }
        awaitingAssistantResponse = false
        latestUserTranscriptNS = nil
    }

    private func elapsedMilliseconds(from earlier: UInt64, to later: UInt64) -> Double {
        guard later >= earlier else { return 0 }
        return Double(later - earlier) / 1_000_000
    }

    private func armInactivityTimeout(at monotonicNS: UInt64) {
        let deadline = inactivityGate.deadlineNS ?? inactivityGate.activate(at: monotonicNS)
        inactivityTimer?.cancel()
        let remainingNS = deadline > monotonicNS ? deadline - monotonicNS : 0
        let work = DispatchWorkItem { [weak self] in
            self?.closeForUserSilence(at: DispatchTime.now().uptimeNanoseconds)
        }
        inactivityTimer = work
        queue.asyncAfter(
            deadline: .now() + .nanoseconds(Int(min(remainingNS, UInt64(Int.max)))),
            execute: work
        )
    }

    private func closeForUserSilence(at monotonicNS: UInt64) {
        guard active, inactivityGate.shouldClose(at: monotonicNS) else { return }
        _ = closeActiveSession(reason: "user_silence_timeout")
    }

    @discardableResult
    private func closeActiveSession(reason: String) -> Bool {
        guard active else { return false }
        return closeSession(reason: reason)
    }

    @discardableResult
    private func closeSession(reason: String) -> Bool {
        guard active || gate.phase == .starting else { return false }
        let threadID = activeThreadID
        let personEntityID = activePersonEntityID
        generation &+= 1
        active = false
        gate.observeEnded()
        _ = send(["type": "stop"], reportFailure: false)
        input = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        activeThreadID = nil
        activePersonEntityID = nil
        activeSessionCapability = nil
        resetSessionEphemera(keepingAudioCapacity: false)
        onEvent(.ended(
            threadID: threadID,
            personEntityID: personEntityID,
            reason: String(reason.prefix(128))
        ))
        return true
    }

    @discardableResult
    private func send(_ chunk: BufferedLiveAudio) -> Bool {
        send([
            "type": "append_audio",
            "data": chunk.data,
            "sampleRate": chunk.sampleRate,
            "samplesPerChannel": chunk.samplesPerChannel,
        ])
    }

    /// One opening frame grounds a user-initiated conversation without making
    /// every speech onset a permanent item in the realtime thread.
    private func enqueueOpeningCameraImageIfEnabled() {
        guard cameraContextAutoInjection else { return }
        enqueueOpeningCameraImage()
    }

    private func enqueueOpeningCameraImage() {
        guard active,
              !openingVisualContextAttached,
              let currentCameraImageDataURI,
              let dataURI = currentCameraImageDataURI(),
              dataURI.utf8.count <= 4 * 1_048_576 else { return }
        openingVisualContextAttached = true
        send([
            "type": "append_image",
            "data": dataURI,
        ])
    }

    @discardableResult
    private func send(_ object: [String: Any], reportFailure: Bool = true) -> Bool {
        guard let input,
              JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return false }
        do {
            try input.write(contentsOf: data)
            try input.write(contentsOf: Data([0x0A]))
            return true
        } catch {
            guard reportFailure else { return false }
            let threadID = activeThreadID
            let personEntityID = activePersonEntityID
            self.input = nil
            active = false
            gate.fail(at: DispatchTime.now().uptimeNanoseconds)
            if let process, process.isRunning { process.terminate() }
            self.process = nil
            activeThreadID = nil
            activePersonEntityID = nil
            if !stopped {
                onEvent(.failed(
                    threadID: threadID,
                    personEntityID: personEntityID,
                    reason: "live_voice_control_pipe_failed"
                ))
            }
            return false
        }
    }

    private static func decodePCM16(
        _ encoded: String,
        channels: Int,
        expectedSamplesPerChannel: Int
    ) -> [Float]? {
        guard (1...8).contains(channels),
              (1...65_536).contains(expectedSamplesPerChannel),
              let data = Data(base64Encoded: encoded),
              data.count == expectedSamplesPerChannel * channels * 2 else { return nil }
        var samples: [Float] = []
        samples.reserveCapacity(expectedSamplesPerChannel * channels)
        for index in stride(from: 0, to: data.count, by: 2) {
            let bits = UInt16(data[index]) | (UInt16(data[index + 1]) << 8)
            samples.append(Float(Int16(bitPattern: bits)) / 32_768)
        }
        return samples
    }

    private func helperURL() -> URL? {
        let fileManager = FileManager.default
        if let override = ProcessInfo.processInfo.environment["SOMA_LIVE_VOICE_HELPER"],
           fileManager.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let candidates = [
            executableURL.deletingLastPathComponent().appendingPathComponent("soma-live-voice"),
            executableURL.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Helpers/soma-live-voice"),
        ]
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private static func contextText(_ context: CodexInteractionContext) -> String {
        var lines = [
            "SOMA interaction context (machine observation, not user speech):",
            "privacy_scope: \(context.privacyScope)",
        ]
        if let value = context.situationSummary { lines.append("situation: \(value)") }
        if let value = context.identityReference { lines.append("identity: \(value)") }
        if context.personContextAvailable, let value = context.personEntityID {
            lines.append("person_context_reference: \(value.uuidString.lowercased())")
        }
        if let value = context.interactionAuthority { lines.append("interaction_authority: \(value.rawValue)") }
        if let value = context.personMemoryMission {
            lines.append("person_memory_mission_required: \(value.missingRequiredKeys.joined(separator: ","))")
        }
        if let value = context.preferredLanguageTag { lines.append("preferred_language: \(value)") }
        if let value = context.languageStartInstruction { lines.append("l1_language_instruction: \(value)") }
        if let value = context.rapportSummary { lines.append("rapport: \(value)") }
        if let value = context.embodimentSummary { lines.append("embodiment: \(value)") }
        if !context.activeTaskSummaries.isEmpty {
            lines.append("active_tasks: \(context.activeTaskSummaries.joined(separator: " | "))")
        }
        if !context.memorySummaries.isEmpty {
            lines.append("memory: \(context.memorySummaries.joined(separator: " | "))")
        }
        return String(lines.joined(separator: "\n").prefix(24_000))
    }

    private static func pcm16Data(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * MemoryLayout<Int16>.size)
        for sample in samples {
            var value = Int16(
                max(Double(Int16.min), min(Double(Int16.max), Double(sample) * Double(Int16.max)))
            ).littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        return data
    }
}

func testAppServerLiveVoiceLauncher() -> String {
    let semaphore = DispatchSemaphore(value: 0)
    let result = BlockingLiveVoiceTestResult()
    let launcher = AppServerLiveVoiceLauncher { event in
        switch event {
        case .active:
            if result.observeActive() { semaphore.signal() }
        case .naturalTurnTakingConfirmed:
            break
        case let .failed(_, _, reason):
            result.fail(reason)
            semaphore.signal()
        case .launchRequested, .inputTransportStarted, .outputPlaybackReady,
             .inputBootstrapReplayed,
             .responseInterrupted, .interruptedAudioCleared, .proactiveOpeningTriggered,
             .proactiveOpeningExtraOutputSuppressed, .hermesReportOfferStarted, .hearingUser,
             .visualContextAttached, .visualContextRejected,
             .embodimentMCPReady, .embodimentMCPUnavailable, .personContextReady,
             .hermesTaskResultAccepted, .hermesTaskResultRejected,
             .personContextUnavailable, .embodimentMCPCall, .inputAccepted,
             .transcriptFinalized, .preparingResponse, .responseStarted,
             .discordReplyAccepted, .discordReplyRejected,
             .assistantSpeechStarted, .assistantSpeechEnded,
             .assistantOutputReferenceReady, .microphoneCaptureSuppressed,
             .playbackEchoAssessed, .participantBargeInAdmitted, .acousticEchoDiscarded,
             .responding, .responseCompleted, .ended:
            break
        }
    }
    launcher.startIfNeeded(
        authorization: "explicit_test",
        context: nil,
        at: DispatchTime.now().uptimeNanoseconds
    )
    _ = semaphore.wait(timeout: .now() + 25)
    let value = result.value ?? "timeout"
    launcher.stop()
    return value
}

private final class BlockingLiveVoiceTestResult: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    private var failureReason: String?

    func observeActive() -> Bool {
        lock.lock()
        active = true
        lock.unlock()
        return true
    }

    func fail(_ reason: String) {
        lock.lock()
        failureReason = reason
        lock.unlock()
    }

    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        if let failureReason { return "failed:\(failureReason)" }
        if active { return "active" }
        return nil
    }
}
