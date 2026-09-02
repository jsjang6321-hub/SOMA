import Foundation

public enum L2ToolAutonomy: String, Codable, CaseIterable, Sendable {
    case epistemic
    case goalBoundEmbodiment = "goal_bound_embodiment"
    case groundedMemoryWrite = "grounded_memory_write"
    case explicitConsent = "explicit_consent"
    case explicitRequest = "explicit_request"
}

public enum L2CognitiveAuthorizationBasis: String, Codable, CaseIterable, Sendable {
    case autonomousGoal = "autonomous_goal"
    case explicitStatement = "explicit_statement"
    case explicitConsent = "explicit_consent"
    case explicitRequest = "explicit_request"
}

public enum CognitiveActionEffect: String, Codable, CaseIterable, Sendable {
    case epistemic
    case reversibleEmbodiment = "reversible_embodiment"
    case durableMemory = "durable_memory"
    case identityManagement = "identity_management"
    case conversationControl = "conversation_control"
    case externalWork = "external_work"
    case hostComputer = "host_computer"
}

public enum CognitiveActionStatus: String, Codable, CaseIterable, Sendable {
    case succeeded
    case failed
}

/// An explanation of why a tool call belongs to the current cognitive goal.
/// Mutating calls supply this from the model; the trusted MCP gateway creates
/// it for read-only epistemic calls so schema mechanics cannot block sensing.
public struct L2CognitiveToolIntent: Codable, Equatable, Sendable {
    public let goalEpisodeID: UUID
    public let purpose: String
    public let expectedInformationGain: Double
    public let evidenceIDs: [String]
    public let authorizationBasis: L2CognitiveAuthorizationBasis

    public init(
        goalEpisodeID: UUID,
        purpose: String,
        expectedInformationGain: Double,
        evidenceIDs: [String] = [],
        authorizationBasis: L2CognitiveAuthorizationBasis
    ) {
        self.goalEpisodeID = goalEpisodeID
        self.purpose = String(purpose.trimmingCharacters(in: .whitespacesAndNewlines).prefix(512))
        self.expectedInformationGain = expectedInformationGain.isFinite
            ? min(max(expectedInformationGain, 0), 1)
            : 0
        self.evidenceIDs = Array(evidenceIDs.uniqued().prefix(32)).map { String($0.prefix(256)) }
        self.authorizationBasis = authorizationBasis
    }
}

/// A privacy-bounded record of one completed cognitive tool action. The
/// result fingerprint permits idempotence without persisting raw tool output.
public struct CognitiveActionEpisode: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let goalEpisodeID: UUID
    public let sourceLayer: CognitiveControlLayer
    public let toolName: String
    public let effect: CognitiveActionEffect
    public let purpose: String
    public let expectedInformationGain: Double
    public let evidenceIDs: [String]
    public let status: CognitiveActionStatus
    public let resultFingerprint: String
    public let requestFingerprint: String?
    public let resultSummary: String
    public let completedAt: Date

    public init(
        id: UUID = UUID(),
        goalEpisodeID: UUID,
        sourceLayer: CognitiveControlLayer,
        toolName: String,
        effect: CognitiveActionEffect,
        purpose: String,
        expectedInformationGain: Double,
        evidenceIDs: [String] = [],
        status: CognitiveActionStatus,
        resultFingerprint: String,
        requestFingerprint: String? = nil,
        resultSummary: String,
        completedAt: Date = Date()
    ) {
        self.id = id
        self.goalEpisodeID = goalEpisodeID
        self.sourceLayer = sourceLayer
        self.toolName = String(toolName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(96))
        self.effect = effect
        self.purpose = String(purpose.trimmingCharacters(in: .whitespacesAndNewlines).prefix(512))
        self.expectedInformationGain = expectedInformationGain.isFinite
            ? min(max(expectedInformationGain, 0), 1)
            : 0
        self.evidenceIDs = Array(evidenceIDs.uniqued().prefix(32)).map { String($0.prefix(256)) }
        self.status = status
        self.resultFingerprint = String(resultFingerprint.lowercased().prefix(128))
        self.requestFingerprint = requestFingerprint.map { String($0.lowercased().prefix(128)) }
        self.resultSummary = String(resultSummary.trimmingCharacters(in: .whitespacesAndNewlines).prefix(512))
        self.completedAt = completedAt
    }

    public func isSemanticallyEquivalent(to other: Self) -> Bool {
        guard goalEpisodeID == other.goalEpisodeID,
              toolName == other.toolName,
              effect == other.effect,
              status == other.status else {
            return false
        }
        if let requestFingerprint, !requestFingerprint.isEmpty,
           let otherFingerprint = other.requestFingerprint, !otherFingerprint.isEmpty {
            return requestFingerprint == otherFingerprint
                && Set(evidenceIDs) == Set(other.evidenceIDs)
        }
        return purpose.caseInsensitiveCompare(other.purpose) == .orderedSame
            && Set(evidenceIDs) == Set(other.evidenceIDs)
            && resultFingerprint == other.resultFingerprint
    }
}

