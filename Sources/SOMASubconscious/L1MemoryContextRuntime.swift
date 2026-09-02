import Foundation
import SOMACore

private enum L1MemoryContextRuntimeError: LocalizedError {
    case invalidEndpoint
    case requestEncoding
    case transport(String)
    case responseStatus(Int)
    case missingResponse
    case invalidResponse(String)
    case memoryUnavailable
    case invalidPersonContextRequest

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "l1_ollama_endpoint_invalid"
        case .requestEncoding: "l1_ollama_request_encoding_failed"
        case let .transport(message): "l1_ollama_transport_\(message)"
        case let .responseStatus(status): "l1_ollama_http_\(status)"
        case .missingResponse: "l1_ollama_response_missing"
        case let .invalidResponse(message): "l1_ollama_response_invalid_\(message)"
        case .memoryUnavailable: "person_context_memory_unavailable"
        case .invalidPersonContextRequest: "person_context_request_invalid"
        }
    }
}

struct OllamaGenerateRequest: Encodable {
    let model: String
    let prompt: String
    let format: String
    let stream: Bool
    let think = false
    let images: [String]?
    let options: Options

    struct Options: Encodable {
        let temperature: Double
        let numPredict: Int

        enum CodingKeys: String, CodingKey {
            case temperature
            case numPredict = "num_predict"
        }
    }
}

struct OllamaGenerateResponse: Decodable {
    let response: String?
    let doneReason: String?
    enum CodingKeys: String, CodingKey {
        case response
        case doneReason = "done_reason"
    }
}

/// Cloud-backed models may wrap an otherwise valid JSON object in a Markdown
/// fence despite a JSON-format request. Normalize that transport decoration
/// before decoding, without attempting to repair malformed model output.
func decodeOllamaJSONObject<Payload: Decodable>(
    _ type: Payload.Type,
    from content: String
) -> Payload? {
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    let unfenced: String
    if trimmed.hasPrefix("```") {
        var lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        lines.removeFirst()
        if let last = lines.last,
           last.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") {
            lines.removeLast()
        }
        unfenced = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
        unfenced = trimmed
    }
    let candidates = [unfenced, trimmed].compactMap { candidate -> String? in
        guard let first = candidate.firstIndex(of: "{"),
              let last = candidate.lastIndex(of: "}"),
              first <= last else {
            return nil
        }
        return String(candidate[first...last])
    }
    for candidate in candidates {
        if let data = candidate.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(Payload.self, from: data) {
            return decoded
        }
    }
    return nil
}

/// A tool definition passed to Ollama's /api/chat tool-calling.
struct OllamaToolDefinition: Encodable {
    let type: String = "function"
    let function: Function

    struct Function: Encodable {
        let name: String
        let description: String
        let parameters: Parameters

        struct Parameters: Encodable {
            let type: String = "object"
            let properties: [String: Property]
            let required: [String]
        }

        struct Property: Encodable {
            let type: String
            let description: String?
        }
    }
}

/// The tool-calling /api/chat request payload.
struct L1MemoryContext: Sendable {
    let projections: [RemoteMemoryProjection]
    let informationNeeds: [L1InformationNeed]
    let rapport: L1RapportContext?
    let proactiveContactPreference: ProactiveContactPreference
    let preferredLanguageTag: String?
    let contactHistory: [L1SocialContactEvent]
    let personPreferences: String
    let recalledEpisodes: [String]
}

private struct RecalledEpisode: Sendable {
    let narrative: String
    let endedAt: Date

    func context(at date: Date) -> String {
        MemoryContextPresentation.pastEpisode(
            narrative: narrative,
            endedAt: endedAt,
            now: date
        )
    }
}

private final class SynchronousWriteResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?

    func set(_ value: Bool) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func read() -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Keeps the L1 cloud packet on the allowed side of the memory boundary.
/// Raw conversation, biometric identity material, and local-only records stay
/// in the encrypted journal; only marked summaries, rapport, and information
/// motives can become situation context.
/// A durable, persisted information need (open question) that L2 can resolve
/// as a mission. Mirrors L1InformationNeed but carries the memory record ID.
public struct PersistedInformationNeed: Codable, Equatable, Sendable {
    public let motiveID: UUID
    public let question: String
    public let targetEntityID: UUID?
    public let expectedInformationGain: Double
    public let createdAt: Date

    public init(
        motiveID: UUID,
        question: String,
        targetEntityID: UUID?,
        expectedInformationGain: Double,
        createdAt: Date
    ) {
        self.motiveID = motiveID
        self.question = question
        self.targetEntityID = targetEntityID
        self.expectedInformationGain = expectedInformationGain
        self.createdAt = createdAt
    }
}
private final class RecoveringCognitiveMemoryStore: @unchecked Sendable {
    private let lock = NSLock()
    private let directory: URL
    private let onHealth: @Sendable (String, String) -> Void
    private var store: CognitiveMemoryStore?
    private var opening = false
    private var nextOpenAttempt = Date.distantPast
    private var startupRecoveryAttemptsRemaining = 3

    init(onHealth: @escaping @Sendable (String, String) -> Void) {
        self.directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SOMA/memory", isDirectory: true)
        self.onHealth = onHealth
        _ = currentStore()
    }

    func currentStore() -> CognitiveMemoryStore? {
        let now = Date()
        lock.lock()
        if let store {
            lock.unlock()
            return store
        }
        guard !opening, now >= nextOpenAttempt else {
            lock.unlock()
            return nil
        }
        opening = true
        lock.unlock()

        let openedStore: CognitiveMemoryStore?
        let openError: Error?
        let recovery: CognitiveMemoryJournalRecoveryActivationReport?
        do {
            let key = try OwnerOnlyInstallationSecret.loadOrCreate(
                in: directory,
                filename: "installation-key-v1.bin"
            )
            do {
                openedStore = try CognitiveMemoryStore(directoryURL: directory, encryptionKey: key)
                recovery = nil
            } catch let error as CognitiveMemoryError {
                guard case .corruptJournal = error else { throw error }
                let activatedRecovery = try CognitiveMemoryStore.activateRecoverablePrefix(
                    from: directory,
                    encryptionKey: key
                )
                openedStore = try CognitiveMemoryStore(directoryURL: directory, encryptionKey: key)
                recovery = activatedRecovery
            }
            openError = nil
        } catch {
            openedStore = nil
            openError = error
            recovery = nil
        }
        let retryAfterStartupFailure: Bool

        lock.lock()
        opening = false
        if let openedStore {
            store = openedStore
            nextOpenAttempt = .distantFuture
            retryAfterStartupFailure = false
        } else {
            // A launch-agent restart can overlap the former instance's final
            // file-lock release. Keep single-writer semantics, but retry after
            // that short handoff instead of disabling durable memory forever.
            nextOpenAttempt = now.addingTimeInterval(1)
            retryAfterStartupFailure = startupRecoveryAttemptsRemaining > 0
            if retryAfterStartupFailure {
                startupRecoveryAttemptsRemaining -= 1
            }
        }
        lock.unlock()

        if openedStore != nil {
            if let recovery {
                onHealth(
                    "memory_recovered",
                    "source_entries=\(recovery.sourceEntryCount); recovered_entries=\(recovery.recoveredEntryCount); first_rejected_line=\(recovery.firstRejectedLine); backup=\(recovery.backupJournalURL.lastPathComponent)"
                )
            }
            onHealth("memory_ready", "store=encrypted_local; remote_projection=policy_filtered")
        } else if let openError {
            let failure = String(describing: openError)
            onHealth(
                "memory_unavailable",
                "error=\(failure); type=\(String(reflecting: type(of: openError)))"
            )
        }
        if retryAfterStartupFailure {
            onHealth("memory_retry_scheduled", "reason=startup_store_open_failure; delay_seconds=1.25")
            scheduleStartupRecovery()
        }
        return openedStore
    }

    private func scheduleStartupRecovery() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.25) { [weak self] in
            self?.onHealth("memory_retrying", "reason=startup_store_open_failure")
            _ = self?.currentStore()
        }
    }
}

final class L1MemoryContextProvider: @unchecked Sendable {
    private static let obsoletePlaceAffiliationQuestion =
        "Understand this person's relationship to the current place and its recurring objects before treating place observations as personal context."
    private static let conversationFactKeys: Set<String> = [
        "interests",
        "work_context",
        "ongoing_project",
        "personal_context",
    ]

    private static func informationNeedSource(
        for record: CognitiveMemoryRecord
    ) -> L1InformationMotiveSource {
        let sourceIDs = record.provenance.map(\.sourceID)
        if sourceIDs.contains("l1_initial_social_orientation") {
            return .initialSocialOrientation
        }
        if sourceIDs.contains("l1_interest_discovery") {
            return .interestDiscovery
        }
        if sourceIDs.contains(where: { $0.hasPrefix("l1_place_affiliation") }) {
            return .placeAffiliation
        }
        return .retainedMemoryGap
    }

    private static func isUngroundedInferenceNeed(
        _ record: CognitiveMemoryRecord
    ) -> Bool {
        record.provenance.contains { provenance in
            let modelProposedQuestion = provenance.source == .l1Inference
                && (provenance.sourceID == "l1_memory_proposal:open_question"
                    || provenance.sourceID.hasPrefix("l1_conversation_consolidation"))
            return modelProposedQuestion
                && !provenance.evidenceIDs.contains(where: {
                    $0.hasPrefix("conversation_turn:")
                })
        }
    }

    private struct ConversationMemoryConsolidation: Decodable {
        enum Kind: String, Decodable {
            case personFact = "person_fact"
            case task
            case openQuestion = "open_question"
        }

        struct Memory: Decodable {
            let kind: Kind
            let key: String?
            let summary: String
            let confidence: Double?
        }

        let narrative: String
        let salience: Double?
        let memories: [Memory]?
    }

    private struct ActiveConversation {
        let archiver: ConversationTranscriptArchiver
        let turnWriteBarrier: ConversationTurnWriteBarrier
        let startedAt: Date
        let personEntityID: UUID?
        var socialEpisode: L1ConversationContactEpisode
    }

    private let recoveringStore: RecoveringCognitiveMemoryStore
    private var store: CognitiveMemoryStore? { recoveringStore.currentStore() }
    private let onHealth: @Sendable (String, String) -> Void
    private let onPreferredLanguageChanged: @Sendable (UUID, String?) -> Void
    private let onSocialContactPersisted: @Sendable (UUID) -> Void
    private let transcriptRetentionSeconds: TimeInterval
    private let preferredLanguageLock = NSLock()
    private var preferredLanguageByPersonID: [UUID: String] = [:]
    private var personContextByPersonID: [UUID: PersonContextSnapshot] = [:]
    private var personMemorySummariesByPersonID: [UUID: [String]] = [:]
    private var personInfoNeedsByPersonID: [UUID: [PersistedInformationNeed]] = [:]
    private let legacyNeedSweepLock = NSLock()
    private var legacyNeedSweepStarted = false
    private let placeAffiliationLock = NSLock()
    private var placeAffiliationBySpaceID: [UUID: L1PlaceAffiliationContext] = [:]
    private let conversationLock = NSLock()
    private var activeConversations: [String: ActiveConversation] = [:]
    /// Every durable consequence of a finalized Live turn joins this group.
    /// Shutdown drains it before committing the episode closure, preserving the
    /// event order L1 uses for social continuity.
    private let conversationWriteGroup = DispatchGroup()
    private let embeddingClient = OllamaEmbeddingClient()
    private let embeddingCache = EpisodicEmbeddingCache()

