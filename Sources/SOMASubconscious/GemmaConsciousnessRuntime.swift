import Foundation
import SOMACore

private enum GemmaConsciousnessRuntimeError: LocalizedError {
    case invalidEndpoint
    case requestEncoding
    case transport(String)
    case responseStatus(Int)
    case missingResponse
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "consciousness_endpoint_invalid"
        case .requestEncoding: "consciousness_request_encoding_failed"
        case let .transport(message): "consciousness_transport_\(message)"
        case let .responseStatus(status): "consciousness_http_\(status)"
        case .missingResponse: "consciousness_response_missing"
        case let .invalidResponse(message): "consciousness_response_invalid_\(message)"
        }
    }
}

/// One shared, strictly single-flight transport for the two cognitive roles.
/// Executive work always runs before event reflection, which always runs before
/// periodic reflection. Event and periodic requests coalesce to their newest
/// workspace snapshot; intention episodes remain distinct and ordered.
final class GemmaConsciousnessRuntime: @unchecked Sendable {
    typealias ThoughtCompletion = @Sendable (
        L1ThoughtRequest,
        Result<L1ThoughtUpdate, Error>,
        UInt64
    ) -> Void
    typealias ExecutiveCompletion = @Sendable (
        L1ExecutiveRequest,
        Result<L1ExecutiveDecision, Error>,
        UInt64
    ) -> Void

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [Message]
        let stream = false
        let think = false
        let format = "json"
        let options: Options

        struct Message: Encodable {
            let role: String
            let content: String
            let images: [String]?
        }

        struct Options: Encodable {
            let temperature: Double
            let numPredict: Int

