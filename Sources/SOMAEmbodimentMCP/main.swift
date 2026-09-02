import CryptoKit
import Foundation
import SOMACore

private enum ServerFailure: Error, LocalizedError {
    case invalidArguments(String)
    case protocolViolation(String)

    var errorDescription: String? {
        switch self {
        case let .invalidArguments(message), let .protocolViolation(message): message
        }
    }
}

private struct ControlArguments: Codable {
    let requestId: String?
    let sourceLayer: CognitiveControlLayer
    let ownerId: String
    let priority: UInt8
    let leaseMs: UInt64
    let reason: String
    let evidenceIds: [String]?

    func request(operation: CognitiveEmbodimentOperation) -> CognitiveEmbodimentRequest {
        let requestID = requestId ?? UUID().uuidString.lowercased()
        let now = DispatchTime.now().uptimeNanoseconds
        return CognitiveEmbodimentRequest(
            requestID: requestID,
            layer: sourceLayer,
            reason: reason,
            evidenceIDs: evidenceIds ?? [],
            lease: EmbodimentLease(
                ownerID: ownerId,
                priority: priority,
                issuedAtNS: now,
                durationMilliseconds: leaseMs,
                cancellationToken: "mcp:\(requestID)"
            ),
            operation: operation
        )
    }
}

private struct RegisterArguments: Codable {
    let control: ControlArguments
    let registration: SemanticTargetArguments
}

private struct SemanticTargetArguments: Codable {
    let targetReference: String
    let sceneId: String?
    let label: String
    let aliases: [String]
    let visualQuery: String?
    let expectedKind: AttentionTargetKind?
    let initialSelectionLogPrior: Double

    var value: SemanticTargetRegistration {
        SemanticTargetRegistration(
            targetReference: targetReference,
            sceneID: sceneId,
            label: label,
            aliases: aliases,
            visualQuery: visualQuery,
            expectedKind: expectedKind,
            initialSelectionLogPrior: initialSelectionLogPrior
        )
    }
}

private struct RemoveArguments: Codable {
    let control: ControlArguments
    let targetReference: String
}

private struct AttentionArguments: Codable {
    let control: ControlArguments
    let policy: AttentionPolicyGoal
}

private struct TrackArguments: Codable {
    let control: ControlArguments
    let goal: TrackTargetGoal
}

private struct OrientArguments: Codable {
    let control: ControlArguments
    let goal: OrientGoal
}

private struct ExploreArguments: Codable {
    let control: ControlArguments
    let policy: ExplorationPolicyGoal
}

private struct CaptureArguments: Codable {
    let control: ControlArguments
    let goal: CaptureViewGoal
}

private struct OpticalZoomArguments: Codable {
    let control: ControlArguments
    let goal: OpticalZoomGoal
}

private struct AudioCaptureModeArguments: Codable {
    let control: ControlArguments
    let goal: AudioCaptureModeGoal
}

private struct AudioInputGainArguments: Codable {
    let control: ControlArguments
    let goal: AudioInputGainGoal
}

private struct CameraWhiteBalanceArguments: Codable {
    let control: ControlArguments
    let goal: CameraWhiteBalanceGoal
}

private struct CameraExposureLockArguments: Codable {
    let control: ControlArguments
    let goal: CameraExposureLockGoal
}

private struct CameraFocusArguments: Codable {
    let control: ControlArguments
    let goal: CameraFocusGoal
}

private struct CameraAbsoluteExposureArguments: Codable {
    let control: ControlArguments
    let goal: CameraAbsoluteExposureGoal
}

private struct CameraFacePriorityArguments: Codable {
    let control: ControlArguments
    let goal: CameraFacePriorityGoal
}

private struct CameraAntiFlickerArguments: Codable {
    let control: ControlArguments
    let goal: CameraAntiFlickerGoal
}

private struct CameraImageTuningArguments: Codable {
    let control: ControlArguments
    let goal: CameraImageTuningGoal
}

private struct NativeHumanTrackingPolicyArguments: Codable {
    let control: ControlArguments
    let goal: NativeHumanTrackingPolicyGoal
}

private struct CameraFieldOfViewArguments: Codable {
    let control: ControlArguments
    let goal: CameraFieldOfViewGoal
}

private struct ExpressionArguments: Codable {
    let control: ControlArguments
    let expression: SocialGimbalExpression
}

private struct ReleaseArguments: Codable {
    let control: ControlArguments
}

private struct ViewResultArguments: Codable {
    let requestId: String
}

private struct EnrollPresentIdentityArguments: Codable {
    let personEntityId: UUID
    let confirmedByUser: Bool
}

private struct PersonContextArguments: Codable {
    let personEntityId: UUID?
    let languageTag: String?
    let proactiveContact: ProactiveContactPreference?
    let familiarity: Double?
    let interactionComfort: Double?
    let communicationAlignment: Double?
    let key: String?
    let value: String?
    let confirmedByUser: Bool?
    let query: String?

    func request(for operation: PersonContextIPCOperation) throws -> PersonContextIPCRequest {
        switch operation {
        case .get:
            guard personEntityId != nil else {
                throw ServerFailure.invalidArguments("get_person_context requires person_entity_id")
            }
        case .setPreferredLanguage:
            guard personEntityId != nil, languageTag != nil, confirmedByUser == true else {
                throw ServerFailure.invalidArguments("set_preferred_language requires person_entity_id, language_tag and confirmed_by_user=true")
            }
        case .clearPreferredLanguage:
            guard personEntityId != nil, confirmedByUser == true else {
                throw ServerFailure.invalidArguments("clear_preferred_language requires person_entity_id and confirmed_by_user=true")
            }
        case .setContactPreference:
            guard personEntityId != nil, proactiveContact != nil, confirmedByUser == true else {
                throw ServerFailure.invalidArguments("set_contact_preference requires person_entity_id, proactive_contact and confirmed_by_user=true")
            }
        case .setRapport:
            guard personEntityId != nil,
                  familiarity != nil,
                  interactionComfort != nil,
                  communicationAlignment != nil,
                  proactiveContact != nil,
                  confirmedByUser == true else {
                throw ServerFailure.invalidArguments("set_person_rapport requires person_entity_id, rapport values, proactive_contact, and confirmed_by_user=true")
            }
        case .setFact:
            guard personEntityId != nil, key != nil, value != nil, confirmedByUser == true else {
                throw ServerFailure.invalidArguments("set_person_fact requires person_entity_id, key, value, and confirmed_by_user=true")
            }
        case .removeFact:
            guard personEntityId != nil, key != nil, confirmedByUser == true else {
                throw ServerFailure.invalidArguments("remove_person_fact requires person_entity_id, key and confirmed_by_user=true")
            }
        case .recallEpisodes:
            guard let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ServerFailure.invalidArguments("recall_episodes requires query")
            }
        }
        return PersonContextIPCRequest(
            operation: operation,
            personEntityID: personEntityId,
            languageTag: languageTag,
            proactiveContact: proactiveContact,
            familiarity: familiarity,
            interactionComfort: interactionComfort,
            communicationAlignment: communicationAlignment,
            factKey: key,
            factValue: value,
            confirmedByUser: confirmedByUser ?? false,
            query: query
        )
    }
}

private struct InformationNeedsArguments: Codable {
    let personEntityId: UUID
    let motiveId: UUID?
    let acquiredFact: String?

    func request(for operation: InformationNeedsIPCOperation) throws -> InformationNeedsIPCRequest {
        switch operation {
        case .list:
            guard motiveId == nil, acquiredFact == nil else {
                throw ServerFailure.invalidArguments("list_information_needs requires only person_entity_id")
            }
        case .recordAnswer:
            guard motiveId != nil,
                  let fact = acquiredFact?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !fact.isEmpty else {
                throw ServerFailure.invalidArguments("record_information_need_answer requires person_entity_id, motive_id, and acquired_fact")
            }
        }
        return InformationNeedsIPCRequest(
            operation: operation,
            personEntityID: personEntityId,
            motiveID: motiveId,
            acquiredFact: acquiredFact
        )
    }
}

private struct DelegateHermesTaskArguments: Codable {
    let title: String
    let objective: String
    let workingDirectory: String?
}

private struct ContinueHermesTaskArguments: Codable {
    let taskId: UUID
    let objective: String
    let title: String?
}

private struct HermesTaskReferenceArguments: Codable {
    let taskId: UUID
}

private struct ListHermesTasksArguments: Codable {
    let statuses: [HermesAgentTaskStatus]?
}

private struct ResolveHermesReportOfferArguments: Codable {
    let taskId: UUID
    let wantsReport: Bool
}

private struct HostComputerControlArguments: Codable {
    let action: HostComputerInputAction
}

private struct CognitiveIntentArguments: Codable {
    let goalEpisodeId: UUID
    let purpose: String
    let expectedInformationGain: Double
    let evidenceIds: [String]?
    let authorizationBasis: L2CognitiveAuthorizationBasis

    var value: L2CognitiveToolIntent {
        L2CognitiveToolIntent(
            goalEpisodeID: goalEpisodeId,
            purpose: purpose,
            expectedInformationGain: expectedInformationGain,
            evidenceIDs: evidenceIds ?? [],
            authorizationBasis: authorizationBasis
        )
    }
}

private final class EmbodimentMCPServer {
    private let socketURL: URL
    private let sessionAuthorization: String?
    private var initialized = false
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let gatewayReadGoalEpisodeID = UUID()
    private let supportedProtocolVersion = "2025-11-25"
    private let maximumLineBytes = 1_048_576