    init(
        onHealth: @escaping @Sendable (String, String) -> Void,
        onPreferredLanguageChanged: @escaping @Sendable (UUID, String?) -> Void = { _, _ in },
        onSocialContactPersisted: @escaping @Sendable (UUID) -> Void = { _ in },
        transcriptRetentionSeconds: TimeInterval = 24 * 60 * 60
    ) {
        self.onHealth = onHealth
        self.onPreferredLanguageChanged = onPreferredLanguageChanged
        self.onSocialContactPersisted = onSocialContactPersisted
        self.transcriptRetentionSeconds = min(max(transcriptRetentionSeconds, 60 * 60), 24 * 60 * 60)
        recoveringStore = RecoveringCognitiveMemoryStore(onHealth: onHealth)
    }

    func context(
        for entityID: UUID,
        createPseudonymousEntity: Bool = false,
        placeAffiliation: L1PlaceAffiliationContext? = nil
    ) async -> L1MemoryContext {
        guard let store else {
            return L1MemoryContext(
                projections: [],
                informationNeeds: [],
                rapport: nil,
                proactiveContactPreference: .unknown,
                preferredLanguageTag: nil,
                contactHistory: [],
                personPreferences: "",
                recalledEpisodes: []
            )
        }
        do {
            let now = Date()
            await retireUngroundedInferenceNeedsIfNeeded(at: now)
            if createPseudonymousEntity {
                try await ensurePseudonymousEntity(entityID, in: store, at: now)
            }
            let personContext = try await store.personContext(for: entityID, at: now)
            var openQuestionRecords = try await store.query(
                .init(kinds: [.openQuestion], relatedTo: [entityID], limit: 500),
                at: now
            )
            if await retireSatisfiedProfileNeeds(
                in: openQuestionRecords,
                personContext: personContext,
                for: entityID,
                at: now
            ) > 0 {
                openQuestionRecords = try await store.query(
                    .init(kinds: [.openQuestion], relatedTo: [entityID], limit: 500),
                    at: now
                )
            }
            var records = try await store.query(
                .init(relatedTo: [entityID], limit: 96),
                at: now
            )
            if await retireObsoletePlaceAffiliationNeeds(
                in: openQuestionRecords,
                for: entityID,
                at: now
            ) > 0 {
                openQuestionRecords = try await store.query(
                    .init(kinds: [.openQuestion], relatedTo: [entityID], limit: 500),
                    at: now
                )
                records = try await store.query(
                    .init(relatedTo: [entityID], limit: 96),
                    at: now
                )
            }
            let allowed = records.filter {
                $0.disclosure == .remoteSummaryAllowed
                    && $0.sensitivity != .biometric
                    && $0.sensitivity != .secret
            }
            let projections = allowed.map {
                RemoteMemoryProjection(
                    id: $0.id,
                    revision: $0.revision,
                    tier: $0.tier,
                    kind: $0.kind,
                    summary: $0.summary,
                    confidence: $0.confidence,
                    updatedAt: $0.updatedAt
                )
            }
            var inadmissibleInferenceNeedIDs: [UUID] = []
            let allowedOpenQuestions = openQuestionRecords.filter {
                $0.disclosure == .remoteSummaryAllowed
                    && $0.sensitivity != .biometric
                    && $0.sensitivity != .secret
            }
            var needs = allowedOpenQuestions.compactMap { record -> L1InformationNeed? in
                guard case let .openQuestion(question) = record.payload,
                      question.targetEntityID == entityID,
                      question.status == .open else {
                    return nil
                }
                let source = Self.informationNeedSource(for: record)
                // A visual/model-only question is a useful transient thought,
                // not durable evidence about a person. Older journals can
                // contain these from before the admission rule existed; retire
                // them here rather than allowing them to re-enter L1 context.
                if Self.isUngroundedInferenceNeed(record) {
                    inadmissibleInferenceNeedIDs.append(record.id)
                    return nil
                }
                return L1InformationNeed(
                    motiveID: record.id,
                    source: source,
                    informationGoal: question.question,
                    expectedInformationGain: question.expectedInformationGain
                )
            }
            for motiveID in inadmissibleInferenceNeedIDs {
                _ = await dismissInformationNeed(
                    motiveID: motiveID,
                    reason: "ungrounded_l1_inference"
                )
            }
            let contactHistory = records.compactMap { record -> L1SocialContactEvent? in
                guard case let .situation(value) = record.payload,
                      value.participantEntityIDs.contains(entityID),
                      value.state.hasPrefix("social_contact:"),
                      let rawKind = value.state.split(separator: ":", maxSplits: 1).last,
                      let kind = L1SocialContactKind(rawValue: String(rawKind)) else {
                    return nil
                }
                return L1SocialContactEvent(
                    kind: kind,
                    occurredAt: record.updatedAt,
                    purpose: record.summary
                )
            }.sorted { $0.occurredAt > $1.occurredAt }
            let hasPreferredName = personContext.mission.isSatisfied
            if !hasPreferredName,
               !needs.contains(where: { $0.source == .initialSocialOrientation }) {
                let goal = "Learn the person's preferred name or form of address for future respectful interaction."
                let motiveID = await ensureInformationNeed(
                    question: goal,
                    targetEntityID: entityID,
                    expectedInformationGain: 0.95,
                    sourceID: "l1_initial_social_orientation"
                )
                needs.append(L1InformationNeed(
                    motiveID: motiveID ?? UUID(),
                    source: .initialSocialOrientation,
                    informationGoal: goal,
                    expectedInformationGain: 0.95
                ))
            }
            let hasInterestProfile = L1InformationMotiveSource.interestDiscovery
                .isSatisfied(by: personContext)
            if !hasInterestProfile {
                let goal = "When the situation naturally supports it, learn one enduring interest, hobby, or topic this person enjoys discussing."
                let motiveID = await ensureInformationNeed(
                    question: goal,
                    targetEntityID: entityID,
                    expectedInformationGain: 0.64,
                    sourceID: "l1_interest_discovery"
                )
                needs.append(L1InformationNeed(
                    motiveID: motiveID ?? UUID(),
                    source: .interestDiscovery,
                    informationGoal: goal,
                    expectedInformationGain: 0.64
                ))
            }
            // Human conversation has balance: do not barrage the person with
            // every open question at once. Surface only the highest-value needs,
            // capped, so the robot gently pursues one or two things rather than
            // interrogating.
            let maxActiveNeeds = 2
            needs = needs
                .sorted { $0.expectedInformationGain > $1.expectedInformationGain }
                .prefix(maxActiveNeeds)
                .map { $0 }
            let rapportContext = personContext.rapport.map {
                L1RapportContext(
                    familiarity: $0.familiarity,
                    interactionComfort: $0.interactionComfort,
                    communicationAlignment: $0.communicationAlignment,
                    proactiveContact: $0.proactiveContact
                )
            }
            cachePersonContext(personContext)
            cachePersonMemorySummaries(
                projections.map {
                    MemoryContextPresentation.durableMemory(
                        summary: $0.summary,
                        kind: $0.kind,
                        lastRevisedAt: $0.updatedAt
                    )
                }.filter { !$0.isEmpty },
                for: entityID
            )
            let persistedNeeds = await pendingInformationNeeds(for: entityID, at: now, respectCooldown: false)
            cacheInformationNeeds(persistedNeeds, for: entityID)
            // The needs are about to be handed to L1/L2 as a mission; put them
            // into cooldown so the robot does not re-ask the same thing every
            // conversation until the window passes.
            await markInformationNeedsSurfaced(persistedNeeds, at: now)
            let recalled = await recallEpisodes(
                entityID: entityID,
                query: personContext.preferenceDirectives().joined(separator: " "),
                at: now
            )
            return L1MemoryContext(
                projections: projections,
                informationNeeds: needs,
                rapport: rapportContext,
                proactiveContactPreference: personContext.proactiveContactPreference,
                preferredLanguageTag: personContext.preferredLanguageTag,
                contactHistory: Array(contactHistory.prefix(16)),
                personPreferences: personContext.preferenceDirectives().joined(separator: " "),
                recalledEpisodes: recalled.map { $0.context(at: now) }
            )
        } catch {
            onHealth("memory_unavailable", String(error.localizedDescription.prefix(192)))
            return L1MemoryContext(
                projections: [],
                informationNeeds: [],
                rapport: nil,
                proactiveContactPreference: .unknown,
                preferredLanguageTag: nil,
                contactHistory: [],
                personPreferences: "",
                recalledEpisodes: []
            )
        }
    }

    /// Before evidence-bearing proposal records existed, an L1 visual guess
    /// could become an open question in the encrypted journal. Sweep that
    /// narrow legacy class once so it cannot keep resurfacing after upgrade.
    private func retireUngroundedInferenceNeedsIfNeeded(at date: Date) async {
        let shouldSweep = legacyNeedSweepLock.withLock {
            guard !legacyNeedSweepStarted else { return false }
            legacyNeedSweepStarted = true
            return true
        }
        guard shouldSweep, let store else { return }

        let records = (try? await store.query(.init(limit: 1_024), at: date)) ?? []
        let motiveIDs = records.compactMap { record -> UUID? in
            guard case let .openQuestion(question) = record.payload,
                  question.status == .open,
                  Self.isUngroundedInferenceNeed(record) else {
                return nil
            }
            return record.id
        }
        for motiveID in motiveIDs {
            _ = await dismissInformationNeed(
                motiveID: motiveID,
                reason: "ungrounded_l1_inference"
            )
        }
        if !motiveIDs.isEmpty {
            onHealth("info_need_legacy_sweep", "dismissed=\(motiveIDs.count)")
        }
    }

    /// Retires profile-acquisition motives whose required fact is already
    /// present in the authoritative materialized person context. Recent event
    /// windows are intentionally not consulted: high-rate observations must
    /// never make a durable identity fact appear missing.
    private func retireSatisfiedProfileNeeds(
        in records: [CognitiveMemoryRecord],
        personContext: PersonContextSnapshot,
        for entityID: UUID,
        at date: Date
    ) async -> Int {
        let satisfiedIDs = records.compactMap { record -> UUID? in
            guard case let .openQuestion(question) = record.payload,
                  question.targetEntityID == entityID,
                  question.status == .open,
                  Self.informationNeedSource(for: record).isSatisfied(by: personContext) else {
                return nil
            }
            return record.id
        }
        var retired = 0
        for motiveID in satisfiedIDs where await resolveInformationNeed(
            motiveID: motiveID,
            expectedTargetEntityID: entityID,
            at: date
        ) {
            retired += 1
        }
        if retired > 0 {
            onHealth("profile_need_retired", "person=\(entityID.uuidString.lowercased()); count=\(retired)")
        }
        return retired
    }

    private func retireObsoletePlaceAffiliationNeeds(
        in records: [CognitiveMemoryRecord],
        for entityID: UUID,
        at date: Date
    ) async -> Int {
        let obsoleteIDs = records.compactMap { record -> UUID? in
            guard case let .openQuestion(question) = record.payload,
                  question.targetEntityID == entityID,
                  question.status == .open,
                  question.question == Self.obsoletePlaceAffiliationQuestion,
                  record.provenance.contains(where: { $0.sourceID == "l1_place_affiliation" }) else {
                return nil
            }
            return record.id
        }
        var retired = 0
        for motiveID in obsoleteIDs where await resolveInformationNeed(motiveID: motiveID, at: date) {
            retired += 1
        }
        if retired > 0 {
            onHealth("place_affiliation_need_retired", "count=\(retired)")
        }
        return retired
    }

