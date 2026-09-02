#if canImport(XCTest)
import Foundation
import XCTest
@testable import SOMACore

final class EventImportanceTests: XCTestCase {
    private func audiovisualEpisodeGate(
        maximumResolutionMilliseconds: UInt64 = 3_000,
        maximumEvidenceSkewMilliseconds: UInt64 = 750,
        maximumContactLeadMilliseconds: UInt64 = 250
    ) -> LiveVoiceSpeakerEpisodeGate {
        LiveVoiceSpeakerEpisodeGate(
            maximumResolutionMilliseconds: maximumResolutionMilliseconds,
            maximumEvidenceSkewMilliseconds: maximumEvidenceSkewMilliseconds,
            maximumContactLeadMilliseconds: maximumContactLeadMilliseconds,
            openingSpeechConfiguration: .init(
                strongConfidence: 0,
                supportingConfidence: 0,
                requiredStrongWindows: 1,
                requiredSupportingWindows: 1
            )
        )
    }

    func testDistributionNormalizesAndHumanInteractionRequiresAuthorization() {
        let model = EventImportanceModel()
        let novelty = decision(
            model: model,
            features: EventImportanceFeatures(
                novelty: 1,
                predictionError: 0.9,
                informationGain: 0.9,
                persistence: 0.8
            )
        )
        XCTAssertEqual(novelty.policyReason, .humanInteractionNotAuthorized)
        XCTAssertEqual(novelty.distribution.requestHumanInteraction, 0)
        XCTAssertEqual(novelty.recommendedRoute, .wakeL1)
        XCTAssertEqual(novelty.distribution.sum, 1, accuracy: 1e-12)
    }

    func testExplicitContactOpensInteractionAndBuildsL1ContextInParallel() {
        let result = decision(
            model: EventImportanceModel(),
            features: EventImportanceFeatures(
                explicitContact: 0.95,
                socialSalience: 0.9,
                interruptionCost: 1,
                recentWakePressure: 1,
                humanPresence: 0.95
            )
        )
        XCTAssertEqual(result.policyReason, .explicitHumanContact)
        XCTAssertEqual(result.recommendedRoute, .requestHumanInteraction)
        XCTAssertGreaterThan(result.distribution.requestHumanInteraction, 0)
        XCTAssertEqual(result.sample(unitInterval: 0), .requestHumanInteraction)
        XCTAssertTrue(result.dispatch.openHumanInteraction)
        XCTAssertTrue(result.dispatch.wakeL1Context)
        XCTAssertTrue(result.dispatch.bypassesL1Admission)
    }

    func testExplicitContactWakeAndFinalTranscriptHandoffToCodex() throws {
        let result = decision(
            model: EventImportanceModel(),
            features: EventImportanceFeatures(
                explicitContact: 0.95,
                socialSalience: 0.9,
                crossModalCorroboration: 0.95,
                humanPresence: 0.95
            )
        )
        let wake = try HumanInteractionWakeRequest(
            decision: result,
            audioPreRollMilliseconds: 900
        )
        XCTAssertTrue(wake.bypassesL1Admission)
        XCTAssertTrue(wake.prepareL1ContextInParallel)

        let turn = try CodexInteractionTurn(
            interactionID: "interaction-1",
            turnID: "turn-1",
            transcript: "안녕, what are you looking at?",
            languageTag: "und",
            speechStartedAtNS: 1_000,
            transcriptFinalizedAtNS: 2_000,
            evidenceIDs: wake.evidenceIDs,
            contextPacketReference: "context:interaction-1:1"
        )
        let encoded = try JSONEncoder().encode(turn)
        let json = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(json.contains("안녕, what are you looking at?"))
        XCTAssertFalse(json.lowercased().contains("audio"))
        XCTAssertEqual(try JSONDecoder().decode(CodexInteractionTurn.self, from: encoded), turn)
    }

    func testSpeechTurnRequiresAuthorizedWakeAndClosesOnVoiceOffset() throws {
        var segmenter = SpeechTurnSegmenter()
        XCTAssertNil(segmenter.observe(voiceActive: true, at: 1_000_000_000))

        let result = decision(
            model: EventImportanceModel(),
            features: EventImportanceFeatures(
                explicitContact: 0.9,
                socialSalience: 0.9,
                crossModalCorroboration: 0.9,
                humanPresence: 0.9
            )
        )
        let wake = try HumanInteractionWakeRequest(
            decision: result,
            audioPreRollMilliseconds: 900
        )
        let started = segmenter.observe(
            voiceActive: true,
            at: 2_000_000_000,
            authorizedWake: wake
        )
        guard case .started(let start) = started else {
            return XCTFail("authorized voice did not start a turn")
        }
        XCTAssertEqual(start.speechStartedAtNS, 1_740_000_000)
        XCTAssertNil(segmenter.observe(voiceActive: true, at: 2_500_000_000))

        let finished = segmenter.observe(voiceActive: false, at: 3_000_000_000)
        guard case .finished(let finish) = finished else {
            return XCTFail("voice offset did not finish the turn")
        }
        XCTAssertEqual(finish.reason, .voiceOffset)
        XCTAssertEqual(finish.speechStartedAtNS, start.speechStartedAtNS)
        XCTAssertEqual(finish.speechEndedAtNS, 3_000_000_000)
    }

    func testSpeechTurnIsBoundedAndRearmsAfterCooldown() throws {
        var segmenter = SpeechTurnSegmenter(configuration: .init(
            analysisLookbackMilliseconds: 100,
            maximumTurnMilliseconds: 1_000,
            rearmMilliseconds: 500
        ))
        let result = decision(
            model: EventImportanceModel(),
            features: EventImportanceFeatures(explicitContact: 1, humanPresence: 1)
        )
        let wake = try HumanInteractionWakeRequest(decision: result, audioPreRollMilliseconds: 500)
        XCTAssertNotNil(segmenter.observe(voiceActive: true, at: 1_000_000_000, authorizedWake: wake))

        let bounded = segmenter.observe(voiceActive: true, at: 1_900_000_000)
        guard case .finished(let finish) = bounded else {
            return XCTFail("maximum utterance duration was not enforced")
        }
        XCTAssertEqual(finish.reason, .maximumDuration)
        XCTAssertNil(segmenter.observe(voiceActive: true, at: 2_300_000_000, authorizedWake: wake))
        XCTAssertNotNil(segmenter.observe(voiceActive: true, at: 2_400_000_000, authorizedWake: wake))
    }

    func testCodexAccountBridgeBuildsBoundedScopedPromptAndParsesCLIJSONL() throws {
        let turn = try CodexInteractionTurn(
            interactionID: "interaction-account",
            turnID: "turn-account",
            transcript: "지금 뭘 보고 있어?",
            languageTag: "ko",
            speechStartedAtNS: 10,
            transcriptFinalizedAtNS: 20,
            evidenceIDs: ["vision:face", "voice:onset"],
            contextPacketReference: "context:account"
        )
        let context = try CodexInteractionContext(
            situationSummary: "A known human is centered in the current view.",
            identityReference: "person:local-owner",
            preferredLanguageTag: "ko",
            languageStartInstruction: "한국어로 자연스럽게 대답하세요.",
            rapportSummary: "familiar",
            activeTaskSummaries: ["Finish the SOMA interaction bridge."],
            memorySummaries: ["The user prefers concise Korean responses."],
            embodimentSummary: "L0 currently owns face fixation."
        )
        let request = try CodexAccountTurnRequest(turn: turn, context: context)
        try request.validate()
        let prompt = CodexAccountPromptBuilder.prompt(for: request)
        XCTAssertTrue(prompt.contains("지금 뭘 보고 있어?"))
        XCTAssertTrue(prompt.contains("person:local-owner"))
        XCTAssertTrue(prompt.contains("Preferred response language: ko"))
        XCTAssertTrue(prompt.contains("한국어로 자연스럽게 대답하세요."))
        XCTAssertTrue(prompt.contains("preceding turns in this same interaction"))
        XCTAssertTrue(prompt.contains("Cognitive tool initiative"))
        XCTAssertTrue(prompt.contains("do not wait for the participant to name the tool"))
        XCTAssertTrue(prompt.contains("File, shell, network, service, system"))
        XCTAssertEqual(L2CognitiveToolPolicy.autonomy(for: "capture_view"), .goalBoundEmbodiment)
        XCTAssertEqual(L2CognitiveToolPolicy.autonomy(for: "get_person_context"), .epistemic)
        XCTAssertEqual(L2CognitiveToolPolicy.autonomy(for: "set_person_fact"), .groundedMemoryWrite)
        XCTAssertEqual(L2CognitiveToolPolicy.autonomy(for: "enroll_present_identity"), .explicitConsent)
        XCTAssertEqual(L2CognitiveToolPolicy.autonomy(for: "set_audio_input_gain"), .explicitRequest)
        XCTAssertNil(L2CognitiveToolPolicy.autonomy(for: "future_unknown_tool"))
        XCTAssertTrue(L2CognitiveToolPolicy.permits(.autonomousGoal, for: "capture_view"))
        XCTAssertFalse(L2CognitiveToolPolicy.permits(.autonomousGoal, for: "set_audio_input_gain"))
        XCTAssertTrue(L2CognitiveToolPolicy.permits(.explicitRequest, for: "set_audio_input_gain"))
        XCTAssertEqual(L2CognitiveToolPolicy.autonomy(for: "observe_host_screen"), .explicitRequest)
        XCTAssertEqual(L2CognitiveToolPolicy.autonomy(for: "control_host_computer"), .explicitRequest)
        XCTAssertFalse(L2CognitiveToolPolicy.permits(.autonomousGoal, for: "observe_host_screen"))
        XCTAssertTrue(L2CognitiveToolPolicy.permits(.explicitRequest, for: "observe_host_screen"))
        XCTAssertEqual(L2CognitiveToolPolicy.effect(for: "control_host_computer"), .hostComputer)
        XCTAssertFalse(L2CognitiveToolPolicy.usesSemanticDeduplication(for: "observe_host_screen"))
        XCTAssertTrue(L2CognitiveToolPolicy.usesSemanticDeduplication(for: "control_host_computer"))
        XCTAssertFalse(L2CognitiveToolPolicy.permits(.explicitStatement, for: "enroll_present_identity"))
        XCTAssertTrue(L2CognitiveToolPolicy.permits(.explicitConsent, for: "enroll_present_identity"))
        XCTAssertThrowsError(try JSONDecoder().decode(
            L2CognitiveAuthorizationBasis.self,
            from: Data("\"system_preflight\"".utf8)
        ))
        XCTAssertFalse(prompt.lowercased().contains("raw audio"))

        let jsonl = """
        {"type":"thread.started","thread_id":"thread-123"}
        {"type":"turn.started"}
        {"type":"item.completed","item":{"id":"item-1","type":"agent_message","text":"당신을 보고 있어요."}}
        {"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":12,"reasoning_output_tokens":2}}
        """
        let result = try CodexCLIJSONLParser.parse(Data(jsonl.utf8))
        XCTAssertEqual(result.threadID, "thread-123")
        XCTAssertEqual(result.assistantText, "당신을 보고 있어요.")
        XCTAssertEqual(result.usage?.cachedInputTokens, 20)
    }