    init(socketURL: URL) {
        self.socketURL = socketURL
        self.sessionAuthorization = Self.environmentSessionAuthorization()
        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    func run() {
        while let line = readLine(strippingNewline: true) {
            guard line.lengthOfBytes(using: .utf8) <= maximumLineBytes else {
                write(error: -32600, message: "request exceeds 1 MiB", id: NSNull())
                continue
            }
            do {
                let value = try JSONSerialization.jsonObject(with: Data(line.utf8))
                guard let object = value as? [String: Any] else {
                    throw ServerFailure.protocolViolation("request must be a JSON object")
                }
                try handle(object)
            } catch {
                write(error: -32700, message: bounded(error.localizedDescription), id: NSNull())
            }
        }
    }

    private func handle(_ request: [String: Any]) throws {
        guard request["jsonrpc"] as? String == "2.0",
              let method = request["method"] as? String else {
            throw ServerFailure.protocolViolation("invalid JSON-RPC request")
        }
        let id = request["id"] ?? NSNull()
        let isNotification = request["id"] == nil

        switch method {
        case "initialize":
            guard !isNotification else { return }
            initialized = true
            write(result: [
                "protocolVersion": supportedProtocolVersion,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "soma-embodiment", "version": "0.5.0"],
                "instructions": "SOMA cognition tools are routed to the local L0 owner. capture_view observes the robot camera; observe_host_screen observes the Mac display, and they are never interchangeable. control_host_computer performs only one immediate explicit administrator input action. Longer host work belongs to delegate_hermes_task. L0 retains participant, privacy, motor, and host-input authority."
            ], id: id)
        case "notifications/initialized", "notifications/cancelled":
            return
        case "ping":
            guard !isNotification else { return }
            write(result: [:], id: id)
        case "tools/list":
            guard initialized else {
                write(error: -32002, message: "server is not initialized", id: id)
                return
            }
            write(result: ["tools": toolDefinitions()], id: id)
        case "tools/call":
            guard initialized else {
                write(error: -32002, message: "server is not initialized", id: id)
                return
            }
            guard let parameters = request["params"] as? [String: Any],
                  let name = parameters["name"] as? String else {
                write(error: -32602, message: "tools/call requires a tool name", id: id)
                return
            }
            guard knownToolNames.contains(name) else {
                write(error: -32602, message: "unknown tool: \(name)", id: id)
                return
            }
            let cognitiveIntent: L2CognitiveToolIntent
            var arguments = parameters["arguments"] as? [String: Any] ?? [:]
            if L2CognitiveToolPolicy.requiresModelAuthoredIntent(for: name) {
                guard let rawIntent = arguments.removeValue(forKey: "cognitive_intent") as? [String: Any] else {
                    write(result: toolFailure("\(name) requires a policy-bound cognitive_intent"), id: id)
                    return
                }
                do {
                    let decoded: CognitiveIntentArguments = try decode(rawIntent)
                    cognitiveIntent = decoded.value
                    guard !cognitiveIntent.purpose.isEmpty else {
                        write(result: toolFailure("cognitive_intent purpose is required"), id: id)
                        return
                    }
                } catch {
                    write(result: toolFailure(error.localizedDescription), id: id)
                    return
                }
            } else {
                arguments.removeValue(forKey: "cognitive_intent")
                guard let gatewayIntent = L2CognitiveToolPolicy.gatewayEpistemicIntent(
                    for: name,
                    goalEpisodeID: gatewayReadGoalEpisodeID
                ) else {
                    write(result: toolFailure("tool has no epistemic authorization policy: \(name)"), id: id)
                    return
                }
                cognitiveIntent = gatewayIntent
            }
            guard L2CognitiveToolPolicy.autonomy(for: name) != nil else {
                write(result: toolFailure("tool has no cognitive authorization policy: \(name)"), id: id)
                return
            }
            if !L2CognitiveToolPolicy.permits(cognitiveIntent.authorizationBasis, for: name) {
                write(
                    result: toolFailure("authorization_basis does not permit \(name)"),
                    id: id
                )
                return
            }
            do {
                try authorizeCognitiveIntent(cognitiveIntent)
            } catch {
                write(result: toolFailure(error.localizedDescription), id: id)
                return
            }
            let requestFingerprint = semanticRequestFingerprint(toolName: name, arguments: arguments)
            do {
                if L2CognitiveToolPolicy.usesSemanticDeduplication(for: name),
                   try cognitiveActionAlreadyRecorded(
                    toolName: name,
                    intent: cognitiveIntent,
                    requestFingerprint: requestFingerprint
                ) {
                    write(
                        result: toolFailure(
                            "duplicate cognitive action rejected: the same goal, evidence, and semantic request already ran"
                        ),
                        id: id
                    )
                    return
                }
            } catch {
                write(result: toolFailure("cognitive action lookup failed: \(error.localizedDescription)"), id: id)
                return
            }
            do {
                let reply = try callTool(
                    name: name,
                    arguments: arguments,
                    cognitiveIntent: cognitiveIntent
                )
                guard recordCognitiveAction(
                    toolName: name,
                    intent: cognitiveIntent,
                    reply: reply,
                    requestFingerprint: requestFingerprint,
                    sessionAuthorization: sessionAuthorization
                ) else {
                    write(
                        result: toolFailure("tool executed, but its cognitive outcome could not be recorded; do not retry automatically"),
                        id: id
                    )
                    return
                }
                write(result: toolResult(reply, for: name), id: id)
            } catch ServerFailure.invalidArguments(let message) {
                _ = recordCognitiveFailure(
                    toolName: name,
                    intent: cognitiveIntent,
                    message: message,
                    requestFingerprint: requestFingerprint,
                    sessionAuthorization: sessionAuthorization
                )
                write(result: toolFailure(message), id: id)
            } catch {
                _ = recordCognitiveFailure(
                    toolName: name,
                    intent: cognitiveIntent,
                    message: error.localizedDescription,
                    requestFingerprint: requestFingerprint,
                    sessionAuthorization: sessionAuthorization
                )
                write(result: toolFailure(error.localizedDescription), id: id)
            }
        default:
            if !isNotification { write(error: -32601, message: "method not found", id: id) }
        }
    }