/// A privacy-bounded semantic lookup performed before a cognitive tool call.
/// It carries no tool result and cannot grant embodiment authority.
public struct CognitiveActionQuery: Codable, Equatable, Hashable, Sendable {
    public let goalEpisodeID: UUID
    public let toolName: String
    public let requestFingerprint: String
    public let evidenceIDs: [String]

    public init(
        goalEpisodeID: UUID,
        toolName: String,
        requestFingerprint: String,
        evidenceIDs: [String] = []
    ) {
        self.goalEpisodeID = goalEpisodeID
        self.toolName = String(toolName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(96))
        self.requestFingerprint = String(requestFingerprint.lowercased().prefix(128))
        self.evidenceIDs = Array(evidenceIDs.uniqued().prefix(32)).map { String($0.prefix(256)) }
    }
}

/// One source of truth for how conversational cognition may use SOMA MCP.
/// Enforcement remains in the capability store and L0 arbiter; this contract
/// tells every L2 transport when initiative is cognitively appropriate.
public enum L2CognitiveToolPolicy {
    public static let instruction = """
    Cognitive tool initiative: privately maintain one current conversational goal. Before each response, decide whether a permitted SOMA MCP action would materially reduce an uncertainty that blocks a useful answer, ground a deictic or embodied reference, advance that goal, preserve an explicitly stated durable fact, or verify completion. When it would, call the narrowest suitable tool proactively and silently; do not wait for the participant to name the tool or issue a command, do not speak a provisional wait message, and use the returned result before responding. When no tool materially helps, answer directly without a ceremonial call.

    Autonomous read-only robot perception, memory lookup, and current-state inspection are epistemic actions. Reversible camera orientation, tracking, or reframing may also be initiated when it is necessary for the active conversational goal and remains subject to L0 authority. The host Mac screen is a separate private sensor: observe_host_screen requires a current administrator request and must never be substituted for capture_view. Bounded foreground UI interaction may use control_host_computer after that same explicit request, one immediate input per call; inspect the current screen first and again after any state-changing step whose result is uncertain. Durable memory writes require an explicit fact or preference supplied or confirmed by the participant. Identity enrollment requires explicit consent. Ending the conversation and external file, shell, network, service, or system changes still require the participant's explicit request and applicable authority. When the administrator explicitly delegates external work, use delegate_hermes_task once and return its task ID immediately instead of pretending to perform the work in the voice turn. Use get_hermes_task or list_hermes_tasks to retrieve actual progress and results. Continue or cancel the external worker only on an explicit request. A controller-supplied pending_hermes_report_task_id authorizes only a yes/no report offer: after a clear answer, call resolve_hermes_report_offer exactly once with that ID and the participant's decision. Never disclose or fetch the result before acceptance.

    Every non-read-only SOMA MCP call must include cognitive_intent with one stable goal_episode_id reused across calls serving the same conversational objective, a concise private purpose, expected_information_gain from 0 to 1, only supplied evidence_ids, and authorization_basis. The trusted gateway supplies this envelope for read-only epistemic tools; do not add cognitive_intent to their arguments. Use autonomous_goal only for reversible goal-bound orientation, tracking, reframing, and expression. Use explicit_statement for a fact or preference the participant just supplied, explicit_consent for identity enrollment, and explicit_request for conversation termination or device configuration the participant explicitly requested. Generate a new goal_episode_id when the conversational objective materially changes. Never expose these fields to the participant. Do not repeat a mutating call when the same goal and semantic request already produced an equivalent result; treat tool failure as evidence and never claim an unverified result.
    """