    func testCompletedPersonMemoryMissionIsOmittedFromLiveContext() throws {
        let personID = UUID()
        let completed = PersonContextMission(
            requiredKeys: ["preferred_name"],
            missingRequiredKeys: [],
            recommendedKeys: ["relationship_context"]
        )
        let context = try CodexInteractionContext(
            personEntityID: personID,
            sessionCapability: UUID().uuidString.lowercased(),
            interactionAuthority: .participant,
            personMemoryMission: completed
        )
        XCTAssertNil(context.personMemoryMission)
        XCTAssertEqual(context.personEntityID, personID)
        XCTAssertNotNil(context.sessionCapability)
    }

    func testUnrecognizedLiveSpeakerKeepsEmbodimentAuthorityWithoutPersonMemory() throws {
        let context = try CodexInteractionContext(
            personEntityID: UUID(),
            personContextAvailable: false,
            sessionCapability: UUID().uuidString.lowercased(),
            interactionAuthority: .participant,
            personMemoryMission: PersonContextMission(
                requiredKeys: ["preferred_name"],
                missingRequiredKeys: ["preferred_name"],
                recommendedKeys: []
            )
        )
        XCTAssertFalse(context.personContextAvailable)
        XCTAssertNil(context.personMemoryMission)

        let restored = try JSONDecoder().decode(
            CodexInteractionContext.self,
            from: JSONEncoder().encode(context)
        )
        XCTAssertEqual(restored, context)
    }

    func testInteractionContextRetainsBoundedProactiveIdentityDescription() throws {
        let description = "locally recognized person; do not infer an identity beyond supplied context. Person context is available only through the supplied local MCP reference. Explicit stored preferences: Address this person as \"승엽\"."
        let context = try CodexInteractionContext(
            identityReference: description,
            personEntityID: UUID(),
            sessionCapability: UUID().uuidString.lowercased(),
            interactionAuthority: .administrator
        )
        XCTAssertEqual(context.identityReference, description)
    }

    func testCodexAccountBridgeRejectsAnInvalidDecodedTurn() throws {
        let json = """
        {"schemaVersion":1,"turn":{"interactionID":"interaction","turnID":"turn","transcript":"   ","speechStartedAtNS":20,"transcriptFinalizedAtNS":10,"evidenceIDs":[]},"context":{"activeTaskSummaries":[],"memorySummaries":[],"privacyScope":"interaction_scoped"}}
        """
        let decoded = try JSONDecoder().decode(CodexAccountTurnRequest.self, from: Data(json.utf8))
        XCTAssertThrowsError(try decoded.validate())
    }

    func testNonHumanNoveltyCannotCreateInteractionWake() {
        let result = decision(
            model: EventImportanceModel(),
            features: EventImportanceFeatures(novelty: 1, informationGain: 1)
        )
        XCTAssertThrowsError(
            try HumanInteractionWakeRequest(
                decision: result,
                audioPreRollMilliseconds: 900
            )
        )
    }

    func testSafetyRemainsLocalAndCannotOpenHumanInteraction() {
        let result = decision(
            model: EventImportanceModel(),
            features: EventImportanceFeatures(
                explicitContact: 1,
                urgency: 1,
                safetyRisk: 1,
                humanPresence: 1
            )
        )
        XCTAssertEqual(result.policyReason, .localSafety)
        XCTAssertEqual(result.recommendedRoute, .stayL0)
        XCTAssertEqual(result.distribution.requestHumanInteraction, 0)
        XCTAssertFalse(result.dispatch.openHumanInteraction)
        XCTAssertEqual(result.sample(unitInterval: 0.99), .stayL0)
    }

    func testAcceptedMemoryCuriosityCanOpenInteractionOnlyWithHumanPresent() {
        let absent = decision(
            model: EventImportanceModel(),
            features: EventImportanceFeatures(acceptedMemoryCuriosity: 1)
        )
        XCTAssertEqual(absent.distribution.requestHumanInteraction, 0)

        let present = decision(
            model: EventImportanceModel(),
            features: EventImportanceFeatures(
                socialSalience: 0.8,
                humanPresence: 0.9,
                acceptedMemoryCuriosity: 1
            )
        )
        XCTAssertEqual(present.policyReason, .acceptedMemoryCuriosity)
        XCTAssertEqual(present.recommendedRoute, .requestHumanInteraction)
        XCTAssertTrue(present.dispatch.openHumanInteraction)
        XCTAssertFalse(present.dispatch.bypassesL1Admission)
    }

    func testBootstrapCorpusAndTemperatureCalibration() throws {
        let examples = try loadBootstrapCorpus()
        let calibration = examples.filter { $0.partition == .calibration }
        let evaluation = examples.filter { $0.partition == .evaluation }
        XCTAssertEqual(calibration.count, 16)
        XCTAssertEqual(evaluation.count, 16)
        let baseline = try EventImportanceEvaluator.evaluate(model: EventImportanceModel(), examples: calibration)
        let temperature = try EventImportanceEvaluator.calibratedTemperature(
            parameters: .bootstrap,
            examples: calibration
        )
        let calibratedParameters = try EventImportanceParameters.bootstrap.withTemperature(temperature)
        let calibrated = try EventImportanceEvaluator.evaluate(
            model: EventImportanceModel(parameters: calibratedParameters),
            examples: calibration
        )
        let heldOut = try EventImportanceEvaluator.evaluate(
            model: EventImportanceModel(parameters: calibratedParameters),
            examples: evaluation
        )
        XCTAssertLessThanOrEqual(calibrated.negativeLogLikelihood, baseline.negativeLogLikelihood + 1e-12)
        XCTAssertEqual(calibrated.unauthorizedHumanInteractionRequests, 0)
        XCTAssertEqual(heldOut.unauthorizedHumanInteractionRequests, 0)
    }

    func testSamplingIsReplayable() {
        let result = decision(model: EventImportanceModel(), features: EventImportanceFeatures())
        XCTAssertEqual(result.sample(unitInterval: 0), .stayL0)
        XCTAssertEqual(result.sample(unitInterval: 0), result.sample(unitInterval: 0))
    }

    func testLegacyInteractionRouteDecodesButNewEncodingIsLayerNeutral() throws {
        let legacy = try JSONDecoder().decode(
            CognitiveRoute.self,
            from: Data("\"request_l2_human\"".utf8)
        )
        XCTAssertEqual(legacy, .requestHumanInteraction)
        XCTAssertEqual(
            String(decoding: try JSONEncoder().encode(legacy), as: UTF8.self),
            "\"request_human_interaction\""
        )
    }

    func testLegacyThirdLayerEmbodimentAuthorityMigratesToL2() throws {
        let legacy = try JSONDecoder().decode(
            CognitiveControlLayer.self,
            from: Data("\"l3\"".utf8)
        )
        XCTAssertEqual(legacy, .l2)
        XCTAssertEqual(CognitiveControlLayer.allCases, [.l1, .l2])
        XCTAssertEqual(
            String(decoding: try JSONEncoder().encode(legacy), as: UTF8.self),
            "\"l2\""
        )
    }

    func testDirectContactIsRequiredToStartUserConversation() {
        let start: UInt64 = 1_000_000_000
        var gate = ConversationContactGate(configuration: .init(
            conversationInactivityMilliseconds: 60_000
        ))
        XCTAssertEqual(
            gate.observeVoiceActivity(active: true, at: start, directContact: false),
            nil
        )
        _ = gate.observeVoiceActivity(active: false, at: start + 1, directContact: false)
        XCTAssertEqual(
            gate.observeVoiceActivity(active: true, at: start + 2, directContact: true),
            .voiceActivity
        )
    }

    func testNewConversationRequiresCurrentL0FixationRatherThanGazeHistory() {
        let start: UInt64 = 1_000_000_000
        var fixation = L0FaceFixationAdmission(freshnessMilliseconds: 500)
        var conversation = ConversationContactGate()

        // A detector can retain a direct-gaze history while L0 has already
        // resumed coverage. Clearing the L0 fixation must make that history
        // ineligible for a fresh voice session.
        fixation.observeVerifiedFixation(
            sceneID: "face-a",
            directContact: true,
            at: start
        )
        XCTAssertTrue(fixation.permitsNewSession(at: start + 100_000_000))
        fixation.clear()
        XCTAssertFalse(fixation.permitsNewSession(at: start + 120_000_000))
        XCTAssertNil(
            conversation.observeVoiceActivity(
                active: true,
                at: start + 120_000_000,
                directContact: fixation.permitsNewSession(at: start + 120_000_000)
            )
        )
    }

    func testAmbientVoiceEpisodeCannotBeUpgradedByLaterEyeContact() {
        let start: UInt64 = 1_000_000_000
        var gate = ConversationContactGate()

        XCTAssertNil(
            gate.observeVoiceActivity(active: true, at: start, directContact: false)
        )
        XCTAssertNil(
            gate.observeVoiceActivity(
                active: true,
                at: start + 300_000_000,
                directContact: true
            )
        )

        _ = gate.observeVoiceActivity(
            active: false,
            at: start + 600_000_000,
            directContact: true
        )
        XCTAssertEqual(
            gate.observeVoiceActivity(
                active: true,
                at: start + 900_000_000,
                directContact: true
            ),
            .voiceActivity
        )
    }

    func testOneSpeechEpisodeEmitsAtMostOneAuthorization() {
        let start: UInt64 = 1_000_000_000
        var gate = ConversationContactGate()

        XCTAssertEqual(
            gate.observeVoiceActivity(active: true, at: start, directContact: true),
            .voiceActivity
        )
        XCTAssertNil(
            gate.observeVoiceActivity(
                active: true,
                at: start + 260_000_000,
                directContact: true
            )
        )
    }

    func testWeakSingleVADWindowCannotOpenNewConversation() {
        let start: UInt64 = 1_000_000_000
        var gate = ConversationContactGate()

        XCTAssertNil(gate.observeVoiceActivity(
            active: true,
            at: start,
            directContact: true,
            voiceConfidence: 0.374
        ))
        XCTAssertNil(gate.observeVoiceActivity(
            active: true,
            at: start + 260_000_000,
            directContact: true,
            voiceConfidence: 0.08
        ))
        XCTAssertNil(gate.observeVoiceActivity(
            active: false,
            at: start + 520_000_000,
            directContact: true,
            voiceConfidence: 0
        ))
    }

    func testSustainedModerateVoiceEvidenceOpensWithContinuousDirectContact() {
        let start: UInt64 = 1_000_000_000
        var gate = ConversationContactGate()

        XCTAssertNil(gate.observeVoiceActivity(
            active: true,
            at: start,
            directContact: true,
            voiceConfidence: 0.42
        ))
        XCTAssertEqual(gate.observeVoiceActivity(
            active: true,
            at: start + 260_000_000,
            directContact: true,
            voiceConfidence: 0.44
        ), .voiceActivity)
    }