    private func callTool(
        name: String,
        arguments: [String: Any],
        cognitiveIntent: L2CognitiveToolIntent
    ) throws -> EmbodimentIPCReply {
        let sessionAuthorization = try sessionAuthorization(for: name, arguments: arguments)
        let toolArguments = arguments
        switch name {
        case "end_conversation":
            guard toolArguments.isEmpty else {
                throw ServerFailure.invalidArguments("end_conversation takes no arguments")
            }
            return try EmbodimentShadowSocketClient.send(
                .init(kind: .endConversation, sessionAuthorization: sessionAuthorization),
                socketURL: socketURL
            )
        case "get_robot_body_state", "list_scene_entities", "get_spatial_map":
            guard toolArguments.isEmpty else {
                throw ServerFailure.invalidArguments("\(name) takes no arguments")
            }
            return try EmbodimentShadowSocketClient.send(
                .init(kind: .snapshot, sessionAuthorization: sessionAuthorization),
                socketURL: socketURL
            )
        case "get_activity_overview":
            guard toolArguments.isEmpty else {
                throw ServerFailure.invalidArguments("get_activity_overview takes no arguments")
            }
            let bodyReply = try EmbodimentShadowSocketClient.send(
                .init(kind: .snapshot, sessionAuthorization: sessionAuthorization),
                socketURL: socketURL
            )
            guard bodyReply.ok, let snapshot = bodyReply.snapshot else { return bodyReply }
            let taskReply = try EmbodimentShadowSocketClient.send(
                .init(
                    kind: .hermesAgentTask,
                    hermesAgentTask: .init(operation: .list),
                    sessionAuthorization: sessionAuthorization
                ),
                socketURL: socketURL
            )
            guard taskReply.ok else { return taskReply }
            let activities = (taskReply.hermesAgentTask?.tasks ?? []).map(HermesAgentTaskActivity.init)
            return EmbodimentIPCReply(
                ok: true,
                snapshot: snapshot,
                activityOverview: .init(robotBody: snapshot, delegatedTasks: activities)
            )
        case "observe_host_screen":
            guard toolArguments.isEmpty else {
                throw ServerFailure.invalidArguments("observe_host_screen takes no semantic arguments")
            }
            return try EmbodimentShadowSocketClient.send(
                .init(
                    kind: .hostComputer,
                    cognitiveAuthorizationBasis: .explicitRequest,
                    hostComputer: .init(operation: .observeScreen),
                    sessionAuthorization: sessionAuthorization
                ),
                socketURL: socketURL
            )
        case "control_host_computer":
            let value: HostComputerControlArguments = try decode(toolArguments)
            try value.action.validate()
            return try EmbodimentShadowSocketClient.send(
                .init(
                    kind: .hostComputer,
                    cognitiveAuthorizationBasis: .explicitRequest,
                    hostComputer: .init(operation: .performInput, input: value.action),
                    sessionAuthorization: sessionAuthorization
                ),
                socketURL: socketURL
            )
        case "get_view_capture":
            let value: ViewResultArguments = try decode(toolArguments)
            return try EmbodimentShadowSocketClient.send(
                .init(
                    kind: .captureResult,
                    requestID: value.requestId,
                    sessionAuthorization: sessionAuthorization
                ),
                socketURL: socketURL
            )
        case "list_present_people", "list_identity_registry":
            guard toolArguments.isEmpty else {
                throw ServerFailure.invalidArguments("\(name) takes no arguments")
            }
            let query: IdentityRosterQuery = name == "list_present_people" ? .present : .registered
            return try EmbodimentShadowSocketClient.send(
                .init(
                    kind: .identityRoster,
                    identityRosterQuery: query,
                    sessionAuthorization: sessionAuthorization
                ),
                socketURL: socketURL
            )
        case "enroll_present_identity":
            let value: EnrollPresentIdentityArguments = try decode(toolArguments)
            guard value.confirmedByUser else {
                throw ServerFailure.invalidArguments("enroll_present_identity requires confirmed_by_user=true")
            }
            return try EmbodimentShadowSocketClient.send(
                .init(
                    kind: .identityEnrollment,
                    identityEnrollment: .init(
                        personEntityID: value.personEntityId,
                        confirmedByUser: true
                    ),
                    sessionAuthorization: sessionAuthorization
                ),
                socketURL: socketURL
            )
        case "get_person_context", "set_preferred_language", "clear_preferred_language",
             "set_contact_preference", "set_person_rapport", "set_person_fact",
             "remove_person_fact", "recall_episodes":
            guard let operation = personContextOperation(forTool: name) else {
                throw ServerFailure.invalidArguments("unknown tool: \(name)")
            }
            let value: PersonContextArguments = try decode(toolArguments)
            return try EmbodimentShadowSocketClient.send(
                .init(
                    kind: .personContext,
                    personContext: try value.request(for: operation),
                    sessionAuthorization: sessionAuthorization
                ),
                socketURL: socketURL
            )
        case "list_information_needs", "record_information_need_answer":
            let value: InformationNeedsArguments = try decode(toolArguments)
            let operation: InformationNeedsIPCOperation = name == "list_information_needs" ? .list : .recordAnswer
            return try EmbodimentShadowSocketClient.send(
                .init(
                    kind: .informationNeeds,
                    informationNeeds: try value.request(for: operation),
                    sessionAuthorization: sessionAuthorization
                ),
                socketURL: socketURL
            )
        case "delegate_hermes_task":
            let value: DelegateHermesTaskArguments = try decode(toolArguments)
            return try EmbodimentShadowSocketClient.send(
                .init(
                    kind: .hermesAgentTask,
                    hermesAgentTask: .init(
                        operation: .submit,
                        goalEpisodeID: cognitiveIntent.goalEpisodeID,
                        title: value.title,
                        objective: value.objective,
                        workingDirectory: value.workingDirectory
                    ),
                    sessionAuthorization: sessionAuthorization
                ),
                socketURL: socketURL
            )
        case "continue_hermes_task":
            let value: ContinueHermesTaskArguments = try decode(toolArguments)
            return try EmbodimentShadowSocketClient.send(
                .init(
                    kind: .hermesAgentTask,
                    hermesAgentTask: .init(
                        operation: .continueTask,
                        taskID: value.taskId,
                        goalEpisodeID: cognitiveIntent.goalEpisodeID,
                        title: value.title,
                        objective: value.objective
                    ),
                    sessionAuthorization: sessionAuthorization
                ),
                socketURL: socketURL
            )
        case "get_hermes_task", "cancel_hermes_task":
            let value: HermesTaskReferenceArguments = try decode(toolArguments)
            return try EmbodimentShadowSocketClient.send(
                .init(
                    kind: .hermesAgentTask,
                    hermesAgentTask: .init(
                        operation: name == "get_hermes_task" ? .get : .cancel,
                        taskID: value.taskId
                    ),
                    sessionAuthorization: sessionAuthorization
                ),
                socketURL: socketURL
            )
        case "list_hermes_tasks":
            let value: ListHermesTasksArguments = try decode(toolArguments)
            return try EmbodimentShadowSocketClient.send(
                .init(
                    kind: .hermesAgentTask,
                    hermesAgentTask: .init(operation: .list, statuses: value.statuses),
                    sessionAuthorization: sessionAuthorization
                ),
                socketURL: socketURL
            )
        case "resolve_hermes_report_offer":
            let value: ResolveHermesReportOfferArguments = try decode(toolArguments)
            return try EmbodimentShadowSocketClient.send(
                .init(
                    kind: .hermesAgentTask,
                    hermesAgentTask: .init(
                        operation: .resolveReportOffer,
                        taskID: value.taskId,
                        wantsReport: value.wantsReport
                    ),
                    sessionAuthorization: sessionAuthorization
                ),
                socketURL: socketURL
            )
        case "register_semantic_target", "remove_semantic_target", "set_attention_policy",
             "track_target", "orient_to", "set_exploration_policy", "capture_view",
             "set_camera_optical_zoom", "set_audio_capture_mode", "set_audio_input_gain", "set_camera_white_balance", "set_camera_exposure_lock", "set_camera_focus", "set_camera_absolute_exposure", "set_camera_face_priority", "set_camera_anti_flicker", "set_camera_image_tuning", "set_native_human_tracking_policy", "set_camera_field_of_view", "express_gimbal", "release_embodiment":
            var authorizedArguments = toolArguments
            authorizedArguments["control"] = trustedEmbodimentControl(
                toolName: name,
                intent: cognitiveIntent
            )
            let request = try embodimentRequest(for: name, arguments: authorizedArguments)
            let initial = try EmbodimentShadowSocketClient.send(
                .init(
                    kind: .submit,
                    request: request,
                    sessionAuthorization: sessionAuthorization
                ),
                socketURL: socketURL
            )
            guard name == "capture_view", initial.ok else { return initial }
            let capture: CaptureArguments = try decode(authorizedArguments)
            guard capture.goal.requestsCurrentFrame || initial.snapshot?.physicalActuationEnabled == true else {
                return EmbodimentIPCReply(
                    ok: false,
                    error: "capture_view_requires_physical_l0_adapter",
                    decision: initial.decision,
                    snapshot: initial.snapshot
                )
            }
            return try waitForViewCapture(
                request: request,
                initial: initial,
                sessionAuthorization: sessionAuthorization
            )
        default:
            throw ServerFailure.invalidArguments("unknown tool: \(name)")
        }
    }

    private func authorizeCognitiveIntent(_ intent: L2CognitiveToolIntent) throws {
        let reply = try EmbodimentShadowSocketClient.send(
            .init(
                kind: .cognitiveAuthorization,
                cognitiveAuthorizationBasis: intent.authorizationBasis,
                sessionAuthorization: sessionAuthorization
            ),
            socketURL: socketURL
        )
        guard reply.ok else {
            throw ServerFailure.invalidArguments(
                reply.error ?? "cognitive authorization is unavailable"
            )
        }
    }

    /// The model selects a semantic goal, while the trusted local gateway owns
    /// source identity, priority, and lease bounds before L0 arbitration.
    private func trustedEmbodimentControl(
        toolName: String,
        intent: L2CognitiveToolIntent
    ) -> [String: Any] {
        let leaseMilliseconds: UInt64
        switch toolName {
        case "track_target", "set_attention_policy", "set_exploration_policy":
            leaseMilliseconds = 120_000
        case "orient_to", "capture_view":
            leaseMilliseconds = 15_000
        case "express_gimbal":
            leaseMilliseconds = 3_000
        case "release_embodiment":
            leaseMilliseconds = 1
        default:
            leaseMilliseconds = 10_000
        }
        return [
            "source_layer": CognitiveControlLayer.l2.rawValue,
            "owner_id": "l2:\(intent.goalEpisodeID.uuidString.lowercased())",
            "priority": 90,
            "lease_ms": leaseMilliseconds,
            "reason": String(intent.purpose.prefix(240)),
            "evidence_ids": Array(intent.evidenceIDs.prefix(16)).map { String($0.prefix(128)) },
        ]
    }