    /// Semantically recalls the most relevant past episodes by embedding the
    /// query and episode narratives and ranking by cosine similarity blended
    /// with salience and recency. Falls back to recency-only ranking when the
    /// embedding model is unavailable. `entityID` optionally scopes to one
    /// person; nil recalls across all episodes.
    private func recallEpisodes(
        entityID: UUID?,
        query: String,
        limit: Int = 4,
        at date: Date
    ) async -> [RecalledEpisode] {
        guard let store else { return [] }
        do {
            let episodes = try await store.query(
                .init(kinds: [.episode], relatedTo: entityID.map { [$0] } ?? [], limit: 200),
                at: date
            )
            guard !episodes.isEmpty else { return [] }
            let scoped = entityID != nil
            let queryText = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? (scoped ? "recent meaningful conversation with this person" : "recent meaningful conversation")
                : (scoped ? "conversation with this person about \(query)" : query)
            guard let queryEmbedding = await embeddingClient.embed(queryText) else {
                return episodes
                    .sorted { lhs, rhs in
                        (recalledEpisode(from: lhs)?.endedAt ?? lhs.updatedAt)
                            > (recalledEpisode(from: rhs)?.endedAt ?? rhs.updatedAt)
                    }
                    .prefix(limit)
                    .compactMap { recalledEpisode(from: $0) }
            }
            var scored: [(episode: RecalledEpisode, similarity: Float, salience: Double)] = []
            for episode in episodes {
                guard let recalled = recalledEpisode(from: episode) else { continue }
                let narrative = recalled.narrative
                let embedding: [Float]?
                if let cached = embeddingCache.embedding(for: episode.id) {
                    embedding = cached
                } else if let fresh = await embeddingClient.embed(narrative) {
                    embeddingCache.set(fresh, for: episode.id)
                    embedding = fresh
                } else {
                    embedding = nil
                }
                guard let embedding, let sim = cosineSimilarity(queryEmbedding, embedding) else { continue }
                scored.append((recalled, sim, episodeSalience(episode)))
            }
            let ranked = scored.sorted { lhs, rhs in
                let l = Double(lhs.similarity) * 0.6 + lhs.salience * 0.3 + recencyScore(lhs.episode.endedAt, now: date) * 0.1
                let r = Double(rhs.similarity) * 0.6 + rhs.salience * 0.3 + recencyScore(rhs.episode.endedAt, now: date) * 0.1
                return l > r
            }
            return ranked.prefix(limit).map(\.episode)
        } catch {
            return []
        }
    }

    /// Public episodic recall for the L1 `recall_episodes` tool.
    func recallEpisodes(
        query: String,
        entityID: UUID?,
        limit: Int = 4,
        at date: Date = Date()
    ) async -> [String] {
        await recallEpisodes(entityID: entityID, query: query, limit: limit, at: date)
            .map { $0.context(at: date) }
    }

    private func recalledEpisode(from record: CognitiveMemoryRecord) -> RecalledEpisode? {
        guard case let .episode(value) = record.payload else { return nil }
        let narrative = value.narrative.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !narrative.isEmpty else { return nil }
        return RecalledEpisode(narrative: narrative, endedAt: value.endedAt)
    }

    private func episodeSalience(_ record: CognitiveMemoryRecord) -> Double {
        guard case let .episode(value) = record.payload else { return 0.5 }
        return min(max(value.salience, 0), 1)
    }

    private func recencyScore(_ date: Date, now: Date) -> Double {
        let age = max(0, now.timeIntervalSince(date))
        // 0 at 30+ days old, 1 at now, linear in between.
        return max(0, min(1, 1 - age / (30 * 24 * 60 * 60)))
    }

    /// Stores a compact social-contact event independently of the current
    /// process. L1 receives the recent event sequence as context; it chooses
    /// whether another contact is appropriate rather than inheriting a fixed
    /// elapsed-time social cooldown.
    @discardableResult
    func recordSocialContact(
        _ kind: L1SocialContactKind,
        with entityID: UUID,
        purpose: String? = nil,
        at date: Date = Date()
    ) async -> Bool {
        guard let store else { return false }
        do {
            let normalizedPurpose = purpose?.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = normalizedPurpose?.isEmpty == false
                ? "Social contact \(kind.rawValue): \(String(normalizedPurpose!.prefix(320)))"
                : "Social contact \(kind.rawValue)."
            _ = try await store.insert(
                CognitiveMemoryDraft(
                    tier: .mediumTerm,
                    summary: summary,
                    payload: .situation(SituationMemory(
                        state: "social_contact:\(kind.rawValue)",
                        participantEntityIDs: [entityID]
                    )),
                    confidence: 1,
                    provenance: [
                        MemoryProvenance(
                            source: .l1Inference,
                            sourceID: "l1_social_contact",
                            observedAt: date,
                            evidenceIDs: ["social:\(entityID.uuidString.lowercased())"],
                            modelID: "gemma4:31b-cloud"
                        )
                    ],
                    sensitivity: .personal,
                    disclosure: .remoteSummaryAllowed,
                    expiresAt: date.addingTimeInterval(90 * 24 * 60 * 60)
                ),
                at: date
            )
            onSocialContactPersisted(entityID)
            onHealth("social_contact_recorded", "kind=\(kind.rawValue)")
            return true
        } catch {
            onHealth("social_contact_record_failed", String(error.localizedDescription.prefix(192)))
            return false
        }
    }