    func testStrongVoiceEvidenceOpensImmediatelyButCannotSubstituteForGaze() {
        let start: UInt64 = 1_000_000_000
        var admitted = ConversationContactGate()
        XCTAssertEqual(admitted.observeVoiceActivity(
            active: true,
            at: start,
            directContact: true,
            voiceConfidence: 0.85
        ), .voiceActivity)

        var rejected = ConversationContactGate()
        XCTAssertNil(rejected.observeVoiceActivity(
            active: true,
            at: start,
            directContact: false,
            voiceConfidence: 0.85
        ))
        XCTAssertNil(rejected.observeVoiceActivity(
            active: true,
            at: start + 260_000_000,
            directContact: true,
            voiceConfidence: 0.90
        ))
    }

    func testAvertedGazeBreaksPendingModerateVoiceAdmission() {
        let start: UInt64 = 1_000_000_000
        var gate = ConversationContactGate()

        XCTAssertNil(gate.observeVoiceActivity(
            active: true,
            at: start,
            directContact: true,
            voiceConfidence: 0.42
        ))
        XCTAssertNil(gate.observeVoiceActivity(
            active: true,
            at: start + 260_000_000,
            directContact: false,
            voiceConfidence: 0.44
        ))
        XCTAssertNil(gate.observeVoiceActivity(
            active: true,
            at: start + 520_000_000,
            directContact: true,
            voiceConfidence: 0.90
        ))
    }

    func testCurrentVerifiedFaceFixationRequiresDirectGazeAndExpires() {
        let start: UInt64 = 2_000_000_000
        var fixation = L0FaceFixationAdmission(freshnessMilliseconds: 500)

        fixation.observeVerifiedFixation(
            sceneID: "face-a",
            directContact: false,
            at: start
        )
        XCTAssertEqual(fixation.state(at: start), .averted)
        XCTAssertFalse(fixation.permitsNewSession(at: start))

        fixation.observeVerifiedFixation(
            sceneID: "face-a",
            directContact: true,
            at: start + 100_000_000
        )
        XCTAssertEqual(fixation.state(at: start + 100_000_000), .direct)
        XCTAssertTrue(fixation.permitsNewSession(at: start + 599_000_000))
        XCTAssertEqual(fixation.state(at: start + 601_000_000), .absent)
        XCTAssertFalse(fixation.permitsNewSession(at: start + 601_000_000))
    }

    func testNewLiveConversationRequiresCurrentVerifiedHumanTarget() {
        let anchoredModel = PredictiveWorldModel()
        let anchored = anchoredModel.ingestVisual(
            VisualObservation(
                rect: NormalizedRect(x: 0.40, y: 0.25, width: 0.20, height: 0.30),
                confidence: 0.90,
                source: .neuralFaceDetector,
                kind: .human,
                label: "face",
                isActionEligible: true
            ),
            at: 1_000_000_000
        )
        XCTAssertTrue(LiveConversationVisualAdmission.permitsNewSession(for: anchored))

        let unanchoredModel = PredictiveWorldModel()
        let unanchored = unanchoredModel.ingestVisual(
            VisualObservation(
                rect: NormalizedRect(x: 0.40, y: 0.25, width: 0.20, height: 0.30),
                confidence: 0.90,
                source: .neuralDetector,
                kind: .object,
                label: "bicycle",
                isActionEligible: false
            ),
            at: 1_000_000_000
        )
        XCTAssertFalse(LiveConversationVisualAdmission.permitsNewSession(for: unanchored))
    }

    func testOpenedConversationAllowsFollowUpsUntilInactivityExpiry() {
        let start: UInt64 = 2_000_000_000
        var gate = ConversationContactGate(configuration: .init(
            conversationInactivityMilliseconds: 60_000
        ))
        gate.markConversationOpened(at: start)
        XCTAssertEqual(
            gate.observeVoiceActivity(
                active: true,
                at: start + 59_999_000_000,
                directContact: false
            ),
            .activeConversation
        )
        _ = gate.observeVoiceActivity(
            active: false,
            at: start + 59_999_500_000,
            directContact: false
        )
        XCTAssertEqual(
            gate.observeVoiceActivity(
                active: true,
                at: start + 60_000_000_000,
                directContact: true
            ),
            .voiceActivity
        )
    }

    func testConversationLeaseOnlyRenewsForConfirmedUserActivity() {
        let start: UInt64 = 3_000_000_000
        var gate = ConversationContactGate(configuration: .init(
            conversationInactivityMilliseconds: 60_000
        ))
        gate.markConversationOpened(at: start)

        // Speech transport/VAD may contain room noise or output echo. Without
        // an explicit confirmed user turn, the lease must expire on schedule.
        XCTAssertNil(
            gate.observeVoiceActivity(
                active: true,
                at: start + 60_000_000_000,
                directContact: false
            )
        )
        _ = gate.observeVoiceActivity(
            active: false,
            at: start + 60_000_000_001,
            directContact: false
        )

        gate.markConversationOpened(at: start)
        gate.recordConversationActivity(at: start + 59_000_000_000)
        XCTAssertEqual(
            gate.observeVoiceActivity(
                active: true,
                at: start + 118_000_000_000,
                directContact: false
            ),
            .activeConversation
        )
        _ = gate.observeVoiceActivity(
            active: false,
            at: start + 118_500_000_000,
            directContact: false
        )
        XCTAssertNil(
            gate.observeVoiceActivity(
                active: true,
                at: start + 119_000_000_000,
                directContact: false
            )
        )
    }

    func testLiveVoiceSessionClosesAfterOneMinuteWithoutUserActivity() {
        let start: UInt64 = 1_000_000_000
        var gate = LiveVoiceSessionInactivityGate()
        let initialDeadline = gate.activate(at: start)
        XCTAssertFalse(gate.shouldClose(at: initialDeadline - 1))
        XCTAssertTrue(gate.shouldClose(at: initialDeadline))

        let renewedDeadline = gate.recordUserActivity(at: initialDeadline - 1)
        XCTAssertEqual(renewedDeadline, initialDeadline + 59_999_999_999)
        XCTAssertFalse(gate.shouldClose(at: renewedDeadline! - 1))
        XCTAssertTrue(gate.shouldClose(at: renewedDeadline!))
    }

    func testLiveVoiceSessionUsesConfiguredSilenceTimeout() {
        let start: UInt64 = 1_000_000_000
        var gate = LiveVoiceSessionInactivityGate(timeoutMilliseconds: 120_000)
        let deadline = gate.activate(at: start)

        XCTAssertEqual(deadline, start + 120_000_000_000)
        XCTAssertFalse(gate.shouldClose(at: deadline - 1))
        XCTAssertTrue(gate.shouldClose(at: deadline))
    }

    func testLiveVoiceInputLevelerBoostsOnlyVADAdmittedQuietSpeech() {
        var leveler = LiveVoiceInputLeveler()
        let quietSpeech = (0..<960).map { index in
            Float(sin(Double(index) * 0.12)) * 0.002
        }

        let inactive = leveler.process(quietSpeech)
        XCTAssertEqual(inactive.samples, quietSpeech)
        XCTAssertEqual(inactive.appliedGainDB, 0, accuracy: 0.001)

        leveler.observeVoiceActivity(true)
        let active = leveler.process(quietSpeech)
        XCTAssertGreaterThan(active.appliedGainDB, 15)
        XCTAssertGreaterThan(
            active.samples.map { abs($0) }.max() ?? 0,
            quietSpeech.map { abs($0) }.max() ?? 0
        )
        XCTAssertLessThanOrEqual(active.samples.map { abs($0) }.max() ?? 0, 0.98)

        leveler.observeVoiceActivity(false)
        let background = leveler.process(quietSpeech)
        XCTAssertEqual(background.samples, quietSpeech)
        XCTAssertEqual(background.appliedGainDB, 0, accuracy: 0.001)
    }

    func testLiveVoiceInputLevelerLimitsSuddenLoudSpeech() {
        var leveler = LiveVoiceInputLeveler()
        leveler.observeVoiceActivity(true)
        _ = leveler.process(Array(repeating: 0.001, count: 960))
        let loud = leveler.process([0.95, -0.95, 0.8, -0.8])
        XCTAssertLessThanOrEqual(loud.samples.map { abs($0) }.max() ?? 0, 0.98)
    }

    func testAudioVisualSpeakerAttributionRejectsStableMouthBackgroundSound() {
        let assessment = AudioVisualSpeakerAttribution.assess(.init(
            faceVisible: true,
            directGaze: true,
            mouthMotion: 0,
            mouthSampleCount: 6,
            directionMatchesFace: false,
            voiceConfidence: 0.9
        ))
        XCTAssertEqual(assessment.classification, .likelyBackground)
        XCTAssertFalse(assessment.admitsAudio)
    }

    func testAudioVisualSpeakerAttributionAdmitsCorrelatedSpeakerAndPreservesAmbiguity() {
        let speaker = AudioVisualSpeakerAttribution.assess(.init(
            faceVisible: true,
            directGaze: true,
            mouthMotion: 0.85,
            mouthSampleCount: 6,
            directionMatchesFace: true,
            voiceConfidence: 0.8
        ))
        XCTAssertEqual(speaker.classification, .likelySpeaker)
        XCTAssertTrue(speaker.admitsAudio)

        let offscreen = AudioVisualSpeakerAttribution.assess(.init(
            faceVisible: false,
            directGaze: false,
            mouthMotion: nil,
            mouthSampleCount: 0,
            directionMatchesFace: nil,
            voiceConfidence: 0.8
        ))
        XCTAssertEqual(offscreen.classification, .ambiguous)
        XCTAssertTrue(offscreen.admitsAudio)

        let visuallyStillWithoutDirection = AudioVisualSpeakerAttribution.assess(.init(
            faceVisible: true,
            directGaze: true,
            mouthMotion: 0.0,
            mouthSampleCount: 8,
            directionMatchesFace: nil,
            voiceConfidence: 0.85
        ))
        XCTAssertEqual(visuallyStillWithoutDirection.classification, .ambiguous)
        XCTAssertTrue(visuallyStillWithoutDirection.admitsAudio)

        let gazeAndVoiceOnly = AudioVisualSpeakerAttribution.assess(.init(
            faceVisible: true,
            directGaze: true,
            mouthMotion: nil,
            mouthSampleCount: 1,
            directionMatchesFace: nil,
            voiceConfidence: 1
        ))
        XCTAssertEqual(gazeAndVoiceOnly.classification, .ambiguous)
    }