    private func embodimentRequest(
        for name: String,
        arguments: [String: Any]
    ) throws -> CognitiveEmbodimentRequest {
        switch name {
        case "register_semantic_target":
            let value: RegisterArguments = try decode(arguments)
            return value.control.request(operation: .registerTarget(value.registration.value))
        case "remove_semantic_target":
            let value: RemoveArguments = try decode(arguments)
            return value.control.request(operation: .removeTarget(value.targetReference))
        case "set_attention_policy":
            let value: AttentionArguments = try decode(arguments)
            return value.control.request(operation: .setAttentionPolicy(value.policy))
        case "track_target":
            let value: TrackArguments = try decode(arguments)
            return value.control.request(operation: .trackTarget(value.goal))
        case "orient_to":
            let value: OrientArguments = try decode(arguments)
            return value.control.request(operation: .orient(value.goal))
        case "set_exploration_policy":
            let value: ExploreArguments = try decode(arguments)
            return value.control.request(operation: .explore(value.policy))
        case "capture_view":
            let value: CaptureArguments = try decode(arguments)
            return value.control.request(operation: .captureView(value.goal))
        case "set_camera_optical_zoom":
            let value: OpticalZoomArguments = try decode(arguments)
            return value.control.request(operation: .setOpticalZoom(value.goal))
        case "set_audio_capture_mode":
            let value: AudioCaptureModeArguments = try decode(arguments)
            return value.control.request(operation: .setAudioCaptureMode(value.goal))
        case "set_audio_input_gain":
            let value: AudioInputGainArguments = try decode(arguments)
            return value.control.request(operation: .setAudioInputGain(value.goal))
        case "set_camera_white_balance":
            let value: CameraWhiteBalanceArguments = try decode(arguments)
            return value.control.request(operation: .setCameraWhiteBalance(value.goal))
        case "set_camera_exposure_lock":
            let value: CameraExposureLockArguments = try decode(arguments)
            return value.control.request(operation: .setCameraExposureLock(value.goal))
        case "set_camera_focus":
            let value: CameraFocusArguments = try decode(arguments)
            return value.control.request(operation: .setCameraFocus(value.goal))
        case "set_camera_absolute_exposure":
            let value: CameraAbsoluteExposureArguments = try decode(arguments)
            return value.control.request(operation: .setCameraAbsoluteExposure(value.goal))
        case "set_camera_face_priority":
            let value: CameraFacePriorityArguments = try decode(arguments)
            return value.control.request(operation: .setCameraFacePriority(value.goal))
        case "set_camera_anti_flicker":
            let value: CameraAntiFlickerArguments = try decode(arguments)
            return value.control.request(operation: .setCameraAntiFlicker(value.goal))
        case "set_camera_image_tuning":
            let value: CameraImageTuningArguments = try decode(arguments)
            return value.control.request(operation: .setCameraImageTuning(value.goal))
        case "set_native_human_tracking_policy":
            let value: NativeHumanTrackingPolicyArguments = try decode(arguments)
            return value.control.request(operation: .setNativeHumanTrackingPolicy(value.goal))
        case "set_camera_field_of_view":
            let value: CameraFieldOfViewArguments = try decode(arguments)
            return value.control.request(operation: .setCameraFieldOfView(value.goal))
        case "express_gimbal":
            let value: ExpressionArguments = try decode(arguments)
            return value.control.request(operation: .express(value.expression))
        case "release_embodiment":
            let value: ReleaseArguments = try decode(arguments)
            return value.control.request(operation: .release)
        default:
            throw ServerFailure.invalidArguments("unknown tool: \(name)")
        }
    }