    /// Records a durable narrative episode only after every finalized turn is
    /// available. The same consolidation pass extracts explicit durable facts,
    /// tasks, and genuine open questions from the conversation.
    @discardableResult
    func recordEpisode(
        personEntityID: UUID,
        archiver: ConversationTranscriptArchiver,
        startedAt: Date,
        endedAt: Date,
        reason: String,
        at date: Date = Date()
    ) async -> Bool {
        guard let store else { return false }
        do {
            let turns = try await archiver.pending(at: date)
            guard !turns.isEmpty else {
                onHealth("episode_consolidation_deferred", "reason=no_finalized_turns")
                return false
            }
            let transcript = turns
                .sorted { lhs, rhs in
                    guard case let .conversationTurn(l) = lhs.payload,
                          case let .conversationTurn(r) = rhs.payload else { return lhs.id.uuidString < rhs.id.uuidString }
                    return l.turnSequence < r.turnSequence
                }
                .compactMap { record -> String? in
                    guard case let .conversationTurn(turn) = record.payload else { return nil }
                    let text = turn.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                    return text.isEmpty ? nil : "\(turn.role.rawValue): \(text)"
                }
                .joined(separator: "\n")
            guard !transcript.isEmpty else {
                onHealth("episode_consolidation_deferred", "reason=empty_finalized_turns")
                return false
            }
            guard let consolidation = await summarizeEpisode(
                transcript: transcript,
                reason: reason
            ) else {
                onHealth("episode_consolidation_deferred", "reason=model_response_unavailable")
                return false
            }
            let boundedNarrative = String(consolidation.narrative.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1_200))
            guard !boundedNarrative.isEmpty else {
                onHealth("episode_consolidation_deferred", "reason=empty_narrative")
                return false
            }
            let salience = min(max(consolidation.salience ?? 0.5, 0), 1)
            let interactionID = await archiver.interactionID
            let threadID = await archiver.threadID
            let episode = try await store.insert(
                CognitiveMemoryDraft(
                    tier: .mediumTerm,
                    summary: String(boundedNarrative.prefix(320)),
                    payload: .episode(EpisodeMemory(
                        startedAt: startedAt,
                        endedAt: endedAt,
                        participantEntityIDs: [personEntityID],
                        narrative: boundedNarrative,
                        salience: salience
                    )),
                    confidence: 0.8,
                    provenance: [
                        MemoryProvenance(
                            source: .l1Inference,
                            sourceID: "l1_episode",
                            observedAt: date,
                            evidenceIDs: ["episode:\(interactionID.uuidString.lowercased())"],
                            modelID: "gemma4:31b-cloud"
                        )
                    ],
                    sensitivity: .personal,
                    disclosure: .localOnly,
                    expiresAt: date.addingTimeInterval(90 * 24 * 60 * 60)
                ),
                at: date
            )
            let result = try await persistConversationMemories(
                consolidation.memories ?? [],
                personEntityID: personEntityID,
                threadID: threadID,
                at: date
            )
            let derivedIDs = [episode.id] + result.derivedMemoryIDs
            for turn in turns {
                _ = try await archiver.markConsolidated(
                    recordID: turn.id,
                    derivedMemoryIDs: derivedIDs,
                    at: date
                )
            }
            cachePersonContext(try await store.personContext(for: personEntityID, at: date))
            let pendingNeeds = await pendingInformationNeeds(
                for: personEntityID,
                at: date,
                respectCooldown: false
            )
            cacheInformationNeeds(pendingNeeds, for: personEntityID)
            warmContext(for: personEntityID)
            onHealth(
                "conversation_memory_consolidated",
                "turns=\(turns.count); episode_chars=\(boundedNarrative.count); facts=\(result.facts); tasks=\(result.tasks); questions=\(result.questions)"
            )
            return true
        } catch {
            onHealth("episode_record_failed", String(error.localizedDescription.prefix(192)))
            return false
        }
    }

    private struct PersistedConversationMemoryResult {
        var derivedMemoryIDs: [UUID] = []
        var facts = 0
        var tasks = 0
        var questions = 0
    }

    private func persistConversationMemories(
        _ memories: [ConversationMemoryConsolidation.Memory],
        personEntityID: UUID,
        threadID: String,
        at date: Date
    ) async throws -> PersistedConversationMemoryResult {
        guard let store else { return .init() }
        var result = PersistedConversationMemoryResult()
        for memory in memories.prefix(6) {
            let summary = String(memory.summary.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1_024))
            let confidence = min(max(memory.confidence ?? 0, 0), 1)
            guard !summary.isEmpty, confidence >= 0.70 else { continue }
            switch memory.kind {
            case .personFact:
                guard let rawKey = memory.key?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                      Self.conversationFactKeys.contains(rawKey) else {
                    continue
                }
                _ = try await store.setExplicitPersonFact(
                    personEntityID: personEntityID,
                    key: rawKey,
                    value: summary,
                    sourceID: "l1_conversation_consolidation:\(threadID)",
                    at: date
                )
                result.facts += 1
            case .task:
                let record = try await store.insert(
                    CognitiveMemoryDraft(
                        tier: .mediumTerm,
                        summary: summary,
                        payload: .task(TaskMemory(title: summary, status: .active, ownerEntityID: personEntityID)),
                        confidence: confidence,
                        provenance: [MemoryProvenance(
                            source: .consolidation,
                            sourceID: "l1_conversation_consolidation:\(threadID)",
                            observedAt: date,
                            evidenceIDs: ["conversation:\(threadID)"],
                            modelID: "gemma4:31b-cloud"
                        )],
                        sensitivity: .personal,
                        disclosure: .remoteSummaryAllowed,
                        expiresAt: date.addingTimeInterval(30 * 24 * 60 * 60)
                    ),
                    at: date
                )
                result.derivedMemoryIDs.append(record.id)
                result.tasks += 1
            case .openQuestion:
                if let id = await ensureInformationNeed(
                    question: summary,
                    targetEntityID: personEntityID,
                    expectedInformationGain: confidence,
                    sourceID: "l1_conversation_consolidation"
                ) {
                    result.derivedMemoryIDs.append(id)
                    result.questions += 1
                }
            }
        }
        return result
    }

    /// Asks L1 to turn a finished conversation into a privacy-preserving
    /// episode plus only explicitly supported person-context additions.
    private func summarizeEpisode(
        transcript: String,
        reason: String
    ) async -> ConversationMemoryConsolidation? {
        let boundedTranscript = String(transcript.prefix(6_000))
        guard !boundedTranscript.isEmpty else { return nil }
        let prompt = """
        You are SOMA's memory consolidator. Turn this finished conversation into a short, neutral memory. The original transcript stays local: never quote it and never include sensitive identifiers.

        Return one 1-3 sentence narrative of what happened and its importance (salience 0.0...1.0). Then emit only durable information explicitly stated by the user or jointly resolved in the conversation. Do not infer facts from tone, appearance, the room, or a single gesture. Do not emit a relationship score: contact history is stored separately.

        For each memory, use exactly one kind:
        - person_fact: a stable fact stated by the user. key must be interests, work_context, ongoing_project, or personal_context.
        - task: an active task the user explicitly asked SOMA to remember or work on.
        - open_question: a meaningful unresolved question that a future conversation can naturally answer.

        Omit memories when the transcript does not support them. Never duplicate information already said in the same conversation. Do not turn casual filler, momentary states, or model guesses into memory.
        Closure reason: \(reason.isEmpty ? "conversation ended" : reason)
        Transcript:
        \(boundedTranscript)
        Return strict JSON only:
        {"narrative":"...","salience":0.7,"memories":[{"kind":"person_fact","key":"interests","summary":"...","confidence":0.9}]}
        """
        guard let url = URL(string: "\(somaOllamaHost())/api/generate") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": ProcessInfo.processInfo.environment["SOMA_L1_MODEL"] ?? "gemma4:31b-cloud",
            "prompt": prompt,
            "stream": false,
            "think": false,
            "format": "json",
            "options": ["temperature": 0.2, "num_predict": 360],
        ])
        request.timeoutInterval = 20
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let outer = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = outer["response"] as? String,
                  let decoded = decodeOllamaJSONObject(ConversationMemoryConsolidation.self, from: content) else {
                return nil
            }
            guard !decoded.narrative.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return decoded
        } catch {
            return nil
        }
    }

    /// Consolidates short-term episodes: promotes high-salience ones to
    /// long-term so they survive, leaving low-value ones to expire. Runs on a
    /// slow periodic timer to mimic human memory consolidation.
    func consolidateEpisodes() async {
        guard let store else { return }
        do {
            let now = Date()
            let shortTerm = try await store.query(
                .init(tiers: [.shortTerm], kinds: [.episode], limit: 200),
                at: now
            )
            var promoted = 0
            for record in shortTerm {
                let salience = episodeSalience(record)
                let recency = recencyScore(record.updatedAt, now: now)
                let score = salience * 0.7 + recency * 0.3
                guard score >= 0.6 else { continue }
                _ = try? await store.promote(
                    id: record.id,
                    to: .longTerm,
                    expiresAt: now.addingTimeInterval(365 * 24 * 60 * 60),
                    provenance: record.provenance,
                    reason: "consolidation_salience",
                    at: now
                )
                promoted += 1
            }
            if promoted > 0 {
                onHealth("memory_consolidated", "promoted=\(promoted)")
            }
        } catch {
            onHealth("memory_consolidation_failed", String(error.localizedDescription.prefix(192)))
        }
    }

    /// Stores an observed fact about a person (used by the L1 memory-add tool).
    @discardableResult
    func storePersonFact(
        _ fact: String,
        for entityID: UUID,
        at date: Date = Date()
    ) async -> Bool {
        let normalized = fact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= 1024, let store else { return false }
        do {
            _ = try await store.insert(
                CognitiveMemoryDraft(
                    tier: .mediumTerm,
                    summary: normalized,
                    payload: .personFact(PersonFactMemory(
                        personEntityID: entityID,
                        key: "observed_fact",
                        value: normalized
                    )),
                    confidence: 0.8,
                    provenance: [
                        MemoryProvenance(
                            source: .l1Inference,
                            sourceID: "l1_person_fact",
                            observedAt: date,
                            evidenceIDs: ["person_fact:\(entityID.uuidString.lowercased())"],
                            modelID: "gemma4:31b-cloud"
                        )
                    ],
                    sensitivity: .personal,
                    disclosure: .remoteSummaryAllowed,
                    expiresAt: date.addingTimeInterval(store.maximumMediumTermLifetime)
                ),
                at: date
            )
            onSocialContactPersisted(entityID)
            onHealth("person_fact_stored", "entity=\(entityID.uuidString.lowercased())")
            return true
        } catch {
            onHealth("person_fact_store_failed", String(error.localizedDescription.prefix(192)))
            return false
        }
    }

    /// Uses the encrypted memory store as the source of truth for affiliation
    /// and caches only the compact scalar projection needed by L1 packets.
    func cachedPlaceAffiliation(
        spaceID: UUID,
        label: String?,
        isStable: Bool
    ) -> L1PlaceAffiliationContext {
        let cached = placeAffiliationLock.withLock {
            placeAffiliationBySpaceID[spaceID]
        }
        guard let cached else {
            return L1PlaceAffiliationContext(
                spaceID: spaceID,
                label: label,
                isStable: isStable
            )
        }
        return L1PlaceAffiliationContext(
            spaceID: spaceID,
            label: label ?? cached.label,
            isStable: isStable,
            ownerEntityID: cached.ownerEntityID,
            unassignedObservationCount: cached.unassignedObservationCount
        )
    }

    private func refreshedPlaceAffiliation(
        _ context: L1PlaceAffiliationContext,
        at date: Date
    ) async -> L1PlaceAffiliationContext {
        let refreshed = L1PlaceAffiliationContext(
            spaceID: context.spaceID,
            label: context.label,
            isStable: context.isStable,
            ownerEntityID: await spaceOwner(spaceID: context.spaceID, at: date),
            unassignedObservationCount: await pendingSpaceObjectCount(spaceID: context.spaceID, at: date)
        )
        placeAffiliationLock.withLock {
            placeAffiliationBySpaceID[context.spaceID] = refreshed
        }
        return refreshed
    }

    /// A stable neutral entity representing the robot's home space. Recognized
    /// objects seen while no person is engaged are bound here first; they are
    /// promoted to a person's taste profile only once the space owner is learned
    /// (via setSpaceOwner, typically from a conversation).
    public static let homeSpaceEntityID = UUID(uuidString: "A0A0E5C4-3B8A-4C1D-9E6F-5B7D0A2E8C11")!

    /// Binds a recognized object to a space without attributing it to any
    /// person yet. Called when the object is seen during empty exploration.
    @discardableResult
    func storeSpaceObject(
        name: String,
        category: String,
        description: String,
        spaceID: UUID,
        at date: Date = Date()
    ) async -> Bool {
        guard let store else { return false }
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return false }
        do {
            _ = try await store.insert(
                CognitiveMemoryDraft(
                    tier: .mediumTerm,
                    summary: "Object in the space \(spaceID.uuidString.lowercased()): \(normalizedName)\(category.isEmpty ? "" : " (\(category))")",
                    payload: .personFact(PersonFactMemory(
                        personEntityID: spaceID,
                        key: "space_object",
                        value: "\(normalizedName)|\(category)|\(description)"
                    )),
                    confidence: 0.7,
                    provenance: [
                        MemoryProvenance(
                            source: .l1Inference,
                            sourceID: "l1_space_object",
                            observedAt: date,
                            evidenceIDs: ["space_object:\(spaceID.uuidString.lowercased())"],
                            modelID: "gemma4:31b-cloud"
                        )
                    ],
                    sensitivity: .personal,
                    disclosure: .remoteSummaryAllowed,
                    expiresAt: date.addingTimeInterval(store.maximumMediumTermLifetime)
                ),
                at: date
            )
            _ = placeAffiliationLock.withLock {
                placeAffiliationBySpaceID.removeValue(forKey: spaceID)
            }
            return true
        } catch {
            onHealth("space_object_store_failed", String(error.localizedDescription.prefix(192)))
            return false
        }
    }

    /// Records who owns a space and promotes every un-attributed space-bound
    /// object to that owner's taste profile. Idempotent: space objects are
    /// deleted as they are promoted, so a repeat call re-promotes only objects
    /// added since.
    @discardableResult
    func associateRecognizedPersonWithUnassignedSpace(
        _ personEntityID: UUID,
        spaceID: UUID,
        at date: Date = Date()
    ) async -> Bool {
        if let existing = await spaceOwner(spaceID: spaceID, at: date) {
            return existing == personEntityID
        }
        return await setSpaceOwner(personEntityID, spaceID: spaceID, at: date)
    }

    @discardableResult
    func setSpaceOwner(
        _ ownerEntityID: UUID,
        spaceID: UUID,
        at date: Date = Date()
    ) async -> Bool {
        guard let store else { return false }
        do {
            let current = try await store.personContext(for: spaceID, at: date)
            if current.facts["space_owner"] != ownerEntityID.uuidString.lowercased() {
                _ = try await store.insert(
                    CognitiveMemoryDraft(
                        tier: .mediumTerm,
                        summary: "Space \(spaceID.uuidString.lowercased()) owner is \(ownerEntityID.uuidString.lowercased())",
                        payload: .personFact(PersonFactMemory(
                            personEntityID: spaceID,
                            key: "space_owner",
                            value: ownerEntityID.uuidString.lowercased()
                        )),
                        confidence: 0.9,
                        provenance: [
                            MemoryProvenance(
                                source: .l2Interaction,
                                sourceID: "l2_space_owner",
                                observedAt: date,
                                evidenceIDs: ["space_owner:\(spaceID.uuidString.lowercased())"],
                                modelID: "codex"
                            )
                        ],
                        sensitivity: .personal,
                        disclosure: .remoteSummaryAllowed,
                        expiresAt: date.addingTimeInterval(store.maximumMediumTermLifetime)
                    ),
                    at: date
                )
            }
            let records = try await store.query(
                .init(relatedTo: [spaceID], limit: 200),
                at: date
            )
            var promoted = 0
            for record in records {
                guard case let .personFact(fact) = record.payload,
                      fact.personEntityID == spaceID,
                      fact.key == "space_object" else { continue }
                let parts = fact.value.split(separator: "|", maxSplits: 2).map(String.init)
                guard let name = parts.first, !name.isEmpty else { continue }
                let category = parts.count > 1 ? parts[1] : ""
                let tasteFact = "The user has/collects \(name)\(category.isEmpty ? "" : " (\(category))"). Hobby/taste item worth remembering."
                _ = try await store.insert(
                    CognitiveMemoryDraft(
                        tier: .mediumTerm,
                        summary: tasteFact,
                        payload: .personFact(PersonFactMemory(
                            personEntityID: ownerEntityID,
                            key: "observed_fact",
                            value: tasteFact
                        )),
                        confidence: 0.8,
                        provenance: [
                            MemoryProvenance(
                                source: .l1Inference,
                                sourceID: "l1_space_object_promotion",
                                observedAt: date,
                                evidenceIDs: ["space_object:\(record.id.uuidString.lowercased())"],
                                modelID: "gemma4:31b-cloud"
                            )
                        ],
                        sensitivity: .personal,
                        disclosure: .remoteSummaryAllowed,
                        expiresAt: date.addingTimeInterval(store.maximumMediumTermLifetime)
                    ),
                    at: date
                )
                try await store.delete(id: record.id, reason: "promoted_to_space_owner", at: date)
                promoted += 1
            }
            onHealth("space_owner_set", "owner=\(ownerEntityID.uuidString.lowercased()); space=\(spaceID.uuidString.lowercased()); promoted=\(promoted)")
            placeAffiliationLock.withLock {
                let prior = placeAffiliationBySpaceID[spaceID]
                placeAffiliationBySpaceID[spaceID] = L1PlaceAffiliationContext(
                    spaceID: spaceID,
                    label: prior?.label,
                    isStable: prior?.isStable ?? false,
                    ownerEntityID: ownerEntityID,
                    unassignedObservationCount: 0
                )
            }
            return true
        } catch {
            onHealth("space_owner_set_failed", String(error.localizedDescription.prefix(192)))
            return false
        }
    }

    /// The current space owner entity ID, if one has been learned.
    func spaceOwner(spaceID: UUID, at date: Date = Date()) async -> UUID? {
        guard let store else { return nil }
        let snapshot = try? await store.personContext(for: spaceID, at: date)
        return snapshot?.facts["space_owner"].flatMap(UUID.init(uuidString:))
    }

    /// Number of recognized objects currently bound to a space and awaiting
    /// owner promotion.
    func pendingSpaceObjectCount(spaceID: UUID, at date: Date = Date()) async -> Int {
        guard let store else { return 0 }
        let records = (try? await store.query(.init(relatedTo: [spaceID], limit: 200), at: date)) ?? []
        return records.filter {
            guard case let .personFact(fact) = $0.payload else { return false }
            return fact.personEntityID == spaceID && fact.key == "space_object"
        }.count
    }

    // MARK: Durable information-need management
    //
    // Information the robot wants to acquire about a person or its environment
    // is persisted as an open question so it survives restarts, can be handed
    // to L2 as an actionable mission (via get/resolve_information_need MCP
    // tools), and is tracked until resolved.

    /// Ensures an open information need exists (deduped by target + question +
    /// open status). Returns its motive ID (the memory record ID).
    @discardableResult
    func ensureInformationNeed(
        question: String,
        targetEntityID: UUID?,
        expectedInformationGain: Double,
        sourceID: String,
        at date: Date = Date()
    ) async -> UUID? {
        guard let store else { return nil }
        let normalized = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        do {
            let query: CognitiveMemoryQuery = targetEntityID.map {
                .init(kinds: [.openQuestion], relatedTo: [$0], limit: 500)
            } ?? .init(kinds: [.openQuestion], limit: 500)
            let records = try await store.query(query, at: date)
            if let existing = records.first(where: { record in
                guard case let .openQuestion(q) = record.payload else { return false }
                return q.status == .open
                    && q.targetEntityID == targetEntityID
                    && q.question.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized.lowercased()
            }) {
                return existing.id
            }
            let id = UUID()
            _ = try await store.insert(
                CognitiveMemoryDraft(
                    tier: .mediumTerm,
                    summary: "Open information need: \(normalized)",
                    payload: .openQuestion(OpenQuestionMemory(
                        question: normalized,
                        targetEntityID: targetEntityID,
                        expectedInformationGain: expectedInformationGain,
                        status: .open
                    )),
                    confidence: 0.7,
                    provenance: [
                        MemoryProvenance(
                            source: .l1Inference,
                            sourceID: sourceID,
                            observedAt: date,
                            evidenceIDs: ["info_need:\(targetEntityID?.uuidString.lowercased() ?? "any")"],
                            modelID: "gemma4:31b-cloud"
                        )
                    ],
                    sensitivity: .personal,
                    disclosure: .remoteSummaryAllowed,
                    expiresAt: date.addingTimeInterval(store.maximumMediumTermLifetime)
                ),
                id: id,
                at: date
            )
            return id
        } catch {
            onHealth("info_need_failed", String(error.localizedDescription.prefix(160)))
            return nil
        }
    }

    /// Pending (open) information needs scoped to a person, highest expected
    /// information gain first. Needs
    /// still inside their cooldown window are withheld so the robot does not
    /// re-ask the same thing every conversation. `respectCooldown: false`
    /// reports the full open set — used when the person explicitly asks what
    /// the robot still wants to learn, where withholding would answer "none"
    /// despite open needs existing.
    func pendingInformationNeeds(
        for entityID: UUID,
        at date: Date = Date(),
        respectCooldown: Bool = true
    ) async -> [PersistedInformationNeed] {
        guard let store else { return [] }
        let records = (try? await store.query(
            .init(kinds: [.openQuestion], relatedTo: [entityID], limit: 500),
            at: date
        )) ?? []
        return records.compactMap { record -> PersistedInformationNeed? in
            guard case let .openQuestion(q) = record.payload, q.status == .open else { return nil }
            if respectCooldown, let cooldown = q.cooldownUntil, cooldown > date { return nil }
            return PersistedInformationNeed(
                motiveID: record.id,
                question: q.question,
                targetEntityID: q.targetEntityID,
                expectedInformationGain: q.expectedInformationGain,
                createdAt: record.updatedAt
            )
        }.sorted {
            if $0.expectedInformationGain != $1.expectedInformationGain {
                return $0.expectedInformationGain > $1.expectedInformationGain
            }
            return $0.createdAt > $1.createdAt
        }
    }

    /// Pending (open) information needs across all people, ordered by expected
    /// information gain, with cooldown withheld.
    func allPendingInformationNeeds(
        at date: Date = Date(),
        respectCooldown: Bool = true
    ) async -> [PersistedInformationNeed] {
        guard let store else { return [] }
        let records = (try? await store.query(
            .init(kinds: [.openQuestion], limit: 500),
            at: date
        )) ?? []
        return records.compactMap { record -> PersistedInformationNeed? in
            guard case let .openQuestion(q) = record.payload, q.status == .open else { return nil }
            if respectCooldown, let cooldown = q.cooldownUntil, cooldown > date { return nil }
            return PersistedInformationNeed(
                motiveID: record.id,
                question: q.question,
                targetEntityID: q.targetEntityID,
                expectedInformationGain: q.expectedInformationGain,
                createdAt: record.updatedAt
            )
        }.sorted {
            if $0.expectedInformationGain != $1.expectedInformationGain {
                return $0.expectedInformationGain > $1.expectedInformationGain
            }
            return $0.createdAt > $1.createdAt
        }
    }

    /// Puts the given open information needs into a cooldown window so they are
    /// not re-surfaced to L2 until the window passes. Called when the needs are
    /// actually handed to L2 as a mission. The window is configurable via
    /// `SOMA_L1_QUESTION_COOLDOWN_SECONDS` and defaults to 0 — no cooldown —
    /// so open questions stay visible to L1/L2 until they are actually
    /// answered, instead of vanishing for a day after one surface.
    func markInformationNeedsSurfaced(
        _ needs: [PersistedInformationNeed],
        cooldown: TimeInterval? = nil,
        at date: Date = Date()
    ) async {
        guard let store else { return }
        let effectiveCooldown = cooldown
            ?? somaEnvDouble("SOMA_L1_QUESTION_COOLDOWN_SECONDS", default: 0)
        guard effectiveCooldown > 0 else { return }
        let until = date.addingTimeInterval(effectiveCooldown)
        for need in needs {
            do {
                guard let previous = try await store.record(id: need.motiveID, at: date),
                      case let .openQuestion(q) = previous.payload,
                      q.status == .open else { continue }
                _ = try await store.correct(
                    id: need.motiveID,
                    replacement: CognitiveMemoryDraft(
                        tier: previous.tier,
                        summary: previous.summary,
                        payload: .openQuestion(OpenQuestionMemory(
                            question: q.question,
                            targetEntityID: q.targetEntityID,
                            expectedInformationGain: q.expectedInformationGain,
                            cooldownUntil: until,
                            status: .open
                        )),
                        confidence: previous.confidence,
                        provenance: previous.provenance,
                        sensitivity: previous.sensitivity,
                        disclosure: previous.disclosure,
                        expiresAt: previous.expiresAt
                    ),
                    reason: "information_need_surfaced",
                    at: date
                )
            } catch {
                // Non-fatal: a failed cooldown write just means the need may be
                // surfaced again next cycle.
            }
        }
    }

    /// Persists an acquired fact to the target person's durable profile before
    /// closing its open information need. A failed fact write leaves the need
    /// open, so the answer can never be lost by marking its motive complete.
    @discardableResult
    func resolveInformationNeed(
        motiveID: UUID,
        expectedTargetEntityID: UUID? = nil,
        acquiredFact: String? = nil,
        at date: Date = Date()
    ) async -> Bool {
        guard let store else { return false }
        do {
            guard let previous = try await store.record(id: motiveID, at: date),
                  case let .openQuestion(q) = previous.payload,
                  q.status == .open,
                  expectedTargetEntityID == nil || q.targetEntityID == expectedTargetEntityID else {
                return false
            }
            if let fact = acquiredFact?.trimmingCharacters(in: .whitespacesAndNewlines),
               !fact.isEmpty {
                guard let targetEntityID = q.targetEntityID,
                      await storePersonFact(fact, for: targetEntityID, at: date) else {
                    return false
                }
            }
            _ = try await store.correct(
                id: motiveID,
                expectedRevision: previous.revision,
                replacement: CognitiveMemoryDraft(
                    tier: previous.tier,
                    summary: "Resolved information need: \(q.question)",
                    payload: .openQuestion(OpenQuestionMemory(
                        question: q.question,
                        targetEntityID: q.targetEntityID,
                        expectedInformationGain: q.expectedInformationGain,
                        status: .resolved
                    )),
                    confidence: previous.confidence,
                    provenance: previous.provenance,
                    sensitivity: previous.sensitivity,
                    disclosure: previous.disclosure,
                    expiresAt: previous.expiresAt
                ),
                reason: "information_need_resolved",
                at: date
            )
            if let targetEntityID = q.targetEntityID {
                let remaining = await pendingInformationNeeds(
                    for: targetEntityID,
                    at: date,
                    respectCooldown: false
                )
                cacheInformationNeeds(remaining, for: targetEntityID)
            }
            onHealth("info_need_resolved", "motive=\(motiveID.uuidString.lowercased())")
            return true
        } catch let error as CognitiveMemoryError {
            if case .revisionConflict = error {
                let latest = try? await store.record(id: motiveID, at: Date())
                if let latest,
                   case let .openQuestion(question) = latest.payload,
                   question.status != .open {
                    return false
                }
            }
            onHealth("info_need_resolve_failed", String(error.localizedDescription.prefix(160)))
            return false
        } catch {
            onHealth("info_need_resolve_failed", String(error.localizedDescription.prefix(160)))
            return false
        }
    }

    /// Retires an information need whose premise was rejected or found to be
    /// unsupported. The historical record remains auditable, but it can no
    /// longer steer L1 or be surfaced to L2 as a future mission.
    @discardableResult
    func dismissInformationNeed(
        motiveID: UUID,
        reason: String,
        at date: Date = Date()
    ) async -> Bool {
        guard let store else { return false }
        do {
            guard let previous = try await store.record(id: motiveID, at: date),
                  case let .openQuestion(question) = previous.payload,
                  question.status == .open else {
                return false
            }
            _ = try await store.correct(
                id: motiveID,
                replacement: CognitiveMemoryDraft(
                    tier: previous.tier,
                    summary: "Dismissed information need: \(question.question)",
                    payload: .openQuestion(OpenQuestionMemory(
                        question: question.question,
                        targetEntityID: question.targetEntityID,
                        expectedInformationGain: question.expectedInformationGain,
                        status: .dismissed
                    )),
                    confidence: previous.confidence,
                    provenance: previous.provenance,
                    sensitivity: previous.sensitivity,
                    disclosure: previous.disclosure,
                    expiresAt: previous.expiresAt
                ),
                reason: String(reason.prefix(96)),
                at: date
            )
            if let entityID = question.targetEntityID {
                cacheInformationNeeds(
                    await pendingInformationNeeds(
                        for: entityID,
                        at: date,
                        respectCooldown: false
                    ),
                    for: entityID
                )
            }
            onHealth("info_need_dismissed", "motive=\(motiveID.uuidString.lowercased()); reason=\(String(reason.prefix(96)))")
            return true
        } catch {
            onHealth("info_need_dismiss_failed", String(error.localizedDescription.prefix(160)))
            return false
        }
    }

    /// Consume L1's model-proposed memory suggestions and persist those that
    /// clear the confidence bar. Person-linked kinds are bound to the recognized
    /// person when one is present; otherwise they degrade to a generic episode.
    @discardableResult
    func proposeMemories(
        _ proposals: [L1MemoryProposal],
        personEntityID: UUID?,
        at date: Date = Date()
    ) async -> [UUID] {
        guard let store else { return [] }
        var storedIDs: [UUID] = []
        for proposal in proposals where proposal.confidence >= 0.55 {
            guard proposal.kind != .relationship else {
                onHealth("memory_proposal_rejected", "kind=relationship; source=contact_evidence")
                continue
            }
            // A model may notice an uncertainty in an image, but an open
            // question becomes a future social obligation. Require an actual
            // participant turn from this cycle before making it durable.
            guard proposal.kind != .openQuestion || !proposal.sourceTurnRecordIDs.isEmpty else {
                onHealth("memory_proposal_rejected", "kind=open_question; reason=missing_participant_evidence")
                continue
            }
            do {
                let record = try await store.insert(
                    Self.draft(from: proposal, personEntityID: personEntityID, at: date),
                    at: date
                )
                storedIDs.append(record.id)
                onHealth("memory_proposal_stored", "kind=\(proposal.kind.rawValue)")
            } catch {
                onHealth("memory_proposal_store_failed", String(error.localizedDescription.prefix(192)))
            }
        }
        return storedIDs
    }

    private static func draft(
        from proposal: L1MemoryProposal,
        personEntityID: UUID?,
        at date: Date
    ) -> CognitiveMemoryDraft {
        let summary = proposal.summary
        let evidenceIDs = proposal.evidenceIDs + proposal.sourceTurnRecordIDs.map {
            "conversation_turn:\($0.uuidString.lowercased())"
        }
        let provenance = [MemoryProvenance(
            source: .l1Inference,
            sourceID: "l1_memory_proposal:\(proposal.kind.rawValue)",
            observedAt: date,
            evidenceIDs: evidenceIDs,
            modelID: "gemma4:31b-cloud"
        )]
        let payload: CognitiveMemoryPayload
        let tier: MemoryTier
        switch proposal.kind {
        case .personFact:
            let pid = personEntityID ?? UUID()
            payload = .personFact(PersonFactMemory(
                personEntityID: pid,
                key: stableFactKey(for: summary),
                value: summary
            ))
            tier = .mediumTerm
        case .openQuestion:
            payload = .openQuestion(OpenQuestionMemory(
                question: summary,
                targetEntityID: personEntityID,
                expectedInformationGain: proposal.confidence
            ))
            tier = .shortTerm
        case .relationship:
            payload = .relationship(RelationshipMemory(
                personEntityID: personEntityID ?? UUID(),
                rapport: RapportProfile(
                    familiarity: proposal.confidence,
                    interactionComfort: proposal.confidence,
                    communicationAlignment: proposal.confidence
                )
            ))
            tier = .mediumTerm
        case .task:
            payload = .task(TaskMemory(
                title: summary,
                status: .active,
                ownerEntityID: personEntityID
            ))
            tier = .mediumTerm
        default: // episode and correction degrade to a narrative episode
            payload = .episode(EpisodeMemory(
                startedAt: date,
                endedAt: date,
                participantEntityIDs: personEntityID.map { [$0] } ?? [],
                narrative: summary,
                salience: proposal.confidence
            ))
            tier = .mediumTerm
        }
        return CognitiveMemoryDraft(
            tier: tier,
            summary: summary,
            payload: payload,
            confidence: proposal.confidence,
            provenance: provenance,
            sensitivity: .personal,
            disclosure: .remoteSummaryAllowed,
            expiresAt: date.addingTimeInterval(30 * 24 * 60 * 60)
        )
    }

    private static func stableFactKey(for value: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        ).utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "learned_fact_\(String(hash, radix: 16))"
    }

    /// Keeps exact Live Voice turns on this Mac until a higher-layer memory
    /// pass turns them into typed facts, episodes, tasks, or questions.
    func beginConversation(threadID: String, personEntityID: UUID?) {
        let normalized = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, let store else { return }
        conversationLock.lock()
        defer { conversationLock.unlock() }
        if activeConversations[normalized] == nil {
            if activeConversations.count >= 32,
               let oldestThreadID = activeConversations.min(by: {
                   $0.value.startedAt < $1.value.startedAt
               })?.key {
                activeConversations.removeValue(forKey: oldestThreadID)
            }
            activeConversations[normalized] = ActiveConversation(
                archiver: ConversationTranscriptArchiver(
                    store: store,
                    interactionID: UUID(),
                    threadID: normalized,
                    participantEntityIDs: personEntityID.map { [$0] } ?? [],
                    retentionSeconds: transcriptRetentionSeconds
                ),
                turnWriteBarrier: ConversationTurnWriteBarrier(),
                startedAt: Date(),
                personEntityID: personEntityID,
                socialEpisode: L1ConversationContactEpisode()
            )
        }
    }

    func archiveConversationTurn(
        threadID: String,
        role: ConversationParticipantRole,
        rawText: String,
        at date: Date = Date()
    ) {
        let normalizedThreadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedThreadID.isEmpty, !normalizedText.isEmpty else { return }
        conversationLock.lock()
        let active = activeConversations[normalizedThreadID]
        var firstParticipantResponseEntityID: UUID?
        if var updated = active,
           updated.socialEpisode.observeFinalizedTurn(role: role) {
            activeConversations[normalizedThreadID] = updated
            firstParticipantResponseEntityID = updated.personEntityID
        }
        active?.turnWriteBarrier.beginWrite()
        conversationLock.unlock()
        guard let active else {
            onHealth("conversation_turn_unassociated", "role=\(role.rawValue); chars=\(normalizedText.count)")
            return
        }
        let writeGroup = conversationWriteGroup
        if let personEntityID = firstParticipantResponseEntityID {
            writeGroup.enter()
            Task { [weak self, writeGroup] in
                defer { writeGroup.leave() }
                _ = await self?.recordSocialContact(
                    .participantResponded,
                    with: personEntityID,
                    purpose: "The person supplied a finalized Live voice turn.",
                    at: date
                )
            }
        }
        writeGroup.enter()
        Task { [self, active, normalizedThreadID, normalizedText, role, date, writeGroup] in
            defer {
                active.turnWriteBarrier.finishWrite()
                writeGroup.leave()
            }
            do {
                _ = try await active.archiver.append(
                    role: role,
                    rawText: String(normalizedText.prefix(8_192)),
                    sourceEventID: "live_voice:\(normalizedThreadID):\(role.rawValue)",
                    at: date
                )
                self.onHealth(
                    "conversation_turn_stored",
                    "role=\(role.rawValue); chars=\(normalizedText.count); storage=encrypted_short_term"
                )
            } catch {
                self.onHealth("conversation_turn_store_failed", String(error.localizedDescription.prefix(192)))
            }
        }
    }

    /// Completes the durable social episode for a Live session. This records
    /// observed response and closure separately, so L1 can reason from a
    /// sequence rather than a fixed interval since the last invitation.
    func endConversation(
        threadID: String?,
        personEntityID: UUID?,
        interrupted: Bool,
        reason: String,
        at date: Date = Date()
    ) async -> Bool {
        let normalizedThreadID = threadID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let active = normalizedThreadID.flatMap { takeActiveConversation(threadID: $0) }
        let participantID = active?.personEntityID ?? personEntityID
        guard let participantID else { return true }
        if let active {
            await active.turnWriteBarrier.waitUntilDrained()
        }
        let boundedReason = String(reason.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        let kind = active?.socialEpisode.closureKind(interrupted: interrupted)
            ?? (interrupted ? .conversationInterrupted : .conversationEnded)
        let contactRecorded = await recordSocialContact(
            kind,
            with: participantID,
            purpose: boundedReason.isEmpty ? nil : boundedReason,
            at: date
        )
        if let active {
            await recordEpisode(
                personEntityID: participantID,
                archiver: active.archiver,
                startedAt: active.startedAt,
                endedAt: date,
                reason: boundedReason,
                at: date
            )
        }
        return contactRecorded
    }

    /// Recovers encrypted turns left pending by a prior process exit. Recovery
    /// uses the same transcript-to-memory path as a normal session closure, so
    /// a restart never turns an otherwise valid conversation into lost context.
    func recoverPendingConversationMemories(at date: Date = Date()) async {
        guard let store else { return }
        struct Recovery: Sendable {
            let interactionID: UUID
            let threadID: String
            let personEntityID: UUID
            var startedAt: Date
            var endedAt: Date
        }
        do {
            let pendingTurns = try await store.query(
                .init(tiers: [.shortTerm], kinds: [.conversationTurn], limit: 500),
                at: date
            )
            var recoveries: [UUID: Recovery] = [:]
            for record in pendingTurns {
                guard case let .conversationTurn(turn) = record.payload,
                      turn.consolidationState == .pending,
                      let personEntityID = turn.participantEntityIDs.first else {
                    continue
                }
                if var existing = recoveries[turn.interactionID] {
                    existing.startedAt = min(existing.startedAt, turn.finalizedAt)
                    existing.endedAt = max(existing.endedAt, turn.finalizedAt)
                    recoveries[turn.interactionID] = existing
                } else {
                    recoveries[turn.interactionID] = Recovery(
                        interactionID: turn.interactionID,
                        threadID: turn.threadID,
                        personEntityID: personEntityID,
                        startedAt: turn.finalizedAt,
                        endedAt: turn.finalizedAt
                    )
                }
            }
            let ordered = recoveries.values.sorted { $0.endedAt < $1.endedAt }
            guard !ordered.isEmpty else { return }
            onHealth("conversation_memory_recovery_started", "sessions=\(ordered.count)")
            var consolidated = 0
            for recovery in ordered.prefix(8) {
                let archiver = ConversationTranscriptArchiver(
                    store: store,
                    interactionID: recovery.interactionID,
                    threadID: recovery.threadID,
                    participantEntityIDs: [recovery.personEntityID],
                    retentionSeconds: transcriptRetentionSeconds
                )
                if await recordEpisode(
                    personEntityID: recovery.personEntityID,
                    archiver: archiver,
                    startedAt: recovery.startedAt,
                    endedAt: recovery.endedAt,
                    reason: "recovered_after_restart",
                    at: date
                ) {
                    consolidated += 1
                }
            }
            onHealth(
                "conversation_memory_recovery_finished",
                "sessions=\(ordered.count); consolidated=\(consolidated)"
            )
        } catch {
            onHealth("conversation_memory_recovery_failed", String(error.localizedDescription.prefix(192)))
        }
    }

    /// The service's synchronous shutdown path must not abandon a recorded
    /// Live-session consequences. The encrypted journal and social-event writes are local and bounded;
    /// a timeout is surfaced rather than pretending the closure persisted.
    @discardableResult
    func endConversationBeforeShutdown(
        threadID: String?,
        personEntityID: UUID?,
        reason: String,
        timeout: TimeInterval = 2
    ) -> Bool {
        let startedNS = DispatchTime.now().uptimeNanoseconds
        let transcriptDeadline = DispatchTime.now() + max(0.1, timeout / 2)
        let writesDrained = conversationWriteGroup.wait(timeout: transcriptDeadline) == .success
        if !writesDrained {
            onHealth("conversation_write_shutdown_drain_timeout", "reason=\(String(reason.prefix(96)))")
        }
        let elapsedNS = DispatchTime.now().uptimeNanoseconds - startedNS
        let remaining = max(0.1, timeout - (Double(elapsedNS) / 1_000_000_000))
        let completion = DispatchSemaphore(value: 0)
        let result = SynchronousWriteResult()
        Task { [weak self] in
            let persisted = await self?.endConversation(
                threadID: threadID,
                personEntityID: personEntityID,
                interrupted: true,
                reason: reason
            ) ?? false
            result.set(persisted)
            completion.signal()
        }
        let deadline = DispatchTime.now() + remaining
        guard completion.wait(timeout: deadline) == .success else {
            onHealth("social_contact_shutdown_finalize_timeout", "reason=\(String(reason.prefix(96)))")
            return false
        }
        guard result.read() == true else {
            onHealth("social_contact_shutdown_finalize_failed", "reason=\(String(reason.prefix(96)))")
            return false
        }
        return writesDrained
    }

    private func takeActiveConversation(threadID: String) -> ActiveConversation? {
        guard !threadID.isEmpty else { return nil }
        conversationLock.lock()
        defer { conversationLock.unlock() }
        return activeConversations.removeValue(forKey: threadID)
    }

    /// The audio path needs a synchronous, bounded lookup when it opens a
    /// Live session. The encrypted store remains the source of truth; this is
    /// only a small cache populated by normal context reads and MCP updates.
    func cachedPreferredLanguage(for personEntityID: UUID) -> String? {
        preferredLanguageLock.lock()
        defer { preferredLanguageLock.unlock() }
        return preferredLanguageByPersonID[personEntityID]
    }

    func cachedPersonMemoryMission(for personEntityID: UUID) -> PersonContextMission? {
        preferredLanguageLock.lock()
        defer { preferredLanguageLock.unlock() }
        return personContextByPersonID[personEntityID]?.mission
    }

    /// The most recently recalled durable memory projections for this person
    /// (including recognized-object taste facts), for surfacing in reactive
    /// speech context the same way the L1 proactive path does.
    func cachedPersonMemorySummaries(for personEntityID: UUID) -> [String] {
        preferredLanguageLock.lock()
        defer { preferredLanguageLock.unlock() }
        return personMemorySummariesByPersonID[personEntityID] ?? []
    }

    func warmContext(for personEntityID: UUID) {
        Task { _ = await context(for: personEntityID) }
    }

    /// Persists durable, enforceable per-person preferences captured from a
    /// live user turn. Runs on the L1 queue; extraction is a lightweight local
    /// model call and only writes when the user stated a new/changed preference.
    func captureUserPreferences(
        threadID: String?,
        role: ConversationParticipantRole,
        rawText: String,
        at date: Date = Date()
    ) async {
        guard role == .user else { return }
        let normalizedThreadID = threadID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedThreadID.isEmpty, !text.isEmpty else { return }
        guard let personEntityID = activePersonEntityID(forThread: normalizedThreadID), let store else { return }
        let extracted = await Self.extractUserPreferences(from: text)
        guard !extracted.isEmpty else { return }
        do {
            var changed = false
            let current = try await store.personContext(for: personEntityID, at: date)
            for (key, value) in extracted {
                guard PersonContextSnapshot.preferenceKeys.contains(key) else { continue }
                if current.facts[key]?.trimmingCharacters(in: .whitespacesAndNewlines) == value {
                    continue
                }
                _ = try await store.setExplicitPersonFact(
                    personEntityID: personEntityID,
                    key: key,
                    value: value,
                    sourceID: "l2_live_voice:\(normalizedThreadID)",
                    at: date
                )
                changed = true
            }
            if changed {
                cachePersonContext(try await store.personContext(for: personEntityID, at: date))
                onHealth("person_preference_captured", "entity=\(personEntityID.uuidString.lowercased()); keys=\(extracted.map(\.key).joined(separator: ","))")
            }
        } catch {
            onHealth("person_preference_capture_failed", String(error.localizedDescription.prefix(192)))
        }
    }

    private func activePersonEntityID(forThread threadID: String) -> UUID? {
        conversationLock.lock()
        defer { conversationLock.unlock() }
        return activeConversations[threadID]?.personEntityID
    }

    /// Just-in-time episodic recall for an active conversation turn: recalls
    /// episodes relevant to the user's latest message and returns their
    /// narratives so the live-voice runtime can append them as context.
    func recallEpisodesForTurn(
        threadID: String?,
        text: String,
        at date: Date = Date()
    ) async -> [String] {
        let normalizedThreadID = threadID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !normalizedThreadID.isEmpty,
              let personEntityID = activePersonEntityID(forThread: normalizedThreadID) else { return [] }
        return await recallEpisodes(entityID: personEntityID, query: text, at: date)
            .map { $0.context(at: date) }
    }

    /// Reads the stored preference directives for a person as one instruction
    /// string (used by the L1 packet and the L2 conversation context).
    func personPreferenceDirectives(for personEntityID: UUID) -> String {
        preferredLanguageLock.lock()
        defer { preferredLanguageLock.unlock() }
        guard let snapshot = personContextByPersonID[personEntityID] else { return "" }
        let directives = snapshot.preferenceDirectives()
        return directives.isEmpty ? "" : directives.joined(separator: " ")
    }

    /// Asks the local model whether the user stated any durable preference or
    /// request in this turn, and returns the extracted {key, value} pairs.
    private static func extractUserPreferences(
        from text: String
    ) async -> [(key: String, value: String)] {
        let allowed = PersonContextSnapshot.preferenceKeys.sorted().joined(separator: ", ")
        let prompt = """
        The user just said: "\(text)"
        Did they state a durable preference, how to address them, or an ongoing request?
        If yes, choose the matching key from this set: \(allowed).
        Return strict JSON only: {"preferences":[{"key":"...","value":"..."}]} or {"preferences":[]}.
        Keep each value short and concrete. If nothing durable was stated, return {"preferences":[]}.
        """
        guard let url = URL(string: "\(somaOllamaHost())/api/generate") else { return [] }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": ProcessInfo.processInfo.environment["SOMA_L1_MODEL"] ?? "gemma4:31b-cloud",
            "prompt": prompt,
            "stream": false,
            "think": false,
            "format": "json",
            "options": ["temperature": 0.1, "num_predict": 160],
        ])
        request.timeoutInterval = 15
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let outer = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = outer["response"] as? String,
                  let contentData = content.data(using: .utf8),
                  let parsed = try JSONSerialization.jsonObject(with: contentData) as? [String: Any],
                  let rawPreferences = parsed["preferences"] as? [[String: Any]] else {
                return []
            }
            return rawPreferences.compactMap { item -> (key: String, value: String)? in
                guard let key = item["key"] as? String,
                      let value = item["value"] as? String else { return nil }
                let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalizedKey.isEmpty, !normalizedValue.isEmpty else { return nil }
                return (normalizedKey, normalizedValue)
            }
        } catch {
            return []
        }
    }

    /// Seeds durable person facts for the local administrator from the control
    /// settings, so L1 neither asks for the name nor falls back to English.
    /// Facts are written only when absent: an explicit later correction by the
    /// user is never overwritten. The preferred language comes from the Mac's
    /// primary system language when the profile does not already declare one.
    func seedAdministratorContext(
        entityID: UUID,
        preferredAddress: String?,
        displayName: String?
    ) async {
        guard let store else { return }
        // The local administrator speaks Korean in this deployment; the Mac's
        // primary UI language is English, so do not trust Locale's first tag.
        // Prefer a Korean tag from the system list, falling back to ko.
        let languageTag = PersonContextFormat.normalizedLanguageTag(
            Locale.preferredLanguages.first { $0.lowercased().hasPrefix("ko") }
                ?? "ko"
        )
        do {
            let context = try await store.personContext(for: entityID)
            // The name the robot should use: the configured address form (e.g.
            // "형") wins, but the enrolled display name is the fallback. The
            // display name is always configured, so "learn the preferred name"
            // must never be invented as a pending need for the administrator.
            let address = preferredAddress?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let preferredName = (address?.isEmpty == false ? address : nil)
                ?? (name?.isEmpty == false ? name : nil)
            if let preferredName, context.facts["preferred_name"] == nil {
                try await store.setExplicitPersonFact(
                    personEntityID: entityID,
                    key: "preferred_name",
                    value: preferredName,
                    sourceID: "l1_administrator_seed"
                )
            }
            // Canonical profile motives are reconciled against the materialized
            // profile rather than a recency-limited event window.
            let seededContext = try await store.personContext(for: entityID)
            let openRecords = (try? await store.query(
                .init(kinds: [.openQuestion], relatedTo: [entityID], limit: 500),
                at: Date()
            )) ?? []
            for record in openRecords {
                guard case let .openQuestion(q) = record.payload,
                      q.status == .open,
                      Self.informationNeedSource(for: record).isSatisfied(by: seededContext)
                else { continue }
                _ = await resolveInformationNeed(motiveID: record.id, at: Date())
            }
            // Correct an accidental non-Korean tag (e.g. en-KR seeded earlier),
            // while leaving an already-Korean tag untouched.
            let currentLanguage = context.facts["preferred_language"]
            let isAlreadyKorean = currentLanguage?.lowercased().hasPrefix("ko") ?? false
            if let languageTag, !isAlreadyKorean {
                try await store.setExplicitPersonFact(
                    personEntityID: entityID,
                    key: "preferred_language",
                    value: languageTag,
                    sourceID: "l1_administrator_seed"
                )
            }
            cachePersonContext(try await store.personContext(for: entityID))
        } catch {
            onHealth("person_context_seed_failed", String(error.localizedDescription.prefix(192)))
        }
    }

    func currentDailyWorldMemory(at date: Date = Date()) async -> L1DailyWorldMemory? {
        guard let store else { return nil }
        let day = Self.localDayKey(for: date)
        do {
            let records = try await store.query(.init(kinds: [.situation], limit: 500), at: date)
            return records.compactMap { record -> L1DailyWorldMemory? in
                guard case let .situation(situation) = record.payload,
                      situation.state == "daily_world_memory:\(day)",
                      let data = record.summary.data(using: .utf8),
                      let memory = try? JSONDecoder().decode(L1DailyWorldMemory.self, from: data),
                      memory.localDay == day,
                      !memory.topics.isEmpty else {
                    return nil
                }
                return memory
            }.first
        } catch {
            onHealth("daily_world_memory_unavailable", String(error.localizedDescription.prefix(192)))
            return nil
        }
    }

    /// Claims the single public-world collection slot for the local calendar
    /// day. Persisting the attempt prevents a service restart from repeatedly
    /// asking the App Server for the same daily brief after a transient error.
    func claimDailyWorldMemoryCollectionSlot(at date: Date = Date()) async -> Bool {
        guard let store else { return true }
        let day = Self.localDayKey(for: date)
        let memoryState = "daily_world_memory:\(day)"
        let attemptState = "daily_world_memory_attempt:\(day)"
        do {
            let existing = try await store.query(.init(kinds: [.situation], limit: 500), at: date)
            let alreadyCollectedOrClaimed = existing.contains { record in
                guard case let .situation(situation) = record.payload else { return false }
                return situation.state == memoryState || situation.state == attemptState
            }
            guard !alreadyCollectedOrClaimed else { return false }
            let calendar = Calendar.autoupdatingCurrent
            // Must stay within the short-term retention policy (24h), which
            // this record's tier is subject to; a 2-day expiry was rejected by
            // validation. 23h covers the rest of the local day with margin.
            let expiry = calendar.date(byAdding: .hour, value: 23, to: date)!
            _ = try await store.insert(
                CognitiveMemoryDraft(
                    tier: .shortTerm,
                    summary: "Daily public-world collection attempt for local day \(day)",
                    payload: .situation(SituationMemory(state: attemptState)),
                    confidence: 1,
                    provenance: [MemoryProvenance(
                        source: .taskSystem,
                        sourceID: "daily_world_memory_scheduler",
                        observedAt: date,
                        evidenceIDs: [attemptState]
                    )],
                    sensitivity: .ordinary,
                    disclosure: .localOnly,
                    expiresAt: expiry
                ),
                at: date
            )
            return true
        } catch {
            onHealth("daily_world_memory_slot_unavailable", String(error.localizedDescription.prefix(192)))
            return false
        }
    }

    func storeDailyWorldMemory(_ memory: L1DailyWorldMemory, at date: Date = Date()) async {
        guard let store else { return }
        let day = Self.localDayKey(for: date)
        guard memory.localDay == day, !memory.topics.isEmpty else {
            onHealth("daily_world_memory_rejected", "reason=invalid_local_day_or_empty_topics")
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let summary = String(decoding: try encoder.encode(memory), as: UTF8.self)
            guard summary.utf8.count <= 4_096 else {
                onHealth("daily_world_memory_rejected", "reason=summary_too_large")
                return
            }
            let state = "daily_world_memory:\(day)"
            let expiry = Calendar.autoupdatingCurrent.date(byAdding: .day, value: 7, to: date)!
            let draft = CognitiveMemoryDraft(
                tier: .mediumTerm,
                summary: summary,
                payload: .situation(SituationMemory(state: state)),
                confidence: 0.70,
                provenance: [MemoryProvenance(
                    source: .taskSystem,
                    sourceID: "codex_app_server_luna",
                    observedAt: date,
                    evidenceIDs: ["daily_world_memory:\(day)"],
                    modelID: "gpt-5.6-luna"
                )],
                sensitivity: .ordinary,
                disclosure: .remoteSummaryAllowed,
                expiresAt: expiry
            )
            let existing = try await store.query(.init(kinds: [.situation], limit: 500), at: date)
                .first { record in
                    guard case let .situation(situation) = record.payload else { return false }
                    return situation.state == state
                }
            if let existing {
                _ = try await store.correct(
                    id: existing.id,
                    replacement: draft,
                    reason: "daily_world_memory_refresh",
                    at: date
                )
            } else {
                _ = try await store.insert(draft, at: date)
            }
            onHealth("daily_world_memory_stored", "day=\(day); topics=\(memory.topics.count); tier=medium_term")
        } catch {
            onHealth("daily_world_memory_store_failed", String(error.localizedDescription.prefix(192)))
        }
    }

    /// Administrator-only callers use this through the capability-gated MCP
    /// endpoint. The store supplies an explicitly shareable projection only.
    func registeredPersonContexts() async throws -> [PersonContextSnapshot] {
        guard let store else { throw L1MemoryContextRuntimeError.memoryUnavailable }
        let contexts = try await store.personContexts()
        contexts.forEach(cachePersonContext)
        return contexts
    }

    /// Executes an L2 person-context request in the owning L0 process. The MCP
    /// child only forwards this request over the current-user socket and never
    /// opens the encrypted journal itself.
    func applyPersonContext(_ request: PersonContextIPCRequest) async throws -> PersonContextSnapshot {
        guard let store else { throw L1MemoryContextRuntimeError.memoryUnavailable }
        guard request.operation != .recallEpisodes else {
            // Handled by the dedicated recallEpisodesProvider; not a person-
            // context mutation.
            throw L1MemoryContextRuntimeError.invalidPersonContextRequest
        }
        guard let personEntityID = request.personEntityID else {
            throw L1MemoryContextRuntimeError.invalidPersonContextRequest
        }
        let snapshot: PersonContextSnapshot
        switch request.operation {
        case .get:
            snapshot = try await store.personContext(for: personEntityID)
        case .setPreferredLanguage:
            guard request.confirmedByUser,
                  let rawTag = request.languageTag,
                  let languageTag = PersonContextFormat.normalizedLanguageTag(rawTag) else {
                throw L1MemoryContextRuntimeError.invalidPersonContextRequest
            }
            snapshot = try await store.setExplicitPersonFact(
                personEntityID: personEntityID,
                key: "preferred_language",
                value: languageTag
            )
        case .clearPreferredLanguage:
            guard request.confirmedByUser else { throw L1MemoryContextRuntimeError.invalidPersonContextRequest }
            snapshot = try await store.clearExplicitPersonFact(
                personEntityID: personEntityID,
                key: "preferred_language"
            )
        case .setContactPreference:
            guard request.confirmedByUser,
                  let preference = request.proactiveContact else {
                throw L1MemoryContextRuntimeError.invalidPersonContextRequest
            }
            snapshot = try await store.setExplicitPersonFact(
                personEntityID: personEntityID,
                key: "proactive_contact",
                value: preference.rawValue
            )
        case .setRapport:
            guard request.confirmedByUser,
                  let familiarity = request.familiarity,
                  let interactionComfort = request.interactionComfort,
                  let communicationAlignment = request.communicationAlignment,
                  let preference = request.proactiveContact else {
                throw L1MemoryContextRuntimeError.invalidPersonContextRequest
            }
            snapshot = try await store.setExplicitPersonRapport(
                personEntityID: personEntityID,
                rapport: RapportProfile(
                    familiarity: familiarity,
                    interactionComfort: interactionComfort,
                    communicationAlignment: communicationAlignment,
                    proactiveContact: preference
                )
            )
        case .setFact:
            guard request.confirmedByUser,
                  let key = request.factKey,
                  let value = request.factValue else {
                throw L1MemoryContextRuntimeError.invalidPersonContextRequest
            }
            snapshot = try await store.setExplicitPersonFact(
                personEntityID: personEntityID,
                key: key,
                value: value
            )
        case .removeFact:
            guard request.confirmedByUser, let key = request.factKey else {
                throw L1MemoryContextRuntimeError.invalidPersonContextRequest
            }
            snapshot = try await store.clearExplicitPersonFact(
                personEntityID: personEntityID,
                key: key
            )
        case .recallEpisodes:
            // Handled by the dedicated recallEpisodesProvider; not a person-
            // context mutation.
            throw L1MemoryContextRuntimeError.invalidPersonContextRequest
        }
        cachePersonContext(snapshot)
        return snapshot
    }

    private func cachePersonContext(_ snapshot: PersonContextSnapshot) {
        preferredLanguageLock.lock()
        let previous = preferredLanguageByPersonID[snapshot.personEntityID]
        preferredLanguageByPersonID[snapshot.personEntityID] = snapshot.preferredLanguageTag
        personContextByPersonID[snapshot.personEntityID] = snapshot
        preferredLanguageLock.unlock()
        guard previous != snapshot.preferredLanguageTag else { return }
        onPreferredLanguageChanged(snapshot.personEntityID, snapshot.preferredLanguageTag)
    }

    private func cachePersonMemorySummaries(_ summaries: [String], for personEntityID: UUID) {
        preferredLanguageLock.lock()
        personMemorySummariesByPersonID[personEntityID] = summaries
        preferredLanguageLock.unlock()
    }

    private func cacheInformationNeeds(_ needs: [PersistedInformationNeed], for personEntityID: UUID) {
        preferredLanguageLock.lock()
        personInfoNeedsByPersonID[personEntityID] = needs
        preferredLanguageLock.unlock()
    }

    /// Pending information needs for a person, for handing L2 an actionable
    /// acquisition mission in reactive speech context.
    func cachedPendingInformationNeeds(for personEntityID: UUID) -> [PersistedInformationNeed] {
        preferredLanguageLock.lock()
        defer { preferredLanguageLock.unlock() }
        return personInfoNeedsByPersonID[personEntityID] ?? []
    }

    private static func localDayKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func ensurePseudonymousEntity(
        _ entityID: UUID,
        in store: CognitiveMemoryStore,
        at date: Date
    ) async throws {
        guard try await store.record(id: entityID, at: date) == nil else { return }
        _ = try await store.insert(
            CognitiveMemoryDraft(
                tier: .mediumTerm,
                summary: "Locally pseudonymous recurring person",
                payload: .entity(EntityMemory(type: .person)),
                confidence: 0.80,
                provenance: [
                    MemoryProvenance(
                        source: .sensorSummary,
                        sourceID: "pseudonymous_face_identity",
                        observedAt: date,
                        evidenceIDs: ["identity:\(entityID.uuidString.lowercased())"],
                        modelID: "insightface-w600k-r50-coreml"
                    )
                ],
                sensitivity: .personal,
                disclosure: .localOnly,
                expiresAt: date.addingTimeInterval(179 * 24 * 60 * 60)
            ),
            id: entityID,
            at: date
        )
    }
}