    func testAudioVisualCorroborationIsBoundToCurrentVoiceEpisode() {
        XCTAssertEqual(AudioVisualEpisodeEvidence.resolvedOnset(
            classifiedWindowStartNS: 1_000,
            classifiedWindowEndNS: 1_260,
            acousticOnsetNS: 1_200
        ), 1_200)
        XCTAssertEqual(AudioVisualEpisodeEvidence.resolvedOnset(
            classifiedWindowStartNS: 1_000,
            classifiedWindowEndNS: 1_260,
            acousticOnsetNS: 1_300
        ), 1_000)
        XCTAssertEqual(AudioVisualEpisodeEvidence.resolvedOnset(
            classifiedWindowStartNS: 1_260,
            classifiedWindowEndNS: 1_520,
            acousticOnsetNS: 1_210,
            earliestAllowedNS: 1_000
        ), 1_210)
        XCTAssertEqual(AudioVisualEpisodeEvidence.resolvedOnset(
            classifiedWindowStartNS: 1_260,
            classifiedWindowEndNS: 1_520,
            acousticOnsetNS: nil,
            earliestAllowedNS: 1_300
        ), 1_300)
        XCTAssertFalse(AudioVisualEpisodeEvidence.belongsToCurrentEpisode(
            observedNS: 900,
            onsetNS: 1_000,
            nowNS: 1_200,
            maximumAgeNS: 500
        ))
        XCTAssertTrue(AudioVisualEpisodeEvidence.belongsToCurrentEpisode(
            observedNS: 1_050,
            onsetNS: 1_000,
            nowNS: 1_200,
            maximumAgeNS: 500
        ))
        XCTAssertNil(AudioVisualEpisodeEvidence.mouthMotion(
            baseline: 0.01,
            postOnsetApertures: [0.08]
        ))
        XCTAssertGreaterThan(
            AudioVisualEpisodeEvidence.mouthMotion(
                baseline: 0.01,
                postOnsetApertures: [0.04, 0.09]
            ) ?? 0,
            0.9
        )
    }

    func testSpeakerEpisodeCombinesContactAndLaterSpeakerEvidenceForSameFace() {
        var gate = audiovisualEpisodeGate(maximumResolutionMilliseconds: 750)
        let onset = gate.observe(
            active: true,
            trackedFaceID: "face-a",
            evidence: .init(
                faceVisible: true,
                directGaze: true,
                mouthMotion: nil,
                mouthSampleCount: 1,
                directionMatchesFace: nil,
                voiceConfidence: 0.8
            ),
            assessment: .init(classification: .ambiguous, probability: 0.57),
            at: 1_000_000_000
        )
        XCTAssertEqual(onset.state, .pending)
        XCTAssertTrue(onset.directContactObserved)
        XCTAssertFalse(onset.speakerEvidenceObserved)

        let confirmed = gate.observe(
            active: true,
            trackedFaceID: "face-a",
            evidence: .init(
                faceVisible: true,
                directGaze: false,
                mouthMotion: 0.9,
                mouthSampleCount: 6,
                directionMatchesFace: true,
                voiceConfidence: 0.72
            ),
            assessment: .init(classification: .likelySpeaker, probability: 0.86),
            at: 1_300_000_000
        )
        XCTAssertEqual(confirmed.state, .confirmed)
        XCTAssertTrue(confirmed.didTransition)
        XCTAssertTrue(confirmed.directContactObserved)
        XCTAssertTrue(confirmed.speakerEvidenceObserved)
        XCTAssertEqual(confirmed.maximumVoiceConfidence, 0.8, accuracy: 0.0001)
    }

    func testOpeningSpeechEvidenceRejectsObservedFalseActivationConfidenceBand() {
        var evidence = LiveVoiceOpeningSpeechAccumulator()
        let start: UInt64 = 1_000_000_000

        XCTAssertFalse(evidence.observe(
            active: true,
            confidence: 0.558,
            at: start
        ).qualified)
        XCTAssertFalse(evidence.observe(
            active: true,
            confidence: 0.651,
            at: start + 260_000_000
        ).qualified)
        XCTAssertFalse(evidence.observe(
            active: true,
            confidence: 0.651,
            at: start + 520_000_000
        ).qualified)
        XCTAssertEqual(evidence.snapshot.supportingWindowCount, 0)
    }

    func testOpeningSpeechEvidenceRequiresTemporalSupportAndResetsAtOffset() {
        var evidence = LiveVoiceOpeningSpeechAccumulator()
        let start: UInt64 = 2_000_000_000

        XCTAssertFalse(evidence.observe(
            active: true,
            confidence: 0.84,
            at: start
        ).qualified)
        let repeatedTimestamp = evidence.observe(
            active: true,
            confidence: 0.91,
            at: start
        )
        XCTAssertFalse(repeatedTimestamp.qualified)
        XCTAssertEqual(repeatedTimestamp.strongWindowCount, 1)
        XCTAssertTrue(evidence.observe(
            active: true,
            confidence: 0.86,
            at: start + 260_000_000
        ).qualified)

        XCTAssertFalse(evidence.observe(
            active: false,
            confidence: 0,
            at: start + 520_000_000
        ).qualified)
        XCTAssertFalse(evidence.observe(
            active: true,
            confidence: 0.72,
            at: start + 780_000_000
        ).qualified)
        XCTAssertFalse(evidence.observe(
            active: true,
            confidence: 0.74,
            at: start + 1_040_000_000
        ).qualified)
        XCTAssertTrue(evidence.observe(
            active: true,
            confidence: 0.70,
            at: start + 1_300_000_000
        ).qualified)
    }

    func testSpeakerEpisodeCannotConfirmFromIncidentalMouthMotionAndWeakVAD() {
        var gate = LiveVoiceSpeakerEpisodeGate()
        let start: UInt64 = 3_000_000_000
        let first = gate.observe(
            active: true,
            trackedFaceID: "face-a",
            evidence: .init(
                faceVisible: true,
                directGaze: true,
                mouthMotion: nil,
                mouthSampleCount: 1,
                directionMatchesFace: nil,
                voiceConfidence: 0.558
            ),
            assessment: .init(classification: .ambiguous, probability: 0.534),
            directContactObservedNS: start - 20_000_000,
            episodeOnsetNS: start,
            at: start
        )
        XCTAssertEqual(first.state, .pending)

        let incidentalMotion = gate.observe(
            active: true,
            trackedFaceID: "face-a",
            evidence: .init(
                faceVisible: true,
                directGaze: true,
                mouthMotion: 0.821,
                mouthSampleCount: 4,
                directionMatchesFace: nil,
                voiceConfidence: 0.651
            ),
            assessment: .init(classification: .likelySpeaker, probability: 0.769),
            speakerEvidenceObservedNS: start + 260_000_000,
            at: start + 260_000_000
        )
        XCTAssertEqual(incidentalMotion.state, .pending)
        XCTAssertTrue(incidentalMotion.speakerEvidenceObserved)
        XCTAssertFalse(incidentalMotion.speechEvidence.qualified)
    }

    func testSpeakerEpisodeConfirmsAfterRepeatedStrongSpeechEvidence() {
        var gate = LiveVoiceSpeakerEpisodeGate()
        let start: UInt64 = 4_000_000_000
        XCTAssertEqual(gate.observe(
            active: true,
            trackedFaceID: "face-a",
            evidence: .init(
                faceVisible: true,
                directGaze: true,
                mouthMotion: 0.7,
                mouthSampleCount: 4,
                directionMatchesFace: nil,
                voiceConfidence: 0.84
            ),
            assessment: .init(classification: .likelySpeaker, probability: 0.8),
            directContactObservedNS: start - 20_000_000,
            speakerEvidenceObservedNS: start,
            episodeOnsetNS: start,
            at: start
        ).state, .pending)

        let confirmed = gate.observe(
            active: true,
            trackedFaceID: "face-a",
            evidence: .init(
                faceVisible: true,
                directGaze: true,
                mouthMotion: 0.8,
                mouthSampleCount: 6,
                directionMatchesFace: nil,
                voiceConfidence: 0.86
            ),
            assessment: .init(classification: .likelySpeaker, probability: 0.84),
            speakerEvidenceObservedNS: start + 260_000_000,
            at: start + 260_000_000
        )
        XCTAssertEqual(confirmed.state, .confirmed)
        XCTAssertTrue(confirmed.speechEvidence.qualified)
        XCTAssertEqual(confirmed.speechEvidence.strongWindowCount, 2)
    }

    func testSpeakerEpisodeUsesAudioWindowTimeAcrossDelayedCallbacks() {
        var gate = LiveVoiceSpeakerEpisodeGate()
        let onset: UInt64 = 5_000_000_000
        XCTAssertEqual(gate.observe(
            active: true,
            trackedFaceID: "face-a",
            evidence: .init(
                faceVisible: true,
                directGaze: true,
                mouthMotion: 0.7,
                mouthSampleCount: 4,
                directionMatchesFace: nil,
                voiceConfidence: 0.84
            ),
            assessment: .init(classification: .likelySpeaker, probability: 0.8),
            directContactObservedNS: onset - 20_000_000,
            speakerEvidenceObservedNS: onset,
            voiceWindowObservedNS: onset,
            episodeOnsetNS: onset,
            at: onset + 700_000_000
        ).state, .pending)

        let confirmed = gate.observe(
            active: true,
            trackedFaceID: "face-a",
            evidence: .init(
                faceVisible: true,
                directGaze: true,
                mouthMotion: 0.8,
                mouthSampleCount: 6,
                directionMatchesFace: nil,
                voiceConfidence: 0.86
            ),
            assessment: .init(classification: .likelySpeaker, probability: 0.84),
            speakerEvidenceObservedNS: onset + 260_000_000,
            voiceWindowObservedNS: onset + 260_000_000,
            at: onset + 1_900_000_000
        )
        XCTAssertEqual(confirmed.state, .confirmed)
        XCTAssertTrue(confirmed.speechEvidence.qualified)
    }

    func testSpeakerEpisodeDoesNotAcquireContactAfterAcousticOnset() {
        var lateGaze = audiovisualEpisodeGate()
        XCTAssertEqual(lateGaze.observe(
            active: true,
            trackedFaceID: "face-a",
            evidence: .init(
                faceVisible: true,
                directGaze: false,
                mouthMotion: nil,
                mouthSampleCount: 1,
                directionMatchesFace: nil,
                voiceConfidence: 0.8
            ),
            assessment: .init(classification: .ambiguous, probability: 0.45),
            at: 2_000_000_000
        ).state, .pending)
        let speakerFirst = lateGaze.observe(
            active: true,
            trackedFaceID: "face-a",
            evidence: .init(
                faceVisible: true,
                directGaze: false,
                mouthMotion: 1,
                mouthSampleCount: 6,
                directionMatchesFace: true,
                voiceConfidence: 0.9
            ),
            assessment: .init(classification: .likelySpeaker, probability: 0.75),
            at: 2_200_000_000
        )
        XCTAssertEqual(speakerFirst.state, .pending)
        XCTAssertFalse(speakerFirst.directContactObserved)
        XCTAssertTrue(speakerFirst.speakerEvidenceObserved)
        let contactLater = lateGaze.observe(
            active: true,
            trackedFaceID: "face-a",
            evidence: .init(
                faceVisible: true,
                directGaze: true,
                mouthMotion: 1,
                mouthSampleCount: 6,
                directionMatchesFace: true,
                voiceConfidence: 0.9
            ),
            assessment: .init(classification: .ambiguous, probability: 0.57),
            at: 2_700_000_000
        )
        XCTAssertEqual(contactLater.state, .pending)
        XCTAssertFalse(contactLater.directContactObserved)
        XCTAssertTrue(contactLater.speakerEvidenceObserved)
    }