            enum CodingKeys: String, CodingKey {
                case temperature
                case numPredict = "num_predict"
            }
        }
    }

    private struct ChatResponse: Decodable {
        struct Message: Decodable { let content: String? }
        let message: Message?
        let response: String?
    }

    private let queue = DispatchQueue(label: "soma.l1.consciousness-transport", qos: .utility)
    private let session: URLSession
    private let endpoint: URL
    private let configuration: L1ModelConfiguration
    private let onHealth: @Sendable (String, String) -> Void
    private let thoughtCompletion: ThoughtCompletion
    private let executiveCompletion: ExecutiveCompletion

    private var task: URLSessionDataTask?
    private var inFlight: L1ConsciousnessWorkItem?
    private var workQueue = L1ConsciousnessWorkQueue()
    private var stopped = false

    init(
        configuration: L1ModelConfiguration = .gemma31,
        endpoint: URL? = nil,
        onHealth: @escaping @Sendable (String, String) -> Void,
        thoughtCompletion: @escaping ThoughtCompletion,
        executiveCompletion: @escaping ExecutiveCompletion
    ) throws {
        let resolvedEndpoint: URL
        if let endpoint {
            resolvedEndpoint = endpoint
        } else if let raw = ProcessInfo.processInfo.environment["SOMA_L1_OLLAMA_ENDPOINT"],
                  let configured = URL(string: raw) {
            resolvedEndpoint = configured
        } else {
            resolvedEndpoint = URL(string: "http://127.0.0.1:11434/api/chat")!
        }
        guard ["http", "https"].contains(resolvedEndpoint.scheme?.lowercased() ?? ""),
              resolvedEndpoint.host != nil else {
            throw GemmaConsciousnessRuntimeError.invalidEndpoint
        }
        self.endpoint = resolvedEndpoint
        self.configuration = configuration
        self.onHealth = onHealth
        self.thoughtCompletion = thoughtCompletion
        self.executiveCompletion = executiveCompletion

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        let timeout = TimeInterval(configuration.deadlineMilliseconds(for: .situation)) / 1_000
        sessionConfiguration.timeoutIntervalForRequest = timeout
        sessionConfiguration.timeoutIntervalForResource = timeout + 2
        session = URLSession(configuration: sessionConfiguration)
        onHealth(
            "consciousness_configured",
            "model=\(configuration.model); queue=executive,event,periodic; single_in_flight=true"
        )
    }

    func submitThought(_ request: L1ThoughtRequest) {
        queue.async { [weak self] in
            guard let self, !stopped else { return }
            workQueue.enqueue(request)
            startNextIfIdle()
        }
    }

    func submitExecutive(_ request: L1ExecutiveRequest) {
        queue.async { [weak self] in
            guard let self, !stopped else { return }
            let alreadyRunning: Bool
            if case let .executive(active)? = inFlight {
                alreadyRunning = active.intention.id == request.intention.id
            } else {
                alreadyRunning = false
            }
            workQueue.enqueue(
                request,
                excludingActiveIntentionID: alreadyRunning ? request.intention.id : nil
            )
            startNextIfIdle()
        }
    }

    func stop() {
        queue.sync {
            stopped = true
            workQueue.removeAll()
            task?.cancel()
            task = nil
            inFlight = nil
            session.invalidateAndCancel()
        }
    }

    private func startNextIfIdle() {
        guard !stopped, task == nil, inFlight == nil else { return }
        guard let work = workQueue.dequeue() else { return }
        inFlight = work
        start(work, retryCount: 1)
    }

    private func start(_ work: L1ConsciousnessWorkItem, retryCount: Int) {
        let systemPrompt: String
        let packet: String
        let binding: String
        let images: [String]?
        do {
            switch work {
            case let .thought(request):
                systemPrompt = Self.thoughtPrompt
                packet = try Self.packet(request)
                let evidence = request.availableEvidenceIDs.sorted().joined(separator: ",")
                let hypotheses = request.workspace.hypotheses.map { $0.id.uuidString.lowercased() }.joined(separator: ",")
                let intentions = request.workspace.intentions
                    .filter { $0.completedAt == nil }
                    .map { $0.id.uuidString.lowercased() }
                    .joined(separator: ",")
                binding = "expected_revision=\(request.workspace.revision); cycle_id=\(request.cycleID.uuidString.lowercased()); available_evidence_ids=[\(evidence)]; available_hypothesis_ids=[\(hypotheses)]; active_intention_ids=[\(intentions)]"
                images = try Self.images(for: request.visuals)
            case let .executive(request):
                systemPrompt = Self.executivePrompt
                packet = try Self.packet(request)
                binding = "expected_revision=\(request.workspaceRevision); cycle_id=\(request.cycleID.uuidString.lowercased()); intention_episode_id=\(request.intention.id.uuidString.lowercased())"
                images = nil
            }
        } catch {
            completeFailure(work, error: GemmaConsciousnessRuntimeError.requestEncoding)
            return
        }
        let temperature: Double
        let maximumTokens: Int
        switch work {
        case .thought:
            temperature = 0.35
            maximumTokens = 1_400
        case .executive:
            temperature = 0.10
            maximumTokens = 420
        }
        let payload = ChatRequest(
            model: configuration.model,
            messages: [
                .init(role: "system", content: systemPrompt, images: nil),
                .init(
                    role: "user",
                    content: "authoritative_output_binding:\n\(binding)\npacket:\n\(packet)",
                    images: images
                ),
            ],
            options: .init(temperature: temperature, numPredict: maximumTokens)
        )
        guard let body = try? JSONEncoder().encode(payload) else {
            completeFailure(work, error: GemmaConsciousnessRuntimeError.requestEncoding)
            return
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        onHealth(
            "model_started",
            "role=\(work.label); queue_executive=\(workQueue.executiveCount); event_pending=\(workQueue.hasEventThought ? 1 : 0); periodic_pending=\(workQueue.hasPeriodicThought ? 1 : 0)"
        )
        task = session.dataTask(with: request) { [weak self] data, response, error in
            self?.queue.async { [weak self] in
                guard let self, !stopped else { return }
                task = nil
                if let status = (response as? HTTPURLResponse)?.statusCode,
                   !(200 ... 299).contains(status) {
                    handleFailure(work, error: GemmaConsciousnessRuntimeError.responseStatus(status), retryCount: retryCount)
                    return
                }
                guard error == nil, let data,
                      let response = try? JSONDecoder().decode(ChatResponse.self, from: data),
                      let content = response.message?.content ?? response.response,
                      let object = Self.jsonObjectData(from: content) else {
                    handleFailure(
                        work,
                        error: GemmaConsciousnessRuntimeError.transport(error?.localizedDescription ?? "malformed_response"),
                        retryCount: retryCount
                    )
                    return
                }
                onHealth("model_response", "role=\(work.label); json=\(String(decoding: object, as: UTF8.self).prefix(4_096))")
                do {
                    switch work {
                    case let .thought(request):
                        let update = try L1ThoughtResponseDecoder.decode(object, for: request)
                        complete(work, result: .success(update))
                    case let .executive(request):
                        let decision = try L1ExecutiveResponseDecoder.decode(object, for: request)
                        complete(work, result: .success(decision))
                    }
                } catch {
                    handleFailure(work, error: error, retryCount: retryCount)
                }
            }
        }
        task?.resume()
    }

    private func handleFailure(_ work: L1ConsciousnessWorkItem, error: Error, retryCount: Int) {
        let identicalRetryPermitted = (error as? ConsciousnessResponseError)?
            .permitsIdenticalRequestRetry ?? true
        if retryCount > 0, identicalRetryPermitted {
            onHealth("model_retry", "role=\(work.label); reason=\(String(error.localizedDescription.prefix(240)))")
            start(work, retryCount: retryCount - 1)
        } else {
            if retryCount > 0 {
                onHealth(
                    "model_retry_suppressed",
                    "role=\(work.label); reason=semantic_authority_failure; detail=\(String(error.localizedDescription.prefix(240)))"
                )
            }
            completeFailure(work, error: error)
        }
    }

    private func completeFailure(_ work: L1ConsciousnessWorkItem, error: Error) {
        switch work {
        case .thought:
            complete(work, result: Result<L1ThoughtUpdate, Error>.failure(error))
        case .executive:
            complete(work, result: Result<L1ExecutiveDecision, Error>.failure(error))
        }
    }

    private func complete<T>(_ work: L1ConsciousnessWorkItem, result: Result<T, Error>) {
        let completedNS = DispatchTime.now().uptimeNanoseconds
        switch work {
        case let .thought(request):
            let typed: Result<L1ThoughtUpdate, Error> = result.flatMap { value in
                guard let value = value as? L1ThoughtUpdate else {
                    return .failure(GemmaConsciousnessRuntimeError.invalidResponse("thought_type"))
                }
                return .success(value)
            }
            thoughtCompletion(request, typed, completedNS)
        case let .executive(request):
            let typed: Result<L1ExecutiveDecision, Error> = result.flatMap { value in
                guard let value = value as? L1ExecutiveDecision else {
                    return .failure(GemmaConsciousnessRuntimeError.invalidResponse("executive_type"))
                }
                return .success(value)
            }
            executiveCompletion(request, typed, completedNS)
        }
        switch result {
        case .success:
            onHealth("model_completed", "role=\(work.label)")
        case let .failure(error):
            onHealth("model_failed", "role=\(work.label); reason=\(String(error.localizedDescription.prefix(240)))")
        }
        inFlight = nil
        startNextIfIdle()
    }

    private static func packet<Payload: Encodable>(_ payload: Payload) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(payload), as: UTF8.self)
    }

    private static func jsonObjectData(from content: String) -> Data? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.firstIndex(of: "{"),
              let last = trimmed.lastIndex(of: "}"), first <= last else {
            return nil
        }
        let candidate = String(trimmed[first ... last])
        guard let data = candidate.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            return nil
        }
        return data
    }

    private static func images(for resources: [L1VisualResource]) throws -> [String]? {
        let encoded = resources.prefix(2).compactMap { resource -> String? in
            resource.imageData()?.base64EncodedString()
        }
        return encoded.isEmpty ? nil : encoded
    }

    private static let thoughtPrompt = """
    You are SOMA L1a, the private thought-update process inside a persistent mental workspace. You do not choose social actions, speak, move the gimbal, or issue behavior directives. Assess only what changed, how existing hypotheses should be supported, contradicted, resolved, abandoned, or associated, and what deserves the foreground next. Evidence IDs and workspace revision are authoritative. Copy expected_revision exactly from authoritative_output_binding; it is the current revision, not a value to increment or predict. Never invent evidence, identity, gaze, speech, object details, or memory. Relationship uncertainty is canonical workspace state; do not recompute or overwrite it.

    The inner_monologue is the original English first-person thought. It must continue, revise, contradict, associate, retire, or explicitly idle relative to the existing stream; never merely redescribe an unchanged scene. thought_episodes are persistent lineage: continue an active episode while its question or goal remains unresolved, revise or retire it when evidence changes, and do not recreate a textually new thought for the same unresolved episode. cognitive_actions are L1/L2 tool outcomes linked to a goal episode. An accepted executive command proves only that an action was dispatched, not that its completion condition was achieved. Retiring a goal-linked episode requires intention_resolution naming that goal, satisfied or impossible, and citing at least one supplied observation newer than the latest dispatch boundary; a satisfied goal must already have been dispatched. Otherwise continue or revise it. New post-dispatch evidence may justify a different follow-up action under the same goal. Do not request the same action again when an equivalent successful semantic request is already present, and self-correct when an action failed or contradicted the goal. On a periodic wake, do not summarize visible contents or describe a frame in the present tense. Evaluate the prior thought episode, unresolved hypotheses, drives, associations, memory, goal progress, decay, or contradiction instead. If none warrants development, emit an honest metacognitive idle thought explaining that no belief currently needs revision, without narrating scene appearance. Do not keep the social channel foreground merely because a person remains present: compare recent thought candidates and use perceptual, memory_association, curiosity, self_correction, or idle when they better represent what changed. A repeated contact state without a new semantic consequence should support or retire an existing hypothesis with low novelty, not create another intention to monitor it.

    Treat unresolved interest without a present opportunity as tonic curiosity: preserve or update its hypothesis but leave intention null. Create an intention only for actionable pressure grounded in current evidence and authority. For a concrete visual uncertainty about the exact current detector target, an inspection intention may set attention_target_label to that supplied label; if L1b accepts it, SOMA will align the gimbal, capture one settled short-lived view, and return an active_visual_observation with the image attached. That returned observation is new evidence: inspect it, then resolve, contradict, or revise the goal instead of asking for the same capture again. Never create an inspection merely to collect pictures or redescribe a scene. Supplied information_needs are the authoritative unresolved profile gaps; never claim an identity, name, language, or interest gap that is not present there, and resolve or contradict an older hypothesis when current memory already supplies the fact. When evidence resolves or invalidates a hypothesis, use resolve or abandon and apply a negative drive_signal to the corresponding curiosity, concern, social_interest, or interruption_pressure so the motive can become satisfied instead of remaining permanently active. Visual resources may be requested only from visual_resource_offers.

    Return one JSON object and no Markdown. Use exactly this shape:
    {"expected_revision":0,"evidence_ids":["supplied ID"],"inner_monologue":"English first-person thought","channel":"perceptual|social|memory_association|curiosity|self_correction|idle","continuity":"continue|revise|contradict|associate|retire|idle","parent_thought_id":null,"confidence":0.5,"salience":0.5,"novelty":0.0,"hypothesis_mutations":[{"operation":"propose|support|contradict|resolve|abandon","hypothesis_id":null,"seed":null,"strength":0.5,"evidence_ids":["supplied ID"]}],"drive_signal":{"curiosity":0.0,"concern":0.0,"boredom":0.0,"social_interest":0.0,"interruption_pressure":0.0},"intention":null,"intention_resolution":null,"requested_visual_resource_ids":[],"memory_proposals":[]}
    A proposed mutation requires seed={"id":null,"kind":"perceptual|situational|social|memory_association|curiosity","subject_entity_id":null,"content":"...","confidence":0.5,"salience":0.5}. A non-null intention requires {"id":"UUID","domain":"social|attention|inspection","objective":"...","completion_condition":"observable condition that ends this goal","attention_target_label":null,"pressure":0.0,"evidence_ids":["supplied ID"],"created_at":milliseconds_since_epoch,"executed_at":null}. A non-null intention_resolution requires {"intention_id":"existing UUID","outcome":"satisfied|impossible","evidence_ids":["new supplied ID"],"explanation":"how the evidence meets or invalidates the observable completion condition"}. Set attention_target_label only to an exact detector target_label supplied in behavior_context when an inspection intention concerns that target. Never add action, behavior_directive, opening, rationale, social_decision, or executive_decision fields.
    """

    private static let executivePrompt = """
    You are SOMA L1b, a narrow executive judge. You receive one frozen workspace revision, its foreground thought, a specific intention episode with an objective and completion condition, current social/motor authority, and an explicit action set. Copy cycle_id, expected_revision, and intention_episode_id exactly from authoritative_output_binding. You cannot modify thoughts, hypotheses, memory, drives, or evidence. Choose exactly one available action that advances the intention toward its completion condition. Prefer no_action when the pressure is weak, stale-looking, socially inappropriate, already satisfied, or when an equivalent successful cognitive action already completed the goal. inspect_attention_target is a one-shot active-sensing action: it aligns to the grounded current target, captures a settled expiring image, and returns that result to L1a; choose it only when that new image can answer the intention's concrete visual uncertainty. spoken_opening is valid only with a current social opportunity and one supplied information motive; its opening must naturally pursue that closed motive in the preferred language without announcing internal objectives. Never invent an entity, motive, target, or permission.

    Return one JSON object and no Markdown, exactly:
    {"cycle_id":"copied UUID","expected_revision":0,"intention_episode_id":"copied UUID","action":"no_action|nonverbal_invitation|spoken_opening|resume_scanning|seek_people|inspect_attention_target","confidence":0.5,"rationale":"brief evidence-grounded reason","opening":null,"motive_id":null}
    Only spoken_opening may carry opening and motive_id. Every other action must set both to null.
    """
}

private extension L1ConsciousnessWorkItem {
    var label: String {
        switch self {
        case let .thought(request): "l1a_\(request.wakeKind.rawValue)"
        case .executive: "l1b_executive"
        }
    }
}