/// Event-driven Gemma L1 adapter. It receives bounded situation packets only;
/// frames and audio never enter this transport. A single in-flight request plus
/// one pending slot prevents a slow cloud response from creating a backlog.
struct L1SituationRuntimeContext: Sendable {
    let spatialContext: L1SpatialContext?
    let dailyWorldMemory: L1DailyWorldMemory?
    let visualResourceOffers: [L1VisualResourceOffer]

    init(
        spatialContext: L1SpatialContext? = nil,
        dailyWorldMemory: L1DailyWorldMemory? = nil,
        visualResourceOffers: [L1VisualResourceOffer] = []
    ) {
        self.spatialContext = spatialContext
        self.dailyWorldMemory = dailyWorldMemory
        self.visualResourceOffers = Array(visualResourceOffers.prefix(8))
    }
}

struct L1SocialAvailability: Equatable, Sendable {
    let conversationActive: Bool
    let participantSpeaking: Bool

    init(conversationActive: Bool = false, participantSpeaking: Bool = false) {
        self.conversationActive = conversationActive
        self.participantSpeaking = participantSpeaking
    }
}

/// A process-local projection of the Live conversation lifecycle for L1
/// admission. It has no transcript or identity data: while a session is live,
/// new social initiatives are invalid for every presence observation.
final class L1LiveConversationStateRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var availability = L1SocialAvailability()

    func begin() {
        lock.lock()
        availability = L1SocialAvailability(conversationActive: true)
        lock.unlock()
    }

    func setParticipantSpeaking(_ speaking: Bool) {
        lock.lock()
        guard availability.conversationActive else {
            lock.unlock()
            return
        }
        availability = L1SocialAvailability(conversationActive: true, participantSpeaking: speaking)
        lock.unlock()
    }

    func end() {
        lock.lock()
        availability = L1SocialAvailability()
        lock.unlock()
    }

    func snapshot() -> L1SocialAvailability {
        lock.lock()
        defer { lock.unlock() }
        return availability
    }
}