    func testSpeakerEpisodeAcceptsDelayedDeliveryOfPreOnsetContact() {
        var gate = audiovisualEpisodeGate(maximumResolutionMilliseconds: 3_000)
        XCTAssertEqual(gate.observe(
            active: true,
            trackedFaceID: "face-a",
            evidence: .init(
                faceVisible: true,
                directGaze: false,
                mouthMotion: 0.9,
                mouthSampleCount: 6,
                directionMatchesFace: true,
                voiceConfidence: 0.9
            ),
            assessment: .init(classification: .likelySpeaker, probability: 0.9),
            at: 10_000_000_000
        ).state, .pending)
        XCTAssertEqual(gate.observeGaze(
            .direct,
            trackedFaceID: "face-a",
            observedNS: 9_900_000_000,
            at: 12_700_000_000
        ).state, .confirmed)
    }

    func testSpeakerEpisodeWithoutFaceAtOnsetCannotAcquireAnotherPersonLater() {
        var gate = audiovisualEpisodeGate()
        XCTAssertEqual(gate.observe(
            active: true,
            trackedFaceID: nil,
            evidence: .init(
                faceVisible: false,
                directGaze: false,
                mouthMotion: nil,
                mouthSampleCount: 0,
                directionMatchesFace: nil,
                voiceConfidence: 0.9
            ),
            assessment: .init(classification: .ambiguous, probability: 0.45),
            at: 20_000_000_000
        ).state, .rejected)
        XCTAssertEqual(gate.observe(
            active: true,
            trackedFaceID: "face-a",
            evidence: .init(
                faceVisible: true,
                directGaze: true,
                mouthMotion: 1,
                mouthSampleCount: 6,
                directionMatchesFace: true,
                voiceConfidence: 0.9
            ),
            assessment: .init(classification: .likelySpeaker, probability: 1),
            at: 20_500_000_000
        ).state, .rejected)
    }

    func testSpeakerEpisodeDoesNotFuseTemporallyUnrelatedModalities() {
        var gate = audiovisualEpisodeGate(
            maximumResolutionMilliseconds: 3_000,
            maximumEvidenceSkewMilliseconds: 750
        )
        XCTAssertEqual(gate.observe(
            active: true,
            trackedFaceID: "face-a",
            evidence: .init(
                faceVisible: true,
                directGaze: false,
                mouthMotion: 1,
                mouthSampleCount: 5,
                directionMatchesFace: true,
                voiceConfidence: 0.9
            ),
            assessment: .init(classification: .likelySpeaker, probability: 0.75),
            at: 1_000_000_000
        ).state, .pending)
        let unrelatedContact = gate.observe(
            active: true,
            trackedFaceID: "face-a",
            evidence: .init(
                faceVisible: true,
                directGaze: true,
                mouthMotion: 0,
                mouthSampleCount: 6,
                directionMatchesFace: nil,
                voiceConfidence: 0.9
            ),
            assessment: .init(classification: .ambiguous, probability: 0.4),
            at: 2_000_000_000
        )
        XCTAssertEqual(unrelatedContact.state, .pending)
        XCTAssertFalse(unrelatedContact.directContactObserved)
        XCTAssertTrue(unrelatedContact.speakerEvidenceObserved)
    }

    func testSpeakerEpisodeUsesCaptureTimesInsteadOfCallbackTimeForFusion() {
        var gate = audiovisualEpisodeGate(
            maximumResolutionMilliseconds: 3_000,
            maximumEvidenceSkewMilliseconds: 750
        )
        XCTAssertEqual(gate.observe(
            active: true,
            trackedFaceID: "face-a",
            evidence: .init(
                faceVisible: true,
                directGaze: false,
                mouthMotion: 1,
                mouthSampleCount: 5,
                directionMatchesFace: true,
                voiceConfidence: 0.9
            ),
            assessment: .init(classification: .likelySpeaker, probability: 0.75),
            speakerEvidenceObservedNS: 1_000_000_000,
            at: 1_100_000_000
        ).state, .pending)
        XCTAssertEqual(gate.observe(
            active: true,
            trackedFaceID: "face-a",
            evidence: .init(
                faceVisible: true,
                directGaze: true,
                mouthMotion: 0,
                mouthSampleCount: 6,
                directionMatchesFace: nil,
                voiceConfidence: 0.9
            ),
            assessment: .init(classification: .ambiguous, probability: 0.4),
            directContactObservedNS: 2_000_000_000,
            at: 2_050_000_000
        ).state, .pending)
    }

    func testSpeakerEpisodeRejectsFaceSwitchAndExpiredEvidence() {

        var switchedFace = audiovisualEpisodeGate()
        XCTAssertEqual(switchedFace.observe(
            active: true,
            trackedFaceID: "face-a",
            evidence: .init(
                faceVisible: true,
                directGaze: true,
                mouthMotion: nil,
                mouthSampleCount: 1,
                directionMatchesFace: nil,
                voiceConfidence: 0.7
            ),
            assessment: .init(classification: .ambiguous, probability: 0.55),
            at: 3_000_000_000
        ).state, .pending)
        XCTAssertEqual(switchedFace.observe(
            active: true,
            trackedFaceID: "face-b",
            evidence: .init(
                faceVisible: true,
                directGaze: true,
                mouthMotion: 1,
                mouthSampleCount: 6,
                directionMatchesFace: true,
                voiceConfidence: 0.9
            ),
            assessment: .init(classification: .likelySpeaker, probability: 1),
            at: 3_200_000_000
        ).state, .rejected)

        var expired = audiovisualEpisodeGate(maximumResolutionMilliseconds: 750)
        XCTAssertEqual(expired.observe(
            active: true,
            trackedFaceID: "face-a",
            evidence: .init(
                faceVisible: true,
                directGaze: true,
                mouthMotion: nil,
                mouthSampleCount: 1,
                directionMatchesFace: nil,
                voiceConfidence: 0.8
            ),
            assessment: .init(classification: .ambiguous, probability: 0.57),
            at: 4_000_000_000
        ).state, .pending)
        XCTAssertEqual(expired.observe(
            active: true,
            trackedFaceID: "face-a",
            evidence: .init(
                faceVisible: true,
                directGaze: true,
                mouthMotion: 1,
                mouthSampleCount: 8,
                directionMatchesFace: true,
                voiceConfidence: 0.9
            ),
            assessment: .init(classification: .likelySpeaker, probability: 1),
            at: 4_750_000_000
        ).state, .rejected)
    }

    func testSpeakerEpisodeNeverCombinesContactWithoutIndependentSpeakerCue() {
        var gate = audiovisualEpisodeGate(maximumResolutionMilliseconds: 3_000)
        XCTAssertEqual(gate.observe(
            active: true,
            trackedFaceID: "face-a",
            evidence: .init(
                faceVisible: true,
                directGaze: false,
                mouthMotion: nil,
                mouthSampleCount: 0,
                directionMatchesFace: nil,
                voiceConfidence: 0.95
            ),
            assessment: .init(classification: .ambiguous, probability: 0.24),
            at: 5_000_000_000
        ).state, .pending)
        let gazeDuringNoise = gate.observe(
            active: true,
            trackedFaceID: "face-a",
            evidence: .init(
                faceVisible: true,
                directGaze: true,
                mouthMotion: 0,
                mouthSampleCount: 5,
                directionMatchesFace: nil,
                voiceConfidence: 0.95
            ),
            assessment: .init(classification: .ambiguous, probability: 0.35),
            at: 5_600_000_000
        )
        XCTAssertEqual(gazeDuringNoise.state, .pending)
        XCTAssertFalse(gazeDuringNoise.directContactObserved)
        XCTAssertFalse(gazeDuringNoise.speakerEvidenceObserved)
        XCTAssertEqual(gate.observe(
            active: true,
            trackedFaceID: "face-a",
            evidence: .init(
                faceVisible: true,
                directGaze: true,
                mouthMotion: 0,
                mouthSampleCount: 8,
                directionMatchesFace: nil,
                voiceConfidence: 0.95
            ),
            assessment: .init(classification: .ambiguous, probability: 0.35),
            at: 8_000_000_000
        ).state, .rejected)
    }

    func testSpeakerEpisodeDeadlineUsesAcousticOnsetInsteadOfDelayedVADCallback() {
        let evidence = AudioVisualSpeakerEvidence(
            faceVisible: true,
            directGaze: true,
            mouthMotion: 1,
            mouthSampleCount: 6,
            directionMatchesFace: true,
            voiceConfidence: 0.9
        )
        let assessment = AudioVisualSpeakerAssessment(
            classification: .likelySpeaker,
            probability: 0.95
        )

        var timely = audiovisualEpisodeGate(maximumResolutionMilliseconds: 750)
        XCTAssertEqual(timely.observe(
            active: true,
            trackedFaceID: "face-a",
            evidence: evidence,
            assessment: assessment,
            directContactObservedNS: 1_000_000_000,
            episodeOnsetNS: 1_000_000_000,
            at: 1_700_000_000
        ).state, .confirmed)

        var delayed = audiovisualEpisodeGate(maximumResolutionMilliseconds: 750)
        XCTAssertEqual(delayed.observe(
            active: true,
            trackedFaceID: "face-a",
            evidence: evidence,
            assessment: assessment,
            directContactObservedNS: 2_000_000_000,
            episodeOnsetNS: 2_000_000_000,
            at: 2_800_000_000
        ).state, .rejected)
    }

    func testConfirmedSpeakerEpisodeRevokesOnFaceSwitchOrSpatialContradiction() {
        var faceSwitch = audiovisualEpisodeGate()
        let confirmedEvidence = AudioVisualSpeakerEvidence(
            faceVisible: true,
            directGaze: true,
            mouthMotion: 1,
            mouthSampleCount: 4,
            directionMatchesFace: true,
            voiceConfidence: 0.9
        )
        XCTAssertEqual(faceSwitch.observe(
            active: true,
            trackedFaceID: "face-a",
            evidence: confirmedEvidence,
            assessment: .init(classification: .likelySpeaker, probability: 0.95),
            at: 1_000
        ).state, .confirmed)
        XCTAssertEqual(faceSwitch.observe(
            active: true,
            trackedFaceID: "face-b",
            evidence: confirmedEvidence,
            assessment: .init(classification: .likelySpeaker, probability: 0.95),
            at: 1_100
        ).state, .rejected)

        var spatialMismatch = audiovisualEpisodeGate()
        XCTAssertEqual(spatialMismatch.observe(
            active: true,
            trackedFaceID: "face-a",
            evidence: confirmedEvidence,
            assessment: .init(classification: .likelySpeaker, probability: 0.95),
            at: 2_000
        ).state, .confirmed)
        XCTAssertEqual(spatialMismatch.observe(
            active: true,
            trackedFaceID: "face-a",
            evidence: .init(
                faceVisible: true,
                directGaze: true,
                mouthMotion: 0,
                mouthSampleCount: 4,
                directionMatchesFace: false,
                voiceConfidence: 0.9
            ),
            assessment: .init(classification: .likelyBackground, probability: 0.2),
            at: 2_100
        ).state, .rejected)
    }