    public static func autonomy(for toolName: String) -> L2ToolAutonomy? {
        switch toolName {
        case "get_robot_body_state", "get_activity_overview", "list_scene_entities", "get_spatial_map",
             "get_view_capture", "list_present_people", "list_identity_registry",
             "get_person_context", "recall_episodes", "list_information_needs":
            .epistemic
        case "set_preferred_language", "clear_preferred_language", "set_contact_preference",
             "set_person_rapport", "set_person_fact", "remove_person_fact",
             "record_information_need_answer":
            .groundedMemoryWrite
        case "enroll_present_identity":
            .explicitConsent
        case "end_conversation":
            .explicitRequest
        case "get_hermes_task", "list_hermes_tasks":
            .epistemic
        case "delegate_hermes_task", "continue_hermes_task", "cancel_hermes_task",
             "resolve_hermes_report_offer":
            .explicitRequest
        case "observe_host_screen", "control_host_computer":
            .explicitRequest
        case "register_semantic_target", "remove_semantic_target", "set_attention_policy",
             "track_target", "orient_to", "set_exploration_policy", "capture_view",
             "set_camera_optical_zoom", "express_gimbal",
             "release_embodiment":
            .goalBoundEmbodiment
        case "set_audio_capture_mode", "set_audio_input_gain", "set_camera_white_balance",
             "set_camera_exposure_lock", "set_camera_focus", "set_camera_absolute_exposure",
             "set_camera_face_priority", "set_camera_anti_flicker", "set_camera_image_tuning",
             "set_native_human_tracking_policy", "set_camera_field_of_view":
            .explicitRequest
        default:
            nil
        }
    }

    public static func effect(for toolName: String) -> CognitiveActionEffect? {
        switch toolName {
        case "get_robot_body_state", "get_activity_overview", "list_scene_entities", "get_spatial_map",
             "get_view_capture", "list_present_people", "list_identity_registry",
             "get_person_context", "recall_episodes", "list_information_needs":
            .epistemic
        case "set_preferred_language", "clear_preferred_language", "set_contact_preference",
             "set_person_rapport", "set_person_fact", "remove_person_fact",
             "record_information_need_answer":
            .durableMemory
        case "enroll_present_identity":
            .identityManagement
        case "end_conversation":
            .conversationControl
        case "get_hermes_task", "list_hermes_tasks":
            .epistemic
        case "delegate_hermes_task", "continue_hermes_task", "cancel_hermes_task",
             "resolve_hermes_report_offer":
            .externalWork
        case "observe_host_screen", "control_host_computer":
            .hostComputer
        default:
            autonomy(for: toolName) == nil ? nil : .reversibleEmbodiment
        }
    }

    public static func permits(
        _ basis: L2CognitiveAuthorizationBasis,
        for toolName: String
    ) -> Bool {
        switch autonomy(for: toolName) {
        case .epistemic:
            true
        case .goalBoundEmbodiment:
            basis == .autonomousGoal || basis == .explicitRequest
        case .groundedMemoryWrite:
            basis == .explicitStatement || basis == .explicitRequest
        case .explicitConsent:
            basis == .explicitConsent
        case .explicitRequest:
            basis == .explicitRequest
        case nil:
            false
        }
    }

    /// Public read schemas contain only semantic arguments. The trusted local
    /// gateway supplies the policy envelope after authenticating the session.
    public static func requiresModelAuthoredIntent(for toolName: String) -> Bool {
        autonomy(for: toolName) != .epistemic
    }