    private func waitForViewCapture(
        request: CognitiveEmbodimentRequest,
        initial: EmbodimentIPCReply,
        sessionAuthorization: String?
    ) throws -> EmbodimentIPCReply {
        let maximumWaitNS: UInt64 = 15_000_000_000
        let now = DispatchTime.now().uptimeNanoseconds
        let boundedDeadline = min(request.lease.expiresAtNS, now + maximumWaitNS)
        var lastSnapshot = initial.snapshot
        while DispatchTime.now().uptimeNanoseconds < boundedDeadline {
            let reply = try EmbodimentShadowSocketClient.send(
                .init(
                    kind: .captureResult,
                    requestID: request.requestID,
                    sessionAuthorization: sessionAuthorization
                ),
                socketURL: socketURL
            )
            lastSnapshot = reply.snapshot ?? lastSnapshot
            if let resource = reply.viewResource {
                switch resource.state {
                case .ready:
                    return EmbodimentIPCReply(
                        ok: true,
                        decision: initial.decision,
                        snapshot: lastSnapshot,
                        viewResource: resource
                    )
                case .failed, .expired:
                    return EmbodimentIPCReply(
                        ok: false,
                        error: resource.failureReason ?? resource.state.rawValue,
                        decision: initial.decision,
                        snapshot: lastSnapshot,
                        viewResource: resource
                    )
                case .pendingAlignment, .awaitingFrame, .encoding:
                    break
                }
            } else if reply.error != "capture_result_unknown" {
                return reply
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return EmbodimentIPCReply(
            ok: false,
            error: "capture_wait_timeout; query get_view_capture with request_id=\(request.requestID)",
            decision: initial.decision,
            snapshot: lastSnapshot
        )
    }

    private func sessionAuthorization(
        for toolName: String,
        arguments: [String: Any]
    ) throws -> String? {
        guard protectedToolNames.contains(toolName) else { return nil }
        guard arguments["session_token"] == nil else {
            throw ServerFailure.invalidArguments("session_token is managed by the active SOMA interaction")
        }
        guard let sessionAuthorization else {
            throw ServerFailure.invalidArguments("\(toolName) is unavailable outside an active SOMA interaction")
        }
        return sessionAuthorization
    }

    private func decode<T: Decodable>(_ arguments: [String: Any]) throws -> T {
        do {
            let data = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
            return try decoder.decode(T.self, from: data)
        } catch {
            throw ServerFailure.invalidArguments("invalid tool arguments: \(bounded(error.localizedDescription))")
        }
    }

    private func recordCognitiveAction(
        toolName: String,
        intent: L2CognitiveToolIntent,
        reply: EmbodimentIPCReply,
        requestFingerprint: String?,
        sessionAuthorization: String?
    ) -> Bool {
        guard let effect = L2CognitiveToolPolicy.effect(for: toolName) else { return false }
        let data = (try? encoder.encode(reply)) ?? Data("unencodable".utf8)
        let episode = CognitiveActionEpisode(
            goalEpisodeID: intent.goalEpisodeID,
            sourceLayer: .l2,
            toolName: toolName,
            effect: effect,
            purpose: intent.purpose,
            expectedInformationGain: intent.expectedInformationGain,
            evidenceIDs: intent.evidenceIDs,
            status: reply.ok ? .succeeded : .failed,
            resultFingerprint: Self.sha256(data),
            requestFingerprint: requestFingerprint,
            resultSummary: cognitiveSummary(toolName: toolName, reply: reply)
        )
        guard let acknowledgement = try? EmbodimentShadowSocketClient.send(
            .init(
                kind: .cognitiveActionOutcome,
                cognitiveAction: episode,
                sessionAuthorization: sessionAuthorization
            ),
            socketURL: socketURL
        ) else { return false }
        return acknowledgement.ok
    }

    private func cognitiveActionAlreadyRecorded(
        toolName: String,
        intent: L2CognitiveToolIntent,
        requestFingerprint: String
    ) throws -> Bool {
        let reply = try EmbodimentShadowSocketClient.send(
            .init(
                kind: .cognitiveActionQuery,
                cognitiveActionQuery: .init(
                    goalEpisodeID: intent.goalEpisodeID,
                    toolName: toolName,
                    requestFingerprint: requestFingerprint,
                    evidenceIDs: intent.evidenceIDs
                ),
                sessionAuthorization: sessionAuthorization
            ),
            socketURL: socketURL
        )
        guard reply.ok else {
            throw ServerFailure.invalidArguments(reply.error ?? "cognitive action lookup unavailable")
        }
        return reply.cognitiveActionDuplicate == true
    }

    private func recordCognitiveFailure(
        toolName: String,
        intent: L2CognitiveToolIntent,
        message: String,
        requestFingerprint: String?,
        sessionAuthorization: String?
    ) -> Bool {
        guard let effect = L2CognitiveToolPolicy.effect(for: toolName) else { return false }
        let boundedMessage = bounded(message)
        let episode = CognitiveActionEpisode(
            goalEpisodeID: intent.goalEpisodeID,
            sourceLayer: .l2,
            toolName: toolName,
            effect: effect,
            purpose: intent.purpose,
            expectedInformationGain: intent.expectedInformationGain,
            evidenceIDs: intent.evidenceIDs,
            status: .failed,
            resultFingerprint: Self.sha256(Data(boundedMessage.utf8)),
            requestFingerprint: requestFingerprint,
            resultSummary: "The cognitive tool action failed: \(boundedMessage)"
        )
        guard let acknowledgement = try? EmbodimentShadowSocketClient.send(
            .init(
                kind: .cognitiveActionOutcome,
                cognitiveAction: episode,
                sessionAuthorization: sessionAuthorization
            ),
            socketURL: socketURL
        ) else { return false }
        return acknowledgement.ok
    }

    private func cognitiveSummary(toolName: String, reply: EmbodimentIPCReply) -> String {
        guard reply.ok else {
            return "The cognitive tool action failed: \(bounded(reply.error ?? "unknown failure"))"
        }
        switch toolName {
        case "capture_view", "get_view_capture":
            return reply.viewResource == nil
                ? "The requested visual evidence was accepted but no completed view was returned."
                : "Current visual evidence was acquired."
        case "get_person_context":
            return "The participant context was refreshed from canonical memory."
        case "list_information_needs":
            return "The curiosity queue was refreshed with \(reply.informationNeeds?.items.count ?? 0) open motives."
        case "record_information_need_answer":
            return "A confirmed answer was stored and its information motive was closed."
        case "recall_episodes":
            return "Episodic memory returned \(reply.recalledEpisodes?.count ?? 0) relevant summaries."
        case "list_present_people", "list_identity_registry":
            return "The identity roster returned \(reply.identityRoster?.entries.count ?? 0) bounded entries."
        case "set_preferred_language", "clear_preferred_language", "set_contact_preference",
             "set_person_rapport", "set_person_fact", "remove_person_fact":
            return "Explicitly grounded participant context was persisted."
        case "enroll_present_identity":
            return "A consented present identity was enrolled."
        case "end_conversation":
            return "The active conversation was ended."
        case "delegate_hermes_task", "continue_hermes_task":
            return "External work was accepted by the Hermes agent task queue."
        case "get_hermes_task", "list_hermes_tasks":
            return "Hermes agent task state was refreshed."
        case "resolve_hermes_report_offer":
            return reply.hermesAgentTask?.reportDecision == .accepted
                ? "The participant accepted the pending Hermes report and its result was returned."
                : "The participant declined the pending Hermes report."
        case "cancel_hermes_task":
            return "The Hermes agent task was cancelled."
        case "observe_host_screen":
            return reply.hostComputer?.screen == nil
                ? "The current host screen could not be observed."
                : "A short-lived current host-screen image was acquired."
        case "control_host_computer":
            return "One explicit administrator host-input action completed."
        default:
            if let reason = reply.decision?.reason, !reason.isEmpty {
                return "The embodied cognitive action completed: \(bounded(reason))"
            }
            return "The cognitive tool action completed successfully."
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func semanticRequestFingerprint(
        toolName: String,
        arguments: [String: Any]
    ) -> String {
        let payload: [String: Any] = [
            "tool": toolName,
            "arguments": Self.semanticArguments(arguments),
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            ?? Data("unencodable".utf8)
        return Self.sha256(data)
    }

    private static func semanticArguments(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, entry in
                guard entry.key != "request_id", entry.key != "reason" else { return }
                result[entry.key] = semanticArguments(entry.value)
            }
        }
        if let array = value as? [Any] {
            return array.map(semanticArguments)
        }
        return value
    }

    private func personContextOperation(forTool name: String) -> PersonContextIPCOperation? {
        switch name {
        case "get_person_context": .get
        case "set_preferred_language": .setPreferredLanguage
        case "clear_preferred_language": .clearPreferredLanguage
        case "set_contact_preference": .setContactPreference
        case "set_person_rapport": .setRapport
        case "set_person_fact": .setFact
        case "remove_person_fact": .removeFact
        case "recall_episodes": .recallEpisodes
        default: nil
        }
    }

    /// Projects only the fields a given tool actually returns, so the model
    /// never sees unrelated L0 internals (e.g. a person-context reply does not
    /// leak the embodiment snapshot).
    private func toolResult(_ reply: EmbodimentIPCReply, for toolName: String) -> [String: Any] {
        var projected: [String: Any] = ["ok": reply.ok]
        if let error = reply.error { projected["error"] = error }
        switch toolName {
        case "get_robot_body_state", "list_scene_entities", "get_spatial_map":
            if let snapshot = reply.snapshot { projected["snapshot"] = try? jsonObject(snapshot) }
        case "get_activity_overview":
            if let overview = reply.activityOverview {
                projected["activity_overview"] = try? jsonObject(overview)
            }
        case "observe_host_screen", "control_host_computer":
            if let hostComputer = reply.hostComputer {
                projected["host_computer"] = try? jsonObject(hostComputer)
            }
        case "get_view_capture":
            if let resource = reply.viewResource { projected["view_resource"] = try? jsonObject(resource) }
        case "list_present_people", "list_identity_registry":
            if let roster = reply.identityRoster { projected["identity_roster"] = try? jsonObject(roster) }
        case "enroll_present_identity":
            if let enrollment = reply.identityEnrollment { projected["identity_enrollment"] = try? jsonObject(enrollment) }
        case "get_person_context", "set_preferred_language", "clear_preferred_language",
             "set_contact_preference", "set_person_rapport", "set_person_fact", "remove_person_fact":
            if let context = reply.personContext { projected["person_context"] = try? jsonObject(context) }
        case "recall_episodes":
            projected["recalled_episodes"] = reply.recalledEpisodes ?? []
        case "list_information_needs", "record_information_need_answer":
            if let needs = reply.informationNeeds { projected["information_needs"] = try? jsonObject(needs) }
        case "delegate_hermes_task", "continue_hermes_task", "get_hermes_task",
             "list_hermes_tasks", "cancel_hermes_task", "resolve_hermes_report_offer":
            if let task = reply.hermesAgentTask { projected["hermes_agent_task"] = try? jsonObject(task) }
        case "capture_view":
            if let decision = reply.decision { projected["decision"] = try? jsonObject(decision) }
            if let resource = reply.viewResource { projected["view_resource"] = try? jsonObject(resource) }
        default:
            if let decision = reply.decision { projected["decision"] = try? jsonObject(decision) }
        }
        let text = (try? JSONSerialization.data(withJSONObject: projected, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        var content: [[String: Any]] = [["type": "text", "text": text]]
        if let resource = reply.viewResource,
           resource.state == .ready,
           let imagePath = resource.imagePath,
           let mimeType = resource.mimeType {
            if let image = imageContent(path: imagePath, mimeType: mimeType) {
                content.append(image)
            }
            content.append([
                "type": "resource_link",
                "name": "SOMA view \(resource.requestID)",
                "uri": URL(fileURLWithPath: imagePath).absoluteString,
                "mimeType": mimeType,
            ])
        }
        if let screen = reply.hostComputer?.screen {
            if let image = imageContent(path: screen.imagePath, mimeType: screen.mimeType) {
                content.append(image)
            }
            content.append([
                "type": "resource_link",
                "name": "Current host screen",
                "uri": URL(fileURLWithPath: screen.imagePath).absoluteString,
                "mimeType": screen.mimeType,
            ])
        }
        return [
            "content": content,
            "structuredContent": projected,
            "isError": !reply.ok,
        ]
    }

    private func imageContent(path: String, mimeType: String) -> [String: Any]? {
        let supportedTypes: Set<String> = ["image/jpeg", "image/png", "image/webp"]
        let maximumBytes = 8 * 1_048_576
        guard supportedTypes.contains(mimeType.lowercased()),
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let fileType = attributes[.type] as? FileAttributeType,
              fileType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              size.intValue > 0,
              size.intValue <= maximumBytes,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe]),
              data.count <= maximumBytes else {
            return nil
        }
        return [
            "type": "image",
            "data": data.base64EncodedString(),
            "mimeType": mimeType.lowercased(),
        ]
    }

    private func toolFailure(_ message: String) -> [String: Any] {
        let safe = bounded(message)
        return [
            "content": [["type": "text", "text": safe]],
            "structuredContent": ["ok": false, "error": safe],
            "isError": true,
        ]
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: encoder.encode(value))
    }

    private func write(result: [String: Any], id: Any) {
        writeJSON(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func write(error code: Int, message: String, id: Any) {
        writeJSON([
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": code, "message": bounded(message)],
        ])
    }

    private func writeJSON(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }

    private func bounded(_ message: String) -> String { String(message.prefix(240)) }

    private var knownToolNames: Set<String> {
        return [
            "end_conversation",
            "get_robot_body_state",
            "get_activity_overview",
            "observe_host_screen",
            "control_host_computer",
            "list_scene_entities",
            "get_spatial_map",
            "get_view_capture",
            "list_present_people",
            "list_identity_registry",
            "enroll_present_identity",
            "register_semantic_target",
            "remove_semantic_target",
            "set_attention_policy",
            "track_target",
            "orient_to",
            "set_exploration_policy",
            "capture_view",
            "set_camera_optical_zoom",
            "set_audio_capture_mode",
            "set_audio_input_gain",
            "set_camera_white_balance",
            "set_camera_exposure_lock",
            "set_camera_focus",
            "set_camera_absolute_exposure",
            "set_camera_face_priority",
            "set_camera_anti_flicker",
            "set_camera_image_tuning",
            "set_native_human_tracking_policy",
            "set_camera_field_of_view",
            "express_gimbal",
            "release_embodiment",
            "get_person_context",
            "set_preferred_language",
            "clear_preferred_language",
            "set_contact_preference",
            "set_person_rapport",
            "set_person_fact",
            "remove_person_fact",
            "recall_episodes",
            "list_information_needs",
            "record_information_need_answer",
            "delegate_hermes_task",
            "continue_hermes_task",
            "get_hermes_task",
            "list_hermes_tasks",
            "cancel_hermes_task",
            "resolve_hermes_report_offer",
        ]
    }

    /// Every MCP operation is bound to one currently speaking participant.
    /// L0 validates the opaque token; a model cannot select another person's
    /// context or obtain motor authority merely by changing an argument.
    private var protectedToolNames: Set<String> { knownToolNames }

    private func toolDefinitions() -> [[String: Any]] {
        embodimentStateTools()
            + hostComputerTools()
            + conversationTools()
            + identityTools()
            + personContextTools()
            + informationNeedTools()
            + hermesAgentTools()
            + embodimentControlTools()
    }

    private func embodimentStateTools() -> [[String: Any]] {
        [
            tool("get_robot_body_state", L2TaskRoutingPolicy.embodimentStateToolDescription, objectSchema([:], required: []), readOnly: true),
            tool("get_activity_overview", L2TaskRoutingPolicy.activityOverviewToolDescription, objectSchema([:], required: []), readOnly: true),
            tool("list_scene_entities", "Read the bounded scalar projection of L0's persistent scene entities and semantic bindings for this interaction.", objectSchema([:], required: []), readOnly: true),
            tool("get_spatial_map", "Read L0's bounded spherical coverage atlas, rolling panorama status, remembered scene bearings, and shared gimbal reachability envelope.", objectSchema([:], required: []), readOnly: true),
            tool("get_view_capture", "Read one short-lived capture result by request ID.", objectSchema([
                "request_id": stringSchema(maxLength: 96),
            ], required: ["request_id"]), readOnly: true),
        ]
    }

    private func hostComputerTools() -> [[String: Any]] {
        [
            tool(
                "observe_host_screen",
                "Administrator-only: capture the Mac's current main display as a short-lived image after an explicit request to inspect what is on screen. This is not the OBSBOT camera. Use it before coordinate input and use returned pixel/coordinate dimensions to reason about the display.",
                objectSchema([:], required: []),
                readOnly: true
            ),
            tool(
                "control_host_computer",
                "Administrator-only: perform exactly one immediate pointer, scroll, text, or supported-key action on the Mac after an explicit request. Observe the current screen first when coordinates matter. Use Hermes instead for shell, files, repositories, research, services, or multi-step background work.",
                objectSchema([
                    "action": hostComputerActionSchema(),
                ], required: ["action"])
            ),
        ]
    }

    private func conversationTools() -> [[String: Any]] {
        [
            tool("end_conversation", "End this current Live Voice conversation immediately after the participant explicitly asks to stop, be quiet, or end it. This cannot affect any other session. Call it silently because the audio transport closes at once.", objectSchema([:], required: [])),
        ]
    }

    private func identityTools() -> [[String: Any]] {
        [
            tool("list_present_people", "Administrator-only: compare recently observed faces with local registered identities and return the current non-biometric presence projection. Unknown people remain unnamed.", objectSchema([:], required: []), readOnly: true),
            tool("list_identity_registry", "Administrator-only: list locally registered person-context records, including explicit name, language, rapport, and facts but never face embeddings or raw transcripts.", objectSchema([:], required: []), readOnly: true),
            tool("enroll_present_identity", "Administrator-only: promote one currently present, already-confirmed anonymous identity into a persistent local face-recognition profile. Call only after explicit consent or confirmation from the person; then store their explicitly stated name/language with the person-context tools.", objectSchema([
                "person_entity_id": uuidSchema(),
                "confirmed_by_user": ["type": "boolean", "const": true],
            ], required: ["person_entity_id", "confirmed_by_user"])),
        ]
    }

    private func personContextTools() -> [[String: Any]] {
        [
            tool("get_person_context", "Read the current participant's remote-shareable language, contact, rapport, and factual context. Administrator sessions may read an explicitly supplied registered identity from list_identity_registry; participant sessions remain limited to their own reference. It never returns a face embedding, raw transcript, or local-only identity record.", objectSchema([
                "person_entity_id": uuidSchema(),
            ], required: ["person_entity_id"]), readOnly: true),
            tool("set_preferred_language", "Persist a person's stated BCP-47 language preference. Call only after the person explicitly states or confirms it.", objectSchema([
                "person_entity_id": uuidSchema(),
                "language_tag": stringSchema(maxLength: 35),
                "confirmed_by_user": ["type": "boolean", "const": true],
            ], required: ["person_entity_id", "language_tag", "confirmed_by_user"])),
            tool("clear_preferred_language", "Remove a person's previously stated language preference after explicit confirmation.", objectSchema([
                "person_entity_id": uuidSchema(),
                "confirmed_by_user": ["type": "boolean", "const": true],
            ], required: ["person_entity_id", "confirmed_by_user"])),
            tool("set_contact_preference", "Persist a person's explicit preference about proactive contact. This is social context, not motor authority.", objectSchema([
                "person_entity_id": uuidSchema(),
                "proactive_contact": ["type": "string", "enum": ProactiveContactPreference.allCases.map(\.rawValue)],
                "confirmed_by_user": ["type": "boolean", "const": true],
            ], required: ["person_entity_id", "proactive_contact", "confirmed_by_user"])),
            tool("set_person_rapport", "Persist explicitly confirmed rapport settings for one person. Do not infer values from a single utterance.", objectSchema([
                "person_entity_id": uuidSchema(),
                "familiarity": numberSchema(minimum: 0, maximum: 1),
                "interaction_comfort": numberSchema(minimum: 0, maximum: 1),
                "communication_alignment": numberSchema(minimum: 0, maximum: 1),
                "proactive_contact": ["type": "string", "enum": ProactiveContactPreference.allCases.map(\.rawValue)],
                "confirmed_by_user": ["type": "boolean", "const": true],
            ], required: ["person_entity_id", "familiarity", "interaction_comfort", "communication_alignment", "proactive_contact", "confirmed_by_user"])),
            tool("set_person_fact", "Persist one person fact only when the person explicitly gives or confirms it. For language use set_preferred_language instead.", objectSchema([
                "person_entity_id": uuidSchema(),
                "key": stringSchema(maxLength: 64),
                "value": stringSchema(maxLength: 1024),
                "confirmed_by_user": ["type": "boolean", "const": true],
            ], required: ["person_entity_id", "key", "value", "confirmed_by_user"])),
            tool("remove_person_fact", "Remove a person fact after explicit correction or deletion request.", objectSchema([
                "person_entity_id": uuidSchema(),
                "key": stringSchema(maxLength: 64),
                "confirmed_by_user": ["type": "boolean", "const": true],
            ], required: ["person_entity_id", "key", "confirmed_by_user"])),
            tool("recall_episodes", "Recall past conversation episodes relevant to a query. This is SOMA's own memory; which person a memory relates to is inferred from context, so person_entity_id is optional (omit to search all of SOMA's memory). Returns narrative summaries only, never raw transcripts.", objectSchema([
                "person_entity_id": uuidSchema(),
                "query": stringSchema(maxLength: 512),
            ], required: ["query"])),
        ]
    }

    private func informationNeedTools() -> [[String: Any]] {
        [
            tool("list_information_needs", "Read L1's currently unresolved durable information needs for one person, sorted from highest expected information gain. Use this as the real curiosity queue; do not invent checklist items from an empty profile.", objectSchema([
                "person_entity_id": uuidSchema(),
            ], required: ["person_entity_id"]), readOnly: true),
            tool("record_information_need_answer", "Store an explicitly learned answer as a durable person fact, then close that exact L1 information need in one MCP operation. Call only after the person actually answers; never infer, guess, or close a need because of an image or silence.", objectSchema([
                "person_entity_id": uuidSchema(),
                "motive_id": uuidSchema(),
                "acquired_fact": stringSchema(maxLength: 1024),
            ], required: ["person_entity_id", "motive_id", "acquired_fact"])),
        ]
    }

    private func hermesAgentTools() -> [[String: Any]] {
        [
            tool("delegate_hermes_task", L2TaskRoutingPolicy.hermesDelegationToolDescription, objectSchema([
                "title": stringSchema(maxLength: 160),
                "objective": stringSchema(maxLength: 24_000),
                "working_directory": stringSchema(maxLength: 1_024),
            ], required: ["title", "objective"])),
            tool("continue_hermes_task", "Continue a completed, failed, or input-blocked Hermes task in its preserved worker session after an explicit administrator request.", objectSchema([
                "task_id": uuidSchema(),
                "objective": stringSchema(maxLength: 24_000),
                "title": stringSchema(maxLength: 160),
            ], required: ["task_id", "objective"])),
            tool("get_hermes_task", "Read the current status and actual result of one delegated Hermes task.", objectSchema([
                "task_id": uuidSchema(),
            ], required: ["task_id"]), readOnly: true),
            tool("list_hermes_tasks", "List recent delegated Hermes tasks, optionally filtered by status. Completed entries contain the actual worker result.", objectSchema([
                "statuses": [
                    "type": "array", "maxItems": HermesAgentTaskStatus.allCases.count,
                    "items": ["type": "string", "enum": HermesAgentTaskStatus.allCases.map(\.rawValue)],
                ],
            ], required: []), readOnly: true),
            tool("cancel_hermes_task", "Cancel one queued or running Hermes task after an explicit administrator request.", objectSchema([
                "task_id": uuidSchema(),
            ], required: ["task_id"])),
            tool("resolve_hermes_report_offer", "Resolve the one controller-authorized pending Hermes report offer after the administrator clearly accepts or declines it. Set wants_report=true only after acceptance; the tool then returns the actual result to report. Set false after a decline and do not reveal the result. Never call this without the matching pending report-offer context.", objectSchema([
                "task_id": uuidSchema(),
                "wants_report": ["type": "boolean"],
            ], required: ["task_id", "wants_report"])),
        ]
    }

    private func embodimentControlTools() -> [[String: Any]] {
        [
            tool("register_semantic_target", "Register a stable semantic target label or visual query with L0.", objectSchema([
                "registration": registrationSchema(),
            ], required: ["registration"])),
            tool("remove_semantic_target", "Remove a semantic target owned by the caller.", objectSchema([
                "target_reference": stringSchema(maxLength: 96),
            ], required: ["target_reference"])),
            tool("set_attention_policy", "Set probabilistic target priors, commitment, novelty, habituation, and dwell policy.", objectSchema([
                "policy": attentionPolicySchema(),
            ], required: ["policy"])),
            tool("track_target", "Lease tracking of one registered, scene-grounded semantic target through L0.", objectSchema([
                "goal": trackGoalSchema(),
            ], required: ["goal"])),
            tool("orient_to", "Lease orientation toward a gimbal-home-relative spherical bearing through L0.", objectSchema([
                "goal": orientGoalSchema(),
            ], required: ["goal"])),
            tool("set_exploration_policy", "Lease an exploration distribution over regions, bearings, tempo, dwell, novelty, and continuity.", objectSchema([
                "policy": explorationPolicySchema(),
            ], required: ["policy"])),
            tool("capture_view", "Capture a view and return it as MCP image content plus a short-lived local resource link. Use goal.current_frame=true for the immediate current camera frame without moving the gimbal; use target_reference or bearing only when a reframed view is needed.", objectSchema([
                "goal": captureGoalSchema(),
            ], required: ["goal"])),
            tool("set_camera_optical_zoom", "Set a physical camera zoom factor for a concrete detail-observation goal. L0 verifies the active device's reported factor and updates spatial projection before using later frames. Use 1.0 to restore the wide view.", objectSchema([
                "goal": opticalZoomGoalSchema(),
            ], required: ["goal"])),
            tool("set_audio_capture_mode", "Choose the physical microphone capture mode for a concrete listening task. spatial_stereo preserves sound-direction evidence; conversation_front prioritizes a person already in front of the camera. L0 verifies the selected device mode.", objectSchema([
                "goal": audioCaptureModeGoalSchema(),
            ], required: ["goal"])),
            tool("set_audio_input_gain", "Set microphone input gain for a specific listening task. This changes input level without changing spatial capture mode or moving the gimbal. L0 verifies firmware readback.", objectSchema([
                "goal": audioInputGainGoalSchema(),
            ], required: ["goal"])),
            tool("set_camera_white_balance", "Set camera white balance for a concrete visual task. auto retains adaptive color; manual locks a Kelvin temperature for stable repeated observations. L0 verifies the firmware-reported state before accepting later visual evidence.", objectSchema([
                "goal": cameraWhiteBalanceGoalSchema(),
            ], required: ["goal"])),
            tool("set_camera_exposure_lock", "Hold the camera's current automatic exposure for a stable visual observation, or release it back to automatic exposure. This does not take a gimbal lease; L0 verifies the firmware-reported setting.", objectSchema([
                "goal": cameraExposureLockGoalSchema(),
            ], required: ["goal"])),
            tool("set_camera_focus", "Set automatic focus or one explicit manual focal position for a bounded close inspection. This does not move the gimbal; L0 verifies the firmware-reported mode and position.", objectSchema([
                "goal": cameraFocusGoalSchema(),
            ], required: ["goal"])),
            tool("set_camera_absolute_exposure", "Return exposure to automatic mode or set one measured firmware shutter code for a specific visual task. L0 reads the active camera's permitted code range before applying it.", objectSchema([
                "goal": cameraAbsoluteExposureGoalSchema(),
            ], required: ["goal"])),
            tool("set_camera_face_priority", "Enable or disable the camera firmware's face-priority autofocus and auto-exposure. This does not select a person or move the gimbal; L0 verifies both firmware status bits.", objectSchema([
                "goal": cameraFacePriorityGoalSchema(),
            ], required: ["goal"])),
            tool("set_camera_anti_flicker", "Set the firmware anti-flicker mode for a visual observation. This does not move the gimbal; L0 verifies the reported camera setting.", objectSchema([
                "goal": cameraAntiFlickerGoalSchema(),
            ], required: ["goal"])),
            tool("set_camera_image_tuning", "Set one or more camera image controls as one verified transaction. If any requested firmware setting cannot be applied or read back, L0 restores every requested control to its original value.", objectSchema([
                "goal": cameraImageTuningGoalSchema(),
            ], required: ["goal"])),
            tool("set_native_human_tracking_policy", "Configure Tiny 3 native human tracking response, retention, and adaptive or fixed pan/pitch gain. Fixed gains require both axes and disabled adaptive gains. It changes firmware tracking behavior but does not bypass L0 target selection, gimbal safety, or motor ownership.", objectSchema([
                "goal": nativeHumanTrackingPolicyGoalSchema(),
            ], required: ["goal"])),
            tool("set_camera_field_of_view", "Set the camera's calibrated 86, 78, or 65 degree optical field of view for a concrete observation. L0 verifies firmware state and updates spherical projection before later visual evidence is interpreted.", objectSchema([
                "goal": cameraFieldOfViewGoalSchema(),
            ], required: ["goal"])),
            tool("express_gimbal", "Lease a bounded semantic social gimbal expression through L0.", objectSchema([
                "expression": ["type": "string", "enum": SocialGimbalExpression.allCases.map(\.rawValue)],
            ], required: ["expression"])),
            tool("release_embodiment", "Release this conversational goal's motor lease, attention policy, and registered targets.", objectSchema([:], required: [])),
        ]
    }

    private func tool(
        _ name: String,
        _ description: String,
        _ inputSchema: [String: Any],
        readOnly: Bool = false
    ) -> [String: Any] {
        var augmentedSchema = inputSchema
        if L2CognitiveToolPolicy.requiresModelAuthoredIntent(for: name) {
            var properties = augmentedSchema["properties"] as? [String: Any] ?? [:]
            properties["cognitive_intent"] = cognitiveIntentSchema()
            augmentedSchema["properties"] = properties
            var required = augmentedSchema["required"] as? [String] ?? []
            if !required.contains("cognitive_intent") { required.append("cognitive_intent") }
            augmentedSchema["required"] = required
        }
        return [
            "name": name,
            "description": description,
            "inputSchema": augmentedSchema,
            "annotations": [
                "readOnlyHint": readOnly,
                "destructiveHint": false,
                "idempotentHint": readOnly || name == "release_embodiment",
                "openWorldHint": false,
            ],
        ]
    }

    private static func environmentSessionAuthorization() -> String? {
        guard let value = ProcessInfo.processInfo.environment["SOMA_SESSION_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              value.count == 36,
              value.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || $0 == "-"
              }) else {
            return nil
        }
        return value
    }

    private func cognitiveIntentSchema() -> [String: Any] {
        objectSchema([
            "goal_episode_id": uuidSchema(),
            "purpose": stringSchema(maxLength: 512),
            "expected_information_gain": numberSchema(minimum: 0, maximum: 1),
            "evidence_ids": [
                "type": "array",
                "maxItems": 32,
                "items": stringSchema(maxLength: 256),
            ],
            "authorization_basis": [
                "type": "string",
                "enum": L2CognitiveAuthorizationBasis.allCases.map(\.rawValue),
            ],
        ], required: ["goal_episode_id", "purpose", "expected_information_gain", "authorization_basis"])
    }

    private func hostComputerActionSchema() -> [String: Any] {
        var schema = objectSchema([
            "kind": ["type": "string", "enum": HostComputerInputKind.allCases.map(\.rawValue)],
            "x": numberSchema(minimum: 0, maximum: 1),
            "y": numberSchema(minimum: 0, maximum: 1),
            "button": ["type": "string", "enum": HostComputerPointerButton.allCases.map(\.rawValue)],
            "delta_x": ["type": "integer", "minimum": -2_000, "maximum": 2_000],
            "delta_y": ["type": "integer", "minimum": -2_000, "maximum": 2_000],
            "text": stringSchema(maxLength: 1_024),
            "key": ["type": "string", "enum": HostComputerKey.allCases.map(\.rawValue)],
            "modifiers": [
                "type": "array",
                "maxItems": 5,
                "uniqueItems": true,
                "items": ["type": "string", "enum": HostComputerKeyModifier.allCases.map(\.rawValue)],
            ],
        ], required: ["kind"])
        schema["oneOf"] = [
            ["properties": ["kind": ["const": HostComputerInputKind.movePointer.rawValue]], "required": ["x", "y"]],
            ["properties": ["kind": ["const": HostComputerInputKind.click.rawValue]], "required": ["x", "y"]],
            ["properties": ["kind": ["const": HostComputerInputKind.doubleClick.rawValue]], "required": ["x", "y"]],
            ["properties": ["kind": ["const": HostComputerInputKind.scroll.rawValue]], "anyOf": [["required": ["delta_x"]], ["required": ["delta_y"]]]],
            ["properties": ["kind": ["const": HostComputerInputKind.typeText.rawValue]], "required": ["text"]],
            ["properties": ["kind": ["const": HostComputerInputKind.pressKey.rawValue]], "required": ["key"]],
        ]
        return schema
    }

    private func registrationSchema() -> [String: Any] {
        var schema = objectSchema([
            "target_reference": stringSchema(maxLength: 96),
            "scene_id": stringSchema(maxLength: 96),
            "label": stringSchema(maxLength: 96),
            "aliases": ["type": "array", "maxItems": 12, "items": stringSchema(maxLength: 96)],
            "visual_query": stringSchema(maxLength: 240),
            "expected_kind": ["type": "string", "enum": ["human", "object", "unknown"]],
            "initial_selection_log_prior": numberSchema(minimum: -12, maximum: 12),
        ], required: ["target_reference", "label", "aliases", "initial_selection_log_prior"])
        schema["anyOf"] = [
            ["required": ["scene_id"]],
            ["required": ["visual_query"]],
        ]
        return schema
    }

    private func attentionPolicySchema() -> [String: Any] {
        objectSchema([
            "targets": [
                "type": "array", "maxItems": 64,
                "items": objectSchema([
                    "target_reference": stringSchema(maxLength: 96),
                    "selection_log_prior": numberSchema(minimum: -12, maximum: 12),
                    "tracking_commitment": numberSchema(minimum: 0, maximum: 1),
                ], required: ["target_reference", "selection_log_prior", "tracking_commitment"]),
            ],
            "selection_temperature": numberSchema(minimum: 0.1, maximum: 5),
            "novelty_strength": numberSchema(minimum: 0, maximum: 1),
            "habituation_strength": numberSchema(minimum: 0, maximum: 1),
            "minimum_dwell_milliseconds": ["type": "integer", "minimum": 0, "maximum": 60_000],
            "maximum_dwell_milliseconds": ["type": "integer", "minimum": 0, "maximum": 60_000],
        ], required: ["targets", "selection_temperature", "novelty_strength", "habituation_strength", "minimum_dwell_milliseconds", "maximum_dwell_milliseconds"])
    }

    private func trackGoalSchema() -> [String: Any] {
        objectSchema([
            "target_reference": stringSchema(maxLength: 96),
            "framing": rectSchema(),
            "reacquire_if_occluded": ["type": "boolean"],
            "motion_style": motionStyleSchema(),
        ], required: ["target_reference", "reacquire_if_occluded", "motion_style"])
    }

    private func orientGoalSchema() -> [String: Any] {
        objectSchema([
            "bearing": bearingSchema(),
            "tolerance_degrees": numberSchema(minimum: 0.5, maximum: 30),
            "motion_style": motionStyleSchema(),
        ], required: ["bearing", "tolerance_degrees", "motion_style"])
    }

    private func explorationPolicySchema() -> [String: Any] {
        objectSchema([
            "mode": ["type": "string", "enum": ExplorationMode.allCases.map(\.rawValue)],
            "regions": [
                "type": "array", "maxItems": 32,
                "items": objectSchema([
                    "center": bearingSchema(),
                    "azimuth_radius_degrees": numberSchema(minimum: 1, maximum: 180),
                    "elevation_radius_degrees": numberSchema(minimum: 1, maximum: 90),
                    "preference": numberSchema(minimum: -1, maximum: 1),
                ], required: ["center", "azimuth_radius_degrees", "elevation_radius_degrees", "preference"]),
            ],
            "preferred_directions": [
                "type": "array", "maxItems": 32,
                "items": objectSchema([
                    "bearing": bearingSchema(),
                    "concentration": numberSchema(minimum: 0.1, maximum: 50),
                    "weight": ["type": "number", "exclusiveMinimum": 0],
                ], required: ["bearing", "concentration", "weight"]),
            ],
            "coverage_strength": numberSchema(minimum: 0, maximum: 1),
            "novelty_strength": numberSchema(minimum: 0, maximum: 1),
            "memory_gap_strength": numberSchema(minimum: 0, maximum: 1),
            "motion_continuity": numberSchema(minimum: 0, maximum: 1),
            "tempo": numberSchema(minimum: 0, maximum: 1),
            "dwell_milliseconds": ["type": "integer", "minimum": 0, "maximum": 60_000],
        ], required: ["mode", "regions", "preferred_directions", "coverage_strength", "novelty_strength", "memory_gap_strength", "motion_continuity", "tempo", "dwell_milliseconds"])
    }

    private func captureGoalSchema() -> [String: Any] {
        var schema = objectSchema([
            "target_reference": stringSchema(maxLength: 96),
            "bearing": bearingSchema(),
            "field_of_view_degrees": numberSchema(minimum: 5, maximum: 120),
            "current_frame": ["type": "boolean", "const": true],
        ], required: [])
        schema["anyOf"] = [
            ["required": ["target_reference"]],
            ["required": ["bearing"]],
            ["required": ["current_frame"]],
        ]
        return schema
    }

    private func opticalZoomGoalSchema() -> [String: Any] {
        objectSchema([
            "factor": numberSchema(minimum: 1, maximum: 2),
        ], required: ["factor"])
    }

    private func audioCaptureModeGoalSchema() -> [String: Any] {
        objectSchema([
            "mode": ["type": "string", "enum": MicrophoneCaptureMode.allCases.map(\.rawValue)],
        ], required: ["mode"])
    }

    private func audioInputGainGoalSchema() -> [String: Any] {
        objectSchema([
            "percent": ["type": "integer", "minimum": 0, "maximum": 100],
        ], required: ["percent"])
    }

    private func cameraWhiteBalanceGoalSchema() -> [String: Any] {
        objectSchema([
            "mode": ["type": "string", "enum": CameraWhiteBalanceMode.allCases.map(\.rawValue)],
            "temperatureKelvin": ["type": "integer", "minimum": 2_000, "maximum": 9_000],
        ], required: ["mode"])
    }

    private func cameraExposureLockGoalSchema() -> [String: Any] {
        objectSchema([
            "locked": ["type": "boolean"],
        ], required: ["locked"])
    }

    private func cameraFocusGoalSchema() -> [String: Any] {
        objectSchema([
            "mode": ["type": "string", "enum": CameraFocusMode.allCases.map(\.rawValue)],
            "position": ["type": "integer", "minimum": 0, "maximum": 100],
        ], required: ["mode"])
    }

    private func cameraAbsoluteExposureGoalSchema() -> [String: Any] {
        objectSchema([
            "mode": ["type": "string", "enum": CameraAbsoluteExposureMode.allCases.map(\.rawValue)],
            "shutterCode": ["type": "integer", "minimum": 0, "maximum": 100],
        ], required: ["mode"])
    }

    private func cameraFacePriorityGoalSchema() -> [String: Any] {
        objectSchema([
            "enabled": ["type": "boolean"],
        ], required: ["enabled"])
    }

    private func cameraAntiFlickerGoalSchema() -> [String: Any] {
        objectSchema([
            "mode": ["type": "string", "enum": CameraAntiFlickerMode.allCases.map(\.rawValue)],
        ], required: ["mode"])
    }

    private func cameraImageTuningGoalSchema() -> [String: Any] {
        objectSchema([
            "brightness": numberSchema(minimum: 0, maximum: 100),
            "contrast": numberSchema(minimum: 0, maximum: 100),
            "hue": numberSchema(minimum: 0, maximum: 100),
            "saturation": numberSchema(minimum: 0, maximum: 100),
            "sharpness": numberSchema(minimum: 0, maximum: 100),
        ], required: [])
    }

    private func nativeHumanTrackingPolicyGoalSchema() -> [String: Any] {
        objectSchema([
            "speed": ["type": "string", "enum": NativeHumanTrackingSpeed.allCases.map(\.rawValue)],
            "motionTracking": ["type": "boolean"],
            "foreTarget": ["type": "boolean"],
            "adaptiveComposition": ["type": "boolean"],
            "adaptivePanGain": ["type": "boolean"],
            "adaptivePitchGain": ["type": "boolean"],
            "panGain": numberSchema(minimum: 0.1, maximum: 1.0),
            "pitchGain": numberSchema(minimum: 0.1, maximum: 1.0),
        ], required: ["speed", "motionTracking", "foreTarget", "adaptiveComposition"])
    }

    private func cameraFieldOfViewGoalSchema() -> [String: Any] {
        objectSchema([
            "degrees": ["type": "integer", "enum": [65, 78, 86]],
        ], required: ["degrees"])
    }

    private func bearingSchema() -> [String: Any] {
        objectSchema([
            "azimuth_degrees": numberSchema(minimum: -180, maximum: 180),
            "elevation_degrees": numberSchema(minimum: -90, maximum: 90),
        ], required: ["azimuth_degrees", "elevation_degrees"])
    }

    private func rectSchema() -> [String: Any] {
        objectSchema([
            "x": numberSchema(minimum: 0, maximum: 1),
            "y": numberSchema(minimum: 0, maximum: 1),
            "width": ["type": "number", "exclusiveMinimum": 0, "maximum": 1],
            "height": ["type": "number", "exclusiveMinimum": 0, "maximum": 1],
        ], required: ["x", "y", "width", "height"])
    }

    private func motionStyleSchema() -> [String: Any] {
        ["type": "string", "enum": EmbodimentMotionStyle.allCases.map(\.rawValue)]
    }

    private func stringSchema(maxLength: Int) -> [String: Any] {
        ["type": "string", "minLength": 1, "maxLength": maxLength]
    }

    private func uuidSchema() -> [String: Any] {
        ["type": "string", "format": "uuid", "minLength": 36, "maxLength": 36]
    }

    private func numberSchema(minimum: Double, maximum: Double) -> [String: Any] {
        ["type": "number", "minimum": minimum, "maximum": maximum]
    }

    private func objectSchema(_ properties: [String: Any], required: [String]) -> [String: Any] {
        [
            "type": "object",
            "properties": properties,
            "required": required,
            "additionalProperties": false,
        ]
    }
}

private enum Invocation {
    case server(URL)
    case runtimeShutdown(URL)
}

private func parseInvocation(_ arguments: [String]) throws -> Invocation {
    if arguments.count == 2,
       arguments[0] == "--socket",
       arguments[1].hasPrefix("/") {
        return .server(URL(fileURLWithPath: arguments[1]))
    }
    if arguments.count == 3,
       arguments[0] == "--runtime-shutdown",
       arguments[1] == "--socket",
       arguments[2].hasPrefix("/") {
        return .runtimeShutdown(URL(fileURLWithPath: arguments[2]))
    }
    throw ServerFailure.invalidArguments("usage: soma-embodiment --socket /absolute/path.sock | --runtime-shutdown --socket /absolute/path.sock")
}

do {
    switch try parseInvocation(Array(CommandLine.arguments.dropFirst())) {
    case let .server(socketURL):
        EmbodimentMCPServer(socketURL: socketURL).run()
    case let .runtimeShutdown(socketURL):
        let reply = try EmbodimentShadowSocketClient.send(
            .init(kind: .runtimeShutdown),
            socketURL: socketURL,
            timeoutSeconds: 24
        )
        guard reply.ok else {
            throw ServerFailure.protocolViolation(reply.error ?? "runtime shutdown was rejected")
        }
    }
} catch {
    FileHandle.standardError.write(Data("soma-embodiment: \(error.localizedDescription)\n".utf8))
    Foundation.exit(EXIT_FAILURE)
}