    func testNewerAvertedGazeInvalidatesContactBeforeSpeakerConfirmation() {
        var gate = audiovisualEpisodeGate()
        XCTAssertEqual(gate.observe(
            active: true,
            trackedFaceID: "face-a",
            evidence: .init(
                faceVisible: true,
                directGaze: true,
                mouthMotion: nil,
                mouthSampleCount: 1,
                directionMatchesFace: nil,
                voiceConfidence: 0.8
            ),
            assessment: .init(classification: .ambiguous, probability: 0.55),
            directContactObservedNS: 1_000_000_000,
            at: 1_050_000_000
        ).state, .pending)

        let averted = gate.observeGaze(
            .averted,
            trackedFaceID: "face-a",
            observedNS: 1_100_000_000,
            at: 1_150_000_000
        )
        XCTAssertEqual(averted.state, .pending)
        XCTAssertFalse(averted.directContactObserved)

        let speaker = gate.observe(
            active: true,
            trackedFaceID: "face-a",
            evidence: .init(
                faceVisible: true,
                directGaze: false,
                mouthMotion: 1,
                mouthSampleCount: 6,
                directionMatchesFace: true,
                voiceConfidence: 0.9
            ),
            assessment: .init(classification: .likelySpeaker, probability: 0.8),
            speakerEvidenceObservedNS: 1_200_000_000,
            at: 1_250_000_000
        )
        XCTAssertEqual(speaker.state, .pending)
        XCTAssertFalse(speaker.directContactObserved)
        XCTAssertTrue(speaker.speakerEvidenceObserved)
    }

    func testDelayedPreConfirmationAversionRevokesButLaterLookAwayDoesNot() {
        let evidence = AudioVisualSpeakerEvidence(
            faceVisible: true,
            directGaze: true,
            mouthMotion: 1,
            mouthSampleCount: 5,
            directionMatchesFace: true,
            voiceConfidence: 0.9
        )
        let assessment = AudioVisualSpeakerAssessment(
            classification: .likelySpeaker,
            probability: 0.95
        )

        var delayedContradiction = audiovisualEpisodeGate()
        XCTAssertEqual(delayedContradiction.observe(
            active: true,
            trackedFaceID: "face-a",
            evidence: evidence,
            assessment: assessment,
            directContactObservedNS: 2_000_000_000,
            speakerEvidenceObservedNS: 2_100_000_000,
            at: 2_200_000_000
        ).state, .confirmed)
        XCTAssertEqual(delayedContradiction.observeGaze(
            .averted,
            trackedFaceID: "face-a",
            observedNS: 2_150_000_000,
            at: 2_250_000_000
        ).state, .rejected)

        var establishedConversation = audiovisualEpisodeGate()
        XCTAssertEqual(establishedConversation.observe(
            active: true,
            trackedFaceID: "face-a",
            evidence: evidence,
            assessment: assessment,
            directContactObservedNS: 3_000_000_000,
            speakerEvidenceObservedNS: 3_100_000_000,
            at: 3_200_000_000
        ).state, .confirmed)
        XCTAssertEqual(establishedConversation.observeGaze(
            .averted,
            trackedFaceID: "face-a",
            observedNS: 3_250_000_000,
            at: 3_300_000_000
        ).state, .confirmed)
    }

    func testStrictLiveVoiceAudioRoutingRequiresCurrentTurnAdmission() {
        XCTAssertFalse(LiveVoiceAudioRoutingPolicy.forwards(
            sessionActive: true,
            requiresVerifiedSpeakerForEveryTurn: true,
            currentTurnAdmitted: false
        ))
        XCTAssertTrue(LiveVoiceAudioRoutingPolicy.forwards(
            sessionActive: true,
            requiresVerifiedSpeakerForEveryTurn: true,
            currentTurnAdmitted: true
        ))
        XCTAssertTrue(LiveVoiceAudioRoutingPolicy.forwards(
            sessionActive: true,
            requiresVerifiedSpeakerForEveryTurn: false,
            currentTurnAdmitted: false
        ))

        var episodeAudio = LiveVoiceTimestampedEpisodeBuffer<String>(
            detectorHistoryNS: 500,
            maximumEpisodeDurationNS: 700
        )
        episodeAudio.ingest("ambient-before-first-onset", captureNS: 100, durationNS: 100)
        episodeAudio.ingest("rejected-onset", captureNS: 200, durationNS: 100)
        episodeAudio.begin(at: 200)
        episodeAudio.ingest("rejected-tail", captureNS: 300, durationNS: 100)
        episodeAudio.end()
        episodeAudio.ingest("ambient-between-episodes", captureNS: 400, durationNS: 100)
        episodeAudio.ingest("confirmed-onset", captureNS: 500, durationNS: 100)
        episodeAudio.begin(at: 500)
        episodeAudio.ingest("confirmed-tail", captureNS: 600, durationNS: 100)
        XCTAssertEqual(episodeAudio.take(), ["confirmed-onset", "confirmed-tail"])
    }

    func testDuplexCaptureGateQuarantinesPlaybackAndTail() {
        var gate = LiveVoiceDuplexCaptureGate(trailingSuppressionMilliseconds: 500)
        XCTAssertFalse(gate.quarantinesMicrophone(at: 1_000_000_000))
        gate.beginAssistantOutput(at: 1_000_000_000)
        XCTAssertTrue(gate.quarantinesMicrophone(at: 1_100_000_000))
        gate.endAssistantOutput(at: 2_000_000_000)
        XCTAssertTrue(gate.quarantinesMicrophone(at: 2_499_999_999))
        XCTAssertFalse(gate.quarantinesMicrophone(at: 2_500_000_000))
    }

    func testVerifiedBargeInOverridesPlaybackOnlyForCurrentSpeechEpisode() {
        var gate = LiveVoiceDuplexCaptureGate()
        gate.beginAssistantOutput(at: 1_000_000_000)
        gate.observeParticipantSpeech(active: true, verified: false, at: 1_100_000_000)
        XCTAssertTrue(gate.quarantinesMicrophone(at: 1_100_000_000))
        gate.observeParticipantSpeech(active: true, verified: true, at: 1_200_000_000)
        XCTAssertFalse(gate.quarantinesMicrophone(at: 1_200_000_000))
        gate.observeParticipantSpeech(active: true, verified: false, at: 1_300_000_000)
        XCTAssertFalse(gate.quarantinesMicrophone(at: 1_300_000_000))
        gate.observeParticipantSpeech(active: false, verified: false, at: 1_400_000_000)
        XCTAssertTrue(gate.quarantinesMicrophone(at: 1_400_000_000))
    }

    func testVerifiedStrictBargeInRemainsReleasedWhilePlaybackIsStillActive() {
        var gate = LiveVoiceDuplexCaptureGate()
        gate.beginAssistantOutput(at: 1_000_000_000)
        gate.observeParticipantSpeech(active: true, verified: true, at: 1_100_000_000)

        XCTAssertTrue(gate.requiresParticipantVerification(at: 1_200_000_000))
        XCTAssertFalse(gate.quarantinesMicrophone(at: 1_200_000_000))
        XCTAssertTrue(LiveVoiceAudioRoutingPolicy.forwards(
            sessionActive: true,
            requiresVerifiedSpeakerForEveryTurn: true,
            currentTurnAdmitted: true
        ))

        gate.observeParticipantSpeech(active: true, verified: false, at: 1_400_000_000)
        XCTAssertFalse(gate.quarantinesMicrophone(at: 1_400_000_000))
        gate.observeParticipantSpeech(active: false, verified: false, at: 1_600_000_000)
        XCTAssertTrue(gate.quarantinesMicrophone(at: 1_600_000_000))
    }

    func testUnverifiedPlaybackEpisodeRemainsQuarantinedBeyondTrailingTimer() {
        var gate = LiveVoiceDuplexCaptureGate(trailingSuppressionMilliseconds: 500)
        gate.beginAssistantOutput(at: 1_000_000_000)
        gate.observeParticipantSpeech(active: true, verified: false, at: 1_100_000_000)
        gate.endAssistantOutput(at: 2_000_000_000)

        XCTAssertTrue(gate.quarantinesMicrophone(at: 2_700_000_000))
        XCTAssertTrue(gate.requiresParticipantVerification(at: 2_700_000_000))

        gate.observeParticipantSpeech(active: false, verified: false, at: 2_800_000_000)
        XCTAssertFalse(gate.quarantinesMicrophone(at: 2_800_000_000))
    }

    func testDuplexSpeakerVerificationMakesDirectGazeOptionalByPolicy() {
        XCTAssertTrue(LiveVoiceDuplexSpeakerPolicy.verifiesParticipant(
            trackedFaceVisible: true,
            independentSpeakerEvidence: true,
            speechEvidenceQualified: true,
            directContactConfirmed: false,
            speakerAttributionRejected: false,
            requiresDirectGaze: false
        ))
        XCTAssertFalse(LiveVoiceDuplexSpeakerPolicy.verifiesParticipant(
            trackedFaceVisible: true,
            independentSpeakerEvidence: true,
            speechEvidenceQualified: true,
            directContactConfirmed: false,
            speakerAttributionRejected: false,
            requiresDirectGaze: true
        ))
        XCTAssertFalse(LiveVoiceDuplexSpeakerPolicy.verifiesParticipant(
            trackedFaceVisible: true,
            independentSpeakerEvidence: false,
            speechEvidenceQualified: true,
            directContactConfirmed: true,
            speakerAttributionRejected: false,
            requiresDirectGaze: false
        ))
        XCTAssertFalse(LiveVoiceDuplexSpeakerPolicy.verifiesParticipant(
            trackedFaceVisible: true,
            independentSpeakerEvidence: true,
            speechEvidenceQualified: true,
            directContactConfirmed: true,
            speakerAttributionRejected: true,
            requiresDirectGaze: false
        ))
    }

    func testPlaybackReferenceIdentifiesDelayedGainChangedEcho() {
        var matcher = LiveVoiceEchoReferenceMatcher()
        let reference = deterministicAudio(count: 24_000, seed: 0xA11CE)
        matcher.appendReference(reference, sampleRate: 16_000)
        let microphone = reference[8_000..<16_000].map { $0 * -0.34 }
        matcher.appendMicrophone(Array(microphone), sampleRate: 16_000)

        let assessment = matcher.assess()
        XCTAssertEqual(assessment.relationship, .echoDominated)
        XCTAssertGreaterThan(assessment.maximumCorrelation, 0.9)
        XCTAssertFalse(assessment.permitsBargeIn)
    }