    public static func gatewayEpistemicIntent(
        for toolName: String,
        goalEpisodeID: UUID = UUID()
    ) -> L2CognitiveToolIntent? {
        guard autonomy(for: toolName) == .epistemic else { return nil }
        return L2CognitiveToolIntent(
            goalEpisodeID: goalEpisodeID,
            purpose: "Read current SOMA state through \(toolName).",
            expectedInformationGain: 0.5,
            authorizationBasis: .autonomousGoal
        )
    }

    /// Current state and memory projections may change while their semantic
    /// query remains identical. Read calls therefore never belong in the
    /// completed-action deduplication cache. Task creation has its own durable
    /// idempotency key in the coordinator.
    public static func usesSemanticDeduplication(for toolName: String) -> Bool {
        guard autonomy(for: toolName) != .epistemic else { return false }
        return ![
            "observe_host_screen",
            "delegate_hermes_task",
            "continue_hermes_task",
            "get_hermes_task",
            "list_hermes_tasks",
            "cancel_hermes_task",
            "resolve_hermes_report_offer",
        ].contains(toolName)
    }
}

/// Keeps conversational, embodied, and external work in distinct execution
/// domains. Hermes availability means eligible administrator work is routed to
/// the durable worker without blocking the live social channel; it does not
/// turn ordinary conversation into background jobs.
public enum L2TaskRoutingPolicy {
    public static let embodimentStateToolDescription = "Read only SOMA's robot-body state: L0 lease, camera/gimbal attention target, and attention policy for this interaction. This is not the host Mac's OS, CPU, memory, filesystem, process, network, or service state."

    public static let hermesDelegationToolDescription = "Delegate an administrator's explicit external job to the local Hermes Agent when it requires shell or process work, files or repositories, coding, web or API research, services, or multi-step work that can continue while the voice conversation remains responsive. Returns immediately with a durable task ID; acceptance is not completion. Use observe_host_screen/control_host_computer only for an immediate visible UI interaction, and never use this for SOMA camera/gimbal state."

    public static let activityOverviewToolDescription = "Administrator-only: read a compact current overview of SOMA's robot-body state and delegated Hermes task activity. Use this for an ambiguous request such as 'what are you doing?' or 'status report'. It omits worker result contents. Use get_robot_body_state for a specifically physical camera/gimbal question, list_hermes_tasks for delegated-work details, and delegate_hermes_task for host-Mac inspection."

    public static func instruction(hermesEnabled: Bool) -> String {
        guard hermesEnabled else {
            return "External task routing: Hermes delegation is disabled for this session. Never claim that external work was queued or completed. Continue to use only conversational reasoning and the available SOMA memory and embodiment tools."
        }
        return """
        External task routing: before responding to an administrator's explicit request, classify the requested outcome into exactly one execution domain. A direct answer stays in conversation. SOMA perception, memory, camera, gimbal, and attention use the narrow SOMA tools. A bounded foreground visible Mac UI interaction uses observe_host_screen and control_host_computer. Work requiring operating-system or resource inspection, shell commands, processes, files, repositories, coding, web or API research, services, or material work that can proceed independently belongs to the Hermes external-worker domain. The administrator does not need to say the word Hermes.

        Route status requests by their subject. For SOMA's physical camera, gimbal, attention, or tracking state, use get_robot_body_state. For delegated work progress or results, use list_hermes_tasks. For an ambiguous administrator request such as 'what are you doing?' or 'status report', use get_activity_overview. Use observe_host_screen only when the administrator explicitly asks about the visible display. For the host Mac's CPU, memory, processes, files, network, services, or an inspection that has not already been delegated, create a Hermes job. Do not substitute screen pixels or get_robot_body_state for host-computer status.

        For an eligible external job, call delegate_hermes_task exactly once before speaking. After the delegation tool returns successfully, acknowledge aloud in one short sentence that the computer supervisor accepted the work and that completion will be reported, then keep listening and converse normally while the worker runs. Do not read the task UUID aloud. Do not block, poll, or send a provisional wait message. Completion is delivered separately and must be reported only from the actual task result. Reuse the same goal_episode_id so one request cannot create duplicate workers.
        """
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