final class L1DailyWorldMemoryRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var memory: L1DailyWorldMemory?

    func publish(_ memory: L1DailyWorldMemory?) {
        lock.lock()
        self.memory = memory
        lock.unlock()
    }

    func snapshot() -> L1DailyWorldMemory? {
        lock.lock()
        defer { lock.unlock() }
        return memory
    }
}

/// Converts recognized-person observations into sparse L1 cycles. Identity
/// evidence is a wake signal, not a command to speak. Repeated recognition is
/// locally coalesced before Gemma is contacted, and a late response is ignored.
final class L1ThoughtStreamRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var stream: (any L1ThoughtStreaming)?

    func install(_ stream: any L1ThoughtStreaming) {
        lock.lock()
        self.stream = stream
        lock.unlock()
    }

    func observe(_ decision: FaceIdentityRuntimeDecision, label: String?, at monotonicNS: UInt64) {
        lock.lock()
        let stream = self.stream
        lock.unlock()
        stream?.observe(decision, label: label, at: monotonicNS)
    }

    func depart(_ entityID: UUID) {
        lock.lock()
        let stream = self.stream
        lock.unlock()
        stream?.depart(entityID)
    }

    func invalidateMemoryContext(for entityID: UUID) {
        lock.lock()
        let stream = self.stream
        lock.unlock()
        stream?.invalidateMemoryContext(for: entityID)
    }

    func recordNonverbalInvitation(with entityID: UUID, at monotonicNS: UInt64) {
        lock.lock()
        let stream = self.stream
        lock.unlock()
        stream?.recordNonverbalInvitation(with: entityID, at: monotonicNS)
    }

    func recordCognitiveAction(_ episode: CognitiveActionEpisode) async -> Bool {
        let stream = currentStream()
        return await stream?.recordCognitiveAction(episode) ?? false
    }

    func reserveCognitiveAction(_ query: CognitiveActionQuery) async -> Bool {
        let stream = currentStream()
        return await stream?.reserveCognitiveAction(query) ?? false
    }

    private func currentStream() -> (any L1ThoughtStreaming)? {
        lock.lock()
        defer { lock.unlock() }
        return stream
    }

    func wakeFromAuxiliary(_ interrupt: L1AuxiliarySemanticInterrupt) {
        lock.lock()
        let stream = self.stream
        lock.unlock()
        stream?.wakeFromAuxiliary(interrupt)
    }

    func stop() {
        lock.lock()
        let stream = self.stream
        self.stream = nil
        lock.unlock()
        stream?.stop()
    }
}