    func testPlaybackReferenceAllowsAcousticallyIndependentInterruptionWithoutGaze() {
        var matcher = LiveVoiceEchoReferenceMatcher()
        matcher.appendReference(
            deterministicAudio(count: 24_000, seed: 0xA11CE),
            sampleRate: 16_000
        )
        matcher.appendMicrophone(
            deterministicAudio(count: 8_000, seed: 0xBADC0DE),
            sampleRate: 16_000
        )

        let assessment = matcher.assess()
        XCTAssertEqual(assessment.relationship, .acousticallyIndependent)
        XCTAssertLessThan(assessment.maximumCorrelation, 0.2)
        XCTAssertTrue(assessment.permitsBargeIn)
        XCTAssertTrue(LiveVoiceDuplexSpeakerPolicy.verifiesParticipant(
            trackedFaceVisible: true,
            independentSpeakerEvidence: true,
            speechEvidenceQualified: true,
            directContactConfirmed: false,
            speakerAttributionRejected: false,
            requiresDirectGaze: false
        ))
    }

    func testPlaybackReferenceFailsClosedUntilEnoughAudioExists() {
        var matcher = LiveVoiceEchoReferenceMatcher()
        matcher.appendReference([Float](repeating: 0.1, count: 200), sampleRate: 8_000)
        matcher.appendMicrophone([Float](repeating: 0.1, count: 200), sampleRate: 8_000)

        let assessment = matcher.assess()
        XCTAssertEqual(assessment.relationship, .insufficientEvidence)
        XCTAssertFalse(assessment.permitsBargeIn)
    }

    func testRenderedPlaybackReferencePreemptsAndPermanentlyRejectsUpstreamAudio() {
        var arbiter = LiveVoicePlaybackReferenceArbiter()

        XCTAssertEqual(
            arbiter.observe(.appServer),
            .init(accepted: true, resetsReference: false)
        )
        XCTAssertEqual(
            arbiter.observe(.webRTCPlayback),
            .init(accepted: true, resetsReference: true)
        )
        XCTAssertEqual(
            arbiter.observe(.appServer),
            .init(accepted: false, resetsReference: false)
        )
        XCTAssertEqual(
            arbiter.observe(.webRTCPlayback),
            .init(accepted: true, resetsReference: false)
        )
    }

    private func deterministicAudio(count: Int, seed: UInt64) -> [Float] {
        var state = seed
        return (0..<count).map { index in
            state = state &* 6_364_136_223_846_793_005 &+ 1
            let noise = Float(Double((state >> 32) & 0xFFFF) / 32_767.5 - 1)
            let carrier = Float(sin(Double(index) * 0.071) * 0.45)
            return carrier + noise * 0.25
        }
    }

    func testContradictedSpeakerEpisodeCannotReleaseDuplexCapture() {
        var episode = audiovisualEpisodeGate()
        let initial = episode.observe(
            active: true,
            trackedFaceID: "face-a",
            evidence: .init(
                faceVisible: true,
                directGaze: true,
                mouthMotion: 0.8,
                mouthSampleCount: 4,
                directionMatchesFace: true,
                voiceConfidence: 0.9
            ),
            assessment: .init(classification: .likelySpeaker, probability: 0.95),
            at: 1_000_000_000
        )
        XCTAssertEqual(initial.state, .confirmed)

        let contradicted = episode.observe(
            active: true,
            trackedFaceID: "face-a",
            evidence: .init(
                faceVisible: true,
                directGaze: false,
                mouthMotion: 0,
                mouthSampleCount: 4,
                directionMatchesFace: false,
                voiceConfidence: 0.9
            ),
            assessment: .init(classification: .likelyBackground, probability: 0.1),
            at: 1_260_000_000
        )
        XCTAssertEqual(contradicted.state, .rejected)
        XCTAssertTrue(contradicted.speakerEvidenceObserved)
        XCTAssertTrue(contradicted.speechEvidence.qualified)
        XCTAssertFalse(LiveVoiceDuplexSpeakerPolicy.verifiesParticipant(
            trackedFaceVisible: true,
            independentSpeakerEvidence: contradicted.speakerEvidenceObserved,
            speechEvidenceQualified: contradicted.speechEvidence.qualified,
            directContactConfirmed: false,
            speakerAttributionRejected: contradicted.state == .rejected,
            requiresDirectGaze: false
        ))
    }

    func testTimestampedEpisodeBufferPreservesDelayedOnsetExactlyOnceAndStaysBounded() {
        var episodeAudio = LiveVoiceTimestampedEpisodeBuffer<Int>(
            detectorHistoryNS: 1_000,
            maximumEpisodeDurationNS: 1_000
        )
        episodeAudio.ingest(0, captureNS: 900, durationNS: 100)
        episodeAudio.ingest(1, captureNS: 1_000, durationNS: 100)
        episodeAudio.ingest(2, captureNS: 1_100, durationNS: 100)
        episodeAudio.ingest(3, captureNS: 1_200, durationNS: 100)
        episodeAudio.begin(at: 1_000)
        episodeAudio.ingest(4, captureNS: 1_300, durationNS: 100)
        XCTAssertEqual(episodeAudio.take(), [1, 2, 3, 4])

        var bounded = LiveVoiceTimestampedEpisodeBuffer<Int>(
            detectorHistoryNS: 1_000,
            maximumEpisodeDurationNS: 300
        )
        for value in 1...4 {
            bounded.ingest(
                value,
                captureNS: UInt64(900 + value * 100),
                durationNS: 100
            )
        }
        bounded.begin(at: 1_000)
        XCTAssertEqual(bounded.take(), [2, 3, 4])
    }

    func testStrictEpisodeQuarantineReleasesOnlyAssessedAudio() {
        var quarantine = LiveVoiceTimestampedEpisodeBuffer<String>(
            detectorHistoryNS: 1_000,
            maximumEpisodeDurationNS: 2_000
        )
        quarantine.ingest("onset", captureNS: 1_000, durationNS: 100)
        quarantine.begin(at: 1_000)
        quarantine.ingest("verified-window", captureNS: 1_200, durationNS: 200)
        quarantine.ingest("unassessed-mismatch", captureNS: 1_400, durationNS: 200)
        XCTAssertEqual(
            quarantine.take(throughCaptureNS: 1_200),
            ["onset", "verified-window"]
        )
        quarantine.end()
        XCTAssertTrue(quarantine.take().isEmpty)
    }

    func testStrictEpisodeQuarantineSplitsUnalignedAssessmentBoundary() {
        var quarantine = LiveVoiceTimestampedEpisodeBuffer<String>(
            detectorHistoryNS: 1_000,
            maximumEpisodeDurationNS: 2_000
        )
        let splitter: (String, UInt64) -> (prefix: String, suffix: String)? = {
            value, prefixDuration in
            ("\(value)-prefix-\(prefixDuration)", "\(value)-suffix")
        }
        quarantine.ingest("pre-onset", captureNS: 1_000, durationNS: 100)
        quarantine.ingest("onset", captureNS: 1_100, durationNS: 100)
        quarantine.begin(at: 1_000, splitting: splitter)
        quarantine.ingest("crossing", captureNS: 1_300, durationNS: 200)

        XCTAssertEqual(
            quarantine.take(throughCaptureNS: 1_150, splitting: splitter),
            ["onset", "crossing-prefix-50"]
        )
        quarantine.end()
        XCTAssertTrue(quarantine.take().isEmpty)
    }

    func testTimestampedEpisodeBufferCutsPreOnsetPrefixInsideChunk() {
        var audio = LiveVoiceTimestampedEpisodeBuffer<String>(
            detectorHistoryNS: 1_000,
            maximumEpisodeDurationNS: 2_000
        )
        let splitter: (String, UInt64) -> (prefix: String, suffix: String)? = {
            value, prefixDuration in
            ("\(value)-prefix-\(prefixDuration)", "\(value)-suffix")
        }
        audio.ingest("crossing-onset", captureNS: 1_300, durationNS: 300)
        audio.begin(at: 1_120, splitting: splitter)
        XCTAssertEqual(audio.take(), ["crossing-onset-suffix"])
    }

    func testTimestampedEpisodeBufferDropsChunkEndingExactlyAtOnset() {
        var audio = LiveVoiceTimestampedEpisodeBuffer<String>(
            detectorHistoryNS: 1_000,
            maximumEpisodeDurationNS: 2_000
        )
        let splitter: (String, UInt64) -> (prefix: String, suffix: String)? = {
            value, _ in ("\(value)-prefix", "\(value)-suffix")
        }
        audio.ingest("pre-onset", captureNS: 1_000, durationNS: 100)
        audio.ingest("speech", captureNS: 1_100, durationNS: 100)
        audio.begin(at: 1_000, splitting: splitter)
        XCTAssertEqual(audio.take(), ["speech"])
    }

    func testMidWindowAcousticOnsetCutsSilenceWithoutLosingSpeech() {
        let onset = AudioVisualEpisodeEvidence.resolvedOnset(
            classifiedWindowStartNS: 1_000,
            classifiedWindowEndNS: 1_260,
            acousticOnsetNS: 1_200
        )
        var audio = LiveVoiceTimestampedEpisodeBuffer<String>(
            detectorHistoryNS: 1_000,
            maximumEpisodeDurationNS: 2_000
        )
        audio.ingest("window-silence", captureNS: 1_050, durationNS: 50)
        audio.ingest("speech-onset", captureNS: 1_200, durationNS: 50)
        audio.ingest("speech-tail", captureNS: 1_250, durationNS: 50)
        audio.begin(at: onset)
        XCTAssertEqual(
            audio.take(throughCaptureNS: 1_260),
            ["speech-onset", "speech-tail"]
        )
    }

    func testDiscontinuityRolloverPreservesReplacementFrameForNextEpisode() {
        var audio = LiveVoiceTimestampedEpisodeBuffer<String>(
            detectorHistoryNS: 1_000,
            maximumEpisodeDurationNS: 2_000
        )
        audio.ingest("old-episode", captureNS: 100, durationNS: 100)
        audio.begin(at: 100)
        audio.ingest("replacement-frame", captureNS: 300, durationNS: 100)
        audio.end(preservingDetectorHistoryFrom: 300)
        audio.begin(at: 200)
        XCTAssertEqual(audio.take(), ["replacement-frame"])
    }

    func testIndicatorPriorityMakesSocialAndCognitiveStateLegible() {
        var inputs = SubconsciousIndicatorInputs(
            visualState: .none,
            interactionState: .idle
        )
        XCTAssertEqual(inputs.resolvedState, .exploring)
        inputs.visualState = .humanDetected
        XCTAssertEqual(inputs.resolvedState, .humanDetected)
        inputs.visualState = .eyeContact
        XCTAssertEqual(inputs.resolvedState, .contactReady)
        inputs.interactionState = .conversation
        XCTAssertEqual(inputs.resolvedState, .conversation)
        XCTAssertEqual(inputs.visualPresentationState, .conversation)
        inputs.interactionState = .preparingReply
        XCTAssertEqual(inputs.resolvedState, .working)
        XCTAssertEqual(inputs.visualPresentationState, .contactReady)
        inputs.visualState = .none
        inputs.interactionState = .idle
        XCTAssertEqual(inputs.resolvedState, .exploring)
    }

    func testHumanPresenceIndicatorIsIndependentOfMotorOrConversationGates() {
        var inputs = SubconsciousIndicatorInputs()
        inputs.observeHumanVisualPresence()
        XCTAssertEqual(inputs.visualState, .humanDetected)
        XCTAssertEqual(inputs.interactionState, .idle)

        inputs.visualState = .eyeContact
        inputs.observeHumanVisualPresence()
        XCTAssertEqual(inputs.visualState, .eyeContact)
    }

    func testIndicatorSignalsResolveToFixedDeviceRenderings() {
        let contract = tiny3LiteTestContract()
        XCTAssertEqual(SubconsciousIndicatorState.contactReady.humanMeaning, "ready_speak_now")
        XCTAssertEqual(SubconsciousIndicatorState.conversation.humanMeaning, "conversation_active")
        XCTAssertEqual(SubconsciousIndicatorState.working.humanMeaning, "conversation_active")
        XCTAssertEqual(contract.firmwareIndicatorStateID(for: .green), 54)
        XCTAssertFalse(contract.usesFirmwareDefaultIndicator(for: .green))
        XCTAssertEqual(contract.firmwareIndicatorStateID(for: .yellow), 16)
        XCTAssertEqual(contract.firmwareIndicatorStateID(for: .blue), 57)
        XCTAssertEqual(
            SOMALEDSettings().deviceRendering(for: .contactReady, on: contract),
            SOMALEDDeviceRendering(stateID: 57, pattern: .blink)
        )
        XCTAssertEqual(
            SOMALEDSettings().deviceRendering(for: .conversation, on: contract),
            SOMALEDDeviceRendering(stateID: 16, pattern: .steady)
        )
    }

    func testEyeContactIndicatorLeaseBridgesBriefGazeDropoutsOnly() {
        let start: UInt64 = 9_000_000_000
        var lease = EyeContactIndicatorLease(holdMilliseconds: 3_000)

        lease.observe(at: start)
        XCTAssertTrue(lease.isActive(at: start + 2_999_000_000))
        XCTAssertTrue(lease.isActive(at: start + 3_000_000_000))
        XCTAssertFalse(lease.isActive(at: start + 3_001_000_000))

        lease.observe(at: start + 4_000_000_000)
        lease.clear()
        XCTAssertFalse(lease.isActive(at: start + 4_001_000_000))

        lease.observe(sceneID: "face-a", at: start)
        XCTAssertTrue(lease.maintain(sceneID: "face-a", at: start + 100_000_000))
        XCTAssertTrue(lease.maintain(sceneID: "face-b", at: start + 200_000_000))
        XCTAssertTrue(lease.isActive(at: start + 2_999_000_000))
        XCTAssertFalse(lease.maintain(sceneID: "face-a", at: start + 3_001_000_000))
        XCTAssertFalse(lease.maintain(sceneID: "face-b", at: start + 3_001_000_000))
    }

    func testEyeContactIndicatorLeaseRequiresSustainedAvertedEvidenceToClear() {
        let start: UInt64 = 15_000_000_000
        var lease = EyeContactIndicatorLease(
            holdMilliseconds: 3_000,
            aversionConfirmationMilliseconds: 750
        )

        lease.observe(sceneID: "face-a", at: start)
        XCTAssertTrue(lease.observeAverted(sceneID: "face-a", at: start + 100_000_000))
        XCTAssertTrue(lease.isActive(at: start + 849_000_000))
        XCTAssertFalse(lease.observeAverted(sceneID: "face-a", at: start + 850_000_000))
        XCTAssertFalse(lease.isActive(at: start + 851_000_000))

        lease.observe(sceneID: "face-a", at: start + 900_000_000)
        XCTAssertTrue(lease.observeAverted(sceneID: "face-b", at: start + 1_000_000_000))
        XCTAssertFalse(lease.observeAverted(sceneID: "face-b", at: start + 1_750_000_000))
        XCTAssertFalse(lease.isActive(at: start + 1_751_000_000))

        lease.observe(sceneID: "face-a", at: start + 1_000_000_000)
        XCTAssertTrue(lease.observeAverted(sceneID: "face-a", at: start + 1_100_000_000))
        lease.observe(sceneID: "face-a", at: start + 1_500_000_000)
        XCTAssertTrue(lease.isActive(at: start + 2_249_000_000))
    }

    func testEyeContactIndicatorReducerNeverPromotesMissingOrAvertedGaze() {
        let start: UInt64 = 25_000_000_000
        var lease = EyeContactIndicatorLease(
            holdMilliseconds: 3_000,
            aversionConfirmationMilliseconds: 750
        )

        XCTAssertFalse(lease.update(
            gazeEvidence: .unavailable,
            sceneID: "face-a",
            at: start
        ))
        XCTAssertFalse(lease.update(
            gazeEvidence: .averted,
            sceneID: "face-a",
            at: start + 100_000_000
        ))
        XCTAssertTrue(lease.update(
            gazeEvidence: .direct,
            sceneID: "face-a",
            at: start + 200_000_000
        ))
        XCTAssertTrue(lease.update(
            gazeEvidence: .unavailable,
            sceneID: "face-a",
            at: start + 300_000_000
        ))
        XCTAssertTrue(lease.update(
            gazeEvidence: .averted,
            sceneID: "face-b",
            at: start + 400_000_000
        ))
        XCTAssertFalse(lease.update(
            gazeEvidence: .averted,
            sceneID: "face-b",
            at: start + 1_150_000_000
        ))
    }

    func testDirectGazeWinsWhenAssociatedDetectorsDisagree() {
        XCTAssertEqual(
            VisualGazeEvidence.combined([.unavailable, .direct, .averted]),
            .direct
        )
        XCTAssertEqual(
            VisualGazeEvidence.combined([.unavailable, .averted]),
            .averted
        )
        XCTAssertEqual(
            VisualGazeEvidence.combined([.unavailable]),
            .unavailable
        )
    }

    func testLiveVoiceLaunchGateDebouncesAndHasBoundedRetry() {
        var gate = LiveVoiceLaunchGate()
        let start: UInt64 = 10_000_000_000
        XCTAssertTrue(gate.beginLaunch(at: start))
        XCTAssertFalse(gate.beginLaunch(at: start + 1))
        gate.fail(at: start, retryMilliseconds: 5_000)
        XCTAssertFalse(gate.beginLaunch(at: start + 4_999_999_999))
        XCTAssertTrue(gate.beginLaunch(at: start + 5_000_000_000))
        gate.observeActive()
        XCTAssertEqual(gate.phase, .active)
        XCTAssertFalse(gate.beginLaunch(at: start + 6_000_000_000))
        gate.observeEnded()
        XCTAssertTrue(gate.beginLaunch(at: start + 6_000_000_000))
    }

    func testInitialTurnValidationRevokesOnlyUnconfirmedParticipantOpenings() {
        var validation = LiveVoiceInitialTurnValidation(transcriptTimeoutMilliseconds: 3_500)
        validation.begin(origin: .participantContact)
        XCTAssertTrue(validation.shouldCloseWhenContactIsRevoked)
        XCTAssertFalse(validation.permitsAssistantResponse)
        XCTAssertEqual(
            validation.observeTransportActive(at: 1_000_000_000),
            4_500_000_000
        )
        XCTAssertFalse(validation.shouldCloseForMissingTranscript(at: 4_499_999_999))
        XCTAssertTrue(validation.shouldCloseForMissingTranscript(at: 4_500_000_000))
        validation.confirmParticipantInput()
        XCTAssertFalse(validation.shouldCloseWhenContactIsRevoked)
        XCTAssertTrue(validation.permitsAssistantResponse)
        XCTAssertNil(validation.transcriptDeadlineNS)
        XCTAssertFalse(validation.shouldCloseForMissingTranscript(at: UInt64.max))

        validation.begin(origin: .proactive)
        XCTAssertFalse(validation.shouldCloseWhenContactIsRevoked)
        XCTAssertTrue(validation.permitsAssistantResponse)
        XCTAssertNil(validation.observeTransportActive(at: 10_000_000_000))
        validation.reset()
        XCTAssertNil(validation.origin)
    }

    func testInitialTurnValidationAcceptsOnlySubmittedAndTransportedOpeningAudio() {
        var validation = LiveVoiceInitialTurnValidation(transcriptTimeoutMilliseconds: 3_500)
        validation.begin(origin: .participantContact)
        _ = validation.observeTransportActive(at: 1_000_000_000)

        validation.observeInitialAudioSubmitted()
        XCTAssertFalse(validation.permitsAssistantResponse)
        XCTAssertNotNil(validation.transcriptDeadlineNS)

        validation.observeInitialAudioTransportProgress()
        XCTAssertTrue(validation.permitsAssistantResponse)
        XCTAssertNil(validation.transcriptDeadlineNS)
        XCTAssertFalse(validation.shouldCloseWhenContactIsRevoked)
        XCTAssertFalse(validation.shouldCloseForMissingTranscript(at: UInt64.max))

        validation.begin(origin: .participantContact)
        validation.observeInitialAudioTransportProgress()
        XCTAssertFalse(validation.permitsAssistantResponse)
        validation.observeInitialAudioSubmitted()
        XCTAssertTrue(validation.permitsAssistantResponse)

        validation.begin(origin: .proactive)
        validation.observeInitialAudioSubmitted()
        validation.observeInitialAudioTransportProgress()
        XCTAssertFalse(validation.initialAudioSubmitted)
        XCTAssertFalse(validation.initialAudioTransportConfirmed)
        XCTAssertTrue(validation.permitsAssistantResponse)
    }

    private func decision(
        model: EventImportanceModel,
        features: EventImportanceFeatures
    ) -> EventImportanceDecision {
        model.evaluate(
            EventImportanceInput(
                eventID: "test",
                monotonicNS: 1,
                evidenceIDs: ["evidence:test"],
                features: features
            )
        )
    }

    private func loadBootstrapCorpus() throws -> [LabelledEventImportanceExample] {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = sourceRoot
            .appendingPathComponent("Sources/SOMAEventEval/Resources/bootstrap-v3.jsonl")
        let decoder = JSONDecoder()
        return try String(contentsOf: url, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map { try decoder.decode(LabelledEventImportanceExample.self, from: Data($0.utf8)) }
    }
}
#endif
