@preconcurrency import AVFoundation
import AudioToolbox
import CoreML
import CoreMedia
import CoreVideo
import CoreImage
import Foundation
import SOMACore
import SOMAOpenCV
import SOMAVADModel
@preconcurrency import Vision

private let somaSubconsciousResourceBundle: Bundle = {
    let bundleName = "SOMA_SOMASubconscious.bundle"
    let candidates = [
        Bundle.main.resourceURL?.appendingPathComponent(bundleName),
        Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent(bundleName, isDirectory: true),
        Bundle.main.bundleURL.appendingPathComponent(bundleName, isDirectory: true),
    ]
    for case let candidate? in candidates {
        if let bundle = Bundle(url: candidate) { return bundle }
    }
    return Bundle.module
}()

// MARK: - SOMA .env layer configuration helpers
/// Reads a boolean from a `SOMA_*` / `OLLAMA_*` environment variable that the
/// Control Center manages through `~/Library/Application Support/SOMA/.env`.
func somaEnvBool(_ key: String, default defaultValue: Bool) -> Bool {
    guard let raw = ProcessInfo.processInfo.environment[key] else { return defaultValue }
    switch raw.lowercased() {
    case "true", "1", "yes", "on": return true
    case "false", "0", "no", "off": return false
    default: return defaultValue
    }
}

func somaEnvDouble(_ key: String, default defaultValue: Double) -> Double {
    guard let raw = ProcessInfo.processInfo.environment[key],
          let value = Double(raw), value > 0 else { return defaultValue }
    return value
}

func somaEnvString(_ key: String, default defaultValue: String) -> String {
    guard let raw = ProcessInfo.processInfo.environment[key],
          !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return defaultValue }
    return raw.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// The base host of the local Ollama server (from `.env` `OLLAMA_HOST`).
func somaOllamaHost() -> String {
    let raw = ProcessInfo.processInfo.environment["OLLAMA_HOST"] ?? "http://127.0.0.1:11434"
    return raw.replacingOccurrences(of: "/$", with: "", options: .regularExpression)
}

/// Issues a lightweight warm-up generate request to the L1 model with a keep-
/// alive window, so the first real concurrent requests (situation analysis and
/// the language-directive generation) are not rejected with done_reason == "load"
/// while the model is still loading.
func warmUpL1Model() {
    let model = ProcessInfo.processInfo.environment["SOMA_L1_MODEL"] ?? "gemma4:31b-cloud"
    guard let url = URL(string: "\(somaOllamaHost())/api/generate") else { return }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let body: [String: Any] = [
        "model": model,
        "prompt": "ping",
        "stream": false,
        "think": false,
        "keep_alive": 600,
        "options": ["num_predict": 1],
    ]
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    request.timeoutInterval = 15
    URLSession.shared.dataTask(with: request).resume()
}


/// Runs registered graceful-stop closures when the process receives SIGTERM or
/// SIGINT (e.g. `launchctl bootout` from the menu bar "Stop SOMA"). Without this
/// the runtime is killed abruptly and the camera's built-in AI tracking is left
/// enabled, so it keeps following people after SOMA has been stopped.
private final class GracefulShutdown: @unchecked Sendable {
    private let lock = NSLock()
    private var actions: [() -> Void] = []
    private let source: DispatchSourceSignal

    init(signals: [Int32]) {
        for sig in signals { signal(sig, SIG_IGN) }
        let src = DispatchSource.makeSignalSource(
            signal: signals[0],
            queue: DispatchQueue.global(qos: .userInitiated)
        )
        self.source = src
        src.setEventHandler { [weak self] in self?.fire() }
        src.resume()
    }

    func onTerminate(_ action: @escaping () -> Void) {
        lock.lock()
        actions.append(action)
        lock.unlock()
    }

    private func fire() {
        lock.lock()
        let current = actions
        lock.unlock()
        current.forEach { $0() }
        // Give the shutdown command (AI-tracking off + park) time to flush
        // before the process exits.
        usleep(700_000)
        Foundation.exit(EXIT_SUCCESS)
    }
}

/// Mutable holder for the anonymous-registration review gate. The FaceIdentity
/// runtime consults `approve()` before surfacing a new anonymous identity; the
/// reviewer is installed once L1 setup is ready and otherwise defaults to allow.
final class AnonymousReviewBox: @unchecked Sendable {
    var reviewer: @Sendable () -> Bool = { true }
    func approve() -> Bool { reviewer() }
}

/// Accumulates L1's model-driven curiosity (information needs / topic goals)
/// about the interaction target and broader context, periodically collects
/// current web material on those topics via Ollama's hosted web_search, and
/// exposes the collected context so L1 can craft richer conversational openers.
final class L1CuriosityCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "soma.l1.curiosity")
    private let onHealth: @Sendable (String, String) -> Void
    private var topics: [String: Double] = [:]
    private var collected: [String: [CuriosityItem]] = [:]
    private var timer: DispatchSourceTimer?

    struct CuriosityItem {
        let title: String
        let url: String
        let snippet: String
    }

    init(onHealth: @escaping @Sendable (String, String) -> Void) {
        self.onHealth = onHealth
    }

    /// Accumulate curiosity topics from an L1 frame's information needs.
    /// Weighted by expected information gain, capped to the most valuable 24.
    func registerTopics(from needs: [L1InformationNeed]) {
        lock.lock()
        for need in needs {
            let topic = need.informationGoal.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !topic.isEmpty else { continue }
            topics[topic, default: 0] = max(topics[topic] ?? 0, need.expectedInformationGain)
        }
        if topics.count > 24 {
            let sorted = topics.sorted { $0.value > $1.value }.prefix(24).map { ($0.key, $0.value) }
            topics = Dictionary(uniqueKeysWithValues: sorted)
        }
        lock.unlock()
        onHealth("curiosity_topics", "count=\(topics.count)")
    }

    /// Kick off collection: an initial pass shortly after start, then repeat
    /// on the configured cadence. Honors SOMA_L1_CURIOSITY_ENABLED and
    /// SOMA_L1_CURIOSITY_INTERVAL_HOURS from the managed .env.
    func start() {
        guard somaEnvBool("SOMA_L1_CURIOSITY_ENABLED", default: true) else {
            onHealth("curiosity_collect", "state=disabled; reason=SOMA_L1_CURIOSITY_ENABLED")
            return
        }
        let intervalSeconds = Int(somaEnvDouble("SOMA_L1_CURIOSITY_INTERVAL_HOURS", default: 24) * 3600)
        queue.asyncAfter(deadline: .now() + .seconds(60)) { [weak self] in
            self?.collectAll()
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .seconds(intervalSeconds), repeating: .seconds(intervalSeconds))
        t.setEventHandler { [weak self] in
            self?.collectAll()
        }
        t.resume()
        timer = t
    }

    private func collectAll() {
        lock.lock()
        let snapshot = Array(topics.keys)
        lock.unlock()
        guard !snapshot.isEmpty else {
            onHealth("curiosity_collect", "state=idle; topics=0")
            return
        }
        var collectedThisRun = 0
        var failed = 0
        for topic in snapshot {
            let raw = performL1WebSearch(query: topic, maxResults: 4)
            guard let data = raw.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  obj["ok"] as? Bool == true,
                  let results = obj["results"] as? [[String: Any]] else {
                failed += 1
                continue
            }
            let items = results.compactMap { r -> CuriosityItem? in
                guard let title = r["title"] as? String else { return nil }
                return CuriosityItem(
                    title: title,
                    url: r["url"] as? String ?? "",
                    snippet: r["snippet"] as? String ?? ""
                )
            }
            lock.lock()
            collected[topic] = items
            lock.unlock()
            collectedThisRun += items.count
        }
        onHealth("curiosity_collect", "state=done; topics=\(snapshot.count); results=\(collectedThisRun); failed=\(failed)")
    }

    /// A compact summary of collected material, used to inform L1 openers.
    /// Returns an empty string when nothing has been collected yet.
    func contextSummary(limit: Int = 4) -> String {
        lock.lock()
        defer { lock.unlock() }
        guard !collected.isEmpty else { return "" }
        var lines: [String] = []
        let ordered = collected.keys.sorted { collected[$0]?.count ?? 0 > collected[$1]?.count ?? 0 }
        for topic in ordered.prefix(limit) {
            let items = collected[topic] ?? []
            guard !items.isEmpty else { continue }
            let head = items.prefix(2).map { "\($0.title): \($0.snippet)" }.joined(separator: " | ")
            lines.append("[\(topic)] \(head)")
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n")
    }
}

/// Synchronous L1 review of the current frame: asks the local Gemma model
/// whether the primary face is a real human worth tracking as an anonymous
/// identity. Runs only when a brand-new anonymous identity is about to be
/// created, so the blocking wait is rare and acceptable.
func l1PersonContextSummary(_ provider: L1MemoryContextProvider, for entityID: UUID) -> String {
    let semaphore = DispatchSemaphore(value: 0)
    let box = SynchronousResultBox<String>()
    Task { [provider] in
        let ctx = await provider.context(for: entityID)
        var facts: [String] = ctx.projections.map { $0.summary }
        if let rapport = ctx.rapport {
            facts.append("familiarity=\(rapport.familiarity)")
        }
        if !ctx.informationNeeds.isEmpty {
            facts.append("open_information_needs=\(ctx.informationNeeds.count)")
        }
        let joined = facts.prefix(12).joined(separator: " | ")
            .replacingOccurrences(of: "\"", with: "'")
        box.set(.success(#"{"ok":true,"projections":\#(facts.count),"summary":"\#(joined)"}"#))
        semaphore.signal()
    }
    semaphore.wait()
    if case let .success(summary)? = box.get() {
        return summary
    }
    return #"{"ok":false,"error":"no_context"}"#
}

func l1StorePersonFact(_ provider: L1MemoryContextProvider, for entityID: UUID, fact: String) -> String {
    let semaphore = DispatchSemaphore(value: 0)
    let box = SynchronousResultBox<Bool>()
    Task { [provider] in
        let stored = await provider.storePersonFact(fact, for: entityID)
        box.set(.success(stored))
        semaphore.signal()
    }
    semaphore.wait()
    if case let .success(stored)? = box.get() {
        return stored ? #"{"ok":true,"stored":true}"# : #"{"ok":false,"error":"store_unavailable"}"#
    }
    return #"{"ok":false,"error":"store_unavailable"}"#
}

func l1StoreSpaceObject(
    _ provider: L1MemoryContextProvider,
    name: String,
    category: String,
    description: String,
    spaceID: UUID
) -> String {
    let semaphore = DispatchSemaphore(value: 0)
    let box = SynchronousResultBox<Bool>()
    Task { [provider] in
        let stored = await provider.storeSpaceObject(
            name: name,
            category: category,
            description: description,
            spaceID: spaceID
        )
        box.set(.success(stored))
        semaphore.signal()
    }
    semaphore.wait()
    if case let .success(stored)? = box.get() {
        return stored ? #"{"ok":true,"stored":true}"# : #"{"ok":false,"error":"store_unavailable"}"#
    }
    return #"{"ok":false,"error":"store_unavailable"}"#
}

func l1SetSpaceOwner(
    _ provider: L1MemoryContextProvider,
    for entityID: UUID,
    spaceID: UUID
) -> String {
    let semaphore = DispatchSemaphore(value: 0)
    let box = SynchronousResultBox<Bool>()
    Task { [provider] in
        let stored = await provider.setSpaceOwner(entityID, spaceID: spaceID)
        box.set(.success(stored))
        semaphore.signal()
    }
    semaphore.wait()
    if case let .success(stored)? = box.get() {
        return stored ? #"{"ok":true,"owner_set":true}"# : #"{"ok":false,"error":"store_unavailable"}"#
    }
    return #"{"ok":false,"error":"store_unavailable"}"#
}

func l1SpaceStatus(_ provider: L1MemoryContextProvider, spaceID: UUID) -> String {
    let semaphore = DispatchSemaphore(value: 0)
    let box = SynchronousResultBox<String>()
    Task { [provider] in
        let owner = (await provider.spaceOwner(spaceID: spaceID))?.uuidString.lowercased() ?? ""
        let pending = await provider.pendingSpaceObjectCount(spaceID: spaceID)
        box.set(.success(#"{"ok":true,"space":"\#(spaceID.uuidString.lowercased())","owner":"\#(owner)","pending_space_objects":\#(pending)}"#))
        semaphore.signal()
    }
    semaphore.wait()
    if case let .success(status)? = box.get() {
        return status
    }
    return #"{"ok":false,"error":"unavailable"}"#
}

func l1GetInformationNeeds(_ provider: L1MemoryContextProvider, for entityID: UUID?) -> String {
    let semaphore = DispatchSemaphore(value: 0)
    let box = SynchronousResultBox<[PersistedInformationNeed]>()
    Task { [provider] in
        let needs: [PersistedInformationNeed]
        if let entityID {
            // The person explicitly asked: report the real open set, ignoring
            // the re-ask cooldown that would otherwise answer "none".
            needs = await provider.pendingInformationNeeds(for: entityID, respectCooldown: false)
        } else {
            needs = await provider.allPendingInformationNeeds(respectCooldown: false)
        }
        box.set(.success(needs))
        semaphore.signal()
    }
    semaphore.wait()
    if case let .success(needs)? = box.get() {
        let payloads = needs.map { need -> [String: Any] in
            [
                "motive_id": need.motiveID.uuidString.lowercased(),
                "question": need.question,
                "target_entity_id": need.targetEntityID?.uuidString.lowercased() ?? "",
                "expected_information_gain": need.expectedInformationGain,
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: ["ok": true, "count": needs.count, "needs": payloads]),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
    }
    return #"{"ok":false,"error":"unavailable"}"#
}

func l1ResolveInformationNeed(
    _ provider: L1MemoryContextProvider,
    motiveID: UUID,
    acquiredFact: String?
) -> String {
    let semaphore = DispatchSemaphore(value: 0)
    let box = SynchronousResultBox<Bool>()
    Task { [provider] in
        let ok = await provider.resolveInformationNeed(motiveID: motiveID, acquiredFact: acquiredFact)
        box.set(.success(ok))
        semaphore.signal()
    }
    semaphore.wait()
    if case let .success(ok)? = box.get() {
        return ok ? #"{"ok":true,"resolved":true}"# : #"{"ok":false,"error":"not_open_or_unavailable"}"#
    }
    return #"{"ok":false,"error":"unavailable"}"#
}

func l1RecallEpisodes(_ provider: L1MemoryContextProvider, query: String, entityID: UUID?) -> String {
    let semaphore = DispatchSemaphore(value: 0)
    let box = SynchronousResultBox<String>()
    Task { [provider] in
        let recalled = await provider.recallEpisodes(query: query, entityID: entityID)
        let joined = recalled.joined(separator: " | ").replacingOccurrences(of: "\"", with: "'")
        box.set(.success(#"{"ok":true,"count":\#(recalled.count),"episodes":"\#(joined)"}"#))
        semaphore.signal()
    }
    semaphore.wait()
    if case let .success(summary)? = box.get() {
        return summary
    }
    return #"{"ok":false,"error":"recall_failed"}"#
}

private struct L1WebSearchResult: Decodable {
    let results: [ResultItem]?
    struct ResultItem: Decodable {
        let title: String?
        let url: String?
        let content: String?
    }
}

private struct L1WebFetchResult: Decodable {
    let title: String?
    let content: String?
}

/// Minimal Ollama /api/chat response decoder for the parallel object
/// identification call (image-based).
private struct L1ObjectIdentificationResponse: Decodable {
    let message: Message?
    struct Message: Decodable {
        let content: String?
    }
}

/// Calls Ollama's hosted web_search API. Requires OLLAMA_API_KEY.
func performL1WebSearch(query: String, maxResults: Int = 5) -> String {
    guard let key = ProcessInfo.processInfo.environment["OLLAMA_API_KEY"], !key.isEmpty else {
        return #"{"ok":false,"error":"OLLAMA_API_KEY not set; hosted web_search requires an Ollama API key"}"#
    }
    guard let url = URL(string: "https://ollama.com/api/web_search") else {
        return #"{"ok":false,"error":"bad_url"}"#
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    let body = ["query": query, "max_results": maxResults] as [String: Any]
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    request.timeoutInterval = 20
    let semaphore = DispatchSemaphore(value: 0)
    let box = SynchronousResultBox<String>()
    URLSession.shared.dataTask(with: request) { data, response, error in
        defer { semaphore.signal() }
        guard error == nil,
              let data,
              let decoded = try? JSONDecoder().decode(L1WebSearchResult.self, from: data),
              let results = decoded.results, !results.isEmpty else {
            let raw = data.flatMap { String(data: $0, encoding: .utf8) } ?? "no_data"
            box.set(.success(#"{"ok":false,"error":"search_failed","detail":"\#(String(raw.prefix(160)).replacingOccurrences(of: "\"", with: "'"))"}"#))
            return
        }
        let items = results.prefix(maxResults).map { item -> [String: String] in
            [
                "title": item.title ?? "",
                "url": item.url ?? "",
                "snippet": (item.content ?? "").prefix(400).replacingOccurrences(of: "\"", with: "'")
            ]
        }
        let payload = ["ok": true, "query": query, "results": items] as [String: Any]
        let encoded = (try? JSONSerialization.data(withJSONObject: payload)).flatMap { String(data: $0, encoding: .utf8) } ?? #"{"ok":false}"#
        box.set(.success(encoded))
    }.resume()
    semaphore.wait()
    if case let .success(value)? = box.get() { return value }
    return #"{"ok":false}"#
}

/// Calls Ollama's hosted web_fetch API. Requires OLLAMA_API_KEY.
func performL1WebFetch(url: String) -> String {
    guard let key = ProcessInfo.processInfo.environment["OLLAMA_API_KEY"], !key.isEmpty else {
        return #"{"ok":false,"error":"OLLAMA_API_KEY not set; hosted web_fetch requires an Ollama API key"}"#
    }
    guard let endpoint = URL(string: "https://ollama.com/api/web_fetch") else {
        return #"{"ok":false,"error":"bad_url"}"#
    }
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    request.httpBody = try? JSONSerialization.data(withJSONObject: ["url": url])
    request.timeoutInterval = 20
    let semaphore = DispatchSemaphore(value: 0)
    let box = SynchronousResultBox<String>()
    URLSession.shared.dataTask(with: request) { data, response, error in
        defer { semaphore.signal() }
        guard error == nil, let data,
              let decoded = try? JSONDecoder().decode(L1WebFetchResult.self, from: data),
              let content = decoded.content, !content.isEmpty else {
            let raw = data.flatMap { String(data: $0, encoding: .utf8) } ?? "no_data"
            box.set(.success(#"{"ok":false,"error":"fetch_failed","detail":"\#(String(raw.prefix(160)).replacingOccurrences(of: "\"", with: "'"))"}"#))
            return
        }
        let payload: [String: Any] = [
            "ok": true,
            "title": decoded.title ?? "",
            "content": String(content.prefix(2000)).replacingOccurrences(of: "\"", with: "'")
        ]
        let encoded = (try? JSONSerialization.data(withJSONObject: payload)).flatMap { String(data: $0, encoding: .utf8) } ?? #"{"ok":false}"#
        box.set(.success(encoded))
    }.resume()
    semaphore.wait()
    if case let .success(value)? = box.get() { return value }
    return #"{"ok":false}"#
}

/// Sends the given JPEG to the local L1 Gemma model (via Ollama /api/chat,
/// which accepts image input) and asks it to identify the object shown. Runs
/// as an independent inference, parallel to the conscious-stream cycle, and is
/// not part of the L1 situation workload. Returns a JSON string describing the
/// object.
func performL1ObjectIdentification(jpeg: Data) -> String {
    guard !jpeg.isEmpty else {
        return #"{"ok":false,"error":"empty_image"}"#
    }
    let model = ProcessInfo.processInfo.environment["SOMA_L1_MODEL"] ?? "gemma4:31b-cloud"
    guard let url = URL(string: "\(somaOllamaHost())/api/chat") else {
        return #"{"ok":false,"error":"bad_endpoint"}"#
    }
    let system = (
        "You are SOMA L1's object recognition helper. You are shown one camera frame. "
        + "Identify the single most prominent object in the frame (for example a specific "
        + "figurine, a bicycle, a book, a collectible). Be concrete and specific about what it "
        + "is, using general knowledge. Do not identify a person, do not infer private traits, "
        + "do not issue commands. "
        + "Reply with exactly one JSON object with keys: name (short noun), category, "
        + "description (2-3 sentences)."
    )
    let user = "Identify the most prominent object in this image and return the JSON."
    let messages: [[String: Any]] = [
        ["role": "system", "content": system],
        ["role": "user", "content": user, "images": [jpeg.base64EncodedString()]]
    ]
    let payload: [String: Any] = [
        "model": model,
        "messages": messages,
        "stream": false,
        "think": false,
        "options": ["temperature": 0, "num_predict": 384]
    ]
    guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
        return #"{"ok":false,"error":"encode_failed"}"#
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = body
    request.timeoutInterval = 40
    let semaphore = DispatchSemaphore(value: 0)
    let box = SynchronousResultBox<String>()
    URLSession.shared.dataTask(with: request) { data, _, error in
        defer { semaphore.signal() }
        guard error == nil, let data,
              let decoded = try? JSONDecoder().decode(L1ObjectIdentificationResponse.self, from: data),
              let content = decoded.message?.content else {
            let raw = data.flatMap { String(data: $0, encoding: .utf8) } ?? "no_data"
            box.set(.success(#"{"ok":false,"error":"ollama_failed","detail":"\#(String(raw.prefix(160)).replacingOccurrences(of: "\"", with: "'"))"}"#))
            return
        }
        // Best-effort: the model was asked for JSON; try to normalize the text.
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let clean = trimmed
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasPrefix("{"), let data = clean.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let enc = (try? JSONSerialization.data(withJSONObject: obj))
                .flatMap { String(data: $0, encoding: .utf8) }
            box.set(.success(enc ?? #"{"ok":false}"#))
            return
        }
        // Fall back to a text description wrapped as JSON.
        let payloadOut = ["ok": true, "raw": String(clean.prefix(600)).replacingOccurrences(of: "\"", with: "'")]
        let enc = (try? JSONSerialization.data(withJSONObject: payloadOut))
            .flatMap { String(data: $0, encoding: .utf8) } ?? #"{"ok":false}"#
        box.set(.success(enc))
    }.resume()
    semaphore.wait()
    if case let .success(value)? = box.get() { return value }
    return #"{"ok":false}"#
}

/// Sends the given background JPEG to the local L1 Gemma model (via Ollama
/// /api/chat) and asks it to classify the room/space it shows. Used by the
/// space trigger to decide which space the robot is currently in. Returns a
/// JSON string describing the room.
func performL1SpaceClassification(jpeg: Data) -> String {
    guard !jpeg.isEmpty else {
        return #"{"ok":false,"error":"empty_image"}"#
    }
    let model = ProcessInfo.processInfo.environment["SOMA_L1_MODEL"] ?? "gemma4:31b-cloud"
    guard let url = URL(string: "\(somaOllamaHost())/api/chat") else {
        return #"{"ok":false,"error":"bad_endpoint"}"#
    }
    let system = (
        "You are SOMA L1's space-recognition helper. You are shown one camera frame of a room or space. "
        + "Classify what kind of space this is (for example living room, study/office, bedroom, kitchen, "
        + "garage, workshop, hallway, balcony). Be concrete about the general character of the room from "
        + "the visible furniture, layout, and objects. Do not identify people, do not infer private traits, "
        + "do not issue commands. "
        + "Reply with exactly one JSON object with keys: label (short room type), description (2-3 sentences)."
    )
    let user = "Classify the kind of space shown in this image and return the JSON."
    let messages: [[String: Any]] = [
        ["role": "system", "content": system],
        ["role": "user", "content": user, "images": [jpeg.base64EncodedString()]]
    ]
    let payload: [String: Any] = [
        "model": model,
        "messages": messages,
        "stream": false,
        "think": false,
        "options": ["temperature": 0, "num_predict": 384]
    ]
    guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
        return #"{"ok":false,"error":"encode_failed"}"#
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = body
    request.timeoutInterval = 40
    let semaphore = DispatchSemaphore(value: 0)
    let box = SynchronousResultBox<String>()
    URLSession.shared.dataTask(with: request) { data, _, error in
        defer { semaphore.signal() }
        guard error == nil, let data,
              let decoded = try? JSONDecoder().decode(L1ObjectIdentificationResponse.self, from: data),
              let content = decoded.message?.content else {
            let raw = data.flatMap { String(data: $0, encoding: .utf8) } ?? "no_data"
            box.set(.success(#"{"ok":false,"error":"ollama_failed","detail":"\#(String(raw.prefix(160)).replacingOccurrences(of: "\"", with: "'"))"}"#))
            return
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let clean = trimmed
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasPrefix("{"), let data = clean.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let enc = (try? JSONSerialization.data(withJSONObject: obj))
                .flatMap { String(data: $0, encoding: .utf8) }
            box.set(.success(enc ?? #"{"ok":false}"#))
            return
        }
        let payloadOut = ["ok": true, "raw": String(clean.prefix(600)).replacingOccurrences(of: "\"", with: "'")]
        let enc = (try? JSONSerialization.data(withJSONObject: payloadOut))
            .flatMap { String(data: $0, encoding: .utf8) } ?? #"{"ok":false}"#
        box.set(.success(enc))
    }.resume()
    semaphore.wait()
    if case let .success(value)? = box.get() { return value }
    return #"{"ok":false}"#
}

func performL1AnonymousReview(
    frameURL: URL,
    onHealth: @escaping (String, String) -> Void
) -> Bool {
    guard FileManager.default.isReadableFile(atPath: frameURL.path),
          let imageData = try? Data(contentsOf: frameURL),
          imageData.count > 0,
          imageData.count <= 2 * 1_024 * 1_024 else {
        // No frame to review: fall back to allowing the identity.
        return true
    }
    let prompt = """
    Look at this current camera frame. Is the primary face a real human person who should be \
    tracked as an anonymous identity — not a photograph, screen, reflection, or non-human object? \
    If it is clearly a real person, set register_anonymous_identity to true. If it is noise, \
    ambiguous, or not clearly a real living person, set it to false. \
    Reply with strict JSON only: {"register_anonymous_identity":true} or {"register_anonymous_identity":false}.
    """
    let body: [String: Any] = [
        "model": "gemma4:31b-cloud",
        "prompt": prompt,
        "images": [imageData.base64EncodedString()],
        "stream": false,
        "think": false,
        "format": "json",
        "options": ["temperature": 0.2, "num_predict": 32]
    ]
    guard let url = URL(string: "\(somaOllamaHost())/api/generate") else { return true }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 20
    guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return true }
    request.httpBody = payload

    let semaphore = DispatchSemaphore(value: 0)
    let resultBox = SynchronousResultBox<(decision: Bool, healthMessage: String)>()
    URLSession.shared.dataTask(with: request) { data, response, error in
        defer { semaphore.signal() }
        guard error == nil,
              let data,
              let outer = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = outer["response"] as? String,
              let contentData = content.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: contentData) as? [String: Any],
              let register = parsed["register_anonymous_identity"] as? Bool else {
            resultBox.set(.success((true, error?.localizedDescription ?? "malformed_response")))
            return
        }
        resultBox.set(.success((register, register ? "approved" : "declined")))
    }.resume()
    semaphore.wait()
    let result: (decision: Bool, healthMessage: String)
    if case let .success(value)? = resultBox.get() {
        result = value
    } else {
        result = (true, "unavailable")
    }
    onHealth("reviewed", "decision=\(result.healthMessage)")
    return result.decision
}

private enum RuntimeError: LocalizedError {
    case invalidArgument(String)
    case unavailable(String)
    case unauthorized(String)
    case configuration(String)

    var errorDescription: String? {
        switch self {
        case .invalidArgument(let message),
                .unavailable(let message),
                .unauthorized(let message),
                .configuration(let message):
            return message
        }
    }
}

private struct Options {
    let duration: TimeInterval
    let videoID: String
    let audioID: String
    let outputURL: URL
    let traceRotationPolicy: JSONLRotationPolicy?
    let importantOutputURL: URL?
    let importantRotationPolicy: JSONLRotationPolicy?
    let guidedScenario: Bool
    let tdoaCalibrationURL: URL?
    let tdoaCalibrationOutputURL: URL?
    let allowCameraMotion: Bool
    let nativeGimbalHelperURL: URL?
    let nativeGimbalShutdownHelperURL: URL?
    let gimbalOutputURL: URL?
    let gimbalTraceRotationPolicy: JSONLRotationPolicy?
    let allowNativeHumanTracking: Bool
    let allowExternalGimbalControl: Bool
    let allowAutonomousScan: Bool
    let externalGimbalCalibrationURL: URL?
    let externalGimbalCalibrationOutputURL: URL?
    let diagnosticSnapshotURL: URL?
    let faceLockDiagnosticDirectoryURL: URL?
    let l1AuxiliaryVLMPythonURL: URL?
    let l1AuxiliaryVLMWorkerURL: URL?
    let l1AuxiliaryVLMModel: String?
    let embodimentShadowSocketURL: URL?
    let allowEmbodimentMotorControl: Bool
    let embodimentViewDirectoryURL: URL?
    let panoramaOutputURL: URL?
    let panoramaPlaceMemoryURL: URL?
    let cameraGeometryCalibrationURL: URL?
    let cameraGeometryCaptureDirectoryURL: URL?
    let panoramaStripScan: Bool
    let localSpeechLocaleIdentifier: String?
    let l2CodexBridgeURL: URL?
    let l2LiveVoice: Bool
    let controlSettingsURL: URL

    static func parse(_ arguments: [String]) throws -> Options {
        var duration: TimeInterval = 60
        var videoID: String?
        var audioID: String?
        var outputURL = defaultOutputURL()
        var traceMaximumMegabytes: Int?
        var traceRetainedFiles: Int?
        var importantOutputURL: URL?
        var importantMaximumMegabytes: Int?
        var importantRetainedFiles: Int?
        var guidedScenario = false
        var tdoaCalibrationURL: URL?
        var tdoaCalibrationOutputURL: URL?
        var allowCameraMotion = false
        var nativeGimbalHelperURL: URL?
        var nativeGimbalShutdownHelperURL: URL?
        var gimbalOutputURL: URL?
        var gimbalTraceMaximumMegabytes: Int?
        var gimbalTraceRetainedFiles: Int?
        var allowNativeHumanTracking = false
        var allowExternalGimbalControl = false
        var allowAutonomousScan = false
        var externalGimbalCalibrationURL: URL?
        var externalGimbalCalibrationOutputURL: URL?
        var diagnosticSnapshotURL: URL?
        var faceLockDiagnosticDirectoryURL: URL?
        var l1AuxiliaryVLMPythonURL: URL?
        var l1AuxiliaryVLMWorkerURL: URL?
        var l1AuxiliaryVLMModel: String?
        var embodimentShadowSocketURL: URL?
        var allowEmbodimentMotorControl = false
        var embodimentViewDirectoryURL: URL?
        var panoramaOutputURL: URL?
        var panoramaPlaceMemoryURL: URL?
        var cameraGeometryCalibrationURL: URL?
        var cameraGeometryCaptureDirectoryURL: URL?
        var panoramaStripScan = false
        var localSpeechLocaleIdentifier: String?
        var l2CodexBridgeURL: URL?
        var l2LiveVoice = false
        var controlSettingsURL = SOMAControlSettingsStore.defaultURL()
        var index = 0

        while index < arguments.count {
            switch arguments[index] {
            case "--duration":
                index += 1
                guard index < arguments.count,
                      let parsed = TimeInterval(arguments[index]),
                      parsed >= 0 else {
                    throw RuntimeError.invalidArgument("--duration must be 0 (continuous) or a positive number of seconds")
                }
                duration = parsed
            case "--video-id":
                index += 1
                guard index < arguments.count else {
                    throw RuntimeError.invalidArgument("--video-id requires the OBSBOT video unique ID")
                }
                videoID = arguments[index]
            case "--audio-id":
                index += 1
                guard index < arguments.count else {
                    throw RuntimeError.invalidArgument("--audio-id requires the OBSBOT microphone unique ID")
                }
                audioID = arguments[index]
            case "--output":
                index += 1
                guard index < arguments.count else {
                    throw RuntimeError.invalidArgument("--output requires a trace path")
                }
                outputURL = URL(fileURLWithPath: arguments[index])
            case "--trace-max-megabytes":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]) else {
                    throw RuntimeError.invalidArgument("--trace-max-megabytes requires a positive integer")
                }
                traceMaximumMegabytes = value
            case "--trace-retained-files":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]) else {
                    throw RuntimeError.invalidArgument("--trace-retained-files requires a positive integer")
                }
                traceRetainedFiles = value
            case "--important-output":
                index += 1
                guard index < arguments.count else {
                    throw RuntimeError.invalidArgument("--important-output requires a JSONL basename")
                }
                importantOutputURL = URL(fileURLWithPath: arguments[index])
            case "--important-max-megabytes":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]) else {
                    throw RuntimeError.invalidArgument("--important-max-megabytes requires a positive integer")
                }
                importantMaximumMegabytes = value
            case "--important-retained-files":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]) else {
                    throw RuntimeError.invalidArgument("--important-retained-files requires a positive integer")
                }
                importantRetainedFiles = value
            case "--guided-scenario":
                guidedScenario = true
            case "--tdoa-calibration":
                index += 1
                guard index < arguments.count else {
                    throw RuntimeError.invalidArgument("--tdoa-calibration requires a calibration JSON path")
                }
                tdoaCalibrationURL = URL(fileURLWithPath: arguments[index])
            case "--tdoa-calibrate":
                index += 1
                guard index < arguments.count else {
                    throw RuntimeError.invalidArgument("--tdoa-calibrate requires an output JSON path")
                }
                tdoaCalibrationOutputURL = URL(fileURLWithPath: arguments[index])
            case "--allow-camera-motion":
                allowCameraMotion = true
            case "--native-gimbal-helper":
                index += 1
                guard index < arguments.count else {
                    throw RuntimeError.invalidArgument("--native-gimbal-helper requires an executable path")
                }
                nativeGimbalHelperURL = URL(fileURLWithPath: arguments[index])
            case "--native-gimbal-shutdown-helper":
                index += 1
                guard index < arguments.count else {
                    throw RuntimeError.invalidArgument("--native-gimbal-shutdown-helper requires an executable path")
                }
                nativeGimbalShutdownHelperURL = URL(fileURLWithPath: arguments[index])
            case "--gimbal-output":
                index += 1
                guard index < arguments.count else {
                    throw RuntimeError.invalidArgument("--gimbal-output requires a JSONL trace path")
                }
                gimbalOutputURL = URL(fileURLWithPath: arguments[index])
            case "--gimbal-trace-max-megabytes":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]) else {
                    throw RuntimeError.invalidArgument("--gimbal-trace-max-megabytes requires a positive integer")
                }
                gimbalTraceMaximumMegabytes = value
            case "--gimbal-trace-retained-files":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]) else {
                    throw RuntimeError.invalidArgument("--gimbal-trace-retained-files requires a positive integer")
                }
                gimbalTraceRetainedFiles = value
            case "--allow-external-gimbal-control":
                allowExternalGimbalControl = true
            case "--allow-native-human-tracking":
                allowNativeHumanTracking = true
            case "--allow-autonomous-scan":
                allowAutonomousScan = true
            case "--external-gimbal-calibration":
                index += 1
                guard index < arguments.count else {
                    throw RuntimeError.invalidArgument("--external-gimbal-calibration requires a calibration JSON path")
                }
                externalGimbalCalibrationURL = URL(fileURLWithPath: arguments[index])
            case "--calibrate-external-gimbal":
                index += 1
                guard index < arguments.count else {
                    throw RuntimeError.invalidArgument("--calibrate-external-gimbal requires an output JSON path")
                }
                externalGimbalCalibrationOutputURL = URL(fileURLWithPath: arguments[index])
            case "--diagnostic-snapshot":
                index += 1
                guard index < arguments.count else {
                    throw RuntimeError.invalidArgument("--diagnostic-snapshot requires a JPEG output path")
                }
                diagnosticSnapshotURL = URL(fileURLWithPath: arguments[index])
            case "--face-lock-diagnostics":
                index += 1
                guard index < arguments.count else {
                    throw RuntimeError.invalidArgument("--face-lock-diagnostics requires a new directory path")
                }
                faceLockDiagnosticDirectoryURL = URL(fileURLWithPath: arguments[index])
            case "--l1-auxiliary-vlm-python":
                index += 1
                guard index < arguments.count else {
                    throw RuntimeError.invalidArgument("--l1-auxiliary-vlm-python requires an executable path")
                }
                l1AuxiliaryVLMPythonURL = URL(fileURLWithPath: arguments[index])
            case "--l1-auxiliary-vlm-worker":
                index += 1
                guard index < arguments.count else {
                    throw RuntimeError.invalidArgument("--l1-auxiliary-vlm-worker requires a Python worker path")
                }
                l1AuxiliaryVLMWorkerURL = URL(fileURLWithPath: arguments[index])
            case "--l1-auxiliary-vlm-model":
                index += 1
                guard index < arguments.count else {
                    throw RuntimeError.invalidArgument("--l1-auxiliary-vlm-model requires a local model directory")
                }
                l1AuxiliaryVLMModel = arguments[index]
            case "--embodiment-shadow-socket":
                index += 1
                guard index < arguments.count, arguments[index].hasPrefix("/") else {
                    throw RuntimeError.invalidArgument("--embodiment-shadow-socket requires an absolute Unix socket path")
                }
                embodimentShadowSocketURL = URL(fileURLWithPath: arguments[index])
            case "--allow-embodiment-motor-control":
                allowEmbodimentMotorControl = true
            case "--embodiment-view-directory":
                index += 1
                guard index < arguments.count, arguments[index].hasPrefix("/") else {
                    throw RuntimeError.invalidArgument("--embodiment-view-directory requires an absolute directory path")
                }
                embodimentViewDirectoryURL = URL(fileURLWithPath: arguments[index], isDirectory: true)
            case "--panorama-output":
                index += 1
                guard index < arguments.count,
                      arguments[index].hasPrefix("/"),
                      ["jpg", "jpeg"].contains(URL(fileURLWithPath: arguments[index]).pathExtension.lowercased()) else {
                    throw RuntimeError.invalidArgument("--panorama-output requires an absolute JPEG path")
                }
                panoramaOutputURL = URL(fileURLWithPath: arguments[index])
            case "--panorama-place-memory":
                index += 1
                guard index < arguments.count,
                      arguments[index].hasPrefix("/"),
                      URL(fileURLWithPath: arguments[index]).pathExtension.lowercased() == "json" else {
                    throw RuntimeError.invalidArgument("--panorama-place-memory requires an absolute JSON path")
                }
                panoramaPlaceMemoryURL = URL(fileURLWithPath: arguments[index])
            case "--camera-geometry-calibration":
                index += 1
                guard index < arguments.count,
                      arguments[index].hasPrefix("/"),
                      URL(fileURLWithPath: arguments[index]).pathExtension.lowercased() == "json" else {
                    throw RuntimeError.invalidArgument("--camera-geometry-calibration requires an absolute JSON path")
                }
                cameraGeometryCalibrationURL = URL(fileURLWithPath: arguments[index])
            case "--capture-camera-geometry":
                index += 1
                guard index < arguments.count, arguments[index].hasPrefix("/") else {
                    throw RuntimeError.invalidArgument("--capture-camera-geometry requires an absolute new directory path")
                }
                cameraGeometryCaptureDirectoryURL = URL(fileURLWithPath: arguments[index])
            case "--panorama-strip-scan":
                panoramaStripScan = true
            case "--local-speech-recognition":
                index += 1
                guard index < arguments.count else {
                    throw RuntimeError.invalidArgument("--local-speech-recognition requires a locale such as ko-KR or en-US")
                }
                localSpeechLocaleIdentifier = arguments[index]
            case "--l2-codex-bridge":
                index += 1
                guard index < arguments.count, arguments[index].hasPrefix("/") else {
                    throw RuntimeError.invalidArgument("--l2-codex-bridge requires an absolute executable path")
                }
                l2CodexBridgeURL = URL(fileURLWithPath: arguments[index])
            case "--l2-live-voice":
                l2LiveVoice = true
            case "--soma-settings":
                index += 1
                guard index < arguments.count, arguments[index].hasPrefix("/") else {
                    throw RuntimeError.invalidArgument("--soma-settings requires an absolute JSON path")
                }
                controlSettingsURL = URL(fileURLWithPath: arguments[index])
            case "--help", "-h":
                printUsage()
                Foundation.exit(EXIT_SUCCESS)
            default:
                throw RuntimeError.invalidArgument("Unknown argument: \(arguments[index])")
            }
            index += 1
        }

        guard let videoID, let audioID else {
            throw RuntimeError.invalidArgument("--video-id and --audio-id are required. Use `swift run soma-probe --list-formats` first.")
        }
        let traceRotationPolicy = try rotationPolicy(
            maximumMegabytes: traceMaximumMegabytes,
            retainedFiles: traceRetainedFiles,
            optionPrefix: "trace"
        )
        let importantRotationPolicy = try rotationPolicy(
            maximumMegabytes: importantMaximumMegabytes,
            retainedFiles: importantRetainedFiles,
            optionPrefix: "important"
        )
        if (importantOutputURL == nil) != (importantRotationPolicy == nil) {
            throw RuntimeError.invalidArgument("--important-output, --important-max-megabytes, and --important-retained-files must be supplied together")
        }
        if importantOutputURL == outputURL {
            throw RuntimeError.invalidArgument("--important-output must differ from --output")
        }
        let gimbalTraceRotationPolicy = try rotationPolicy(
            maximumMegabytes: gimbalTraceMaximumMegabytes,
            retainedFiles: gimbalTraceRetainedFiles,
            optionPrefix: "gimbal-trace"
        )
        if gimbalTraceRotationPolicy != nil, gimbalOutputURL == nil {
            throw RuntimeError.invalidArgument("Gimbal trace rotation requires --gimbal-output")
        }
        if guidedScenario, duration != GuidedScenarioPhase.duration {
            throw RuntimeError.invalidArgument("--guided-scenario requires --duration 50")
        }
        if tdoaCalibrationOutputURL != nil, duration != TDOACalibrationPhase.duration {
            throw RuntimeError.invalidArgument("--tdoa-calibrate requires --duration 45")
        }
        if guidedScenario, tdoaCalibrationOutputURL != nil {
            throw RuntimeError.invalidArgument("--guided-scenario and --tdoa-calibrate cannot run together")
        }
        if tdoaCalibrationURL != nil, tdoaCalibrationOutputURL != nil {
            throw RuntimeError.invalidArgument("Choose either --tdoa-calibration or --tdoa-calibrate")
        }
        let wantsExternalControl = allowExternalGimbalControl || allowAutonomousScan
            || allowEmbodimentMotorControl || panoramaStripScan
            || externalGimbalCalibrationURL != nil || externalGimbalCalibrationOutputURL != nil
        let wantsActuation = allowCameraMotion || nativeGimbalHelperURL != nil
            || nativeGimbalShutdownHelperURL != nil || gimbalOutputURL != nil
            || wantsExternalControl || allowNativeHumanTracking
        if wantsActuation {
            guard allowCameraMotion, let nativeGimbalHelperURL, let gimbalOutputURL else {
                throw RuntimeError.invalidArgument("Camera motion requires --allow-camera-motion, --native-gimbal-helper, and --gimbal-output together")
            }
            guard duration.rounded() == duration,
                  duration == 0 || (duration >= 1 && duration <= 30) else {
                throw RuntimeError.invalidArgument("Camera-motion runs require an integer --duration of 0 (continuous) or 1...30 seconds")
            }
            guard !guidedScenario, tdoaCalibrationOutputURL == nil else {
                throw RuntimeError.invalidArgument("Camera motion cannot be combined with guided scenarios or TDOA calibration")
            }
            guard FileManager.default.isExecutableFile(atPath: nativeGimbalHelperURL.path) else {
                throw RuntimeError.invalidArgument("Native gimbal helper is not executable: \(nativeGimbalHelperURL.path)")
            }
            if let nativeGimbalShutdownHelperURL,
               !FileManager.default.isExecutableFile(atPath: nativeGimbalShutdownHelperURL.path) {
                throw RuntimeError.invalidArgument("Native gimbal shutdown helper is not executable: \(nativeGimbalShutdownHelperURL.path)")
            }
            guard !FileManager.default.fileExists(atPath: gimbalOutputURL.path) else {
                throw RuntimeError.invalidArgument("Gimbal trace already exists: \(gimbalOutputURL.path)")
            }
        }
        if wantsExternalControl, externalGimbalCalibrationOutputURL == nil {
            guard allowExternalGimbalControl, let externalGimbalCalibrationURL else {
                throw RuntimeError.invalidArgument("External control requires --allow-external-gimbal-control and --external-gimbal-calibration together")
            }
            guard FileManager.default.fileExists(atPath: externalGimbalCalibrationURL.path) else {
                throw RuntimeError.invalidArgument("External gimbal calibration is unavailable: \(externalGimbalCalibrationURL.path)")
            }
        }
        if allowAutonomousScan, !allowExternalGimbalControl {
            throw RuntimeError.invalidArgument("--allow-autonomous-scan requires --allow-external-gimbal-control")
        }
        if allowEmbodimentMotorControl {
            guard embodimentShadowSocketURL != nil,
                  embodimentViewDirectoryURL != nil,
                  allowExternalGimbalControl else {
                throw RuntimeError.invalidArgument("--allow-embodiment-motor-control requires --embodiment-shadow-socket, --embodiment-view-directory, and --allow-external-gimbal-control")
            }
        } else if embodimentViewDirectoryURL != nil {
            throw RuntimeError.invalidArgument("--embodiment-view-directory requires --allow-embodiment-motor-control")
        }
        if panoramaStripScan {
            guard panoramaOutputURL != nil,
                  allowAutonomousScan,
                  duration == 0 || duration == 30,
                  cameraGeometryCaptureDirectoryURL == nil else {
                throw RuntimeError.invalidArgument("--panorama-strip-scan requires --panorama-output, --allow-autonomous-scan, duration 0 or 30 seconds, and no geometry capture")
            }
        }
        if let calibrationOutputURL = externalGimbalCalibrationOutputURL {
            guard !allowExternalGimbalControl, !allowAutonomousScan, !allowNativeHumanTracking, externalGimbalCalibrationURL == nil else {
                throw RuntimeError.invalidArgument("External calibration cannot be combined with external control, scan, native tracking, or an input calibration")
            }
            guard duration >= 12 else {
                throw RuntimeError.invalidArgument("--calibrate-external-gimbal requires --duration of at least 12 seconds")
            }
            guard !FileManager.default.fileExists(atPath: calibrationOutputURL.path) else {
                throw RuntimeError.invalidArgument("External calibration output already exists: \(calibrationOutputURL.path)")
            }
        }
        if let diagnosticSnapshotURL {
            guard duration > 0, !FileManager.default.fileExists(atPath: diagnosticSnapshotURL.path) else {
                throw RuntimeError.invalidArgument("--diagnostic-snapshot requires a positive --duration and a new output path")
            }
        }
        if let faceLockDiagnosticDirectoryURL {
            guard !FileManager.default.fileExists(atPath: faceLockDiagnosticDirectoryURL.path) else {
                throw RuntimeError.invalidArgument("--face-lock-diagnostics requires a new directory path")
            }
        }
        if panoramaPlaceMemoryURL != nil, panoramaOutputURL == nil {
            throw RuntimeError.invalidArgument("--panorama-place-memory requires --panorama-output")
        }
        if let cameraGeometryCalibrationURL,
           !FileManager.default.fileExists(atPath: cameraGeometryCalibrationURL.path) {
            throw RuntimeError.invalidArgument("Camera geometry calibration is unavailable: \(cameraGeometryCalibrationURL.path)")
        }
        if let cameraGeometryCaptureDirectoryURL {
            guard panoramaOutputURL != nil,
                  duration == 0 || duration >= 30,
                  !FileManager.default.fileExists(atPath: cameraGeometryCaptureDirectoryURL.path) else {
                throw RuntimeError.invalidArgument("--capture-camera-geometry requires --panorama-output, duration 0 or at least 30 seconds, and a new directory")
            }
        }
        if let localSpeechLocaleIdentifier {
            guard !localSpeechLocaleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  localSpeechLocaleIdentifier.count <= 32 else {
                throw RuntimeError.invalidArgument("--local-speech-recognition requires a valid bounded locale identifier")
            }
        }
        if let l2CodexBridgeURL {
            guard localSpeechLocaleIdentifier != nil else {
                throw RuntimeError.invalidArgument("--l2-codex-bridge requires --local-speech-recognition")
            }
            guard FileManager.default.isExecutableFile(atPath: l2CodexBridgeURL.path) else {
                throw RuntimeError.invalidArgument("L2 Codex bridge is not executable: \(l2CodexBridgeURL.path)")
            }
        }
        if l2LiveVoice, l2CodexBridgeURL != nil {
            throw RuntimeError.invalidArgument("Choose either --l2-live-voice or --l2-codex-bridge")
        }
        if l2LiveVoice, localSpeechLocaleIdentifier != nil {
            throw RuntimeError.invalidArgument("--l2-live-voice uses direct audio and cannot be combined with --local-speech-recognition")
        }
        let l1AuxiliaryValuesPresent = [
            l1AuxiliaryVLMPythonURL != nil,
            l1AuxiliaryVLMWorkerURL != nil,
            l1AuxiliaryVLMModel != nil,
        ]
        if l1AuxiliaryValuesPresent.contains(true) {
            guard l1AuxiliaryValuesPresent.allSatisfy({ $0 }),
                  let l1AuxiliaryVLMPythonURL,
                  let l1AuxiliaryVLMWorkerURL,
                  let l1AuxiliaryVLMModel else {
                throw RuntimeError.invalidArgument("L1 auxiliary VLM requires its Python, worker, and model arguments together")
            }
            guard FileManager.default.isExecutableFile(atPath: l1AuxiliaryVLMPythonURL.path) else {
                throw RuntimeError.invalidArgument("L1 auxiliary VLM Python is not executable: \(l1AuxiliaryVLMPythonURL.path)")
            }
            guard FileManager.default.fileExists(atPath: l1AuxiliaryVLMWorkerURL.path) else {
                throw RuntimeError.invalidArgument("L1 auxiliary VLM worker is unavailable: \(l1AuxiliaryVLMWorkerURL.path)")
            }
            guard !l1AuxiliaryVLMModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RuntimeError.invalidArgument("--l1-auxiliary-vlm-model cannot be empty")
            }
            guard FileManager.default.fileExists(atPath: l1AuxiliaryVLMModel) else {
                throw RuntimeError.invalidArgument("L1 auxiliary VLM model is unavailable locally: \(l1AuxiliaryVLMModel)")
            }
        }
        return Options(
            duration: duration,
            videoID: videoID,
            audioID: audioID,
            outputURL: outputURL,
            traceRotationPolicy: traceRotationPolicy,
            importantOutputURL: importantOutputURL,
            importantRotationPolicy: importantRotationPolicy,
            guidedScenario: guidedScenario,
            tdoaCalibrationURL: tdoaCalibrationURL,
            tdoaCalibrationOutputURL: tdoaCalibrationOutputURL,
            allowCameraMotion: allowCameraMotion,
            nativeGimbalHelperURL: nativeGimbalHelperURL,
            nativeGimbalShutdownHelperURL: nativeGimbalShutdownHelperURL,
            gimbalOutputURL: gimbalOutputURL,
            gimbalTraceRotationPolicy: gimbalTraceRotationPolicy,
            allowNativeHumanTracking: allowNativeHumanTracking,
            allowExternalGimbalControl: allowExternalGimbalControl,
            allowAutonomousScan: allowAutonomousScan,
            externalGimbalCalibrationURL: externalGimbalCalibrationURL,
            externalGimbalCalibrationOutputURL: externalGimbalCalibrationOutputURL,
            diagnosticSnapshotURL: diagnosticSnapshotURL,
            faceLockDiagnosticDirectoryURL: faceLockDiagnosticDirectoryURL,
            l1AuxiliaryVLMPythonURL: l1AuxiliaryVLMPythonURL,
            l1AuxiliaryVLMWorkerURL: l1AuxiliaryVLMWorkerURL,
            l1AuxiliaryVLMModel: l1AuxiliaryVLMModel,
            embodimentShadowSocketURL: embodimentShadowSocketURL,
            allowEmbodimentMotorControl: allowEmbodimentMotorControl,
            embodimentViewDirectoryURL: embodimentViewDirectoryURL,
            panoramaOutputURL: panoramaOutputURL,
            panoramaPlaceMemoryURL: panoramaPlaceMemoryURL,
            cameraGeometryCalibrationURL: cameraGeometryCalibrationURL,
            cameraGeometryCaptureDirectoryURL: cameraGeometryCaptureDirectoryURL,
            panoramaStripScan: panoramaStripScan,
            localSpeechLocaleIdentifier: localSpeechLocaleIdentifier,
            l2CodexBridgeURL: l2CodexBridgeURL,
            l2LiveVoice: l2LiveVoice,
            controlSettingsURL: controlSettingsURL
        )
    }

    private static func defaultOutputURL() -> URL {
        let formatter = ISO8601DateFormatter()
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("artifacts/subconscious/subconscious-\(stamp).jsonl")
    }

    private static func rotationPolicy(
        maximumMegabytes: Int?,
        retainedFiles: Int?,
        optionPrefix: String
    ) throws -> JSONLRotationPolicy? {
        guard maximumMegabytes != nil || retainedFiles != nil else { return nil }
        guard let maximumMegabytes,
              let retainedFiles,
              maximumMegabytes > 0,
              retainedFiles > 0,
              maximumMegabytes <= Int.max / 1_048_576 else {
            throw RuntimeError.invalidArgument("--\(optionPrefix)-max-megabytes and --\(optionPrefix)-retained-files must be supplied together as positive integers")
        }
        return JSONLRotationPolicy(
            maximumBytes: maximumMegabytes * 1_048_576,
            retainedFiles: retainedFiles
        )
    }
}

private struct GuidedScenarioPhase {
    static let duration: TimeInterval = 50

    let startsAfterSeconds: TimeInterval
    let state: String
    let instruction: String

    static let phases = [
        GuidedScenarioPhase(startsAfterSeconds: 0, state: "prepare_out_of_frame", instruction: "0-5s: move fully outside the frame and become silent"),
        GuidedScenarioPhase(startsAfterSeconds: 5, state: "quiet_out_of_frame", instruction: "5-15s: remain outside the frame and silent"),
        GuidedScenarioPhase(startsAfterSeconds: 15, state: "enter_and_move", instruction: "15-25s: enter the frame and move normally"),
        GuidedScenarioPhase(startsAfterSeconds: 25, state: "speak_to_camera", instruction: "25-35s: face the camera and speak normally"),
        GuidedScenarioPhase(startsAfterSeconds: 35, state: "exit_and_silence", instruction: "35-45s: leave the frame and remain silent"),
        GuidedScenarioPhase(startsAfterSeconds: 45, state: "settle", instruction: "45-50s: remain out of frame and silent")
    ]
}

private struct TDOACalibrationPhase {
    static let duration: TimeInterval = 45

    let startsAfterSeconds: TimeInterval
    let position: TDOACalibrationPosition
    let instruction: String

    static let phases = [
        TDOACalibrationPhase(startsAfterSeconds: 0, position: .left, instruction: "0-15s: stand left of camera, face it, and speak naturally"),
        TDOACalibrationPhase(startsAfterSeconds: 15, position: .center, instruction: "15-30s: stand centered on camera, face it, and speak naturally"),
        TDOACalibrationPhase(startsAfterSeconds: 30, position: .right, instruction: "30-45s: stand right of camera, face it, and speak naturally")
    ]
}

private struct DeviceIdentity: Codable, Sendable {
    let name: String
    let uniqueID: String
    let modelID: String?
}

private struct VideoConfiguration {
    let requested: String
    let applied: Bool
    let detail: String
}

private struct RuntimeEvent: Encodable, Sendable {
    let event: String
    let monotonicNS: UInt64
    let source: String
    let state: String
    let message: String?
}

private struct BeliefEvent: Encodable, Sendable {
    let event = "subconscious.belief"
    let monotonicNS: UInt64
    let reason: String
    let belief: BeliefSnapshot
}

private struct VoiceEvent: Encodable, Sendable {
    let event = "voice.activity"
    let monotonicNS: UInt64
    let source: String
    let active: Bool
    let confidence: Double
    let levelDB: Double
}

private struct SpeechInteractionTraceEvent: Encodable, Sendable {
    let event = "speech.interaction"
    let monotonicNS: UInt64
    let state: String
    let speechStartedAtNS: UInt64?
    let speechEndedAtNS: UInt64?
    let preRollMilliseconds: UInt64?
    let audioChunkCount: Int?
    let transcriptCharacters: Int?
    let localeIdentifier: String?
    let confidence: Double?
    let latencyMilliseconds: Double?
    let handedToL2: Bool?
    let turnID: String?
    let responseCharacters: Int?
    let reason: String?

    init(_ value: LocalSpeechInteractionState, at monotonicNS: UInt64) {
        self.monotonicNS = monotonicNS
        switch value {
        case let .turnStarted(startedNS, preRollMS, chunkCount, authorization):
            state = "turn_started"
            speechStartedAtNS = startedNS
            speechEndedAtNS = nil
            preRollMilliseconds = preRollMS
            audioChunkCount = chunkCount
            transcriptCharacters = nil
            localeIdentifier = nil
            confidence = nil
            latencyMilliseconds = nil
            handedToL2 = nil
            turnID = nil
            responseCharacters = nil
            reason = authorization
        case let .turnCancelled(value):
            state = "turn_cancelled"
            speechStartedAtNS = nil
            speechEndedAtNS = nil
            preRollMilliseconds = nil
            audioChunkCount = nil
            transcriptCharacters = nil
            localeIdentifier = nil
            confidence = nil
            latencyMilliseconds = nil
            handedToL2 = nil
            turnID = nil
            responseCharacters = nil
            reason = value
        case let .recognitionCompleted(startedNS, endedNS, characters, locale, score, latencyMS, handedOff):
            state = "recognition_completed"
            speechStartedAtNS = startedNS
            speechEndedAtNS = endedNS
            preRollMilliseconds = nil
            audioChunkCount = nil
            transcriptCharacters = characters
            localeIdentifier = locale
            confidence = score
            latencyMilliseconds = latencyMS
            handedToL2 = handedOff
            turnID = nil
            responseCharacters = nil
            reason = nil
        case let .recognitionFailed(value):
            state = "recognition_failed"
            speechStartedAtNS = nil
            speechEndedAtNS = nil
            preRollMilliseconds = nil
            audioChunkCount = nil
            transcriptCharacters = nil
            localeIdentifier = nil
            confidence = nil
            latencyMilliseconds = nil
            handedToL2 = nil
            turnID = nil
            responseCharacters = nil
            reason = value
        case let .l2Completed(value, characters, latencyMS):
            state = "l2_completed"
            speechStartedAtNS = nil
            speechEndedAtNS = nil
            preRollMilliseconds = nil
            audioChunkCount = nil
            transcriptCharacters = nil
            localeIdentifier = nil
            confidence = nil
            latencyMilliseconds = latencyMS
            handedToL2 = true
            turnID = value
            responseCharacters = characters
            reason = nil
        case let .l2Failed(value, failure):
            state = "l2_failed"
            speechStartedAtNS = nil
            speechEndedAtNS = nil
            preRollMilliseconds = nil
            audioChunkCount = nil
            transcriptCharacters = nil
            localeIdentifier = nil
            confidence = nil
            latencyMilliseconds = nil
            handedToL2 = false
            turnID = value
            responseCharacters = nil
            reason = failure
        case let .speechStarted(value, characters, locale):
            state = "speech_started"
            speechStartedAtNS = nil
            speechEndedAtNS = nil
            preRollMilliseconds = nil
            audioChunkCount = nil
            transcriptCharacters = nil
            localeIdentifier = locale
            confidence = nil
            latencyMilliseconds = nil
            handedToL2 = true
            turnID = value
            responseCharacters = characters
            reason = nil
        case let .speechCompleted(value, durationMS):
            state = "speech_completed"
            speechStartedAtNS = nil
            speechEndedAtNS = nil
            preRollMilliseconds = nil
            audioChunkCount = nil
            transcriptCharacters = nil
            localeIdentifier = nil
            confidence = nil
            latencyMilliseconds = durationMS
            handedToL2 = true
            turnID = value
            responseCharacters = nil
            reason = nil
        case let .speechCancelled(value, cancellation):
            state = "speech_cancelled"
            speechStartedAtNS = nil
            speechEndedAtNS = nil
            preRollMilliseconds = nil
            audioChunkCount = nil
            transcriptCharacters = nil
            localeIdentifier = nil
            confidence = nil
            latencyMilliseconds = nil
            handedToL2 = true
            turnID = value
            responseCharacters = nil
            reason = cancellation
        }
    }
}

private final class ConversationContactRuntime: @unchecked Sendable {
    private struct DirectedContactHistory {
        private let continuityNS: UInt64 = 500_000_000
        private let windowNS: UInt64 = 45_000_000_000
        private var episodeStartsNS: [UInt64] = []
        private var activeSinceNS: UInt64?
        private var lastObservedNS: UInt64?

        mutating func observe(_ present: Bool, at monotonicNS: UInt64) {
            prune(at: monotonicNS)
            guard present else { return }
            let continues = lastObservedNS.map {
                monotonicNS >= $0 && monotonicNS - $0 <= continuityNS
            } ?? false
            if !continues {
                activeSinceNS = monotonicNS
                episodeStartsNS.append(monotonicNS)
            }
            lastObservedNS = monotonicNS
        }

        mutating func snapshot(at monotonicNS: UInt64) -> L1ContactPattern {
            prune(at: monotonicNS)
            let active = lastObservedNS.map {
                monotonicNS >= $0 && monotonicNS - $0 <= continuityNS
            } ?? false
            let latestAge = lastObservedNS.map {
                monotonicNS >= $0 ? Double(monotonicNS - $0) / 1_000_000_000 : 0
            }
            let activeDuration = active && activeSinceNS != nil
                ? Double(monotonicNS - activeSinceNS!) / 1_000_000_000
                : 0
            return L1ContactPattern(
                eyeContactActive: active,
                recentEpisodeCount: episodeStartsNS.count,
                latestEpisodeAgeSeconds: latestAge,
                activeDurationSeconds: activeDuration
            )
        }

        private mutating func prune(at monotonicNS: UInt64) {
            episodeStartsNS.removeAll { start in
                monotonicNS >= start && monotonicNS - start > windowNS
            }
            if let lastObservedNS,
               monotonicNS >= lastObservedNS,
               monotonicNS - lastObservedNS > continuityNS {
                activeSinceNS = nil
            }
        }
    }

    private let lock = NSLock()
    private var gate: ConversationContactGate
    private var directedContactHistory = DirectedContactHistory()
    private var l0FixationAdmission = L0FaceFixationAdmission()

    init() {
        gate = ConversationContactGate()
    }

    func observe(_ candidates: [SceneCandidate], at monotonicNS: UInt64) {
        let hasEyeContact = candidates.contains { candidate in
            candidate.observedThisFrame
                && candidate.observation.kind == .human
                && candidate.observation.label == "face"
                && candidate.isActionEligible
                && candidate.faceVerificationEligible
                && candidate.faceInteractionLivenessEligible
                && candidate.eyeContactEligible
        }
        lock.lock()
        directedContactHistory.observe(hasEyeContact, at: monotonicNS)
        lock.unlock()
    }

    func contactPattern(at monotonicNS: UInt64) -> L1ContactPattern {
        lock.lock()
        defer { lock.unlock() }
        return directedContactHistory.snapshot(at: monotonicNS)
    }

    /// The motor controller invokes this only after it has accepted a current
    /// verified face lock and cancelled exploration. The return value is a
    /// transition for bounded runtime diagnostics; it deliberately contains no
    /// identity or image data.
    func observeL0FaceFixation(
        sceneID: String?,
        directContact: Bool,
        at monotonicNS: UInt64
    ) -> L0FaceFixationAdmission.State? {
        lock.lock()
        defer { lock.unlock() }
        let previous = l0FixationAdmission.state(at: monotonicNS)
        if let sceneID {
            l0FixationAdmission.observeVerifiedFixation(
                sceneID: sceneID,
                directContact: directContact,
                at: monotonicNS
            )
        } else {
            l0FixationAdmission.clear()
        }
        let current = l0FixationAdmission.state(at: monotonicNS)
        return current == previous ? nil : current
    }

    func observeVoiceActivity(
        active: Bool,
        at monotonicNS: UInt64,
        confidence: Double,
        audioVisualDirectContact: Bool = false
    ) -> ConversationOpeningAuthorization? {
        lock.lock()
        defer { lock.unlock() }
        // Directed-contact history remains L1 social context. It cannot
        // authorize a new conversation on its own: either the current L0
        // fixation or the bounded same-face audiovisual episode must verify
        // direct contact. An already open conversation keeps its own
        // inactivity lease.
        let directContact = l0FixationAdmission.permitsNewSession(at: monotonicNS)
            || audioVisualDirectContact
        return gate.observeVoiceActivity(
            active: active,
            at: monotonicNS,
            directContact: directContact,
            voiceConfidence: confidence
        )
    }

    func markConversationOpened(at monotonicNS: UInt64) {
        lock.lock()
        gate.markConversationOpened(at: monotonicNS)
        lock.unlock()
    }

    func recordConversationActivity(at monotonicNS: UInt64) {
        lock.lock()
        gate.recordConversationActivity(at: monotonicNS)
        lock.unlock()
    }

    func closeConversation() {
        lock.lock()
        gate.closeConversation()
        lock.unlock()
    }
}

private struct AudioDirectionEvent: Encodable, Sendable {
    let event = "audio.direction"
    let monotonicNS: UInt64
    let direction: AudioDirection
    let confidence: Double
    let lagSamples: Int
    let fractionalLagSamples: Double
    let delayMilliseconds: Double
    let correlation: Double
}

private struct AudioSourceBearingEvent: Encodable, Sendable {
    let event = "audio.source"
    let monotonicNS: UInt64
    let requestID: String
    let terminalState: String
    let azimuthDegrees: Double
    let elevationDegrees: Double
    let startingAzimuthDegrees: Double
    let startingElevationDegrees: Double
    let displacementDegrees: Double
    let stabilityDegrees: Double
    let confidence: Double
    let sampleCount: Int

    init(
        monotonicNS: UInt64,
        requestID: String,
        terminalState: String,
        estimate: FirmwareSoundSourceEstimate,
        sampleCount: Int
    ) {
        self.monotonicNS = monotonicNS
        self.requestID = requestID
        self.terminalState = terminalState
        azimuthDegrees = estimate.bearing.azimuthDegrees
        elevationDegrees = estimate.bearing.elevationDegrees
        startingAzimuthDegrees = estimate.startingPose.panDegrees
        startingElevationDegrees = estimate.startingPose.pitchDegrees
        displacementDegrees = estimate.displacementDegrees
        stabilityDegrees = estimate.stabilityDegrees
        confidence = estimate.confidence
        self.sampleCount = sampleCount
    }
}

private struct VisionEvent: Encodable, Sendable {
    let event = "vision.observation"
    let monotonicNS: UInt64
    let source: VisualObservationSource
    let confidence: Double
    let kind: AttentionTargetKind
    let label: String?
    let attentionWeight: Double
    let attentionProbability: Double
    let attentionEntropy: Double
    let captureToBeliefMS: Double
}

private struct FaceIdentityEvent: Encodable, Sendable {
    let schemaVersion = 1
    let event = "identity.observation"
    let monotonicNS: UInt64
    let state: String
    let subject: String
    let confidence: Double
    let inferenceMS: Double
}

/// Face recognition remains a local, probabilistic signal. This tracker only
/// applies an administrator label after the encrypted profile matcher has
/// emitted its repeated-confirmation result, and it expires quickly when the
/// matching face is no longer observed.
private struct InteractionParticipant: Sendable {
    let entityID: UUID
    let authority: SOMAInteractionAuthority
}

private struct IdentityPresenceRuntimeEvent: Encodable, Sendable {
    let schemaVersion = 1
    let event = "identity.presence"
    let monotonicNS: UInt64
    let state: String
    let subject: String
    let previousSubject: String?
    let kind: String
    let confirmations: Int?
    let reason: String
}

/// Holds the most recent primary-face identity decision so a periodic trace
/// heartbeat can re-emit it. The menu bar only reads the tail of the trace, so
/// a sparse identity.observation (emitted only on state transitions) scrolls
/// out of its read window within seconds. Re-emitting the current state keeps a
/// fresh copy available while the face is still present; it is cleared on
/// departure so a stale identity is never replayed after the person leaves.
private final class LatestIdentityBox: @unchecked Sendable {
    private let lock = NSLock()
    private var state: String?
    private var subject: String?
    private var label: String?
    private var confidence: Double = 0
    private var observedNS: UInt64 = 0

    func update(state: String, subject: String, label: String, confidence: Double, observedNS: UInt64) {
        lock.lock(); defer { lock.unlock() }
        self.state = state
        self.subject = subject
        self.label = label
        self.confidence = confidence
        self.observedNS = observedNS
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        state = nil
        subject = nil
        label = nil
        confidence = 0
        observedNS = 0
    }

    func snapshot() -> (state: String, subject: String, label: String?, confidence: Double, observedNS: UInt64)? {
        lock.lock(); defer { lock.unlock() }
        guard let state, let subject else { return nil }
        return (state, subject, label, confidence, observedNS)
    }
}

/// Writes the current primary-face identity to a small always-current JSON file
/// that the menu bar reads directly (instead of scanning a huge trace tail).
private struct CurrentIdentityState: Encodable {
    let state: String
    let subject: String
    let label: String
    let confidence: Double
}

private func writeIdentityState(
    state: String,
    subject: String,
    label: String,
    confidence: Double,
    to url: URL
) throws {
    let snapshot = CurrentIdentityState(
        state: state,
        subject: subject,
        label: label,
        confidence: confidence
    )
    let data = try JSONEncoder().encode(snapshot)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    try data.write(to: url, options: .atomic)
}

private func clearIdentityState(at url: URL) {
    try? FileManager.default.removeItem(at: url)
}

private struct IdentityPresenceUpdate: Sendable {
    let transition: IdentityPresenceTransition
    let participant: InteractionParticipant?
}

/// Converts face-recognition samples into one socially meaningful presence
/// stream. Its state is local only: opaque IDs select person memory, never a
/// display name or a biometric projection.
private final class IdentityPresenceCoordinator: @unchecked Sendable {
    private let administrator: SOMAAdministratorIdentity?
    private let openWithUnknownIdentity: Bool
    private let lock = NSLock()
    private var tracker = IdentityPresenceTracker()
    private var latestParticipant: InteractionParticipant?

    init(administrator: SOMAAdministratorIdentity?, openWithUnknownIdentity: Bool = false) {
        self.administrator = administrator
        self.openWithUnknownIdentity = openWithUnknownIdentity
    }

    func observe(
        _ decision: FaceIdentityRuntimeDecision,
        at monotonicNS: UInt64
    ) -> [IdentityPresenceUpdate] {
        let identity: IdentityPresenceIdentity
        switch decision {
        case let .known(entityID, _, _):
            identity = IdentityPresenceIdentity(entityID: entityID, kind: .enrolled)
        case let .anonymous(entityID, _, _, _):
            identity = IdentityPresenceIdentity(entityID: entityID, kind: .pseudonymous)
        case let .unknownCandidate(handle, _):
            // When proactive openings with unknown identities are enabled, an
            // unrecognized face is treated as a pseudonymous participant so L1
            // may open with it. The entityID is derived from the anonymous
            // handle, so a later promotion to a registered anonymous identity
            // keeps the same participant identity.
            guard openWithUnknownIdentity else { return [] }
            identity = IdentityPresenceIdentity(
                entityID: FaceIdentityRuntime.pseudonymousEntityID(for: handle),
                kind: .pseudonymous
            )
        case .knownCandidate:
            return []
        }
        lock.lock()
        let updates = materialize(tracker.observe(identity, at: monotonicNS))
        lock.unlock()
        return updates
    }

    func observeVerifiedFace(_ present: Bool, at monotonicNS: UInt64) -> [IdentityPresenceUpdate] {
        lock.lock()
        defer { lock.unlock() }
        if present {
            tracker.recordVerifiedFace(at: monotonicNS)
        }
        return materialize(tracker.advance(at: monotonicNS))
    }

    func interactionReference() -> String? {
        guard let participant = currentParticipant() else { return nil }
        switch participant.authority {
        case .administrator:
            return "verified_local_administrator; person context is available only through the supplied local MCP reference"
        case .participant:
            return "locally recognized conversation participant; do not infer or speak a name beyond explicitly stored person context"
        }
    }

    func recognizedPersonEntityID() -> UUID? {
        currentParticipant()?.entityID
    }

    func authority(for personEntityID: UUID) -> SOMAInteractionAuthority {
        personEntityID == administrator?.entityID ? .administrator : .participant
    }

    func hasCurrentParticipant(_ personEntityID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return latestParticipant?.entityID == personEntityID
    }

    func currentParticipant() -> InteractionParticipant? {
        lock.lock()
        defer { lock.unlock() }
        return latestParticipant
    }

    private func materialize(_ transitions: [IdentityPresenceTransition]) -> [IdentityPresenceUpdate] {
        transitions.map { transition in
            switch transition {
            case let .arrived(identity):
                let participant = participant(for: identity)
                latestParticipant = participant
                return IdentityPresenceUpdate(
                    transition: transition,
                    participant: participant
                )
            case let .replaced(_, current):
                let participant = participant(for: current)
                latestParticipant = participant
                return IdentityPresenceUpdate(
                    transition: transition,
                    participant: participant
                )
            case let .departed(identity):
                if latestParticipant?.entityID == identity.entityID {
                    latestParticipant = nil
                }
                return IdentityPresenceUpdate(
                    transition: transition,
                    participant: nil
                )
            case .replacementCandidate:
                return IdentityPresenceUpdate(
                    transition: transition,
                    participant: nil
                )
            }
        }
    }

    private func participant(for identity: IdentityPresenceIdentity) -> InteractionParticipant {
        InteractionParticipant(
            entityID: identity.entityID,
            authority: identity.entityID == administrator?.entityID ? .administrator : .participant
        )
    }
}

/// Maintains a short, multi-person recognition window separately from the
/// single social participant stream. A speaker/interaction handoff remains a
/// deliberate one-person decision, while administrator MCP queries can still
/// report everyone independently recognized in the current view.
private final class PresentIdentityRoster: @unchecked Sendable {
    private struct Entry: Sendable {
        let identity: IdentityPresenceIdentity
        let confidence: Double
        let lastSeenNS: UInt64
        let anonymousHandle: AnonymousFaceHandle?
    }

    private let lock = NSLock()
    private let retentionNS: UInt64 = 3_000_000_000
    private var entries: [UUID: Entry] = [:]

    func record(_ decision: FaceIdentityRuntimeDecision, at monotonicNS: UInt64) {
        let identity: IdentityPresenceIdentity
        let anonymousHandle: AnonymousFaceHandle?
        switch decision {
        case let .known(entityID, _, _):
            identity = .init(entityID: entityID, kind: .enrolled)
            anonymousHandle = nil
        case let .anonymous(entityID, handle, _, _):
            identity = .init(entityID: entityID, kind: .pseudonymous)
            anonymousHandle = handle
        case .unknownCandidate, .knownCandidate:
            return
        }
        lock.lock()
        prune(at: monotonicNS)
        entries[identity.entityID] = Entry(
            identity: identity,
            confidence: decision.confidence,
            lastSeenNS: monotonicNS,
            anonymousHandle: anonymousHandle
        )
        lock.unlock()
    }

    func promoteableAnonymousHandle(
        for personEntityID: UUID,
        at monotonicNS: UInt64
    ) -> AnonymousFaceHandle? {
        lock.lock()
        defer { lock.unlock() }
        prune(at: monotonicNS)
        return entries[personEntityID]?.anonymousHandle
    }

    func entries(at monotonicNS: UInt64) -> [(identity: IdentityPresenceIdentity, confidence: Double, ageMS: UInt64)] {
        lock.lock()
        defer { lock.unlock() }
        prune(at: monotonicNS)
        return entries.values
            .map { entry in
                (
                    identity: entry.identity,
                    confidence: entry.confidence,
                    ageMS: monotonicNS >= entry.lastSeenNS
                        ? (monotonicNS - entry.lastSeenNS) / 1_000_000
                        : 0
                )
            }
            .sorted {
                if $0.ageMS != $1.ageMS { return $0.ageMS < $1.ageMS }
                return $0.identity.entityID.uuidString < $1.identity.entityID.uuidString
            }
    }

    private func prune(at monotonicNS: UInt64) {
        entries = entries.filter { _, entry in
            monotonicNS >= entry.lastSeenNS && monotonicNS - entry.lastSeenNS < retentionNS
        }
    }
}

/// Projects L1 runtime health into the deliberately small vocabulary used by
/// the live diagnostics panel. Runtime traces retain the original event for
/// audit; the panel must never become a second renderer for model prose.
private func l1PanelHealthEvent(state: String, message: String) -> (state: String, message: String)? {
    func value(_ key: String) -> String? {
        message
            .split(whereSeparator: { $0 == ";" || $0 == "·" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { $0.hasPrefix("\(key)=") }
            .map { String($0.dropFirst(key.count + 1)) }
    }

    switch state {
    case "consciousness_configured":
        return ("workspace_ready", "queue=executive,event,periodic · single_in_flight=true")
    case "workspace_created", "workspace_restored":
        return (state, message)
    case "evidence", "state_delta", "hypothesis_created", "hypothesis_updated",
         "hypothesis_active", "hypothesis_dormant", "hypothesis_abandoned", "hypothesis_resolved":
        return (state, message)
    case "thought_wake":
        return ("thought_wake", message)
    case "foreground_thought":
        return ("foreground_thought", message)
    case "cognitive_action":
        return ("cognitive_action", message)
    case "executive_wake", "executive_decision", "action_applied", "action_held",
         "thought_held", "thought_superseded", "executive_held":
        return (state, message)
    case "model_started":
        return ("model_started", message)
    case "model_response":
        return ("model_response_received", message)
    case "model_failed", "model_retry":
        return (state, message)
    case "l1_memory_proposals":
        let count = value("count").flatMap(Int.init) ?? 0
        return ("l1_memory_proposals", "count=\(max(0, count))")
    case "visual_followup":
        return ("visual_followup", "status=requested_context")
    case "visual_request_unavailable":
        return ("visual_request_unavailable", "status=context_unavailable")
    case "active_vision_completed", "active_vision_failed":
        return (state, message)
    case "discarded", "decision_rejected", "opening_suppressed":
        return (state, "reason=policy_or_context_guard")
    case "memory_ready", "memory_consolidated", "conversation_memory_consolidated", "conversation_memory_recovery_finished", "memory_proposal_stored", "daily_world_memory_stored", "person_fact_stored", "person_preference_captured":
        return ("memory_updated", "status=stored")
    case "conversation_memory_recovery_started", "episode_consolidation_deferred":
        return ("memory_deferred", "status=awaiting_consolidation")
    case "conversation_memory_recovery_failed", "memory_unavailable", "memory_consolidation_failed", "memory_proposal_store_failed", "daily_world_memory_store_failed", "person_fact_store_failed", "person_preference_capture_failed":
        return ("memory_deferred", "status=storage_unavailable")
    default:
        return nil
    }
}

private func identityDiagnosticLabel(
    for decision: FaceIdentityRuntimeDecision,
    administrator: SOMAAdministratorIdentity?
) -> String {
    switch decision {
    case let .known(entityID, similarity, _):
        if entityID == administrator?.entityID {
            let name = administrator?.preferredAddress ?? administrator?.displayName ?? "Administrator"
            return "\(name) · known \(String(format: "%.2f", similarity))"
        }
        return "known \(entityID.uuidString.prefix(8)) \(String(format: "%.2f", similarity))"
    case let .knownCandidate(entityID, similarity):
        return "candidate \(entityID.uuidString.prefix(8)) \(String(format: "%.2f", similarity))"
    case let .anonymous(entityID, _, similarity, _):
        return "anonymous \(entityID.uuidString.prefix(8)) \(String(format: "%.2f", similarity))"
    case .unknownCandidate:
        return "unknown"
    }
}

private func identityDisplayLabel(
    for decision: FaceIdentityRuntimeDecision,
    administrator: SOMAAdministratorIdentity?
) -> String {
    if case let .known(entityID, _, _) = decision,
       entityID == administrator?.entityID {
        return administrator?.preferredAddress ?? administrator?.displayName ?? "Administrator"
    }
    return identityDiagnosticLabel(for: decision, administrator: administrator)
}

private func identityPresenceRuntimeEvent(
    for transition: IdentityPresenceTransition,
    at monotonicNS: UInt64
) -> IdentityPresenceRuntimeEvent {
    func subject(_ identity: IdentityPresenceIdentity) -> String {
        identity.entityID.uuidString.lowercased()
    }
    switch transition {
    case let .arrived(identity):
        return IdentityPresenceRuntimeEvent(
            monotonicNS: monotonicNS,
            state: "arrived",
            subject: subject(identity),
            previousSubject: nil,
            kind: identity.kind.rawValue,
            confirmations: nil,
            reason: "recognized_identity"
        )
    case let .replacementCandidate(previous, candidate, confirmations):
        return IdentityPresenceRuntimeEvent(
            monotonicNS: monotonicNS,
            state: "replacement_candidate",
            subject: subject(candidate),
            previousSubject: subject(previous),
            kind: candidate.kind.rawValue,
            confirmations: confirmations,
            reason: "distinct_recognized_identity"
        )
    case let .replaced(previous, current):
        return IdentityPresenceRuntimeEvent(
            monotonicNS: monotonicNS,
            state: "replaced",
            subject: subject(current),
            previousSubject: subject(previous),
            kind: current.kind.rawValue,
            confirmations: nil,
            reason: "repeated_distinct_identity"
        )
    case let .departed(identity):
        return IdentityPresenceRuntimeEvent(
            monotonicNS: monotonicNS,
            state: "departed",
            subject: subject(identity),
            previousSubject: nil,
            kind: identity.kind.rawValue,
            confirmations: nil,
            reason: "verified_face_absent"
        )
    }
}

/// Forwards E2B's scalar wake proposal to the primary L1 stream, which is
/// created later in setup. The interrupt closure runs before the L1 stream
/// exists, so the proposal is buffered here and forwarded once the stream is up.
private final class L1AuxiliaryWakeRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (@Sendable (L1AuxiliarySemanticInterrupt) -> Void)?

    func record(_ interrupt: L1AuxiliarySemanticInterrupt) {
        lock.lock()
        let active = sink
        lock.unlock()
        active?(interrupt)
    }

    func attach(_ sink: @escaping @Sendable (L1AuxiliarySemanticInterrupt) -> Void) {
        lock.lock()
        self.sink = sink
        lock.unlock()
    }
}

/// Passes an auxiliary semantic verdict to the L0 owner. The L0 owner still
/// checks recency and scene identity before it can release a fixation.
private final class L1AuxiliaryHumanVerdictRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (@Sendable (L1AuxiliarySemanticCue) -> Void)?

    func record(_ cue: L1AuxiliarySemanticCue) {
        lock.lock()
        let active = sink
        lock.unlock()
        active?(cue)
    }

    func attach(_ sink: @escaping @Sendable (L1AuxiliarySemanticCue) -> Void) {
        lock.lock()
        self.sink = sink
        lock.unlock()
    }
}

private struct L1AuxiliarySemanticTraceEvent: Encodable, Sendable {
    let event = "l1.auxiliary.semantic"
    let requestID: UInt64
    let monotonicNS: UInt64
    let captureNS: UInt64
    let source: String
    let summary: String
    let targetID: String?
    let novelty: Double
    let socialPresence: Double
    let attentionHint: L1AuxiliaryAttentionHint
    let situation: L1AuxiliarySituation
    let wakeReason: L1AuxiliaryWakeReason
    let wakeScore: Double
    let confidence: Double
    let eyeContact: Double
    let engagement: Double
    let bodyLanguage: L1AuxiliaryBodyLanguage
    let gesture: L1AuxiliaryGesture
    let approach: L1AuxiliaryApproach
    let reaction: L1AuxiliaryReaction
    let inferenceMS: Double
    let captureToCueMS: Double

    init(_ cue: L1AuxiliarySemanticCue) {
        requestID = cue.requestID
        monotonicNS = cue.completedNS
        captureNS = cue.captureNS
        source = cue.source
        summary = cue.summary
        targetID = cue.targetID
        novelty = cue.novelty
        socialPresence = cue.socialPresence
        attentionHint = cue.attentionHint
        situation = cue.situation
        wakeReason = cue.wakeReason
        wakeScore = cue.wakeScore
        confidence = cue.confidence
        eyeContact = cue.eyeContact
        engagement = cue.engagement
        bodyLanguage = cue.bodyLanguage
        gesture = cue.gesture
        approach = cue.approach
        reaction = cue.reaction
        inferenceMS = cue.inferenceMS
        captureToCueMS = milliseconds(from: cue.captureNS, to: cue.completedNS)
    }
}

private struct L1AuxiliarySemanticInterruptTraceEvent: Encodable, Sendable {
    let event = "l1.auxiliary.wake_proposal"
    let requestID: UInt64
    let monotonicNS: UInt64
    let captureNS: UInt64
    let situation: L1AuxiliarySituation
    let reason: L1AuxiliaryWakeReason
    let score: Double
    let confidence: Double
    let evidence: String

    init(_ interrupt: L1AuxiliarySemanticInterrupt) {
        requestID = interrupt.requestID
        monotonicNS = interrupt.completedNS
        captureNS = interrupt.captureNS
        situation = interrupt.situation
        reason = interrupt.reason
        score = interrupt.score
        confidence = interrupt.confidence
        evidence = interrupt.evidence
    }
}

private struct EmbodimentShadowTraceEvent: Encodable, Sendable {
    let event = "embodiment.decision"
    let monotonicNS: UInt64
    let requestID: String
    let layer: CognitiveControlLayer
    let operation: CognitiveEmbodimentOperationKind
    let status: EmbodimentShadowStatus
    let reason: String
    let preemptedRequestID: String?
    let activeOwnerID: String?
    let activeOperation: CognitiveEmbodimentOperationKind?
    let activeTargetReference: String?
    let activePriority: UInt8?
    let registeredTargetCount: Int
    let attentionPolicyOwnerCount: Int
    let physicalActuationEnabled: Bool

    init(_ decision: EmbodimentShadowDecision) {
        monotonicNS = decision.snapshot.monotonicNS
        requestID = decision.requestID
        layer = decision.layer
        operation = decision.operation
        status = decision.status
        reason = decision.reason
        preemptedRequestID = decision.preemptedRequestID
        activeOwnerID = decision.snapshot.activeOwnerID
        activeOperation = decision.snapshot.activeOperation
        activeTargetReference = decision.snapshot.activeTargetReference
        activePriority = decision.snapshot.activePriority
        registeredTargetCount = decision.snapshot.registeredTargets.count
        attentionPolicyOwnerCount = decision.snapshot.attentionPolicyOwners.count
        physicalActuationEnabled = decision.snapshot.physicalActuationEnabled
    }
}

private struct EmbodimentMotorTraceEvent: Encodable, Sendable {
    let event = "embodiment.motor"
    let monotonicNS: UInt64
    let requestID: String?
    let action: String
    let reason: String?
    let targetReference: String?
    let sceneID: String?
    let targetAzimuthDegrees: Double?
    let targetElevationDegrees: Double?
    let fieldOfViewDegrees: Double?
    let observedThisFrame: Bool?
    let framingCenterX: Double?
    let framingCenterY: Double?
    let framingWidth: Double?
    let framingHeight: Double?
    let expiresAtNS: UInt64?

    init(_ intent: EmbodimentMotorIntent, monotonicNS: UInt64) {
        self.monotonicNS = monotonicNS
        switch intent {
        case let .orient(requestID, bearing, _, _, expiresAtNS, reason):
            self.requestID = requestID
            action = "orient"
            self.reason = reason
            targetReference = nil
            sceneID = nil
            targetAzimuthDegrees = bearing.azimuthDegrees
            targetElevationDegrees = bearing.elevationDegrees
            fieldOfViewDegrees = nil
            observedThisFrame = nil
            framingCenterX = nil
            framingCenterY = nil
            framingWidth = nil
            framingHeight = nil
            self.expiresAtNS = expiresAtNS
        case let .track(requestID, targetReference, sceneID, bearing, observed, framing, _, expiresAtNS):
            self.requestID = requestID
            action = "track"
            reason = nil
            self.targetReference = targetReference
            self.sceneID = sceneID
            targetAzimuthDegrees = bearing.azimuthDegrees
            targetElevationDegrees = bearing.elevationDegrees
            fieldOfViewDegrees = nil
            observedThisFrame = observed
            framingCenterX = framing?.centerX
            framingCenterY = framing?.centerY
            framingWidth = framing?.width
            framingHeight = framing?.height
            self.expiresAtNS = expiresAtNS
        case let .capture(requestID, targetReference, sceneID, bearing, fieldOfView, expiresAtNS):
            self.requestID = requestID
            action = "capture"
            reason = "capture_view_alignment"
            self.targetReference = targetReference
            self.sceneID = sceneID
            targetAzimuthDegrees = bearing.azimuthDegrees
            targetElevationDegrees = bearing.elevationDegrees
            fieldOfViewDegrees = fieldOfView
            observedThisFrame = nil
            framingCenterX = nil
            framingCenterY = nil
            framingWidth = nil
            framingHeight = nil
            self.expiresAtNS = expiresAtNS
        case let .captureCurrent(requestID, fieldOfView, expiresAtNS):
            self.requestID = requestID
            action = "capture_current"
            reason = "capture_view_current_frame"
            targetReference = nil
            sceneID = nil
            targetAzimuthDegrees = nil
            targetElevationDegrees = nil
            fieldOfViewDegrees = fieldOfView
            observedThisFrame = nil
            framingCenterX = nil
            framingCenterY = nil
            framingWidth = nil
            framingHeight = nil
            self.expiresAtNS = expiresAtNS
        case let .opticalZoom(requestID, factor):
            self.requestID = requestID
            action = "optical_zoom"
            reason = String(format: "factor=%.3f", factor)
            targetReference = nil
            sceneID = nil
            targetAzimuthDegrees = nil
            targetElevationDegrees = nil
            fieldOfViewDegrees = nil
            observedThisFrame = nil
            framingCenterX = nil
            framingCenterY = nil
            framingWidth = nil
            framingHeight = nil
            expiresAtNS = nil
        case let .audioCaptureMode(requestID, mode):
            self.requestID = requestID
            action = "audio_capture_mode"
            reason = mode.rawValue
            targetReference = nil
            sceneID = nil
            targetAzimuthDegrees = nil
            targetElevationDegrees = nil
            fieldOfViewDegrees = nil
            observedThisFrame = nil
            framingCenterX = nil
            framingCenterY = nil
            framingWidth = nil
            framingHeight = nil
            expiresAtNS = nil
        case let .audioInputGain(requestID, percent):
            self.requestID = requestID
            action = "audio_input_gain"
            reason = "percent=\(percent)"
            targetReference = nil
            sceneID = nil
            targetAzimuthDegrees = nil
            targetElevationDegrees = nil
            fieldOfViewDegrees = nil
            observedThisFrame = nil
            framingCenterX = nil
            framingCenterY = nil
            framingWidth = nil
            framingHeight = nil
            expiresAtNS = nil
        case let .cameraWhiteBalance(requestID, mode, temperatureKelvin):
            self.requestID = requestID
            action = "camera_white_balance"
            reason = temperatureKelvin.map { "\(mode.rawValue)=\($0)K" } ?? mode.rawValue
            targetReference = nil
            sceneID = nil
            targetAzimuthDegrees = nil
            targetElevationDegrees = nil
            fieldOfViewDegrees = nil
            observedThisFrame = nil
            framingCenterX = nil
            framingCenterY = nil
            framingWidth = nil
            framingHeight = nil
            expiresAtNS = nil
        case let .cameraExposureLock(requestID, locked):
            self.requestID = requestID
            action = "camera_exposure_lock"
            reason = locked ? "locked" : "automatic"
            targetReference = nil
            sceneID = nil
            targetAzimuthDegrees = nil
            targetElevationDegrees = nil
            fieldOfViewDegrees = nil
            observedThisFrame = nil
            framingCenterX = nil
            framingCenterY = nil
            framingWidth = nil
            framingHeight = nil
            expiresAtNS = nil
        case let .cameraFocus(requestID, mode, position):
            self.requestID = requestID
            action = "camera_focus"
            reason = position.map { "\(mode.rawValue)=\($0)" } ?? mode.rawValue
            targetReference = nil
            sceneID = nil
            targetAzimuthDegrees = nil
            targetElevationDegrees = nil
            fieldOfViewDegrees = nil
            observedThisFrame = nil
            framingCenterX = nil
            framingCenterY = nil
            framingWidth = nil
            framingHeight = nil
            expiresAtNS = nil
        case let .cameraAbsoluteExposure(requestID, mode, shutterCode):
            self.requestID = requestID
            action = "camera_absolute_exposure"
            reason = shutterCode.map { "\(mode.rawValue)=\($0)" } ?? mode.rawValue
            targetReference = nil
            sceneID = nil
            targetAzimuthDegrees = nil
            targetElevationDegrees = nil
            fieldOfViewDegrees = nil
            observedThisFrame = nil
            framingCenterX = nil
            framingCenterY = nil
            framingWidth = nil
            framingHeight = nil
            expiresAtNS = nil
        case let .cameraFacePriority(requestID, enabled):
            self.requestID = requestID
            action = "camera_face_priority"
            reason = enabled ? "enabled" : "disabled"
            targetReference = nil
            sceneID = nil
            targetAzimuthDegrees = nil
            targetElevationDegrees = nil
            fieldOfViewDegrees = nil
            observedThisFrame = nil
            framingCenterX = nil
            framingCenterY = nil
            framingWidth = nil
            framingHeight = nil
            expiresAtNS = nil
        case let .cameraAntiFlicker(requestID, mode):
            self.requestID = requestID
            action = "camera_anti_flicker"
            reason = mode.rawValue
            targetReference = nil
            sceneID = nil
            targetAzimuthDegrees = nil
            targetElevationDegrees = nil
            fieldOfViewDegrees = nil
            observedThisFrame = nil
            framingCenterX = nil
            framingCenterY = nil
            framingWidth = nil
            framingHeight = nil
            expiresAtNS = nil
        case let .cameraImageTuning(requestID, goal):
            self.requestID = requestID
            action = "camera_image_tuning"
            reason = "brightness=\(goal.brightness.map(String.init) ?? "keep"); contrast=\(goal.contrast.map(String.init) ?? "keep"); hue=\(goal.hue.map(String.init) ?? "keep"); saturation=\(goal.saturation.map(String.init) ?? "keep"); sharpness=\(goal.sharpness.map(String.init) ?? "keep")"
            targetReference = nil
            sceneID = nil
            targetAzimuthDegrees = nil
            targetElevationDegrees = nil
            fieldOfViewDegrees = nil
            observedThisFrame = nil
            framingCenterX = nil
            framingCenterY = nil
            framingWidth = nil
            framingHeight = nil
            expiresAtNS = nil
        case let .nativeHumanTrackingPolicy(requestID, speed, motionTracking, foreTarget, adaptiveComposition, adaptivePanGain, adaptivePitchGain, panGain, pitchGain):
            self.requestID = requestID
            action = "native_human_tracking_policy"
            let panGainValue = panGain.map { String($0) } ?? "keep"
            let pitchGainValue = pitchGain.map { String($0) } ?? "keep"
            reason = "speed=\(speed.rawValue); motion=\(motionTracking); fore_target=\(foreTarget); adaptive_composition=\(adaptiveComposition); adaptive_pan_gain=\(adaptivePanGain); adaptive_pitch_gain=\(adaptivePitchGain); pan_gain=\(panGainValue); pitch_gain=\(pitchGainValue)"
            targetReference = nil
            sceneID = nil
            targetAzimuthDegrees = nil
            targetElevationDegrees = nil
            fieldOfViewDegrees = nil
            observedThisFrame = nil
            framingCenterX = nil
            framingCenterY = nil
            framingWidth = nil
            framingHeight = nil
            expiresAtNS = nil
        case let .cameraFieldOfView(requestID, degrees):
            self.requestID = requestID
            action = "camera_field_of_view"
            reason = "degrees=\(degrees)"
            targetReference = nil
            sceneID = nil
            targetAzimuthDegrees = nil
            targetElevationDegrees = nil
            fieldOfViewDegrees = Double(degrees)
            observedThisFrame = nil
            framingCenterX = nil
            framingCenterY = nil
            framingWidth = nil
            framingHeight = nil
            expiresAtNS = nil
        case let .explore(requestID, policy, expiresAtNS):
            self.requestID = requestID
            action = "explore"
            reason = policy.mode.rawValue
            targetReference = nil
            sceneID = nil
            targetAzimuthDegrees = nil
            targetElevationDegrees = nil
            fieldOfViewDegrees = nil
            observedThisFrame = nil
            framingCenterX = nil
            framingCenterY = nil
            framingWidth = nil
            framingHeight = nil
            self.expiresAtNS = expiresAtNS
        case let .express(requestID, expression, expiresAtNS):
            self.requestID = requestID
            action = "express"
            reason = expression.rawValue
            targetReference = nil
            sceneID = nil
            targetAzimuthDegrees = nil
            targetElevationDegrees = nil
            fieldOfViewDegrees = nil
            observedThisFrame = nil
            framingCenterX = nil
            framingCenterY = nil
            framingWidth = nil
            framingHeight = nil
            self.expiresAtNS = expiresAtNS
        case let .suspend(requestID, reason, expiresAtNS):
            self.requestID = requestID
            action = "suspend"
            self.reason = reason
            targetReference = nil
            sceneID = nil
            targetAzimuthDegrees = nil
            targetElevationDegrees = nil
            fieldOfViewDegrees = nil
            observedThisFrame = nil
            framingCenterX = nil
            framingCenterY = nil
            framingWidth = nil
            framingHeight = nil
            self.expiresAtNS = expiresAtNS
        case let .release(requestID, reason):
            self.requestID = requestID
            action = "release"
            self.reason = reason
            targetReference = nil
            sceneID = nil
            targetAzimuthDegrees = nil
            targetElevationDegrees = nil
            fieldOfViewDegrees = nil
            observedThisFrame = nil
            framingCenterX = nil
            framingCenterY = nil
            framingWidth = nil
            framingHeight = nil
            expiresAtNS = nil
        }
    }
}

private struct SemanticBindingTraceEvent: Encodable, Sendable {
    let event = "semantic.binding"
    let monotonicNS: UInt64
    let sourceSceneNS: UInt64
    let targetReference: String
    let sceneID: String?
    let status: SemanticTargetBindingStatus
    let posteriorProbability: Double
    let normalizedEntropy: Double
    let reason: String
    let observedThisFrame: Bool
    let motorCommandIssued = false

    init(_ binding: SemanticTargetBinding, sourceSceneNS: UInt64, monotonicNS: UInt64) {
        self.monotonicNS = monotonicNS
        self.sourceSceneNS = sourceSceneNS
        targetReference = binding.targetReference
        sceneID = binding.sceneID
        status = binding.status
        posteriorProbability = binding.posteriorProbability
        normalizedEntropy = binding.normalizedEntropy
        reason = binding.reason
        observedThisFrame = binding.observedThisFrame
    }
}

/// Scalar-only audit record for every active scene candidate. No pixels or
/// embeddings are persisted; labels remain hypotheses rather than identities.
private struct SceneEvent: Encodable, Sendable {
    let event = "scene.candidate"
    let monotonicNS: UInt64
    let sceneID: String
    let source: VisualObservationSource
    let kind: AttentionTargetKind
    let label: String?
    let confidence: Double
    let centerX: Double
    let centerY: Double
    let width: Double
    let height: Double
    let observedThisFrame: Bool
    let observationCount: Int
    let stabilityMilliseconds: Double
    let sourceCount: Int
    let actionEligible: Bool
    let faceActivityEligible: Bool
    let faceVerified: Bool
    let faceInteractionLivenessEligible: Bool
    let trackingMinimumCenterX: Double
    let trackingMaximumCenterX: Double
    let trackingMinimumCenterY: Double
    let trackingMaximumCenterY: Double
    let azimuthDegrees: Double?
    let elevationDegrees: Double?
    let spatialConfidence: Double
    let lastSeenMilliseconds: Double
}

private struct CameraIntentEvent: Encodable, Sendable {
    let event = "camera.intent"
    let monotonicNS: UInt64
    let owner: CameraControlOwner
    let state: String
    let route: AttentionActuatorRoute
    let commandID: String
    let targetKind: AttentionTargetKind?
    let targetLabel: String?
    let targetProbability: Double
}

/// The state captured whenever the bridge asks the native helper to stop.
/// This is diagnostic-only: it never participates in target selection or
/// motor control. The accompanying recorder links it to the latest bounded
/// face-lock JPEG so a stationary failure can be reconstructed afterwards.
private struct GimbalStopDiagnostic: Sendable {
    let monotonicNS: UInt64
    let reason: String
    let faceLockActive: Bool
    let faceLockMotorPermitted: Bool
    let lastObservedFaceMilliseconds: Double?
    let targetID: String?
    let targetKind: AttentionTargetKind?
    let targetLabel: String?
    let targetConfidence: Double?
    let targetCenterX: Double?
    let targetCenterY: Double?
    let targetActionEligible: Bool?
    let posePitchDegrees: Double?
    let posePanDegrees: Double?
}

private struct MetricsEvent: Encodable, Sendable {
    let event = "subconscious.metrics"
    let monotonicNS: UInt64
    let videoCallbacks: Int
    let audioCallbacks: Int
    let visionUpdates: Int
    let visionMisses: Int
    let visionFramesSkipped: Int
    let videoFramesSuperseded: Int
    let audioVADFramesSuperseded: Int
    let neuralEngineInferences: Int
    let neuralFaceInferences: Int
    let neuralVADInferences: Int
    let maximumVideoCallbackMS: Double
    let maximumAudioCallbackMS: Double
    let averageVideoCallbackMS: Double
    let averageAudioCallbackMS: Double
    let maximumVideoFrameIntervalMS: Double
    let maximumAudioCallbackIntervalMS: Double
    let maximumVisionMS: Double
    let maximumCaptureToBeliefMS: Double
    let averageNeuralEngineMS: Double
    let maximumNeuralEngineMS: Double
    let averageNeuralVADMS: Double
    let maximumNeuralVADMS: Double
    let maximumVADWindowEndToEvidenceMS: Double
}

private enum LongTermDisposition: Sendable {
    case never
    case always
    case onChange(key: String, fingerprint: String)
    case periodic(key: String, minimumIntervalNS: UInt64)
}

private protocol TraceEvent: Encodable, Sendable {
    var monotonicNS: UInt64 { get }
    var longTermDisposition: LongTermDisposition { get }
}

private extension TraceEvent {
    var longTermDisposition: LongTermDisposition { .never }
}

extension RuntimeEvent: TraceEvent {
    var longTermDisposition: LongTermDisposition {
        if event.hasPrefix("scenario.") { return .always }
        if source == "attention_gimbal_bridge", state.hasPrefix("coverage_") { return .never }
        let failureStates = ["error", "fail", "fault", "reject", "timeout", "unavailable", "disconnect", "interrupt"]
        let isFailure = failureStates.contains { state.localizedCaseInsensitiveContains($0) }
        let fingerprint = isFailure ? "\(state)|\(message ?? "")" : state
        return .onChange(key: "runtime:\(event):\(source)", fingerprint: fingerprint)
    }
}

extension BeliefEvent: TraceEvent {
    var longTermDisposition: LongTermDisposition {
        let target = belief.target
        let fingerprint = [
            belief.targetStatus.rawValue,
            belief.attentionCue.route.rawValue,
            target?.kind.rawValue ?? "none",
            target?.label ?? "none",
        ].joined(separator: "|")
        return .onChange(key: "belief", fingerprint: fingerprint)
    }
}

extension VoiceEvent: TraceEvent {
    var longTermDisposition: LongTermDisposition { .always }
}

extension SpeechInteractionTraceEvent: TraceEvent {
    var longTermDisposition: LongTermDisposition { .always }
}

extension AudioDirectionEvent: TraceEvent {
    var longTermDisposition: LongTermDisposition {
        .onChange(key: "audio.direction", fingerprint: direction.rawValue)
    }
}
extension AudioSourceBearingEvent: TraceEvent {
    var longTermDisposition: LongTermDisposition { .always }
}
extension VisionEvent: TraceEvent {}
extension FaceIdentityEvent: TraceEvent {}
extension IdentityPresenceRuntimeEvent: TraceEvent {
    var longTermDisposition: LongTermDisposition { .always }
}
extension L1AuxiliarySemanticTraceEvent: TraceEvent {}
extension L1AuxiliarySemanticInterruptTraceEvent: TraceEvent {
    var longTermDisposition: LongTermDisposition { .always }
}
extension EmbodimentShadowTraceEvent: TraceEvent {
    var longTermDisposition: LongTermDisposition { .always }
}
extension EmbodimentMotorTraceEvent: TraceEvent {
    var longTermDisposition: LongTermDisposition { .always }
}
extension SemanticBindingTraceEvent: TraceEvent {
    var longTermDisposition: LongTermDisposition { .always }
}
extension SceneEvent: TraceEvent {}
extension CameraIntentEvent: TraceEvent {
    var longTermDisposition: LongTermDisposition {
        let mode: String
        if state.hasPrefix("coverage_") || state.hasPrefix("autonomous_scan_") {
            mode = "exploration"
        } else if state == "face_servo_velocity_requested"
                    || state == "social_reframe_requested"
                    || state == "native_tracking_requested" {
            mode = "social_tracking"
        } else {
            mode = state
        }
        let fingerprint = [
            owner.rawValue,
            mode,
            route.rawValue,
            targetKind?.rawValue ?? "none",
            targetLabel ?? "none",
        ].joined(separator: "|")
        return .onChange(key: "camera.intent", fingerprint: fingerprint)
    }
}

extension MetricsEvent: TraceEvent {
    var longTermDisposition: LongTermDisposition {
        .periodic(key: "metrics", minimumIntervalNS: 3_600_000_000_000)
    }
}

private final class JSONLWriter: @unchecked Sendable {
    private struct PendingEvent {
        let monotonicNS: UInt64
        let data: Data
        let longTermDisposition: LongTermDisposition
    }

    private let queue = DispatchQueue(label: "soma.subconscious.trace")
    private let detailedStore: RotatingJSONLStore
    private let importantStore: RotatingJSONLStore?
    private let runtimeHealthStore: RuntimeHealthSnapshotStore?
    private let encoder: JSONEncoder
    private let reorderWindowNS: UInt64 = 20_000_000
    private var pending: [PendingEvent] = []
    private var greatestQueuedNS: UInt64 = 0
    private var lastWrittenNS: UInt64 = 0
    private var lateEventsDropped = 0
    private var lastImportantFingerprint: [String: String] = [:]
    private var lastImportantNS: [String: UInt64] = [:]

    init(
        url: URL,
        rotationPolicy: JSONLRotationPolicy? = nil,
        importantURL: URL? = nil,
        importantRotationPolicy: JSONLRotationPolicy? = nil
    ) throws {
        do {
            detailedStore = try RotatingJSONLStore(baseURL: url, policy: rotationPolicy)
            if let importantURL, let importantRotationPolicy {
                importantStore = try RotatingJSONLStore(
                    baseURL: importantURL,
                    policy: importantRotationPolicy
                )
            } else {
                importantStore = nil
            }
            runtimeHealthStore = try? RuntimeHealthSnapshotStore(
                fileURL: url
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent("runtime-health.json")
            )
        } catch {
            throw RuntimeError.configuration("Cannot create trace output: \(error.localizedDescription)")
        }
        encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
    }

    func write<T: TraceEvent>(_ event: T) {
        queue.async { [weak self] in
            guard let self, var data = try? self.encoder.encode(event) else { return }
            if let health = event as? RuntimeEvent,
               health.event == "source.health",
               RuntimeHealthProjectionPolicy.retains(source: health.source, state: health.state) {
                _ = try? self.runtimeHealthStore?.update(
                    source: health.source,
                    state: health.state,
                    monotonicNS: health.monotonicNS
                )
            }
            data.append(0x0A)
            self.enqueue(PendingEvent(
                monotonicNS: event.monotonicNS,
                data: data,
                longTermDisposition: event.longTermDisposition
            ))
        }
    }

    func close() {
        queue.sync {
            flush(through: UInt64.max)
            try? detailedStore.close()
            try? importantStore?.close()
        }
    }

    func drain() -> Int {
        queue.sync {
            flush(through: UInt64.max)
            return lateEventsDropped
        }
    }

    private func enqueue(_ event: PendingEvent) {
        greatestQueuedNS = max(greatestQueuedNS, event.monotonicNS)
        pending.append(event)
        let cutoff = greatestQueuedNS > reorderWindowNS ? greatestQueuedNS - reorderWindowNS : 0
        flush(through: cutoff)
    }

    private func flush(through cutoff: UInt64) {
        pending.sort { $0.monotonicNS < $1.monotonicNS }
        var future: [PendingEvent] = []
        for event in pending {
            guard event.monotonicNS <= cutoff else {
                future.append(event)
                continue
            }
            guard event.monotonicNS >= lastWrittenNS else {
                lateEventsDropped += 1
                continue
            }
            try? detailedStore.write(event.data)
            if shouldWriteLongTerm(event.longTermDisposition, at: event.monotonicNS) {
                try? importantStore?.write(event.data)
            }
            lastWrittenNS = event.monotonicNS
        }
        pending = future
    }

    private func shouldWriteLongTerm(_ disposition: LongTermDisposition, at monotonicNS: UInt64) -> Bool {
        guard importantStore != nil else { return false }
        switch disposition {
        case .never:
            return false
        case .always:
            return true
        case .onChange(let key, let fingerprint):
            guard lastImportantFingerprint[key] != fingerprint else { return false }
            lastImportantFingerprint[key] = fingerprint
            lastImportantNS[key] = monotonicNS
            return true
        case .periodic(let key, let minimumIntervalNS):
            if let previousNS = lastImportantNS[key],
               monotonicNS >= previousNS,
               monotonicNS - previousNS < minimumIntervalNS {
                return false
            }
            lastImportantNS[key] = monotonicNS
            return true
        }
    }
}

private final class LatencyCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var videoCallbacks = 0
    private var audioCallbacks = 0
    private var visionUpdates = 0
    private var visionMisses = 0
    private var visionFramesSkipped = 0
    private var supersededFrames = 0
    private var supersededAudioVADFrames = 0
    private var neuralEngineInferences = 0
    private var neuralFaceInferences = 0
    private var neuralVADInferences = 0
    private var previousVideoNS: UInt64?
    private var previousAudioNS: UInt64?
    private var maximumVideoCallbackMS = 0.0
    private var maximumAudioCallbackMS = 0.0
    private var totalVideoCallbackMS = 0.0
    private var totalAudioCallbackMS = 0.0
    private var maximumVideoFrameIntervalMS = 0.0
    private var maximumAudioCallbackIntervalMS = 0.0
    private var maximumVisionMS = 0.0
    private var maximumCaptureToBeliefMS = 0.0
    private var totalNeuralEngineMS = 0.0
    private var maximumNeuralEngineMS = 0.0
    private var totalNeuralVADMS = 0.0
    private var maximumNeuralVADMS = 0.0
    private var maximumVADWindowEndToEvidenceMS = 0.0

    func videoCallback(at now: UInt64, processingMS: Double) {
        lock.lock()
        defer { lock.unlock() }
        videoCallbacks += 1
        if let previousVideoNS { maximumVideoFrameIntervalMS = max(maximumVideoFrameIntervalMS, milliseconds(from: previousVideoNS, to: now)) }
        previousVideoNS = now
        maximumVideoCallbackMS = max(maximumVideoCallbackMS, processingMS)
        totalVideoCallbackMS += processingMS
    }

    func audioCallback(at now: UInt64, processingMS: Double) {
        lock.lock()
        defer { lock.unlock() }
        audioCallbacks += 1
        if let previousAudioNS { maximumAudioCallbackIntervalMS = max(maximumAudioCallbackIntervalMS, milliseconds(from: previousAudioNS, to: now)) }
        previousAudioNS = now
        maximumAudioCallbackMS = max(maximumAudioCallbackMS, processingMS)
        totalAudioCallbackMS += processingMS
    }

    func visionUpdate(inferenceMS: Double, captureToBeliefMS: Double) {
        lock.lock()
        visionUpdates += 1
        maximumVisionMS = max(maximumVisionMS, inferenceMS)
        maximumCaptureToBeliefMS = max(maximumCaptureToBeliefMS, captureToBeliefMS)
        lock.unlock()
    }

    func visionMiss(inferenceMS: Double, captureToBeliefMS: Double) {
        lock.lock()
        visionMisses += 1
        maximumVisionMS = max(maximumVisionMS, inferenceMS)
        maximumCaptureToBeliefMS = max(maximumCaptureToBeliefMS, captureToBeliefMS)
        lock.unlock()
    }

    func visionFrameSkipped() {
        lock.lock()
        visionFramesSkipped += 1
        lock.unlock()
    }

    func neuralEngineInference(inferenceMS: Double) {
        lock.lock()
        neuralEngineInferences += 1
        totalNeuralEngineMS += inferenceMS
        maximumNeuralEngineMS = max(maximumNeuralEngineMS, inferenceMS)
        lock.unlock()
    }

    func neuralFaceInference() {
        lock.lock()
        neuralFaceInferences += 1
        lock.unlock()
    }

    func neuralVADInference(inferenceMS: Double, windowEndToEvidenceMS: Double) {
        lock.lock()
        neuralVADInferences += 1
        totalNeuralVADMS += inferenceMS
        maximumNeuralVADMS = max(maximumNeuralVADMS, inferenceMS)
        maximumVADWindowEndToEvidenceMS = max(maximumVADWindowEndToEvidenceMS, windowEndToEvidenceMS)
        lock.unlock()
    }

    func supersedeFrame() {
        lock.lock()
        supersededFrames += 1
        lock.unlock()
    }

    func supersedeAudioVADFrame() {
        lock.lock()
        supersededAudioVADFrames += 1
        lock.unlock()
    }

    func snapshot(at now: UInt64) -> MetricsEvent {
        lock.lock()
        defer { lock.unlock() }
        return MetricsEvent(
            monotonicNS: now,
            videoCallbacks: videoCallbacks,
            audioCallbacks: audioCallbacks,
            visionUpdates: visionUpdates,
            visionMisses: visionMisses,
            visionFramesSkipped: visionFramesSkipped,
            videoFramesSuperseded: supersededFrames,
            audioVADFramesSuperseded: supersededAudioVADFrames,
            neuralEngineInferences: neuralEngineInferences,
            neuralFaceInferences: neuralFaceInferences,
            neuralVADInferences: neuralVADInferences,
            maximumVideoCallbackMS: maximumVideoCallbackMS,
            maximumAudioCallbackMS: maximumAudioCallbackMS,
            averageVideoCallbackMS: videoCallbacks == 0 ? 0 : totalVideoCallbackMS / Double(videoCallbacks),
            averageAudioCallbackMS: audioCallbacks == 0 ? 0 : totalAudioCallbackMS / Double(audioCallbacks),
            maximumVideoFrameIntervalMS: maximumVideoFrameIntervalMS,
            maximumAudioCallbackIntervalMS: maximumAudioCallbackIntervalMS,
            maximumVisionMS: maximumVisionMS,
            maximumCaptureToBeliefMS: maximumCaptureToBeliefMS,
            averageNeuralEngineMS: neuralEngineInferences == 0 ? 0 : totalNeuralEngineMS / Double(neuralEngineInferences),
            maximumNeuralEngineMS: maximumNeuralEngineMS,
            averageNeuralVADMS: neuralVADInferences == 0 ? 0 : totalNeuralVADMS / Double(neuralVADInferences),
            maximumNeuralVADMS: maximumNeuralVADMS,
            maximumVADWindowEndToEvidenceMS: maximumVADWindowEndToEvidenceMS
        )
    }
}

private final class VideoFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let captureNS: UInt64
    let exposureNS: UInt64

    init(pixelBuffer: CVPixelBuffer, captureNS: UInt64, exposureNS: UInt64) {
        self.pixelBuffer = pixelBuffer
        self.captureNS = captureNS
        self.exposureNS = exposureNS
    }
}

private final class LatestFrameMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: VideoFrame?
    private var signalPending = false

    func publish(_ frame: VideoFrame) -> (shouldWake: Bool, superseded: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let superseded = latest != nil
        latest = frame
        if signalPending { return (false, superseded) }
        signalPending = true
        return (true, superseded)
    }

    func take() -> VideoFrame? {
        lock.lock()
        defer { lock.unlock() }
        signalPending = false
        defer { latest = nil }
        return latest
    }
}

private final class BeliefPublisher: @unchecked Sendable {
    private let lock = NSLock()
    private let writer: JSONLWriter
    private let onPublished: ((BeliefSnapshot, String) -> Void)?
    private var lastPublishNS: UInt64 = 0
    private var lastPolicy: ActiveSensingPolicy?
    private var lastTargetStatus: TargetStatus?
    private var lastAttentionCue: AttentionCue?

    init(writer: JSONLWriter, onPublished: ((BeliefSnapshot, String) -> Void)? = nil) {
        self.writer = writer
        self.onPublished = onPublished
    }

    func publish(_ belief: BeliefSnapshot, reason: String, force: Bool = false) {
        lock.lock()
        guard belief.monotonicNS >= lastPublishNS else {
            lock.unlock()
            return
        }
        let changed = belief.policy != lastPolicy
            || belief.targetStatus != lastTargetStatus
            || belief.attentionCue != lastAttentionCue
        let due = belief.monotonicNS - lastPublishNS >= 100_000_000
        guard force || changed || due else {
            lock.unlock()
            return
        }
        lastPublishNS = belief.monotonicNS
        lastPolicy = belief.policy
        lastTargetStatus = belief.targetStatus
        lastAttentionCue = belief.attentionCue
        lock.unlock()
        writer.write(BeliefEvent(monotonicNS: belief.monotonicNS, reason: reason, belief: belief))
        onPublished?(belief, reason)
    }
}

private final class GimbalPoseStore: @unchecked Sendable {
    private let lock = NSLock()
    private let geometryCalibration: CameraGeometryCalibration?
    private var recent: [GimbalPose] = []
    private var recentRaw: [GimbalPose] = []
    private var deviceProfile: OBSBOTDeviceProfile?
    private var deviceIdentifier: String?
    private var deviceCapabilities: OBSBOTDeviceCapabilities?
    private var attitudeCalibration: ExternalGimbalCalibration?
    private var runtimeAttitudeHome: GimbalPose?
    private var horizontalFieldOfViewDegrees = OBSBOTTiny2LiteOptics.wideHorizontalDegrees
    private var fieldOfViewMode = 86
    private var baseCameraProjectionModel = CameraProjectionModel.pinhole(
        horizontalFieldOfViewDegrees: OBSBOTTiny2LiteOptics.wideHorizontalDegrees
    )
    private var cameraProjectionModel = CameraProjectionModel.pinhole(
        horizontalFieldOfViewDegrees: OBSBOTTiny2LiteOptics.wideHorizontalDegrees
    )
    private var opticalZoomFactor = 1.0
    private var motionUntilNS: UInt64 = 0

    init(geometryCalibration: CameraGeometryCalibration? = nil) {
        self.geometryCalibration = geometryCalibration
        if let geometryCalibration, geometryCalibration.fovMode == 86 {
            baseCameraProjectionModel = geometryCalibration.projection
            cameraProjectionModel = geometryCalibration.projection
            horizontalFieldOfViewDegrees = geometryCalibration.projection.horizontalFieldOfViewDegrees
        }
    }

    func configureDeviceProfile(
        _ profile: OBSBOTDeviceProfile,
        capabilities: OBSBOTDeviceCapabilities,
        deviceIdentifier: String? = nil,
        calibration: ExternalGimbalCalibration? = nil
    ) {
        lock.lock()
        deviceProfile = profile
        let resolvedIdentifier = deviceIdentifier ?? profile.rawValue
        self.deviceIdentifier = resolvedIdentifier
        deviceCapabilities = capabilities
        attitudeCalibration = calibration?.isValid == true
            && calibration?.matches(deviceIdentifier: resolvedIdentifier) == true
            ? calibration
            : nil
        fieldOfViewMode = Int(OBSBOTTiny2LiteOptics.nominalWideModeDegrees)
        baseCameraProjectionModel = .pinhole(
            horizontalFieldOfViewDegrees: capabilities.nominalWideHorizontalFieldOfViewDegrees
        )
        opticalZoomFactor = 1
        if let geometryCalibration,
           geometryCalibration.applies(toDeviceIdentifier: resolvedIdentifier),
           geometryCalibration.fovMode == fieldOfViewMode {
            baseCameraProjectionModel = geometryCalibration.projection
        }
        applyOpticalZoomProjection()
        lock.unlock()
    }

    func update(pitchDegrees: Double, panDegrees: Double, at monotonicNS: UInt64) {
        guard pitchDegrees.isFinite, panDegrees.isFinite else { return }
        lock.lock()
        let raw = GimbalPose(pitchDegrees: pitchDegrees, panDegrees: panDegrees, monotonicNS: monotonicNS)
        recentRaw.append(raw)
        if let runtimeAttitudeHome {
            recent.append(GimbalPose(
                pitchDegrees: raw.pitchDegrees - runtimeAttitudeHome.pitchDegrees,
                panDegrees: raw.panDegrees - runtimeAttitudeHome.panDegrees,
                monotonicNS: monotonicNS
            ))
        } else {
            recent.append(attitudeCalibration?.logicalPose(from: raw) ?? raw)
        }
        // Live control reads only the newest samples, while the camera's host-
        // aligned PTS may arrive hundreds of milliseconds after exposure. Keep
        // more than the one-second PTS admission window so panorama alignment
        // can still find both measured sides of that exposure without relaxing
        // the 50/80 ms interpolation bounds.
        if recent.count > 128 { recent.removeFirst(recent.count - 128) }
        if recentRaw.count > 128 { recentRaw.removeFirst(recentRaw.count - 128) }
        lock.unlock()
    }

    /// Tiny 3 Lite's raw attitude origin is device-session dependent. The
    /// native bridge recentres first, then supplies this settled reference so
    /// visual tracking and spatial mapping share the same pose frame.
    func establishRuntimeAttitudeHome(
        pitchDegrees: Double,
        panDegrees: Double,
        at monotonicNS: UInt64
    ) {
        guard pitchDegrees.isFinite, panDegrees.isFinite else { return }
        lock.lock()
        runtimeAttitudeHome = GimbalPose(
            pitchDegrees: pitchDegrees,
            panDegrees: panDegrees,
            monotonicNS: monotonicNS
        )
        recent.removeAll(keepingCapacity: true)
        recentRaw.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    func updateFieldOfViewMode(_ degrees: Double) -> Double? {
        lock.lock()
        let horizontal = deviceCapabilities?.horizontalFieldOfViewDegrees(forNominalMode: degrees)
        guard let horizontal else {
            lock.unlock()
            return nil
        }
        fieldOfViewMode = Int(degrees)
        if let geometryCalibration,
           let deviceIdentifier,
           geometryCalibration.applies(toDeviceIdentifier: deviceIdentifier),
           geometryCalibration.fovMode == Int(degrees) {
            baseCameraProjectionModel = geometryCalibration.projection
        } else {
            baseCameraProjectionModel = .pinhole(horizontalFieldOfViewDegrees: horizontal)
        }
        applyOpticalZoomProjection()
        let appliedHorizontal = horizontalFieldOfViewDegrees
        lock.unlock()
        return appliedHorizontal
    }

    /// The device reports a normalized zoom factor after each accepted camera
    /// command.  Rebuild its ray model before accepting later image evidence,
    /// otherwise spatial memory would assign cropped observations to a wider
    /// world sector than they actually occupy.
    func updateOpticalZoomFactor(_ factor: Double) -> Double? {
        guard factor.isFinite, factor >= 1, factor <= 2 else { return nil }
        lock.lock()
        opticalZoomFactor = factor
        applyOpticalZoomProjection()
        let appliedHorizontal = horizontalFieldOfViewDegrees
        lock.unlock()
        return appliedHorizontal
    }

    private func applyOpticalZoomProjection() {
        cameraProjectionModel = baseCameraProjectionModel.withOpticalZoom(opticalZoomFactor)
            ?? baseCameraProjectionModel
        horizontalFieldOfViewDegrees = cameraProjectionModel.horizontalFieldOfViewDegrees
    }

    /// Attitude packets describe where the gimbal was, but external velocity
    /// commands tell us that it is still moving between packets. Activity
    /// detection must never interpret that image motion as a person's motion.
    func noteMotion(at monotonicNS: UInt64, durationNS: UInt64) {
        lock.lock()
        motionUntilNS = max(motionUntilNS, monotonicNS &+ durationNS)
        lock.unlock()
    }

    func projection(at captureNS: UInt64) -> (
        pose: GimbalPose?,
        horizontalFieldOfViewDegrees: Double,
        fieldOfViewMode: Int,
        cameraProjectionModel: CameraProjectionModel,
        cameraSettled: Bool,
        angularVelocityDegreesPerSecond: Double
    ) {
        lock.lock()
        defer { lock.unlock() }
        let pose = recent.last(where: { $0.monotonicNS <= captureNS && $0.isFresh(for: captureNS, maximumAgeNS: 50_000_000) })
        let commandMotionActive = captureNS <= motionUntilNS
        guard let pose,
              let prior = recent.last(where: {
                  $0.monotonicNS < pose.monotonicNS
                    && pose.monotonicNS - $0.monotonicNS <= 100_000_000
              }),
              pose.monotonicNS > prior.monotonicNS else {
            return (
                pose,
                horizontalFieldOfViewDegrees,
                fieldOfViewMode,
                cameraProjectionModel,
                false,
                .infinity
            )
        }
        let elapsedSeconds = Double(pose.monotonicNS - prior.monotonicNS) / 1_000_000_000
        let panRate = abs(pose.panDegrees - prior.panDegrees) / elapsedSeconds
        let pitchRate = abs(pose.pitchDegrees - prior.pitchDegrees) / elapsedSeconds
        let angularVelocityDegreesPerSecond = hypot(panRate, pitchRate)
        return (
            pose,
            horizontalFieldOfViewDegrees,
            fieldOfViewMode,
            cameraProjectionModel,
            !commandMotionActive && panRate <= 4 && pitchRate <= 4,
            angularVelocityDegreesPerSecond
        )
    }

    /// Panorama-only delayed lookup. The real-time detector continues to use
    /// `projection(at:)`; this path waits for a measured attitude after the
    /// exposure and interpolates rather than increasing L0 reaction latency.
    func captureAlignedPose(at captureNS: UInt64) -> CaptureAlignedPoseResolution {
        lock.lock()
        defer { lock.unlock() }
        // The native helper asks for attitude at 20 ms cadence, but the device can
        // return no sample during an AI-tracking transaction and create a gap
        // near its 100 ms polling ceiling. Panorama may wait and interpolate a
        // measured bracket; live tracking retains the strict 50 ms path above.
        return CaptureAlignedPoseInterpolator.resolve(
            samples: recent,
            at: captureNS,
            maximumSampleDistanceNS: 120_000_000,
            maximumBracketSpanNS: 200_000_000
        )
    }

    func latest(at monotonicNS: UInt64, maximumAgeNS: UInt64 = 75_000_000) -> GimbalPose? {
        lock.lock()
        defer { lock.unlock() }
        return recent.last(where: { $0.monotonicNS <= monotonicNS && $0.isFresh(for: monotonicNS, maximumAgeNS: maximumAgeNS) })
    }

    func latestRaw(at monotonicNS: UInt64, maximumAgeNS: UInt64 = 75_000_000) -> GimbalPose? {
        lock.lock()
        defer { lock.unlock() }
        return recentRaw.last(where: {
            $0.monotonicNS <= monotonicNS && $0.isFresh(for: monotonicNS, maximumAgeNS: maximumAgeNS)
        })
    }

    func hasContinuousFeedback(
        at monotonicNS: UInt64,
        minimumSamples: Int = 3,
        maximumSampleAgeNS: UInt64 = 500_000_000,
        maximumInterSampleGapNS: UInt64 = 220_000_000
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let samples = recent.reversed().prefix { pose in
            monotonicNS >= pose.monotonicNS
                && monotonicNS - pose.monotonicNS <= maximumSampleAgeNS
        }
        guard samples.count >= minimumSamples else { return false }
        let ordered = samples.reversed()
        for (previous, next) in zip(ordered, ordered.dropFirst()) {
            guard next.monotonicNS > previous.monotonicNS,
                  next.monotonicNS - previous.monotonicNS <= maximumInterSampleGapNS else {
                return false
            }
        }
        return true
    }

    /// Motor commands must use the latest physical pose, not a pose ordered
    /// before the frame timestamp. The helper can report a few milliseconds
    /// after Vision finishes a frame; rejecting that newer sample creates a
    /// stop/start cadence even though attitude feedback is continuous.
    func current(maximumAgeNS: UInt64 = 150_000_000) -> GimbalPose? {
        let now = monotonicNanoseconds()
        lock.lock()
        defer { lock.unlock() }
        guard let pose = recent.last,
              now >= pose.monotonicNS,
              now - pose.monotonicNS <= maximumAgeNS else {
            return nil
        }
        return pose
    }

    /// Latest measured attitude rate in logical pose coordinates. Commands are
    /// deliberately not used here: this feedback describes what the gimbal is
    /// actually doing after device latency and gives the face servo a real
    /// braking signal rather than an assumed one.
    func currentVelocity(maximumAgeNS: UInt64 = 150_000_000) -> GimbalVelocityFeedback? {
        let now = monotonicNanoseconds()
        lock.lock()
        defer { lock.unlock() }
        guard let latest = recent.last,
              now >= latest.monotonicNS,
              now - latest.monotonicNS <= maximumAgeNS,
              let prior = recent.reversed().first(where: { sample in
                  latest.monotonicNS > sample.monotonicNS
                      && latest.monotonicNS - sample.monotonicNS >= 8_000_000
                      && latest.monotonicNS - sample.monotonicNS <= 120_000_000
              }) else {
            return nil
        }
        let elapsed = Double(latest.monotonicNS - prior.monotonicNS) / 1_000_000_000
        guard elapsed > 0 else { return nil }
        let feedback = GimbalVelocityFeedback(
            pitchDegreesPerSecond: (latest.pitchDegrees - prior.pitchDegrees) / elapsed,
            panDegreesPerSecond: (latest.panDegrees - prior.panDegrees) / elapsed
        )
        // Reject malformed device-attitude jumps rather than presenting an
        // implausible instantaneous rate as a braking measurement.
        guard feedback.pitchDegreesPerSecond.isFinite,
              feedback.panDegreesPerSecond.isFinite,
              abs(feedback.pitchDegreesPerSecond) <= 360,
              abs(feedback.panDegreesPerSecond) <= 360 else {
            return nil
        }
        return feedback
    }

    /// The most recent pose regardless of age. Used by bounded gaze expressions
    /// so a stale attitude sample during a firmware tracking transaction does
    /// not stall an overlay that should complete on a fixed timer.
    func lastKnown() -> GimbalPose? {
        lock.lock()
        defer { lock.unlock() }
        return recent.last
    }

    /// Returns logical device-attitude samples for one bounded motor lease. These
    /// poses share the spatial frame used by panorama and exploration.
    func trajectory(from startNS: UInt64, through endNS: UInt64) -> [GimbalPose] {
        lock.lock()
        defer { lock.unlock() }
        return recent.filter { pose in
            pose.monotonicNS >= startNS && pose.monotonicNS <= endNS
        }
    }

}

/// Keeps semantic binding off the Vision queue. At most one scene update is
/// evaluated and one newer update is retained; intermediate snapshots are
/// superseded rather than accumulated behind live perception.
private final class EmbodimentSceneBridge: @unchecked Sendable {
    private struct Pending: Sendable {
        let candidates: [SceneCandidate]
        let sourceSceneNS: UInt64
    }

    private let queue = DispatchQueue(label: "soma.embodiment.scene-binding", qos: .utility)
    private let lock = NSLock()
    private let arbiter: ShadowEmbodimentArbiter
    private let writer: JSONLWriter
    private let onSnapshot: @Sendable (EmbodimentShadowSnapshot) -> Void
    private var pending: Pending?
    private var draining = false
    private var accepting = true

    init(
        arbiter: ShadowEmbodimentArbiter,
        writer: JSONLWriter,
        onSnapshot: @escaping @Sendable (EmbodimentShadowSnapshot) -> Void = { _ in }
    ) {
        self.arbiter = arbiter
        self.writer = writer
        self.onSnapshot = onSnapshot
    }

    func submit(_ candidates: [SceneCandidate], at sourceSceneNS: UInt64) {
        lock.lock()
        guard accepting else {
            lock.unlock()
            return
        }
        pending = Pending(candidates: candidates, sourceSceneNS: sourceSceneNS)
        guard !draining else {
            lock.unlock()
            return
        }
        draining = true
        lock.unlock()
        queue.async { [weak self] in self?.drain() }
    }

    func stop() {
        lock.lock()
        accepting = false
        pending = nil
        lock.unlock()
        queue.sync {}
    }

    private func drain() {
        while let work = take() {
            let entities = work.candidates.map(EmbodimentSceneEntity.init)
            let completedNS = monotonicNanoseconds()
            for binding in arbiter.updateScene(entities, at: completedNS) {
                writer.write(SemanticBindingTraceEvent(
                    binding,
                    sourceSceneNS: work.sourceSceneNS,
                    monotonicNS: completedNS
                ))
            }
            onSnapshot(arbiter.snapshot(at: completedNS))
        }
    }

    private func take() -> Pending? {
        lock.lock()
        defer { lock.unlock() }
        guard accepting, let pending else {
            draining = false
            return nil
        }
        self.pending = nil
        return pending
    }
}

/// Serializes accepted cognitive leases and scene-grounding refreshes before
/// handing semantic motor intents to the existing L0 gimbal owner queue.
private final class CognitiveEmbodimentMotorAdapter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "soma.embodiment.motor-adapter")
    private let bridge: AttentionGimbalBridge
    private let writer: JSONLWriter
    private var coordinator = EmbodimentMotorCoordinator()
    private var expiryGeneration = 0
    private var accepting = true

    init(bridge: AttentionGimbalBridge, writer: JSONLWriter) {
        self.bridge = bridge
        self.writer = writer
    }

    func submit(_ request: CognitiveEmbodimentRequest, decision: EmbodimentShadowDecision) {
        queue.async { [weak self] in
            guard let self, accepting else { return }
            let now = monotonicNanoseconds()
            if let intent = coordinator.apply(request: request, decision: decision, at: now) {
                publish(intent, at: now)
            }
            scheduleExpiryIfNeeded()
        }
    }

    func update(_ snapshot: EmbodimentShadowSnapshot) {
        queue.async { [weak self] in
            guard let self, accepting else { return }
            let now = monotonicNanoseconds()
            if let intent = coordinator.update(snapshot: snapshot, at: now) {
                publish(intent, at: now)
            }
            scheduleExpiryIfNeeded()
        }
    }

    func stop() {
        queue.sync {
            guard accepting else { return }
            accepting = false
            expiryGeneration += 1
            if let intent = coordinator.stop() {
                publish(intent, at: monotonicNanoseconds())
            }
        }
    }

    func completeCapture(requestID: String, succeeded: Bool) {
        queue.async { [weak self] in
            guard let self, accepting else { return }
            expiryGeneration += 1
            if let intent = coordinator.complete(
                requestID: requestID,
                reason: succeeded ? "capture_completed" : "capture_failed"
            ) {
                publish(intent, at: monotonicNanoseconds())
            }
        }
    }

    private func scheduleExpiryIfNeeded() {
        expiryGeneration += 1
        let generation = expiryGeneration
        guard let requestID = coordinator.activeRequestID,
              let expiresAtNS = coordinator.activeExpiresAtNS else { return }
        let now = monotonicNanoseconds()
        guard expiresAtNS > now else {
            if let intent = coordinator.expire(at: now) { publish(intent, at: now) }
            return
        }
        let delayNS = min(expiresAtNS - now, UInt64(Int.max))
        queue.asyncAfter(deadline: .now() + .nanoseconds(Int(delayNS))) { [weak self] in
            self?.expire(requestID: requestID, generation: generation)
        }
    }

    private func expire(requestID: String, generation: Int) {
        guard accepting,
              generation == expiryGeneration,
              coordinator.activeRequestID == requestID else { return }
        let now = monotonicNanoseconds()
        if let intent = coordinator.expire(at: now) {
            publish(intent, at: now)
        }
    }

    private func publish(_ intent: EmbodimentMotorIntent, at monotonicNS: UInt64) {
        bridge.ingestEmbodimentIntent(intent)
        writer.write(EmbodimentMotorTraceEvent(intent, monotonicNS: monotonicNS))
    }
}

private enum LiveVoicePresentationState: String, Sendable {
    case inactive
    case ready
    case hearingUser = "hearing_user"
    case preparingResponse = "preparing_response"
    case responding
}

/// Motor command authority, L0 < L1 < L2. A higher layer may preempt a lower
/// layer's reflexive face lock or in-flight gesture.
private enum ScanPriority {
    case l0
    case l1
    case l2
}

private final class AttentionGimbalBridge: @unchecked Sendable {
    private enum State {
        case running
        case stopped
    }

    /// A short, CPU-local image reference used only while deriving the Tiny 3
    /// pose convention. The reference deliberately contains no semantic or
    /// identity data: LK follows the scene's visual texture, so a detector
    /// changing an anonymous saliency ID cannot invalidate the measurement.
    private struct CalibrationSample: Sendable {
        let bgra: Data
        let bytesPerRow: Int
        let width: Int
        let height: Int
        let captureNS: UInt64
        let pose: GimbalPose
    }

    private enum CalibrationStage {
        case awaitingTarget
        case panPulse(baseline: CalibrationSample, startedNS: UInt64)
        case panSettling(baseline: CalibrationSample, pulseCount: Int, stoppedNS: UInt64)
        case pitchPulse(panImageDelta: Double, panPoseDelta: Double, baseline: CalibrationSample, startedNS: UInt64)
        case pitchSettling(panImageDelta: Double, panPoseDelta: Double, baseline: CalibrationSample, pulseCount: Int, stoppedNS: UInt64)
        case completed
        case failed
    }

    private enum CognitiveMotionMode {
        case waypoint(
            bearing: GimbalRelativeBearing,
            toleranceDegrees: Double,
            motionStyle: EmbodimentMotionStyle,
            state: String
        )
        case capture(
            requestID: String,
            bearing: GimbalRelativeBearing,
            fieldOfViewDegrees: Double,
            stableSinceNS: UInt64?,
            lastPositionCommandNS: UInt64?
        )
        case exploration(policy: ExplorationPolicyGoal)
        case expression(
            kind: SocialGimbalExpression,
            basePose: GimbalPose?,
            waypointIndex: Int,
            waypointStartedNS: UInt64?
        )
        case suspended(reason: String)
    }

    private enum NativeTrackingRuntimeAvailability: String {
        case unverified
        case verified
        case unavailable

        var permitsNewHandoff: Bool {
            self != .unavailable
        }
    }

    private let queue = DispatchQueue(label: "soma.subconscious.gimbal-bridge")
    private let writer: JSONLWriter
    private let process: Process
    private let input: FileHandle
    private let readyInput: FileHandle
    private let shutdownHelperURL: URL?
    private let shutdownOutputURL: URL
    private let shutdownTraceRotationPolicy: JSONLRotationPolicy?
    private let exited = DispatchSemaphore(value: 0)
    private let nativeHumanTrackingEnabled: Bool
    private let ledSettings: SOMALEDSettings
    private let calibrationOutputURL: URL?
    private let poseStore: GimbalPoseStore
    private let spatialAtlas: SphericalSceneAtlasStore
    private let faceLockDiagnosticRecorder: FaceLockDiagnosticRecorder?
    private let embodimentViewCaptureStore: EmbodimentViewCaptureStore?
    /// Publishes only an L0-accepted fixation. Raw scene candidates stay
    /// inside perception and cannot independently open a Live Voice session.
    private let onL0FaceFixation: (String?, Bool, UInt64) -> Void
    private let externalCalibration: ExternalGimbalCalibration?
    private var state: State = .running
    private var gate = NativeHumanTrackingGate()
    private var nativeCommandID: String?
    /// Transport acknowledgement only means the device accepted a mode switch. It
    /// becomes a motor owner after its response has been observed.
    private var nativeTrackingActive = false
    private var nativeTrackingFunctionallyVerified = false
    private var nativeTrackingStartPending = false
    /// Deadline for a pending native start. The device handoff (external
    /// yield + AI-mode switch) takes ~1-4s; if the helper never confirms
    /// within this window the pending start is cancelled so a stuck device
    /// cannot block future start attempts forever.
    private var nativeStartDeadlineNS: UInt64?
    private var lastNativeGateDiagnosticNS: UInt64 = 0
    /// The device can refuse to re-enter its AI tracking mode after a stop
    /// (firmware wedge). Spamming native_start every frame keeps it wedged
    /// and floods the helper with futile mode switches. After an unconfirmed
    /// start, back off with an exponential cooldown so the device gets time
    /// to recover; the app's face servo holds the person meanwhile.
    private var nativeRetryCooldownUntilNS: UInt64?
    private var nativeConsecutiveFailures = 0
    private let nativeStartConfirmationWindowNS: UInt64 = 8_000_000_000
    private var nativeHeartbeatGeneration = 0
    private var nativeTrackingLiveness = NativeTrackingLiveness()
    private var nativeTrackingRuntimeAvailability: NativeTrackingRuntimeAvailability = .unverified
    private var externalGate: ExternalGimbalAttentionGate?
    private var idleExplorationGate: IdleExplorationGate?
    private var externalCommandID: String?
    private var helperReady = false
    private var deviceProfile: OBSBOTDeviceProfile?
    private var deviceContract: OBSBOTDeviceContract?
    private var deviceCapabilities: OBSBOTDeviceCapabilities?
    private var rejectedFirmwareAudioModes = Set<Int>()
    private var commandSequence = 0
    private var calibrationStage: CalibrationStage = .awaitingTarget
    private var calibrationHomePose: GimbalPose?
    private let calibrationMaximumPulsesPerAxis = 3
    private var calibrationMode: Bool
    private var lastCalibrationFrameAdmissionNS: UInt64 = 0
    private var lastCalibrationOpticalDiagnosticNS: UInt64 = 0
    private var externalStopGeneration = 0
    private var scanGeneration = 0
    private var scanRunning = false
    /// Motor authority is L0 < L1 < L2: the higher the layer, the more it may
    /// preempt the reflexive L0 face lock. A coverage scan records which layer
    /// started it so a lower layer never tears a higher layer's scan away.
    private var scanPriority: ScanPriority = .l0
    private var explorationWaypoint: SpatialCoverageDirection?
    private var explorationWaypointStartedNS: UInt64?
    private var explorationWaypointDeadlineNS: UInt64?
    private var explorationWaypointStartingPose: GimbalPose?
    /// The atlas cell selected by the posterior. `explorationWaypoint` can be
    /// an inset motor guide, so only this source cell is valid evidence for a
    /// completed unproductive look.
    private var explorationWaypointSource: SpatialCoverageDirection?
    private var explorationWaypointIndex = 0
    private let cameraGeometryCalibrationMode: Bool
    private let panoramaStripScanMode: Bool
    private var cameraGeometryRouteIndex = 0
    private var panoramaStripRouteIndex = 0
    private var cameraGeometryCommandedRouteIndex: Int?
    private var cameraGeometryWaypointStableSinceNS: UInt64?
    private var panoramaWaypointStableSinceNS: UInt64?
    private var cameraGeometryNextPositionCommandNS: UInt64 = 0
    private var explorationBoundaryTurning = false
    private var smoothExploration = SmoothExplorationDynamics()
    private var visualEvidenceGeneration = 0
    private var scanScheduledForEvidenceGeneration: Int?
    private var helperDiagnosticBuffer = ""
    private var poseAvailabilityReported = false
    private var fieldOfViewAvailabilityReported = false
    private var poseWaitStopIssued = false
    private var poseStreamDegradedReported = false
    // The calibration expresses an expected axis sign. During exploration the
    // Device attitude is the authority: one non-moving pan pulse reverses the
    // next pulse; both directions failing requires a physical re-home.
    private var explorationPanPolarity = 1.0
    private var panStallRecovery = PanStallRecovery()
    private var explorationRecentering = false
    private var explorationFailureCount = 0
    // The exploration posterior is intentionally stochastic. A process-local
    // entropy seed avoids replaying the same otherwise-valid route after every
    // service restart; coverage evidence still shapes every subsequent draw.
    private var explorationRandomState: UInt64 = 0
    private var attentionController = SubconsciousAttentionController()
    private var lastAttentionDecisionSignature: String?
    /// Snapshot of the current L0 attention state for the periodic L1
    /// behavior-awareness pass (which the social gate otherwise never sees).
    private var behaviorAttentionState = "idle"
    private var behaviorTargetLabel: String?
    private var behaviorTargetConfidence = 0.0
    private var behaviorIsFaceTarget = false
    private var behaviorChangedAtNS: UInt64 = 0
    private var recentAttentionStates: [String] = []
    /// Supplies the currently recognized identity label (e.g. the administrator's
    /// name) so the behavior-awareness pass knows who it is looking at.
    var recognizedIdentityProvider: (() -> String?)?
    private var actionableVisualContinuity = VisualEvidenceContinuity()
    private var socialTrackingContinuity = VisualEvidenceContinuity(lossConfirmationMilliseconds: 1_200)
    /// Native tracking retains motor authority only while fresh human evidence
    /// or measured recovery motion shows that the firmware is still following.
    /// This prevents the device's lost-target state from holding the gimbal.
    private var nativeTrackingRecovery = NativeTrackingRecovery()
    private var faceLock = FaceLockLease()
    /// Bounded recovery window for a verified face lock that has lost its face.
    /// The lock may hold through a short detector gap, but it must not pin the
    /// gimbal indefinitely when the person has actually left. After this window
    /// the lock is released and L0 resumes scanning.
    private var socialRetentionDeadlineNS: UInt64?
    /// How long a face lock holds through continuous detector misses before
    /// the release path resumes scanning. The face detector delivers in bursts
    /// (several frames, then gaps of 1-18s under ANE contention), so a short
    /// window turns a normal inter-burst gap into a lock release. 15s covers
    /// the observed gap distribution; a continuous 15s absence is a physical
    /// departure, not a dropped frame.
    private let socialRetentionWindowNS: UInt64 = 15_000_000_000
    /// Auto-release a long social fixation that never turns into engagement.
    /// If the robot holds the same face lock for `faceFixationReleaseWindowNS`
    /// with no active conversation, it releases the lock and resumes scanning.
    /// This prevents a false-positive "face" (e.g. an object bound to a stored
    /// identity) from pinning the gimbal indefinitely. A cooldown after each
    /// release keeps the scan running instead of instantly re-latching.
    private var faceFixationSceneID: String?
    private var faceFixationStartNS: UInt64?
    private var faceFixationCooldownUntilNS: UInt64 = 0
    /// Time window (ns) for the no-response auto-release. Configurable via
    /// `SOMA_L0_FIXATION_RELEASE_SECONDS`: 0 (default) means keep gazing
    /// indefinitely — no time-based release, only the judgment-based E2B
    /// release; a positive value tolerates non-response for that many seconds
    /// before releasing the face lock and resuming scanning.
    private var faceFixationReleaseWindowNS: UInt64 {
        UInt64(somaEnvDouble("SOMA_L0_FIXATION_RELEASE_SECONDS", default: 0) * 1_000_000_000)
    }
    private let faceFixationReleaseCooldownNS: UInt64 = 30_000_000_000
    private var activeSpatialFaceReacquisition: (id: String, deadlineNS: UInt64)?
    private var attemptedSpatialFaceReacquisitionIDs: Set<String> = []
    private var confirmedVisualLossNS: UInt64?
    private var lastSpatialFaceReacquisitionCommandNS: UInt64 = 0
    /// Bounded command/feedback samples make the live face-servo loop
    /// inspectable without turning the rolling runtime trace into a 50 Hz
    /// attitude dump.
    private var lastFaceServoDiagnosticNS: UInt64 = 0
    private var lastObservedFaceNS: UInt64?
    private var lastObservedFaceRect: SOMACore.NormalizedRect?
    private var lastMotorTarget: AttentionTarget?
    private var freshFaceBearings: [String: (bearing: GimbalRelativeBearing, captureNS: UInt64, observedNS: UInt64)] = [:]
    // Camera delivery and face-model warm-up begin after the helper reports
    // ready. Do not let no-target exploration pull the optical axis away from
    // the user before that first live face pass has had time to arrive.
    private var explorationEligibleAfterNS: UInt64 = 0
    private var activeCognitiveMotorRequestID: String?
    private var activeCognitiveMotorExpiresAtNS: UInt64?
    private var firmwareSoundFollowingActive: Bool?
    private var pendingFirmwareSoundFollowing: (enabled: Bool, commandID: String)?
    private var firmwareSoundFollowingRetryAfterNS: UInt64 = 0
    /// A brief new voice onset can recruit a verified device microphone array
    /// while no face is visible, but it may never preempt L1/L2 motor
    /// ownership or outlive fresh visual evidence.
    private var auditoryOrientingAdmission = SOMACore.AuditoryOrientingAdmission()
    private var auditoryOrientingLease = SOMACore.AuditoryOrientingLease()
    private let auditoryMotionQualificationDelayNS: UInt64 = 900_000_000
    private struct AuditoryOrientationTrajectory {
        let requestID: String
        let onsetNS: UInt64
        var activationNS: UInt64?
        var activationPose: GimbalPose?
    }
    /// The firmware supplies closed-loop sound orientation but no numeric DOA
    /// bearing. Pair its acknowledged activation with the measured attitude
    /// trajectory so the resulting settled pose becomes spatial evidence.
    private var auditoryOrientationTrajectory: AuditoryOrientationTrajectory?

    /// Coverage is the fallback motor owner. A queued visual-loss callback
    /// must not acquire the gimbal while another attention loop owns it.
    private var coverageScanBlockedByMotorLease: Bool {
        activeCognitiveMotorRequestID != nil
            || auditoryOrientingLease.isActive
            || nativeTrackingActive
            || nativeTrackingStartPending
    }

    /// The device accepts only one gimbal-control mode at a time. A native
    /// handoff is already an ownership claim even before its asynchronous
    /// acknowledgement arrives: any external motion command during that window
    /// returns the camera to manual mode.
    private var nativeTrackingOwnsMotor: Bool {
        nativeTrackingActive || nativeTrackingStartPending
    }

    private var lastNativeLeaseMotionSuppressionNS: UInt64 = 0

    private var cognitiveMotionMode: CognitiveMotionMode?
    private var cognitiveMotionGeneration = 0
    private var cognitiveMotionLoopRunning = false
    private var cognitiveMotionHolding = false
    private var cognitiveDynamics = SmoothExplorationDynamics()
    private var cognitiveExplorationWaypoint: SpatialCoverageDirection?
    private var cognitiveExplorationWaypointStartedNS: UInt64?
    private var indicatorInputs = SubconsciousIndicatorInputs()
    /// Monotonic time of the most recent frame with a fresh human observation.
    /// The indicator's visual state must not drop on a single miss frame:
    /// detector confidence dips frame-to-frame, and a strobe on every dip
    /// flashes the LED and reads as lost tracking.
    private var lastFreshHumanObservationNS: UInt64?
    /// How long a fresh human observation keeps the indicator lit through
    /// subsequent miss frames (hysteresis window). Face detections arrive in
    /// bursts (several frames, then a 1-4s gap), so the window must cover the
    /// typical inter-burst gap (p90 ~3.7s) or the LED still strobes between
    /// bursts.
    private let indicatorVisualGraceNS: UInt64 = 4_000_000_000
    private var localSpeechListening = false
    private var localSpeechWorking = false
    private var localSpeechSpeaking = false
    private var liveVoicePresentation: LiveVoicePresentationState = .inactive
    private var liveVoiceUserSpeaking = false
    private var liveVoiceResponsePending = false
    private var activeIndicatorState: SubconsciousIndicatorState?
    private var activeIndicatorRendering: SOMALEDDeviceRendering?
    private var indicatorIlluminated = false
    private var indicatorCalibrationPreset: SOMALEDFirmwarePreset?
    private var indicatorCalibrationStateID: Int?
    private var indicatorReassertionGeneration = 0
    /// A completed Vision gaze result remains current through a normal
    /// asynchronous landmark gap. This affects only presentation; speech still
    /// requires a separately fresh direct-contact observation.
    private var eyeContactIndicatorLease = EyeContactIndicatorLease(holdMilliseconds: 3_000)
    private let indicatorReassertionIntervalMilliseconds = 1_000

    private var allowsMotorControl: Bool {
        guard deviceContract?.supportsNativeBridge == true,
              let deviceCapabilities, let deviceProfile else { return false }
        if deviceCapabilities.supportsCalibratedMotorControl { return true }
        return externalCalibration?.matches(deviceIdentifier: deviceContract?.profileID ?? deviceProfile.rawValue) == true
            && (!deviceCapabilities.requiresMeasuredAttitudeFrame
                || externalCalibration?.hasMeasuredAttitudeAxes == true)
    }

    private var externalPoseProjection: GimbalPoseProjection {
        externalCalibration?.poseProjection ?? .identity
    }

    private var activeKinematicEnvelope: GimbalKinematicEnvelope {
        deviceProfile?.kinematicEnvelope ?? .obsbotTiny2Lite
    }

    private var allowsBoundedCalibrationPulses: Bool {
        calibrationMode && deviceCapabilities?.supportsBoundedCalibrationPulses == true
    }

    private var supportsFirmwareIndicatorPalette: Bool {
        deviceCapabilities?.supportsFirmwareIndicatorPalette == true
    }

    private var supportsIndicatorRendering: Bool {
        supportsFirmwareIndicatorPalette
    }

    private var supportsBasicIndicatorControl: Bool {
        deviceCapabilities?.supportsIndicatorEnableAndBrightness == true
    }

    init(
        helperURL: URL,
        shutdownHelperURL: URL? = nil,
        outputURL: URL,
        traceRotationPolicy: JSONLRotationPolicy?,
        duration: TimeInterval,
        externalCalibration: ExternalGimbalCalibration?,
        autonomousScanEnabled: Bool,
        idleExplorationEnabled: Bool,
        nativeHumanTrackingEnabled: Bool,
        ledSettings: SOMALEDSettings,
        calibrationOutputURL: URL?,
        cameraGeometryCalibrationMode: Bool,
        panoramaStripScanMode: Bool,
        poseStore: GimbalPoseStore,
        spatialAtlas: SphericalSceneAtlasStore,
        faceLockDiagnosticRecorder: FaceLockDiagnosticRecorder?,
        embodimentViewCaptureStore: EmbodimentViewCaptureStore?,
        onL0FaceFixation: @escaping (String?, Bool, UInt64) -> Void,
        writer: JSONLWriter
    ) throws {
        self.writer = writer
        self.shutdownHelperURL = shutdownHelperURL
        shutdownOutputURL = outputURL
        shutdownTraceRotationPolicy = traceRotationPolicy
        self.nativeHumanTrackingEnabled = nativeHumanTrackingEnabled
        self.ledSettings = ledSettings
        self.calibrationOutputURL = calibrationOutputURL
        self.cameraGeometryCalibrationMode = cameraGeometryCalibrationMode
        self.panoramaStripScanMode = panoramaStripScanMode
        self.poseStore = poseStore
        self.spatialAtlas = spatialAtlas
        self.faceLockDiagnosticRecorder = faceLockDiagnosticRecorder
        self.embodimentViewCaptureStore = embodimentViewCaptureStore
        self.onL0FaceFixation = onL0FaceFixation
        self.externalCalibration = externalCalibration
        var entropy = SystemRandomNumberGenerator()
        explorationRandomState = UInt64.random(in: UInt64.min...UInt64.max, using: &entropy)
        calibrationMode = calibrationOutputURL != nil
        externalGate = externalCalibration.map {
            ExternalGimbalAttentionGate(calibration: $0, autonomousScanEnabled: autonomousScanEnabled)
        }
        idleExplorationGate = externalCalibration == nil && idleExplorationEnabled
            ? IdleExplorationGate()
            : nil
        process = Process()
        let inputPipe = Pipe()
        let readyPipe = Pipe()
        input = inputPipe.fileHandleForWriting
        readyInput = readyPipe.fileHandleForReading
        process.executableURL = helperURL
        var processArguments = [
            "--serve",
            "--allow-camera-motion",
            "--duration", String(Int(duration)),
            "--output", outputURL.path,
        ]
        if calibrationMode {
            processArguments.append("--allow-device-calibration")
        } else if externalCalibration?.hasMeasuredAttitudeAxes == true {
            processArguments.append("--allow-profile-calibrated-motion")
        }
        if let traceRotationPolicy {
            processArguments += [
                "--trace-max-megabytes", String(traceRotationPolicy.maximumBytes / 1_048_576),
                "--trace-retained-files", String(traceRotationPolicy.retainedFiles),
            ]
        }
        process.arguments = processArguments
        process.standardInput = inputPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = readyPipe
        let runtimePID = ProcessInfo.processInfo.processIdentifier
        process.terminationHandler = { [writer, exited = self.exited] completed in
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNanoseconds(),
                source: "attention_gimbal_bridge",
                state: completed.terminationStatus == 0 ? "stopped" : "fault",
                message: "runtime_pid=\(runtimePID); termination_status=\(completed.terminationStatus)"
            ))
            exited.signal()
        }
        try process.run()
        readyInput.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.ingestHelperDiagnostics(data)
        }
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: monotonicNanoseconds(),
            source: "attention_gimbal_bridge",
            state: "started",
            message: "runtime_pid=\(runtimePID); local_scalar_pipe_only; exploration_posterior=entropy_seeded"
        ))
    }

    private func ingestHelperDiagnostics(_ data: Data) {
        guard let chunk = String(data: data, encoding: .utf8) else { return }
        // Attitude reports arrive every 20 ms and must stay fresher than the
        // 250 ms pose window the coverage scan relies on. The bridge queue is
        // busy with attention work (apply, scan ticks, trace writes), so
        // queuing attitude lines behind it starves the pose stream and the
        // scan stalls in coverage_pose_wait_curve. Parse attitude lines
        // directly on the (serialized) pipe-handler thread — GimbalPoseStore
        // is lock-protected — and dispatch the rare stateful lines (native
        // tracking transitions, FOV) to the bridge queue as before.
        helperDiagnosticBuffer.append(chunk)
        while let newline = helperDiagnosticBuffer.firstIndex(of: "\n") {
            let line = String(helperDiagnosticBuffer[..<newline])
            helperDiagnosticBuffer.removeSubrange(...newline)
            if line.hasPrefix("SOMA_GIMBAL_ATTITUDE ") {
                consumeAttitudeLine(line)
            } else if line.hasPrefix("SOMA_GIMBAL_HOME ") {
                consumeHomeLine(line)
            } else {
                queue.async { [weak self] in self?.consumeHelperDiagnostic(line) }
            }
        }
    }

    private func consumeAttitudeLine(_ line: String) {
        let values = line.split(separator: " ").dropFirst().reduce(into: [String: Substring]()) { result, part in
            let pair = part.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { return }
            result[String(pair[0])] = pair[1]
        }
        guard let pitchText = values["pitch"], let pitch = Double(pitchText),
              let panText = values["pan"], let pan = Double(panText),
              let sampleText = values["monotonic_ns"], let sampleNS = UInt64(sampleText) else { return }
        let receivedNS = monotonicNanoseconds()
        // The native helper and DispatchTime can use monotonic clocks with
        // different sleep epochs. The local scalar pipe's receive timestamp
        // is therefore the shared clock for capture alignment; helper reports
        // arrive every 20 ms, below the 50 ms image-pose freshness window.
        guard sampleNS > 0 else { return }
        poseStore.update(pitchDegrees: pitch, panDegrees: pan, at: receivedNS)
        guard !poseAvailabilityReported else { return }
        poseAvailabilityReported = true
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: receivedNS,
            source: "gimbal_pose",
            state: "available",
            message: "native_attitude_feedback"
        ))
    }

    private func consumeHomeLine(_ line: String) {
        let values = line.split(separator: " ").dropFirst().reduce(into: [String: Substring]()) { result, part in
            let pair = part.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { return }
            result[String(pair[0])] = pair[1]
        }
        guard let pitchText = values["pitch"], let pitch = Double(pitchText),
              let panText = values["pan"], let pan = Double(panText) else { return }
        let receivedNS = monotonicNanoseconds()
        poseStore.establishRuntimeAttitudeHome(
            pitchDegrees: pitch,
            panDegrees: pan,
            at: receivedNS
        )
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: receivedNS,
            source: "gimbal_pose",
            state: "home_reference_updated",
            message: "profile_calibrated_center"
        ))
    }

    private func consumeHelperDiagnostic(_ line: String) {
        if line.hasPrefix("SOMA_CONTROL_TRANSPORT ") {
            let values = line.split(separator: " ").dropFirst().reduce(into: [String: Substring]()) { result, part in
                let pair = part.split(separator: "=", maxSplits: 1)
                guard pair.count == 2 else { return }
                result[String(pair[0])] = pair[1]
            }
            let state = values["state"].map(String.init) ?? "degraded"
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNanoseconds(),
                source: "obsbot_control_transport",
                state: state,
                message: String(line.dropFirst("SOMA_CONTROL_TRANSPORT ".count))
            ))
            return
        }
        if line.hasPrefix("SOMA_GIMBAL_HEALTH ") {
            let values = line.split(separator: " ").dropFirst().reduce(into: [String: Substring]()) { result, part in
                let pair = part.split(separator: "=", maxSplits: 1)
                guard pair.count == 2 else { return }
                result[String(pair[0])] = pair[1]
            }
            let result = values["result"].flatMap { Int($0) }
            let warningFlags = values["warning_flags"].flatMap { Int($0) }
            let errorFlags = values["error_flags"].flatMap { Int($0) }
            let state: String
            if result != 0 {
                state = "unavailable"
            } else if errorFlags != 0 {
                state = "error"
            } else if warningFlags != 0 {
                state = "warning"
            } else {
                state = "healthy"
            }
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNanoseconds(),
                source: "obsbot_gimbal",
                state: state,
                message: String(line.dropFirst("SOMA_GIMBAL_HEALTH ".count))
            ))
            return
        }
        if line.hasPrefix("SOMA_OBSBOT_CAPABILITY ") {
            guard let contract = OBSBOTDeviceContract.parse(line) else {
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: monotonicNanoseconds(),
                    source: "obsbot_device",
                    state: "invalid_capability_contract",
                    message: String(line.prefix(192))
                ))
                return
            }
            guard let profile = contract.knownProfile else {
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: monotonicNanoseconds(),
                    source: "obsbot_device",
                    state: "adapter_required",
                    message: "profile=\(contract.profileID); native_bridge=\(contract.supportsNativeBridge); sensory_runtime_available=true"
                ))
                return
            }
            deviceContract = contract
            deviceProfile = profile
            deviceCapabilities = contract.capabilities
            poseStore.configureDeviceProfile(
                profile,
                capabilities: contract.capabilities,
                deviceIdentifier: contract.profileID,
                calibration: externalCalibration
            )
            if helperReady {
                reconcileFirmwareSoundFollowing(
                    at: monotonicNanoseconds(),
                    reason: "capabilities_ready"
                )
            }
            let firmware = contract.firmware ?? "unknown"
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNanoseconds(),
                source: "obsbot_device",
                state: "capabilities_ready",
                message: "profile=\(profile.rawValue); firmware=\(firmware); native_bridge=\(contract.supportsNativeBridge); motor_calibrated=\(contract.capabilities.supportsCalibratedMotorControl); native_human_tracking=\(contract.supportsNativeHumanTracking); firmware_indicator_palette=\(contract.capabilities.supportsFirmwareIndicatorPalette); direct_indicator_rgb=\(contract.capabilities.supportsDirectIndicatorRGB); selectable_audio_modes=\(contract.capabilities.supportsSelectableAudioModes); sound_localization=\(contract.capabilities.supportsDeviceSoundLocalization)"
            ))
            return
        }
        if line.hasPrefix("SOMA_AUDIO_FRONTEND ") {
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNanoseconds(),
                source: "obsbot_audio_frontend",
                state: "settings_observed",
                message: String(line.dropFirst("SOMA_AUDIO_FRONTEND ".count))
            ))
            return
        }
        if line.hasPrefix("SOMA_AUDIO_MODE ") {
            let values = line.split(separator: " ").dropFirst().reduce(into: [String: Substring]()) { result, part in
                let pair = part.split(separator: "=", maxSplits: 1)
                guard pair.count == 2 else { return }
                result[String(pair[0])] = pair[1]
            }
            let confirmed = values["confirmed"].map { $0 == "true" }
            if let requested = values["requested"].flatMap({ Int($0) }) {
                if confirmed == true {
                    rejectedFirmwareAudioModes.remove(requested)
                } else if confirmed == false {
                    rejectedFirmwareAudioModes.insert(requested)
                }
            }
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNanoseconds(),
                source: "obsbot_audio_frontend",
                state: confirmed == true
                    ? "capture_mode_active"
                    : (confirmed == false ? "capture_mode_unconfirmed" : "capture_mode_observed"),
                message: String(line.dropFirst("SOMA_AUDIO_MODE ".count))
            ))
            return
        }
        if line.hasPrefix("SOMA_DOA_FOLLOW ") {
            let values = line.split(separator: " ").dropFirst().reduce(into: [String: Substring]()) { result, part in
                let pair = part.split(separator: "=", maxSplits: 1)
                guard pair.count == 2 else { return }
                result[String(pair[0])] = pair[1]
            }
            let enabled = values["enabled"] == "true"
            let confirmed = values["confirmed"].map { $0 == "true" } ?? true
            let commandID = values["command_id"].map(String.init)
            let observedNS = monotonicNanoseconds()
            if let pendingFirmwareSoundFollowing,
               commandID == pendingFirmwareSoundFollowing.commandID {
                self.pendingFirmwareSoundFollowing = nil
            }
            if confirmed {
                firmwareSoundFollowingActive = enabled
                firmwareSoundFollowingRetryAfterNS = 0
            } else {
                firmwareSoundFollowingActive = nil
                firmwareSoundFollowingRetryAfterNS = observedNS + 1_000_000_000
            }
            if confirmed, enabled {
                armAuditoryOrientationTrajectory(at: observedNS)
            }
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: observedNS,
                source: "obsbot_audio_doa",
                state: confirmed
                    ? (enabled ? "device_sound_following_active" : "device_sound_following_disabled")
                    : "device_sound_following_unconfirmed",
                message: String(line.dropFirst("SOMA_DOA_FOLLOW ".count))
            ))
            return
        }
        if line.hasPrefix("SOMA_CAMERA_OPTICS ") {
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNanoseconds(),
                source: "obsbot_camera_optics",
                state: "settings_observed",
                message: String(line.dropFirst("SOMA_CAMERA_OPTICS ".count))
            ))
            return
        }
        if line.hasPrefix("SOMA_CAMERA_WHITE_BALANCE ") {
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNanoseconds(),
                source: "obsbot_camera_imaging",
                state: "white_balance_active",
                message: String(line.dropFirst("SOMA_CAMERA_WHITE_BALANCE ".count))
            ))
            return
        }
        if line.hasPrefix("SOMA_CAMERA_FOV ") {
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNanoseconds(),
                source: "obsbot_camera_optics",
                state: "field_of_view_active",
                message: String(line.dropFirst("SOMA_CAMERA_FOV ".count))
            ))
            return
        }
        if line == "SOMA_NATIVE_BRIDGE_READY" {
            guard !helperReady else { return }
            helperReady = true
            reconcileFirmwareSoundFollowing(
                at: monotonicNanoseconds(),
                reason: "bridge_startup"
            )
            explorationEligibleAfterNS = monotonicNanoseconds() + 3_000_000_000
            if supportsBasicIndicatorControl {
                let indicatorEnableCommandID = nextCommandID(prefix: "indicator-enable")
                send("indicator_enabled \(indicatorEnableCommandID) \(ledSettings.responseMode == .off ? 0 : 1)")
                let indicatorBrightnessCommandID = nextCommandID(prefix: "indicator-brightness")
                send("indicator_brightness \(indicatorBrightnessCommandID) \(ledSettings.brightness)")
            }
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNanoseconds(),
                source: "attention_gimbal_bridge",
                state: "ready",
                message: "runtime_pid=\(ProcessInfo.processInfo.processIdentifier); native_endpoint_discovered"
            ))
            if allowsMotorControl && (cameraGeometryCalibrationMode || panoramaStripScanMode) {
                startSmoothExploration()
            }
            refreshIndicator(
                at: monotonicNanoseconds(),
                forceHardwareReassertion: true
            )
            if supportsIndicatorRendering {
                startIndicatorReassertionLoop()
            }
            return
        }
        if line.hasPrefix("SOMA_NATIVE_TRACKING ") {
            let values = line.split(separator: " ").dropFirst().reduce(into: [String: Substring]()) { result, part in
                let pair = part.split(separator: "=", maxSplits: 1)
                guard pair.count == 2 else { return }
                result[String(pair[0])] = pair[1]
            }
            guard let state = values["state"] else { return }
            let commandID = values["command_id"].map(String.init)
            let outcome = values["outcome"].map(String.init)
            if state == "accepted" {
                nativeTrackingActive = true
                nativeTrackingFunctionallyVerified = false
                nativeTrackingStartPending = false
                nativeStartDeadlineNS = nil
                startNativeHeartbeatLoop()
                startNativeTrackingLivenessCheck(at: monotonicNanoseconds())
                // Native human tracking can replace the visible hardware
                // indication while it activates. Reassert the selected SOMA
                // signal after the device has confirmed that transition.
                refreshIndicator(
                    at: monotonicNanoseconds(),
                    forceHardwareReassertion: true
                )
            } else if state == "inactive" {
                // The helper's requestManualStop emits an inactive native
                // tracking ack for ANY manual transition, including the
                // external servo's own release/stop cycles while no native
                // session exists. Treating those as native failures would
                // re-arm the retry cooldown on every servo release and starve
                // the next native start indefinitely. Only a native session we
                // actually own (active or pending) is a real failure signal.
                guard nativeTrackingActive || nativeTrackingStartPending else { return }
                if nativeTrackingStartPending {
                    // Reinitialization emits unrelated inactive updates while
                    // a request is pending. Only the matching terminal
                    // rejection may cancel this handoff.
                    guard outcome == "start_rejected",
                          commandID == nativeCommandID else {
                        return
                    }
                    nativeTrackingStartPending = false
                    nativeStartDeadlineNS = nil
                    nativeCommandID = nil
                    _ = gate.invalidate()
                    nativeConsecutiveFailures += 1
                    let cooldownMilliseconds = min(
                        5_000 * (1 << min(nativeConsecutiveFailures - 1, 3)),
                        40_000
                    )
                    nativeRetryCooldownUntilNS = monotonicNanoseconds()
                        + UInt64(cooldownMilliseconds) * 1_000_000
                    writer.write(RuntimeEvent(
                        event: "source.health",
                        monotonicNS: monotonicNanoseconds(),
                        source: "native_tracking",
                        state: "start_rejected",
                        message: "device_rejected_portrait_tracking; retry_after_ms=\(cooldownMilliseconds)"
                    ))
                    return
                }
                stopNativeHeartbeatLoop()
                nativeTrackingLiveness.cancel()
                nativeTrackingRecovery.reset()
                nativeTrackingActive = false
                nativeTrackingFunctionallyVerified = false
                nativeTrackingStartPending = false
                nativeStartDeadlineNS = nil
                nativeCommandID = nil
                _ = gate.stop()
                nativeConsecutiveFailures += 1
                let cooldownMilliseconds = min(
                    10_000 * (1 << min(nativeConsecutiveFailures - 1, 3)),
                    60_000
                )
                nativeRetryCooldownUntilNS = monotonicNanoseconds()
                    + UInt64(cooldownMilliseconds) * 1_000_000
            }
            return
        }
        if line.hasPrefix("SOMA_GIMBAL_FOV degrees="),
           let degrees = Double(line.dropFirst("SOMA_GIMBAL_FOV degrees=".count)),
           let horizontal = poseStore.updateFieldOfViewMode(degrees) {
            guard !fieldOfViewAvailabilityReported else { return }
            fieldOfViewAvailabilityReported = true
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNanoseconds(),
                source: "gimbal_pose",
                state: "fov_available",
                message: String(
                    format: "reported_fov_mode=%.0f; horizontal_degrees=%.3f; optical_profile=%@; aspect_ratio=16:9",
                    degrees,
                    horizontal,
                    deviceProfile?.rawValue ?? "unknown"
                )
            ))
            return
        }
        if line.hasPrefix("SOMA_CAMERA_ZOOM factor="),
           let factor = Double(line.dropFirst("SOMA_CAMERA_ZOOM factor=".count)),
           let horizontal = poseStore.updateOpticalZoomFactor(factor) {
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNanoseconds(),
                source: "obsbot_camera_optics",
                state: "optical_zoom_active",
                message: String(
                    format: "reported_factor=%.3f; horizontal_degrees=%.3f",
                    factor,
                    horizontal
                )
            ))
            return
        }
        guard line.hasPrefix("SOMA_GIMBAL_ATTITUDE ") else { return }
        // Attitude lines are consumed on the pipe-handler fast path in
        // ingestHelperDiagnostics; they never reach this queue.
    }

    func ingest(_ belief: BeliefSnapshot, reason: String) {
        queue.async { [weak self] in self?.apply(belief, reason: reason) }
    }

    /// The auxiliary model can reject only the human hypothesis that produced
    /// its frame. It cannot acquire a target or issue a motor command.
    func ingestSemanticHumanVerdict(_ cue: L1AuxiliarySemanticCue) {
        queue.async { [weak self] in
            self?.applySemanticHumanVerdict(cue)
        }
    }

    func ingestSceneCandidates(
        _ candidates: [SceneCandidate],
        captureNS: UInt64,
        at monotonicNS: UInt64
    ) {
        queue.async { [weak self] in
            self?.spatialAtlas.updateScene(candidates.map(EmbodimentSceneEntity.init))
            self?.applySceneCandidates(candidates, captureNS: captureNS, at: monotonicNS)
        }
    }

    /// Feeds the bounded device-calibration routine a frame whose pose is
    /// aligned to its exposure. Normal attention never copies camera frames;
    /// this path is admitted only for the initial visual reference and the
    /// two short settle windows.
    func ingestCalibrationFrame(
        _ pixelBuffer: CVPixelBuffer,
        captureNS: UInt64,
        observedNS: UInt64
    ) {
        let shouldCapture = queue.sync { [self] in
            guard calibrationMode, process.isRunning, helperReady else { return false }
            switch calibrationStage {
            case .awaitingTarget:
                return true
            case let .panSettling(_, _, stoppedNS),
                 let .pitchSettling(_, _, _, _, stoppedNS):
                return captureNS >= stoppedNS + 400_000_000
                    && (lastCalibrationFrameAdmissionNS == 0
                        || captureNS >= lastCalibrationFrameAdmissionNS + 150_000_000)
            case .panPulse, .pitchPulse, .completed, .failed:
                return false
            }
        }
        guard shouldCapture,
              let sample = calibrationSample(from: pixelBuffer, captureNS: captureNS) else {
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            self.lastCalibrationFrameAdmissionNS = captureNS
            self.applyCalibrationFrame(sample, at: observedNS)
        }
    }

    func ingestSpeechInteractionState(_ speechState: LocalSpeechInteractionState) {
        queue.async { [weak self] in
            guard let self else { return }
            switch speechState {
            case .turnStarted:
                localSpeechListening = true
                localSpeechWorking = false
                localSpeechSpeaking = false
            case let .recognitionCompleted(_, _, _, _, _, _, handedToL2):
                localSpeechListening = false
                localSpeechWorking = handedToL2
            case .speechStarted:
                localSpeechListening = false
                localSpeechWorking = false
                localSpeechSpeaking = true
            case .speechCompleted, .speechCancelled:
                localSpeechSpeaking = false
            case .l2Completed:
                localSpeechListening = false
                localSpeechWorking = false
            case .l2Failed, .recognitionFailed, .turnCancelled:
                localSpeechListening = false
                localSpeechWorking = false
                localSpeechSpeaking = false
            }
            refreshCommunicationIndicatorInputs()
            refreshIndicator(at: monotonicNanoseconds())
        }
    }

    func ingestLiveVoicePresentation(_ presentation: LiveVoicePresentationState) {
        queue.async { [weak self] in
            guard let self else { return }
            guard presentation != .preparingResponse || liveVoiceResponsePending else { return }
            liveVoicePresentation = presentation
            if presentation == .inactive {
                liveVoiceUserSpeaking = false
                liveVoiceResponsePending = false
            } else if presentation == .responding || presentation == .ready {
                liveVoiceResponsePending = false
            }
            refreshCommunicationIndicatorInputs()
            refreshIndicator(at: monotonicNanoseconds())
        }
    }

    func ingestLiveVoiceTurnAccepted() {
        queue.async { [weak self] in
            guard let self, liveVoicePresentation != .inactive else { return }
            liveVoiceResponsePending = true
        }
    }

    func ingestLiveVoiceUserActivity(active: Bool) {
        queue.async { [weak self] in
            guard let self, liveVoicePresentation != .inactive else { return }
            liveVoiceUserSpeaking = active
            refreshCommunicationIndicatorInputs()
            refreshIndicator(at: monotonicNanoseconds())
        }
    }

    private func refreshCommunicationIndicatorInputs() {
        // A connected Live Voice session is already a social commitment. It
        // keeps one unambiguous session presentation while the user pauses or
        // the assistant prepares a reply; speech activity only changes the
        // conversational turn, not the visible readiness state.
        let liveVoiceSessionOpen = liveVoicePresentation != .inactive
        let conversationActive = liveVoiceSessionOpen
            || localSpeechListening
            || localSpeechSpeaking
        let preparingReply = !liveVoiceSessionOpen && localSpeechWorking
        indicatorInputs.interactionState = conversationActive
            ? .conversation
            : (preparingReply ? .preparingReply : .idle)
    }

    func ingestCoverage(
        pose: GimbalPose,
        horizontalFieldOfViewDegrees: Double,
        poseProjection: GimbalPoseProjection,
        cameraProjectionModel: CameraProjectionModel,
        backgroundObservationQuality: Double,
        dynamicVisionRects: [SOMACore.NormalizedRect],
        at monotonicNS: UInt64
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            self.spatialAtlas.observe(
                pose: pose,
                horizontalFieldOfViewDegrees: horizontalFieldOfViewDegrees,
                poseProjection: poseProjection,
                cameraProjectionModel: cameraProjectionModel,
                at: monotonicNS
            )
            guard backgroundObservationQuality > 0 else { return }
            self.spatialAtlas.observePanorama(
                pose: pose,
                horizontalFieldOfViewDegrees: horizontalFieldOfViewDegrees,
                frameQuality: backgroundObservationQuality,
                dynamicVisionRects: dynamicVisionRects,
                poseProjection: poseProjection,
                cameraProjectionModel: cameraProjectionModel,
                at: monotonicNS
            )
        }
    }

    func ingestEmbodimentIntent(_ intent: EmbodimentMotorIntent) {
        queue.async { [weak self] in self?.applyEmbodimentIntent(intent) }
    }

    func stop() {
        let shouldStop: Bool = queue.sync {
            if case .stopped = state { return false }
            let stopNS = monotonicNanoseconds()
            onL0FaceFixation(nil, false, stopNS)
            if calibrationOutputURL != nil {
                switch calibrationStage {
                case .completed, .failed:
                    break
                default:
                    writer.write(RuntimeEvent(
                        event: "source.health",
                        monotonicNS: monotonicNanoseconds(),
                        source: "external_gimbal_calibration",
                        state: "incomplete",
                        message: "no_calibration_written"
                    ))
                }
            }
            stopAuditoryOrienting(
                state: "runtime_stopping",
                at: stopNS,
                resumeExploration: false
            )
            // Sound following is a firmware state, not a host-side velocity
            // command. Clear it even when no local lease survived a previous
            // process so the next launch begins from an unowned motor state.
            disableFirmwareSoundFollowing(at: stopNS, reason: "runtime_stopping")
            let commandID = nextCommandID(prefix: "shutdown")
            send(shutdownHelperURL == nil
                ? "shutdown \(commandID)"
                : "manual_stop \(commandID)")
            writer.write(CameraIntentEvent(
                monotonicNS: monotonicNanoseconds(),
                owner: .manual,
                state: "shutdown_requested",
                route: .none,
                commandID: commandID,
                targetKind: nil,
                targetLabel: nil,
                targetProbability: 0
            ))
            try? input.close()
            readyInput.readabilityHandler = nil
            stopNativeHeartbeatLoop()
            cancelExternalStop()
            cancelScan()
            state = .stopped
            return true
        }
        guard shouldStop else { return }
        if process.isRunning {
            if exited.wait(timeout: .now() + 7) == .timedOut {
                process.terminate()
                _ = exited.wait(timeout: .now() + 3)
            }
        }
        runLifecycleShutdownIfNeeded()
    }

    private func runLifecycleShutdownIfNeeded() {
        guard let shutdownHelperURL else { return }
        let lifecycle = Process()
        lifecycle.executableURL = shutdownHelperURL
        var arguments = [
            "--allow-camera-motion",
            "--park-sleep",
            "--output", shutdownOutputURL.path,
        ]
        if let shutdownTraceRotationPolicy {
            arguments += [
                "--trace-max-megabytes", String(shutdownTraceRotationPolicy.maximumBytes / 1_048_576),
                "--trace-retained-files", String(shutdownTraceRotationPolicy.retainedFiles),
            ]
        }
        lifecycle.arguments = arguments
        lifecycle.standardOutput = FileHandle.nullDevice
        lifecycle.standardError = FileHandle.nullDevice
        do {
            try lifecycle.run()
            lifecycle.waitUntilExit()
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNanoseconds(),
                source: "attention_gimbal_bridge",
                state: lifecycle.terminationStatus == 0
                    ? "lifecycle_shutdown_completed"
                    : "lifecycle_shutdown_failed",
                message: "termination_status=\(lifecycle.terminationStatus); verified_park_sleep=\(lifecycle.terminationStatus == 0)"
            ))
        } catch {
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNanoseconds(),
                source: "attention_gimbal_bridge",
                state: "lifecycle_shutdown_failed",
                message: String(error.localizedDescription.prefix(192))
            ))
        }
    }

    private func apply(_ belief: BeliefSnapshot, reason: String) {
        guard process.isRunning else {
            state = .stopped
            return
        }
        guard helperReady else { return }
        guard allowsMotorControl || allowsBoundedCalibrationPulses else { return }
        guard !cameraGeometryCalibrationMode, !panoramaStripScanMode else { return }
        guard !explorationRecentering else { return }
        if calibrationMode {
            // Calibration is driven by capture-aligned optical-flow frames.
            // Beliefs are semantic and may assign a new anonymous scene ID as
            // the camera moves, so they cannot provide the correspondence.
            return
        }
        guard activeCognitiveMotorRequestID == nil else {
            // Perception continues while a higher layer owns the motor lease,
            // but autonomous L0 evidence cannot race that leased goal.
            return
        }
        let now = belief.monotonicNS
        cancelStaleNativeStartIfNeeded(at: now)
        reconcileFirmwareSoundFollowing(at: now, reason: "attention_state")
        if reason != "vision_miss", auditoryOrientingProtectedBySocialEngagement {
            stopAuditoryOrienting(
                state: "social_engagement_observed",
                at: now,
                resumeExploration: false
            )
        }
        if reason == "vision_miss" {
            // A completed detector miss can race another detector's fresh
            // face result. The worker already applies this continuity rule,
            // but keep it at the motor boundary as well: an isolated empty
            // result must not interrupt an active face correction.
            guard actionableVisualContinuity.confirmsLoss(at: now) else { return }
            let nativeOwnsSocialTracking = nativeTrackingActive || nativeTrackingStartPending
            // A device-confirmed native AI lock owns its own live visual loop
            // (the OBSBOT tracks the person independently of this app's ANE
            // detector). While the device-confirmed native lock is held, an
            // isolated app-detector gap is a perception dropout rather than a
            // physical departure. The recovery supervisor releases ownership
            // after visual absence and measured gimbal motion no longer
            // support reacquisition. A
            // pending, not-yet-device-confirmed start still yields to the
            // shorter social gap so a false start cannot hold the gimbal
            // forever.
            // A face lease is a geometric continuity aid, not evidence that a
            // person is still in view. Keep it only while fresh face evidence
            // (or a device-confirmed native track) remains within its own
            // loss window. Previously the controller received the lease bit
            // alone, so a stale person hypothesis could indefinitely suppress
            // exploration after the camera was no longer seeing a person.
            let socialEvidenceFresh = nativeTrackingFunctionallyVerified
                ? !nativeTrackingConfirmsTargetLoss(at: now)
                : !socialTrackingContinuity.confirmsLoss(at: now)
            let socialFixationSupported = faceLock.permitsMotor(at: now)
                && socialEvidenceFresh
            let retainNativeThroughDetectorGap = socialFixationSupported
                && nativeOwnsSocialTracking
            let decision = attentionController.advance(
                belief: belief,
                evidence: .visualLoss,
                socialFixationPermitted: socialFixationSupported,
                nativeSocialTrackingActive: retainNativeThroughDetectorGap
            )
            // A confirmed visual departure must release the geometric face
            // latch as well as the attention state. FaceLockLease deliberately
            // has no wall-clock expiry after independent verification, so
            // retaining it after the continuity evidence expires leaves L0 in
            // an impossible state: attention selects exploration while the
            // motor admission still sees a permanent social lock.
            if !socialEvidenceFresh {
                releaseSocialFaceLock(at: now, reason: "visual_continuity_expired")
            }
            recordAttentionDecision(decision, target: belief.target, at: now)
            if decision.suppressesExploration {
                // Only a verified face lock is allowed a short detector gap.
                // A raw model candidate must never freeze exploration when it
                // disappears, otherwise a static false positive can hold the
                // gimbal in place without ever commanding a useful fixation.
                if externalCommandID != nil {
                    cancelExternalStop()
                    sendExternalStop(state: "face_lock_detector_gap", at: now)
                }
                // Bounded recovery: a verified face lock may hold through a
                // short detector gap, but must not pin the gimbal indefinitely
                // when the person has actually left. After the window, release
                // the lock and resume scanning. The release is sticky for
                // unverified locks: without the post-release cooldown a
                // phantom face re-latches within a second and the robot
                // oscillates fixation/retention forever. A verified lock is a
                // real person by construction (the landmark verifier rules out
                // static face-shaped distractors), so its release — a long
                // detector gap, not a wrong fixation — must not trigger the
                // ignore-cooldown: the person re-entering the view is latched
                // immediately.
                if socialRetentionDeadlineNS == nil {
                    socialRetentionDeadlineNS = now + socialRetentionWindowNS
                } else if now >= socialRetentionDeadlineNS! {
                    releaseSocialFaceLock(at: now, reason: "retention_window_expired")
                    applyVisualLoss(belief, at: now)
                }
                return
            }
            applyVisualLoss(belief, at: now)
            return
        }
        guard VisualObservationSource(rawValue: reason) != nil else {
            // Predictions, audio, and periodic snapshots carry no new pixels;
            // they must never extend a physical motion pulse.
            _ = attentionController.advance(
                belief: belief,
                evidence: .nonVisualUpdate,
                socialFixationPermitted: faceLock.permitsMotor(at: now)
            )
            return
        }
        let decision = attentionController.advance(
            belief: belief,
            evidence: .visualObservation,
            socialFixationPermitted: faceLock.permitsInitialMotor(at: now)
                && (nativeTrackingFunctionallyVerified
                    ? !nativeTrackingConfirmsTargetLoss(at: now)
                    : !socialTrackingContinuity.confirmsLoss(at: now)),
            nativeSocialTrackingPermitted: faceLock.permitsInitialMotor(at: now),
            nativeSocialTrackingActive: nativeTrackingActive || nativeTrackingStartPending
        )
        recordAttentionDecision(decision, target: belief.target, at: now)
        switch decision.state {
        case .sceneObservation:
            // Objects and saliency remain genuine attention hypotheses. They
            // can delay a new blind search, but have no L0 motor authority to
            // cut a coverage trajectory that is already observing the scene.
            recordCurrentVisualAttention(at: now)
            if scanRunning, decision.preservesActiveExploration { return }
            quiesceForNonMotorAttention(at: now, target: belief.target, reason: reason)
            return
        case .socialRetention:
            // A current body box or detector-ID gap preserves social context
            // without pretending it is a fresh face measurement for a motor.
            // A provisional one-frame person candidate must not insert a
            // multi-second stop into an already active coverage trajectory.
            recordCurrentVisualAttention(at: now)
            if scanRunning, decision.preservesActiveExploration { return }
            cancelScan()
            if externalCommandID != nil {
                cancelExternalStop()
                sendExternalStop(state: "social_attention_no_fresh_face", at: now)
            }
            // A verified face lock may hold through a short detector gap, but it
            // must not pin the gimbal indefinitely when the person has actually
            // left. After a bounded recovery window, release the lock and
            // resume scanning so the robot does not sit still forever. The
            // release sets the post-release cooldown for unverified locks so a
            // phantom face cannot instantly re-latch and restart the
            // oscillation; a verified lock's release is a long detector gap and
            // re-latches immediately when the person re-enters the view.
            if socialRetentionDeadlineNS == nil {
                socialRetentionDeadlineNS = now + socialRetentionWindowNS
            } else if now >= socialRetentionDeadlineNS! {
                releaseSocialFaceLock(at: now, reason: "retention_window_expired")
                applyVisualLoss(belief, at: now)
            }
            return
        case .socialReframing:
            recordCurrentVisualAttention(at: now)
            guard let target = belief.target else { return }
            applySocialReframing(belief, target: target, at: now, reason: reason)
            return
        case .exploration, .idle:
            // A static non-human scene candidate receives a bounded,
            // probability-weighted observation dwell. When that dwell ends,
            // the scene remains in memory but deliberately yields to the
            // spherical explorer without waiting for it to vanish from pixels.
            let explorationAfterObservationDwell = decision.sceneID != nil
            guard explorationAfterObservationDwell || actionableVisualContinuity.confirmsLoss(at: now) else { return }
            // A device-confirmed native lock is its own live visual loop: the
            // OBSBOT tracks the person independently of this app's detectors.
            // An app-side object/body dwell ending is not evidence that the
            // tracked person left, and resuming the coverage scan would send
            // external velocity that yields the device's AI lock away. Retain
            // the lease through the competing candidate (same rule as
            // scene_observation and social_reframing); only a sustained
            // absence confirmed by the native recovery supervisor may tear it down.
            if retainNativeLeaseThroughCompetingAttention(at: now) {
                cancelScan()
                return
            }
            applyVisualLoss(belief, at: now)
            return
        case .socialFixation:
            socialRetentionDeadlineNS = nil
            applyFaceFixationAutoRelease(target: belief.target, at: now)
            break
        }
        guard let target = belief.target else { return }
        if target.isFaceMotorTarget,
           faceLock.suppressesCompetingFace(
               sceneID: target.id,
               rect: target.rect,
               at: now
           ) {
            // A competing raw face candidate is not a visual-loss event for
            // the confirmed face. The direct SceneField face path keeps the
            // native helper alive from the held face itself.
            return
        }
        if target.isFaceMotorTarget,
           (!faceLock.holds(sceneID: target.id, rect: target.rect, at: now)
                || !faceLock.permitsInitialMotor(at: now)) {
            // A raw face gets only the short, non-renewable correction that
            // brings a clipped face into the independent verifier's view.
            guard actionableVisualContinuity.confirmsLoss(at: now) else { return }
            applyVisualLoss(belief, at: now)
            return
        }
        if let target = belief.target,
           faceLock.suppressesNonHumanAttention(
               kind: target.kind,
               attentionWeight: target.attentionWeight,
               at: now
           ) {
            // Selection normally suppresses this before a belief is emitted.
            // Keep the same L0 rule at the motor boundary so a future source
            // cannot make a default object interrupt an active face lock.
            return
        }
        // Keep only scalar context for a target that actually crossed the
        // motor boundary. A rejected lower-frame face-like candidate must not
        // be reported later as though it justified a physical stop.
        lastMotorTarget = target
        actionableVisualContinuity.recordObservation(at: now)
        confirmedVisualLossNS = nil
        if var idleExplorationGate {
            idleExplorationGate.recordNoCalibratedTarget(at: now)
            self.idleExplorationGate = idleExplorationGate
            scheduleScanAfterContinuousVisualLoss()
        } else {
            visualEvidenceGeneration += 1
        }
        let verifiedCurrentFaceLock: Bool
        if let target = belief.target {
            verifiedCurrentFaceLock = faceLock.permitsMotor(at: now)
                && faceLock.holds(sceneID: target.id, rect: target.rect, at: now)
        } else {
            verifiedCurrentFaceLock = false
        }
        let immediateNativeAcquisition = verifiedCurrentFaceLock
        let nativeAction: NativeHumanTrackingAction
        // A temporally matched ANE face may already be handing its image-space
        // box to the device while landmark verification is still pending.  Do
        // not let the slower belief path revoke that pending transfer simply
        // because it is not yet allowed to create social/identity authority.
        // Once the device accepts the start, the normal active-native path
        // retains ownership only through its visual-loss continuity rules.
        let nativeLeasePermitted = faceLock.permitsMotor(at: now)
            || ((nativeTrackingStartPending || nativeTrackingActive)
                && faceLock.permitsInitialMotor(at: now))
        if nativeTrackingMayStart && nativeLeasePermitted {
            // Retain a device-confirmed native lock through a short detector
            // blip: the current frame briefly lost its face target (nil, a
            // body/saliency candidate taking precedence, or a fast head move)
            // while the verified face lock still holds. Only a sustained
            // absence confirmed by the native recovery supervisor should tear
            // the native lock down — the same principle as the vision_miss
            // retention above.
            if gate.isActive, !verifiedCurrentFaceLock, !nativeTrackingConfirmsTargetLoss(at: now) {
                nativeAction = gate.heartbeatIfActive(at: now)
            } else {
                nativeAction = gate.update(
                    belief,
                    immediateAcquisitionPermitted: immediateNativeAcquisition
                )
            }
        } else {
            nativeAction = gate.invalidate()
        }
        if now - lastNativeGateDiagnosticNS >= 500_000_000 {
            lastNativeGateDiagnosticNS = now
            let diagTarget = belief.target
            writer.write(RuntimeEvent(
                event: "native.gate",
                monotonicNS: now,
                source: "native_gate",
                state: String(describing: nativeAction),
                message: "target=\(diagTarget?.label ?? "nil")/\(diagTarget?.id ?? "-")"
                    + " conf=\(String(format: "%.2f", diagTarget?.confidence ?? 0))"
                    + " post=\(String(format: "%.2f", diagTarget?.posteriorProbability ?? 0))"
                    + " eligible=\(diagTarget?.isActionEligible ?? false)"
                    + " lockScene=\(faceLock.sceneID ?? "-")"
                    + " lockActive=\(faceLock.isActive(at: now))"
                    + " lockPermits=\(faceLock.permitsMotor(at: now))"
                    + " lockProvisional=\(faceLock.isProvisional(at: now))"
                    + " gateActive=\(gate.isActive)"
                    + " verifiedLock=\(verifiedCurrentFaceLock)"
                    + " recovery=\(nativeTrackingRecovery.state.rawValue)"
                    + " enabled=\(nativeHumanTrackingEnabled)"
                    + " runtimeAvailability=\(nativeTrackingRuntimeAvailability.rawValue)"
                    + " nativeActive=\(nativeTrackingActive)"
                    + " cooldownUntil=\(nativeRetryCooldownUntilNS.map { $0 >= now ? String(format: "%.0f", Double($0 - now) / 1e9) : "0" } ?? "-")s"
                    + " pending=\(nativeTrackingStartPending)"
                    + " deadlineIn=\(nativeStartDeadlineNS.map { $0 >= now ? String(format: "%.0f", Double($0 - now) / 1e9) : "0" } ?? "-")s"
            ))
        }
        let externalAction: ExternalGimbalAttentionAction
        if var externalGate {
            // Keep the visual servo alive while a fresh face earns the native
            // lease. Once the device confirms native tracking, it becomes the
            // sole motor owner; a face must never create a 500 ms dead zone.
            let nativeHandoffPending = nativeTrackingMayStart
                && (nativeTrackingStartPending || nativeAction == .start)
            let nativeOwnsHuman = nativeTrackingActive || nativeHandoffPending
            let faceBearing: GimbalRelativeBearing?
            if let target = belief.target,
               let stored = freshFaceBearings[target.id],
               now >= stored.observedNS,
               now - stored.observedNS <= 500_000_000 {
                faceBearing = stored.bearing
            } else {
                faceBearing = nil
            }
            let currentPose = poseStore.current()
            let currentVelocity = poseStore.currentVelocity()
            // External velocity is a physical closed loop. A face rectangle
            // without its capture-time bearing or a current device attitude is
            // awareness, not enough state to steer the gimbal: image-space
            // fallback here was the source of full-speed starts before the
            // pose loop could establish its absolute target.
            let hasFaceServoReference = belief.target?.isFaceMotorTarget != true
                || (faceBearing != nil && currentPose != nil)
            let observationAction = hasFaceServoReference
                ? externalGate.update(
                    belief,
                    faceBearing: faceBearing,
                    faceObservationNS: belief.target.flatMap { target in
                        freshFaceBearings[target.id]?.captureNS
                    },
                    currentPose: currentPose,
                    currentVelocity: currentVelocity,
                    poseProjection: externalPoseProjection
                )
                : (externalCommandID == nil ? .none : .stop)
            externalAction = nativeOwnsHuman
                ? (externalCommandID != nil || scanRunning ? .stop : .none)
                : observationAction
            self.externalGate = externalGate
        } else {
            externalAction = .none
        }
        if belief.target?.kind == .human {
            apply(externalAction, at: now, target: belief.target, reason: reason)
            apply(nativeAction, at: now, target: belief.target, reason: reason)
        } else {
            apply(nativeAction, at: now, target: belief.target, reason: reason)
            apply(externalAction, at: now, target: belief.target, reason: reason)
        }
    }

    private func recordAttentionDecision(
        _ decision: SubconsciousAttentionDecision,
        target: AttentionTarget?,
        at monotonicNS: UInt64
    ) {
        let attentionStateSignature = "\(decision.state.rawValue)|\(decision.permitsNativeSocialTracking)|\(decision.permitsExternalSocialReframing)"
        let focusSignature = "\(attentionStateSignature)|\(decision.sceneID ?? "none")|\(target?.kind.rawValue ?? "none")|\(target?.label ?? "none")|\(target?.isFaceMotorTarget == true)"
        if focusSignature != lastAttentionDecisionSignature {
            lastAttentionDecisionSignature = focusSignature
            behaviorAttentionState = decision.state.rawValue
            behaviorChangedAtNS = monotonicNS
            recentAttentionStates.append(decision.state.rawValue)
            if recentAttentionStates.count > 16 {
                recentAttentionStates.removeFirst(recentAttentionStates.count - 16)
            }
        }
        // A behavioral-state transition is much slower than visual evidence.
        // Always project the latest target into L1 context so a stale
        // face-shaped candidate cannot masquerade as the current focus after
        // L0 has already returned to exploration.
        behaviorTargetLabel = target?.label
        behaviorTargetConfidence = target?.confidence ?? 0
        behaviorIsFaceTarget = target?.isFaceMotorTarget ?? false
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: monotonicNS,
            source: "l0_attention_controller",
            state: decision.state.rawValue,
            message: String(
                format: "scene_id=%@; target=%@; posterior_probability=%.3f; native_social_tracking=%@",
                decision.sceneID ?? "none",
                target?.label ?? "none",
                decision.posteriorProbability,
                decision.permitsNativeSocialTracking ? "eligible" : (decision.permitsExternalSocialReframing ? "social_reframe" : "not_eligible")
            )
        ))
    }

    func makeBehaviorContext(at nowNS: UInt64) -> L1BehaviorContext {
        let fixationSeconds = behaviorChangedAtNS == 0 ? 0 : Double(nowNS - behaviorChangedAtNS) / 1_000_000_000
        return L1BehaviorContext(
            attentionState: behaviorAttentionState,
            targetLabel: behaviorTargetLabel,
            targetConfidence: behaviorTargetConfidence,
            isFaceTarget: behaviorIsFaceTarget,
            fixationSeconds: fixationSeconds,
            scanActive: scanRunning,
            idleSeconds: fixationSeconds,
            recentStates: recentAttentionStates,
            recognizedIdentity: recognizedIdentityProvider?()
        )
    }

    /// The L0 face lock is the current real-time social commitment. L1 may
    /// deliberately supersede it, but an auxiliary model's wake-up cannot turn
    /// its own advisory cue into an indirect motor preemption.
    func hasVerifiedFaceLock(at monotonicNS: UInt64) -> Bool {
        faceLock.permitsMotor(at: monotonicNS)
    }

    private func recordCurrentVisualAttention(at monotonicNS: UInt64) {
        actionableVisualContinuity.recordObservation(at: monotonicNS)
        confirmedVisualLossNS = nil
        visualEvidenceGeneration += 1
        scanScheduledForEvidenceGeneration = nil
    }

    private func recordNativeTrackingHumanEvidence(at monotonicNS: UInt64) {
        let prior = nativeTrackingRecovery.state
        nativeTrackingRecovery.recordHumanObservation(at: monotonicNS)
        guard prior == .reacquiring else { return }
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: monotonicNS,
            source: "native_tracking",
            state: "visual_reacquired",
            message: "Fresh human evidence restored the native tracking lease"
        ))
        refreshIndicator(at: monotonicNS, forceHardwareReassertion: true)
    }

    /// Native tracking is retained only while it is visibly following the
    /// person. A moving gimbal receives a bounded opportunity to bring an
    /// off-screen target back; a stationary gimbal with no human evidence has
    /// already stopped recovering and releases after that state is confirmed.
    private func nativeTrackingConfirmsTargetLoss(at monotonicNS: UInt64) -> Bool {
        // Pending and newly accepted handoffs are governed by their explicit
        // acquisition/liveness deadline. Visual recovery becomes authoritative
        // only after native motion has been functionally verified.
        guard nativeTrackingActive, nativeTrackingFunctionallyVerified else {
            return false
        }
        let prior = nativeTrackingRecovery.state
        let next = nativeTrackingRecovery.evaluateAbsence(
            at: monotonicNS,
            measuredVelocity: poseStore.currentVelocity(maximumAgeNS: 250_000_000)
        )
        guard next != prior else { return next == .targetLost }
        switch next {
        case .tracking:
            break
        case .reacquiring:
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNS,
                source: "native_tracking",
                state: "visual_reacquisition_started",
                message: "Human evidence absent; native motion remains under bounded observation"
            ))
            // Firmware can expose its own lost-target presentation as soon as
            // the subject leaves frame. Preserve SOMA's semantic state while
            // recovery is still in progress.
            refreshIndicator(at: monotonicNS, forceHardwareReassertion: true)
        case .targetLost:
            indicatorInputs.visualState = .none
            eyeContactIndicatorLease.clear()
            lastFreshHumanObservationNS = nil
            refreshIndicator(at: monotonicNS, forceHardwareReassertion: true)
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNS,
                source: "native_tracking",
                state: "target_departure_confirmed",
                message: "No human evidence and no viable native recovery trajectory; releasing to spatial search"
            ))
        }
        return next == .targetLost
    }

    private func releaseSocialFaceLock(at monotonicNS: UInt64, reason: String) {
        let wasVerified = faceLock.permitsMotor(at: monotonicNS)
        let hadFaceLock = faceLock.isActive(at: monotonicNS)
        socialRetentionDeadlineNS = nil
        guard hadFaceLock else { return }
        faceLock.invalidate()
        onL0FaceFixation(nil, false, monotonicNS)
        if !wasVerified {
            faceFixationCooldownUntilNS = monotonicNS + faceFixationReleaseCooldownNS
        }
        lastMotorTarget = nil
        activeSpatialFaceReacquisition = nil
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: monotonicNS,
            source: "attention_gimbal_bridge",
            state: "social_face_lock_released",
            message: "reason=\(reason); verified=\(wasVerified)"
        ))
    }

    /// The device-confirmed native lease (or a pending handoff) owns the
    /// gimbal. Competing L0 attention — a body candidate of the tracked
    /// person, a scene/object candidate, or a detector-ID transition — is
    /// perception-only while native visual recovery remains viable: it must
    /// not tear the lease down (gate.invalidate sends a manual_stop, which
    /// kills the device's AI lock) nor steer the gimbal (an external motion
    /// would yield the device's tracking away). Only a sustained absence
    /// confirmed by visual absence plus measured gimbal recovery state, an
    /// explicit release, or a higher-authority motor claim may end the lease.
    /// Returns true when the lease was retained this frame.
    @discardableResult
    private func retainNativeLeaseThroughCompetingAttention(at now: UInt64) -> Bool {
        guard nativeTrackingActive || nativeTrackingStartPending else { return false }
        guard !nativeTrackingConfirmsTargetLoss(at: now) else { return false }
        let action = gate.heartbeatIfActive(at: now)
        if action != .none {
            apply(action, at: now, target: nil, reason: "native_lease_retained")
        }
        return true
    }

    private func quiesceForNonMotorAttention(
        at monotonicNS: UInt64,
        target: AttentionTarget?,
        reason: String
    ) {
        cancelScan()
        if retainNativeLeaseThroughCompetingAttention(at: monotonicNS) {
            return
        }
        let nativeAction = gate.invalidate()
        apply(nativeAction, at: monotonicNS, target: target, reason: reason)
        guard externalCommandID != nil else { return }
        cancelExternalStop()
        sendExternalStop(state: "scene_attention_no_motor", at: monotonicNS)
    }

    private func applySocialReframing(
        _ belief: BeliefSnapshot,
        target: AttentionTarget,
        at monotonicNS: UInt64,
        reason: String
    ) {
        guard target.kind == .human, target.label != "face" else {
            quiesceForNonMotorAttention(at: monotonicNS, target: target, reason: reason)
            return
        }
        // A body candidate of the tracked person (or a false-positive
        // person box) must not tear down a confirmed native lease or drag
        // the gimbal away from the device's AI lock.
        if retainNativeLeaseThroughCompetingAttention(at: monotonicNS) {
            return
        }
        cancelScan()
        let nativeAction = gate.invalidate()
        if var externalGate {
            let action = externalGate.update(
                belief,
                currentPose: poseStore.current(),
                poseProjection: externalPoseProjection,
                allowSocialReframing: true
            )
            self.externalGate = externalGate
            apply(nativeAction, at: monotonicNS, target: target, reason: reason)
            apply(action, at: monotonicNS, target: target, reason: reason)
        } else {
            apply(nativeAction, at: monotonicNS, target: target, reason: reason)
        }
    }

    private func applyVisualLoss(_ belief: BeliefSnapshot, at now: UInt64) {
        // Scene processing can observe a face one queue turn before the
        // selector publishes its matching belief. A miss in that interval is
        // not permission to restart exploration and look away from the face.
        guard !hasRecentObservedFace(at: now) else { return }
        // Hysteresis for the LED only: a fresh human observation within the
        // grace window keeps the indicator lit through brief detector misses,
        // so a per-frame confidence dip cannot strobe the LED. The attention
        // loss bookkeeping below (confirmedVisualLossNS, scan scheduling) must
        // ALWAYS run — a lit indicator (e.g. a low-confidence person or a
        // static false positive) must never freeze exploration, or the scan
        // never starts and the gimbal sits still forever.
        if indicatorInputs.visualState != .none {
            if let lastHit = lastFreshHumanObservationNS,
               now - lastHit < indicatorVisualGraceNS {
                // Keep the LED lit through the detector gap.
            } else {
                indicatorInputs.visualState = .none
                eyeContactIndicatorLease.clear()
                refreshIndicator(at: now)
            }
        }
        // Keep the first confirmed-loss time. Replacing it on every empty
        // detector frame makes every recovery grace period recede forever.
        if confirmedVisualLossNS == nil {
            confirmedVisualLossNS = now
        }
        let nativeAction = nativeTrackingMayStart
            ? (gate.isActive
                && !nativeTrackingConfirmsTargetLoss(at: now)
                ? gate.heartbeatIfActive(at: now)
                : gate.update(belief, hasVisualEvidence: false))
            : gate.invalidate()
        let externalAction: ExternalGimbalAttentionAction
        if var externalGate {
            externalAction = scanRunning ? .none : externalGate.recordVisualLoss(at: now)
            self.externalGate = externalGate
            // A just-lost face gets time to re-enter the current view before
            // coverage can pull the camera elsewhere. This keeps a detector
            // gap from turning a social fixation into a broad search sweep.
            scheduleScanAfterContinuousVisualLoss()
        } else if var idleExplorationGate {
            idleExplorationGate.recordNoCalibratedTarget(at: now)
            self.idleExplorationGate = idleExplorationGate
            scheduleScanAfterContinuousVisualLoss()
            externalAction = .none
        } else {
            externalAction = .none
        }
        if belief.target?.kind == .human {
            apply(externalAction, at: now, target: nil, reason: "vision_miss")
            apply(nativeAction, at: now, target: nil, reason: "vision_miss")
        } else {
            apply(nativeAction, at: now, target: nil, reason: "vision_miss")
            apply(externalAction, at: now, target: nil, reason: "vision_miss")
        }
    }

    /// Raw acoustic onsets enter perception immediately but do not own the
    /// motor merely because room level crossed an adaptive threshold. Speech
    /// corroboration or a genuinely sharp transient must admit the reflex.
    func ingestAuditoryOnset(_ evidence: SOMACore.AuditoryOnsetEvidence) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let admitted = self.auditoryOrientingAdmission.observeOnset(evidence) else { return }
            self.beginAuditoryOrienting(from: admitted, corroboration: "salient_transient")
        }
    }

    func ingestAuditoryVoiceActivity(
        active: Bool,
        confidence: Double,
        at monotonicNS: UInt64
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let admitted = self.auditoryOrientingAdmission.observeVoiceActivity(
                active: active,
                confidence: confidence,
                at: monotonicNS
            ) else { return }
            self.beginAuditoryOrienting(from: admitted, corroboration: "neural_voice")
        }
    }

    /// Tiny 3 Lite exposes firmware sound following as a motor mode, not as a
    /// passive direction sensor. It therefore receives authority only after
    /// evidence admission, and never while a live person already owns visual
    /// attention.
    private func beginAuditoryOrienting(
        from evidence: SOMACore.AuditoryOnsetEvidence,
        corroboration: String
    ) {
        let monotonicNS = max(evidence.monotonicNS, monotonicNanoseconds())
        guard case .running = state,
              helperReady,
              process.isRunning,
              deviceCapabilities?.supportsDeviceSoundLocalization == true,
              activeCognitiveMotorRequestID == nil,
              !auditoryMotorOrientationBlocked(at: monotonicNS) else {
            return
        }

        let requestID = nextCommandID(prefix: "auditory-orient")
        guard let episode = auditoryOrientingLease.begin(
            requestID: requestID,
            at: monotonicNS
        ) else {
            return
        }
        auditoryOrientationTrajectory = AuditoryOrientationTrajectory(
            requestID: requestID,
            onsetNS: evidence.monotonicNS,
            activationNS: nil,
            activationPose: nil
        )
        cancelScan()
        if externalCommandID != nil {
            cancelExternalStop()
            sendExternalStop(state: "auditory_orienting_acquired", at: monotonicNS)
            // External/manual mode invalidates firmware motor ownership even
            // when the last API readback still says sound following is active.
            firmwareSoundFollowingActive = nil
        }
        if firmwareSoundFollowingActive == true {
            armAuditoryOrientationTrajectory(at: monotonicNS)
        } else {
            requestFirmwareSoundFollowing(
                enabled: true,
                at: monotonicNS,
                reason: "auditory_evidence_admitted"
            )
        }
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: monotonicNS,
            source: "obsbot_audio_doa",
            state: "auditory_orienting_requested",
            message: String(
                format: "request_id=%@; corroboration=%@; level_db=%.1f; threshold_db=%.1f; onset_confidence=%.3f; transient=%@; visual_human=false; lease_ms=4500",
                requestID,
                corroboration,
                evidence.levelDB,
                evidence.thresholdDB,
                evidence.confidence,
                evidence.transient ? "true" : "false"
            )
        ))
        scheduleAuditoryOrientingExpiry(episode)
    }

    private func scheduleAuditoryOrientingExpiry(_ episode: SOMACore.AuditoryOrientingEpisode) {
        queue.asyncAfter(deadline: .now() + .nanoseconds(Int(auditoryOrientingLease.durationNS))) { [weak self] in
            guard let self,
                  self.auditoryOrientingLease.contains(requestID: episode.requestID) else {
                return
            }
            self.stopAuditoryOrienting(
                state: "auditory_orienting_expired",
                at: monotonicNanoseconds(),
                resumeExploration: !self.auditoryOrientingProtectedBySocialEngagement
            )
        }
    }

    private func stopAuditoryOrienting(
        state: String,
        at monotonicNS: UInt64,
        resumeExploration: Bool
    ) {
        guard let episode = auditoryOrientingLease.end() else { return }
        let requestID = episode.requestID
        finalizeAuditoryOrientation(
            requestID: requestID,
            state: state,
            at: monotonicNS
        )
        reconcileFirmwareSoundFollowing(at: monotonicNS, reason: state)
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: monotonicNS,
            source: "obsbot_audio_doa",
            state: state,
            message: "request_id=\(requestID); visual_face=\(hasRecentObservedFace(at: monotonicNS)); exploration_resume=\(resumeExploration)"
        ))
        if resumeExploration,
           activeCognitiveMotorRequestID == nil {
            scheduleScanAfterContinuousVisualLoss(minimumDelayMilliseconds: 150)
        }
    }

    private func armAuditoryOrientationTrajectory(at monotonicNS: UInt64) {
        guard var trajectory = auditoryOrientationTrajectory,
              trajectory.requestID == auditoryOrientingLease.activeRequestID,
              trajectory.activationNS == nil,
              let pose = poseStore.current(maximumAgeNS: 600_000_000) ?? poseStore.lastKnown() else {
            return
        }
        trajectory.activationNS = monotonicNS
        trajectory.activationPose = pose
        auditoryOrientationTrajectory = trajectory
        writer.write(RuntimeEvent(
            event: "audio.source",
            monotonicNS: monotonicNS,
            source: "obsbot_audio_doa",
            state: "trajectory_armed",
            message: String(
                format: "request_id=%@; onset_to_activation_ms=%.1f; start_azimuth_degrees=%.3f; start_elevation_degrees=%.3f",
                trajectory.requestID,
                milliseconds(from: trajectory.onsetNS, to: monotonicNS),
                pose.panDegrees,
                pose.pitchDegrees
            )
        ))
        scheduleAuditoryMotionQualification(for: trajectory)
    }

    private func scheduleAuditoryMotionQualification(
        for trajectory: AuditoryOrientationTrajectory
    ) {
        queue.asyncAfter(
            deadline: .now() + .nanoseconds(Int(auditoryMotionQualificationDelayNS))
        ) { [weak self] in
            guard let self,
                  self.auditoryOrientingLease.contains(requestID: trajectory.requestID),
                  let current = self.auditoryOrientationTrajectory,
                  current.requestID == trajectory.requestID,
                  let activationNS = current.activationNS,
                  let activationPose = current.activationPose else {
                return
            }
            let samples = self.poseStore.trajectory(
                from: activationNS,
                through: monotonicNanoseconds()
            )
            guard !SOMACore.FirmwareSoundSourceEstimator.hasMeasuredDirectionalMotion(
                startingPose: activationPose,
                trajectory: samples
            ) else {
                return
            }
            self.stopAuditoryOrienting(
                state: "auditory_orienting_no_measured_motion",
                at: monotonicNanoseconds(),
                resumeExploration: true
            )
        }
    }

    private func finalizeAuditoryOrientation(
        requestID: String,
        state: String,
        at monotonicNS: UInt64
    ) {
        guard let trajectory = auditoryOrientationTrajectory,
              trajectory.requestID == requestID else {
            return
        }
        auditoryOrientationTrajectory = nil
        guard let activationNS = trajectory.activationNS,
              let activationPose = trajectory.activationPose else {
            writer.write(RuntimeEvent(
                event: "audio.source",
                monotonicNS: monotonicNS,
                source: "obsbot_audio_doa",
                state: "estimate_unavailable",
                message: "request_id=\(requestID); reason=firmware_activation_not_observed; terminal_state=\(state)"
            ))
            return
        }
        let samples = poseStore.trajectory(from: activationNS, through: monotonicNS)
        guard let estimate = FirmwareSoundSourceEstimator.estimate(
            startingPose: activationPose,
            trajectory: samples
        ) else {
            writer.write(RuntimeEvent(
                event: "audio.source",
                monotonicNS: monotonicNS,
                source: "obsbot_audio_doa",
                state: "estimate_unavailable",
                message: "request_id=\(requestID); reason=insufficient_attitude_trajectory; samples=\(samples.count); terminal_state=\(state)"
            ))
            return
        }
        writer.write(AudioSourceBearingEvent(
            monotonicNS: monotonicNS,
            requestID: requestID,
            terminalState: state,
            estimate: estimate,
            sampleCount: samples.count
        ))
    }

    private func scheduleScanAfterContinuousVisualLoss(minimumDelayMilliseconds: Int? = nil) {
        guard !explorationRecentering, !coverageScanBlockedByMotorLease else { return }
        let evidenceGeneration = visualEvidenceGeneration
        guard scanScheduledForEvidenceGeneration != evidenceGeneration else { return }
        scanScheduledForEvidenceGeneration = evidenceGeneration
        let now = monotonicNanoseconds()
        // Social retention may reserve a longer local reacquisition window,
        // while the actuator gate owns the canonical absence dwell. Taking the
        // later of the two prevents the transport timer from racing either
        // state machine at an exact timing boundary.
        let baseDelayMilliseconds: Int
        if let minimumDelayMilliseconds {
            baseDelayMilliseconds = minimumDelayMilliseconds
        } else if faceLock.isActive(at: now),
           faceLock.permitsMotor(at: now) {
            // Keep the social identity latched while its remembered bearing
            // gets the first bounded recovery attempt. Broad coverage starts
            // only if that local attempt fails to put the face back in view.
            baseDelayMilliseconds = 1_500
        } else if externalGate == nil && idleExplorationGate != nil {
            baseDelayMilliseconds = 450
        } else {
            baseDelayMilliseconds = 450
        }
        let baseDeadlineNS = now + UInt64(baseDelayMilliseconds) * 1_000_000
        let gateDeadlineNS = autonomousScanEligibleAtNS() ?? now
        let firstAttemptNS = max(baseDeadlineNS, explorationEligibleAfterNS, gateDeadlineNS)
        scheduleScanAttempt(for: evidenceGeneration, noEarlierThan: firstAttemptNS)
    }

    private func autonomousScanEligibleAtNS() -> UInt64? {
        if let externalGate {
            return externalGate.nextScanEligibleAtNS
        }
        return idleExplorationGate?.nextScanEligibleAtNS
    }

    private func scheduleScanAttempt(
        for evidenceGeneration: Int,
        noEarlierThan deadlineNS: UInt64
    ) {
        let now = monotonicNanoseconds()
        let remainingNS = deadlineNS > now ? deadlineNS - now : 0
        let delayMilliseconds = max(1, Int((remainingNS + 999_999) / 1_000_000))
        queue.asyncAfter(deadline: .now() + .milliseconds(delayMilliseconds)) { [weak self] in
            guard let self,
                  self.visualEvidenceGeneration == evidenceGeneration,
                  self.scanScheduledForEvidenceGeneration == evidenceGeneration,
                  case .running = self.state,
                  self.helperReady else {
                return
            }
            let now = monotonicNanoseconds()
            // A callback may have been queued before helper readiness set the
            // start-up grace. Enforce the same boundary at execution time;
            // otherwise that stale callback can begin a sweep before the
            // first live face pass reaches the bridge.
            guard now >= self.explorationEligibleAfterNS else {
                self.scheduleScanAttempt(
                    for: evidenceGeneration,
                    noEarlierThan: self.explorationEligibleAfterNS
                )
                return
            }
            guard !self.hasRecentObservedFace(at: now) else {
                self.scanScheduledForEvidenceGeneration = nil
                return
            }
            // The state may have changed since this callback was armed. Do
            // not let coverage preempt a currently active motor lease.
            guard !self.coverageScanBlockedByMotorLease else {
                self.scanScheduledForEvidenceGeneration = nil
                return
            }
            let action: ExternalGimbalAttentionAction
            if var externalGate = self.externalGate {
                action = externalGate.beginScanIfEligible(at: now)
                self.externalGate = externalGate
            } else if var idleExplorationGate = self.idleExplorationGate {
                action = idleExplorationGate.beginIfEligible(at: now)
                self.idleExplorationGate = idleExplorationGate
            } else {
                self.scanScheduledForEvidenceGeneration = nil
                return
            }
            if action == .none {
                // Dispatch timing is approximate while the absence deadline is
                // monotonic. A timer that wakes fractionally early must remain
                // armed rather than silently consuming this entire no-target
                // interval. The next attempt is derived from the gate's state,
                // so this cannot spin after a fresh target or disabled gate.
                guard let gateDeadlineNS = self.autonomousScanEligibleAtNS() else {
                    self.scanScheduledForEvidenceGeneration = nil
                    return
                }
                self.scheduleScanAttempt(
                    for: evidenceGeneration,
                    noEarlierThan: max(gateDeadlineNS, now + 1_000_000)
                )
                return
            }
            self.apply(action, at: now, target: nil, reason: "visual_absence_timeout")
        }
    }

    private func apply(
        _ action: NativeHumanTrackingAction,
        at now: UInt64,
        target: AttentionTarget?,
        reason: String
    ) {
        switch action {
        case .none:
            return
        case .start:
            guard let target else { return }
            guard nativeTrackingMayStart, !nativeTrackingActive else {
                _ = gate.invalidate()
                return
            }
            guard now >= (nativeRetryCooldownUntilNS ?? 0) else {
                // Gate ownership is provisional until the command is written
                // to the bridge. Leaving it active during a cooldown makes a
                // failed handoff look like a live device lock and prevents the
                // next eligible frame from retrying.
                _ = gate.invalidate()
                return
            }
            if nativeTrackingStartPending {
                // A pending start whose confirmation window has passed is
                // stale: clear it (and the helper's half-finished handoff)
                // before starting fresh.
                guard now >= (nativeStartDeadlineNS ?? .max) else {
                    _ = gate.invalidate()
                    return
                }
                nativeStartDeadlineNS = nil
                nativeTrackingStartPending = false
                _ = gate.invalidate()
                let cleanupID = nextCommandID(prefix: "manual-stop")
                send("manual_stop \(cleanupID)")
                writer.write(CameraIntentEvent(
                    monotonicNS: now,
                    owner: .nativeAI,
                    state: "native_tracking_timeout",
                    route: .none,
                    commandID: cleanupID,
                    targetKind: nil,
                    targetLabel: nil,
                    targetProbability: 0
                ))
            }
            let commandID = nextCommandID(prefix: "native-human")
            nativeTrackingStartPending = true
            nativeStartDeadlineNS = now + nativeStartConfirmationWindowNS
            // The native lease makes the device the sole motor owner. The
            // coverage scan must not keep emitting external velocity during
            // the handoff: the helper yields native tracking to any external
            // velocity command, so a leftover scan pulse would kill the very
            // lock this start is establishing.
            cancelScan()
            cancelExternalStop()
            externalCommandID = nil
            let targetRect = target.rect.clippedToUnitSquare()
            let bridgeLocale = Locale(identifier: "en_US_POSIX")
            let targetBox = targetRect.map { rect in
                [rect.x, rect.y, rect.width, rect.height]
                    .map { String(format: "%.6f", locale: bridgeLocale, arguments: [$0]) }
                    .joined(separator: " ")
            }
            send("native_start \(commandID)\(targetBox.map { " \($0)" } ?? "")")
            nativeCommandID = commandID
            writer.write(CameraIntentEvent(
                monotonicNS: now,
                owner: .nativeAI,
                state: "native_tracking_requested",
                route: .nativeHumanTracking,
                commandID: commandID,
                targetKind: target.kind,
                targetLabel: target.label,
                targetProbability: target.posteriorProbability
            ))
        case .heartbeat:
            guard nativeTrackingActive, let commandID = nativeCommandID else { return }
            send("heartbeat \(commandID)")
        case .stop:
            // A pending start is an ordered barrier: the helper is switching
            // the device into AI tracking (external yield + mode switch takes
            // ~1-4s), and an app-side detector gap during that window is not
            // permission to cancel the handoff. Tearing the start down on a
            // gap makes it cancel itself before the device confirms, then the
            // helper still holds the half-finished tracking, so the next start
            // bounces off with owner_busy and native tracking never engages.
            // Only the bounded confirmation window (device never confirmed)
            // cancels a pending start.
            if nativeTrackingStartPending {
                guard now >= (nativeStartDeadlineNS ?? .max) else { return }
                nativeStartDeadlineNS = nil
            }
            stopNativeHeartbeatLoop()
            nativeTrackingLiveness.cancel()
            let commandID = nextCommandID(prefix: "manual-stop")
            send("manual_stop \(commandID)")
            nativeCommandID = nil
            nativeTrackingActive = false
            nativeTrackingFunctionallyVerified = false
            nativeTrackingStartPending = false
            nativeTrackingRecovery.reset()
            writer.write(CameraIntentEvent(
                monotonicNS: now,
                owner: .nativeAI,
                state: reason == "vision_miss" ? "vision_lost" : "target_not_human_or_not_credible",
                route: .none,
                commandID: commandID,
                targetKind: nil,
                targetLabel: nil,
                targetProbability: 0
            ))
        }
    }

    /// A native start the device never confirmed within its window is stale:
    /// cancel it so a later start attempt is not blocked forever. Runs on the
    /// belief frame path, so a stuck pending start is cleaned up within one
    /// frame of the deadline even when no vision loss ever arrives.
    private func cancelStaleNativeStartIfNeeded(at now: UInt64) {
        guard nativeTrackingStartPending,
              let deadline = nativeStartDeadlineNS,
              now >= deadline else { return }
        nativeStartDeadlineNS = nil
        nativeTrackingStartPending = false
        _ = gate.invalidate()
        // A start the device never confirmed within the window is a failure
        // too: back off so a wedged device is not hammered on every frame.
        nativeConsecutiveFailures += 1
        let cooldownMilliseconds = min(
            10_000 * (1 << min(nativeConsecutiveFailures - 1, 3)),
            60_000
        )
        nativeRetryCooldownUntilNS = now + UInt64(cooldownMilliseconds) * 1_000_000
        let commandID = nextCommandID(prefix: "manual-stop")
        send("manual_stop \(commandID)")
        writer.write(CameraIntentEvent(
            monotonicNS: now,
            owner: .nativeAI,
            state: "native_tracking_timeout",
            route: .none,
            commandID: commandID,
            targetKind: nil,
            targetLabel: nil,
            targetProbability: 0
        ))
    }

    /// The helper's 750 ms ownership watchdog protects against a dead bridge,
    /// not a momentary detector gap. Once native tracking is acknowledged,
    /// keep that watchdog alive from the control queue until this bridge
    /// explicitly releases the native lease.
    private func startNativeHeartbeatLoop() {
        nativeHeartbeatGeneration += 1
        scheduleNativeHeartbeat(generation: nativeHeartbeatGeneration)
    }

    private func scheduleNativeHeartbeat(generation: Int) {
        queue.asyncAfter(deadline: .now() + .milliseconds(200)) { [weak self] in
            guard let self,
                  generation == self.nativeHeartbeatGeneration,
                  case .running = self.state,
                  self.process.isRunning,
                  self.helperReady,
                  self.nativeTrackingActive else {
                return
            }
            let now = monotonicNanoseconds()
            self.apply(
                self.gate.heartbeatIfActive(at: now),
                at: now,
                target: nil,
                reason: "native_tracking_lease"
            )
            self.scheduleNativeHeartbeat(generation: generation)
        }
    }

    private func stopNativeHeartbeatLoop() {
        nativeHeartbeatGeneration += 1
    }

    private func recentObservedFaceRect(at monotonicNS: UInt64) -> SOMACore.NormalizedRect? {
        guard let lastObservedFaceNS,
              let lastObservedFaceRect,
              monotonicNS >= lastObservedFaceNS,
              monotonicNS - lastObservedFaceNS <= 750_000_000 else {
            return nil
        }
        return lastObservedFaceRect
    }

    private func startNativeTrackingLivenessCheck(at monotonicNS: UInt64) {
        let token = nativeTrackingLiveness.begin(
            target: recentObservedFaceRect(at: monotonicNS),
            pose: poseStore.lastKnown(),
            at: monotonicNS
        )
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: monotonicNS,
            source: "native_tracking",
            state: "functional_verification_started",
            message: "deadline_ms=\(nativeTrackingLiveness.acquisitionTimeoutMilliseconds); transport_acceptance_is_not_a_lock"
        ))
        queue.asyncAfter(
            deadline: .now() + .milliseconds(nativeTrackingLiveness.acquisitionTimeoutMilliseconds)
        ) { [weak self] in
            self?.evaluateNativeTrackingLiveness(token: token)
        }
    }

    private func evaluateNativeTrackingLiveness(token: UInt64) {
        guard case .running = state, nativeTrackingActive else { return }
        let now = monotonicNanoseconds()
        let result = nativeTrackingLiveness.evaluate(
            token: token,
            target: recentObservedFaceRect(at: now),
            pose: poseStore.lastKnown(),
            at: now
        )
        switch result {
        case .superseded:
            return
        case .observing:
            queue.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
                self?.evaluateNativeTrackingLiveness(token: token)
            }
        case .confirmed:
            nativeTrackingRuntimeAvailability = .verified
            nativeTrackingFunctionallyVerified = true
            nativeConsecutiveFailures = 0
            nativeRetryCooldownUntilNS = nil
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: now,
                source: "native_tracking",
                state: "functional_verification_confirmed",
                message: "target_centering_or_measured_progress"
            ))
        case .unresponsive:
            nativeTrackingFunctionallyVerified = false
            nativeConsecutiveFailures += 1
            let cooldownMilliseconds = min(
                5_000 * (1 << min(nativeConsecutiveFailures - 1, 3)),
                40_000
            )
            nativeRetryCooldownUntilNS = now + UInt64(cooldownMilliseconds) * 1_000_000
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: now,
                source: "native_tracking",
                state: "functional_verification_failed",
                message: "no_target_centering_or_measured_progress; runtime_capability=retryable; retry_after_ms=\(cooldownMilliseconds); retaining_visual_face_lock"
            ))
            // A native mode that does not react disproves only its own motor
            // claim. The independently verified visual face stays eligible
            // for the predictive external tracker on the next video frame.
            let stop = gate.stop()
            apply(stop, at: now, target: nil, reason: "native_tracking_unresponsive")
        }
    }

    private var nativeTrackingMayStart: Bool {
        nativeHumanTrackingEnabled
            && deviceContract?.supportsNativeHumanTracking == true
            && nativeTrackingRuntimeAvailability.permitsNewHandoff
    }

    private func apply(
        _ action: ExternalGimbalAttentionAction,
        at now: UInt64,
        target: AttentionTarget?,
        reason: String
    ) {
        switch action {
        case .none:
            return
        case let .velocity(pitch, pan):
            if target == nil {
                startSmoothExploration()
            } else {
                guard let target else { return }
                cancelScan()
                if target.isFaceMotorTarget {
                    sendExternalVelocity(
                        pitch: pitch,
                        pan: pan,
                        state: "face_servo_velocity_requested",
                        target: target,
                        at: now,
                        hardStopAfterNS: 350_000_000
                    )
                    return
                }
                sendExternalVelocity(
                    pitch: pitch,
                    pan: pan,
                    state: target.kind == .human ? "social_reframe_requested" : "visual_fixation_requested",
                    target: target,
                    at: now,
                    hardStopAfterNS: 350_000_000
                )
            }
        case .hold:
            guard let target, target.isFaceMotorTarget else { return }
            cancelScan()
            sendExternalVelocity(
                pitch: 0,
                pan: 0,
                state: "face_hold_requested",
                target: target,
                at: now,
                hardStopAfterNS: 350_000_000
            )
        case .stop:
            cancelScan()
            cancelExternalStop()
            sendExternalStop(state: reason == "vision_miss" ? "vision_lost" : "external_attention_released", at: now)
        }
    }

    private func applySceneCandidates(
        _ candidates: [SceneCandidate],
        captureNS: UInt64,
        at monotonicNS: UInt64
    ) {
        guard !cameraGeometryCalibrationMode, !panoramaStripScanMode else { return }
        if calibrationMode {
            return
        }
        // A raw face rectangle is a hypothesis, not yet social evidence. It
        // must either be independently verified or show face activity before
        // it can alter the outward human-presence signal. This rejects a
        // reflection of SOMA's own camera while keeping a real person at the
        // edge responsive as soon as either evidence source arrives.
        let socialHumanCandidates = candidates.filter {
            guard $0.observedThisFrame, $0.observation.kind == .human else {
                return false
            }
            guard $0.observation.label == "face" else {
                // A body-only detector result is useful before a face enters
                // view, but a single low-confidence rectangle must not turn a
                // chair or curtain edge into a visible person. SceneField's
                // second geometrically associated observation is the minimum
                // temporal evidence for body-only social presence.
                return $0.isActionEligible && $0.observationCount >= 2
            }
            return $0.faceVerificationEligible || $0.faceActivityEligible
        }
        if !socialHumanCandidates.isEmpty {
            lastFreshHumanObservationNS = monotonicNS
            recordNativeTrackingHumanEvidence(at: monotonicNS)
            if auditoryOrientingLease.isActive {
                stopAuditoryOrienting(
                    state: "visual_human_preempted_auditory_orientation",
                    at: monotonicNS,
                    resumeExploration: false
                )
            }
            let priorVisualState = indicatorInputs.visualState
            indicatorInputs.observeHumanVisualPresence()
            // A person is in view but the ready-to-speak blink must still
            // fall back to human_detected once the eye-contact lease expires,
            // even on frames that yield no fresh face observation (face briefly
            // undetected or the person has stopped looking). Without this, the
            // blink can stay asserted while the user looks away.
            let hasFreshEyeContactThisFrame = socialHumanCandidates.contains {
                $0.observation.label == "face" && $0.eyeContactEligible
            }
            if indicatorInputs.visualState == .eyeContact,
               !hasFreshEyeContactThisFrame,
               !eyeContactIndicatorLease.isActive(at: monotonicNS) {
                indicatorInputs.visualState = .humanDetected
            }
            if indicatorInputs.visualState != priorVisualState {
                refreshIndicator(at: monotonicNS)
            }
        }
        guard process.isRunning,
              helperReady,
              !explorationRecentering else {
            return
        }
        freshFaceBearings.removeAll(keepingCapacity: true)
        for candidate in candidates where candidate.observedThisFrame
            && candidate.observation.kind == .human
            && candidate.observation.label == "face"
            && candidate.observation.source == .neuralFaceDetector {
            if let bearing = candidate.observedBearing ?? candidate.bearing {
                freshFaceBearings[candidate.id] = (
                    bearing: bearing,
                    captureNS: captureNS,
                    observedNS: monotonicNS
                )
            }
        }
        guard activeCognitiveMotorRequestID == nil else { return }
        let observedFaces = candidates.filter { candidate in
            candidate.observedThisFrame
                && candidate.observation.kind == .human
                && candidate.observation.label == "face"
                && candidate.isActionEligible
        }
        // A complete landmark set can acquire a static, real face immediately.
        // An ANE-only candidate normally needs world-relative activity. During
        // an active exploration pulse that activity cannot be measured, so a
        // repeated high-confidence face may only open the provisional external
        // re-centering path; native authority still requires verification.
        // A landmark-verified face is a real person (the verifier rules out
        // static face-shaped distractors), so it may interrupt the coverage
        // scan even while it is near an edge. Requiring a foveal frame here let
        // the scan sweep past the user and keep running, destabilizing the
        // person's identity because the gimbal never stopped to face them.
        let verifiedFace = observedFaces
            .filter { $0.faceVerificationEligible }
            .max { $0.observation.confidence < $1.observation.confidence }
        let heldFace = observedFaces.first(where: {
            faceLock.permitsMotor(at: monotonicNS)
                && faceLock.holds(sceneID: $0.id, rect: $0.observation.rect, at: monotonicNS)
        })
        let observedFace: SceneCandidate?
        if let heldFace,
           !(faceLock.isProvisional(at: monotonicNS)
                && verifiedFace?.id != heldFace.id) {
            observedFace = heldFace
        } else if let verifiedFace {
            // A landmark-confirmed face must immediately replace a provisional
            // ANE-only lookalike. Raw candidates still acquire first when
            // they are alone, but they cannot make a person wait out a false
            // lock once independent face evidence arrives.
            observedFace = verifiedFace
        } else if !faceLock.permitsMotor(at: monotonicNS) {
            // A moving raw face may acquire the initial provisional lease,
            // but it may never replace an already confirmed social reference.
            // The earlier ordering let an unrelated active false positive
            // steal a live face lock and turn the gimbal away from the user.
            observedFace = observedFaces
                .filter {
                    let provisionalExplorationInterception = scanRunning
                        && FaceLockLease.permitsProvisionalExplorationInterception(
                            observationCount: $0.observationCount,
                            confidence: $0.observation.confidence
                        )
                    // The native tracker takes the image-space target box
                    // directly, so an edge face is exactly where it has the
                    // most value: it can acquire before the coverage motion
                    // carries the person out of view.  The old foveal-only
                    // rule was appropriate for an external velocity servo but
                    // incorrectly prevented native acquisition altogether.
                    return $0.faceActivityEligible || provisionalExplorationInterception
                }
                .max { $0.observation.confidence < $1.observation.confidence }
        } else if faceLock.permitsMotor(at: monotonicNS) {
            // Keep the current verified social reference through a detector
            // ID gap. A new raw rectangle waits for independent verification
            // rather than becoming an arbitrary handoff target.
            observedFace = nil
        } else {
            observedFace = nil
        }
        if let observedFace {
            // A current face gets one short re-centering attempt even before
            // independent verification, so an edge-clipped real face is not
            // discarded before the verifier can see it. Verification is still
            // required to extend the lease or enable native AI tracking.
            let accepted: Bool
            if monotonicNS < faceFixationCooldownUntilNS,
               !observedFace.faceVerificationEligible {
                // The cooldown suppresses only the unverified geometry that
                // caused the release. Independent face evidence represents a
                // new observation and must reacquire immediately.
                accepted = false
            } else {
                accepted = faceLock.observe(
                    sceneID: observedFace.id,
                    rect: observedFace.observation.rect,
                    verified: observedFace.faceVerificationEligible,
                    at: monotonicNS
                )
            }
            if accepted, faceLock.permitsInitialMotor(at: monotonicNS) {
                let preemptedExploration = scanRunning || activeSpatialFaceReacquisition != nil
                lastObservedFaceNS = monotonicNS
                lastObservedFaceRect = observedFace.observation.rect
                if observedFace.faceVerificationEligible {
                    preemptCognitiveExpressionForVerifiedFace(at: monotonicNS)
                }
                let hasSocialFaceEvidence = observedFace.faceVerificationEligible
                    || observedFace.faceActivityEligible
                var lockedGazeEvidence: SOMACore.VisualGazeEvidence = .unavailable
                if faceLock.isActive(at: monotonicNS), hasSocialFaceEvidence {
                    // The motor lock chooses one rectangle, whereas landmark
                    // gaze can arrive through a second, geometrically
                    // associated detector in the same frame. Fuse all
                    // associated estimates before deciding the social signal;
                    // otherwise a held ANE rectangle with no landmarks can
                    // hide a fresh direct-gaze result from System Vision.
                    let associatedGazeEvidence = SOMACore.VisualGazeEvidence.combined(
                        observedFaces
                            .filter {
                                faceLock.holds(
                                    sceneID: $0.id,
                                    rect: $0.observation.rect,
                                    at: monotonicNS
                                )
                            }
                            .map(\.observation.gazeEvidence)
                    )
                    lockedGazeEvidence = observedFace.faceInteractionLivenessEligible
                        ? associatedGazeEvidence
                        : .unavailable
                    // Eye contact is perceptual evidence from the current
                    // face lock, but static face geometry is insufficient for
                    // social admission. Interaction liveness is established
                    // independently from the landmark gaze classifier.
                    let contactReady = eyeContactIndicatorLease.update(
                        gazeEvidence: lockedGazeEvidence,
                        sceneID: observedFace.id,
                        at: monotonicNS
                    )
                    indicatorInputs.visualState = contactReady ? .eyeContact : .humanDetected
                    refreshIndicator(at: monotonicNS)
                    socialTrackingContinuity.recordObservation(at: monotonicNS)
                    recordNativeTrackingHumanEvidence(at: monotonicNS)
                }
                // Invalidate any absence callback that was queued before this
                // frame. It must not revive a search pulse after preemption.
                visualEvidenceGeneration += 1
                scanScheduledForEvidenceGeneration = nil
                activeSpatialFaceReacquisition = nil
                attemptedSpatialFaceReacquisitionIDs.removeAll()
                explorationFailureCount = max(0, explorationFailureCount - 1)
                cancelScan()
                // A direct gaze observation becomes eligible to open Live
                // Voice only after this accepted L0 face lock has cancelled
                // the active coverage route. This preserves the first spoken
                // utterance while rejecting gaze history left behind by a
                // scan that is still moving elsewhere.
                if faceLock.permitsMotor(at: monotonicNS) {
                    onL0FaceFixation(
                        observedFace.id,
                        lockedGazeEvidence == .direct,
                        monotonicNS
                    )
                } else {
                    onL0FaceFixation(nil, false, monotonicNS)
                }
                if preemptedExploration, externalCommandID != nil {
                    cancelExternalStop()
                    sendExternalStop(state: "face_observation_preempted_exploration", at: monotonicNS)
                }
                let directTarget = AttentionTarget(
                    id: observedFace.id,
                    rect: observedFace.observation.rect,
                    confidence: observedFace.observation.confidence,
                    velocityX: 0,
                    velocityY: 0,
                    kind: observedFace.observation.kind,
                    label: observedFace.observation.label,
                    attentionWeight: observedFace.observation.attentionWeight,
                    posteriorProbability: observedFace.spatialConfidence,
                    stabilityMilliseconds: observedFace.stabilityMilliseconds,
                    isActionEligible: observedFace.isActionEligible
                )
                let nativeAction: NativeHumanTrackingAction
                // SceneField is the first path that has both the current
                // image-space face box and independent verification. Waiting
                // for the later belief pass leaves the coverage trajectory in
                // control for another frame or more, which is enough for an
                // edge face to leave the camera before the firmware accepts
                // its tracking transition. Start the bounded native lease at
                // this verified frame; raw ANE-only rectangles still receive
                // only the provisional local fixation above.
                if observedFace.faceVerificationEligible,
                   faceLock.permitsMotor(at: monotonicNS),
                   nativeTrackingMayStart,
                   !nativeTrackingActive,
                   !nativeTrackingStartPending {
                    nativeAction = gate.acquireFromTemporalFaceEvidence(
                        at: monotonicNS
                    )
                    writer.write(RuntimeEvent(
                        event: "source.health",
                        monotonicNS: monotonicNS,
                        source: "native_tracking",
                        state: "verified_face_handoff",
                        message: "scene_id=\(observedFace.id); source=scene_field; coverage_preempted=\(preemptedExploration)"
                    ))
                } else {
                    nativeAction = gate.heartbeatIfActive(at: monotonicNS)
                }
                apply(
                    nativeAction,
                    at: monotonicNS,
                    target: directTarget,
                    reason: observedFace.observation.source.rawValue
                )
                return
            }
        }

        // Native-only installations still need a local face lock. Only the
        // optional external spatial re-acquisition path depends on a learned
        // screen-to-gimbal calibration.
        guard externalCalibration != nil,
              faceLock.permitsMotor(at: monotonicNS),
              let lockedFaceID = faceLock.sceneID else { return }
        guard let rememberedFace = candidates
            .filter({ candidate in
                !candidate.observedThisFrame
                    && candidate.observation.kind == .human
                    && candidate.observation.label == "face"
                    && candidate.id == lockedFaceID
                    && candidate.observationCount >= 2
                    && candidate.spatialConfidence >= 0.70
                    && candidate.bearing != nil
            })
            .min(by: { $0.lastSeenMilliseconds < $1.lastSeenMilliseconds }) else {
            return
        }
        guard let confirmedVisualLossNS,
              monotonicNS >= confirmedVisualLossNS + 200_000_000 else { return }
        applySpatialFaceReacquisition(rememberedFace, at: monotonicNS)
    }

    private func releaseWrongFixation(reason: String, at monotonicNS: UInt64, priority: ScanPriority = .l0) {
        faceLock.invalidate()
        onL0FaceFixation(nil, false, monotonicNS)
        lastMotorTarget = nil
        // Make the release sticky: block re-acquiring the same (possibly
        // false-positive) face lock for the cooldown window so the coverage
        // scan actually runs instead of instantly re-latching.
        faceFixationCooldownUntilNS = monotonicNS + faceFixationReleaseCooldownNS
        let nativeAction = gate.invalidate()
        apply(nativeAction, at: monotonicNS, target: nil, reason: reason)
        sendExternalStop(state: reason, at: monotonicNS)
        resumeCoverageScan(priority: priority)
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: monotonicNS,
            source: "l0_auxiliary_release",
            state: reason,
            message: "Released a fixation judged to be wrong; resumed coverage scan (priority \(priority))"
        ))
    }

    private func applySemanticHumanVerdict(_ cue: L1AuxiliarySemanticCue) {
        let now = monotonicNanoseconds()
        let strongNonHumanVerdict = cue.confidence >= 0.75
            && cue.socialPresence <= 0.20
            && cue.attentionHint != .person
            && cue.reaction != .engage
        guard strongNonHumanVerdict,
              cue.captureNS <= now,
              now - cue.captureNS <= 8_000_000_000,
              activeCognitiveMotorRequestID == nil,
              let targetID = cue.targetID,
              faceLock.sceneID == targetID,
              faceLock.permitsMotor(at: now) else {
            return
        }
        releaseWrongFixation(
            reason: "semantic_nonhuman_veto",
            at: now,
            priority: .l0
        )
        let detail = String(
            format: "scene_id=%@; cue_age_ms=%.0f; social_presence=%.2f; confidence=%.2f",
            targetID,
            Double(now - cue.captureNS) / 1_000_000,
            cue.socialPresence,
            cue.confidence
        )
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: now,
            source: "l0_auxiliary_release",
            state: "semantic_nonhuman_veto",
            message: detail
        ))
    }

    /// Time-bounded auto-release for a social fixation that never becomes
    /// engagement. A real conversation must never be torn away, so an active
    /// conversation resets the timer. Otherwise, holding the same face lock
    /// beyond `faceFixationReleaseWindowNS` releases it and resumes scanning
    /// while the detector keeps reporting the same false-positive face.
    private func applyFaceFixationAutoRelease(target: AttentionTarget?, at now: UInt64) {
        // Time-based release is opt-in via SOMA_L0_FIXATION_RELEASE_SECONDS.
        // When disabled (0) the robot keeps gazing until L0 observes departure.
        guard faceFixationReleaseWindowNS > 0 else {
            faceFixationSceneID = nil
            faceFixationStartNS = nil
            return
        }
        let conversationActive = liveVoicePresentation == .hearingUser
            || liveVoicePresentation == .responding
        if conversationActive {
            faceFixationSceneID = nil
            faceFixationStartNS = nil
            return
        }
        guard let target,
              target.isFaceMotorTarget,
              faceLock.permitsMotor(at: now) else {
            faceFixationSceneID = nil
            faceFixationStartNS = nil
            return
        }
        if faceFixationSceneID != target.id {
            faceFixationSceneID = target.id
            faceFixationStartNS = now
        }
        guard let start = faceFixationStartNS,
              now >= start + faceFixationReleaseWindowNS,
              now >= faceFixationCooldownUntilNS else { return }
        faceFixationSceneID = nil
        faceFixationStartNS = nil
        faceFixationCooldownUntilNS = now + faceFixationReleaseCooldownNS
        releaseWrongFixation(reason: "face_fixation_timeout", at: now, priority: .l1)
    }
    private func applySpatialFaceReacquisition(_ candidate: SceneCandidate, at monotonicNS: UInt64) {
        guard !hasRecentObservedFace(at: monotonicNS) else { return }
        if let activeSpatialFaceReacquisition {
            guard activeSpatialFaceReacquisition.id == candidate.id else { return }
            guard monotonicNS < activeSpatialFaceReacquisition.deadlineNS else {
                attemptedSpatialFaceReacquisitionIDs.insert(candidate.id)
                self.activeSpatialFaceReacquisition = nil
                return
            }
        } else {
            guard !attemptedSpatialFaceReacquisitionIDs.contains(candidate.id) else { return }
            activeSpatialFaceReacquisition = (candidate.id, monotonicNS + 1_000_000_000)
        }
        guard let calibration = externalCalibration,
              let bearing = candidate.bearing,
              let pose = poseStore.latest(at: monotonicNS),
              let motionGuide = GimbalVisibilityRoutePlanner.guide(
                to: bearing,
                from: pose,
                kinematicEnvelope: activeKinematicEnvelope,
                horizontalViewMarginDegrees: 18,
                verticalViewMarginDegrees: 12
              ) else {
            attemptedSpatialFaceReacquisitionIDs.insert(candidate.id)
            activeSpatialFaceReacquisition = nil
            return
        }
        let panError = spatialFaceReacquisitionSpeed(
            errorDegrees: motionGuide.azimuthDegrees - pose.panDegrees,
            maximumDegreesPerSecond: 72,
            fullScaleDegrees: 24
        )
        let pitchError = spatialFaceReacquisitionSpeed(
            errorDegrees: motionGuide.elevationDegrees - pose.pitchDegrees,
            maximumDegreesPerSecond: 30,
            fullScaleDegrees: 12
        )
        let pan = calibration.panCommand(
            forPoseError: panError,
            projection: externalPoseProjection
        )
        let pitch = calibration.pitchCommand(
            forPoseError: pitchError,
            projection: externalPoseProjection
        )
        guard pan != 0 || pitch != 0 else {
            attemptedSpatialFaceReacquisitionIDs.insert(candidate.id)
            activeSpatialFaceReacquisition = nil
            return
        }
        guard lastSpatialFaceReacquisitionCommandNS == 0
                || monotonicNS >= lastSpatialFaceReacquisitionCommandNS + 100_000_000 else {
            return
        }
        cancelScan()
        lastSpatialFaceReacquisitionCommandNS = monotonicNS
        sendExternalVelocity(
            pitch: pitch,
            pan: pan,
            state: "spatial_face_reacquisition_requested",
            target: nil,
            at: monotonicNS,
            hardStopAfterNS: 250_000_000
        )
    }

    private func spatialFaceReacquisitionSpeed(
        errorDegrees: Double,
        maximumDegreesPerSecond: Double,
        fullScaleDegrees: Double
    ) -> Double {
        let magnitude = abs(errorDegrees)
        guard magnitude > 1.5 else { return 0 }
        let normalized = min(1, (magnitude - 1.5) / max(fullScaleDegrees - 1.5, 0.1))
        let minimum = min(8, maximumDegreesPerSecond)
        let speed = minimum + (maximumDegreesPerSecond - minimum) * pow(normalized, 1.2)
        return errorDegrees < 0 ? -speed : speed
    }

    private func spatialSpeed(
        errorDegrees: Double,
        maximumDegreesPerSecond: Double,
        fullScaleDegrees: Double
    ) -> Double {
        let magnitude = abs(errorDegrees)
        guard magnitude > 1 else { return 0 }
        let normalized = min(1, (magnitude - 1) / max(fullScaleDegrees - 1, 0.1))
        let minimum = min(18, maximumDegreesPerSecond)
        let speed = minimum + (maximumDegreesPerSecond - minimum) * pow(normalized, 1.35)
        return errorDegrees < 0 ? -speed : speed
    }

    private func angularDifference(_ targetDegrees: Double, _ currentDegrees: Double) -> Double {
        var difference = (targetDegrees - currentDegrees).truncatingRemainder(dividingBy: 360)
        if difference > 180 { difference -= 360 }
        if difference <= -180 { difference += 360 }
        return difference
    }

    private func beginCalibration(with sample: CalibrationSample, at monotonicNS: UInt64) {
        cancelScan()
        calibrationHomePose = sample.pose
        sendCalibrationPanPulse(baseline: sample, pulseCount: 1, at: monotonicNS)
    }

    private func sendCalibrationPanPulse(
        baseline: CalibrationSample,
        pulseCount: Int,
        at monotonicNS: UInt64
    ) {
        calibrationStage = .panPulse(baseline: baseline, startedNS: monotonicNS)
        sendCalibrationVelocity(
            pitch: 0,
            pan: 18,
            state: "calibration_pan_pulse",
            target: nil,
            at: monotonicNS,
            afterStop: { [weak self] stoppedNS in
                self?.calibrationStage = .panSettling(
                    baseline: baseline,
                    pulseCount: pulseCount,
                    stoppedNS: stoppedNS
                )
            }
        )
    }

    private func sendCalibrationPitchPulse(
        panImageDelta: Double,
        panPoseDelta: Double,
        baseline: CalibrationSample,
        pulseCount: Int,
        at monotonicNS: UInt64
    ) {
        calibrationStage = .pitchPulse(
            panImageDelta: panImageDelta,
            panPoseDelta: panPoseDelta,
            baseline: baseline,
            startedNS: monotonicNS
        )
        sendCalibrationVelocity(
            pitch: 25,
            pan: 0,
            state: "calibration_pitch_pulse",
            target: nil,
            at: monotonicNS,
            afterStop: { [weak self] stoppedNS in
                self?.calibrationStage = .pitchSettling(
                    panImageDelta: panImageDelta,
                    panPoseDelta: panPoseDelta,
                    baseline: baseline,
                    pulseCount: pulseCount,
                    stoppedNS: stoppedNS
                )
            }
        )
    }

    private func advanceCalibration(
        with sample: CalibrationSample,
        at monotonicNS: UInt64
    ) {
        switch calibrationStage {
        case let .panSettling(baseline, pulseCount, stoppedNS):
            guard monotonicNS >= stoppedNS + 400_000_000 else { return }
            guard let displacement = opticalDisplacement(from: baseline, to: sample, at: monotonicNS) else {
                if monotonicNS >= stoppedNS + 2_000_000_000 {
                    failCalibration("optical_flow_pan_unavailable", at: monotonicNS)
                }
                return
            }
            let panImageDelta = displacement.x
            let panPoseDelta = sample.pose.panDegrees - baseline.pose.panDegrees
            guard abs(panImageDelta) >= 0.015 else {
                guard pulseCount < calibrationMaximumPulsesPerAxis else {
                    failCalibration("pan_response_below_optical_jitter", at: monotonicNS)
                    return
                }
                sendCalibrationPanPulse(
                    baseline: baseline,
                    pulseCount: pulseCount + 1,
                    at: monotonicNS
                )
                return
            }
            sendCalibrationPitchPulse(
                panImageDelta: panImageDelta,
                panPoseDelta: panPoseDelta,
                baseline: sample,
                pulseCount: 1,
                at: monotonicNS
            )
        case let .pitchSettling(panImageDelta, panPoseDelta, baseline, pulseCount, stoppedNS):
            guard monotonicNS >= stoppedNS + 400_000_000 else { return }
            guard let displacement = opticalDisplacement(from: baseline, to: sample, at: monotonicNS) else {
                if monotonicNS >= stoppedNS + 2_000_000_000 {
                    failCalibration("optical_flow_pitch_unavailable", at: monotonicNS)
                }
                return
            }
            let pitchImageDelta = displacement.y
            let pitchPoseDelta = sample.pose.pitchDegrees - baseline.pose.pitchDegrees
            guard abs(pitchImageDelta) >= 0.015 || pulseCount == calibrationMaximumPulsesPerAxis else {
                sendCalibrationPitchPulse(
                    panImageDelta: panImageDelta,
                    panPoseDelta: panPoseDelta,
                    baseline: baseline,
                    pulseCount: pulseCount + 1,
                    at: monotonicNS
                )
                return
            }
            guard let calibration = ExternalGimbalCalibration.fromPositivePulseDisplacements(
                panImageDelta: panImageDelta,
                pitchImageDelta: pitchImageDelta,
                maximumPanDegreesPerSecond: deviceCapabilities?.maximumPanDegreesPerSecond ?? 180,
                maximumPitchDegreesPerSecond: deviceCapabilities?.maximumPitchDegreesPerSecond ?? 90,
                deviceIdentifier: deviceContract?.profileID,
                deviceProfile: deviceProfile,
                panPoseDelta: panPoseDelta,
                pitchPoseDelta: pitchPoseDelta,
                homePose: calibrationHomePose
            ) else {
                failCalibration("pitch_response_below_detector_jitter", at: monotonicNS)
                return
            }
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(calibration).write(to: calibrationOutputURL!, options: .atomic)
                calibrationStage = .completed
                calibrationMode = false
                if let deviceProfile, let deviceCapabilities {
                    poseStore.configureDeviceProfile(
                        deviceProfile,
                        capabilities: deviceCapabilities,
                        deviceIdentifier: deviceContract?.profileID,
                        calibration: calibration
                    )
                }
                externalGate = ExternalGimbalAttentionGate(calibration: calibration, autonomousScanEnabled: true)
                idleExplorationGate = nil
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: monotonicNS,
                    source: "external_gimbal_calibration",
                    state: "completed",
                    message: String(
                        format: "tracker=lucas_kanade; pan_image_delta=%.4f; pitch_image_delta=%.4f; pan_pose_delta=%.3f; pitch_pose_delta=%.3f",
                        panImageDelta,
                        pitchImageDelta,
                        panPoseDelta,
                        pitchPoseDelta
                    )
                ))
            } catch {
                failCalibration("write_failed", at: monotonicNS)
            }
        default:
            return
        }
    }

    private func calibrationSample(
        from pixelBuffer: CVPixelBuffer,
        captureNS: UInt64
    ) -> CalibrationSample? {
        guard let pose = poseStore.latestRaw(at: captureNS, maximumAgeNS: 150_000_000) else {
            return nil
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width >= 32, height >= 32, bytesPerRow >= width * 4 else { return nil }
        return CalibrationSample(
            bgra: Data(bytes: baseAddress, count: bytesPerRow * height),
            bytesPerRow: bytesPerRow,
            width: width,
            height: height,
            captureNS: captureNS,
            pose: pose
        )
    }

    private func applyCalibrationFrame(
        _ sample: CalibrationSample,
        at monotonicNS: UInt64
    ) {
        guard calibrationMode, process.isRunning, helperReady else { return }
        switch calibrationStage {
        case .awaitingTarget:
            beginCalibration(with: sample, at: monotonicNS)
        case .panPulse, .pitchPulse, .completed, .failed:
            return
        case .panSettling, .pitchSettling:
            advanceCalibration(with: sample, at: monotonicNS)
        }
    }

    private func opticalDisplacement(
        from baseline: CalibrationSample,
        to current: CalibrationSample,
        at monotonicNS: UInt64
    ) -> (x: Double, y: Double)? {
        guard baseline.width == current.width,
              baseline.height == current.height,
              baseline.bytesPerRow == current.bytesPerRow else {
            return nil
        }
        let result = baseline.bgra.withUnsafeBytes { baselineBytes in
            current.bgra.withUnsafeBytes { currentBytes in
                soma_lucas_kanade_translation_bgra(
                    baselineBytes.bindMemory(to: UInt8.self).baseAddress,
                    Int32(baseline.bytesPerRow),
                    currentBytes.bindMemory(to: UInt8.self).baseAddress,
                    Int32(current.bytesPerRow),
                    Int32(baseline.width),
                    Int32(baseline.height)
                )
            }
        }
        guard result.success != 0,
              result.tracked_points >= 12,
              result.confidence >= 0.55 else {
            if lastCalibrationOpticalDiagnosticNS == 0
                || monotonicNS >= lastCalibrationOpticalDiagnosticNS + 500_000_000 {
                lastCalibrationOpticalDiagnosticNS = monotonicNS
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: monotonicNS,
                    source: "external_gimbal_calibration",
                    state: "optical_flow_rejected",
                    message: String(
                        format: "success=%d; tracked_points=%d; confidence=%.3f; translation_x=%.2f; translation_y=%.2f; elapsed_ms=%.2f",
                        result.success,
                        result.tracked_points,
                        result.confidence,
                        result.translation_x,
                        result.translation_y,
                        result.elapsed_milliseconds
                    )
                ))
            }
            return nil
        }
        return (
            Double(result.translation_x) / Double(baseline.width),
            Double(result.translation_y) / Double(baseline.height)
        )
    }

    private func applyEmbodimentIntent(_ intent: EmbodimentMotorIntent) {
        let now = monotonicNanoseconds()
        if !allowsMotorControl {
            switch intent {
            case .captureCurrent, .suspend, .release:
                break
            default:
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: now,
                    source: "embodiment_motor",
                    state: "calibration_required",
                    message: "profile=\(deviceProfile?.rawValue ?? "unknown"); motion_request_rejected"
                ))
                return
            }
        }
        switch intent {
        case let .orient(requestID, bearing, tolerance, style, expiresAtNS, reason):
            claimCognitiveMotor(requestID: requestID, expiresAtNS: expiresAtNS, at: now)
            cognitiveMotionMode = .waypoint(
                bearing: bearing,
                toleranceDegrees: tolerance,
                motionStyle: style,
                state: "cognitive_\(reason)"
            )
            cognitiveMotionHolding = false
            startCognitiveMotionLoop()
        case let .track(requestID, reference, sceneID, bearing, observed, framing, style, expiresAtNS):
            claimCognitiveMotor(requestID: requestID, expiresAtNS: expiresAtNS, at: now)
            let targetBearing = framing.flatMap {
                poseStore.projection(at: now).cameraProjectionModel.cameraBearing(
                    placing: bearing,
                    at: $0,
                    poseProjection: externalPoseProjection
                )
            } ?? bearing
            cognitiveMotionMode = .waypoint(
                bearing: targetBearing,
                toleranceDegrees: observed ? 2.0 : 4.0,
                motionStyle: style,
                state: "cognitive_track_\(String(reference.prefix(32)))_\(String(sceneID.prefix(32)))"
            )
            cognitiveMotionHolding = false
            startCognitiveMotionLoop()
        case let .capture(requestID, reference, sceneID, bearing, fieldOfView, expiresAtNS):
            claimCognitiveMotor(requestID: requestID, expiresAtNS: expiresAtNS, at: now)
            embodimentViewCaptureStore?.prepare(
                requestID: requestID,
                targetReference: reference,
                sceneID: sceneID,
                bearing: bearing,
                fieldOfViewDegrees: fieldOfView,
                leaseExpiresAtNS: expiresAtNS,
                at: now
            )
            cognitiveMotionMode = .capture(
                requestID: requestID,
                bearing: bearing,
                fieldOfViewDegrees: fieldOfView,
                stableSinceNS: nil,
                lastPositionCommandNS: nil
            )
            cognitiveMotionHolding = false
            startCognitiveMotionLoop()
        case let .captureCurrent(requestID, fieldOfView, expiresAtNS):
            embodimentViewCaptureStore?.prepareCurrent(
                requestID: requestID,
                fieldOfViewDegrees: fieldOfView,
                leaseExpiresAtNS: expiresAtNS,
                cameraPose: poseStore.current(maximumAgeNS: 600_000_000) ?? poseStore.lastKnown(),
                at: now
            )
        case let .opticalZoom(requestID, factor):
            guard helperReady else {
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: now,
                    source: "obsbot_camera_optics",
                    state: "helper_unavailable",
                    message: "request_id=\(String(requestID.prefix(96)))"
                ))
                return
            }
            send(String(format: "camera_zoom %@ %.4f", requestID, factor))
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: now,
                source: "obsbot_camera_optics",
                state: "optical_zoom_requested",
                message: String(format: "request_id=%@; requested_factor=%.3f", String(requestID.prefix(96)), factor)
            ))
        case let .audioCaptureMode(requestID, mode):
            guard let firmwareMode = deviceContract?.firmwareAudioMode(for: mode) else {
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: now,
                    source: "obsbot_audio_frontend",
                    state: "capture_mode_unsupported",
                    message: "request_id=\(String(requestID.prefix(96))); mode=\(mode.rawValue)"
                ))
                return
            }
            guard !rejectedFirmwareAudioModes.contains(Int(firmwareMode)) else {
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: now,
                    source: "obsbot_audio_frontend",
                    state: "capture_mode_unavailable_on_device",
                    message: "request_id=\(String(requestID.prefix(96))); mode=\(mode.rawValue); firmware_mode=\(firmwareMode)"
                ))
                return
            }
            guard helperReady else {
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: now,
                    source: "obsbot_audio_frontend",
                    state: "helper_unavailable",
                    message: "request_id=\(String(requestID.prefix(96))); mode=\(mode.rawValue)"
                ))
                return
            }
            send("audio_mode \(requestID) \(firmwareMode)")
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: now,
                source: "obsbot_audio_frontend",
                state: "capture_mode_requested",
                message: "request_id=\(String(requestID.prefix(96))); mode=\(mode.rawValue); firmware_mode=\(firmwareMode)"
            ))
        case let .audioInputGain(requestID, percent):
            guard helperReady else {
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: now,
                    source: "obsbot_audio_frontend",
                    state: "helper_unavailable",
                    message: "request_id=\(String(requestID.prefix(96))); input_gain_percent=\(percent)"
                ))
                return
            }
            send("audio_input_gain \(requestID) \(percent)")
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: now,
                source: "obsbot_audio_frontend",
                state: "input_gain_requested",
                message: "request_id=\(String(requestID.prefix(96))); input_gain_percent=\(percent)"
            ))
        case let .cameraWhiteBalance(requestID, mode, temperatureKelvin):
            guard helperReady else {
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: now,
                    source: "obsbot_camera_imaging",
                    state: "helper_unavailable",
                    message: "request_id=\(String(requestID.prefix(96))); mode=\(mode.rawValue)"
                ))
                return
            }
            switch mode {
            case .auto:
                send("camera_white_balance \(requestID) auto")
            case .manual:
                guard let temperatureKelvin else {
                    writer.write(RuntimeEvent(
                        event: "source.health",
                        monotonicNS: now,
                        source: "obsbot_camera_imaging",
                        state: "white_balance_invalid",
                        message: "request_id=\(String(requestID.prefix(96))); manual_temperature_missing"
                    ))
                    return
                }
                send("camera_white_balance \(requestID) manual \(temperatureKelvin)")
            }
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: now,
                source: "obsbot_camera_imaging",
                state: "white_balance_requested",
                message: "request_id=\(String(requestID.prefix(96))); mode=\(mode.rawValue); temperature_kelvin=\(temperatureKelvin.map(String.init) ?? "automatic")"
            ))
        case let .cameraExposureLock(requestID, locked):
            guard helperReady else {
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: now,
                    source: "obsbot_camera_imaging",
                    state: "helper_unavailable",
                    message: "request_id=\(String(requestID.prefix(96))); exposure_lock=\(locked)"
                ))
                return
            }
            send("camera_ae_lock \(requestID) \(locked ? 1 : 0)")
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: now,
                source: "obsbot_camera_imaging",
                state: "exposure_lock_requested",
                message: "request_id=\(String(requestID.prefix(96))); locked=\(locked)"
            ))
        case let .cameraFocus(requestID, mode, position):
            guard helperReady else {
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: now,
                    source: "obsbot_camera_imaging",
                    state: "helper_unavailable",
                    message: "request_id=\(String(requestID.prefix(96))); focus_mode=\(mode.rawValue)"
                ))
                return
            }
            switch mode {
            case .auto:
                send("camera_focus \(requestID) auto")
            case .manual:
                guard let position else {
                    writer.write(RuntimeEvent(
                        event: "source.health",
                        monotonicNS: now,
                        source: "obsbot_camera_imaging",
                        state: "focus_invalid",
                        message: "request_id=\(String(requestID.prefix(96))); manual_position_missing"
                    ))
                    return
                }
                send("camera_focus \(requestID) manual \(position)")
            }
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: now,
                source: "obsbot_camera_imaging",
                state: "focus_requested",
                message: "request_id=\(String(requestID.prefix(96))); mode=\(mode.rawValue); position=\(position.map(String.init) ?? "automatic")"
            ))
        case let .cameraAbsoluteExposure(requestID, mode, shutterCode):
            guard helperReady else {
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: now,
                    source: "obsbot_camera_imaging",
                    state: "helper_unavailable",
                    message: "request_id=\(String(requestID.prefix(96))); exposure_mode=\(mode.rawValue)"
                ))
                return
            }
            switch mode {
            case .auto:
                send("camera_absolute_exposure \(requestID) auto")
            case .manual:
                guard let shutterCode else {
                    writer.write(RuntimeEvent(
                        event: "source.health",
                        monotonicNS: now,
                        source: "obsbot_camera_imaging",
                        state: "absolute_exposure_invalid",
                        message: "request_id=\(String(requestID.prefix(96))); manual_shutter_code_missing"
                    ))
                    return
                }
                send("camera_absolute_exposure \(requestID) manual \(shutterCode)")
            }
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: now,
                source: "obsbot_camera_imaging",
                state: "absolute_exposure_requested",
                message: "request_id=\(String(requestID.prefix(96))); mode=\(mode.rawValue); shutter_code=\(shutterCode.map(String.init) ?? "automatic")"
            ))
        case let .cameraFacePriority(requestID, enabled):
            guard helperReady else {
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: now,
                    source: "obsbot_camera_imaging",
                    state: "helper_unavailable",
                    message: "request_id=\(String(requestID.prefix(96))); face_priority=\(enabled)"
                ))
                return
            }
            send("camera_face_priority \(requestID) \(enabled ? 1 : 0)")
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: now,
                source: "obsbot_camera_imaging",
                state: "face_priority_requested",
                message: "request_id=\(String(requestID.prefix(96))); enabled=\(enabled)"
            ))
        case let .cameraAntiFlicker(requestID, mode):
            guard helperReady else {
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: now,
                    source: "obsbot_camera_imaging",
                    state: "helper_unavailable",
                    message: "request_id=\(String(requestID.prefix(96))); anti_flicker=\(mode.rawValue)"
                ))
                return
            }
            let firmwareMode: Int
            switch mode {
            case .off: firmwareMode = 0
            case .hz50: firmwareMode = 1
            case .hz60: firmwareMode = 2
            case .auto: firmwareMode = 3
            }
            send("camera_anti_flicker \(requestID) \(firmwareMode)")
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: now,
                source: "obsbot_camera_imaging",
                state: "anti_flicker_requested",
                message: "request_id=\(String(requestID.prefix(96))); mode=\(mode.rawValue)"
            ))
        case let .cameraImageTuning(requestID, goal):
            guard helperReady else {
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: now,
                    source: "obsbot_camera_imaging",
                    state: "helper_unavailable",
                    message: "request_id=\(String(requestID.prefix(96))); image_tuning_requested"
                ))
                return
            }
            let value: (Int?) -> String = { $0.map(String.init) ?? "keep" }
            send("camera_image_tuning \(requestID) \(value(goal.brightness)) \(value(goal.contrast)) \(value(goal.hue)) \(value(goal.saturation)) \(value(goal.sharpness))")
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: now,
                source: "obsbot_camera_imaging",
                state: "image_tuning_requested",
                message: "request_id=\(String(requestID.prefix(96))); brightness=\(value(goal.brightness)); contrast=\(value(goal.contrast)); hue=\(value(goal.hue)); saturation=\(value(goal.saturation)); sharpness=\(value(goal.sharpness))"
            ))
        case let .nativeHumanTrackingPolicy(requestID, speed, motionTracking, foreTarget, adaptiveComposition, adaptivePanGain, adaptivePitchGain, panGain, pitchGain):
            guard helperReady else {
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: now,
                    source: "obsbot_native_human_tracking",
                    state: "helper_unavailable",
                    message: "request_id=\(String(requestID.prefix(96))); speed=\(speed.rawValue)"
                ))
                return
            }
            let firmwareSpeed: Int
            switch speed {
            case .superLazy: firmwareSpeed = 0
            case .lazy: firmwareSpeed = 1
            case .slow: firmwareSpeed = 2
            case .fast: firmwareSpeed = 3
            case .crazy: firmwareSpeed = 4
            }
            let gainToken: (Double?) -> String = { value in
                value.map { String(format: "%.3f", $0) } ?? "keep"
            }
            send("native_tracking_policy \(requestID) \(firmwareSpeed) \(motionTracking ? 1 : 0) \(foreTarget ? 1 : 0) \(adaptiveComposition ? 1 : 0) \(adaptivePanGain ? 1 : 0) \(adaptivePitchGain ? 1 : 0) \(gainToken(panGain)) \(gainToken(pitchGain))")
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: now,
                source: "obsbot_native_human_tracking",
                state: "policy_requested",
                message: "request_id=\(String(requestID.prefix(96))); speed=\(speed.rawValue); motion=\(motionTracking); fore_target=\(foreTarget); adaptive_composition=\(adaptiveComposition); adaptive_pan_gain=\(adaptivePanGain); adaptive_pitch_gain=\(adaptivePitchGain); pan_gain=\(gainToken(panGain)); pitch_gain=\(gainToken(pitchGain))"
            ))
        case let .cameraFieldOfView(requestID, degrees):
            guard helperReady else {
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: now,
                    source: "obsbot_camera_optics",
                    state: "helper_unavailable",
                    message: "request_id=\(String(requestID.prefix(96))); field_of_view_degrees=\(degrees)"
                ))
                return
            }
            send("camera_fov \(requestID) \(degrees)")
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: now,
                source: "obsbot_camera_optics",
                state: "field_of_view_requested",
                message: "request_id=\(String(requestID.prefix(96))); field_of_view_degrees=\(degrees)"
            ))
        case let .explore(requestID, policy, expiresAtNS):
            claimCognitiveMotor(requestID: requestID, expiresAtNS: expiresAtNS, at: now)
            cognitiveMotionMode = .exploration(policy: policy)
            cognitiveExplorationWaypoint = nil
            cognitiveExplorationWaypointStartedNS = nil
            cognitiveMotionHolding = false
            startCognitiveMotionLoop()
        case let .express(requestID, expression, expiresAtNS):
            claimCognitiveMotor(requestID: requestID, expiresAtNS: expiresAtNS, at: now)
            cognitiveMotionMode = .expression(
                kind: expression,
                basePose: nil,
                waypointIndex: 0,
                waypointStartedNS: nil
            )
            cognitiveMotionHolding = false
            startCognitiveMotionLoop()
        case let .suspend(requestID, reason, expiresAtNS):
            claimCognitiveMotor(requestID: requestID, expiresAtNS: expiresAtNS, at: now)
            if reason.hasPrefix("capture_") {
                embodimentViewCaptureStore?.fail(
                    requestID: requestID,
                    reason: reason,
                    leaseExpiresAtNS: expiresAtNS,
                    at: now
                )
            }
            cognitiveMotionMode = .suspended(reason: reason)
            stopCognitiveMotion(state: "cognitive_\(reason)", at: now, retainLease: true)
        case let .release(requestID, reason):
            guard requestID == nil || activeCognitiveMotorRequestID == requestID else { return }
            releaseCognitiveMotor(state: "cognitive_\(reason)", at: now)
        }
    }

    /// A social expression is an optional overlay. It must never carry the
    /// camera away from a face that the independent visual pipeline has just
    /// confirmed in the current frame.
    private func preemptCognitiveExpressionForVerifiedFace(at monotonicNS: UInt64) {
        guard activeCognitiveMotorRequestID != nil,
              case .expression = cognitiveMotionMode else {
            return
        }
        releaseCognitiveMotor(
            state: "verified_face_preempted_expression",
            at: monotonicNS
        )
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: monotonicNS,
            source: "embodiment_motor",
            state: "expression_preempted_by_verified_face",
            message: "current frame has independently verified face evidence"
        ))
    }

    private func claimCognitiveMotor(requestID: String, expiresAtNS: UInt64, at monotonicNS: UInt64) {
        let changesOwner = activeCognitiveMotorRequestID != requestID
        let previousRequestID = activeCognitiveMotorRequestID
        if changesOwner {
            stopAuditoryOrienting(
                state: "cognitive_motor_preempted",
                at: monotonicNS,
                resumeExploration: false
            )
        }
        activeCognitiveMotorRequestID = requestID
        activeCognitiveMotorExpiresAtNS = expiresAtNS
        visualEvidenceGeneration += 1
        scanScheduledForEvidenceGeneration = nil
        activeSpatialFaceReacquisition = nil
        cancelScan()
        if changesOwner {
            if let previousRequestID {
                embodimentViewCaptureStore?.cancel(
                    requestID: previousRequestID,
                    reason: "capture_preempted",
                    at: monotonicNS
                )
            }
            cognitiveMotionGeneration += 1
            cognitiveMotionLoopRunning = false
            cognitiveDynamics.reset()
            cognitiveExplorationWaypoint = nil
            cognitiveExplorationWaypointStartedNS = nil
            let nativeAction = gate.invalidate()
            apply(nativeAction, at: monotonicNS, target: nil, reason: "cognitive_motor_preemption")
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNS,
                source: "embodiment_motor",
                state: "lease_acquired",
                message: "request_id=\(String(requestID.prefix(96)))"
            ))
        }
        reconcileFirmwareSoundFollowing(at: monotonicNS, reason: "cognitive_motor_acquired")
    }

    private func startCognitiveMotionLoop() {
        guard !cognitiveMotionLoopRunning else { return }
        cognitiveMotionLoopRunning = true
        cognitiveMotionGeneration += 1
        scheduleCognitiveMotionTick(generation: cognitiveMotionGeneration)
    }

    private func scheduleCognitiveMotionTick(generation: Int, afterMilliseconds: Int = 0) {
        queue.asyncAfter(deadline: .now() + .milliseconds(afterMilliseconds)) { [weak self] in
            self?.runCognitiveMotionTick(generation: generation)
        }
    }

    private func runCognitiveMotionTick(generation: Int) {
        guard generation == cognitiveMotionGeneration,
              cognitiveMotionLoopRunning,
              let requestID = activeCognitiveMotorRequestID,
              let expiresAtNS = activeCognitiveMotorExpiresAtNS else { return }
        let now = monotonicNanoseconds()
        guard now < expiresAtNS else {
            releaseCognitiveMotor(state: "cognitive_lease_expired", at: now)
            return
        }
        guard process.isRunning, helperReady, let calibration = externalCalibration else {
            if !cognitiveMotionHolding {
                cognitiveMotionHolding = true
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: now,
                    source: "embodiment_motor",
                    state: "actuator_unavailable",
                    message: "request_id=\(String(requestID.prefix(96)))"
                ))
            }
            scheduleCognitiveMotionTick(generation: generation, afterMilliseconds: 100)
            return
        }
        // Bounded gaze expressions complete on a fixed timer, so they may use
        // the last known pose even if the attitude sample is stale (e.g. during
        // a firmware tracking transaction). Other modes need a fresh pose to
        // avoid driving on outdated geometry.
        let pose: GimbalPose?
        if case .expression = cognitiveMotionMode {
            pose = poseStore.lastKnown()
        } else {
            // 600ms window: the native attitude reporter emits at ~70-90ms
            // cadence with occasional gaps during firmware mode switches.
            pose = poseStore.current(maximumAgeNS: 600_000_000)
        }
        guard let pose else {
            if !cognitiveMotionHolding {
                stopCognitiveMotion(state: "cognitive_pose_wait", at: now, retainLease: true)
                cognitiveMotionLoopRunning = true
            }
            scheduleCognitiveMotionTick(
                generation: cognitiveMotionGeneration,
                afterMilliseconds: 50
            )
            return
        }

        switch cognitiveMotionMode {
        case let .waypoint(bearing, tolerance, style, state):
            driveCognitiveWaypoint(
                bearing,
                toleranceDegrees: tolerance,
                motionStyle: style,
                state: state,
                calibration: calibration,
                pose: pose,
                at: now
            )
        case let .capture(requestID, bearing, fieldOfView, stableSinceNS, lastPositionCommandNS):
            driveCognitiveCapture(
                requestID: requestID,
                bearing: bearing,
                fieldOfViewDegrees: fieldOfView,
                stableSinceNS: stableSinceNS,
                lastPositionCommandNS: lastPositionCommandNS,
                pose: pose,
                at: now
            )
        case let .exploration(policy):
            driveCognitiveExploration(
                policy: policy,
                calibration: calibration,
                pose: pose,
                at: now
            )
        case let .expression(kind, basePose, waypointIndex, waypointStartedNS):
            driveCognitiveExpression(
                kind: kind,
                basePose: basePose,
                waypointIndex: waypointIndex,
                waypointStartedNS: waypointStartedNS,
                calibration: calibration,
                pose: pose,
                at: now
            )
        case let .suspended(reason):
            if !cognitiveMotionHolding {
                stopCognitiveMotion(state: "cognitive_\(reason)", at: now, retainLease: true)
            }
        case .none:
            break
        }
        if cognitiveMotionLoopRunning {
            scheduleCognitiveMotionTick(
                generation: cognitiveMotionGeneration,
                afterMilliseconds: 50
            )
        }
    }

    private func driveCognitiveWaypoint(
        _ target: GimbalRelativeBearing,
        toleranceDegrees: Double,
        motionStyle: EmbodimentMotionStyle,
        accelerationMultiplier: Double = 1,
        state: String,
        calibration: ExternalGimbalCalibration,
        pose: GimbalPose,
        at monotonicNS: UInt64
    ) {
        guard let guide = GimbalVisibilityRoutePlanner.guide(
            to: target,
            from: pose,
            kinematicEnvelope: activeKinematicEnvelope,
            observationPreference: .centered
        ) else {
            stopCognitiveMotion(state: "cognitive_route_unreachable", at: monotonicNS, retainLease: true)
            return
        }
        let panError = guide.azimuthDegrees - pose.panDegrees
        let pitchError = guide.elevationDegrees - pose.pitchDegrees
        guard hypot(panError, pitchError) > toleranceDegrees else {
            if !cognitiveMotionHolding {
                stopCognitiveMotion(state: "\(state)_holding", at: monotonicNS, retainLease: true)
            }
            return
        }
        cognitiveMotionHolding = false
        let profile = cognitiveMotionProfile(for: motionStyle)
        let desiredPan = SmoothExplorationDynamics.stoppingVelocity(
            errorDegrees: panError,
            maximumDegreesPerSecond: min(profile.panSpeed, calibration.maximumPanDegreesPerSecond),
            accelerationDegreesPerSecondSquared: profile.panAcceleration,
            deadbandDegrees: toleranceDegrees
        )
        let desiredPitch = SmoothExplorationDynamics.stoppingVelocity(
            errorDegrees: pitchError,
            maximumDegreesPerSecond: min(profile.pitchSpeed, calibration.maximumPitchDegreesPerSecond),
            accelerationDegreesPerSecondSquared: profile.pitchAcceleration,
            deadbandDegrees: toleranceDegrees
        )
        let velocity = cognitiveDynamics.advance(
            towardPitch: calibration.pitchCommand(
                forPoseError: desiredPitch,
                projection: externalPoseProjection
            ),
            pan: calibration.panCommand(
                forPoseError: desiredPan,
                projection: externalPoseProjection
            ),
            at: monotonicNS,
            maximumPitchAcceleration: profile.pitchAcceleration * accelerationMultiplier,
            maximumPanAcceleration: profile.panAcceleration * accelerationMultiplier
        )
        sendExternalVelocity(
            pitch: velocity.pitchDegreesPerSecond,
            pan: velocity.panDegreesPerSecond,
            state: state,
            target: nil,
            at: monotonicNS,
            hardStopAfterNS: 250_000_000
        )
    }

    private func driveCognitiveCapture(
        requestID: String,
        bearing: GimbalRelativeBearing,
        fieldOfViewDegrees: Double,
        stableSinceNS: UInt64?,
        lastPositionCommandNS: UInt64?,
        pose: GimbalPose,
        at monotonicNS: UInt64
    ) {
        guard let guide = GimbalVisibilityRoutePlanner.guide(
            to: bearing,
            from: pose,
            kinematicEnvelope: activeKinematicEnvelope,
            observationPreference: .centered
        ) else {
            embodimentViewCaptureStore?.cancel(
                requestID: requestID,
                reason: "capture_route_unreachable",
                at: monotonicNS
            )
            stopCognitiveMotion(
                state: "cognitive_capture_route_unreachable",
                at: monotonicNS,
                retainLease: true
            )
            return
        }
        let error = hypot(
            guide.azimuthDegrees - pose.panDegrees,
            guide.elevationDegrees - pose.pitchDegrees
        )
        let alignment = CaptureAlignmentHysteresis.evaluate(
            errorDegrees: error,
            stableSinceNS: stableSinceNS,
            at: monotonicNS
        )
        switch alignment.phase {
        case .capture:
            stopCognitiveMotion(
                state: "cognitive_capture_aligned",
                at: monotonicNS,
                retainLease: true
            )
            embodimentViewCaptureStore?.markAligned(
                requestID: requestID,
                cameraPose: pose,
                at: monotonicNS
            )
        case .drive:
            let shouldRefreshPosition = lastPositionCommandNS.map {
                monotonicNS >= $0 + 250_000_000
            } ?? true
            if shouldRefreshPosition {
                sendExternalPosition(
                    pitch: guide.elevationDegrees,
                    pan: guide.azimuthDegrees,
                    state: "cognitive_capture_position",
                    target: nil,
                    at: monotonicNS,
                    hardStopAfterNS: nil
                )
            }
            cognitiveMotionMode = .capture(
                requestID: requestID,
                bearing: bearing,
                fieldOfViewDegrees: fieldOfViewDegrees,
                stableSinceNS: nil,
                lastPositionCommandNS: shouldRefreshPosition
                    ? monotonicNS
                    : lastPositionCommandNS
            )
        case .beginSettling:
            stopCognitiveMotion(
                state: "cognitive_capture_settling",
                at: monotonicNS,
                retainLease: true
            )
            cognitiveMotionMode = .capture(
                requestID: requestID,
                bearing: bearing,
                fieldOfViewDegrees: fieldOfViewDegrees,
                stableSinceNS: alignment.stableSinceNS,
                lastPositionCommandNS: lastPositionCommandNS
            )
            cognitiveMotionLoopRunning = true
        case .awaitSettling:
            break
        }
    }

    private func driveCognitiveExploration(
        policy: ExplorationPolicyGoal,
        calibration: ExternalGimbalCalibration,
        pose: GimbalPose,
        at monotonicNS: UInt64
    ) {
        if let waypoint = cognitiveExplorationWaypoint,
           let startedNS = cognitiveExplorationWaypointStartedNS {
            let distance = hypot(
                waypoint.bearing.azimuthDegrees - pose.panDegrees,
                waypoint.bearing.elevationDegrees - pose.pitchDegrees
            )
            let blendRadius = 3 + 9 * policy.motionContinuity
            let dwellElapsed = monotonicNS >= startedNS + policy.dwellMilliseconds * 1_000_000
            if distance <= blendRadius && (policy.motionContinuity >= 0.60 || dwellElapsed) {
                spatialAtlas.recordUnproductiveVisit(to: waypoint, at: monotonicNS)
                cognitiveExplorationWaypoint = nil
                cognitiveExplorationWaypointStartedNS = nil
            }
        }
        if cognitiveExplorationWaypoint == nil {
            let atlas = spatialAtlas.snapshot(at: monotonicNS)
            guard let sampled = CognitiveExplorationPlanner.sample(
                cells: atlas.cells,
                policy: policy,
                from: pose,
                kinematicEnvelope: atlas.kinematicEnvelope,
                uniform: nextExplorationUniform()
            ),
            let guide = GimbalVisibilityRoutePlanner.guide(
                to: sampled.bearing,
                from: pose,
                kinematicEnvelope: atlas.kinematicEnvelope,
                observationPreference: .centered
            ) else {
                stopCognitiveMotion(state: "cognitive_exploration_no_route", at: monotonicNS, retainLease: true)
                cognitiveMotionLoopRunning = true
                return
            }
            cognitiveExplorationWaypoint = SpatialCoverageDirection(
                bearing: guide,
                probability: sampled.probability,
                panoramaQuality: sampled.panoramaQuality,
                placeFamiliarity: sampled.placeFamiliarity,
                expectedInformationGain: sampled.expectedInformationGain
            )
            cognitiveExplorationWaypointStartedNS = monotonicNS
            spatialAtlas.recordExplorationCommit(to: sampled, at: monotonicNS)
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNS,
                source: "embodiment_motor",
                state: "cognitive_exploration_direction_sampled",
                message: String(
                    format: "mode=%@; probability=%.4f; azimuth_degrees=%.2f; elevation_degrees=%.2f",
                    policy.mode.rawValue,
                    sampled.probability,
                    sampled.bearing.azimuthDegrees,
                    sampled.bearing.elevationDegrees
                )
            ))
        }
        guard let waypoint = cognitiveExplorationWaypoint else { return }
        let tempoScale = 0.45 + 0.55 * policy.tempo
        let style: EmbodimentMotionStyle = policy.motionContinuity >= 0.65 ? .smooth : .curious
        let profile = cognitiveMotionProfile(for: style)
        let adjustedProfile = (
            panSpeed: profile.panSpeed * tempoScale,
            pitchSpeed: profile.pitchSpeed * tempoScale,
            panAcceleration: profile.panAcceleration,
            pitchAcceleration: profile.pitchAcceleration
        )
        driveCognitiveWaypoint(
            waypoint.bearing,
            toleranceDegrees: max(1.5, 5 * (1 - policy.motionContinuity)),
            motionStyle: style,
            state: "cognitive_exploration_\(policy.mode.rawValue)",
            calibration: ExternalGimbalCalibration(
                panSign: calibration.panSign,
                pitchSign: calibration.pitchSign,
                maximumPanDegreesPerSecond: min(calibration.maximumPanDegreesPerSecond, adjustedProfile.panSpeed),
                maximumPitchDegreesPerSecond: min(calibration.maximumPitchDegreesPerSecond, adjustedProfile.pitchSpeed)
            ),
            pose: pose,
            at: monotonicNS
        )
        // Exploration owns the lease for its full duration. A requested dwell
        // pauses physical output but keeps this low-rate planner alive so the
        // next waypoint can blend in without a new MCP request.
        cognitiveMotionLoopRunning = true
    }

    private func driveCognitiveExpression(
        kind: SocialGimbalExpression,
        basePose: GimbalPose?,
        waypointIndex: Int,
        waypointStartedNS: UInt64?,
        calibration: ExternalGimbalCalibration,
        pose: GimbalPose,
        at monotonicNS: UInt64
    ) {
        let base = basePose ?? pose
        let offsets = cognitiveExpressionOffsets(kind, currentPan: base.panDegrees)
        guard waypointIndex < offsets.count else {
            // An expression is a bounded overlay. Holding its lease after the
            // return waypoint would suppress face fixation until timeout.
            releaseCognitiveMotor(state: "cognitive_expression_completed", at: monotonicNS)
            return
        }
        let offset = offsets[waypointIndex]
        let target = GimbalRelativeBearing(
            azimuthDegrees: base.panDegrees + offset.pan,
            elevationDegrees: base.pitchDegrees + offset.pitch
        )
        let distance = hypot(target.azimuthDegrees - pose.panDegrees, target.elevationDegrees - pose.pitchDegrees)
        let startedNS = waypointStartedNS ?? monotonicNS
        let minimumWaypointNS: UInt64 = 120_000_000
        let arrivalToleranceDegrees = 1.8
        // Advance on arrival OR on a time fallback. Some gimbal transports do not
        // reflect commanded movement in the attitude feedback, so the pose
        // distance never converges; without this fallback the expression would
        // hold until the lease expires and never report completion.
        let waypointTimeoutNS: UInt64 = 400_000_000
        if distance <= arrivalToleranceDegrees {
            // Waypoint reached. Advance once the minimum dwell time has elapsed;
            // otherwise hold (keep the loop running) WITHOUT re-driving the
            // waypoint. Re-driving would hit the "_holding" branch in
            // driveCognitiveWaypoint, which stops the motion loop and stalls the
            // expression before it can advance to the next waypoint.
            let dwellElapsed = monotonicNS >= startedNS + minimumWaypointNS
            cognitiveMotionMode = .expression(
                kind: kind,
                basePose: base,
                waypointIndex: dwellElapsed ? waypointIndex + 1 : waypointIndex,
                waypointStartedNS: dwellElapsed ? monotonicNS : startedNS
            )
            return
        }
        if monotonicNS >= startedNS + waypointTimeoutNS {
            // Time fallback: advance even if the pose never converged.
            cognitiveMotionMode = .expression(
                kind: kind,
                basePose: base,
                waypointIndex: waypointIndex + 1,
                waypointStartedNS: monotonicNS
            )
            return
        }
        cognitiveMotionMode = .expression(
            kind: kind,
            basePose: base,
            waypointIndex: waypointIndex,
            waypointStartedNS: startedNS
        )
        driveCognitiveWaypoint(
            target,
            toleranceDegrees: 1.2,
            motionStyle: .attentive,
            accelerationMultiplier: 1,
            state: "cognitive_expression_\(kind.rawValue)",
            calibration: calibration,
            pose: pose,
            at: monotonicNS
        )
    }

    private func cognitiveExpressionOffsets(
        _ expression: SocialGimbalExpression,
        currentPan: Double
    ) -> [(pitch: Double, pan: Double)] {
        let inward = currentPan > 0 ? -1.0 : 1.0
        switch expression {
        case .attentiveReframe:
            return [(pitch: 2, pan: 7 * inward), (pitch: 0, pan: 0)]
        case .thinkingGlance:
            return [(pitch: 4, pan: 10 * inward), (pitch: 0, pan: 0)]
        }
    }

    private func cognitiveMotionProfile(
        for style: EmbodimentMotionStyle
    ) -> (panSpeed: Double, pitchSpeed: Double, panAcceleration: Double, pitchAcceleration: Double) {
        switch style {
        case .precise: (36, 18, 90, 60)
        case .smooth: (58, 28, 120, 80)
        case .attentive: (78, 34, 180, 100)
        case .curious: (48, 25, 110, 75)
        case .playful: (68, 32, 190, 105)
        case .cautious: (28, 15, 70, 45)
        }
    }

    private func stopCognitiveMotion(state: String, at monotonicNS: UInt64, retainLease: Bool) {
        cognitiveMotionGeneration += 1
        cognitiveMotionLoopRunning = false
        cognitiveDynamics.reset()
        cognitiveMotionHolding = true
        cognitiveExplorationWaypoint = nil
        cognitiveExplorationWaypointStartedNS = nil
        cancelExternalStop()
        if externalCommandID != nil {
            sendExternalStop(state: state, at: monotonicNS)
        }
        if !retainLease {
            activeCognitiveMotorRequestID = nil
            activeCognitiveMotorExpiresAtNS = nil
            cognitiveMotionMode = nil
        }
    }

    private func releaseCognitiveMotor(state: String, at monotonicNS: UInt64) {
        guard activeCognitiveMotorRequestID != nil else { return }
        let releasedRequestID = activeCognitiveMotorRequestID
        if let releasedRequestID {
            embodimentViewCaptureStore?.cancel(
                requestID: releasedRequestID,
                reason: state,
                at: monotonicNS
            )
        }
        stopCognitiveMotion(state: state, at: monotonicNS, retainLease: false)
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: monotonicNS,
            source: "embodiment_motor",
            state: "lease_released",
            message: "request_id=\(String((releasedRequestID ?? "none").prefix(96))); reason=\(String(state.prefix(96)))"
        ))
        reconcileFirmwareSoundFollowing(at: monotonicNS, reason: "cognitive_motor_released")
        scanScheduledForEvidenceGeneration = nil
        scheduleScanAfterContinuousVisualLoss()
    }

    private func disableFirmwareSoundFollowing(at monotonicNS: UInt64, reason: String) {
        requestFirmwareSoundFollowing(enabled: false, at: monotonicNS, reason: reason)
    }

    private func requestFirmwareSoundFollowing(
        enabled: Bool,
        at monotonicNS: UInt64,
        reason: String
    ) {
        guard helperReady,
              process.isRunning,
              deviceCapabilities?.supportsDeviceSoundLocalization == true else {
            return
        }
        guard monotonicNS >= firmwareSoundFollowingRetryAfterNS else { return }
        if pendingFirmwareSoundFollowing?.enabled == enabled { return }
        if pendingFirmwareSoundFollowing == nil,
           firmwareSoundFollowingActive == enabled {
            return
        }
        let commandID = nextCommandID(prefix: enabled ? "doa-enable" : "doa-disable")
        pendingFirmwareSoundFollowing = (enabled, commandID)
        send("doa_follow \(commandID) \(enabled ? 1 : 0)")
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: monotonicNS,
            source: "obsbot_audio_doa",
            state: enabled
                ? "firmware_sound_following_enable_requested"
                : "firmware_sound_following_disable_requested",
            message: "reason=\(String(reason.prefix(96))); command_id=\(commandID)"
        ))
    }

    /// The firmware must be listening before a short sound begins. Its sound
    /// detector remains armed while L0 is not socially engaged, but yields as
    /// soon as eye contact, conversation, or another cognitive motor lease
    /// owns the gimbal.
    private func reconcileFirmwareSoundFollowing(at monotonicNS: UInt64, reason: String) {
        guard helperReady,
              process.isRunning,
              deviceCapabilities?.supportsDeviceSoundLocalization == true else {
            return
        }
        let orienting = auditoryOrientingLease.isActive
        requestFirmwareSoundFollowing(
            enabled: orienting,
            at: monotonicNS,
            reason: reason
        )
    }

    private func auditoryMotorOrientationBlocked(at monotonicNS: UInt64) -> Bool {
        auditoryOrientingProtectedBySocialEngagement
            || nativeTrackingOwnsMotor
            || faceLock.permitsMotor(at: monotonicNS)
            || hasRecentObservedHuman(at: monotonicNS)
    }

    /// Presence and momentary eye contact do not disable hearing. Only an
    /// active conversation suppresses autonomous acoustic reorientation; this
    /// prevents landmark jitter from repeatedly toggling the firmware while
    /// preserving a stable conversational gaze once a session is established.
    private var auditoryOrientingProtectedBySocialEngagement: Bool {
        indicatorInputs.interactionState == .conversation
    }

    private func sendCalibrationVelocity(
        pitch: Double,
        pan: Double,
        state: String,
        target: AttentionTarget?,
        at monotonicNS: UInt64,
        afterStop: @escaping @Sendable (UInt64) -> Void
    ) {
        sendExternalVelocity(
            pitch: pitch,
            pan: pan,
            state: state,
            target: target,
            at: monotonicNS,
            hardStopAfterNS: 180_000_000,
            hardStopState: state == "calibration_pan_pulse" ? "calibration_pan_stop" : "calibration_pitch_stop",
            helperPulseDurationMS: 180,
            afterStop: afterStop
        )
    }

    private func sendExternalVelocity(
        pitch: Double,
        pan: Double,
        state: String,
        target: AttentionTarget?,
        at monotonicNS: UInt64,
        hardStopAfterNS: UInt64,
        hardStopState: String = "external_hard_stop",
        helperPulseDurationMS: Int? = nil,
        afterStop: (@Sendable (UInt64) -> Void)? = nil
    ) {
        guard !suppressExternalMotionForNativeLease(
            state: state,
            at: monotonicNS
        ) else {
            return
        }
        // A face command is never allowed to keep pushing while its own
        // previous commands have carried the optical axis into a posture that
        // cannot be justified by the current image. Release the latch, stop,
        // and request the helper's home position before considering another
        // candidate.
        if target?.isFaceMotorTarget == true,
           requestFaceServoRecenterIfBeyondEnvelope(at: monotonicNS) {
            return
        }
        cancelExternalStop()
        if pitch != 0 || pan != 0 {
            poseStore.noteMotion(
                at: monotonicNS,
                durationNS: max(hardStopAfterNS, 180_000_000) + 250_000_000
            )
        }
        let commandID = externalCommandID ?? nextCommandID(prefix: "external")
        externalCommandID = commandID
        if let helperPulseDurationMS {
            send(String(format: "external_pulse %@ %.4f %.4f %d", commandID, pitch, pan, helperPulseDurationMS))
        } else {
            send(String(format: "external_velocity %@ %.4f %.4f", commandID, pitch, pan))
        }
        writer.write(CameraIntentEvent(
            monotonicNS: monotonicNS,
            owner: .external,
            state: state,
            route: .externalVisualControl,
            commandID: commandID,
            targetKind: target?.kind,
            targetLabel: target?.label,
            targetProbability: target?.posteriorProbability ?? 0
        ))
        if target?.isFaceMotorTarget == true,
           monotonicNS >= lastFaceServoDiagnosticNS + 150_000_000 {
            lastFaceServoDiagnosticNS = monotonicNS
            let measuredPose = poseStore.current(maximumAgeNS: 500_000_000)
            writer.write(RuntimeEvent(
                event: "face_servo.command",
                monotonicNS: monotonicNS,
                source: "face_servo",
                state: state,
                message: String(
                    format: "scene_id=%@; center_x=%.3f; center_y=%.3f; command_pitch_dps=%.2f; command_pan_dps=%.2f; feedback_pitch_degrees=%@; feedback_pan_degrees=%@",
                    target?.id ?? "none",
                    target?.rect.centerX ?? -1,
                    target?.rect.centerY ?? -1,
                    pitch,
                    pan,
                    measuredPose.map { String(format: "%.2f", $0.pitchDegrees) } ?? "unavailable",
                    measuredPose.map { String(format: "%.2f", $0.panDegrees) } ?? "unavailable"
                )
            ))
        }
        scheduleExternalStop(afterNS: hardStopAfterNS, state: hardStopState, afterStop: afterStop)
    }

    private func requestFaceServoRecenterIfBeyondEnvelope(at monotonicNS: UInt64) -> Bool {
        guard !explorationRecentering,
              let pose = poseStore.current(maximumAgeNS: 500_000_000),
              (abs(pose.pitchDegrees) >= 42 || abs(pose.panDegrees) >= 115) else {
            return false
        }
        faceLock.invalidate()
        lastMotorTarget = nil
        sendExternalStop(state: "face_servo_limit_recenter", at: monotonicNS)
        requestExplorationRecenter(at: monotonicNS, observedPanMotion: 0)
        return true
    }

    private func sendExternalPosition(
        pitch: Double,
        pan: Double,
        state: String,
        target: AttentionTarget?,
        at monotonicNS: UInt64,
        hardStopAfterNS: UInt64?
    ) {
        guard !suppressExternalMotionForNativeLease(
            state: state,
            at: monotonicNS
        ) else {
            return
        }
        cancelExternalStop()
        poseStore.noteMotion(at: monotonicNS, durationNS: 750_000_000)
        let commandID = externalCommandID ?? nextCommandID(prefix: "external")
        externalCommandID = commandID
        send(String(format: "external_position %@ %.4f %.4f", commandID, pitch, pan))
        writer.write(CameraIntentEvent(
            monotonicNS: monotonicNS,
            owner: .external,
            state: state,
            route: .externalVisualControl,
            commandID: commandID,
            targetKind: target?.kind,
            targetLabel: target?.label,
            targetProbability: target?.posteriorProbability ?? 0
        ))
        if let hardStopAfterNS {
            scheduleExternalStop(afterNS: hardStopAfterNS, state: "external_hard_stop")
        }
    }

    private func sendExternalStop(state: String, at monotonicNS: UInt64) {
        guard !nativeTrackingOwnsMotor else {
            cancelExternalStop()
            externalCommandID = nil
            return
        }
        poseStore.noteMotion(at: monotonicNS, durationNS: 250_000_000)
        let faceAgeMilliseconds: Double?
        if let lastObservedFaceNS, monotonicNS >= lastObservedFaceNS {
            faceAgeMilliseconds = Double(monotonicNS - lastObservedFaceNS) / 1_000_000
        } else {
            faceAgeMilliseconds = nil
        }
        let target = lastMotorTarget
        let pose = poseStore.current(maximumAgeNS: 500_000_000)
        faceLockDiagnosticRecorder?.recordStop(GimbalStopDiagnostic(
            monotonicNS: monotonicNS,
            reason: state,
            faceLockActive: faceLock.isActive(at: monotonicNS),
            faceLockMotorPermitted: faceLock.permitsMotor(at: monotonicNS),
            lastObservedFaceMilliseconds: faceAgeMilliseconds,
            targetID: target?.id,
            targetKind: target?.kind,
            targetLabel: target?.label,
            targetConfidence: target?.confidence,
            targetCenterX: target?.rect.centerX,
            targetCenterY: target?.rect.centerY,
            targetActionEligible: target?.isActionEligible,
            posePitchDegrees: pose?.pitchDegrees,
            posePanDegrees: pose?.panDegrees
        ))
        let commandID = nextCommandID(prefix: "external-stop")
        send("external_stop \(commandID)")
        externalCommandID = nil
        writer.write(CameraIntentEvent(
            monotonicNS: monotonicNS,
            owner: .external,
            state: state,
            route: .none,
            commandID: commandID,
            targetKind: nil,
            targetLabel: nil,
            targetProbability: 0
        ))
    }

    private func suppressExternalMotionForNativeLease(
        state: String,
        at monotonicNS: UInt64
    ) -> Bool {
        guard nativeTrackingOwnsMotor else { return false }
        cancelExternalStop()
        externalCommandID = nil
        if monotonicNS >= lastNativeLeaseMotionSuppressionNS + 250_000_000 {
            lastNativeLeaseMotionSuppressionNS = monotonicNS
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNS,
                source: "attention_gimbal_bridge",
                state: "external_motion_suppressed",
                message: "reason=native_tracking_lease; requested_state=\(String(state.prefix(96)))"
            ))
        }
        return true
    }

    private func scheduleExternalStop(
        afterNS: UInt64,
        state: String,
        afterStop: (@Sendable (UInt64) -> Void)? = nil
    ) {
        externalStopGeneration += 1
        let generation = externalStopGeneration
        queue.asyncAfter(deadline: .now() + .nanoseconds(Int(afterNS))) { [weak self] in
            guard let self,
                  self.externalStopGeneration == generation,
                  case .running = self.state else { return }
            let stoppedNS = monotonicNanoseconds()
            self.sendExternalStop(state: state, at: stoppedNS)
            afterStop?(stoppedNS)
        }
    }

    private func cancelExternalStop() {
        externalStopGeneration += 1
    }

    private func startSmoothExploration(priority: ScanPriority = .l0) {
        // A remembered face has its own bounded return path. Starting a
        // coverage trajectory alongside it races two targets through the same
        // command slot and is perceived as looking away from the person.
        let now = monotonicNanoseconds()
        guard externalCalibration != nil else {
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: now,
                source: "attention_gimbal_bridge",
                state: "coverage_requires_calibrated_pose",
                message: "autonomous_scan_not_started"
            ))
            return
        }
        let exclusiveScan = cameraGeometryCalibrationMode || panoramaStripScanMode
        switch priority {
        case .l0:
            // Reflexive L0 scan is the lowest authority: it yields to a
            // recently observed face, an active L0 face lock, and an in-flight
            // L1 gaze expression.
            guard (exclusiveScan || !hasRecentObservedFace(at: now)),
                  (exclusiveScan || activeSpatialFaceReacquisition == nil),
                  (exclusiveScan || !faceLock.permitsMotor(at: now)),
                  (exclusiveScan || !cognitiveMotionLoopRunning),
                  !scanRunning,
                  !explorationRecentering else { return }
        case .l1:
            // L1 (conscious stream) outranks L0: it may tear away the reflexive
            // face lock to scan, but yields to an active L2 scan.
            guard !(scanRunning && scanPriority == .l2),
                  !explorationRecentering else { return }
            faceLock.invalidate()
        case .l2:
            // L2 (conversation) is the highest authority: it may tear away the
            // L0 face lock and preempt an in-flight L1 cognitive expression.
            guard !explorationRecentering else { return }
            faceLock.invalidate()
            stopCognitiveMotion(state: "l2_preempted", at: now, retainLease: false)
        }
        scanPriority = priority
        scanRunning = true
        onL0FaceFixation(nil, false, now)
        scanGeneration += 1
        explorationWaypoint = nil
        explorationWaypointStartedNS = nil
        explorationWaypointDeadlineNS = nil
        explorationWaypointStartingPose = nil
        explorationWaypointSource = nil
        explorationWaypointIndex = 0
        cameraGeometryCommandedRouteIndex = nil
        cameraGeometryWaypointStableSinceNS = nil
        panoramaWaypointStableSinceNS = nil
        cameraGeometryNextPositionCommandNS = 0
        explorationBoundaryTurning = false
        poseWaitStopIssued = false
        poseStreamDegradedReported = false
        smoothExploration.reset()
        scheduleScanControlTick(generation: scanGeneration)
    }

    /// L1/L2 behavior directive entry point: resume the coverage scan. The
    /// `priority` argument encodes the motor authority of the issuing layer
    /// (L1 conscious stream or L2 conversation), so a higher layer may tear
    /// away the reflexive L0 face lock.
    func resumeCoverageScan(priority: ScanPriority = .l0) {
        startSmoothExploration(priority: priority)
    }

    private func cancelScan() {
        scanGeneration += 1
        // A scheduled absence callback is valid only until the scan it may
        // start is preempted. Keeping its generation after cancellation makes
        // a later legitimate resume (for example after an auditory orienting
        // lease expires) look like a duplicate and leaves the camera idle.
        scanScheduledForEvidenceGeneration = nil
        scanRunning = false
        explorationWaypoint = nil
        explorationWaypointStartedNS = nil
        explorationWaypointDeadlineNS = nil
        explorationWaypointStartingPose = nil
        explorationWaypointSource = nil
        cameraGeometryCommandedRouteIndex = nil
        cameraGeometryWaypointStableSinceNS = nil
        panoramaWaypointStableSinceNS = nil
        cameraGeometryNextPositionCommandNS = 0
        explorationBoundaryTurning = false
        poseWaitStopIssued = false
        poseStreamDegradedReported = false
        smoothExploration.reset()
    }

    private func hasRecentObservedFace(at monotonicNS: UInt64) -> Bool {
        guard let lastObservedFaceNS else { return false }
        guard monotonicNS >= lastObservedFaceNS else { return true }
        return monotonicNS - lastObservedFaceNS <= 600_000_000
    }

    private func hasRecentObservedHuman(at monotonicNS: UInt64) -> Bool {
        guard let lastFreshHumanObservationNS else { return false }
        guard monotonicNS >= lastFreshHumanObservationNS else { return true }
        return monotonicNS - lastFreshHumanObservationNS <= 600_000_000
    }

    private func scheduleScanControlTick(generation: Int, afterMilliseconds: Int = 0) {
        queue.asyncAfter(deadline: .now() + .milliseconds(afterMilliseconds)) { [weak self] in
            self?.runScanControlTick(generation: generation)
        }
    }

    private func runScanControlTick(generation: Int) {
        guard scanRunning, generation == scanGeneration else { return }
        let now = monotonicNanoseconds()
        // A reflexive L0 scan yields to a recently observed face, an active L0
        // face lock, and a spatial reacquisition. A higher-authority L1/L2 scan
        // keeps scanning: it already tore the face lock away on initiation.
        let l0Yields = !hasRecentObservedFace(at: now)
            && activeSpatialFaceReacquisition == nil
            && !faceLock.permitsMotor(at: now)
        guard cameraGeometryCalibrationMode || panoramaStripScanMode
            || (scanPriority == .l0 ? l0Yields : true) else {
            cancelScan()
            return
        }
        guard let calibration = externalCalibration else {
            cancelScan()
            return
        }
        let desired: (pitch: Double, pan: Double, state: String)
            // The native helper reports attitude on a dedicated thread at a
            // ~70-90ms cadence (synchronous device round-trip), with occasional
            // multi-hundred-ms gaps while the bridge loop is inside a mode
            // switch. A 600ms window absorbs those gaps; the gimbal moves
            // slowly enough that a pose up to 600ms old is still safe for
            // waypoint tracking.
            guard let pose = poseStore.latest(at: now, maximumAgeNS: 600_000_000) else {
                // A calibrated spherical route has no valid frame of
                // reference without current attitude feedback. Releasing a
                // prior velocity once preserves the last safe posture; a
                // repeated zero-velocity command would instead seize the
                // camera in external mode while providing no recovery path.
                if !poseWaitStopIssued {
                    poseWaitStopIssued = true
                    if externalCommandID != nil {
                        sendExternalStop(state: "coverage_pose_unavailable", at: now)
                    }
                    writer.write(RuntimeEvent(
                        event: "source.health",
                        monotonicNS: now,
                        source: "attention_gimbal_bridge",
                        state: "coverage_pose_unavailable",
                        message: "route_paused_until_sdk_attitude_feedback"
                    ))
                }
                scheduleScanControlTick(generation: generation, afterMilliseconds: 50)
                return
            }
            if !poseStore.hasContinuousFeedback(at: now) {
                if !poseStreamDegradedReported {
                    poseStreamDegradedReported = true
                    writer.write(RuntimeEvent(
                        event: "source.health",
                        monotonicNS: now,
                        source: "attention_gimbal_bridge",
                        state: "coverage_pose_stream_degraded",
                        message: "sdk_attitude_gap_observed; route_continues_with_fresh_measured_pose"
                    ))
                }
            } else {
                poseStreamDegradedReported = false
            }
            poseWaitStopIssued = false
            if cameraGeometryCalibrationMode {
                runCameraGeometryCalibrationTick(
                    pose: pose,
                    at: now,
                    generation: generation
                )
                return
            }
            // Turn inward early enough to brake before the joint limit. This
            // remains a velocity curve; absolute re-centering is reserved for
            // a measured two-direction stall instead of normal exploration.
            beginBoundaryTurnIfNeeded(at: now, pose: pose)
            finishExplorationWaypointIfNeeded(at: now, pose: pose)
            guard scanRunning, generation == scanGeneration, !explorationRecentering else { return }
            if explorationWaypoint == nil {
                var plannedDirection: (cell: SpatialCoverageDirection, guide: GimbalRelativeBearing, uniform: Double)?
                if panoramaStripScanMode {
                    let bearing = Self.panoramaStripScanBearings[
                        panoramaStripRouteIndex % Self.panoramaStripScanBearings.count
                    ]
                    plannedDirection = (
                        SpatialCoverageDirection(
                            bearing: bearing,
                            probability: 1,
                            panoramaQuality: 0,
                            placeFamiliarity: 0,
                            expectedInformationGain: 1
                        ),
                        bearing,
                        0
                    )
                    panoramaStripRouteIndex += 1
                } else {
                    for _ in 0..<8 {
                        let coverageUniform = nextExplorationUniform()
                        guard let sampledDirection = spatialAtlas.sampleNextDirection(
                            from: pose,
                            at: now,
                            temperature: explorationTemperature,
                            uniform: coverageUniform
                        ) else { break }
                        if let motionGuide = GimbalVisibilityRoutePlanner.guide(
                            to: sampledDirection.bearing,
                            from: pose,
                            kinematicEnvelope: activeKinematicEnvelope,
                            observationPreference: .centered
                        ) {
                            plannedDirection = (sampledDirection, motionGuide, coverageUniform)
                            break
                        }
                        writer.write(RuntimeEvent(
                            event: "source.health",
                            monotonicNS: now,
                            source: "attention_gimbal_bridge",
                            state: "coverage_direction_unreachable",
                            message: String(
                                format: "cell_azimuth_degrees=%.2f; cell_elevation_degrees=%.2f",
                                sampledDirection.bearing.azimuthDegrees,
                                sampledDirection.bearing.elevationDegrees
                            )
                        ))
                    }
                }
                guard let plannedDirection else {
                    explorationWaypointDeadlineNS = nil
                    writer.write(RuntimeEvent(
                        event: "source.health",
                        monotonicNS: now,
                        source: "attention_gimbal_bridge",
                        state: "coverage_no_exploration_sampled",
                        message: String(format: "temperature=%.2f", explorationTemperature)
                    ))
                    let velocity = smoothExploration.advance(towardPitch: 0, pan: 0, at: now)
                    sendSmoothExplorationVelocity(
                        velocity,
                        state: "coverage_exploration_decelerating",
                        at: now
                    )
                    scheduleScanControlTick(generation: generation, afterMilliseconds: 150)
                    return
                }
                explorationWaypoint = SpatialCoverageDirection(
                    bearing: plannedDirection.guide,
                    probability: plannedDirection.cell.probability,
                    panoramaQuality: plannedDirection.cell.panoramaQuality,
                    placeFamiliarity: plannedDirection.cell.placeFamiliarity,
                    expectedInformationGain: plannedDirection.cell.expectedInformationGain
                )
                explorationWaypointStartedNS = now
                explorationWaypointSource = plannedDirection.cell
                explorationWaypointDeadlineNS = now + UInt64(
                    SmoothExplorationDynamics.waypointTimeoutSeconds(
                        panErrorDegrees: plannedDirection.guide.azimuthDegrees - pose.panDegrees,
                        pitchErrorDegrees: plannedDirection.guide.elevationDegrees - pose.pitchDegrees,
                        maximumPanDegreesPerSecond: min(
                            maximumActiveExplorationPanDegreesPerSecond,
                            calibration.maximumPanDegreesPerSecond
                        ),
                        maximumPitchDegreesPerSecond: min(
                            maximumActiveExplorationPitchDegreesPerSecond,
                            calibration.maximumPitchDegreesPerSecond
                        )
                    ) * 1_000_000_000
                )
                explorationWaypointStartingPose = pose
                panoramaWaypointStableSinceNS = nil
                spatialAtlas.recordExplorationCommit(to: plannedDirection.cell, at: now)
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: now,
                    source: "attention_gimbal_bridge",
                    state: "coverage_direction_sampled",
                    message: String(
                        format: "selection=tempered_posterior; temperature=%.2f; uniform=%.6f; probability=%.3f; panorama_quality=%.3f; place_familiarity=%.3f; expected_information_gain=%.3f; cell_azimuth_degrees=%.2f; cell_elevation_degrees=%.2f; guide_azimuth_degrees=%.2f; guide_elevation_degrees=%.2f",
                        explorationTemperature,
                        plannedDirection.uniform,
                        plannedDirection.cell.probability,
                        plannedDirection.cell.panoramaQuality,
                        plannedDirection.cell.placeFamiliarity,
                        plannedDirection.cell.expectedInformationGain,
                        plannedDirection.cell.bearing.azimuthDegrees,
                        plannedDirection.cell.bearing.elevationDegrees,
                        plannedDirection.guide.azimuthDegrees,
                        plannedDirection.guide.elevationDegrees
                    )
                ))
            }
            guard let direction = explorationWaypoint else { return }
            // Coverage cells are spherical directions, not yaw-only labels.
            // The acceleration limiter blends either a sampled waypoint or a
            // boundary-return guide into the current velocity.
            let pitchError = SmoothExplorationDynamics.stoppingVelocity(
                    errorDegrees: direction.bearing.elevationDegrees - pose.pitchDegrees,
                    maximumDegreesPerSecond: min(
                        maximumActiveExplorationPitchDegreesPerSecond,
                        calibration.maximumPitchDegreesPerSecond
                    ),
                    accelerationDegreesPerSecondSquared: 80
                )
            let panError = SmoothExplorationDynamics.stoppingVelocity(
                    // The spherical map wraps at 180 degrees, but the
                    // physical Tiny pan joint does not. Take the reachable
                    // path through home instead of driving into the nearer
                    // mathematical wrap boundary.
                    errorDegrees: direction.bearing.azimuthDegrees - pose.panDegrees,
                    maximumDegreesPerSecond: min(
                        maximumActiveExplorationPanDegreesPerSecond,
                        calibration.maximumPanDegreesPerSecond
                    ),
                    accelerationDegreesPerSecondSquared: 120
                )
        desired = (
                calibration.pitchCommand(
                    forPoseError: pitchError,
                    projection: externalPoseProjection
                ),
                calibration.panCommand(
                    forPoseError: panError,
                    projection: externalPoseProjection
                ) * explorationPanPolarity,
                explorationBoundaryTurning
                    ? "coverage_boundary_turn_curve"
                    : "coverage_exploration_curve_\(explorationWaypointIndex + 1)"
            )
        let velocity = smoothExploration.advance(
            towardPitch: desired.pitch,
            pan: desired.pan,
            at: now
        )
        sendSmoothExplorationVelocity(velocity, state: desired.state, at: now)
        scheduleScanControlTick(generation: generation, afterMilliseconds: 50)
    }

    private static let cameraGeometryCalibrationBearings: [GimbalRelativeBearing] = [
        .init(azimuthDegrees: -60, elevationDegrees: -15),
        .init(azimuthDegrees: -40, elevationDegrees: -15),
        .init(azimuthDegrees: -20, elevationDegrees: -15),
        .init(azimuthDegrees: 0, elevationDegrees: -15),
        .init(azimuthDegrees: 20, elevationDegrees: -15),
        .init(azimuthDegrees: 40, elevationDegrees: -15),
        .init(azimuthDegrees: 60, elevationDegrees: -15),
        .init(azimuthDegrees: 60, elevationDegrees: 0),
        .init(azimuthDegrees: 40, elevationDegrees: 0),
        .init(azimuthDegrees: 20, elevationDegrees: 0),
        .init(azimuthDegrees: 0, elevationDegrees: 0),
        .init(azimuthDegrees: -20, elevationDegrees: 0),
        .init(azimuthDegrees: -40, elevationDegrees: 0),
        .init(azimuthDegrees: -60, elevationDegrees: 0),
        .init(azimuthDegrees: -60, elevationDegrees: 15),
        .init(azimuthDegrees: -40, elevationDegrees: 15),
        .init(azimuthDegrees: -20, elevationDegrees: 15),
        .init(azimuthDegrees: 0, elevationDegrees: 15),
        .init(azimuthDegrees: 20, elevationDegrees: 15),
        .init(azimuthDegrees: 40, elevationDegrees: 15),
        .init(azimuthDegrees: 60, elevationDegrees: 15),
    ]

    private static let panoramaStripScanBearings: [GimbalRelativeBearing] = [
        .init(azimuthDegrees: -110, elevationDegrees: -24),
        .init(azimuthDegrees: 110, elevationDegrees: -24),
        .init(azimuthDegrees: 110, elevationDegrees: -8),
        .init(azimuthDegrees: -110, elevationDegrees: -8),
        .init(azimuthDegrees: -110, elevationDegrees: 8),
        .init(azimuthDegrees: 110, elevationDegrees: 8),
        .init(azimuthDegrees: 110, elevationDegrees: 24),
        .init(azimuthDegrees: -110, elevationDegrees: 24),
    ]

    private static let maximumExplorationPanDegreesPerSecond = 12.0
    private static let maximumExplorationPitchDegreesPerSecond = 10.0
    private static let maximumPanoramaStripPanDegreesPerSecond = 12.0
    private static let maximumPanoramaStripPitchDegreesPerSecond = 8.0

    private var maximumActiveExplorationPanDegreesPerSecond: Double {
        panoramaStripScanMode
            ? Self.maximumPanoramaStripPanDegreesPerSecond
            : Self.maximumExplorationPanDegreesPerSecond
    }

    private var maximumActiveExplorationPitchDegreesPerSecond: Double {
        panoramaStripScanMode
            ? Self.maximumPanoramaStripPitchDegreesPerSecond
            : Self.maximumExplorationPitchDegreesPerSecond
    }

    private func runCameraGeometryCalibrationTick(
        pose: GimbalPose,
        at monotonicNS: UInt64,
        generation: Int
    ) {
        let route = Self.cameraGeometryCalibrationBearings
        let routeIndex = cameraGeometryRouteIndex % route.count
        let target = route[routeIndex]
        let panError = abs(target.azimuthDegrees - pose.panDegrees)
        let pitchError = abs(target.elevationDegrees - pose.pitchDegrees)
        let reached = panError <= 0.60 && pitchError <= 0.60

        if cameraGeometryCommandedRouteIndex != routeIndex
            || monotonicNS >= cameraGeometryNextPositionCommandNS {
            sendExternalPosition(
                pitch: target.elevationDegrees,
                pan: target.azimuthDegrees,
                state: "camera_geometry_absolute_waypoint_\(routeIndex + 1)",
                target: nil,
                at: monotonicNS,
                hardStopAfterNS: nil
            )
            cameraGeometryCommandedRouteIndex = routeIndex
            cameraGeometryNextPositionCommandNS = monotonicNS + 400_000_000
        }

        if reached {
            if let stableSince = cameraGeometryWaypointStableSinceNS,
               monotonicNS >= stableSince + 900_000_000 {
                cameraGeometryRouteIndex = (routeIndex + 1) % route.count
                cameraGeometryCommandedRouteIndex = nil
                cameraGeometryWaypointStableSinceNS = nil
                cameraGeometryNextPositionCommandNS = 0
            } else if cameraGeometryWaypointStableSinceNS == nil {
                cameraGeometryWaypointStableSinceNS = monotonicNS
            }
        } else {
            cameraGeometryWaypointStableSinceNS = nil
        }

        scheduleScanControlTick(generation: generation, afterMilliseconds: 50)
    }

    private func beginBoundaryTurnIfNeeded(at monotonicNS: UInt64, pose: GimbalPose) {
        let envelope = activeKinematicEnvelope
        let measuredCenter = GimbalRelativeBearing(
            azimuthDegrees: pose.panDegrees,
            elevationDegrees: pose.pitchDegrees
        )
        guard !explorationBoundaryTurning,
              !envelope.containsTrackingCenter(measuredCenter) else { return }
        // Autonomous waypoints may legitimately sit on their own boundary.
        // Recovery begins only outside the wider tracking envelope, otherwise
        // normal servo overshoot would replace a valid strip with an inward
        // recovery target and fragment the resulting spatial coverage.
        let recoveryPan = max(0, envelope.maximumAutonomousPanDegrees - 20)
        let recoveryPitch = max(0, envelope.maximumAutonomousPitchDegrees - 9)
        let targetPan = abs(pose.panDegrees) > envelope.maximumAutonomousPanDegrees
            ? (pose.panDegrees < 0 ? -recoveryPan : recoveryPan)
            : min(max(pose.panDegrees, -recoveryPan), recoveryPan)
        let targetPitch = abs(pose.pitchDegrees) > envelope.maximumAutonomousPitchDegrees
            ? (pose.pitchDegrees < 0 ? -recoveryPitch : recoveryPitch)
            : min(max(pose.pitchDegrees, -recoveryPitch), recoveryPitch)
        explorationBoundaryTurning = true
        explorationWaypoint = SpatialCoverageDirection(
            bearing: GimbalRelativeBearing(
                azimuthDegrees: targetPan,
                elevationDegrees: targetPitch
            ),
            probability: 1
        )
        explorationWaypointStartedNS = monotonicNS
        explorationWaypointSource = nil
        explorationWaypointDeadlineNS = monotonicNS + UInt64(
            SmoothExplorationDynamics.waypointTimeoutSeconds(
                panErrorDegrees: targetPan - pose.panDegrees,
                pitchErrorDegrees: targetPitch - pose.pitchDegrees,
                maximumPanDegreesPerSecond: min(
                    maximumActiveExplorationPanDegreesPerSecond,
                    externalCalibration?.maximumPanDegreesPerSecond
                        ?? maximumActiveExplorationPanDegreesPerSecond
                ),
                maximumPitchDegreesPerSecond: min(
                    maximumActiveExplorationPitchDegreesPerSecond,
                    externalCalibration?.maximumPitchDegreesPerSecond
                        ?? maximumActiveExplorationPitchDegreesPerSecond
                )
            ) * 1_000_000_000
        )
        explorationWaypointStartingPose = pose
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: monotonicNS,
            source: "attention_gimbal_bridge",
            state: "coverage_out_of_envelope_recovery_started",
            message: String(
                format: "pose_pan_degrees=%.2f; pose_pitch_degrees=%.2f; target_pan_degrees=%.2f; target_pitch_degrees=%.2f",
                pose.panDegrees,
                pose.pitchDegrees,
                targetPan,
                targetPitch
            )
        ))
    }

    private func finishExplorationWaypointIfNeeded(at monotonicNS: UInt64, pose: GimbalPose) {
        guard let direction = explorationWaypoint,
              let startedNS = explorationWaypointStartedNS else { return }
        let panError = abs(direction.bearing.azimuthDegrees - pose.panDegrees)
        let pitchError = abs(direction.bearing.elevationDegrees - pose.pitchDegrees)
        // High-information views approach the optical centre; familiar,
        // already-clear views blend earlier into the next reachable route.
        // This keeps epistemic exploration continuous without stopping at a
        // waypoint merely because it was selected by the atlas posterior.
        let lookAheadRadiusDegrees = 2 + 8 * (1 - direction.expectedInformationGain)
        let reached = SmoothExplorationDynamics.shouldBlendToNextWaypoint(
            panErrorDegrees: panError,
            pitchErrorDegrees: pitchError,
            lookAheadRadiusDegrees: lookAheadRadiusDegrees
        )
        let timedOut = explorationWaypointDeadlineNS.map { monotonicNS >= $0 }
            ?? (monotonicNS >= startedNS + 3_500_000_000)
        if panoramaStripScanMode, !explorationBoundaryTurning, reached, !timedOut {
            if let stableSince = panoramaWaypointStableSinceNS {
                guard monotonicNS >= stableSince + 450_000_000 else { return }
            } else {
                panoramaWaypointStableSinceNS = monotonicNS
                return
            }
        } else if !reached {
            panoramaWaypointStableSinceNS = nil
        }
        guard reached || timedOut else { return }
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: monotonicNS,
            source: "attention_gimbal_bridge",
            state: "coverage_waypoint_completed",
            message: String(
                format: "result=%@; target_pan_degrees=%.2f; target_pitch_degrees=%.2f; pose_pan_degrees=%.2f; pose_pitch_degrees=%.2f; elapsed_ms=%.1f",
                reached ? "reached" : "timed_out",
                direction.bearing.azimuthDegrees,
                direction.bearing.elevationDegrees,
                pose.panDegrees,
                pose.pitchDegrees,
                Double(monotonicNS - startedNS) / 1_000_000
            )
        ))
        if reached, !explorationBoundaryTurning, let source = explorationWaypointSource {
            spatialAtlas.recordUnproductiveVisit(to: source, at: monotonicNS)
        }
        if reached {
            explorationFailureCount = max(0, explorationFailureCount - 1)
        } else {
            explorationFailureCount += 1
            if let startingPose = explorationWaypointStartingPose,
               adaptExplorationPanPolarity(
                    from: startingPose,
                    requestedPan: direction.bearing.azimuthDegrees - startingPose.panDegrees
               ) {
                return
            }
        }
        explorationWaypoint = nil
        explorationWaypointStartedNS = nil
        explorationWaypointDeadlineNS = nil
        explorationWaypointStartingPose = nil
        explorationWaypointSource = nil
        panoramaWaypointStableSinceNS = nil
        explorationBoundaryTurning = false
        explorationWaypointIndex = (explorationWaypointIndex + 1) % 6
    }

    private func sendSmoothExplorationVelocity(
        _ velocity: SmoothExplorationVelocity,
        state: String,
        at monotonicNS: UInt64
    ) {
        sendExternalVelocity(
            pitch: velocity.pitchDegreesPerSecond,
            pan: velocity.panDegreesPerSecond,
            state: state,
            target: nil,
            at: monotonicNS,
            hardStopAfterNS: 650_000_000
        )
    }

    private func adaptExplorationPanPolarity(from startingPose: GimbalPose, requestedPan: Double) -> Bool {
        guard abs(requestedPan) >= 12,
              let endingPose = poseStore.latest(
                at: monotonicNanoseconds(),
                maximumAgeNS: 500_000_000
              ) else {
            return false
        }
        let panMotion = abs(angularDifference(endingPose.panDegrees, startingPose.panDegrees))
        switch panStallRecovery.record(
            requestedPanDegreesPerSecond: requestedPan,
            observedMotionDegrees: panMotion
        ) {
        case .none:
            return false
        case .reverse:
            explorationPanPolarity *= -1
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNanoseconds(),
                source: "attention_gimbal_bridge",
                state: "coverage_pan_reversed",
                message: String(format: "requested_pan_degrees_per_second=%.2f; observed_pan_motion_degrees=%.2f", requestedPan, panMotion)
            ))
            return false
        case .recenter:
            requestExplorationRecenter(at: monotonicNanoseconds(), observedPanMotion: panMotion)
            return true
        }
    }

    private func requestExplorationRecenter(at monotonicNS: UInt64, observedPanMotion: Double) {
        guard !explorationRecentering else { return }
        explorationRecentering = true
        cancelExternalStop()
        cancelScan()
        scanScheduledForEvidenceGeneration = nil
        let commandID = nextCommandID(prefix: "coverage-recenter")
        send("recenter \(commandID)")
        writer.write(CameraIntentEvent(
            monotonicNS: monotonicNS,
            owner: .manual,
            state: "coverage_recenter_requested",
            route: .none,
            commandID: commandID,
            targetKind: nil,
            targetLabel: nil,
            targetProbability: 0
        ))
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: monotonicNS,
            source: "attention_gimbal_bridge",
            state: "coverage_pan_stall_recenter",
            message: String(format: "observed_pan_motion_degrees=%.2f", observedPanMotion)
        ))
        awaitExplorationRecenter(untilNS: monotonicNS + 5_000_000_000)
    }

    private func awaitExplorationRecenter(untilNS: UInt64) {
        queue.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
            guard let self, self.explorationRecentering, case .running = self.state else { return }
            let now = monotonicNanoseconds()
            if let pose = self.poseStore.latest(at: now, maximumAgeNS: 500_000_000),
               abs(pose.pitchDegrees) <= 4,
               abs(pose.panDegrees) <= 4 {
                self.explorationRecentering = false
                self.explorationPanPolarity = 1
                self.writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: now,
                    source: "attention_gimbal_bridge",
                    state: "coverage_recentered",
                    message: "sdk_attitude_near_home"
                ))
                self.scheduleScanAfterContinuousVisualLoss()
                return
            }
            guard now < untilNS else {
                self.send("manual_stop \(self.nextCommandID(prefix: "coverage-recenter-timeout"))")
                // A failed home confirmation must not permanently suppress the
                // L0 search loop. Stop the incomplete position command, then
                // re-arm normal no-target exploration from the measured pose.
                self.explorationRecentering = false
                self.explorationPanPolarity = 1
                self.scanScheduledForEvidenceGeneration = nil
                self.writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: now,
                    source: "attention_gimbal_bridge",
                    state: "coverage_recenter_timeout",
                    message: "manual_stop_requested; exploration_rearmed"
                ))
                self.queue.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
                    self?.scheduleScanAfterContinuousVisualLoss()
                }
                return
            }
            self.awaitExplorationRecenter(untilNS: untilNS)
        }
    }

    private var explorationTemperature: Double {
        // Keep stochasticity without flattening the novelty posterior so far
        // that repeatedly visited cells become almost as likely as unseen ones.
        min(1.35, 1 + 0.04 * Double(explorationFailureCount))
    }

    private func nextExplorationUniform() -> Double {
        explorationRandomState = explorationRandomState &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(explorationRandomState >> 11) / 9_007_199_254_740_992
    }

    private func failCalibration(_ message: String, at monotonicNS: UInt64) {
        calibrationStage = .failed
        calibrationMode = false
        visualEvidenceGeneration += 1
        scanScheduledForEvidenceGeneration = nil
        cancelScan()
        cancelExternalStop()
        idleExplorationGate = nil
        externalGate = nil
        sendExternalStop(state: "calibration_failed", at: monotonicNS)
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: monotonicNS,
            source: "external_gimbal_calibration",
            state: "failed",
            message: message
        ))
    }

    private func nextCommandID(prefix: String) -> String {
        commandSequence += 1
        return "\(prefix)-\(commandSequence)"
    }

    private func startIndicatorReassertionLoop() {
        guard supportsIndicatorRendering else { return }
        indicatorReassertionGeneration += 1
        scheduleIndicatorReassertion(generation: indicatorReassertionGeneration)
    }

    private func scheduleIndicatorReassertion(generation: Int) {
        queue.asyncAfter(
            deadline: .now() + .milliseconds(indicatorReassertionIntervalMilliseconds)
        ) { [weak self] in
            guard let self,
                  generation == self.indicatorReassertionGeneration,
                  case .running = self.state,
                  self.helperReady else { return }
            self.reconcileIndicatorPalette(at: monotonicNanoseconds())
            self.scheduleIndicatorReassertion(generation: generation)
        }
    }

    private func refreshIndicator(
        at monotonicNS: UInt64,
        forceHardwareReassertion: Bool = false
    ) {
        guard indicatorCalibrationPreset == nil else { return }
        let next = resolvedIndicatorPresentation(at: monotonicNS)
        guard supportsIndicatorRendering else {
            guard next != activeIndicatorState || indicatorIlluminated else { return }
            activeIndicatorState = next
            activeIndicatorRendering = nil
            indicatorIlluminated = false
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNS,
                source: "social_indicator",
                state: "palette_unverified_for_profile",
                message: "profile=\(deviceProfile?.rawValue ?? "unknown"); requested_state=\(next.rawValue); basic_led_control=\(supportsBasicIndicatorControl)"
            ))
            return
        }
        guard ledSettings.responseMode.permits(next) else {
            guard helperReady, process.isRunning, next != activeIndicatorState || indicatorIlluminated else { return }
            if indicatorIlluminated, let previousRendering = activeIndicatorRendering {
                send(indicatorClearCommand(
                    commandID: nextCommandID(prefix: "indicator-policy-clear"),
                    rendering: previousRendering
                ))
            }
            activeIndicatorState = next
            activeIndicatorRendering = nil
            indicatorIlluminated = false
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNS,
                source: "social_indicator",
                state: "suppressed",
                message: "policy=\(ledSettings.responseMode.rawValue); requested_state=\(next.rawValue); brightness=\(ledSettings.brightness)"
            ))
            return
        }
        guard let nextRendering = indicatorRendering(next, at: monotonicNS) else {
            guard next != activeIndicatorState || indicatorIlluminated else { return }
            if indicatorIlluminated, let previousRendering = activeIndicatorRendering {
                send(indicatorClearCommand(
                    commandID: nextCommandID(prefix: "indicator-unsupported-clear"),
                    rendering: previousRendering
                ))
            }
            activeIndicatorState = next
            activeIndicatorRendering = nil
            indicatorIlluminated = false
            let nextSignal = ledSettings.signal(for: next)
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNS,
                source: "social_indicator",
                state: "color_unsupported_for_profile",
                message: "profile=\(deviceProfile?.rawValue ?? "unknown"); requested_state=\(next.rawValue); color=\(nextSignal.color.rawValue)"
            ))
            return
        }
        guard helperReady,
              process.isRunning,
              forceHardwareReassertion || next != activeIndicatorState || activeIndicatorRendering != nextRendering else { return }
        let nextSignal = ledSettings.signal(for: next)
        let commandID = nextCommandID(prefix: "indicator-enforce")
        if nextRendering.usesFirmwareDefault {
            if indicatorIlluminated,
               let previousRendering = activeIndicatorRendering,
               !previousRendering.usesFirmwareDefault {
                send(indicatorClearCommand(
                    commandID: "\(commandID)-clear",
                    rendering: previousRendering
                ))
            }
        } else if let command = indicatorEnforceCommand(commandID: commandID, rendering: nextRendering) {
            send(command)
        }
        activeIndicatorState = next
        activeIndicatorRendering = nextRendering
        indicatorIlluminated = true
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: monotonicNS,
            source: "social_indicator",
            state: next.rawValue,
            message: "human_meaning=\(next.humanMeaning); visual=\(indicatorInputs.visualState.rawValue); interaction=\(indicatorInputs.interactionState.rawValue); transport=\(nextRendering.usesFirmwareDefault ? "firmware_default" : nextRendering.directColor == nil ? "firmware_state" : "semantic_direct_color"); pulse_enabled=\(nextRendering.pulseEnabled); color=\(nextSignal.color.rawValue); pattern=\(nextRendering.pattern.rawValue); brightness=\(ledSettings.brightness); policy=\(ledSettings.responseMode.rawValue); command_submitted=\(!nextRendering.usesFirmwareDefault)"
        ))
    }

    private func reconcileIndicatorPalette(at monotonicNS: UInt64) {
        guard supportsIndicatorRendering, indicatorCalibrationPreset == nil else { return }
        let next = resolvedIndicatorPresentation(at: monotonicNS)
        guard ledSettings.responseMode.permits(next),
              helperReady,
              process.isRunning,
              indicatorIlluminated,
              next == activeIndicatorState,
              let activeIndicatorRendering,
              activeIndicatorRendering == indicatorRendering(next, at: monotonicNS) else {
            refreshIndicator(at: monotonicNS)
            return
        }
        guard !activeIndicatorRendering.usesFirmwareDefault else { return }
        guard activeIndicatorRendering.pattern == .steady else { return }
        let commandID = nextCommandID(prefix: "indicator-reconcile")
        if let command = indicatorReconcileCommand(commandID: commandID, rendering: activeIndicatorRendering) {
            send(command)
        }
    }

    private func indicatorRendering(
        _ state: SubconsciousIndicatorState,
        at monotonicNS: UInt64
    ) -> SOMALEDDeviceRendering? {
        guard let deviceContract else { return nil }
        let verifiedEyeContact = indicatorInputs.visualState == .eyeContact
            && eyeContactIndicatorLease.isActive(at: monotonicNS)
        return ledSettings.deviceRendering(
            for: state,
            on: deviceContract,
            eyeContactActive: verifiedEyeContact
        )
    }

    /// Face and gaze evidence arrive on different cadence paths from native
    /// tracking acknowledgements. The contact lease is the sole authority for
    /// retaining the invitation signal through those transient state updates,
    /// so an older human/exploring refresh cannot replace a live eye-contact
    /// presentation.
    private func resolvedIndicatorPresentation(at monotonicNS: UInt64) -> SubconsciousIndicatorState {
        if indicatorInputs.interactionState == .conversation {
            return .conversation
        }
        switch indicatorInputs.visualState {
        case .eyeContact:
            return eyeContactIndicatorLease.isActive(at: monotonicNS)
                ? .contactReady
                : .humanDetected
        case .humanDetected:
            return .humanDetected
        case .none:
            return .exploring
        }
    }

    private func indicatorEnforceCommand(
        commandID: String,
        rendering: SOMALEDDeviceRendering
    ) -> String? {
        guard !rendering.usesFirmwareDefault else { return nil }
        if let color = rendering.directColor {
            return "indicator_color_enforce \(commandID) \(color.rawValue) \(rendering.pattern.rawValue)"
        }
        guard let stateID = rendering.stateID else { return nil }
        return "indicator_enforce \(commandID) \(stateID) \(rendering.pattern.rawValue)"
    }

    private func indicatorReconcileCommand(
        commandID: String,
        rendering: SOMALEDDeviceRendering
    ) -> String? {
        guard !rendering.usesFirmwareDefault else { return nil }
        if let color = rendering.directColor {
            return "indicator_color_reconcile \(commandID) \(color.rawValue) \(rendering.pattern.rawValue)"
        }
        guard let stateID = rendering.stateID else { return nil }
        return "indicator_reconcile \(commandID) \(stateID) \(rendering.pattern.rawValue)"
    }

    private func indicatorClearCommand(
        commandID: String,
        rendering: SOMALEDDeviceRendering
    ) -> String {
        if rendering.usesFirmwareDefault { return "" }
        if rendering.directColor != nil {
            return "indicator_color_clear \(commandID)"
        }
        if let stateID = rendering.stateID {
            return "indicator_clear \(commandID) \(stateID)"
        }
        return ""
    }

    func calibrateIndicator(
        preset: SOMALEDFirmwarePreset?
    ) -> Result<Void, Error> {
        queue.sync {
            guard case .running = state, helperReady, process.isRunning else {
                return .failure(RuntimeError.unavailable("The local LED bridge is not ready"))
            }
            guard supportsFirmwareIndicatorPalette else {
                return .failure(RuntimeError.unavailable("This OBSBOT profile has no validated firmware indicator palette"))
            }
            let commandID = nextCommandID(prefix: "indicator-calibration")
            let nextStateID = preset?.firmwareStateID
            if let nextStateID {
                let supportsState = deviceContract?.indicatorStateIDs.values.contains(nextStateID) == true
                guard supportsState else {
                    return .failure(RuntimeError.unavailable("This indicator state is not validated for the connected OBSBOT"))
                }
            }

            if indicatorIlluminated,
               let activeIndicatorRendering,
               activeIndicatorRendering.stateID != nextStateID {
                send(indicatorClearCommand(
                    commandID: "\(commandID)-normal",
                    rendering: activeIndicatorRendering
                ))
            }
            if let indicatorCalibrationStateID,
               indicatorCalibrationStateID != nextStateID {
                send("indicator_clear \(commandID)-previous \(indicatorCalibrationStateID)")
            }

            indicatorCalibrationPreset = preset
            indicatorCalibrationStateID = nextStateID
            activeIndicatorState = nil
            activeIndicatorRendering = nil
            indicatorIlluminated = nextStateID != nil

            if let preset, let nextStateID {
                send("indicator_set \(commandID) \(nextStateID)")
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: monotonicNanoseconds(),
                    source: "social_indicator",
                    state: "calibration_active",
                    message: "preset=\(preset.rawValue); firmware_state_id=\(nextStateID); local_owner_only=true"
                ))
            } else {
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: monotonicNanoseconds(),
                    source: "social_indicator",
                    state: "calibration_ended",
                    message: "normal_state_signalling_resumed"
                ))
                refreshIndicator(at: monotonicNanoseconds())
            }
            return .success(())
        }
    }

    private func send(_ command: String) {
        let verb = command.split(separator: " ", maxSplits: 1).first.map(String.init)
        let isMotionCommand = verb.map {
            ["native_start", "external_velocity", "external_position", "external_pulse", "recenter"].contains($0)
        } ?? false
        let isBoundedCalibrationPulse = verb == "external_pulse" && allowsBoundedCalibrationPulses
        if isMotionCommand && !allowsMotorControl && !isBoundedCalibrationPulse {
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNanoseconds(),
                source: "embodiment_motor",
                state: "calibration_required",
                message: "profile=\(deviceProfile?.rawValue ?? "unknown"); command=\(verb ?? "unknown")"
            ))
            return
        }
        let isPaletteCommand = verb.map {
            [
                "indicator_set", "indicator_clear", "indicator_enforce", "indicator_reconcile",
            ].contains($0)
        } ?? false
        guard !isPaletteCommand || supportsFirmwareIndicatorPalette else { return }
        guard !command.isEmpty else { return }
        guard let data = (command + "\n").data(using: .utf8) else { return }
        try? input.write(contentsOf: data)
    }
}

private final class AudioVADFrame: @unchecked Sendable {
    let samples: [Float]
    let sampleRateHz: Double
    var continuous: Bool
    let captureNS: UInt64
    let durationNS: UInt64
    let levelDB: Double

    init(
        samples: [Float],
        sampleRateHz: Double,
        continuous: Bool,
        captureNS: UInt64,
        durationNS: UInt64,
        levelDB: Double
    ) {
        self.samples = samples
        self.sampleRateHz = sampleRateHz
        self.continuous = continuous
        self.captureNS = captureNS
        self.durationNS = durationNS
        self.levelDB = levelDB
    }
}

private final class LatestAudioVADMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: AudioVADFrame?
    private var signalPending = false
    private var accepting = true

    func publish(_ frame: AudioVADFrame) -> (shouldWake: Bool, superseded: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard accepting else { return (false, false) }
        let superseded = latest != nil
        if superseded { frame.continuous = false }
        latest = frame
        if signalPending { return (false, superseded) }
        signalPending = true
        return (true, superseded)
    }

    func take() -> AudioVADFrame? {
        lock.lock()
        defer { lock.unlock() }
        signalPending = false
        defer { latest = nil }
        return latest
    }

    func stopAccepting() {
        lock.lock()
        accepting = false
        latest = nil
        lock.unlock()
    }
}

private final class AudioVADWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "soma.subconscious.audio-vad", qos: .userInitiated)
    private let mailbox = LatestAudioVADMailbox()
    private let detector: NeuralVoiceActivityDetector
    private let stateLock = NSLock()
    private let onEvidence: (NeuralVoiceActivityEvidence, AudioVADFrame, UInt64) -> Void
    private let onError: (String) -> Void
    private var active = false
    private var errorReported = false

    let computeUnits: String
    let warmupMS: Double

    init(
        activationThreshold: Double,
        onEvidence: @escaping (NeuralVoiceActivityEvidence, AudioVADFrame, UInt64) -> Void,
        onError: @escaping (String) -> Void
    ) throws {
        detector = try NeuralVoiceActivityDetector(activationThreshold: activationThreshold)
        computeUnits = detector.computeUnits
        warmupMS = detector.warmupMS
        self.onEvidence = onEvidence
        self.onError = onError
    }

    func submit(_ frame: AudioVADFrame) -> Bool {
        let result = mailbox.publish(frame)
        guard !result.superseded else { return true }
        guard result.shouldWake else { return false }
        queue.async { [weak self] in self?.processAvailable() }
        return false
    }

    func currentActive() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return active
    }

    func stop() {
        mailbox.stopAccepting()
        queue.sync {}
    }

    private func processAvailable() {
        while let frame = mailbox.take() {
            do {
                let evidence = try detector.ingest(
                    samples: frame.samples,
                    sampleRateHz: frame.sampleRateHz,
                    continuous: frame.continuous,
                    at: frame.captureNS,
                    durationNS: frame.durationNS
                )
                for result in evidence {
                    stateLock.lock()
                    active = result.active
                    stateLock.unlock()
                    onEvidence(result, frame, monotonicNanoseconds())
                }
            } catch {
                detector.reset()
                stateLock.lock()
                active = false
                let shouldReport = !errorReported
                errorReported = true
                stateLock.unlock()
                if shouldReport { onError(error.localizedDescription) }
            }
        }
    }
}

/// Reports aggregate detector evidence without retaining any audio samples.
/// This makes a missing voice onset distinguishable from an L2 launch failure.
private final class VoiceEvidenceTelemetry: @unchecked Sendable {
    private let lock = NSLock()
    private var nextReportNS: UInt64 = 0
    private var peakProbability = 0.0
    private var peakLevelDB = -Double.infinity

    func record(
        evidence: NeuralVoiceActivityEvidence,
        frame: AudioVADFrame,
        at monotonicNS: UInt64
    ) -> String? {
        lock.lock()
        defer { lock.unlock() }

        peakProbability = max(peakProbability, evidence.probability)
        peakLevelDB = max(peakLevelDB, frame.levelDB)
        guard evidence.changed || monotonicNS >= nextReportNS else { return nil }

        let report = String(
            format: "active=%@; probability=%.3f; level_db=%.1f; peak_probability=%.3f; peak_level_db=%.1f",
            evidence.active ? "true" : "false",
            evidence.probability,
            frame.levelDB,
            peakProbability,
            peakLevelDB
        )
        nextReportNS = monotonicNS + 1_000_000_000
        peakProbability = 0
        peakLevelDB = -Double.infinity
        return report
    }
}

private final class AudioAnalyzer: @unchecked Sendable {
    private var previousAudioEndPTS: CMTime?
    private var nextDirectionAnalysisNS: UInt64 = 0
    private var lastDirection: AudioDirection = .unknown
    private let worldModel: PredictiveWorldModel
    private let publisher: BeliefPublisher
    private let writer: JSONLWriter
    private let counters: LatencyCounters
    private let directionEstimator: StereoTDOAEstimator?
    private let calibrationRecorder: TDOACalibrationRecorder?
    private let voiceWorker: AudioVADWorker
    private let speechInteraction: LocalSpeechInteractionCoordinator?
    private let liveVoiceLauncher: AppServerLiveVoiceLauncher?
    private let auditoryOnsetGate = AcousticOnsetGate()
    private let auditoryOnsetHandler: (SOMACore.AuditoryOnsetEvidence) -> Void
    private let visualSpeakerAttribution: VisualSpeakerAttributionStore?
    private var rejectedAudioFormatReported = false

    init(
        worldModel: PredictiveWorldModel,
        publisher: BeliefPublisher,
        writer: JSONLWriter,
        counters: LatencyCounters,
        voiceWorker: AudioVADWorker,
        directionEstimator: StereoTDOAEstimator?,
        calibrationRecorder: TDOACalibrationRecorder?,
        speechInteraction: LocalSpeechInteractionCoordinator?,
        liveVoiceLauncher: AppServerLiveVoiceLauncher?,
        visualSpeakerAttribution: VisualSpeakerAttributionStore? = nil,
        auditoryOnsetHandler: @escaping (SOMACore.AuditoryOnsetEvidence) -> Void
    ) {
        self.worldModel = worldModel
        self.publisher = publisher
        self.writer = writer
        self.counters = counters
        self.voiceWorker = voiceWorker
        self.directionEstimator = directionEstimator
        self.calibrationRecorder = calibrationRecorder
        self.speechInteraction = speechInteraction
        self.liveVoiceLauncher = liveVoiceLauncher
        self.visualSpeakerAttribution = visualSpeakerAttribution
        self.auditoryOnsetHandler = auditoryOnsetHandler
    }

    func ingest(_ sampleBuffer: CMSampleBuffer, at now: UInt64) {
        defer {
            counters.audioCallback(
                at: now,
                processingMS: milliseconds(from: now, to: monotonicNanoseconds())
            )
        }
        guard let audio = monoAudio(from: sampleBuffer) else {
            calibrationRecorder?.record(.rejected(.invalidInput))
            if !rejectedAudioFormatReported {
                rejectedAudioFormatReported = true
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: now,
                    source: "audio",
                    state: "input_format_rejected",
                    message: describeAudioFormat(sampleBuffer)
                ))
            }
            return
        }
        let continuous = audioPacketIsContinuous(sampleBuffer, durationNS: audio.durationNS)
        let auditoryOnset = auditoryOnsetGate.ingest(
            levelDB: audio.levelDB,
            durationNS: audio.durationNS,
            continuous: continuous,
            at: now
        )
        if auditoryOnset.triggered {
            writer.write(RuntimeEvent(
                event: "audio.onset",
                monotonicNS: now,
                source: "audio_onset",
                state: "detected",
                message: String(
                    format: "level_db=%.1f; threshold_db=%.1f; confidence=%.3f; transient=%@; latency_class=audio_callback",
                    audio.levelDB,
                    auditoryOnset.thresholdDB,
                    auditoryOnset.confidence,
                    auditoryOnset.transient ? "true" : "false"
                )
            ))
            auditoryOnsetHandler(SOMACore.AuditoryOnsetEvidence(
                monotonicNS: now >= auditoryOnset.estimatedLookbackNS
                    ? now - auditoryOnset.estimatedLookbackNS
                    : 0,
                levelDB: audio.levelDB,
                thresholdDB: auditoryOnset.thresholdDB,
                confidence: auditoryOnset.confidence,
                transient: auditoryOnset.transient
            ))
        }
        let frame = AudioVADFrame(
            samples: audio.samples,
            sampleRateHz: audio.sampleRateHz,
            continuous: continuous,
            captureNS: now,
            durationNS: audio.durationNS,
            levelDB: audio.levelDB
        )
        speechInteraction?.ingestAudio(SpeechAudioChunk(
            samples: audio.samples,
            sampleRateHz: audio.sampleRateHz,
            captureNS: now,
            durationNS: audio.durationNS,
            continuous: continuous
        ))
        liveVoiceLauncher?.ingestAudio(
            samples: audio.samples,
            sampleRateHz: audio.sampleRateHz,
            captureNS: now,
            durationNS: audio.durationNS
        )
        if voiceWorker.submit(frame) { counters.supersedeAudioVADFrame() }
        if !continuous { lastDirection = .unknown }
        let stereoOutcome = stereoSamples(from: sampleBuffer)
        if let calibrationRecorder {
            // Calibration runs alongside live VAD but must not depend on its
            // asynchronous speech lease. A direct level gate retains spoken
            // packets at turn onset; correlation remains the acceptance test.
            if audio.levelDB < -55 {
                calibrationRecorder.record(.rejected(.lowEnergy))
            } else {
                switch stereoOutcome {
                case let .samples(stereo):
                    calibrationRecorder.record(
                        StereoTDOAEstimator.assess(
                            left: stereo.left,
                            right: stereo.right,
                            sampleRateHz: stereo.sampleRateHz
                        )
                    )
                case let .rejected(reason): calibrationRecorder.record(.rejected(reason))
                }
            }
        }
        guard voiceWorker.currentActive(), now >= nextDirectionAnalysisNS else { return }
        nextDirectionAnalysisNS = now + 125_000_000
        guard case let .samples(stereo) = stereoOutcome else { return }
        guard let directionEstimator else { return }
        let direction = directionEstimator.estimate(left: stereo.left, right: stereo.right, sampleRateHz: stereo.sampleRateHz)
        guard direction.direction != .unknown,
              let lagSamples = direction.lagSamples,
              let fractionalLagSamples = direction.fractionalLagSamples,
              let delayMilliseconds = direction.delayMilliseconds,
              let correlation = direction.correlation else { return }
        let directionalBelief = worldModel.ingestAudioDirection(
            direction.direction,
            confidence: direction.confidence,
            at: now
        )
        publisher.publish(directionalBelief, reason: "audio_direction")
        visualSpeakerAttribution?.record(
            direction: direction.direction,
            confidence: direction.confidence,
            at: now
        )
        if direction.direction != lastDirection {
            lastDirection = direction.direction
            writer.write(AudioDirectionEvent(
                monotonicNS: now,
                direction: direction.direction,
                confidence: direction.confidence,
                lagSamples: lagSamples,
                fractionalLagSamples: fractionalLagSamples,
                delayMilliseconds: delayMilliseconds,
                correlation: correlation
            ))
        }
    }

    func stop() {
        voiceWorker.stop()
    }

    private func audioPacketIsContinuous(_ sampleBuffer: CMSampleBuffer, durationNS: UInt64) -> Bool {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentationTime.isValid else {
            previousAudioEndPTS = nil
            return false
        }
        defer {
            previousAudioEndPTS = CMTimeAdd(
                presentationTime,
                CMTime(value: Int64(durationNS), timescale: 1_000_000_000)
            )
        }
        guard let previousAudioEndPTS else { return false }
        let delta = CMTimeGetSeconds(CMTimeSubtract(presentationTime, previousAudioEndPTS))
        let tolerance = max(0.004, Double(durationNS) / 1_000_000_000 * 0.25)
        return delta.isFinite && abs(delta) <= tolerance
    }
}

private final class TDOACalibrationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var position: TDOACalibrationPosition = .left
    private var diagnostics = TDOACalibrationDiagnostics()

    func setPosition(_ position: TDOACalibrationPosition) {
        lock.lock()
        self.position = position
        lock.unlock()
    }

    func record(_ outcome: StereoTDOAMeasurementOutcome) {
        lock.lock()
        diagnostics.record(position: position, outcome: outcome)
        lock.unlock()
    }

    func makeCalibration() -> StereoDirectionCalibration? {
        lock.lock()
        let calibration = diagnostics.makeCalibration()
        lock.unlock()
        return calibration
    }

    func summary() -> String {
        lock.lock()
        let summary = TDOACalibrationPosition.allCases.map { position in
            let diagnostic = diagnostics.diagnostic(for: position)
            let medianLag = diagnostic.medianLagSamples.map(String.init) ?? "none"
            let fractionalLag = diagnostic.medianFractionalLagSamples.map { String(format: "%.3f", $0) } ?? "none"
            let zeroLagCorrelation = diagnostic.medianZeroLagCorrelation.map { String(format: "%.3f", $0) } ?? "none"
            return "\(position.rawValue){attempts=\(diagnostic.attempts),accepted=\(diagnostic.accepted),eligible=\(diagnostic.eligible),lag_median=\(medianLag),fractional_lag_median=\(fractionalLag),zero_lag_correlation_median=\(zeroLagCorrelation),ambiguous=\(diagnostic.ambiguous),low_energy=\(diagnostic.lowEnergy),invalid_input=\(diagnostic.invalidInput)}"
        }.joined(separator: ";")
        lock.unlock()
        return summary
    }
}

private final class ANEObjectDetector: @unchecked Sendable {
    let computeUnits: String
    let warmupMS: Double
    let confidenceThreshold: Double
    let personConfidenceThreshold: Double
    private let model: MLModel
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    init(confidenceThreshold: Double, personConfidenceThreshold: Double) throws {
        self.confidenceThreshold = confidenceThreshold
        self.personConfidenceThreshold = personConfidenceThreshold
        let modelURL: URL
        if let compiledURL = somaSubconsciousResourceBundle.url(
            forResource: "YOLO11n",
            withExtension: "mlpackage"
        ) {
            modelURL = compiledURL
        } else {
            throw RuntimeError.configuration("Bundled Core ML object detector is missing")
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        computeUnits = "cpu_and_neural_engine"
        let compiledURL = try MLModel.compileModel(at: modelURL)
        let loadedModel = try MLModel(contentsOf: compiledURL, configuration: configuration)
        model = loadedModel
        let startedNS = monotonicNanoseconds()
        try Self.warmUp(model)
        warmupMS = milliseconds(from: startedNS, to: monotonicNanoseconds())
    }

    /// COCO 80 class names in YOLO index order (class 0 = person).
    private static let cocoClassNames: [String] = [
        "person", "bicycle", "car", "motorcycle", "airplane", "bus", "train", "truck", "boat", "traffic light",
        "fire hydrant", "stop sign", "parking meter", "bench", "bird", "cat", "dog", "horse", "sheep", "cow",
        "elephant", "bear", "zebra", "giraffe", "backpack", "umbrella", "handbag", "tie", "suitcase", "frisbee",
        "skis", "snowboard", "sports ball", "kite", "baseball bat", "baseball glove", "skateboard", "surfboard", "tennis racket", "bottle",
        "wine glass", "cup", "fork", "knife", "spoon", "bowl", "banana", "apple", "sandwich", "orange",
        "broccoli", "carrot", "hot dog", "pizza", "donut", "cake", "chair", "couch", "potted plant", "bed",
        "dining table", "toilet", "tv", "laptop", "mouse", "remote", "keyboard", "cell phone", "microwave", "oven",
        "toaster", "sink", "refrigerator", "book", "clock", "vase", "scissors", "teddy bear", "hair drier", "toothbrush",
    ]

    func detect(in pixelBuffer: CVPixelBuffer) throws -> [VisualObservation] {
        // YOLO11n (COCO, NMS built in): 640x640 input, outputs
        // coordinates [N,4] xywh (normalized) and confidence [N,80].
        // MLFeatureValue .scaleFill preserves normalized coordinates 1:1
        // (the whole frame maps to 0...1 on both axes), so the raw xywh
        // is already top-left in the source frame. Store it as-is; any
        // extra flip/un-stretch produced a bottom-left box that moved
        // opposite to the tracked person.
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return [] }
        let scale = 640.0 / Double(max(width, height))
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = ciContext.createCGImage(scaled, from: scaled.extent) else { return [] }
        guard let constraint = model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint else {
            return []
        }
        let input = try MLFeatureValue(
            cgImage: cg,
            constraint: constraint,
            options: [.cropAndScale: VNImageCropAndScaleOption.scaleFill.rawValue]
        )
        // Pass the configured thresholds into the model's built-in NMS:
        // without them the model runs at its default 0.25 and emits
        // spurious low-confidence boxes (phantom persons).
        let prediction = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "image": input,
            "confidenceThreshold": MLFeatureValue(double: personConfidenceThreshold),
            "iouThreshold": MLFeatureValue(double: 0.7),
        ]))
        guard let coords = prediction.featureValue(for: "coordinates")?.multiArrayValue,
              let confidences = prediction.featureValue(for: "confidence")?.multiArrayValue else {
            return []
        }
        let count = coords.shape[0].intValue
        let classCount = confidences.shape[1].intValue
        guard count > 0, coords.shape.count >= 2, coords.shape[1].intValue >= 4,
              classCount >= 1 else {
            return []
        }
        var observations: [VisualObservation] = []
        observations.reserveCapacity(count)
        for index in 0..<count {
            var bestClass = 0
            var bestConfidence = 0.0
            for classIndex in 0..<classCount {
                let value = confidences[index * classCount + classIndex].doubleValue
                if value > bestConfidence {
                    bestConfidence = value
                    bestClass = classIndex
                }
            }
            let minimum = bestClass == 0 ? personConfidenceThreshold : confidenceThreshold
            guard bestConfidence >= minimum else { continue }
            let x = coords[index * 4].doubleValue
            let y = coords[index * 4 + 1].doubleValue
            let w = coords[index * 4 + 2].doubleValue
            let h = coords[index * 4 + 3].doubleValue
            // Reject degenerate boxes: the NMS head occasionally emits
            // zero-size or out-of-range coordinates that would otherwise
            // become phantom observations.
            guard x >= 0, y >= 0, w > 0.02, h > 0.02,
                  x + w <= 1.05, y + h <= 1.05 else { continue }
            observations.append(VisualObservation(
                rect: SOMACore.NormalizedRect(
                    x: x,
                    y: y,
                    width: w,
                    height: h
                ),
                confidence: bestConfidence,
                source: .neuralDetector,
                kind: bestClass == 0 ? .human : .object,
                label: bestClass < Self.cocoClassNames.count ? Self.cocoClassNames[bestClass] : "class\(bestClass)"
            ))
        }
        return observations
    }

    private static func warmUp(_ model: MLModel) throws {
        var pixelBuffer: CVPixelBuffer?
        let attributes = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ] as CFDictionary
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            640,
            640,
            kCVPixelFormatType_32BGRA,
            attributes,
            &pixelBuffer
        ) == kCVReturnSuccess,
              let pixelBuffer else {
            throw RuntimeError.configuration("Cannot allocate Core ML warmup frame")
        }
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let cg = context.createCGImage(ci, from: ci.extent),
              let constraint = model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint else {
            throw RuntimeError.configuration("Cannot prepare Core ML warmup frame")
        }
        let input = try MLFeatureValue(
            cgImage: cg,
            constraint: constraint,
            options: [.cropAndScale: VNImageCropAndScaleOption.scaleFill.rawValue]
        )
        _ = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": input]))
    }
}

private final class ANEFaceDetector: @unchecked Sendable {
    private struct Anchor {
        let x: Double
        let y: Double
    }

    let computeUnits: String
    let warmupMS: Double
    private let model: VNCoreMLModel
    private let anchors: [Anchor]
    /// Post-softmax face confidence bar. The bundled short-range model was
    /// tuned at 0.75, but appearance changes (new haircut, glasses, mask)
    /// routinely push a real face below it while System Vision landmarks
    /// still verify the same rect. The verifier is the motor gate, so this
    /// bar only needs to admit candidates worth verifying, not reject noise.
    private let confidenceThreshold: Double

    init() throws {
        guard let modelURL = somaSubconsciousResourceBundle.url(
            forResource: "BlazeFaceShortRange",
            withExtension: "mlpackage"
        ) else {
            throw RuntimeError.configuration("Bundled Core ML face detector is missing")
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        computeUnits = "cpu_and_neural_engine"
        let compiledURL = try MLModel.compileModel(at: modelURL)
        let loadedModel = try MLModel(contentsOf: compiledURL, configuration: configuration)
        model = try VNCoreMLModel(for: loadedModel)
        anchors = Self.makeAnchors()
        confidenceThreshold = somaEnvDouble("SOMA_BLAZE_FACE_THRESHOLD", default: 0.5)
        let startedNS = monotonicNanoseconds()
        try Self.warmUp(model: model, anchors: anchors)
        warmupMS = milliseconds(from: startedNS, to: monotonicNanoseconds())
    }

    func detect(in pixelBuffer: CVPixelBuffer) throws -> [VisualObservation] {
        try Self.detect(in: pixelBuffer, model: model, anchors: anchors, confidenceThreshold: confidenceThreshold)
    }

    private static func warmUp(model: VNCoreMLModel, anchors: [Anchor]) throws {
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            128,
            128,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        ) == kCVReturnSuccess,
              let pixelBuffer else {
            throw RuntimeError.configuration("Cannot allocate Core ML face warmup frame")
        }
        _ = try detect(in: pixelBuffer, model: model, anchors: anchors, confidenceThreshold: 0.5)
    }

    private static func detect(in pixelBuffer: CVPixelBuffer, model: VNCoreMLModel, anchors: [Anchor], confidenceThreshold: Double) throws -> [VisualObservation] {
        let request = VNCoreMLRequest(model: model)
        // Faces can enter from either edge while the gimbal searches or
        // follows. Center-cropping a 16:9 feed to the square model input
        // discards those side bands before the detector can see them.
        request.imageCropAndScaleOption = .scaleFit
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try handler.perform([request])
        let features = request.results?.compactMap { $0 as? VNCoreMLFeatureValueObservation } ?? []
        let featureNames = features.map(\.featureName).joined(separator: ",")
        guard let rawBoxes = features.first(where: { $0.featureName == "raw_boxes" })?.featureValue.multiArrayValue,
              let rawScores = features.first(where: { $0.featureName == "raw_scores" })?.featureValue.multiArrayValue,
              isFloatingPointArray(rawBoxes),
              isFloatingPointArray(rawScores),
              anchors.count == 896 else {
            throw RuntimeError.configuration("Unexpected Core ML face detector output: \(featureNames)")
        }

        let boxStrides = rawBoxes.strides.map(\.intValue)
        let scoreStrides = rawScores.strides.map(\.intValue)
        guard boxStrides.count == 3, scoreStrides.count == 3 else {
            throw RuntimeError.configuration("Unexpected Core ML face detector output layout")
        }

        let input = SOMACore.NormalizedSquareScaleFit(
            sourceWidth: CVPixelBufferGetWidth(pixelBuffer),
            sourceHeight: CVPixelBufferGetHeight(pixelBuffer)
        )
        var candidates: [VisualObservation] = []
        for index in anchors.indices {
            let scoreOffset = index * scoreStrides[1]
            let score = sigmoid(Double(value(in: rawScores, at: scoreOffset)))
            guard score >= confidenceThreshold else { continue }
            let boxOffset = index * boxStrides[1]
            let xCenter = Double(value(in: rawBoxes, at: boxOffset)) / 128 + anchors[index].x
            let yCenter = Double(value(in: rawBoxes, at: boxOffset + boxStrides[2])) / 128 + anchors[index].y
            let width = Double(value(in: rawBoxes, at: boxOffset + boxStrides[2] * 2)) / 128
            let height = Double(value(in: rawBoxes, at: boxOffset + boxStrides[2] * 3)) / 128
            guard width > 0, height > 0 else { continue }

            guard let rect = input.sourceRect(for: SOMACore.NormalizedRect(
                x: xCenter - width / 2,
                y: yCenter - height / 2,
                width: width,
                height: height
            )), rect.width > 0.02, rect.height > 0.02 else { continue }
            // BlazeFace predicts right eye, left eye, nose, mouth, and ear
            // keypoints after its four box values. A high box score can occur
            // on cable texture; that texture does not normally preserve the
            // bilateral eye -> nose -> mouth geometry of a face.
            func mappedPoint(_ x: Double, _ y: Double) -> (x: Double, y: Double)? {
                input.sourcePoint(x: x, y: y)
            }
            let facePoints = (0..<4).compactMap { pointIndex in
                mappedPoint(
                    Double(value(in: rawBoxes, at: boxOffset + boxStrides[2] * (4 + pointIndex * 2))) / 128 + anchors[index].x,
                    Double(value(in: rawBoxes, at: boxOffset + boxStrides[2] * (5 + pointIndex * 2))) / 128 + anchors[index].y
                )
            }
            guard facePoints.count == 4 else { continue }
            guard hasPlausibleFaceGeometry(
                rightEye: facePoints[0],
                leftEye: facePoints[1],
                nose: facePoints[2],
                mouth: facePoints[3],
                in: rect
            ) else { continue }
            candidates.append(VisualObservation(
                rect: rect,
                confidence: score,
                source: .neuralFaceDetector,
                kind: .human,
                label: "face",
                isActionEligible: true
            ))
        }
        return suppressOverlaps(candidates)
    }

    private static func hasPlausibleFaceGeometry(
        rightEye: (x: Double, y: Double),
        leftEye: (x: Double, y: Double),
        nose: (x: Double, y: Double),
        mouth: (x: Double, y: Double),
        in rect: SOMACore.NormalizedRect
    ) -> Bool {
        let horizontalInset = rect.width * 0.28
        let verticalInset = rect.height * 0.28
        let containsWithTolerance: ((x: Double, y: Double)) -> Bool = { point in
            point.x >= rect.x - horizontalInset
                && point.x <= rect.x + rect.width + horizontalInset
                && point.y >= rect.y - verticalInset
                && point.y <= rect.y + rect.height + verticalInset
        }
        guard [rightEye, leftEye, nose, mouth].allSatisfy(containsWithTolerance) else { return false }
        let eyeSeparation = abs(rightEye.x - leftEye.x)
        let eyeMidX = (rightEye.x + leftEye.x) / 2
        let eyeY = (rightEye.y + leftEye.y) / 2
        return eyeSeparation >= rect.width * 0.12
            && eyeSeparation <= rect.width * 1.20
            && nose.y > eyeY + rect.height * 0.04
            && mouth.y > nose.y + rect.height * 0.04
            && abs(nose.x - eyeMidX) <= rect.width * 0.45
            && abs(mouth.x - nose.x) <= rect.width * 0.55
    }

    private static func makeAnchors() -> [Anchor] {
        let strides = [8, 16, 16, 16]
        var anchors: [Anchor] = []
        var layer = 0
        while layer < strides.count {
            var sameStrideLayers = 0
            while layer + sameStrideLayers < strides.count,
                  strides[layer + sameStrideLayers] == strides[layer] {
                sameStrideLayers += 1
            }
            let grid = 128 / strides[layer]
            for y in 0..<grid {
                for x in 0..<grid {
                    for _ in 0..<(sameStrideLayers * 2) {
                        anchors.append(Anchor(x: (Double(x) + 0.5) / Double(grid), y: (Double(y) + 0.5) / Double(grid)))
                    }
                }
            }
            layer += sameStrideLayers
        }
        return anchors
    }

    private static func isFloatingPointArray(_ array: MLMultiArray) -> Bool {
        array.dataType == .float32 || array.dataType == .float16
    }

    private static func value(in array: MLMultiArray, at offset: Int) -> Float {
        if array.dataType == .float16 {
            return Float(array.dataPointer.bindMemory(to: Float16.self, capacity: offset + 1)[offset])
        }
        return array.dataPointer.bindMemory(to: Float.self, capacity: offset + 1)[offset]
    }

    private static func suppressOverlaps(_ candidates: [VisualObservation]) -> [VisualObservation] {
        let sorted = candidates.sorted { $0.confidence > $1.confidence }
        return sorted.reduce(into: []) { accepted, candidate in
            guard !accepted.contains(where: { intersectionOverUnion($0.rect, candidate.rect) > 0.3 }) else { return }
            accepted.append(candidate)
        }
    }

    private static func intersectionOverUnion(_ lhs: SOMACore.NormalizedRect, _ rhs: SOMACore.NormalizedRect) -> Double {
        let x1 = max(lhs.x, rhs.x)
        let y1 = max(lhs.y, rhs.y)
        let x2 = min(lhs.x + lhs.width, rhs.x + rhs.width)
        let y2 = min(lhs.y + lhs.height, rhs.y + rhs.height)
        let intersection = max(0, x2 - x1) * max(0, y2 - y1)
        let union = lhs.width * lhs.height + rhs.width * rhs.height - intersection
        return union > 0 ? intersection / union : 0
    }

    private static func sigmoid(_ value: Double) -> Double {
        1 / (1 + exp(-min(max(value, -100), 100)))
    }
}

/// System objectness proposes visually distinct but unlabelled regions. It is
/// deliberately separate from the COCO classifier, so it can corroborate a
/// label without treating that label as ground truth.
private final class SystemSaliencyDetector: @unchecked Sendable {
    func detect(in pixelBuffer: CVPixelBuffer) throws -> [VisualObservation] {
        let request = VNGenerateObjectnessBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try handler.perform([request])
        guard let result = request.results?.first as? VNSaliencyImageObservation else { return [] }
        return (result.salientObjects ?? []).compactMap { region in
            let box = region.boundingBox
            let rect = SOMACore.NormalizedRect(
                x: box.origin.x,
                y: 1 - box.origin.y - box.size.height,
                width: box.size.width,
                height: box.size.height
            )
            guard rect.width * rect.height >= 0.01 else { return nil }
            return VisualObservation(
                rect: rect,
                confidence: Double(region.confidence),
                source: .systemSaliency,
                kind: .unknown
            )
        }
    }
}

/// System Vision landmarks independently corroborate an ANE face. A face
/// rectangle alone is too permissive around cables and textured objects; a
/// landmark result must contain actual facial feature points before it can
/// promote a face candidate. They are transient observations only; no pixels
/// or landmark data are written.
private struct SystemFaceEvidence: Sendable {
    let rect: SOMACore.NormalizedRect
    let gazeState: SOMACore.VisualGazeEvidence
    let directGazeConfidence: Double
    /// Raw Vision gaze features for diagnostics. Kept separate from the boolean
    /// so the live trace can reveal why a face is (or is not) contact-ready
    /// without re-deriving them.
    let yaw: Double?
    let pitch: Double?
    let pupilOffsetX: Double?
    let pupilOffsetY: Double?
    let signedPupilOffsetY: Double?
    let meanEyeAperture: Double?
    let mouthAperture: Double?
    let alignment: FaceAlignmentEvidence

    var directedEyeContact: Bool { gazeState == .direct }

    func withGazeState(_ gazeState: SOMACore.VisualGazeEvidence) -> Self {
        Self(
            rect: rect,
            gazeState: gazeState,
            directGazeConfidence: directGazeConfidence,
            yaw: yaw,
            pitch: pitch,
            pupilOffsetX: pupilOffsetX,
            pupilOffsetY: pupilOffsetY,
            signedPupilOffsetY: signedPupilOffsetY,
            meanEyeAperture: meanEyeAperture,
            mouthAperture: mouthAperture,
            alignment: alignment
        )
    }
}

private struct VisualSpeakerFrameEvidence: Sendable {
    let rect: SOMACore.NormalizedRect
    let gazeState: SOMACore.VisualGazeEvidence
    let mouthAperture: Double?
}

private struct VisualSpeakerAttributionSnapshot: Sendable {
    let evidence: AudioVisualSpeakerEvidence
    let assessment: AudioVisualSpeakerAssessment
    let directContactObservedNS: UInt64?
    let directContactContradictedNS: UInt64?
    let speakerEvidenceObservedNS: UInt64?
}

private struct VisualSpeakerGazeUpdate: Sendable {
    let targetID: String
    let state: SOMACore.VisualGazeEvidence
    let observedNS: UInt64
}

private final class RecentAcousticOnsetStore: @unchecked Sendable {
    private let lock = NSLock()
    private var onsets: [UInt64] = []
    private var lastVoiceOffsetNS: UInt64?
    private let retentionNS: UInt64 = 2_000_000_000

    func record(_ evidence: SOMACore.AuditoryOnsetEvidence) {
        lock.lock()
        onsets.append(evidence.monotonicNS)
        prune(at: evidence.monotonicNS)
        lock.unlock()
    }

    func resolve(classifiedWindowStartNS: UInt64, classifiedWindowEndNS: UInt64) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        prune(at: classifiedWindowEndNS)
        let windowDurationNS = classifiedWindowEndNS >= classifiedWindowStartNS
            ? classifiedWindowEndNS - classifiedWindowStartNS
            : 0
        let previousWindowStartNS = classifiedWindowStartNS >= windowDurationNS
            ? classifiedWindowStartNS - windowDurationNS
            : 0
        let lowerBound = max(previousWindowStartNS, lastVoiceOffsetNS ?? 0)
        let acousticOnset = onsets.last {
            $0 >= lowerBound && $0 <= classifiedWindowEndNS
        }
        return AudioVisualEpisodeEvidence.resolvedOnset(
            classifiedWindowStartNS: classifiedWindowStartNS,
            classifiedWindowEndNS: classifiedWindowEndNS,
            acousticOnsetNS: acousticOnset,
            earliestAllowedNS: lowerBound
        )
    }

    func recordVoiceOffset(at monotonicNS: UInt64) {
        lock.lock()
        lastVoiceOffsetNS = monotonicNS
        prune(at: monotonicNS)
        lock.unlock()
    }

    private func prune(at monotonicNS: UInt64) {
        onsets.removeAll {
            monotonicNS >= $0 && monotonicNS - $0 > retentionNS
        }
    }
}

/// Keeps only a short scalar audiovisual window. No pixels, audio, landmark
/// arrays, or voiceprints are retained; the window exists solely to decide
/// whether a VAD onset plausibly belongs to the currently observed face.
private final class VisualSpeakerAttributionStore: @unchecked Sendable {
    private struct Sample {
        let rect: SOMACore.NormalizedRect
        let gazeState: SOMACore.VisualGazeEvidence
        let mouthAperture: Double?
        let observedNS: UInt64
    }

    private struct DirectionSample {
        let direction: AudioDirection
        let confidence: Double
        let observedNS: UInt64
    }

    private struct Episode {
        let targetID: String
        let onsetNS: UInt64
        let baselineMouthAperture: Double?
        var targetRect: SOMACore.NormalizedRect
    }

    private let lock = NSLock()
    private var samples: [Sample] = []
    private var direction: DirectionSample?
    private var episode: Episode?
    private let retentionNS: UInt64 = 1_200_000_000
    // The verifier runs at up to 12 Hz. Three capture intervals absorb normal
    // scheduling jitter without letting an older gaze state authorize a new
    // acoustic episode.
    private let maximumGazeAgeAtOnsetNS: UInt64 = 250_000_000

    func record(
        _ faces: [VisualSpeakerFrameEvidence],
        at monotonicNS: UInt64
    ) -> VisualSpeakerGazeUpdate? {
        lock.lock()
        defer { lock.unlock() }
        prune(at: monotonicNS)
        samples.append(contentsOf: faces.map {
            Sample(
                rect: $0.rect,
                gazeState: $0.gazeState,
                mouthAperture: $0.mouthAperture,
                observedNS: monotonicNS
            )
        })
        guard let episode,
              let current = faces
                .filter({ Self.matches($0.rect, episode.targetRect) })
                .max(by: {
                    Self.overlap($0.rect, episode.targetRect)
                        < Self.overlap($1.rect, episode.targetRect)
                }) else {
            return nil
        }
        return VisualSpeakerGazeUpdate(
            targetID: episode.targetID,
            state: current.gazeState,
            observedNS: monotonicNS
        )
    }

    func record(direction: AudioDirection, confidence: Double, at monotonicNS: UInt64) {
        lock.lock()
        self.direction = DirectionSample(
            direction: direction,
            confidence: min(max(confidence, 0), 1),
            observedNS: monotonicNS
        )
        lock.unlock()
    }

    func beginEpisode(
        targetID: String?,
        targetRect: SOMACore.NormalizedRect?,
        voiceConfidence: Double,
        at onsetNS: UInt64
    ) -> VisualSpeakerAttributionSnapshot {
        lock.lock()
        defer { lock.unlock() }
        prune(at: onsetNS)
        guard let targetID, let targetRect else {
            episode = nil
            let evidence = AudioVisualSpeakerEvidence(
                faceVisible: false,
                directGaze: false,
                mouthMotion: nil,
                mouthSampleCount: 0,
                directionMatchesFace: nil,
                voiceConfidence: voiceConfidence
            )
            return .init(
                evidence: evidence,
                assessment: AudioVisualSpeakerAttribution.assess(evidence),
                directContactObservedNS: nil,
                directContactContradictedNS: nil,
                speakerEvidenceObservedNS: nil
            )
        }
        let onsetFaceSamples = samples.filter {
            onsetNS >= $0.observedNS
                && onsetNS - $0.observedNS <= maximumGazeAgeAtOnsetNS
                && Self.matches($0.rect, targetRect)
        }
        let latestFaceSample = onsetFaceSamples.max { $0.observedNS < $1.observedNS }
        let directGaze = latestFaceSample.map {
            $0.gazeState == .direct
                && onsetNS - $0.observedNS <= maximumGazeAgeAtOnsetNS
        } ?? false
        episode = Episode(
            targetID: targetID,
            onsetNS: onsetNS,
            baselineMouthAperture: latestFaceSample?.mouthAperture,
            targetRect: targetRect
        )
        let evidence = AudioVisualSpeakerEvidence(
            faceVisible: latestFaceSample != nil,
            directGaze: directGaze,
            mouthMotion: nil,
            mouthSampleCount: latestFaceSample?.mouthAperture == nil ? 0 : 1,
            directionMatchesFace: nil,
            voiceConfidence: voiceConfidence
        )
        return .init(
            evidence: evidence,
            assessment: AudioVisualSpeakerAttribution.assess(evidence),
            directContactObservedNS: directGaze ? latestFaceSample?.observedNS : nil,
            directContactContradictedNS: latestFaceSample?.gazeState == .averted
                ? latestFaceSample?.observedNS
                : nil,
            speakerEvidenceObservedNS: nil
        )
    }

    func assessCurrentEpisode(
        targetID: String?,
        targetRect: SOMACore.NormalizedRect?,
        voiceConfidence: Double,
        at monotonicNS: UInt64
    ) -> VisualSpeakerAttributionSnapshot {
        lock.lock()
        defer { lock.unlock() }
        prune(at: monotonicNS)
        guard let episode,
              targetID == episode.targetID,
              let targetRect,
              monotonicNS >= episode.onsetNS else {
            let evidence = AudioVisualSpeakerEvidence(
                faceVisible: false,
                directGaze: false,
                mouthMotion: nil,
                mouthSampleCount: 0,
                directionMatchesFace: nil,
                voiceConfidence: voiceConfidence
            )
            return .init(
                evidence: evidence,
                assessment: AudioVisualSpeakerAttribution.assess(evidence),
                directContactObservedNS: nil,
                directContactContradictedNS: nil,
                speakerEvidenceObservedNS: nil
            )
        }
        self.episode?.targetRect = targetRect
        let postOnsetSamples = samples.filter {
            $0.observedNS > episode.onsetNS
                && $0.observedNS <= monotonicNS
                && Self.matches($0.rect, targetRect)
        }
        let postOnsetApertures = postOnsetSamples.compactMap(\.mouthAperture)
        let apertures = [episode.baselineMouthAperture].compactMap { $0 } + postOnsetApertures
        let mouthMotion = AudioVisualEpisodeEvidence.mouthMotion(
            baseline: episode.baselineMouthAperture,
            postOnsetApertures: postOnsetApertures
        )
        let directionMatchesFace: Bool?
        let directionEvidenceNS: UInt64?
        if let direction,
           direction.confidence >= 0.45,
           AudioVisualEpisodeEvidence.belongsToCurrentEpisode(
                observedNS: direction.observedNS,
                onsetNS: episode.onsetNS,
                nowNS: monotonicNS,
                maximumAgeNS: 500_000_000
           ),
           direction.direction != .unknown {
            let expected: AudioDirection
            if targetRect.centerX < 0.38 {
                expected = .left
            } else if targetRect.centerX > 0.62 {
                expected = .right
            } else {
                expected = .center
            }
            directionMatchesFace = direction.direction == expected
            directionEvidenceNS = directionMatchesFace == true
                ? direction.observedNS
                : nil
        } else {
            directionMatchesFace = nil
            directionEvidenceNS = nil
        }
        let latestGaze = postOnsetSamples.max { $0.observedNS < $1.observedNS }
        let latestDirectGaze = latestGaze?.gazeState == .direct
        let latestContradiction = latestGaze?.gazeState == .averted ? latestGaze : nil
        let latestMouthEvidenceNS = mouthMotion.map { motion in
            motion >= 0.18 && apertures.count >= 3
                ? postOnsetSamples.compactMap { sample in
                    sample.mouthAperture == nil ? nil : sample.observedNS
                }.max()
                : nil
        } ?? nil
        let speakerEvidenceObservedNS = [directionEvidenceNS, latestMouthEvidenceNS]
            .compactMap { $0 }
            .max()
        let evidence = AudioVisualSpeakerEvidence(
            faceVisible: !postOnsetSamples.isEmpty,
            directGaze: latestDirectGaze,
            mouthMotion: mouthMotion,
            mouthSampleCount: apertures.count,
            directionMatchesFace: directionMatchesFace,
            voiceConfidence: voiceConfidence
        )
        return .init(
            evidence: evidence,
            assessment: AudioVisualSpeakerAttribution.assess(evidence),
            // Contact authorizes the opening only when captured at or before
            // acoustic onset. Post-onset gaze still enriches attribution but
            // cannot retroactively create the opening condition.
            directContactObservedNS: nil,
            directContactContradictedNS: latestContradiction?.observedNS,
            speakerEvidenceObservedNS: speakerEvidenceObservedNS
        )
    }

    func endEpisode() {
        lock.lock()
        episode = nil
        lock.unlock()
    }

    private func prune(at monotonicNS: UInt64) {
        samples.removeAll {
            monotonicNS >= $0.observedNS && monotonicNS - $0.observedNS > retentionNS
        }
        if let direction,
           monotonicNS >= direction.observedNS,
           monotonicNS - direction.observedNS > retentionNS {
            self.direction = nil
        }
    }

    private static func matches(
        _ lhs: SOMACore.NormalizedRect,
        _ rhs: SOMACore.NormalizedRect
    ) -> Bool {
        let x1 = max(lhs.x, rhs.x)
        let y1 = max(lhs.y, rhs.y)
        let x2 = min(lhs.x + lhs.width, rhs.x + rhs.width)
        let y2 = min(lhs.y + lhs.height, rhs.y + rhs.height)
        let intersection = max(0, x2 - x1) * max(0, y2 - y1)
        let union = lhs.width * lhs.height + rhs.width * rhs.height - intersection
        if union > 0, intersection / union >= 0.10 { return true }
        return hypot(lhs.centerX - rhs.centerX, lhs.centerY - rhs.centerY) <= 0.14
    }

    private static func overlap(
        _ lhs: SOMACore.NormalizedRect,
        _ rhs: SOMACore.NormalizedRect
    ) -> Double {
        let x1 = max(lhs.x, rhs.x)
        let y1 = max(lhs.y, rhs.y)
        let x2 = min(lhs.x + lhs.width, rhs.x + rhs.width)
        let y2 = min(lhs.y + lhs.height, rhs.y + rhs.height)
        let intersection = max(0, x2 - x1) * max(0, y2 - y1)
        let union = lhs.width * lhs.height + rhs.width * rhs.height - intersection
        return union > 0 ? intersection / union : 0
    }
}

private final class LiveVoiceSpeakerEpisodeRuntime: @unchecked Sendable {
    private let lock = NSLock()
    private var gate = LiveVoiceSpeakerEpisodeGate()

    func observe(
        active: Bool,
        trackedFaceID: String?,
        evidence: AudioVisualSpeakerEvidence,
        assessment: AudioVisualSpeakerAssessment,
        directContactObservedNS: UInt64? = nil,
        directContactContradictedNS: UInt64? = nil,
        speakerEvidenceObservedNS: UInt64? = nil,
        voiceWindowObservedNS: UInt64? = nil,
        episodeOnsetNS: UInt64? = nil,
        at monotonicNS: UInt64
    ) -> LiveVoiceSpeakerEpisodeObservation {
        lock.lock()
        defer { lock.unlock() }
        return gate.observe(
            active: active,
            trackedFaceID: trackedFaceID,
            evidence: evidence,
            assessment: assessment,
            directContactObservedNS: directContactObservedNS,
            directContactContradictedNS: directContactContradictedNS,
            speakerEvidenceObservedNS: speakerEvidenceObservedNS,
            voiceWindowObservedNS: voiceWindowObservedNS,
            episodeOnsetNS: episodeOnsetNS,
            at: monotonicNS
        )
    }


    func observeGaze(
        _ state: SOMACore.VisualGazeEvidence,
        trackedFaceID: String,
        observedNS: UInt64,
        at monotonicNS: UInt64
    ) -> LiveVoiceSpeakerEpisodeObservation {
        lock.lock()
        defer { lock.unlock() }
        return gate.observeGaze(
            state,
            trackedFaceID: trackedFaceID,
            observedNS: observedNS,
            at: monotonicNS
        )
    }
}

private final class SystemFaceVerifier: @unchecked Sendable {
    /// Scales the pupil-centering thresholds that decide directed eye contact.
    /// 1.0 = default (0.60 X / 0.50 Y). Lower = stricter (pupil must be more
    /// centered); higher = more lenient.
    private let pupilCenteringThreshold: Double
    private let expectedDirectPupilOffsetY: Double
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    init(
        pupilCenteringThreshold: Double = 1.0,
        expectedDirectPupilOffsetY: Double = 0
    ) {
        self.pupilCenteringThreshold = min(max(pupilCenteringThreshold, 0.1), 2.0)
        self.expectedDirectPupilOffsetY = min(max(expectedDirectPupilOffsetY, -0.35), 0.35)
    }

    /// VNDetectFaceLandmarksRequest fails on this camera's full-resolution
    /// frames (0 detections at 1920x1080/1280x720, works at <=800px wide).
    /// Downscale before detection; boundingBox/landmarks are normalized so
    /// results remain valid at any scale.
    func scaledCGImage(from pixelBuffer: CVPixelBuffer, maxWidth: Int = 640) -> CGImage? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return nil }
        guard width > maxWidth else { return nil }
        let scale = Double(maxWidth) / Double(width)
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return ciContext.createCGImage(scaled, from: scaled.extent)
    }

    /// Landmark discovery needs a small whole-frame image on this camera, but
    /// that representation leaves too few pixels for a trustworthy pupil
    /// measurement. Once a face is located, repeat only the gaze measurement
    /// on its original-resolution crop.
    private func faceCropCGImage(
        from pixelBuffer: CVPixelBuffer,
        rect: SOMACore.NormalizedRect,
        maxWidth: Int = 640
    ) -> CGImage? {
        let source = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = source.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        let faceWidth = CGFloat(rect.width) * extent.width
        let faceHeight = CGFloat(rect.height) * extent.height
        guard faceWidth > 0, faceHeight > 0 else { return nil }

        // Core Image uses a bottom-left origin, while the perception pipeline
        // uses a top-left normalized rectangle.
        let faceX = CGFloat(rect.x) * extent.width
        let faceY = (1 - CGFloat(rect.y) - CGFloat(rect.height)) * extent.height
        let horizontalPadding = faceWidth * 0.55
        let verticalPadding = faceHeight * 0.70
        let crop = CGRect(
            x: faceX - horizontalPadding,
            y: faceY - verticalPadding,
            width: faceWidth + horizontalPadding * 2,
            height: faceHeight + verticalPadding * 2
        ).intersection(extent)
        guard !crop.isNull, crop.width >= 40, crop.height >= 40 else { return nil }

        let cropped = source.cropped(to: crop)
        let scale = min(1, CGFloat(maxWidth) / crop.width)
        let rendered = cropped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return ciContext.createCGImage(rendered, from: rendered.extent)
    }

    func detect(in pixelBuffer: CVPixelBuffer) -> [SystemFaceEvidence] {
        let faceRequest = VNDetectFaceLandmarksRequest()
        let handler: VNImageRequestHandler
        if let scaled = scaledCGImage(from: pixelBuffer) {
            handler = VNImageRequestHandler(cgImage: scaled, options: [:])
        } else {
            handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        }
        guard (try? handler.perform([faceRequest])) != nil else { return [] }
        return (faceRequest.results ?? []).compactMap { observation in
            guard let landmarks = observation.landmarks,
                  hasFacialFeatureSet(landmarks) else {
                return nil
            }
            // Vision's boundingBox uses a bottom-left origin; the rest of the
            // pipeline (BlazeFace, YOLO, SceneField, FaceConfirmationLease)
            // uses top-left. Flip Y here or verification never matches the
            // ANE face candidate whenever the face leaves the vertical center.
            let visionBox = observation.boundingBox
            let rect = SOMACore.NormalizedRect(
                x: visionBox.origin.x,
                y: 1 - visionBox.origin.y - visionBox.size.height,
                width: visionBox.size.width,
                height: visionBox.size.height
            )
            guard let alignment = alignmentEvidence(landmarks: landmarks, rect: rect) else {
                return nil
            }
            let wholeFrameGaze = gazeAssessment(
                observation: observation,
                landmarks: landmarks,
                rect: rect
            )
            let gaze = refinedGaze(in: pixelBuffer, faceRect: rect) ?? wholeFrameGaze
            let mouthAperture = normalizedAperture(of: landmarks.outerLips)
            return SystemFaceEvidence(
                rect: rect,
                gazeState: gaze.state,
                directGazeConfidence: gaze.directConfidence,
                yaw: gaze.yaw,
                pitch: gaze.pitch,
                pupilOffsetX: gaze.pupilOffsetX,
                pupilOffsetY: gaze.pupilOffsetY,
                signedPupilOffsetY: gaze.signedPupilOffsetY,
                meanEyeAperture: gaze.meanEyeAperture,
                mouthAperture: mouthAperture,
                alignment: alignment
            )
        }
    }

    private func refinedGaze(
        in pixelBuffer: CVPixelBuffer,
        faceRect: SOMACore.NormalizedRect
    ) -> (yaw: Double?, pitch: Double?, pupilOffsetX: Double?, pupilOffsetY: Double?, signedPupilOffsetY: Double?, meanEyeAperture: Double?, directConfidence: Double, state: SOMACore.VisualGazeEvidence)? {
        guard let crop = faceCropCGImage(from: pixelBuffer, rect: faceRect) else { return nil }
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: crop, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observation = (request.results ?? []).max(by: {
                  $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
              }),
              let landmarks = observation.landmarks,
              hasFacialFeatureSet(landmarks) else {
            return nil
        }
        return gazeAssessment(
            observation: observation,
            landmarks: landmarks,
            rect: faceRect
        )
    }

    private func alignmentEvidence(
        landmarks: VNFaceLandmarks2D,
        rect: SOMACore.NormalizedRect
    ) -> FaceAlignmentEvidence? {
        guard let visionLeftEye = landmarks.leftEye,
              let visionRightEye = landmarks.rightEye,
              let nose = landmarks.nose,
              let firstEye = center(of: visionLeftEye, in: rect),
              let secondEye = center(of: visionRightEye, in: rect),
              let noseCenter = center(of: nose, in: rect) else {
            return nil
        }
        // Vision names eyes anatomically. ArcFace's template is ordered by
        // image position, so normalize the pair explicitly for an unmirrored
        // camera frame.
        let imageLeftEye = firstEye.x <= secondEye.x ? firstEye : secondEye
        let imageRightEye = firstEye.x <= secondEye.x ? secondEye : firstEye
        guard imageRightEye.x - imageLeftEye.x >= rect.width * 0.12,
              // Top-left origin: the nose sits below the eyes (larger y).
              noseCenter.y > max(imageLeftEye.y, imageRightEye.y) else {
            return nil
        }
        return FaceAlignmentEvidence(
            rect: rect,
            leftEye: imageLeftEye,
            rightEye: imageRightEye,
            nose: noseCenter
        )
    }

    private func center(
        of region: VNFaceLandmarkRegion2D,
        in rect: SOMACore.NormalizedRect
    ) -> CGPoint? {
        guard region.pointCount > 0 else { return nil }
        var x = 0.0
        var y = 0.0
        for index in 0..<region.pointCount {
            x += Double(region.normalizedPoints[index].x)
            y += Double(region.normalizedPoints[index].y)
        }
        let divisor = Double(region.pointCount)
        return CGPoint(
            x: rect.x + (x / divisor) * rect.width,
            // Vision landmarks are bottom-left normalized; rect is top-left.
            y: rect.y + (1 - (y / divisor)) * rect.height
        )
    }

    private func normalizedAperture(of region: VNFaceLandmarkRegion2D?) -> Double? {
        guard let region, region.pointCount >= 3 else { return nil }
        var minimumX = Double.greatestFiniteMagnitude
        var maximumX = -Double.greatestFiniteMagnitude
        var minimumY = Double.greatestFiniteMagnitude
        var maximumY = -Double.greatestFiniteMagnitude
        for index in 0..<region.pointCount {
            let point = region.normalizedPoints[index]
            minimumX = min(minimumX, Double(point.x))
            maximumX = max(maximumX, Double(point.x))
            minimumY = min(minimumY, Double(point.y))
            maximumY = max(maximumY, Double(point.y))
        }
        let width = maximumX - minimumX
        guard width > 0.001 else { return nil }
        return min(max((maximumY - minimumY) / width, 0), 1)
    }

    private func hasFacialFeatureSet(_ landmarks: VNFaceLandmarks2D) -> Bool {
        // `allPoints` alone is permissive enough to turn cable texture into a
        // face. A physical face confirmation needs bilateral eyes plus nose
        // and mouth structure. This remains a lightweight System Vision gate,
        // not stored biometric data or identity recognition.
        let eyes = (landmarks.leftEye?.pointCount ?? 0) >= 2
            && (landmarks.rightEye?.pointCount ?? 0) >= 2
        let nose = (landmarks.nose?.pointCount ?? 0) >= 2
        let mouth = (landmarks.outerLips?.pointCount ?? 0) >= 3
        return eyes && nose && mouth
    }

    private func gazeAssessment(
        observation: VNFaceObservation,
        landmarks: VNFaceLandmarks2D,
        rect: SOMACore.NormalizedRect
    ) -> (yaw: Double?, pitch: Double?, pupilOffsetX: Double?, pupilOffsetY: Double?, signedPupilOffsetY: Double?, meanEyeAperture: Double?, directConfidence: Double, state: SOMACore.VisualGazeEvidence) {
        let yaw = observation.yaw?.doubleValue
        let pitch = observation.pitch?.doubleValue
        guard rect.centerX >= 0.26, rect.centerX <= 0.74,
              rect.centerY >= 0.13, rect.centerY <= 0.89,
              rect.width * rect.height >= 0.008 else {
            return (yaw, pitch, nil, nil, nil, nil, 0, .unavailable)
        }

        // On the Tiny 3 stream Vision supplies yaw consistently, but pitch is
        // absent even on a clear frontal face. Do not turn an unavailable
        // optional feature into a permanent rejection. Direct contact still
        // requires bilateral pupil evidence below.
        guard let yaw else {
            return (yaw, pitch, nil, nil, nil, nil, 0, .unavailable)
        }
        // Vision's yaw is coarse on this camera (roughly 0, 45, and 90
        // degrees). A pronounced head turn is reliable negative evidence;
        // vertical head pose is not available from this device's Vision
        // result and must not be guessed from it.
        if abs(yaw) > 0.65 {
            return (yaw, pitch, nil, nil, nil, nil, 0, .averted)
        }
        guard let leftEye = landmarks.leftEye,
              let rightEye = landmarks.rightEye,
              let leftPupil = landmarks.leftPupil,
              let rightPupil = landmarks.rightPupil else {
            return (yaw, pitch, nil, nil, nil, nil, 0, .unavailable)
        }
        guard let left = pupilOffset(leftPupil, in: leftEye),
              let right = pupilOffset(rightPupil, in: rightEye) else {
            return (yaw, pitch, nil, nil, nil, nil, 0, .unavailable)
        }
        let leftGeometry = SOMACore.EyeLandmarkGeometry(
            pupilOffsetX: left.x,
            pupilOffsetY: left.y,
            signedPupilOffsetY: left.signedY,
            apertureRatio: left.aperture
        )
        let rightGeometry = SOMACore.EyeLandmarkGeometry(
            pupilOffsetX: right.x,
            pupilOffsetY: right.y,
            signedPupilOffsetY: right.signedY,
            apertureRatio: right.aperture
        )
        let assessment = SOMACore.LandmarkGazeClassifier.assess(
            yaw: yaw,
            pitch: pitch,
            leftEye: leftGeometry,
            rightEye: rightGeometry,
            pupilCenteringScale: pupilCenteringThreshold,
            expectedDirectPupilOffsetY: expectedDirectPupilOffsetY
        )
        return (
            yaw,
            pitch,
            max(left.x, right.x),
            max(left.y, right.y),
            (left.signedY + right.signedY) / 2,
            (left.aperture + right.aperture) / 2,
            assessment.directConfidence,
            assessment.evidence
        )
    }

    private func pupilOffset(
        _ pupil: VNFaceLandmarkRegion2D,
        in eye: VNFaceLandmarkRegion2D
    ) -> (x: Double, y: Double, signedY: Double, aperture: Double)? {
        guard pupil.pointCount > 0, eye.pointCount >= 2 else { return nil }
        let pupilPoint = pupil.normalizedPoints[0]
        var minimumX = Double.greatestFiniteMagnitude
        var maximumX = -Double.greatestFiniteMagnitude
        var minimumY = Double.greatestFiniteMagnitude
        var maximumY = -Double.greatestFiniteMagnitude
        for index in 0..<eye.pointCount {
            let point = eye.normalizedPoints[index]
            minimumX = min(minimumX, Double(point.x))
            maximumX = max(maximumX, Double(point.x))
            minimumY = min(minimumY, Double(point.y))
            maximumY = max(maximumY, Double(point.y))
        }
        let width = maximumX - minimumX
        let height = maximumY - minimumY
        guard width > 0.001, height > 0.001 else { return nil }
        let signedY = (Double(pupilPoint.y) - (minimumY + maximumY) / 2) / (height / 2)
        return (
            x: abs(Double(pupilPoint.x) - (minimumX + maximumX) / 2) / (width / 2),
            y: abs(Double(pupilPoint.y) - (minimumY + maximumY) / 2) / (height / 2),
            signedY: signedY,
            aperture: height / width
        )
    }

}

/// Runs landmark verification outside the L0 perception queue. The worker has
/// one pending slot: it may skip stale frames, but L0 never waits behind a
/// Core Image conversion or a synchronous Vision request to receive its
/// latest corroborating result.
private final class SystemFaceVerificationWorker: @unchecked Sendable {
    struct Result: Sendable {
        let captureNS: UInt64
        let completedNS: UInt64
        let faces: [SystemFaceEvidence]
    }

    private final class Frame: @unchecked Sendable {
        let pixelBuffer: CVPixelBuffer
        let captureNS: UInt64

        init(pixelBuffer: CVPixelBuffer, captureNS: UInt64) {
            self.pixelBuffer = pixelBuffer
            self.captureNS = captureNS
        }
    }

    private let verifier: SystemFaceVerifier
    private let queue = DispatchQueue(label: "soma.subconscious.system-face-verifier", qos: .userInitiated)
    private let lock = NSLock()
    private let intervalNS: UInt64
    private var nextSubmissionNS: UInt64 = 0
    private var pending: Frame?
    private var latest: Result?
    private var processing = false
    private var stopped = false

    init(
        pupilCenteringThreshold: Double,
        expectedDirectPupilOffsetY: Double,
        maximumRateHz: Double = 5
    ) {
        verifier = SystemFaceVerifier(
            pupilCenteringThreshold: pupilCenteringThreshold,
            expectedDirectPupilOffsetY: expectedDirectPupilOffsetY
        )
        intervalNS = UInt64(1_000_000_000 / max(maximumRateHz, 1))
    }

    func submit(pixelBuffer: CVPixelBuffer, captureNS: UInt64) {
        lock.lock()
        guard !stopped, captureNS >= nextSubmissionNS else {
            lock.unlock()
            return
        }
        nextSubmissionNS = captureNS + intervalNS
        pending = Frame(pixelBuffer: pixelBuffer, captureNS: captureNS)
        let startWorker = !processing
        if startWorker { processing = true }
        lock.unlock()
        if startWorker {
            queue.async { [weak self] in self?.drain() }
        }
    }

    func latestResult() -> Result? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    func stop() {
        lock.lock()
        stopped = true
        pending = nil
        lock.unlock()
        queue.sync {}
    }

    private func drain() {
        while true {
            lock.lock()
            guard !stopped, let frame = pending else {
                processing = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()

            let result: Result = autoreleasepool {
                let faces = verifier.detect(in: frame.pixelBuffer)
                return Result(
                    captureNS: frame.captureNS,
                    completedNS: monotonicNanoseconds(),
                    faces: faces
                )
            }

            lock.lock()
            if !stopped, latest?.captureNS ?? 0 <= result.captureNS {
                latest = result
            }
            lock.unlock()
        }
    }
}

/// Low-rate scene understanding is deliberately isolated from the face servo.
/// Object detection, saliency and their pixel conversions are useful for the
/// spatial field, but none is allowed to delay the next L0 face frame.
private final class SceneEnrichmentWorker: @unchecked Sendable {
    struct Result: Sendable {
        let captureNS: UInt64
        let completedNS: UInt64
        let candidates: [VisualObservation]
        let objectInferenceMS: Double?
    }

    private final class Frame: @unchecked Sendable {
        let pixelBuffer: CVPixelBuffer
        let captureNS: UInt64

        init(pixelBuffer: CVPixelBuffer, captureNS: UInt64) {
            self.pixelBuffer = pixelBuffer
            self.captureNS = captureNS
        }
    }

    private let objectDetector: ANEObjectDetector?
    private let saliencyDetector = SystemSaliencyDetector()
    private let onHealth: @Sendable (String, String) -> Void
    private let queue = DispatchQueue(label: "soma.subconscious.scene-enrichment", qos: .utility)
    private let lock = NSLock()
    private var pending: Frame?
    private var latest: Result?
    private var processing = false
    private var stopped = false
    private var nextObjectNS: UInt64 = 0
    private var nextSaliencyNS: UInt64 = 0
    private var nextObjectErrorReportNS: UInt64 = 0

    init(
        objectDetector: ANEObjectDetector?,
        onHealth: @escaping @Sendable (String, String) -> Void
    ) {
        self.objectDetector = objectDetector
        self.onHealth = onHealth
    }

    func submit(pixelBuffer: CVPixelBuffer, captureNS: UInt64) {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        pending = Frame(pixelBuffer: pixelBuffer, captureNS: captureNS)
        let startWorker = !processing
        if startWorker { processing = true }
        lock.unlock()
        if startWorker {
            queue.async { [weak self] in self?.drain() }
        }
    }

    func latestResult() -> Result? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    func stop() {
        lock.lock()
        stopped = true
        pending = nil
        lock.unlock()
        queue.sync {}
    }

    private func drain() {
        while true {
            lock.lock()
            guard !stopped, let frame = pending else {
                processing = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()

            let result = autoreleasepool { enrich(frame) }
            guard let result else { continue }

            lock.lock()
            if !stopped, latest?.captureNS ?? 0 <= result.captureNS {
                latest = result
            }
            lock.unlock()
        }
    }

    private func enrich(_ frame: Frame) -> Result? {
        let now = monotonicNanoseconds()
        var candidates: [VisualObservation] = []
        var objectInferenceMS: Double?
        var didRun = false

        if let objectDetector, now >= nextObjectNS {
            nextObjectNS = now + 125_000_000
            didRun = true
            let startedNS = monotonicNanoseconds()
            do {
                candidates += try objectDetector.detect(in: frame.pixelBuffer)
                objectInferenceMS = milliseconds(from: startedNS, to: monotonicNanoseconds())
            } catch {
                let failedNS = monotonicNanoseconds()
                if failedNS >= nextObjectErrorReportNS {
                    nextObjectErrorReportNS = failedNS + 1_000_000_000
                    onHealth("object_neural_engine", "runtime_error; \(error.localizedDescription)")
                }
            }
        }

        if now >= nextSaliencyNS {
            nextSaliencyNS = now + 250_000_000
            didRun = true
            candidates += (try? saliencyDetector.detect(in: frame.pixelBuffer)) ?? []
        }

        guard didRun else { return nil }
        return Result(
            captureNS: frame.captureNS,
            completedNS: monotonicNanoseconds(),
            candidates: candidates,
            objectInferenceMS: objectInferenceMS
        )
    }
}

private final class DiagnosticPixelBuffer: @unchecked Sendable {
    let value: CVPixelBuffer

    init(_ value: CVPixelBuffer) {
        self.value = value
    }
}

/// Explicit, bounded raw-frame capture for diagnosing a failing face lock.
/// It is deliberately outside the normal scalar-only trace and is created
/// only by the opt-in command-line flag.
private final class FaceLockDiagnosticRecorder: @unchecked Sendable {
    private struct StopReport: Encodable {
        let schemaVersion = 1
        let event = "diagnostic.gimbal_stop"
        let monotonicNS: UInt64
        let reason: String
        let faceLockActive: Bool
        let faceLockMotorPermitted: Bool
        let lastObservedFaceMilliseconds: Double?
        let targetID: String?
        let targetKind: AttentionTargetKind?
        let targetLabel: String?
        let targetConfidence: Double?
        let targetCenterX: Double?
        let targetCenterY: Double?
        let targetActionEligible: Bool?
        let posePitchDegrees: Double?
        let posePanDegrees: Double?
        let latestFrame: String?
        let latestFrameState: String?
        let latestFrameMonotonicNS: UInt64?

        init(_ diagnostic: GimbalStopDiagnostic, latestFrame: String?, latestFrameState: String?, latestFrameMonotonicNS: UInt64?) {
            monotonicNS = diagnostic.monotonicNS
            reason = diagnostic.reason
            faceLockActive = diagnostic.faceLockActive
            faceLockMotorPermitted = diagnostic.faceLockMotorPermitted
            lastObservedFaceMilliseconds = diagnostic.lastObservedFaceMilliseconds
            targetID = diagnostic.targetID
            targetKind = diagnostic.targetKind
            targetLabel = diagnostic.targetLabel
            targetConfidence = diagnostic.targetConfidence
            targetCenterX = diagnostic.targetCenterX
            targetCenterY = diagnostic.targetCenterY
            targetActionEligible = diagnostic.targetActionEligible
            posePitchDegrees = diagnostic.posePitchDegrees
            posePanDegrees = diagnostic.posePanDegrees
            self.latestFrame = latestFrame
            self.latestFrameState = latestFrameState
            self.latestFrameMonotonicNS = latestFrameMonotonicNS
        }
    }

    private let directoryURL: URL
    private let ioQueue = DispatchQueue(label: "soma.subconscious.face-lock-diagnostics", qos: .utility)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let admissionLock = NSLock()
    private let sampleIntervalNS: UInt64 = 500_000_000
    private let faceCandidateIntervalNS: UInt64 = 100_000_000
    private let maximumImages = 60
    private var nextCaptureNS: UInt64 = 0
    private var encoding = false
    private var latestFrame: String?
    private var latestFrameState: String?
    private var latestFrameMonotonicNS: UInt64?

    init(directoryURL: URL) throws {
        self.directoryURL = directoryURL
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    func record(pixelBuffer: CVPixelBuffer, at monotonicNS: UInt64, state: String, force: Bool = false) {
        guard monotonicNS >= nextCaptureNS else { return }
        // A diagnostic is a bounded recent-history ring, not a second video
        // recorder. Face candidates need denser evidence than idle frames,
        // but never a 60 Hz stream of retained IOSurfaces.
        nextCaptureNS = monotonicNS + (force ? faceCandidateIntervalNS : sampleIntervalNS)
        admissionLock.lock()
        guard !encoding else {
            admissionLock.unlock()
            return
        }
        encoding = true
        let outputName = "frame-\(monotonicNS)-\(state).jpg"
        latestFrame = outputName
        latestFrameState = state
        latestFrameMonotonicNS = monotonicNS
        admissionLock.unlock()
        let retainedPixelBuffer = DiagnosticPixelBuffer(pixelBuffer)
        ioQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.admissionLock.lock()
                self.encoding = false
                self.admissionLock.unlock()
            }
            autoreleasepool {
                let image = CIImage(cvPixelBuffer: retainedPixelBuffer.value)
                let outputURL = self.directoryURL.appendingPathComponent(outputName)
                try? self.context.writeJPEGRepresentation(
                    of: image,
                    to: outputURL,
                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                    options: [:]
                )
            }
            let images = ((try? FileManager.default.contentsOfDirectory(
                at: self.directoryURL,
                includingPropertiesForKeys: nil
            )) ?? [])
                .filter { $0.pathExtension.lowercased() == "jpg" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for staleURL in images.dropLast(self.maximumImages) {
                try? FileManager.default.removeItem(at: staleURL)
            }
        }
    }

    /// Appends one bounded scalar state record whenever the bridge stops the
    /// gimbal. The frame recorder remains rate limited; this report points to
    /// the most recent retained JPEG rather than duplicating pixels.
    func recordStop(_ diagnostic: GimbalStopDiagnostic) {
        admissionLock.lock()
        let report = StopReport(
            diagnostic,
            latestFrame: latestFrame,
            latestFrameState: latestFrameState,
            latestFrameMonotonicNS: latestFrameMonotonicNS
        )
        admissionLock.unlock()
        ioQueue.async { [directoryURL] in
            guard let data = try? JSONEncoder().encode(report) else { return }
            let reportURL = directoryURL.appendingPathComponent("gimbal-stop-reports.jsonl")
            if !FileManager.default.fileExists(atPath: reportURL.path) {
                FileManager.default.createFile(atPath: reportURL.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: reportURL) else { return }
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.write(contentsOf: Data([0x0A]))
            } catch {
                return
            }
        }
    }
}

private final class VisionWorker: @unchecked Sendable {
    private enum DetectionOutcome {
        case candidates([VisualObservation], diagnostics: [VisualObservation])
        case miss(diagnostics: [VisualObservation])
    }

    private let mailbox = LatestFrameMailbox()
    private let wake = DispatchSemaphore(value: 0)
    private let queue = DispatchQueue(label: "soma.subconscious.vision", qos: .userInitiated)
    private let worldModel: PredictiveWorldModel
    private let publisher: BeliefPublisher
    private let writer: JSONLWriter
    private let counters: LatencyCounters
    private let faceLockDiagnosticRecorder: FaceLockDiagnosticRecorder?
    private let panoramaCompositor: RollingPanoramaCompositor?
    private let onSceneCandidates: (([SceneCandidate], UInt64, UInt64) -> Void)?
    private let onCoverage: ((
        GimbalPose,
        Double,
        GimbalPoseProjection,
        CameraProjectionModel,
        Double,
        [SOMACore.NormalizedRect],
        UInt64
    ) -> Void)?
    private let onFatalVisionFailure: (() -> Void)?
    private let poseStore: GimbalPoseStore
    private let externalGimbalCalibration: ExternalGimbalCalibration?
    private let sceneEnrichmentWorker: SceneEnrichmentWorker
    private let neuralFaceDetector: ANEFaceDetector?
    private let faceIdentityRuntime: FaceIdentityRuntime?
    private let onCameraFrame: ((CVPixelBuffer, UInt64) -> Void)?
    private let onDiagnosticFrame: ((CVPixelBuffer, [VisualObservation], UInt64) -> Void)?
    private let onIdentityPresenceEvidence: (@Sendable (Bool, UInt64) -> Void)?
    private let onVisualSpeakerEvidence: (@Sendable ([VisualSpeakerFrameEvidence], UInt64) -> Void)?
    private let systemFaceVerificationWorker: SystemFaceVerificationWorker
    private let stateLock = NSLock()
    private var sceneField = SceneField(requiresFaceActivity: true)
    private var nextFaceNS: UInt64 = 0
    private var lastAppliedFaceVerificationCaptureNS: UInt64 = 0
    private var lastAppliedSceneEnrichmentCaptureNS: UInt64 = 0
    private var landmarkGazeEvidence: [
        (rect: SOMACore.NormalizedRect, state: SOMACore.VisualGazeEvidence, observedNS: UInt64)
    ] = []
    private var directGazeConsensus = SOMACore.DirectGazeConsensus()
    private var identityAlignmentEvidence: [(evidence: SystemFaceEvidence, observedNS: UInt64)] = []
    private var nextSceneSnapshotNS: UInt64 = 0
    private var visualEvidenceContinuity = VisualEvidenceContinuity()
    private var socialAttentionLease = SocialAttentionLease()
    private var facePersonFusion = FacePersonFusion()
    // Landmark verification is slower than ANE face detection. It corroborates
    // the high-rate motor path rather than serializing every control update.
    private var faceConfirmationLease = FaceConfirmationLease(maximumAgeMilliseconds: 750)
    private var faceMotorContinuityLease = FaceMotorContinuityLease()
    private var unverifiedFaceRejection = UnverifiedFaceRejectionGate()
    private var panoramaBackgroundAdmission = PanoramaBackgroundAdmission()
    private var nextSystemFaceVerificationHealthNS: UInt64 = 0
    private var lastSystemFaceVerificationHadFace: Bool?
    private var lastAttentionEntropy = 0.0
    private var lastFaceInferenceSuccessNS: UInt64 = 0
    private var faceInferenceFailureReported = false
    private var faceInferenceStallReported = false
    private var stopped = false

    private static func faceEvidenceMatches(
        _ lhs: SOMACore.NormalizedRect,
        _ rhs: SOMACore.NormalizedRect
    ) -> Bool {
        let x1 = max(lhs.x, rhs.x)
        let y1 = max(lhs.y, rhs.y)
        let x2 = min(lhs.x + lhs.width, rhs.x + rhs.width)
        let y2 = min(lhs.y + lhs.height, rhs.y + rhs.height)
        let intersection = max(0, x2 - x1) * max(0, y2 - y1)
        let union = lhs.width * lhs.height + rhs.width * rhs.height - intersection
        if union > 0, intersection / union >= 0.10 { return true }
        return hypot(lhs.centerX - rhs.centerX, lhs.centerY - rhs.centerY) <= 0.14
    }

    init(
        worldModel: PredictiveWorldModel,
        publisher: BeliefPublisher,
        writer: JSONLWriter,
        counters: LatencyCounters,
        poseStore: GimbalPoseStore,
        externalGimbalCalibration: ExternalGimbalCalibration? = nil,
        faceLockDiagnosticRecorder: FaceLockDiagnosticRecorder? = nil,
        panoramaCompositor: RollingPanoramaCompositor? = nil,
        onSceneCandidates: (([SceneCandidate], UInt64, UInt64) -> Void)? = nil,
        onCoverage: ((
            GimbalPose,
            Double,
            GimbalPoseProjection,
            CameraProjectionModel,
            Double,
            [SOMACore.NormalizedRect],
            UInt64
        ) -> Void)? = nil,
        onCameraFrame: ((CVPixelBuffer, UInt64) -> Void)? = nil,
        onDiagnosticFrame: ((CVPixelBuffer, [VisualObservation], UInt64) -> Void)? = nil,
        onIdentityDecision: (@Sendable (FaceIdentityRuntimeDecision, SOMACore.NormalizedRect, Bool, UInt64) -> Void)? = nil,
        onIdentityPresenceEvidence: (@Sendable (Bool, UInt64) -> Void)? = nil,
        onVisualSpeakerEvidence: (@Sendable ([VisualSpeakerFrameEvidence], UInt64) -> Void)? = nil,
        onFatalVisionFailure: (() -> Void)? = nil,
        anonymousReviewProvider: @escaping @Sendable () -> Bool = { true },
        pupilCenteringThreshold: Double = 1.0,
        expectedDirectPupilOffsetY: Double = 0
    ) {
        self.worldModel = worldModel
        self.publisher = publisher
        self.writer = writer
        self.counters = counters
        self.poseStore = poseStore
        self.externalGimbalCalibration = externalGimbalCalibration
        self.faceLockDiagnosticRecorder = faceLockDiagnosticRecorder
        self.panoramaCompositor = panoramaCompositor
        self.onSceneCandidates = onSceneCandidates
        self.onCoverage = onCoverage
        self.onCameraFrame = onCameraFrame
        self.onDiagnosticFrame = onDiagnosticFrame
        self.onFatalVisionFailure = onFatalVisionFailure
        self.onIdentityPresenceEvidence = onIdentityPresenceEvidence
        self.onVisualSpeakerEvidence = onVisualSpeakerEvidence
        self.systemFaceVerificationWorker = SystemFaceVerificationWorker(
            pupilCenteringThreshold: pupilCenteringThreshold,
            expectedDirectPupilOffsetY: expectedDirectPupilOffsetY,
            // Landmark verification runs independently from the 30 Hz capture
            // loop. At 640px it completes in well under one frame interval on
            // the deployment host, so 12 Hz reduces face-acquisition latency
            // without competing with the high-rate ANE detector.
            maximumRateHz: 12
        )
        let objectDetector: ANEObjectDetector?
        let objectDetectorState: String
        let objectDetectorMessage: String
        do {
            let yoloConfidence = somaEnvDouble("SOMA_YOLO_CONFIDENCE_THRESHOLD", default: 0.5)
            let yoloPersonConfidence = somaEnvDouble("SOMA_YOLO_PERSON_THRESHOLD", default: 0.5)
            let detector = try ANEObjectDetector(
                confidenceThreshold: yoloConfidence,
                personConfidenceThreshold: yoloPersonConfidence
            )
            objectDetector = detector
            objectDetectorState = "configured"
            objectDetectorMessage = "model=YOLO11n; compute_units=\(detector.computeUnits); labels=coco_80; object_confidence_threshold=\(yoloConfidence); person_confidence_threshold=\(yoloPersonConfidence); prewarm_ms=\(detector.warmupMS); worker=scene_enrichment"
        } catch {
            objectDetector = nil
            objectDetectorState = "unavailable"
            objectDetectorMessage = error.localizedDescription
        }
        self.sceneEnrichmentWorker = SceneEnrichmentWorker(
            objectDetector: objectDetector,
            onHealth: { source, detail in
                let split = detail.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: monotonicNanoseconds(),
                    source: source,
                    state: split.first.map(String.init) ?? "runtime_error",
                    message: split.dropFirst().first.map(String.init) ?? detail
                ))
            }
        )
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: monotonicNanoseconds(),
            source: "object_neural_engine",
            state: objectDetectorState,
            message: objectDetectorMessage
        ))
        do {
            let detector = try ANEFaceDetector()
            neuralFaceDetector = detector
            lastFaceInferenceSuccessNS = monotonicNanoseconds()
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNanoseconds(),
                source: "face_neural_engine",
                state: "configured",
                message: "model=BlazeFaceShortRange; compute_units=\(detector.computeUnits); prewarm_ms=\(detector.warmupMS); max_hz=60"
            ))
        } catch {
            neuralFaceDetector = nil
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNanoseconds(),
                source: "face_neural_engine",
                state: "unavailable",
                message: error.localizedDescription
            ))
        }
        do {
            faceIdentityRuntime = try FaceIdentityRuntime(
                onHealth: { state, message in
                    writer.write(RuntimeEvent(
                        event: "source.health",
                        monotonicNS: monotonicNanoseconds(),
                        source: "face_identity",
                        state: state,
                        message: message
                    ))
                },
                onDecision: { decision, rect, isPrimaryFace, observedNS, inferenceMS in
                    writer.write(FaceIdentityEvent(
                        monotonicNS: observedNS,
                        state: decision.state,
                        subject: decision.opaqueSubject,
                        confidence: decision.confidence,
                        inferenceMS: inferenceMS
                    ))
                    onIdentityDecision?(decision, rect, isPrimaryFace, observedNS)
                },
                anonymousReviewProvider: anonymousReviewProvider
            )
        } catch {
            faceIdentityRuntime = nil
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNanoseconds(),
                source: "face_identity",
                state: "unavailable",
                message: error.localizedDescription
            ))
        }
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: monotonicNanoseconds(),
            source: "system_face_verifier",
            state: "configured",
            message: "source=VNDetectFaceLandmarksRequest; max_hz=12; latest_result_mailbox=on; corroborates_high_rate_ane_face"
        ))
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: monotonicNanoseconds(),
            source: "system_objectness",
            state: "configured",
            message: "source=VNGenerateObjectnessBasedSaliencyImageRequest; max_hz=4; labels=none"
        ))
    }

    func start() {
        queue.async { [weak self] in self?.workLoop() }
    }

    func submit(pixelBuffer: CVPixelBuffer, captureNS: UInt64, exposureNS: UInt64) {
        guard !isStopped else { return }
        onCameraFrame?(pixelBuffer, captureNS)
        let result = mailbox.publish(VideoFrame(
            pixelBuffer: pixelBuffer,
            captureNS: captureNS,
            exposureNS: exposureNS
        ))
        if result.superseded { counters.supersedeFrame() }
        if result.shouldWake { wake.signal() }
    }

    func stop() {
        stateLock.lock()
        stopped = true
        stateLock.unlock()
        wake.signal()
        queue.sync {}
        systemFaceVerificationWorker.stop()
        sceneEnrichmentWorker.stop()
        faceIdentityRuntime?.stop()
    }

    private func workLoop() {
        while true {
            wake.wait()
            if isStopped { return }
            guard let frame = mailbox.take() else { continue }
            // This dispatch work item lives for the whole capture session, so
            // GCD cannot drain an autorelease pool between frames. Vision and
            // Core ML create autoreleased request/result/IOSurface objects;
            // without this boundary they accumulate until VNCoreMLTransform
            // fails and the capture watchdog restarts the process.
            autoreleasepool {
                process(frame)
            }
        }
    }

    private var isStopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped
    }

    private func process(_ frame: VideoFrame) {
        let startedNS = monotonicNanoseconds()
        let outcome: DetectionOutcome
        do {
            outcome = try detect(in: frame.pixelBuffer, captureNS: frame.captureNS)
        } catch {
            outcome = .miss(diagnostics: [])
        }

        let completedNS = monotonicNanoseconds()
        let inferenceMS = milliseconds(from: startedNS, to: completedNS)
        let captureToBeliefMS = milliseconds(from: frame.captureNS, to: completedNS)
        let projection = poseStore.projection(at: frame.captureNS)
        switch outcome {
        case let .candidates(candidates, diagnosticCandidates):
            let sceneCandidates = sceneField.ingest(
                candidates,
                at: completedNS,
                cameraPose: projection.pose,
                horizontalFieldOfViewDegrees: projection.horizontalFieldOfViewDegrees,
                cameraSettled: projection.cameraSettled,
                poseProjection: externalGimbalCalibration?.poseProjection ?? .identity,
                cameraProjectionModel: projection.cameraProjectionModel
            )
            let sceneFaceCount = sceneCandidates.filter { $0.observation.label == "face" && $0.observedThisFrame }.count
            let sceneObservedCount = sceneCandidates.filter { $0.observedThisFrame }.count
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: completedNS,
                source: "face_pipeline",
                state: "scene",
                message: "scene_face=\(sceneFaceCount); scene_total=\(sceneObservedCount)"
            ))
            submitSpatialObservation(
                frame,
                sceneCandidates: sceneCandidates,
                projection: projection,
                at: completedNS
            )
            writeSceneCandidates(sceneCandidates, at: completedNS)
            onSceneCandidates?(sceneCandidates, frame.captureNS, completedNS)
            onDiagnosticFrame?(frame.pixelBuffer, diagnosticCandidates, frame.captureNS)
            let observedCandidates = sceneCandidates.filter(\.observedThisFrame)
            // System Vision validates faces and gaze asynchronously. Its
            // geometry can belong to an earlier capture, so it must never
            // replace the capture-synchronous ANE rectangle in the motor
            // trajectory. Both remain scene evidence, but only ANE geometry
            // may renew a real-time face command.
            let landmarkFaceCandidates = observedCandidates.filter {
                $0.observation.kind == .human
                    && $0.observation.label == "face"
                    && $0.faceVerificationEligible
                    && $0.observation.source == .systemFaceDetector
            }
            let hasVerifiedFace = observedCandidates.contains {
                $0.observation.kind == .human
                    && $0.observation.label == "face"
                    && $0.faceVerificationEligible
            }
            let realtimeFaceCandidates = observedCandidates.filter {
                $0.observation.kind == .human
                    && $0.observation.label == "face"
                    && $0.faceVerificationEligible
                    && $0.observation.source == .neuralFaceDetector
            }
            let attentionCandidates: [SceneCandidate]
            if !realtimeFaceCandidates.isEmpty {
                attentionCandidates = observedCandidates.filter { candidate in
                    candidate.observation.kind != .human
                        || realtimeFaceCandidates.contains { face in face.id == candidate.id }
                }
            } else if !landmarkFaceCandidates.isEmpty {
                // A landmark result still proves the social target remains in
                // view, but it is not a fresh motor measurement. Keep the
                // last capture-synchronous command alive until ANE provides
                // the next frame instead of steering from delayed geometry.
                visualEvidenceContinuity.recordObservation(at: completedNS)
                counters.visionFrameSkipped()
                return
            } else if hasVerifiedFace {
                attentionCandidates = observedCandidates.filter {
                    // A verified face is the strongest L0 motor evidence and
                    // must be the sole human attention input this frame. The
                    // YOLO person box around the same face (and any raw
                    // unverified face hypothesis) must not compete with it:
                    // when the probabilistic selector alternates between the
                    // face and the enclosing person box, the native gate sees
                    // a non-face target mid-lock, returns .stop and the
                    // device-native tracking lease is torn down.
                    $0.observation.kind != .human
                        || ($0.observation.label == "face" && $0.faceVerificationEligible)
                }
            } else {
                attentionCandidates = observedCandidates
            }
            let attentionObservations = attentionCandidates.map { $0.attentionObservation() }
            if attentionObservations.contains(where: { $0.kind == .human && $0.isActionEligible }) {
                socialAttentionLease.recordEligibleHuman(at: completedNS)
            }
            if socialAttentionLease.suppressesDefaultNonHumanAttention(
                candidates: attentionObservations,
                at: completedNS
            ) {
                counters.visionFrameSkipped()
                return
            }
            guard let observation = chooseAttentionCandidate(attentionObservations) else {
                // A weak or habituated candidate can correctly yield
                // no-target. It still is not proof that the prior visual
                // target vanished; use the same continuous-loss window as an
                // empty detector result before releasing the gimbal.
                guard visualEvidenceContinuity.confirmsLoss(at: completedNS) else {
                    counters.visionFrameSkipped()
                    return
                }
                let belief = worldModel.ingestVisionMiss(at: alignedWorldTimestamp(completedNS))
                counters.visionMiss(inferenceMS: inferenceMS, captureToBeliefMS: captureToBeliefMS)
                publisher.publish(belief, reason: "vision_miss", force: true)
                return
            }
            let belief = worldModel.ingestVisual(observation, at: alignedWorldTimestamp(completedNS))
            visualEvidenceContinuity.recordObservation(at: completedNS)
            counters.visionUpdate(inferenceMS: inferenceMS, captureToBeliefMS: captureToBeliefMS)
            writer.write(VisionEvent(
                monotonicNS: completedNS,
                source: observation.source,
                confidence: observation.confidence,
                kind: observation.kind,
                label: observation.label,
                attentionWeight: observation.attentionWeight,
                attentionProbability: observation.posteriorProbability,
                attentionEntropy: lastAttentionEntropy,
                captureToBeliefMS: captureToBeliefMS
            ))
            publisher.publish(belief, reason: observation.source.rawValue, force: true)
        case let .miss(diagnosticCandidates):
            let sceneCandidates = sceneField.ingest([], at: completedNS)
            submitSpatialObservation(
                frame,
                sceneCandidates: sceneCandidates,
                projection: projection,
                at: completedNS
            )
            onDiagnosticFrame?(frame.pixelBuffer, diagnosticCandidates, frame.captureNS)
            // The scene field is a local spatial map, not just a cache for the
            // attention selector. Emit its offscreen decay at a bounded rate so
            // a trace can reconstruct what remains known outside the frame.
            if completedNS >= nextSceneSnapshotNS {
                nextSceneSnapshotNS = completedNS + 250_000_000
                writeSceneCandidates(sceneCandidates, at: completedNS)
                onSceneCandidates?(sceneCandidates, frame.captureNS, completedNS)
            }
            guard visualEvidenceContinuity.confirmsLoss(at: completedNS) else {
                counters.visionFrameSkipped()
                return
            }
            let belief = worldModel.ingestVisionMiss(at: alignedWorldTimestamp(completedNS))
            counters.visionMiss(inferenceMS: inferenceMS, captureToBeliefMS: captureToBeliefMS)
            publisher.publish(belief, reason: "vision_miss", force: true)
        }
    }

    private func submitSpatialObservation(
        _ frame: VideoFrame,
        sceneCandidates: [SceneCandidate],
        projection: (
            pose: GimbalPose?,
            horizontalFieldOfViewDegrees: Double,
            fieldOfViewMode: Int,
            cameraProjectionModel: CameraProjectionModel,
            cameraSettled: Bool,
            angularVelocityDegreesPerSecond: Double
        ),
        at monotonicNS: UInt64
    ) {
        guard let pose = projection.pose else { return }
        let hasObservedHuman = sceneCandidates.contains {
            $0.observedThisFrame && $0.observation.kind == .human
        }
        let admitsUnmaskedBackground = panoramaBackgroundAdmission.admits(
            hasObservedHuman: hasObservedHuman,
            at: monotonicNS
        )
        let dynamicRects = sceneCandidates.compactMap { candidate -> SOMACore.NormalizedRect? in
            // Detector labels do not imply physical motion. Mask people from
            // the persistent place image, but retain nonhuman objects so a
            // continuous sweep cannot leave permanent detector-shaped holes.
            guard candidate.observedThisFrame,
                  PanoramaEntityMaskPolicy.shouldMask(candidate.observation.kind) else {
                return nil
            }
            return candidate.observation.rect
        }
        // Bitmap panorama generation is optional because it can retain large
        // IOSurfaces, but the attention atlas must still learn which stable
        // parts of the viewing sphere have high-quality visual coverage.
        // Without this lightweight path every cell remains quality zero and
        // exploration reduces to a geometry-only sweep.
        let backgroundObservationQuality: Double
        if (hasObservedHuman || admitsUnmaskedBackground),
           PanoramaObservationQuality.admitsProjection(
               angularVelocityDegreesPerSecond: projection.angularVelocityDegreesPerSecond
           ) {
            backgroundObservationQuality = 0.9 * PanoramaObservationQuality.motionQuality(
                angularVelocityDegreesPerSecond: projection.angularVelocityDegreesPerSecond
            )
        } else {
            backgroundObservationQuality = 0
        }
        onCoverage?(
            pose,
            projection.horizontalFieldOfViewDegrees,
            externalGimbalCalibration?.poseProjection ?? .identity,
            projection.cameraProjectionModel,
            backgroundObservationQuality,
            dynamicRects,
            monotonicNS
        )
        // A detected person can be removed by the per-frame dynamic mask, so
        // the remaining background is still useful. During a detector gap the
        // prior person rectangle is no longer current, therefore the bounded
        // admission hold continues to reject the whole frame. Feature-print
        // persistence independently requires an empty mask.
        guard hasObservedHuman || admitsUnmaskedBackground else { return }
        panoramaCompositor?.submitContext(
            frameNS: frame.captureNS,
            horizontalFieldOfViewDegrees: projection.horizontalFieldOfViewDegrees,
            fieldOfViewMode: projection.fieldOfViewMode,
            cameraProjectionModel: projection.cameraProjectionModel,
            dynamicVisionRects: dynamicRects
        )
    }

    private func detect(in pixelBuffer: CVPixelBuffer, captureNS: UInt64) throws -> DetectionOutcome {
        // The landmark worker owns its own latest-frame mailbox. Submitting is
        // nonblocking, so L0 face inference is never serialized behind
        // Core Image conversion or a synchronous System Vision request.
        systemFaceVerificationWorker.submit(pixelBuffer: pixelBuffer, captureNS: captureNS)
        sceneEnrichmentWorker.submit(pixelBuffer: pixelBuffer, captureNS: captureNS)
        var candidates: [VisualObservation] = []
        // The diagnostic overlay is a measurement display, not SceneField
        // state. Retain only observations whose model input was this buffer.
        var diagnosticCandidates: [VisualObservation] = []
        if let neuralFaceDetector {
            let now = monotonicNanoseconds()
            if now >= nextFaceNS {
                nextFaceNS = now + 33_333_333
                do {
                    let faces = try neuralFaceDetector.detect(in: pixelBuffer)
                    candidates += faces
                    diagnosticCandidates += faces
                    counters.neuralFaceInference()
                    recordFaceInferenceSuccess(at: monotonicNanoseconds())
                } catch {
                    recordFaceInferenceFailure(error, at: monotonicNanoseconds())
                }
            }
        }
        let faceVerificationNow = monotonicNanoseconds()
        if let enrichment = sceneEnrichmentWorker.latestResult(),
           enrichment.captureNS > lastAppliedSceneEnrichmentCaptureNS {
            // Scene results enrich the spatial field, but do not become stale
            // L0 evidence after the camera has moved on.
            lastAppliedSceneEnrichmentCaptureNS = enrichment.captureNS
            if faceVerificationNow >= enrichment.captureNS,
               faceVerificationNow - enrichment.captureNS <= 750_000_000 {
                candidates += enrichment.candidates
                if enrichment.captureNS == captureNS {
                    diagnosticCandidates += enrichment.candidates
                }
                if let objectInferenceMS = enrichment.objectInferenceMS {
                    counters.neuralEngineInference(inferenceMS: objectInferenceMS)
                }
            }
        }
        var newlyVerifiedFaces: [SystemFaceEvidence] = []
        var verificationCaptureNS: UInt64?
        if let verification = systemFaceVerificationWorker.latestResult(),
           verification.captureNS > lastAppliedFaceVerificationCaptureNS {
            // Consume each mailbox result exactly once. A result that reached
            // us too late is diagnostic evidence, not a motor measurement.
            lastAppliedFaceVerificationCaptureNS = verification.captureNS
            if faceVerificationNow >= verification.captureNS,
               faceVerificationNow - verification.captureNS <= 750_000_000 {
                verificationCaptureNS = verification.captureNS
                let stabilizedGaze = directGazeConsensus.stabilize(verification.faces.map {
                    SOMACore.DirectGazeConsensusSample(
                        rect: $0.rect,
                        evidence: $0.gazeState,
                        directConfidence: $0.directGazeConfidence,
                        capturedNS: verification.captureNS
                    )
                })
                let stabilizedFaces = zip(verification.faces, stabilizedGaze).map { face, gaze in
                    face.withGazeState(gaze)
                }
                onVisualSpeakerEvidence?(
                    stabilizedFaces.map {
                        VisualSpeakerFrameEvidence(
                            rect: $0.rect,
                            gazeState: $0.gazeState,
                            mouthAperture: $0.mouthAperture
                        )
                    },
                    verification.captureNS
                )
                newlyVerifiedFaces = stabilizedFaces
                faceConfirmationLease.record(stabilizedFaces.map(\.rect), at: verification.captureNS)
                let hasLandmarkFace = !stabilizedFaces.isEmpty
                if lastSystemFaceVerificationHadFace != hasLandmarkFace
                    || faceVerificationNow >= nextSystemFaceVerificationHealthNS {
                    let captureAgeMS = Double(faceVerificationNow - verification.captureNS) / 1_000_000
                    let directGazeCount = stabilizedFaces.filter { $0.gazeState == .direct }.count
                    let rawDirectGazeCount = verification.faces.filter { $0.gazeState == .direct }.count
                    let avertedGazeCount = stabilizedFaces.filter { $0.gazeState == .averted }.count
                    let unavailableGazeCount = stabilizedFaces.filter { $0.gazeState == .unavailable }.count
                    let gazeSample = stabilizedFaces.first.map { evidence in
                        let yaw = evidence.yaw.map { String(format: "%.3f", $0) } ?? "na"
                        let pitch = evidence.pitch.map { String(format: "%.3f", $0) } ?? "na"
                        let pupilX = evidence.pupilOffsetX.map { String(format: "%.3f", $0) } ?? "na"
                        let pupilY = evidence.pupilOffsetY.map { String(format: "%.3f", $0) } ?? "na"
                        let signedPupilY = evidence.signedPupilOffsetY.map { String(format: "%.3f", $0) } ?? "na"
                        let aperture = evidence.meanEyeAperture.map { String(format: "%.3f", $0) } ?? "na"
                        let confidence = String(format: "%.3f", evidence.directGazeConfidence)
                        return "yaw=\(yaw); pitch=\(pitch); pupil_offset_x=\(pupilX); pupil_offset_y=\(pupilY); pupil_signed_y=\(signedPupilY); eye_aperture=\(aperture); gaze_confidence=\(confidence)"
                    } ?? "none"
                    writer.write(RuntimeEvent(
                        event: "source.health",
                        monotonicNS: faceVerificationNow,
                        source: "system_face_verifier",
                        state: hasLandmarkFace ? "face_detected" : "no_face",
                        message: String(
                            format: "landmark_faces=%d; gaze_direct=%d; gaze_direct_raw=%d; gaze_averted=%d; gaze_unavailable=%d; capture_age_ms=%.1f; gaze_sample=%@",
                            stabilizedFaces.count,
                            directGazeCount,
                            rawDirectGazeCount,
                            avertedGazeCount,
                            unavailableGazeCount,
                            captureAgeMS,
                            gazeSample
                        )
                    ))
                    lastSystemFaceVerificationHadFace = hasLandmarkFace
                    nextSystemFaceVerificationHealthNS = faceVerificationNow + 1_000_000_000
                }
                landmarkGazeEvidence = stabilizedFaces.map {
                    ($0.rect, $0.gazeState, verification.captureNS)
                }
                identityAlignmentEvidence = stabilizedFaces.map { ($0, verification.captureNS) }
            }
        }
        // A newly completed landmark result may rescue an ANE miss, but stale
        // System Vision geometry never becomes a steering measurement.
        let aneFaceRects = candidates.filter { isFaceCandidate($0) }.map(\.rect)
        let systemFaceCandidates: [VisualObservation] = newlyVerifiedFaces.compactMap { evidence in
            guard !aneFaceRects.contains(where: { Self.faceEvidenceMatches(evidence.rect, $0) }) else {
                return nil
            }
            return VisualObservation(
                rect: evidence.rect,
                confidence: 1.0,
                source: .systemFaceDetector,
                kind: .human,
                label: "face",
                isActionEligible: true,
                isFaceVerified: true,
                isEyeContactEligible: evidence.directedEyeContact,
                gazeEvidence: evidence.gazeState
            )
        }
        candidates += systemFaceCandidates
        if verificationCaptureNS == captureNS {
            diagnosticCandidates += systemFaceCandidates
        }
        candidates = facePersonFusion.fuse(candidates, at: faceVerificationNow)
        let directedContactFreshnessNS = UInt64(somaEnvDouble(
            "SOMA_L0_EYE_CONTACT_FRESHNESS_MS",
            default: SOMAEnvSettings.defaultEyeContactFreshnessMilliseconds
        )) * 1_000_000
        candidates = candidates.map { candidate in
            guard isFaceCandidate(candidate) else { return candidate }
            // FacePersonFusion is the primary motor corroboration boundary.
            // A lone ANE face is admissible only after independent *landmark*
            // confirmation; never promote a System-Vision rectangle by itself.
            let independentlyVerified = candidate.isFaceVerified
                || faceConfirmationLease.permits(candidate.rect, at: faceVerificationNow)
            let gazeEvidence: SOMACore.VisualGazeEvidence
            if independentlyVerified,
               let landmarkEvidence = landmarkGazeEvidence.first(where: { evidence in
                   faceVerificationNow >= evidence.observedNS
                       && faceVerificationNow - evidence.observedNS <= directedContactFreshnessNS
                       && Self.faceEvidenceMatches(evidence.rect, candidate.rect)
               }) {
                gazeEvidence = landmarkEvidence.state
            } else {
                gazeEvidence = .unavailable
            }
            let directedEyeContact = gazeEvidence == .direct
            if independentlyVerified {
                faceMotorContinuityLease.record(candidate.rect, at: faceVerificationNow)
            }
            return VisualObservation(
                rect: candidate.rect,
                confidence: candidate.confidence,
                source: candidate.source,
                kind: candidate.kind,
                label: candidate.label,
                attentionWeight: candidate.attentionWeight,
                posteriorProbability: candidate.posteriorProbability,
                sceneID: candidate.sceneID,
                stabilityMilliseconds: candidate.stabilityMilliseconds,
                isActionEligible: candidate.isActionEligible
                    || (candidate.source == .neuralFaceDetector && independentlyVerified),
                isFaceVerified: independentlyVerified,
                isEyeContactEligible: directedEyeContact,
                gazeEvidence: gazeEvidence
            )
        }
        diagnosticCandidates = diagnosticCandidates.map { candidate in
            guard isFaceCandidate(candidate) else { return candidate }
            let independentlyVerified = candidate.isFaceVerified
                || faceConfirmationLease.permits(candidate.rect, at: faceVerificationNow)
            return VisualObservation(
                rect: candidate.rect,
                confidence: candidate.confidence,
                source: candidate.source,
                kind: candidate.kind,
                label: candidate.label,
                attentionWeight: candidate.attentionWeight,
                posteriorProbability: candidate.posteriorProbability,
                sceneID: candidate.sceneID,
                stabilityMilliseconds: candidate.stabilityMilliseconds,
                isActionEligible: candidate.isActionEligible,
                isFaceVerified: independentlyVerified,
                isEyeContactEligible: candidate.isEyeContactEligible,
                gazeEvidence: candidate.gazeEvidence
            )
        }
        for candidate in candidates where isFaceCandidate(candidate) && candidate.isFaceVerified {
            facePersonFusion.promoteValidatedFace(candidate.rect, at: faceVerificationNow)
        }
        let rawFaceCount = candidates.filter(isFaceCandidate).count
        if rawFaceCount == 0 {
            unverifiedFaceRejection.recordNoFace(at: faceVerificationNow)
        }
        var rejectedFaceRects: [SOMACore.NormalizedRect] = []
        candidates = candidates.filter { candidate in
            guard isFaceCandidate(candidate) else { return true }
            let admitted = unverifiedFaceRejection.admits(
                rect: candidate.rect,
                independentlyVerified: candidate.isFaceVerified,
                at: faceVerificationNow
            )
            if !admitted { rejectedFaceRects.append(candidate.rect) }
            return admitted
        }
        candidates = candidates.map { candidate in
            guard isFaceCandidate(candidate),
                  !candidate.isFaceVerified,
                  unverifiedFaceRejection.isValidated(candidate.rect) else {
                return candidate
            }
            return VisualObservation(
                rect: candidate.rect,
                confidence: candidate.confidence,
                source: candidate.source,
                kind: candidate.kind,
                label: candidate.label,
                attentionWeight: candidate.attentionWeight,
                posteriorProbability: candidate.posteriorProbability,
                sceneID: candidate.sceneID,
                stabilityMilliseconds: candidate.stabilityMilliseconds,
                isActionEligible: candidate.isActionEligible,
                isFaceVerified: true,
                isEyeContactEligible: candidate.isEyeContactEligible
            )
        }
        sceneField.invalidateUnverifiedFaceTracks(matching: rejectedFaceRects)
        let verifiedFaceCount = candidates.filter { isFaceCandidate($0) && $0.isFaceVerified }.count
        onIdentityPresenceEvidence?(verifiedFaceCount > 0, faceVerificationNow)
        let verifiedNeuralFaces = candidates.filter { isFaceCandidate($0) && $0.isFaceVerified }
        let identityAlignments: [FaceAlignmentEvidence]
        if verifiedNeuralFaces.isEmpty {
            // BlazeFace (short-range, 0.75 threshold) missed the face this frame,
            // but System Vision independently verified one with landmarks. Feed
            // those alignments straight to identity so a visible person still
            // gets recognized even when the lighter ANE detector cannot confirm
            // a "face" candidate.
            // Person-corroboration gate: only feed System Vision faces to
            // identity when they sit on an actual human body box. This stops
            // face-like objects (e.g. a Dyson purifier) — which systemVision
            // may flag with landmarks but which have no matching "person"
            // detection — from being registered as anonymous identities.
            let humanBodyRects = candidates
                .filter { $0.kind == .human && $0.label != "face" }
                .map(\.rect)
            identityAlignments = identityAlignmentEvidence
                .filter { evidence in
                    faceVerificationNow >= evidence.observedNS
                        && faceVerificationNow - evidence.observedNS <= 250_000_000
                        && humanBodyRects.contains {
                            Self.faceEvidenceMatches(evidence.evidence.rect, $0)
                        }
                }
                .map { $0.evidence.alignment }
        } else {
            identityAlignments = verifiedNeuralFaces
                .sorted {
                    let lhsArea = $0.rect.width * $0.rect.height
                    let rhsArea = $1.rect.width * $1.rect.height
                    if lhsArea != rhsArea { return lhsArea > rhsArea }
                    return $0.confidence > $1.confidence
                }
                .compactMap { identityFace -> FaceAlignmentEvidence? in
                    identityAlignmentEvidence
                        .filter { evidence in
                            faceVerificationNow >= evidence.observedNS
                                && faceVerificationNow - evidence.observedNS <= 250_000_000
                                && Self.faceEvidenceMatches(evidence.evidence.rect, identityFace.rect)
                        }
                        .max(by: { $0.observedNS < $1.observedNS })?
                        .evidence.alignment
                }
        }
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: faceVerificationNow,
            source: "face_identity",
            state: "alignments",
            message: "count=\(identityAlignments.count); verified_neural=\(verifiedNeuralFaces.count); evidence=\(identityAlignmentEvidence.count)"
        ))
        if !identityAlignments.isEmpty {
            faceIdentityRuntime?.submit(
                pixelBuffer: pixelBuffer,
                alignments: identityAlignments,
                at: faceVerificationNow
            )
        }
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: faceVerificationNow,
            source: "face_pipeline",
            state: "detect",
            message: "candidates_face=\(candidates.filter { self.isFaceCandidate($0) }.count); candidates_total=\(candidates.count); verified=\(verifiedFaceCount)"
        ))
        let faceLockDiagnosticState: String
        if verifiedFaceCount > 0 {
            faceLockDiagnosticState = "face_verified"
        } else if !rejectedFaceRects.isEmpty {
            faceLockDiagnosticState = "face_rejected"
        } else if rawFaceCount > 0 {
            faceLockDiagnosticState = "face_unverified"
        } else {
            faceLockDiagnosticState = "face_absent"
        }
        faceLockDiagnosticRecorder?.record(
            pixelBuffer: pixelBuffer,
            at: faceVerificationNow,
            state: faceLockDiagnosticState,
            force: rawFaceCount > 0
        )
        guard !candidates.isEmpty else {
            return .miss(diagnostics: diagnosticCandidates)
        }
        return .candidates(candidates, diagnostics: diagnosticCandidates)
    }

    private func recordFaceInferenceSuccess(at monotonicNS: UInt64) {
        if faceInferenceFailureReported {
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNS,
                source: "face_neural_engine",
                state: "recovered",
                message: "inference_resumed"
            ))
        }
        lastFaceInferenceSuccessNS = monotonicNS
        faceInferenceFailureReported = false
        faceInferenceStallReported = false
    }

    private func recordFaceInferenceFailure(_ error: Error, at monotonicNS: UInt64) {
        if !faceInferenceFailureReported {
            faceInferenceFailureReported = true
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNS,
                source: "face_neural_engine",
                state: "runtime_error",
                message: error.localizedDescription
            ))
        }
        guard !faceInferenceStallReported,
              lastFaceInferenceSuccessNS > 0,
              monotonicNS >= lastFaceInferenceSuccessNS + 2_000_000_000 else {
            return
        }
        faceInferenceStallReported = true
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: monotonicNS,
            source: "face_neural_engine",
            state: "runtime_stalled",
            message: "no_successful_inference_for_2000ms; restarting_capture_session"
        ))
        onFatalVisionFailure?()
    }

    private func isFaceCandidate(_ observation: VisualObservation) -> Bool {
        observation.kind == .human && observation.label == "face"
    }

    private func faceRectanglesOverlap(_ lhs: SOMACore.NormalizedRect, _ rhs: SOMACore.NormalizedRect) -> Bool {
        let left = max(lhs.x, rhs.x)
        let top = max(lhs.y, rhs.y)
        let right = min(lhs.x + lhs.width, rhs.x + rhs.width)
        let bottom = min(lhs.y + lhs.height, rhs.y + rhs.height)
        let intersection = max(0, right - left) * max(0, bottom - top)
        let union = lhs.width * lhs.height + rhs.width * rhs.height - intersection
        return union > 0 && intersection / union >= 0.20
    }

    private func writeSceneCandidates(_ candidates: [SceneCandidate], at monotonicNS: UInt64) {
        // The session map deliberately retains offscreen spatial evidence, but
        // serialising every retained hypothesis on every frame turns a long
        // run into an unbounded trace and starves the live vision pipeline.
        // A scene event is therefore a current observation, while the map
        // itself remains in memory for spatial re-acquisition.
        for candidate in candidates where candidate.observedThisFrame {
            let observation = candidate.observation
            writer.write(SceneEvent(
                monotonicNS: monotonicNS,
                sceneID: candidate.id,
                source: observation.source,
                kind: observation.kind,
                label: observation.label,
                confidence: observation.confidence,
                centerX: observation.rect.centerX,
                centerY: observation.rect.centerY,
                width: observation.rect.width,
                height: observation.rect.height,
                observedThisFrame: candidate.observedThisFrame,
                observationCount: candidate.observationCount,
                stabilityMilliseconds: candidate.stabilityMilliseconds,
                sourceCount: candidate.sourceCount,
                actionEligible: candidate.isActionEligible,
                faceActivityEligible: candidate.faceActivityEligible,
                faceVerified: candidate.faceVerificationEligible,
                faceInteractionLivenessEligible: candidate.faceInteractionLivenessEligible,
                trackingMinimumCenterX: candidate.trackingBoundary.minimumCenterX,
                trackingMaximumCenterX: candidate.trackingBoundary.maximumCenterX,
                trackingMinimumCenterY: candidate.trackingBoundary.minimumCenterY,
                trackingMaximumCenterY: candidate.trackingBoundary.maximumCenterY,
                azimuthDegrees: candidate.bearing?.azimuthDegrees,
                elevationDegrees: candidate.bearing?.elevationDegrees,
                spatialConfidence: candidate.spatialConfidence,
                lastSeenMilliseconds: candidate.lastSeenMilliseconds
            ))
        }
    }

    private func chooseAttentionCandidate(_ candidates: [VisualObservation]) -> VisualObservation? {
        guard !candidates.isEmpty else { return nil }
        let distribution = ProbabilisticAttentionSelector.infer(
            candidates: candidates,
            previousTarget: worldModel.snapshot(at: monotonicNanoseconds()).target
        )
        lastAttentionEntropy = distribution.normalizedEntropy
        return distribution.selected
    }

    /// Audio and Vision complete on independent workers. A late Vision result
    /// must merge at the current belief time rather than being silently dropped
    /// just because a newer audio callback arrived first.
    private func alignedWorldTimestamp(_ completedNS: UInt64) -> UInt64 {
        max(completedNS, worldModel.snapshot(at: completedNS).monotonicNS)
    }
}

private final class CaptureDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let stateLock = NSLock()
    private var accepting = true
    private let worldModel: PredictiveWorldModel
    private let publisher: BeliefPublisher
    private let visionWorker: VisionWorker
    private let audioAnalyzer: AudioAnalyzer
    private let counters: LatencyCounters
    private let videoOutput: AVCaptureVideoDataOutput
    private let audioOutput: AVCaptureAudioDataOutput
    private let l1AuxiliarySemanticBridge: L1AuxiliarySemanticBridge?
    private let embodimentViewCaptureStore: EmbodimentViewCaptureStore?
    private let diagnosticSnapshotURL: URL?
    private var diagnosticSnapshotWritten = false

    init(
        worldModel: PredictiveWorldModel,
        publisher: BeliefPublisher,
        visionWorker: VisionWorker,
        audioAnalyzer: AudioAnalyzer,
        counters: LatencyCounters,
        videoOutput: AVCaptureVideoDataOutput,
        audioOutput: AVCaptureAudioDataOutput,
        diagnosticSnapshotURL: URL?,
        l1AuxiliarySemanticBridge: L1AuxiliarySemanticBridge?,
        embodimentViewCaptureStore: EmbodimentViewCaptureStore?
    ) {
        self.worldModel = worldModel
        self.publisher = publisher
        self.visionWorker = visionWorker
        self.audioAnalyzer = audioAnalyzer
        self.counters = counters
        self.videoOutput = videoOutput
        self.audioOutput = audioOutput
        self.diagnosticSnapshotURL = diagnosticSnapshotURL
        self.l1AuxiliarySemanticBridge = l1AuxiliarySemanticBridge
        self.embodimentViewCaptureStore = embodimentViewCaptureStore
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isAccepting else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let now = monotonicNanoseconds()
        if output === videoOutput, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            let exposureNS = hostAlignedPresentationTimestamp(
                sampleBuffer: sampleBuffer,
                fallbackNS: now
            )
            writeDiagnosticSnapshot(from: pixelBuffer)
            let belief = worldModel.snapshot(at: now)
            publisher.publish(belief, reason: "fast_prediction")
            // L0 receives the live sample first. The semantic helper gets the
            // same retained buffer on a utility queue and has no motor or LED
            // authority, so semantic work cannot enter the reflex path.
            visionWorker.submit(pixelBuffer: pixelBuffer, captureNS: now, exposureNS: exposureNS)
            l1AuxiliarySemanticBridge?.submit(
                pixelBuffer: pixelBuffer,
                context: L1AuxiliaryFrameContext(captureNS: now, trigger: "visual_sample", belief: belief)
            )
            embodimentViewCaptureStore?.submit(
                pixelBuffer: pixelBuffer,
                captureNS: exposureNS
            )
            counters.videoCallback(
                at: now,
                processingMS: milliseconds(from: now, to: monotonicNanoseconds())
            )
        } else if output === audioOutput {
            audioAnalyzer.ingest(sampleBuffer, at: now)
        }
    }

    private func writeDiagnosticSnapshot(from pixelBuffer: CVPixelBuffer) {
        guard let diagnosticSnapshotURL, !diagnosticSnapshotWritten else { return }
        diagnosticSnapshotWritten = true
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: nil)
        try? context.writeJPEGRepresentation(
            of: image,
            to: diagnosticSnapshotURL,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            options: [:]
        )
    }

    func stopAccepting() {
        stateLock.lock()
        accepting = false
        stateLock.unlock()
    }

    private var isAccepting: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return accepting
    }
}

private final class SessionObserver: NSObject, @unchecked Sendable {
    private let writer: JSONLWriter
    private let stateLock = NSLock()
    private let deliveryQueue = DispatchQueue(label: "soma.subconscious.session-observer")
    private var tokens: [NSObjectProtocol] = []
    private var accepting = true

    init(session: AVCaptureSession, writer: JSONLWriter, videoDevice: AVCaptureDevice, audioDevice: AVCaptureDevice) {
        self.writer = writer
        super.init()
        let center = NotificationCenter.default
        tokens = [
            center.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak self] notification in
                self?.write("session", "runtime_error", notification)
            },
            center.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: nil) { [weak self] notification in
                self?.write("session", "interrupted", notification)
            },
            center.addObserver(forName: .AVCaptureSessionInterruptionEnded, object: session, queue: nil) { [weak self] notification in
                self?.write("session", "interruption_ended", notification)
            },
            center.addObserver(forName: .AVCaptureDeviceWasDisconnected, object: videoDevice, queue: nil) { [weak self] notification in
                self?.write("video", "disconnected", notification)
            },
            center.addObserver(forName: .AVCaptureDeviceWasDisconnected, object: audioDevice, queue: nil) { [weak self] notification in
                self?.write("audio", "disconnected", notification)
            },
            center.addObserver(forName: .AVCaptureDeviceWasConnected, object: nil, queue: nil) { [weak self] notification in
                guard let device = notification.object as? AVCaptureDevice else { return }
                if device.uniqueID == videoDevice.uniqueID { self?.write("video", "reconnected", notification) }
                if device.uniqueID == audioDevice.uniqueID { self?.write("audio", "reconnected", notification) }
            },
        ]
    }

    deinit { stop() }

    func stop() {
        stateLock.lock()
        let activeTokens = tokens
        tokens = []
        stateLock.unlock()
        activeTokens.forEach(NotificationCenter.default.removeObserver)
        deliveryQueue.sync { accepting = false }
    }

    private func write(_ source: String, _ state: String, _ notification: Notification) {
        let message = (notification.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription
        deliveryQueue.async { [weak self] in
            guard let self, accepting else { return }
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNanoseconds(),
                source: source,
                state: state,
                message: message
            ))
        }
    }
}

private final class PanoramaPlaceMemoryPersistence: @unchecked Sendable {
    private let url: URL
    private let atlas: SphericalSceneAtlasStore
    private let expectedEncoder: String
    private let expectedRevision: Int
    private let onHealth: @Sendable (String, String) -> Void
    private let lock = NSLock()
    private let writeIntervalNS: UInt64 = 5_000_000_000
    private var lastWriteNS: UInt64 = 0
    private var dirty = false
    private var saveReported = false
    private var failureActive = false

    init(
        url: URL,
        atlas: SphericalSceneAtlasStore,
        expectedEncoder: String,
        expectedRevision: Int,
        onHealth: @escaping @Sendable (String, String) -> Void
    ) {
        self.url = url
        self.atlas = atlas
        self.expectedEncoder = expectedEncoder
        self.expectedRevision = expectedRevision
        self.onHealth = onHealth
    }

    func restore() {
        do {
            guard let snapshot = try SphericalPlaceMemoryFile.load(
                from: url,
                expectedEncoder: expectedEncoder,
                expectedRevision: expectedRevision
            ) else {
                onHealth(
                    "empty",
                    "schema=1; encoder=\(expectedEncoder); revision=\(expectedRevision); path=\(String(url.path.prefix(192)))"
                )
                return
            }
            let restored = atlas.restorePlaceMemory(
                snapshot,
                expectedEncoder: expectedEncoder,
                expectedRevision: expectedRevision
            )
            onHealth(
                "restored",
                "schema=1; encoder=\(expectedEncoder); revision=\(expectedRevision); cells=\(restored); path=\(String(url.path.prefix(192)))"
            )
        } catch {
            onHealth("rejected", String(error.localizedDescription.prefix(192)))
        }
    }

    func recordObservation(at monotonicNS: UInt64) {
        lock.lock()
        dirty = true
        let shouldWrite = lastWriteNS == 0 || monotonicNS - lastWriteNS >= writeIntervalNS
        lock.unlock()
        if shouldWrite { persist(at: monotonicNS, force: false) }
    }

    func flush(at monotonicNS: UInt64) {
        persist(at: monotonicNS, force: true)
    }

    private func persist(at monotonicNS: UInt64, force: Bool) {
        lock.lock()
        guard dirty,
              force || lastWriteNS == 0 || monotonicNS - lastWriteNS >= writeIntervalNS else {
            lock.unlock()
            return
        }
        dirty = false
        lastWriteNS = monotonicNS
        lock.unlock()

        let unixMilliseconds = UInt64(max(0, Date().timeIntervalSince1970 * 1_000))
        let snapshot = atlas.placeMemorySnapshot(
            generatedAtUnixMilliseconds: unixMilliseconds
        )
        do {
            try SphericalPlaceMemoryFile.write(snapshot, to: url)
            lock.lock()
            let report = !saveReported || failureActive
            saveReported = true
            failureActive = false
            lock.unlock()
            if report {
                onHealth(
                    "saved",
                    "schema=1; encoder=\(expectedEncoder); revision=\(expectedRevision); cells=\(snapshot.cells.count); path=\(String(url.path.prefix(192)))"
                )
            }
        } catch {
            lock.lock()
            dirty = true
            let report = !failureActive
            failureActive = true
            lock.unlock()
            if report { onHealth("write_error", String(error.localizedDescription.prefix(192))) }
        }
    }
}

/// Actual physical memory impact (resident + compressed + swapped) of this
/// process, as reported by the kernel. RSS alone hides compressed pages, which
/// is exactly how the IOSurface leak looked "small" while the machine was
/// thrashing.
private struct TaskMemorySnapshot {
    let physicalFootprint: UInt64
    let resident: UInt64
    let internalBytes: UInt64
    let externalBytes: UInt64
    let reusableBytes: UInt64
    let compressed: UInt64
    let purgeableNonvolatile: UInt64
    let purgeableVolatile: UInt64
    let graphicsFootprint: UInt64
    let neuralFootprint: UInt64

    var diagnosticMessage: String {
        func megabytes(_ value: UInt64) -> UInt64 { value / 1_000_000 }
        return "phys_footprint=\(megabytes(physicalFootprint))MB; resident=\(megabytes(resident))MB; internal=\(megabytes(internalBytes))MB; external=\(megabytes(externalBytes))MB; reusable=\(megabytes(reusableBytes))MB; compressed=\(megabytes(compressed))MB; purgeable_nonvolatile=\(megabytes(purgeableNonvolatile))MB; purgeable_volatile=\(megabytes(purgeableVolatile))MB; graphics=\(megabytes(graphicsFootprint))MB; neural=\(megabytes(neuralFootprint))MB"
    }
}

private func currentTaskMemorySnapshot() -> TaskMemorySnapshot? {
    var info = task_vm_info()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    guard result == KERN_SUCCESS else { return nil }
    return TaskMemorySnapshot(
        physicalFootprint: UInt64(info.phys_footprint),
        resident: UInt64(info.resident_size),
        internalBytes: UInt64(info.internal),
        externalBytes: UInt64(info.external),
        reusableBytes: UInt64(info.reusable),
        compressed: UInt64(info.compressed),
        purgeableNonvolatile: UInt64(max(0, info.ledger_purgeable_nonvolatile)),
        purgeableVolatile: UInt64(max(0, info.ledger_purgeable_volatile)),
        graphicsFootprint: UInt64(max(0, info.ledger_tag_graphics_footprint)),
        neuralFootprint: UInt64(max(0, info.ledger_tag_neural_footprint))
    )
}

private func run(_ options: Options) throws {
    let termination = GracefulShutdown(signals: [SIGTERM, SIGINT])
    try requestAccess(for: .video, label: "camera")
    try requestAccess(for: .audio, label: "microphone")
    guard let videoDevice = obsbotDevice(for: .video, uniqueID: options.videoID) else {
        throw RuntimeError.unavailable("The requested OBSBOT video device is unavailable")
    }
    guard let audioDevice = obsbotDevice(for: .audio, uniqueID: options.audioID) else {
        throw RuntimeError.unavailable("The requested OBSBOT microphone is unavailable")
    }
    let selectedFormat = try requestLowLatencyFormat(on: videoDevice)

    let writer = try JSONLWriter(
        url: options.outputURL,
        rotationPolicy: options.traceRotationPolicy,
        importantURL: options.importantOutputURL,
        importantRotationPolicy: options.importantRotationPolicy
    )
    defer { writer.close() }
    // Memory watchdog: a detector/context leak once ballooned phys_footprint
    // to ~57 GB (IOSurface growth). RSS-based checks would have missed it, so
    // watch the kernel footprint and exit for launchd to restart us long
    // before the system starts swapping. 12 GB is ~2x the steady-state
    // footprint (models + buffers) and far below the leak trajectory.
    let footprintLimitBytes: UInt64 = 12 * 1_000_000_000
    Task {
        var warningWasReported = false
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard let memory = currentTaskMemorySnapshot() else { continue }
            if memory.physicalFootprint <= 8 * 1_000_000_000 {
                warningWasReported = false
            } else if !warningWasReported {
                warningWasReported = true
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: monotonicNanoseconds(),
                    source: "memory_watchdog",
                    state: "warning",
                    message: memory.diagnosticMessage
                ))
            }
            guard memory.physicalFootprint > footprintLimitBytes else { continue }
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNanoseconds(),
                source: "memory_watchdog",
                state: "critical",
                message: "\(memory.diagnosticMessage); limit=\(footprintLimitBytes / 1_000_000)MB; exiting_for_launchd_restart=true"
            ))
            exit(0)
        }
    }
    let liveDiagnostics = LiveDiagnosticsWriter(
        rootURL: options.outputURL.deletingLastPathComponent().deletingLastPathComponent()
    )
    let l1CurrentFrameRelay = L1CurrentFrameRelay(
        directoryURL: options.outputURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("volatile", isDirectory: true)
    )
    defer { l1CurrentFrameRelay.removeRetainedFrame() }
    let controlSettings: SOMAControlSettings
    do {
        controlSettings = try SOMAControlSettingsStore(fileURL: options.controlSettingsURL).load()
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: monotonicNanoseconds(),
            source: "control_settings",
            state: "loaded",
            message: "voice=\(controlSettings.realtimeVoice.rawValue); voice_enabled=\(controlSettings.realtimeVoiceEnabled); active_turn_eye_contact=\(controlSettings.realtimeVoiceRequiresEyeContactForEveryTurn); hermes_agent=\(controlSettings.hermesAgentDelegationEnabled); led=\(controlSettings.led.responseMode.rawValue); brightness=\(controlSettings.led.brightness); led_signals=\(controlSettings.led.signals.count); admin_enrolled=\(controlSettings.administrator != nil)"
        ))
    } catch {
        controlSettings = .init()
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: monotonicNanoseconds(),
            source: "control_settings",
            state: "rejected",
            message: String(error.localizedDescription.prefix(192))
        ))
    }
    let discordConversationClient: SOMADiscordConversationClient?
    if controlSettings.discord.isConfigured {
        do {
            if let token = try SOMADiscordSecretStore().loadToken() {
                discordConversationClient = SOMADiscordConversationClient(
                    settings: controlSettings.discord,
                    token: token
                )
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: monotonicNanoseconds(),
                    source: "discord_bridge",
                    state: "armed",
                    message: "channel_allowlisted=true; labmanager_allowlisted=true; token=sealed_owner_only_store; transcript_trace=false"
                ))
            } else {
                discordConversationClient = nil
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: monotonicNanoseconds(),
                    source: "discord_bridge",
                    state: "unavailable",
                    message: "discord_bot_token_missing"
                ))
            }
        } catch {
            discordConversationClient = nil
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNanoseconds(),
                source: "discord_bridge",
                state: "unavailable",
                message: String(error.localizedDescription.prefix(192))
            ))
        }
    } else {
        discordConversationClient = nil
    }
    let identityPresence = IdentityPresenceCoordinator(
        administrator: controlSettings.administrator,
        openWithUnknownIdentity: somaEnvBool("SOMA_L1_OPEN_WITH_UNKNOWN", default: false)
    )
    let presentIdentityRoster = PresentIdentityRoster()
    let latestPrimaryIdentity = LatestIdentityBox()
    // A dedicated always-current identity file lets the menu bar read the
    // present face without scanning a huge trace tail. The trace detail path is
    // <runtime>/detail/<prefix>; the runtime root is two levels up.
    let identityStateURL = options.outputURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("identity-current.json")
    clearIdentityState(at: identityStateURL)
    let liveSessionCapabilities = SOMASessionCapabilityStore()
    let persistentLiveVoiceBroker: PersistentAppServerBroker?
    if options.l2LiveVoice, controlSettings.realtimeVoiceEnabled {
        do {
            let broker = try PersistentAppServerBroker(
                capability: UUID().uuidString.lowercased(),
                onHealth: { state, message in
                    writer.write(RuntimeEvent(
                        event: "source.health",
                        monotonicNS: monotonicNanoseconds(),
                        source: "l2_app_server_broker",
                        state: state,
                        message: message
                    ))
                }
            )
            persistentLiveVoiceBroker = broker
            switch broker.ensureReady() {
            case .success:
                break
            case let .failure(error):
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: monotonicNanoseconds(),
                    source: "l2_app_server_broker",
                    state: "unavailable",
                    message: String(error.localizedDescription.prefix(192))
                ))
            }
        } catch {
            persistentLiveVoiceBroker = nil
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNanoseconds(),
                source: "l2_app_server_broker",
                state: "unavailable",
                message: String(error.localizedDescription.prefix(192))
            ))
        }
    } else {
        persistentLiveVoiceBroker = nil
    }
    defer { persistentLiveVoiceBroker?.stop() }
    let configuredDeviceContract = ProcessInfo.processInfo.environment["SOMA_OBSBOT_CAPABILITY_CONTRACT"]
        .flatMap(OBSBOTDeviceContract.parse)
    let configuredDeviceProfile = configuredDeviceContract?.knownProfile
    let spatialAtlas = SphericalSceneAtlasStore(
        kinematicEnvelope: configuredDeviceProfile?.kinematicEnvelope ?? .obsbotTiny2Lite
    )
    let placeEmbeddingEncoder = PanoramaPlaceEmbedding.cpuSpatialSignatureEncoder
    let placeEmbeddingRevision = 1
    let placeMemoryPersistence = options.panoramaPlaceMemoryURL.map { memoryURL in
        PanoramaPlaceMemoryPersistence(
            url: memoryURL,
            atlas: spatialAtlas,
            expectedEncoder: placeEmbeddingEncoder,
            expectedRevision: placeEmbeddingRevision,
            onHealth: { state, message in
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: monotonicNanoseconds(),
                    source: "panorama_place_memory",
                    state: state,
                    message: message
                ))
            }
        )
    }
    placeMemoryPersistence?.restore()
    let panoramaStatus = PanoramaMapStatusStore()
    let auxiliaryWakeRelay = L1AuxiliaryWakeRelay()
    let auxiliaryHumanVerdictRelay = L1AuxiliaryHumanVerdictRelay()
    let l1AuxiliaryBridgeBox = L1AuxiliaryBridgeBox()
    let poseStoreBox = PoseStoreBox()
    let memoryContextBox = MemoryContextBox()
    let spaceCoordinator = SpaceCoordinator(
        directoryURL: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SOMA/memory", isDirectory: true),
        onHealth: { state, message in
            writer.write(RuntimeEvent(
                event: "l1.space_trigger",
                monotonicNS: DispatchTime.now().uptimeNanoseconds,
                source: "l1_space_trigger",
                state: state,
                message: message
            ))
        },
        classifySpace: performL1SpaceClassification
    )
    let objectKnowledgeStore = ObjectKnowledgeStore()
    let objectRecognitionQueue = ObjectRecognitionQueue(
        maxPending: 4,
        cooldownMilliseconds: 20_000
    ) { item in
        let result = performL1ObjectIdentification(jpeg: item.jpeg)
        let atNS = DispatchTime.now().uptimeNanoseconds
        if let data = result.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let name = obj["name"] as? String {
            let category = obj["category"] as? String ?? ""
            let description = obj["description"] as? String ?? obj["raw"] as? String ?? ""
            objectKnowledgeStore.record(
                name: name,
                category: category,
                description: description,
                panDegrees: item.panDegrees,
                tiltDegrees: item.tiltDegrees,
                atNS: atNS
            )
            // Persist into a durable taste/preference profile. If a person was
            // present and engaged with the object, attribute it to them
            // directly; otherwise bind it to the home space, neutral until the
            // space owner is learned (then promoted to the owner).
            var factState = "space_bound"
            if let entityID = item.personEntityID {
                if let provider = memoryContextBox.provider {
                    let fact = "The user has/collects \(name)\(category.isEmpty ? "" : " (\(category))"). Hobby/taste item worth remembering."
                    let stored = l1StorePersonFact(provider, for: entityID, fact: fact)
                    factState = stored.contains("\"ok\":true") ? "person_stored" : "store_failed"
                } else {
                    factState = "provider_unavailable"
                }
            } else if let provider = memoryContextBox.provider {
                let stored = l1StoreSpaceObject(
                    provider,
                    name: name,
                    category: category,
                    description: description,
                    spaceID: spaceCoordinator.currentSpaceID
                )
                factState = stored.contains("\"ok\":true") ? "space_bound" : "store_failed"
            }
            writer.write(RuntimeEvent(
                event: "l1.object_recognition",
                monotonicNS: atNS,
                source: "l1_object_recognition",
                state: "recognized",
                message: "name=\(name); category=\(category); person_fact=\(factState)"
            ))
        } else {
            writer.write(RuntimeEvent(
                event: "l1.object_recognition",
                monotonicNS: atNS,
                source: "l1_object_recognition",
                state: "failed",
                message: String(result.prefix(200))
            ))
        }
    }
    let liveCameraFrameRelay = options.l2LiveVoice && controlSettings.realtimeVoiceEnabled
        ? LiveCameraFrameRelay()
        : nil
    // The L1 and L2 paths share this arbiter whether or not the external MCP
    // socket is exposed. Transport availability must not change L1's semantic
    // view of the scene or its lease contract with L0.
    let embodimentArbiter = ShadowEmbodimentArbiter(
        spatialAtlas: spatialAtlas,
        panoramaStatus: panoramaStatus,
        physicalActuationEnabled: options.allowEmbodimentMotorControl
    )
    let l1AuxiliarySemanticBridge: L1AuxiliarySemanticBridge?
    if let pythonURL = options.l1AuxiliaryVLMPythonURL,
       let workerURL = options.l1AuxiliaryVLMWorkerURL,
       let model = options.l1AuxiliaryVLMModel {
        l1AuxiliarySemanticBridge = try L1AuxiliarySemanticBridge(
            pythonURL: pythonURL,
            workerURL: workerURL,
            model: model,
            wakeMinimumScore: somaEnvDouble("SOMA_L0_E2B_WAKE_SCORE", default: 0.65),
            wakeMinimumConfidence: somaEnvDouble("SOMA_L0_E2B_WAKE_CONFIDENCE", default: 0.55),
            semanticRefreshIntervalMilliseconds: UInt64(somaEnvDouble("SOMA_L0_E2B_WAKE_INTERVAL_MS", default: 5_000)),
            onHealth: { state, message in
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: monotonicNanoseconds(),
                    source: "l1_auxiliary_vlm",
                    state: state,
                    message: message
                ))
            },
            onCue: { cue in
                writer.write(L1AuxiliarySemanticTraceEvent(cue))
                auxiliaryHumanVerdictRelay.record(cue)
                // Parallel object recognition: when L1's visual helper flags an
                // object (presented to the robot, or encountered while scanning
                // an environment with no dominant person) that is worth talking
                // about, enqueue it. A bounded worker drains the queue one at a
                // time with a pacing pause, asking the Gemma model to identify
                // each object in an independent inference — separate from the
                // conscious-stream cycle.
                let notableObject = cue.attentionHint == .object
                    || (cue.situation == .objectPresentation && !cue.objectLabel.isEmpty)
                let emptyExploration = cue.socialPresence < 0.3
                    && cue.situation != .socialBid
                // Feed stable empty-room background to the space trigger so it
                // can accumulate evidence and, once enough accumulates, ask L1
                // to classify the current room and detect space transitions.
                if emptyExploration,
                   let backgroundJPEG = l1AuxiliaryBridgeBox.bridge?.latestFrameJPEG() {
                    spaceCoordinator.observeBackground(jpeg: backgroundJPEG, at: Date())
                }
                let worthTalkingAbout = cue.conversationValue
                    >= somaEnvDouble("SOMA_OBJECT_CONVERSATION_THRESHOLD", default: 0.55)
                if (notableObject || emptyExploration), worthTalkingAbout,
                   let jpeg = l1AuxiliaryBridgeBox.bridge?.latestFrameJPEG() {
                    // Capture where the camera was looking when this object was
                    // detected, so the inventory is spatially grounded. Pose is
                    // read now (not after the async inference) because the scan
                    // keeps moving while Gemma identifies the object.
                    let seenPose = poseStoreBox.store?.latest(
                        at: cue.captureNS,
                        maximumAgeNS: 250_000_000
                    )
                    let posePan: Double? = seenPose.flatMap { $0.panDegrees.isFinite ? $0.panDegrees : nil }
                    let poseTilt: Double? = seenPose.flatMap { $0.pitchDegrees.isFinite ? $0.pitchDegrees : nil }
                    // Attribute to the actually-present person only. If no one
                    // is engaged (empty-exploration object), personEntityID is
                    // nil and the object is bound to the home space instead of
                    // being attributed to a person prematurely.
                    let personEntityID = identityPresence.recognizedPersonEntityID()
                    objectRecognitionQueue.enqueue(ObjectRecognitionQueue.Item(
                        jpeg: jpeg,
                        panDegrees: posePan,
                        tiltDegrees: poseTilt,
                        summary: cue.summary,
                        objectLabel: cue.objectLabel,
                        personEntityID: personEntityID
                    ))
                    writer.write(RuntimeEvent(
                        event: "l1.object_recognition",
                        monotonicNS: cue.completedNS,
                        source: "l1_object_recognition",
                        state: "queued",
                        message: "label=\(cue.objectLabel); conversation_value=\(String(format: "%.2f", cue.conversationValue)); summary=\(String(cue.summary.prefix(80)))"
                    ))
                }
            },
            onInterrupt: { interrupt in
                auxiliaryWakeRelay.record(interrupt)
                writer.write(L1AuxiliarySemanticInterruptTraceEvent(interrupt))
            }
        )
        l1AuxiliaryBridgeBox.bridge = l1AuxiliarySemanticBridge
    } else {
        l1AuxiliarySemanticBridge = nil
    }
    defer { l1AuxiliarySemanticBridge?.stop() }
    let loadedDirectionCalibration: StereoDirectionCalibration?
    if let calibrationURL = options.tdoaCalibrationURL {
        do {
            let calibration = try JSONDecoder().decode(StereoDirectionCalibration.self, from: Data(contentsOf: calibrationURL))
            guard calibration.schemaVersion == 1 else {
                throw RuntimeError.invalidArgument("Unsupported TDOA calibration schema: \(calibration.schemaVersion)")
            }
            loadedDirectionCalibration = calibration
        } catch let error as RuntimeError {
            throw error
        } catch {
            throw RuntimeError.invalidArgument("Cannot read TDOA calibration: \(error.localizedDescription)")
        }
    } else {
        loadedDirectionCalibration = nil
    }
    let externalGimbalCalibration: ExternalGimbalCalibration?
    if let calibrationURL = options.externalGimbalCalibrationURL {
        do {
            let calibration = try JSONDecoder().decode(ExternalGimbalCalibration.self, from: Data(contentsOf: calibrationURL))
            guard calibration.isValid else {
                throw RuntimeError.invalidArgument("External gimbal calibration must have schema 1, signs of -1 or 1, pan 0...180, and pitch 0...90")
            }
            if let contract = configuredDeviceContract {
                guard calibration.matches(deviceIdentifier: contract.profileID) else {
                    let calibrationDevice = calibration.deviceIdentifier ?? "an unspecified device"
                    throw RuntimeError.invalidArgument("External gimbal calibration belongs to \(calibrationDevice), not \(contract.profileID)")
                }
                if contract.capabilities.requiresMeasuredAttitudeFrame,
                   !calibration.hasMeasuredAttitudeAxes {
                    throw RuntimeError.invalidArgument("\(contract.profileID) requires measured image, device-attitude, and velocity axis signs")
                }
            }
            externalGimbalCalibration = calibration
        } catch let error as RuntimeError {
            throw error
        } catch {
            throw RuntimeError.invalidArgument("Cannot read external gimbal calibration: \(error.localizedDescription)")
        }
    } else {
        externalGimbalCalibration = nil
    }
    let cameraGeometryCalibration: CameraGeometryCalibration?
    if let calibrationURL = options.cameraGeometryCalibrationURL {
        do {
            let calibration = try JSONDecoder().decode(
                CameraGeometryCalibration.self,
                from: Data(contentsOf: calibrationURL)
            )
            guard calibration.isValid else {
                throw RuntimeError.invalidArgument("Camera geometry calibration failed schema, optical, or residual validation")
            }
            cameraGeometryCalibration = calibration
        } catch let error as RuntimeError {
            throw error
        } catch {
            throw RuntimeError.invalidArgument("Cannot read camera geometry calibration: \(error.localizedDescription)")
        }
    } else {
        cameraGeometryCalibration = nil
    }
    let calibrationRecorder = options.tdoaCalibrationOutputURL.map { _ in TDOACalibrationRecorder() }
    let worldModel = PredictiveWorldModel()
    let counters = LatencyCounters()
    let poseStore = GimbalPoseStore(geometryCalibration: cameraGeometryCalibration)
    if let profile = configuredDeviceProfile, let configuredDeviceContract {
        poseStore.configureDeviceProfile(
            profile,
            capabilities: configuredDeviceContract.capabilities,
            deviceIdentifier: configuredDeviceContract.profileID,
            calibration: externalGimbalCalibration
        )
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: monotonicNanoseconds(),
            source: "obsbot_device",
            state: "profile_preflight",
            message: "profile=\(profile.rawValue); source=sdk_launcher; contract=native"
        ))
    } else if let contract = configuredDeviceContract {
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: monotonicNanoseconds(),
            source: "obsbot_device",
            state: "adapter_required",
            message: "profile=\(contract.profileID); native_bridge=\(contract.supportsNativeBridge); sensory_runtime_available=true"
        ))
    }
    poseStoreBox.store = poseStore
    let panoramaPoseProjection: GimbalPoseProjection = externalGimbalCalibration?.poseProjection ?? .identity
    let panoramaCompositor = try options.panoramaOutputURL.map { outputURL in
        try RollingPanoramaCompositor(
            outputURL: outputURL,
            geometryCaptureDirectoryURL: options.cameraGeometryCaptureDirectoryURL,
            statusStore: panoramaStatus,
            poseProjection: panoramaPoseProjection,
            kinematicEnvelope: configuredDeviceProfile?.kinematicEnvelope ?? .obsbotTiny2Lite,
            poseAtCapture: { poseStore.captureAlignedPose(at: $0) },
            onSpatialObservation: { pose, horizontalFieldOfViewDegrees, cameraProjectionModel, dynamicVisionRects, frameQuality, embedding, monotonicNS in
                spatialAtlas.observePanorama(
                    pose: pose,
                    horizontalFieldOfViewDegrees: horizontalFieldOfViewDegrees,
                    frameQuality: frameQuality,
                    dynamicVisionRects: dynamicVisionRects,
                    poseProjection: panoramaPoseProjection,
                    cameraProjectionModel: cameraProjectionModel,
                    at: monotonicNS
                )
                guard let embedding else { return nil }
                let recognition = spatialAtlas.observePlace(
                    embedding: embedding,
                    pose: pose,
                    observationQuality: frameQuality,
                    at: monotonicNS
                )
                if recognition != nil {
                    placeMemoryPersistence?.recordObservation(at: monotonicNS)
                }
                return recognition
            },
            onHealth: { state, message in
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: monotonicNanoseconds(),
                    source: "panorama",
                    state: state,
                    message: message
                ))
            }
        )
    }
    if let panoramaCompositor {
        l1CurrentFrameRelay.setEncodedFrameObserver { jpeg, captureNS in
            panoramaCompositor.submitEncodedJPEG(jpeg, captureNS: captureNS)
        }
    }
    defer {
        panoramaCompositor?.stop()
        placeMemoryPersistence?.flush(at: monotonicNanoseconds())
    }
    if let outputURL = options.panoramaOutputURL {
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: monotonicNanoseconds(),
            source: "panorama",
            state: "configured",
            message: "projection=equirectangular_band; resolution=1024x256; elevation=-45...45; max_hz=4; pose_wait_ms=125; max_pose_distance_ms=120; max_bracket_ms=200; registration=lucas_kanade_cpu; photometric=cpu_channel_gain; seam=quality_weighted; place_encoder=\(placeEmbeddingEncoder); place_revision=\(placeEmbeddingRevision); rolling_output=\(String(outputURL.path.prefix(192)))"
        ))
    }
    if let cameraGeometryCalibration {
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: monotonicNanoseconds(),
            source: "camera_geometry",
            state: "calibrated",
            message: String(
                format: "schema=%d; fov_mode=%d; horizontal_degrees=%.4f; vertical_degrees=%.4f; pairs=%d; rmse_px=%.3f; p90_px=%.3f",
                cameraGeometryCalibration.schemaVersion,
                cameraGeometryCalibration.fovMode,
                cameraGeometryCalibration.projection.horizontalFieldOfViewDegrees,
                cameraGeometryCalibration.projection.verticalFieldOfViewDegrees,
                cameraGeometryCalibration.fittedPairs,
                cameraGeometryCalibration.calibratedRMSEPixels,
                cameraGeometryCalibration.calibratedP90Pixels
            )
        ))
    }
    let complete = DispatchSemaphore(value: 0)
    let conversationContact = ConversationContactRuntime()
    let faceLockDiagnosticRecorder = try options.faceLockDiagnosticDirectoryURL.map {
        try FaceLockDiagnosticRecorder(directoryURL: $0)
    }
    let embodimentViewCaptureStore = try options.embodimentViewDirectoryURL.map { directoryURL in
        try EmbodimentViewCaptureStore(
            directoryURL: directoryURL,
            onHealth: { state, message in
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: monotonicNanoseconds(),
                    source: "embodiment_view",
                    state: state,
                    message: message
                ))
            }
        )
    }
    let attentionGimbalBridge: AttentionGimbalBridge?
    if let helperURL = options.nativeGimbalHelperURL, let gimbalOutputURL = options.gimbalOutputURL {
        // Native human tracking owns only a confirmed face. Keep the external
        // coverage controller available for the genuine no-human state.
        let autonomousExplorationEnabled = options.allowAutonomousScan
            && options.allowCameraMotion
            && somaEnvBool("SOMA_L0_EXPLORE_ENABLED", default: controlSettings.autonomousExplorationEnabled)
        attentionGimbalBridge = try AttentionGimbalBridge(
            helperURL: helperURL,
            shutdownHelperURL: options.nativeGimbalShutdownHelperURL,
            outputURL: gimbalOutputURL,
            traceRotationPolicy: options.gimbalTraceRotationPolicy,
            duration: options.duration,
            externalCalibration: externalGimbalCalibration,
            autonomousScanEnabled: autonomousExplorationEnabled,
            idleExplorationEnabled: autonomousExplorationEnabled,
            nativeHumanTrackingEnabled: options.allowNativeHumanTracking
                && somaEnvBool("SOMA_L0_TRACKING_ENABLED", default: controlSettings.nativeHumanTrackingEnabled),
            ledSettings: controlSettings.led,
            calibrationOutputURL: options.externalGimbalCalibrationOutputURL,
            cameraGeometryCalibrationMode: options.cameraGeometryCaptureDirectoryURL != nil,
            panoramaStripScanMode: options.panoramaStripScan,
            poseStore: poseStore,
            spatialAtlas: spatialAtlas,
            faceLockDiagnosticRecorder: faceLockDiagnosticRecorder,
            embodimentViewCaptureStore: embodimentViewCaptureStore,
            onL0FaceFixation: { sceneID, directContact, observedNS in
                guard let state = conversationContact.observeL0FaceFixation(
                    sceneID: sceneID,
                    directContact: directContact,
                    at: observedNS
                ) else {
                    return
                }
                // Direct/averted updates are frame-rate perception state;
                // emitting each landmark fluctuation would drown out the
                // interaction timeline. Only an anchor clear is a durable
                // control transition worth retaining in the runtime trace.
                guard state == .absent else { return }
                writer.write(RuntimeEvent(
                    event: "human.interaction",
                    monotonicNS: observedNS,
                    source: "conversation_contact",
                    state: "l0_face_fixation_absent",
                    message: "voice_opening_anchor=cleared"
                ))
            },
            writer: writer
        )
        attentionGimbalBridge?.recognizedIdentityProvider = {
            latestPrimaryIdentity.snapshot()?.label
        }
        auxiliaryHumanVerdictRelay.attach { cue in
            attentionGimbalBridge?.ingestSemanticHumanVerdict(cue)
        }
    } else {
        attentionGimbalBridge = nil
    }
    defer { attentionGimbalBridge?.stop() }
    // On stop (menu bar "Stop SOMA" = launchctl bootout), turn off the camera's
    // built-in AI tracking and park the gimbal before the process exits.
    termination.onTerminate { attentionGimbalBridge?.stop() }
    let l1LanguageInstructions = L1LanguageInstructionCache(
        onHealth: { state, message in
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNanoseconds(),
                source: "l1_language_instruction",
                state: state,
                message: message
            ))
        },
        onReady: { _, _ in }
    )
    // Pre-warm the L1 model so the first concurrent requests (including the
    // language-directive generation) are not rejected with done_reason == "load"
    // while the model is still loading.
    warmUpL1Model()
    let l1ThoughtRelay = L1ThoughtStreamRelay()
    let l1LiveConversationState = L1LiveConversationStateRelay()
    let l1MemoryContext = L1MemoryContextProvider(
        onHealth: { state, message in
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNanoseconds(),
                source: "l1_memory",
                state: state,
                message: message
            ))
        },
        onPreferredLanguageChanged: { _, languageTag in
            l1LanguageInstructions.prepare(for: languageTag)
        },
        onSocialContactPersisted: { personEntityID in
            l1ThoughtRelay.invalidateMemoryContext(for: personEntityID)
        },
        transcriptRetentionSeconds: somaEnvDouble("SOMA_MEMORY_SHORT_TERM_RETENTION_HOURS", default: 24) * 60 * 60
    )
    memoryContextBox.provider = l1MemoryContext
    Task {
        await l1MemoryContext.recoverPendingConversationMemories()
    }
    if let administratorID = controlSettings.administrator?.entityID {
        l1MemoryContext.warmContext(for: administratorID)
        Task {
            await l1MemoryContext.seedAdministratorContext(
                entityID: administratorID,
                preferredAddress: controlSettings.administrator?.preferredAddress,
                displayName: controlSettings.administrator?.displayName
            )
        }
    }
    let dailyWorldMemoryRelay = L1DailyWorldMemoryRelay()
    let dailyWorldMemoryCollector = AppServerDailyWorldMemoryCollector(
        onWorldMemory: { memory in
            dailyWorldMemoryRelay.publish(memory)
            Task {
                await l1MemoryContext.storeDailyWorldMemory(memory)
            }
        },
        onHealth: { state, message in
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNanoseconds(),
                source: "daily_world_memory",
                state: state,
                message: message
            ))
        }
    )
    Task {
        let current = await l1MemoryContext.currentDailyWorldMemory()
        dailyWorldMemoryRelay.publish(current)
        guard current == nil,
              await l1MemoryContext.claimDailyWorldMemoryCollectionSlot() else {
            return
        }
        dailyWorldMemoryCollector.collectIfNeeded(current: current)
    }
    defer { dailyWorldMemoryCollector.stop() }
    // Language detected from the participant's most recent speech. L1 and L2
    // both read this so a person who speaks first in a language is answered in
    // that same language even without a stored preferred language.
    let activeLanguage = L1ActiveLanguage()
    let visualSpeakerAttribution = VisualSpeakerAttributionStore()
    let recentAcousticOnset = RecentAcousticOnsetStore()
    let speechInteractionBox = SpeechInteractionBox()
    let liveVoiceLauncher: AppServerLiveVoiceLauncher?
    let liveVoiceBox = LiveVoiceLauncherBox()
    let hermesAgentDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/SOMA/hermes-agent", isDirectory: true)
    let hermesAgentKey = try OwnerOnlyInstallationSecret.loadOrCreate(
        in: hermesAgentDirectory,
        filename: "installation-key-v1.bin"
    )
    let hermesAgentStore = try HermesAgentTaskStore(
        directoryURL: hermesAgentDirectory,
        encryptionKey: hermesAgentKey
    )
    let hermesAgentCoordinator = try HermesAgentTaskCoordinator(
        store: hermesAgentStore,
        enabled: controlSettings.hermesAgentDelegationEnabled,
        defaultWorkingDirectory: controlSettings.hermesAgentWorkspace
            ?? ProcessInfo.processInfo.environment["SOMA_ROOT"]
            ?? FileManager.default.currentDirectoryPath,
        onCompletion: { task in
            let delivered = liveVoiceBox.launcher?.deliverHermesTaskResult(task) ?? false
            writer.write(RuntimeEvent(
                event: "hermes.task",
                monotonicNS: monotonicNanoseconds(),
                source: "hermes_agent",
                state: delivered ? "result_delivery_requested" : "result_pending",
                message: "task_id=\(task.id.uuidString.lowercased()); status=\(task.status.rawValue)"
            ))
        },
        onHealth: { state, message in
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNanoseconds(),
                source: "hermes_agent",
                state: state,
                message: message
            ))
        }
    )
    defer { hermesAgentCoordinator.stop() }
    if options.l2LiveVoice, controlSettings.realtimeVoiceEnabled {
        let launcher = AppServerLiveVoiceLauncher(
            voice: controlSettings.realtimeVoice,
            currentCameraImageDataURI: {
                liveCameraFrameRelay?.currentImageDataURI(at: monotonicNanoseconds())
            },
            embodimentSocketURL: options.embodimentShadowSocketURL,
            requireVerifiedSpeakerForEveryTurn: controlSettings
                .realtimeVoiceRequiresEyeContactForEveryTurn,
            hermesAgentDelegationEnabled: controlSettings.hermesAgentDelegationEnabled,
            inactivityTimeoutMilliseconds: UInt64(
                controlSettings.realtimeVoiceSilenceTimeoutSeconds
            ) * 1_000,
            persistentAppServer: persistentLiveVoiceBroker,
            persistentSessionAuthorizer: { token, scope, at in
                liveSessionCapabilities.authorize(token: token, scope: scope, at: at)
            }
        ) { event in
            let eventNS = monotonicNanoseconds()
            switch event {
            case let .launchRequested(authorization, _):
                l1LiveConversationState.begin()
                liveCameraFrameRelay?.setEnabled(true)
                attentionGimbalBridge?.ingestLiveVoicePresentation(.ready)
                writer.write(RuntimeEvent(
                    event: "human.interaction",
                    monotonicNS: eventNS,
                    source: "l2_live_voice",
                    state: "launch_requested",
                    message: "authorization=\(authorization)"
                ))
            case let .active(threadID, personEntityID):
                l1LiveConversationState.begin()
                conversationContact.markConversationOpened(at: eventNS)
                attentionGimbalBridge?.ingestLiveVoicePresentation(.ready)
                if let personEntityID {
                    Task {
                        await l1MemoryContext.recordSocialContact(
                            .conversationOpened,
                            with: personEntityID,
                            purpose: "A Live voice conversation became active."
                        )
                    }
                }
                if let threadID {
                    l1MemoryContext.beginConversation(
                        threadID: threadID,
                        personEntityID: personEntityID
                    )
                }
                writer.write(RuntimeEvent(
                    event: "human.interaction",
                    monotonicNS: eventNS,
                    source: "l2_live_voice",
                    state: "active",
                    message: threadID.map { "thread_id=\(String($0.prefix(96)))" }
                ))
            case .inputTransportStarted:
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: eventNS,
                    source: "l2_live_voice",
                    state: "input_streaming",
                    message: "audio_worklet_to_webrtc"
                ))
            case let .inputBootstrapReplayed(durationMilliseconds, peakDBFS, maximumGainDB):
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: eventNS,
                    source: "l2_live_voice",
                    state: "opening_audio_replayed",
                    message: String(
                        format: "duration_ms=%.1f; input_peak_dbfs=%.1f; max_gain_db=%.1f",
                        durationMilliseconds,
                        peakDBFS,
                        maximumGainDB
                    )
                ))
            case .outputPlaybackReady:
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: eventNS,
                    source: "l2_live_voice",
                    state: "output_ready",
                    message: "webrtc_audio_to_system_output"
                ))
            case .naturalTurnTakingConfirmed:
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: eventNS,
                    source: "l2_live_voice",
                    state: "natural_turn_taking_confirmed",
                    message: "negotiated_session_interrupt_response=true"
                ))
            case .responseInterrupted:
                writer.write(RuntimeEvent(
                    event: "human.interaction",
                    monotonicNS: eventNS,
                    source: "l2_live_voice",
                    state: "response_interrupted",
                    message: "origin=participant_speech"
                ))
            case .interruptedAudioCleared:
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: eventNS,
                    source: "l2_live_voice",
                    state: "interrupted_audio_cleared",
                    message: "unheard_output_removed=true"
                ))
            case .proactiveOpeningTriggered:
                writer.write(RuntimeEvent(
                    event: "human.interaction",
                    monotonicNS: eventNS,
                    source: "l2_live_voice",
                    state: "opening_triggered",
                    message: "origin=controller_not_user_speech"
                ))
            case .proactiveOpeningExtraOutputSuppressed:
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: eventNS,
                    source: "l2_live_voice",
                    state: "proactive_opening_extra_output_suppressed",
                    message: "session_terminated_before_participant_turn"
                ))
            case let .hermesReportOfferStarted(taskID):
                let resolution = hermesAgentCoordinator.handle(.init(
                    operation: .markReportOffered,
                    taskID: taskID
                ))
                let state: String
                switch resolution {
                case .success: state = "report_offer_started"
                case .failure: state = "report_offer_rejected"
                }
                writer.write(RuntimeEvent(
                    event: "hermes.task",
                    monotonicNS: eventNS,
                    source: "l2_live_voice",
                    state: state,
                    message: "task_id=\(taskID.uuidString.lowercased())"
                ))
            case .hearingUser:
                l1LiveConversationState.setParticipantSpeaking(true)
                attentionGimbalBridge?.ingestLiveVoicePresentation(.hearingUser)
            case .visualContextAttached:
                writer.write(RuntimeEvent(
                    event: "human.interaction",
                    monotonicNS: eventNS,
                    source: "l2_live_voice",
                    state: "visual_context_attached",
                    message: "source=current_camera_frame; retention=live_turn_only"
                ))
            case let .visualContextRejected(reason):
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: eventNS,
                    source: "l2_live_voice",
                    state: "visual_context_rejected",
                    message: String(reason.prefix(192))
                ))
            case .embodimentMCPReady:
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: eventNS,
                    source: "l2_live_voice",
                    state: "embodiment_mcp_ready",
                    message: "capability_preflight=get_robot_body_state; capture_view_and_identity_tools_available"
                ))
            case .personContextReady:
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: eventNS,
                    source: "l2_live_voice",
                    state: "person_context_ready",
                    message: "capability_preflight=get_person_context; local_memory_binding=verified"
                ))
            case let .personContextUnavailable(reason):
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: eventNS,
                    source: "l2_live_voice",
                    state: "person_context_unavailable",
                    message: String(reason.prefix(192))
                ))
            case let .embodimentMCPUnavailable(reason):
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: eventNS,
                    source: "l2_live_voice",
                    state: "embodiment_mcp_unavailable",
                    message: String(reason.prefix(192))
                ))
            case let .embodimentMCPCall(tool, status, error):
                writer.write(RuntimeEvent(
                    event: "l2.mcp",
                    monotonicNS: eventNS,
                    source: "l2_live_voice",
                    state: status,
                    message: "tool=\(tool); error=\(error ?? "none")"
                ))
            case let .inputAccepted(characters):
                attentionGimbalBridge?.ingestLiveVoiceTurnAccepted()
                writer.write(RuntimeEvent(
                    event: "human.interaction",
                    monotonicNS: eventNS,
                    source: "l2_live_voice",
                    state: "input_transcript_ready",
                    message: "characters=\(min(characters, 65_535)); transcript_trace=false; local_archive=on_final"
                ))
            case let .transcriptFinalized(threadID, role, text):
                if role == .user {
                    // A finalized user transcript is the first reliable proof
                    // that the participant, rather than ambient audio, kept
                    // the live conversation active.
                    conversationContact.recordConversationActivity(at: eventNS)
                }
                writer.write(RuntimeEvent(
                    event: "l2.transcript",
                    monotonicNS: eventNS,
                    source: "l2_live_voice",
                    state: role == .user ? "user" : "assistant",
                    message: String(text.prefix(300))
                ))
                if let threadID {
                    l1MemoryContext.archiveConversationTurn(
                        threadID: threadID,
                        role: role,
                        rawText: text
                    )
                    if role == .user {
                        // Detect the participant's spoken language from their
                        // transcript so L1/L2 answer in the same language, and
                        // switch the on-device recognizer to that locale so
                        // subsequent turns transcribe more accurately.
                        if let detected = activeLanguage.detectAndSet(from: text) {
                            speechInteractionBox.coordinator?.setRecognitionLocale(detected)
                            writer.write(RuntimeEvent(
                                event: "source.health",
                                monotonicNS: monotonicNanoseconds(),
                                source: "l1_language",
                                state: "detected",
                                message: "language=\(detected)"
                            ))
                        }
                        Task {
                            await l1MemoryContext.captureUserPreferences(
                                threadID: threadID,
                                role: role,
                                rawText: text,
                                at: Date()
                            )
                        }
                    }
                }
                if role == .user,
                   controlSettings.discord.forwardAdministratorSpeech,
                   SOMADiscordConversationClient.shouldForwardTranscript(text),
                   let discordConversationClient,
                   identityPresence.currentParticipant()?.authority == .administrator {
                    Task {
                        do {
                            let reply = try await discordConversationClient.forwardAdministratorTranscript(
                                text,
                                conversationID: threadID
                            )
                            guard let reply else {
                                writer.write(RuntimeEvent(
                                    event: "source.health",
                                    monotonicNS: monotonicNanoseconds(),
                                    source: "discord_bridge",
                                    state: "reply_timeout",
                                    message: "labmanager_response_not_observed"
                                ))
                                return
                            }
                            let delivered = controlSettings.discord.readLabmanagerRepliesAloud
                                && (liveVoiceBox.launcher?.deliverDiscordReply(
                                    reply.content,
                                    messageID: reply.id
                                ) ?? false)
                            writer.write(RuntimeEvent(
                                event: "discord.message",
                                monotonicNS: monotonicNanoseconds(),
                                source: "discord_bridge",
                                state: delivered ? "reply_delivery_requested" : "reply_not_delivered",
                                message: "channel_allowlisted=true; author=labmanager; characters=\(reply.content.count)"
                            ))
                        } catch {
                            writer.write(RuntimeEvent(
                                event: "source.health",
                                monotonicNS: monotonicNanoseconds(),
                                source: "discord_bridge",
                                state: "request_failed",
                                message: String(error.localizedDescription.prefix(192))
                            ))
                        }
                    }
                }
            case .discordReplyAccepted:
                writer.write(RuntimeEvent(
                    event: "discord.message",
                    monotonicNS: eventNS,
                    source: "discord_bridge",
                    state: "reply_accepted_by_live_voice",
                    message: "controller_envelope=true; participant_authorization=false"
                ))
            case let .discordReplyRejected(reason):
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: eventNS,
                    source: "discord_bridge",
                    state: "reply_rejected_by_live_voice",
                    message: String(reason.prefix(192))
                ))
            case .preparingResponse:
                l1LiveConversationState.setParticipantSpeaking(false)
                attentionGimbalBridge?.ingestLiveVoicePresentation(.preparingResponse)
            case let .responseStarted(latencyMilliseconds):
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: eventNS,
                    source: "l2_live_voice",
                    state: "first_audio",
                    message: String(format: "turn_latency_ms=%.1f", latencyMilliseconds)
                ))
            case .assistantSpeechStarted:
                speechInteractionBox.coordinator?.setRemoteAssistantOutput(
                    active: true,
                    at: eventNS
                )
            case .assistantSpeechEnded:
                speechInteractionBox.coordinator?.setRemoteAssistantOutput(
                    active: false,
                    at: eventNS
                )
            case let .assistantOutputReferenceReady(sampleRate, samples):
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: eventNS,
                    source: "l2_live_voice",
                    state: "output_reference_ready",
                    message: "sample_rate=\(sampleRate); samples=\(samples)"
                ))
            case .microphoneCaptureSuppressed:
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: eventNS,
                    source: "l2_live_voice",
                    state: "microphone_quarantined",
                    message: "assistant_output_active=true"
                ))
            case let .playbackEchoAssessed(relationship, correlation):
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: eventNS,
                    source: "l2_live_voice",
                    state: "playback_echo_assessed",
                    message: String(
                        format: "relationship=%@; correlation=%.3f",
                        relationship.rawValue,
                        correlation
                    )
                ))
            case let .participantBargeInAdmitted(bufferedMilliseconds):
                writer.write(RuntimeEvent(
                    event: "human.interaction",
                    monotonicNS: eventNS,
                    source: "l2_live_voice",
                    state: "barge_in_admitted",
                    message: String(format: "verified_audio_ms=%.1f", bufferedMilliseconds)
                ))
            case .acousticEchoDiscarded:
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: eventNS,
                    source: "l2_live_voice",
                    state: "playback_echo_discarded",
                    message: "participant_evidence=false"
                ))
            case .responding:
                l1LiveConversationState.setParticipantSpeaking(false)
                conversationContact.recordConversationActivity(at: eventNS)
                attentionGimbalBridge?.ingestLiveVoicePresentation(.responding)
                writer.write(RuntimeEvent(
                    event: "human.interaction",
                    monotonicNS: eventNS,
                    source: "l2_live_voice",
                    state: "responding",
                    message: "output_audio=true"
                ))
            case .responseCompleted:
                l1LiveConversationState.setParticipantSpeaking(false)
                conversationContact.recordConversationActivity(at: eventNS)
                attentionGimbalBridge?.ingestLiveVoicePresentation(.ready)
            case let .ended(threadID, personEntityID, reason):
                l1LiveConversationState.end()
                liveCameraFrameRelay?.setEnabled(false)
                conversationContact.closeConversation()
                attentionGimbalBridge?.ingestLiveVoicePresentation(.inactive)
                Task {
                    await l1MemoryContext.endConversation(
                        threadID: threadID,
                        personEntityID: personEntityID,
                        interrupted: false,
                        reason: reason
                    )
                }
                writer.write(RuntimeEvent(
                    event: "human.interaction",
                    monotonicNS: eventNS,
                    source: "l2_live_voice",
                    state: "ended",
                    message: reason
                ))
            case let .hermesTaskResultAccepted(taskID):
                _ = hermesAgentCoordinator.handle(.init(
                    operation: .markReported,
                    taskID: taskID
                ))
                writer.write(RuntimeEvent(
                    event: "hermes.task",
                    monotonicNS: eventNS,
                    source: "l2_live_voice",
                    state: "result_accepted",
                    message: "task_id=\(taskID.uuidString.lowercased())"
                ))
            case let .hermesTaskResultRejected(taskID, reason):
                writer.write(RuntimeEvent(
                    event: "hermes.task",
                    monotonicNS: eventNS,
                    source: "l2_live_voice",
                    state: "result_delivery_rejected",
                    message: "task_id=\(taskID?.uuidString.lowercased() ?? "unknown"); reason=\(reason)"
                ))
            case let .failed(threadID, personEntityID, reason):
                l1LiveConversationState.end()
                liveCameraFrameRelay?.setEnabled(false)
                conversationContact.closeConversation()
                attentionGimbalBridge?.ingestLiveVoicePresentation(.inactive)
                if reason == "service_shutdown" {
                    _ = l1MemoryContext.endConversationBeforeShutdown(
                        threadID: threadID,
                        personEntityID: personEntityID,
                        reason: reason
                    )
                } else {
                    Task {
                        await l1MemoryContext.endConversation(
                            threadID: threadID,
                            personEntityID: personEntityID,
                            interrupted: true,
                            reason: reason
                        )
                    }
                }
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: eventNS,
                    source: "l2_live_voice",
                    state: "failed",
                    message: String(reason.prefix(192))
                ))
            }
        }
        liveVoiceBox.launcher = launcher
        liveVoiceLauncher = launcher
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: monotonicNanoseconds(),
            source: "l2_live_voice",
            state: "configured",
            message: "transport=codex_app_server_webrtc_audio; app_server=persistent_local_broker; idle_realtime=false; idle_model_turn=false; auth=chatgpt_account; voice=\(controlSettings.realtimeVoice.rawValue); contact_gate=joint_live_face_gaze_and_voice_evidence; speaker_attribution=face_gaze_lip_motion_plus_calibrated_doa; new_session_requires=interaction_liveness_plus_direct_gaze_plus_calibrated_or_sustained_voice; active_session_eye_contact=\(controlSettings.realtimeVoiceRequiresEyeContactForEveryTurn ? "required_per_turn" : "optional"); duplex_capture=preplayback_pcm_reference_plus_echo_safe_verified_barge_in; input_leveling=vad_bounded_agc_plus_timestamped_episode_replay; user_silence_timeout_seconds=\(controlSettings.realtimeVoiceSilenceTimeoutSeconds); hermes_task_routing=\(controlSettings.hermesAgentDelegationEnabled ? "enabled" : "disabled"); visual_context=session_opening_frame_only; mcp_capture_view=current_frame_or_reframe; mcp_status_checked=parallel_session_start; text_context=startup_context_plus_explicit_user_coupled_tools"
        ))
    } else {
        liveVoiceLauncher = nil
    }
    defer { liveVoiceLauncher?.stop() }
    // Gate for promoting a face to a registered anonymous identity: L1 reviews
    // the current frame and decides whether it is a real person worth tracking.
    let anonymousReviewBox = AnonymousReviewBox()
    anonymousReviewBox.reviewer = {
        guard let frame = l1CurrentFrameRelay.currentResource(at: monotonicNanoseconds()) else {
            return true
        }
        return performL1AnonymousReview(frameURL: URL(fileURLWithPath: frame.localPath), onHealth: { state, message in
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNanoseconds(),
                source: "l1_anonymous_review",
                state: state,
                message: message
            ))
        })
    }
    let l1EmbodimentRelay = L1EmbodimentToolRelay()
    defer { l1EmbodimentRelay.stop() }
    let l1EmbodimentTools = L1EmbodimentToolGateway(relay: l1EmbodimentRelay)
    let l1ToolExecutor: @Sendable (String, String) -> String = { [l1EmbodimentTools] name, arguments in
        if let result = l1EmbodimentTools.execute(name: name, arguments: arguments) {
            return result
        }
        switch name {
        case "get_person_context":
            guard let data = arguments.data(using: .utf8),
                  let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let idString = args["entity_id"] as? String,
                  let entityID = UUID(uuidString: idString) else {
                return #"{"ok":false,"error":"missing or invalid entity_id"}"#
            }
            return l1PersonContextSummary(l1MemoryContext, for: entityID)
        case "add_memory_fact":
            guard let data = arguments.data(using: .utf8),
                  let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let idString = args["entity_id"] as? String,
                  let entityID = UUID(uuidString: idString),
                  let fact = args["fact"] as? String else {
                return #"{"ok":false,"error":"missing entity_id or fact"}"#
            }
            return l1StorePersonFact(l1MemoryContext, for: entityID, fact: fact)
        case "recall_episodes":
            guard let data = arguments.data(using: .utf8),
                  let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let query = args["query"] as? String, !query.isEmpty else {
                return #"{"ok":false,"error":"missing query"}"#
            }
            let entityID = (args["entity_id"] as? String).flatMap(UUID.init(uuidString:))
            return l1RecallEpisodes(l1MemoryContext, query: query, entityID: entityID)
        case "set_space_owner":
            guard let data = arguments.data(using: .utf8),
                  let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let idString = args["entity_id"] as? String,
                  let entityID = UUID(uuidString: idString) else {
                return #"{"ok":false,"error":"missing or invalid entity_id"}"#
            }
            return l1SetSpaceOwner(l1MemoryContext, for: entityID, spaceID: spaceCoordinator.currentSpaceID)
        case "space_status":
            return l1SpaceStatus(l1MemoryContext, spaceID: spaceCoordinator.currentSpaceID)
        case "get_information_needs":
            let entityID = (arguments.data(using: .utf8).flatMap {
                (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["entity_id"] as? String
            }).flatMap(UUID.init(uuidString:))
            return l1GetInformationNeeds(l1MemoryContext, for: entityID)
        case "resolve_information_need":
            guard let data = arguments.data(using: .utf8),
                  let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let idString = args["motive_id"] as? String,
                  let motiveID = UUID(uuidString: idString) else {
                return #"{"ok":false,"error":"missing or invalid motive_id"}"#
            }
            return l1ResolveInformationNeed(
                l1MemoryContext,
                motiveID: motiveID,
                acquiredFact: args["acquired_fact"] as? String
            )
        case "web_search":
            guard let data = arguments.data(using: .utf8),
                  let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let query = args["query"] as? String, !query.isEmpty else {
                return #"{"ok":false,"error":"missing query"}"#
            }
            let maxResults = (args["max_results"] as? String).flatMap(Int.init) ?? 5
            return performL1WebSearch(query: query, maxResults: max(1, min(10, maxResults)))
        case "web_fetch":
            guard let data = arguments.data(using: .utf8),
                  let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let url = args["url"] as? String, !url.isEmpty else {
                return #"{"ok":false,"error":"missing url"}"#
            }
            return performL1WebFetch(url: url)
        default:
            return #"{"ok":false,"error":"unknown_tool"}"#
        }
    }
    let l1CuriosityCollector = L1CuriosityCollector { state, message in
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: monotonicNanoseconds(),
            source: "l1_curiosity",
            state: state,
            message: message
        ))
    }
    do {
        let l1ThoughtStream = try PersistentConsciousnessStream(
            memoryContext: l1MemoryContext,
            runtimeContext: {
                let nowNS = monotonicNanoseconds()
                let atlas = spatialAtlas.snapshot(at: nowNS)
                let panorama = panoramaStatus.snapshot()
                let placeIdentity = spaceCoordinator.currentIdentity
                let placeAffiliation = l1MemoryContext.cachedPlaceAffiliation(
                    spaceID: placeIdentity.id,
                    label: placeIdentity.label,
                    isStable: placeIdentity.label != nil
                )
                let expiresAt = Date().addingTimeInterval(60)
                let visualOffers: [L1VisualResourceOffer]
                if let panorama,
                   FileManager.default.fileExists(atPath: panorama.imagePath) {
                    visualOffers = [L1VisualResourceOffer(
                        resourceID: "spherical_atlas_current",
                        projection: .sphericalAtlas,
                        description: "Current rolling equirectangular panorama of the reachable camera space.",
                        expiresAt: expiresAt
                    )]
                } else {
                    visualOffers = []
                }
                return L1SituationRuntimeContext(
                    spatialContext: L1SpatialContext(
                        panoramaAvailable: panorama != nil,
                        panoramaRevision: panorama?.revision,
                        reachableCoverageFraction: panorama?.reachableCoverageFraction ?? 0,
                        reachableQualityCoverageFraction: panorama?.reachableQualityCoverageFraction ?? 0,
                        placeRevisits: panorama?.placeRevisits ?? 0,
                        activeSceneEntityCount: atlas.entities.count,
                        placeAffiliation: placeAffiliation
                    ),
                    dailyWorldMemory: dailyWorldMemoryRelay.snapshot(),
                    visualResourceOffers: visualOffers
                )
            },
            socialAvailability: {
                l1LiveConversationState.snapshot()
            },
            visualResourceResolver: { requestedIDs in
                guard requestedIDs == ["spherical_atlas_current"],
                      let panorama = panoramaStatus.snapshot(),
                      FileManager.default.isReadableFile(atPath: panorama.imagePath),
                      let attributes = try? FileManager.default.attributesOfItem(atPath: panorama.imagePath),
                      let size = attributes[.size] as? NSNumber,
                      size.intValue > 0,
                      size.intValue <= 2 * 1_024 * 1_024 else {
                    return []
                }
                return [L1VisualResource(
                    resourceID: "spherical_atlas_current",
                    projection: .sphericalAtlas,
                    localPath: panorama.imagePath,
                    expiresAt: Date().addingTimeInterval(60)
                )]
            },
            currentFrameProvider: {
                l1CurrentFrameRelay.currentResource(at: monotonicNanoseconds())
            },
            socialContactPatternProvider: {
                conversationContact.contactPattern(at: monotonicNanoseconds())
            },
            curiosityContextProvider: {
                let summary = l1CuriosityCollector.contextSummary(limit: 4)
                return summary.isEmpty ? nil : summary
            },
            onHealth: { state, message in
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: monotonicNanoseconds(),
                    source: "l1_situation",
                    state: state,
                    message: message
                ))
                if let panelEvent = l1PanelHealthEvent(state: state, message: message) {
                    liveDiagnostics.recordL1Event(
                        state: panelEvent.state,
                        message: panelEvent.message,
                        at: monotonicNanoseconds()
                    )
                }
            },
            onSocialDecision: { request, decision, presence, completedNS in
                guard let opportunity = request.socialOpportunity else { return false }
                guard !l1LiveConversationState.snapshot().conversationActive else {
                    writer.write(RuntimeEvent(
                        event: "source.health",
                        monotonicNS: completedNS,
                        source: "l1_situation",
                        state: "decision_suppressed",
                        message: "live_conversation_active"
                    ))
                    return false
                }
                do {
                    try L1SocialDecisionValidator().validate(
                        decision,
                        for: opportunity,
                        currentPresence: presence,
                        at: completedNS
                    )
                } catch {
                    writer.write(RuntimeEvent(
                        event: "source.health",
                        monotonicNS: completedNS,
                        source: "l1_situation",
                        state: "decision_rejected",
                        message: String(error.localizedDescription.prefix(192))
                    ))
                    return false
                }
                guard decision.action != .remainSilent else { return true }
                guard identityPresence.hasCurrentParticipant(decision.entityID) else {
                    writer.write(RuntimeEvent(
                        event: "source.health",
                        monotonicNS: completedNS,
                        source: "l1_situation",
                        state: "opening_suppressed",
                        message: "participant_no_longer_present"
                    ))
                    return false
                }
                if decision.action == .spokenOpening {
                    guard somaEnvBool("SOMA_L2_PROACTIVE_OPENINGS", default: true),
                          liveVoiceLauncher != nil else {
                        return false
                    }
                    guard let opening = L1PurposefulOpeningGate.resolve(
                        decision: decision,
                        informationNeeds: request.informationNeeds
                    ) else {
                        writer.write(RuntimeEvent(
                            event: "source.health",
                            monotonicNS: completedNS,
                            source: "l1_situation",
                            state: "opening_suppressed",
                            message: "closed_purpose_required"
                        ))
                        return false
                    }
                    let interactionAuthority = identityPresence.authority(for: decision.entityID)
                    let sessionCapability = liveSessionCapabilities.issue(
                        personEntityID: decision.entityID,
                        authority: interactionAuthority,
                        at: completedNS
                    )
                    guard let context = l1ProactiveInteractionContext(
                        request: request,
                        decision: decision,
                        purpose: opening,
                        languageStartInstruction: l1LanguageInstructions.directive(
                            for: request.preferredLanguageTag
                        ),
                        sessionCapability: sessionCapability,
                        interactionAuthority: interactionAuthority,
                        personMemoryMission: l1MemoryContext.cachedPersonMemoryMission(
                            for: decision.entityID
                        )
                    ) else {
                        writer.write(RuntimeEvent(
                            event: "source.health",
                            monotonicNS: completedNS,
                            source: "l2_live_voice",
                            state: "context_rejected",
                            message: "proactive_interaction_context_invalid"
                        ))
                        return false
                    }
                    // L1 owns social initiation and transfers directly to the
                    // conversation runtime. L0 may mirror the outcome through
                    // embodiment, but cannot become a serial gate for speech.
                    liveVoiceLauncher?.startProactiveOpening(
                        context: context,
                        opening: opening,
                        personEntityID: decision.entityID,
                        at: completedNS
                    )
                    Task {
                        await l1MemoryContext.recordSocialContact(
                            .proactiveOpening,
                            with: decision.entityID,
                            purpose: opening.objective
                        )
                    }
                }
                if decision.action != .spokenOpening {
                    // The durable event becomes L1 context for later social
                    // judgment; L0 does not impose a relationship cooldown.
                    l1ThoughtRelay.recordNonverbalInvitation(
                        with: decision.entityID,
                        at: completedNS
                    )
                }
                return true
            },
            currentPresenceValidator: { entityID, completedNS in
                identityPresence.hasCurrentParticipant(entityID)
            },
            behaviorContextProvider: { [weak attentionGimbalBridge] in
                attentionGimbalBridge?.makeBehaviorContext(at: monotonicNanoseconds())
            },
            onAttentionAction: { [weak attentionGimbalBridge] action, _, atNS in
                switch action {
                case .resumeScanning, .seekPeople:
                    // Periodic L1 awareness is advisory: a verified L0 face
                    // lock is fresher motor evidence and must not be released
                    // just because a background thought asks to keep looking.
                    // Explicit L1/L2 embodiment requests use their dedicated
                    // authority path instead of this passive callback.
                    if attentionGimbalBridge?.hasVerifiedFaceLock(at: atNS) == true {
                        writer.write(RuntimeEvent(
                            event: "source.health",
                            monotonicNS: atNS,
                            source: "l1_situation",
                            state: "action_held",
                            message: "action=\(action.rawValue); reason=verified_face_lock"
                        ))
                        return false
                    }
                    attentionGimbalBridge?.resumeCoverageScan(priority: .l1)
                    return attentionGimbalBridge != nil
                case .noAction, .nonverbalInvitation, .spokenOpening, .inspectAttentionTarget:
                    return false
                }
            },
            toolExecutor: l1ToolExecutor,
            activeVisionExecutor: { [l1EmbodimentTools] request in
                l1EmbodimentTools.performActiveInspection(request)
            },
            onCuriosityNeeds: { needs in
                l1CuriosityCollector.registerTopics(from: needs)
            },
            onMemoryProposals: { proposals, entityID in
                Task {
                    await l1MemoryContext.proposeMemories(proposals, personEntityID: entityID)
                }
            },
            activeLanguageProvider: {
                activeLanguage.recent()
            }
        )
        l1ThoughtRelay.install(l1ThoughtStream)
        // The relay may buffer E2B evidence until the workspace is ready. The
        // evidence still passes through semantic reduction before any L1a call.
        auxiliaryWakeRelay.attach { [weak l1ThoughtStream] interrupt in
            l1ThoughtStream?.wakeFromAuxiliary(interrupt)
        }
        l1CuriosityCollector.start()
    } catch {
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: monotonicNanoseconds(),
            source: "l1_situation",
            state: "unavailable",
            message: String(error.localizedDescription.prefix(192))
        ))
    }
    defer { l1ThoughtRelay.stop() }
    let embodimentMotorAdapter: CognitiveEmbodimentMotorAdapter?
    if options.allowEmbodimentMotorControl {
        guard let attentionGimbalBridge else {
            throw RuntimeError.configuration("Embodiment motor control requires the L0 gimbal bridge")
        }
        embodimentMotorAdapter = CognitiveEmbodimentMotorAdapter(
            bridge: attentionGimbalBridge,
            writer: writer
        )
    } else {
        embodimentMotorAdapter = nil
    }
    if let embodimentViewCaptureStore,
       let embodimentMotorAdapter {
        embodimentViewCaptureStore.setTerminalHandler { [weak embodimentArbiter, weak embodimentMotorAdapter] requestID, succeeded in
            _ = embodimentArbiter?.completeMotorGoal(
                requestID: requestID,
                at: monotonicNanoseconds()
            )
            embodimentMotorAdapter?.completeCapture(
                requestID: requestID,
                succeeded: succeeded
            )
        }
    }
    defer { embodimentMotorAdapter?.stop() }
    l1EmbodimentRelay.install(
        submitter: { request in
            let decision = embodimentArbiter.submit(request, at: monotonicNanoseconds())
            writer.write(EmbodimentShadowTraceEvent(decision))
            embodimentMotorAdapter?.submit(request, decision: decision)
            return decision
        },
        snapshotProvider: {
            embodimentArbiter.snapshot(at: monotonicNanoseconds())
        },
        captureResultProvider: { requestID, monotonicNS in
            embodimentViewCaptureStore?.result(requestID: requestID, at: monotonicNS)
        }
    )
    let embodimentShadowServer: EmbodimentShadowSocketServer?
    if let socketURL = options.embodimentShadowSocketURL {
        let runtimeRoot = ProcessInfo.processInfo.environment["SOMA_RUNTIME_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? socketURL.deletingLastPathComponent().deletingLastPathComponent()
        let hostComputerController = try HostComputerController(
            directoryURL: runtimeRoot.appendingPathComponent("host-screen", isDirectory: true)
        )
        let server = EmbodimentShadowSocketServer(
            socketURL: socketURL,
            arbiter: embodimentArbiter,
            onDecision: { request, decision in
                writer.write(EmbodimentShadowTraceEvent(decision))
                embodimentMotorAdapter?.submit(request, decision: decision)
            },
            captureResultProvider: { requestID, monotonicNS in
                embodimentViewCaptureStore?.result(requestID: requestID, at: monotonicNS)
            },
            personContextProvider: { request in
                let semaphore = DispatchSemaphore(value: 0)
                let resultBox = SynchronousResultBox<PersonContextSnapshot>()
                Task {
                    do {
                        resultBox.set(.success(try await l1MemoryContext.applyPersonContext(request)))
                    } catch {
                        resultBox.set(.failure(error))
                    }
                    semaphore.signal()
                }
                semaphore.wait()
                let result = resultBox.get() ?? .failure(EmbodimentIPCError.timeout)
                if case let .success(snapshot) = result {
                    writer.write(RuntimeEvent(
                        event: "person_context.mission",
                        monotonicNS: monotonicNanoseconds(),
                        source: "person_context_mcp",
                        state: snapshot.mission.isSatisfied ? "satisfied" : "pending",
                        message: "operation=\(request.operation.rawValue); missing_required=\(snapshot.mission.missingRequiredKeys.count); recommended=\(snapshot.mission.recommendedKeys.count)"
                    ))
                }
                if request.operation != .get, case let .success(snapshot) = result,
                   let personEntityID = request.personEntityID {
                    l1ThoughtRelay.invalidateMemoryContext(for: personEntityID)
                    writer.write(RuntimeEvent(
                        event: "person_context.updated",
                        monotonicNS: monotonicNanoseconds(),
                        source: "person_context_mcp",
                        state: request.operation.rawValue,
                        message: "storage=encrypted_local; disclosure=remote_summary_allowed; explicit_confirmation=true"
                    ))
                    switch request.operation {
                    case .setPreferredLanguage, .clearPreferredLanguage:
                        if let languageTag = snapshot.preferredLanguageTag {
                            l1LanguageInstructions.prepare(for: languageTag)
                        }
                    default:
                        break
                    }
                }
                return result
            },
            recallEpisodesProvider: { request in
                let semaphore = DispatchSemaphore(value: 0)
                let resultBox = SynchronousResultBox<[String]>()
                Task {
                    let recalled = await l1MemoryContext.recallEpisodes(
                        query: request.query ?? "",
                        entityID: request.personEntityID,
                        at: Date()
                    )
                    resultBox.set(.success(recalled))
                    semaphore.signal()
                }
                semaphore.wait()
                return resultBox.get() ?? .failure(EmbodimentIPCError.timeout)
            },
            informationNeedsProvider: { request in
                let semaphore = DispatchSemaphore(value: 0)
                let resultBox = SynchronousResultBox<InformationNeedsIPCResult>()
                Task {
                    switch request.operation {
                    case .list:
                        let needs = await l1MemoryContext.pendingInformationNeeds(
                            for: request.personEntityID,
                            respectCooldown: false
                        )
                        resultBox.set(.success(.init(items: needs.map {
                            .init(
                                motiveID: $0.motiveID,
                                question: $0.question,
                                expectedInformationGain: $0.expectedInformationGain
                            )
                        })))
                    case .recordAnswer:
                        guard let motiveID = request.motiveID,
                              let acquiredFact = request.acquiredFact?.trimmingCharacters(in: .whitespacesAndNewlines),
                              !acquiredFact.isEmpty else {
                            resultBox.set(.failure(RuntimeError.unavailable("information_need_answer_missing")))
                            semaphore.signal()
                            return
                        }
                        let recorded = await l1MemoryContext.resolveInformationNeed(
                            motiveID: motiveID,
                            expectedTargetEntityID: request.personEntityID,
                            acquiredFact: acquiredFact
                        )
                        guard recorded else {
                            resultBox.set(.failure(RuntimeError.unavailable("information_need_not_open_for_person")))
                            semaphore.signal()
                            return
                        }
                        l1ThoughtRelay.invalidateMemoryContext(for: request.personEntityID)
                        resultBox.set(.success(.init(recordedMotiveID: motiveID)))
                    }
                    semaphore.signal()
                }
                semaphore.wait()
                let result = resultBox.get() ?? .failure(EmbodimentIPCError.timeout)
                if case let .success(value) = result {
                    writer.write(RuntimeEvent(
                        event: "information_need.mcp",
                        monotonicNS: monotonicNanoseconds(),
                        source: "information_need_mcp",
                        state: request.operation.rawValue,
                        message: request.operation == .list
                            ? "open_count=\(value.items.count)"
                            : "recorded=true"
                    ))
                }
                return result
            },
            identityRosterProvider: { query in
                let now = monotonicNanoseconds()
                let presence = presentIdentityRoster.entries(at: now)
                let semaphore = DispatchSemaphore(value: 0)
                let resultBox = SynchronousResultBox<[PersonContextSnapshot]>()
                Task {
                    do {
                        let values = try await l1MemoryContext.registeredPersonContexts()
                        resultBox.set(.success(values))
                    } catch {
                        resultBox.set(.failure(error))
                    }
                    semaphore.signal()
                }
                semaphore.wait()
                let contexts: [UUID: PersonContextSnapshot]
                switch resultBox.get() ?? .failure(EmbodimentIPCError.timeout) {
                case let .success(values):
                    contexts = Dictionary(uniqueKeysWithValues: values.map { ($0.personEntityID, $0) })
                case let .failure(error):
                    return .failure(error)
                }
                let entries: [IdentityRosterEntry]
                switch query {
                case .present:
                    entries = presence.map { entry in
                        IdentityRosterEntry(
                            personEntityID: entry.identity.entityID,
                            recognitionKind: entry.identity.kind.rawValue,
                            confidence: entry.confidence,
                            lastSeenMillisecondsAgo: entry.ageMS,
                            personContext: contexts[entry.identity.entityID]
                        )
                    }
                case .registered:
                    entries = contexts.values.map { context in
                        IdentityRosterEntry(
                            personEntityID: context.personEntityID,
                            recognitionKind: "registered",
                            personContext: context
                        )
                    }.sorted { $0.personEntityID.uuidString < $1.personEntityID.uuidString }
                }
                return .success(.init(query: query, entries: entries))
            },
            identityEnrollmentProvider: { request in
                guard request.confirmedByUser,
                      let handle = presentIdentityRoster.promoteableAnonymousHandle(
                          for: request.personEntityID,
                          at: monotonicNanoseconds()
                      ) else {
                    return .failure(RuntimeError.unavailable("present_anonymous_identity_not_available"))
                }
                let semaphore = DispatchSemaphore(value: 0)
                let resultBox = SynchronousResultBox<(entityID: UUID, referenceCount: Int)>()
                Task {
                    do {
                        let result = try await FaceIdentityRuntime.promoteAnonymousIdentity(handle: handle)
                        resultBox.set(.success(result))
                    } catch {
                        resultBox.set(.failure(error))
                    }
                    semaphore.signal()
                }
                semaphore.wait()
                switch resultBox.get() ?? .failure(EmbodimentIPCError.timeout) {
                case let .success(result):
                    guard result.entityID == request.personEntityID else {
                        return .failure(RuntimeError.unavailable("identity_enrollment_reference_mismatch"))
                    }
                    writer.write(RuntimeEvent(
                        event: "identity.enrollment",
                        monotonicNS: monotonicNanoseconds(),
                        source: "person_identity_mcp",
                        state: "persistent_profile_created",
                        message: "references=\(result.referenceCount); metadata_disclosure=person_context_only"
                    ))
                    return .success(.init(
                        personEntityID: result.entityID,
                        referenceCount: result.referenceCount
                    ))
                case let .failure(error):
                    return .failure(error)
                }
            },
            indicatorCalibrationHandler: { preset in
                guard let attentionGimbalBridge else {
                    return .failure(RuntimeError.unavailable("The local LED bridge is unavailable"))
                }
                return attentionGimbalBridge.calibrateIndicator(preset: preset)
            },
            cognitiveActionQueryProvider: { query in
                let semaphore = DispatchSemaphore(value: 0)
                let resultBox = SynchronousResultBox<Bool>()
                Task {
                    resultBox.set(.success(await l1ThoughtRelay.reserveCognitiveAction(query)))
                    semaphore.signal()
                }
                // Uncertain deduplication must never authorize a possibly
                // repeated side effect.
                guard semaphore.wait(timeout: .now() + 1) == .success else { return true }
                if case let .success(value) = resultBox.get() { return value }
                return true
            },
            cognitiveActionHandler: { episode in
                let semaphore = DispatchSemaphore(value: 0)
                let resultBox = SynchronousResultBox<Bool>()
                Task {
                    resultBox.set(.success(await l1ThoughtRelay.recordCognitiveAction(episode)))
                    semaphore.signal()
                }
                guard semaphore.wait(timeout: .now() + 2) == .success else { return false }
                writer.write(RuntimeEvent(
                    event: "cognitive.action",
                    monotonicNS: monotonicNanoseconds(),
                    source: "l2_mcp",
                    state: episode.status.rawValue,
                    message: "goal=\(episode.goalEpisodeID.uuidString.lowercased()); tool=\(episode.toolName); effect=\(episode.effect.rawValue); information_gain=\(String(format: "%.2f", episode.expectedInformationGain))"
                ))
                if case let .success(value) = resultBox.get() { return value }
                return false
            },
            cognitiveTurnHandler: { token, active in
                switch liveSessionCapabilities.observeParticipantTurn(
                    token: token,
                    active: active,
                    at: monotonicNanoseconds()
                ) {
                case .success:
                    return .success(())
                case let .failure(error):
                    return .failure(error)
                }
            },
            runtimeShutdownHandler: {
                let shutdownNS = monotonicNanoseconds()
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: shutdownNS,
                    source: "runtime_control",
                    state: "graceful_shutdown_requested",
                    message: "origin=local_service_control; motion=park_then_sleep"
                ))
                attentionGimbalBridge?.stop()
                return .success(())
            },
            conversationTerminationHandler: { sessionAuthorization in
                guard let liveVoiceLauncher else {
                    return .failure(RuntimeError.unavailable("No Live Voice session is active"))
                }
                if let result = liveVoiceLauncher.authorizePersistentBroker(
                    token: sessionAuthorization,
                    scope: .conversationControl,
                    at: monotonicNanoseconds()
                ), case let .failure(error) = result {
                    return .failure(error)
                }
                let result = liveVoiceLauncher.endCurrentSession(authorizedBy: sessionAuthorization)
                if case .success = result {
                    writer.write(RuntimeEvent(
                        event: "human.interaction",
                        monotonicNS: monotonicNanoseconds(),
                        source: "l2_live_voice",
                        state: "end_requested",
                        message: "origin=active_session_mcp"
                    ))
                }
                return result
            },
            sessionAuthorizationProvider: { token, scope in
                if let result = liveVoiceLauncher?.authorizePersistentBroker(
                    token: token,
                    scope: scope,
                    at: monotonicNanoseconds()
                ) {
                    switch result {
                    case .success:
                        return .success(())
                    case let .failure(error):
                        return .failure(error)
                    }
                }
                switch liveSessionCapabilities.authorize(
                    token: token,
                    scope: scope,
                    at: monotonicNanoseconds()
                ) {
                case .success:
                    return .success(())
                case let .failure(error):
                    return .failure(error)
                }
            },
            hermesAgentTaskProvider: { request in
                let result = hermesAgentCoordinator.handle(request)
                if case let .success(value) = result {
                    let task = value.task ?? value.tasks.first
                    writer.write(RuntimeEvent(
                        event: "hermes.task",
                        monotonicNS: monotonicNanoseconds(),
                        source: "l2_mcp",
                        state: request.operation.rawValue,
                        message: task.map {
                            "task_id=\($0.id.uuidString.lowercased()); status=\($0.status.rawValue); deduplicated=\(value.deduplicated)"
                        }
                    ))
                }
                return result
            },
            hostComputerProvider: { request in
                let result = hostComputerController.handle(request)
                let state: String
                switch result {
                case .success:
                    state = request.operation.rawValue
                case .failure:
                    state = "failed"
                }
                writer.write(RuntimeEvent(
                    event: "host.computer",
                    monotonicNS: monotonicNanoseconds(),
                    source: "l2_mcp",
                    state: state,
                    message: "operation=\(request.operation.rawValue); input_kind=\(request.input?.kind.rawValue ?? "none"); content_logged=false"
                ))
                return result
            },
            onHealth: { state, message in
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: monotonicNanoseconds(),
                    source: "embodiment",
                    state: state,
                    message: message
                ))
            }
        )
        try server.start()
        embodimentShadowServer = server
    } else {
        embodimentShadowServer = nil
    }
    defer { embodimentShadowServer?.stop() }
    let embodimentSceneBridge = EmbodimentSceneBridge(
        arbiter: embodimentArbiter,
        writer: writer,
        onSnapshot: { embodimentMotorAdapter?.update($0) }
    )
    defer { embodimentSceneBridge.stop() }
    let publisher = BeliefPublisher(writer: writer) { belief, reason in
        attentionGimbalBridge?.ingest(belief, reason: reason)
    }
    let liveVoiceSpeakerEpisode = LiveVoiceSpeakerEpisodeRuntime()
    let visionWorker = VisionWorker(
        worldModel: worldModel,
        publisher: publisher,
        writer: writer,
        counters: counters,
        poseStore: poseStore,
        externalGimbalCalibration: externalGimbalCalibration,
        faceLockDiagnosticRecorder: faceLockDiagnosticRecorder,
        panoramaCompositor: panoramaCompositor,
        onSceneCandidates: { candidates, captureNS, monotonicNS in
            conversationContact.observe(candidates, at: monotonicNS)
            embodimentSceneBridge.submit(candidates, at: monotonicNS)
            attentionGimbalBridge?.ingestSceneCandidates(
                candidates,
                captureNS: captureNS,
                at: monotonicNS
            )
        },
        onCoverage: { pose, horizontalFieldOfViewDegrees, poseProjection, cameraProjectionModel, backgroundObservationQuality, dynamicVisionRects, monotonicNS in
            attentionGimbalBridge?.ingestCoverage(
                pose: pose,
                horizontalFieldOfViewDegrees: horizontalFieldOfViewDegrees,
                poseProjection: poseProjection,
                cameraProjectionModel: cameraProjectionModel,
                backgroundObservationQuality: backgroundObservationQuality,
                dynamicVisionRects: dynamicVisionRects,
                at: monotonicNS
            )
        },
        onCameraFrame: { pixelBuffer, captureNS in
            liveCameraFrameRelay?.record(pixelBuffer: pixelBuffer, capturedAtNS: captureNS)
            l1CurrentFrameRelay.record(pixelBuffer: pixelBuffer, capturedAtNS: captureNS)
        },
        onDiagnosticFrame: { pixelBuffer, candidates, captureNS in
            liveDiagnostics.recordVisionFrame(
                pixelBuffer,
                candidates: candidates,
                at: captureNS
            )
            attentionGimbalBridge?.ingestCalibrationFrame(
                pixelBuffer,
                captureNS: captureNS,
                observedNS: monotonicNanoseconds()
            )
        },
        onIdentityDecision: { decision, faceRect, isPrimaryFace, monotonicNS in
            presentIdentityRoster.record(decision, at: monotonicNS)
            liveDiagnostics.recordIdentity(
                rect: faceRect,
                label: identityDiagnosticLabel(for: decision, administrator: controlSettings.administrator),
                at: monotonicNS
            )
            guard isPrimaryFace else { return }
            latestPrimaryIdentity.update(
                state: decision.state,
                subject: decision.opaqueSubject,
                label: identityDiagnosticLabel(for: decision, administrator: controlSettings.administrator),
                confidence: decision.confidence,
                observedNS: monotonicNS
            )
            do {
                try writeIdentityState(
                    state: decision.state,
                    subject: decision.opaqueSubject,
                    label: identityDisplayLabel(for: decision, administrator: controlSettings.administrator),
                    confidence: decision.confidence,
                    to: identityStateURL
                )
            } catch {
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: monotonicNS,
                    source: "identity_handoff",
                    state: "write_failed",
                    message: String(error.localizedDescription.prefix(192))
                ))
            }
            // The presence coordinator intentionally emits only arrival,
            // replacement, and departure transitions. L1 needs the continuous
            // recognized samples as its freshness signal, otherwise a stable
            // person disappears from L1's three-second presence window after
            // the initial arrival transition.
            l1ThoughtRelay.observe(
                decision,
                label: identityDiagnosticLabel(for: decision, administrator: controlSettings.administrator),
                at: monotonicNS
            )
            for update in identityPresence.observe(decision, at: monotonicNS) {
                writer.write(identityPresenceRuntimeEvent(for: update.transition, at: monotonicNS))
                if case let .arrived(identity) = update.transition {
                    // Pre-warm the person's durable memory context so reactive
                    // speech can surface recalled facts (e.g. recognized-object
                    // taste profile) even before the first L1 wake cycle.
                    l1MemoryContext.warmContext(for: identity.entityID)
                    if identity.entityID == controlSettings.administrator?.entityID {
                        let spaceID = spaceCoordinator.currentSpaceID
                        Task {
                            let associated = await l1MemoryContext
                                .associateRecognizedPersonWithUnassignedSpace(
                                    identity.entityID,
                                    spaceID: spaceID
                                )
                            writer.write(RuntimeEvent(
                                event: "l1.space_affiliation",
                                monotonicNS: monotonicNanoseconds(),
                                source: "l1_memory",
                                state: associated ? "associated" : "already_associated_elsewhere",
                                message: "space=\(spaceID.uuidString.lowercased())"
                            ))
                            l1MemoryContext.warmContext(for: identity.entityID)
                        }
                    }
                }
                if case let .departed(identity) = update.transition {
                    l1ThoughtRelay.depart(identity.entityID)
                }
                if update.participant?.authority == .administrator {
                    writer.write(RuntimeEvent(
                        event: "administrator.identity",
                        monotonicNS: monotonicNS,
                        source: "administrator_identity",
                        state: "verified_presence",
                        message: "recognized_local_profile; metadata_disclosure=local_only"
                    ))
                }
            }
        },
        onIdentityPresenceEvidence: { verifiedFacePresent, monotonicNS in
            if !verifiedFacePresent {
                latestPrimaryIdentity.clear()
                clearIdentityState(at: identityStateURL)
            }
            for update in identityPresence.observeVerifiedFace(verifiedFacePresent, at: monotonicNS) {
                writer.write(identityPresenceRuntimeEvent(for: update.transition, at: monotonicNS))
                if case let .departed(identity) = update.transition {
                    l1ThoughtRelay.depart(identity.entityID)
                }
            }
        },
        onVisualSpeakerEvidence: { faces, monotonicNS in
            guard let update = visualSpeakerAttribution.record(faces, at: monotonicNS) else {
                return
            }
            let observation = liveVoiceSpeakerEpisode.observeGaze(
                update.state,
                trackedFaceID: update.targetID,
                observedNS: update.observedNS,
                at: monotonicNanoseconds()
            )
            if observation.didTransition, observation.state == .rejected {
                liveVoiceLauncher?.revokeProvisionalParticipantOpening(
                    reason: "visual_contact_revoked_before_opening_confirmation"
                )
                writer.write(RuntimeEvent(
                    event: "human.interaction",
                    monotonicNS: monotonicNanoseconds(),
                    source: "l2_live_voice",
                    state: "opening_revoked",
                    message: "latest_gaze=averted; gaze_capture_ns=\(update.observedNS)"
                ))
            }
        },
        onFatalVisionFailure: {
            complete.signal()
        },
        anonymousReviewProvider: { anonymousReviewBox.approve() },
        pupilCenteringThreshold: somaEnvDouble("SOMA_L0_EYE_CONTACT_PUPIL_THRESHOLD", default: 0.9),
        expectedDirectPupilOffsetY: SOMACameraVerticalPlacement(
            rawValue: somaEnvString("SOMA_L0_CAMERA_VERTICAL_PLACEMENT", default: "eye_level")
        )?.expectedDirectPupilOffsetY ?? 0
    )
    let eventImportanceModel = EventImportanceModel()
    let speechInteraction: LocalSpeechInteractionCoordinator?
    if let localeIdentifier = options.localSpeechLocaleIdentifier,
       options.l2CodexBridgeURL != nil,
       !options.l2LiveVoice {
        speechInteraction = try LocalSpeechInteractionCoordinator(
            localeIdentifier: localeIdentifier,
            codexBridgeURL: options.l2CodexBridgeURL,
            codexWorkingDirectoryURL: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/SOMA/L2Codex", isDirectory: true),
            onState: { state in
                let stateNS = monotonicNanoseconds()
                switch state {
                case let .recognitionCompleted(_, _, _, _, _, _, handedToL2):
                    if handedToL2 {
                        conversationContact.markConversationOpened(at: stateNS)
                    }
                case .l2Completed:
                    conversationContact.recordConversationActivity(at: stateNS)
                case .l2Failed:
                    conversationContact.closeConversation()
                case .turnStarted, .turnCancelled, .recognitionFailed,
                     .speechStarted, .speechCompleted, .speechCancelled:
                    break
                }
                attentionGimbalBridge?.ingestSpeechInteractionState(state)
                writer.write(SpeechInteractionTraceEvent(
                    state,
                    at: stateNS
                ))
            }
        )
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: monotonicNanoseconds(),
            source: "local_speech_recognition",
            state: "configured",
            message: "engine=speech_analyzer; locale=\(String(localeIdentifier.prefix(32))); on_device=true; audio_persistence=false; pre_roll_ms=900; l2_handoff=\(options.l2CodexBridgeURL != nil)"
        ))
        speechInteractionBox.coordinator = speechInteraction
    } else {
        speechInteraction = nil
    }
    defer { speechInteraction?.stop() }
    // A live voice opening is additionally gated by fresh directed visual
    // contact. This lets the microphone onset be calibrated to the actual
    // Tiny 3 front end without turning ambient room noise into a session.
    let voiceVADThreshold = somaEnvDouble("SOMA_L0_VAD_THRESHOLD", default: 0.35)
    let voiceEvidenceTelemetry = VoiceEvidenceTelemetry()
    let voiceWorker = try AudioVADWorker(
        activationThreshold: voiceVADThreshold,
        onEvidence: { evidence, frame, completedNS in
            if evidence.inferenceMS > 0 {
                counters.neuralVADInference(
                    inferenceMS: evidence.inferenceMS,
                    windowEndToEvidenceMS: milliseconds(from: frame.captureNS, to: completedNS)
                )
            }
            if let telemetry = voiceEvidenceTelemetry.record(
                evidence: evidence,
                frame: frame,
                at: completedNS
            ) {
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: completedNS,
                    source: "neural_vad",
                    state: "evidence",
                    message: telemetry
                ))
            }
            let belief = worldModel.ingestVoice(
                active: evidence.active,
                confidence: evidence.probability,
                at: completedNS
            )
            attentionGimbalBridge?.ingestAuditoryVoiceActivity(
                active: evidence.active,
                confidence: evidence.probability,
                at: frame.captureNS
            )
            let visualAdmission = LiveConversationVisualAdmission.permitsNewSession(for: belief)
            let isVoiceOnset = evidence.active && evidence.changed
            if !evidence.active, evidence.changed {
                recentAcousticOnset.recordVoiceOffset(at: evidence.windowEndNS)
            }
            let resolvedVoiceOnsetNS = isVoiceOnset
                ? recentAcousticOnset.resolve(
                    classifiedWindowStartNS: evidence.windowStartNS,
                    classifiedWindowEndNS: evidence.windowEndNS
                )
                : evidence.windowStartNS
            let speakerSnapshot = isVoiceOnset
                ? visualSpeakerAttribution.beginEpisode(
                    targetID: visualAdmission ? belief.target?.id : nil,
                    targetRect: belief.target?.rect,
                    voiceConfidence: evidence.probability,
                    at: resolvedVoiceOnsetNS
                )
                : visualSpeakerAttribution.assessCurrentEpisode(
                    targetID: visualAdmission ? belief.target?.id : nil,
                    targetRect: belief.target?.rect,
                    voiceConfidence: evidence.probability,
                    at: completedNS
                )
            let speakerEpisode = liveVoiceSpeakerEpisode.observe(
                active: evidence.active,
                trackedFaceID: visualAdmission ? belief.target?.id : nil,
                evidence: speakerSnapshot.evidence,
                assessment: speakerSnapshot.assessment,
                directContactObservedNS: speakerSnapshot.directContactObservedNS,
                directContactContradictedNS: speakerSnapshot.directContactContradictedNS,
                speakerEvidenceObservedNS: speakerSnapshot.speakerEvidenceObservedNS,
                voiceWindowObservedNS: evidence.windowEndNS,
                episodeOnsetNS: isVoiceOnset ? resolvedVoiceOnsetNS : nil,
                at: completedNS
            )
            if speakerEpisode.didTransition, speakerEpisode.state == .rejected {
                liveVoiceLauncher?.revokeProvisionalParticipantOpening(
                    reason: "speaker_attribution_revoked_before_participant_input"
                )
            }
            let confirmedTrackedSpeaker = speakerEpisode.state == .confirmed
            // Visual contact and the independent lip/DOA cue may arrive on
            // different detector cadences. The episode gate binds both to the
            // same continuously tracked face before contact is authorized.
            let contactAuthorization: ConversationOpeningAuthorization?
            if !evidence.active {
                contactAuthorization = conversationContact.observeVoiceActivity(
                    active: false,
                    at: completedNS,
                    confidence: evidence.probability
                )
            } else if confirmedTrackedSpeaker {
                contactAuthorization = conversationContact.observeVoiceActivity(
                    active: true,
                    at: completedNS,
                    confidence: speakerEpisode.maximumVoiceConfidence,
                    audioVisualDirectContact: speakerEpisode.directContactObserved
                )
            } else {
                contactAuthorization = nil
            }
            let openingAuthorization = contactAuthorization
            if evidence.changed, options.l2LiveVoice {
                attentionGimbalBridge?.ingestLiveVoiceUserActivity(active: evidence.active)
            }
            let recognizedParticipant = visualAdmission
                ? identityPresence.currentParticipant()
                : nil
            let interactionParticipant = recognizedParticipant ?? InteractionParticipant(
                entityID: UUID(),
                authority: .participant
            )
            let personContextAvailable = recognizedParticipant != nil
            let recognizedPersonEntityID = recognizedParticipant?.entityID
            let preferredLanguageTag = recognizedPersonEntityID.flatMap {
                l1MemoryContext.cachedPreferredLanguage(for: $0)
            } ?? activeLanguage.recent()
                ?? somaEnvString("SOMA_L1_DEFAULT_LANGUAGE", default: "ko")
            let languageStartInstruction = l1LanguageInstructions.directive(for: preferredLanguageTag)
            let personPreferenceDirectives = recognizedPersonEntityID.map {
                l1MemoryContext.personPreferenceDirectives(for: $0)
            } ?? ""
            let interactionIdentityReference = personContextAvailable
                ? l2IdentityReference(
                    base: identityPresence.interactionReference(),
                    explicitPreferences: personPreferenceDirectives
                )
                : nil
            let interactionMemorySummaries = (recognizedPersonEntityID.map {
                l1MemoryContext.cachedPersonMemorySummaries(for: $0)
            } ?? []) + (personPreferenceDirectives.isEmpty
                ? []
                : ["Explicit person preferences: \(personPreferenceDirectives)"])
            if !evidence.active,
               options.l2LiveVoice,
               let administrator = recognizedParticipant,
               administrator.authority == .administrator,
               let liveVoiceLauncher,
               liveVoiceLauncher.canStartHermesReportOffer(at: completedNS),
               let task = hermesAgentCoordinator.pendingReportOffers().first {
                let sessionCapability = liveSessionCapabilities.issue(
                    personEntityID: administrator.entityID,
                    authority: .administrator,
                    at: completedNS
                )
                if let context = speechInteractionContext(
                    from: belief,
                    identityReference: interactionIdentityReference,
                    participant: administrator,
                    personContextAvailable: true,
                    sessionCapability: sessionCapability,
                    personMemoryMission: l1MemoryContext.cachedPersonMemoryMission(
                        for: administrator.entityID
                    ),
                    preferredLanguageTag: preferredLanguageTag,
                    languageStartInstruction: languageStartInstruction,
                    memorySummaries: interactionMemorySummaries
                ) {
                    liveVoiceLauncher.startHermesReportOffer(
                        context: context,
                        task: task,
                        personEntityID: administrator.entityID,
                        at: completedNS
                    )
                }
            }
            if evidence.active, evidence.changed, openingAuthorization == nil {
                writer.write(RuntimeEvent(
                    event: "human.interaction",
                    monotonicNS: completedNS,
                    source: "l2_live_voice",
                    state: "opening_suppressed",
                    message: "new_conversation_evidence_unconfirmed; tracked_face=\(visualAdmission); direct_gaze=\(speakerSnapshot.evidence.directGaze); speaker_class=\(speakerSnapshot.assessment.classification.rawValue); speaker_episode=\(speakerEpisode.state.rawValue); speech_qualified=\(speakerEpisode.speechEvidence.qualified); strong_windows=\(speakerEpisode.speechEvidence.strongWindowCount); supporting_windows=\(speakerEpisode.speechEvidence.supportingWindowCount)"
                ))
            }
            let administratorOpeningAllowed = !controlSettings.administratorOnlyConversations
                || recognizedParticipant?.authority == .administrator
            if let openingAuthorization,
               options.l2LiveVoice,
               administratorOpeningAllowed {
                let sessionCapability = liveSessionCapabilities.issue(
                    personEntityID: interactionParticipant.entityID,
                    authority: interactionParticipant.authority,
                    at: completedNS
                )
                guard let context = speechInteractionContext(
                    from: belief,
                    identityReference: interactionIdentityReference,
                    participant: interactionParticipant,
                    personContextAvailable: personContextAvailable,
                    sessionCapability: sessionCapability,
                    personMemoryMission: recognizedPersonEntityID.flatMap {
                        l1MemoryContext.cachedPersonMemoryMission(for: $0)
                    },
                    preferredLanguageTag: preferredLanguageTag,
                    languageStartInstruction: languageStartInstruction,
                    memorySummaries: interactionMemorySummaries
                ) else {
                    writer.write(RuntimeEvent(
                        event: "source.health",
                        monotonicNS: completedNS,
                        source: "l2_live_voice",
                        state: "context_rejected",
                        message: "speech_interaction_context_invalid"
                    ))
                    return
                }
                liveVoiceLauncher?.startIfNeeded(
                    authorization: openingAuthorization.rawValue,
                    context: context,
                    personEntityID: interactionParticipant.entityID,
                    at: completedNS
                )
            } else if openingAuthorization != nil,
                      controlSettings.administratorOnlyConversations,
                      !administratorOpeningAllowed {
                writer.write(RuntimeEvent(
                    event: "human.interaction",
                    monotonicNS: completedNS,
                    source: "l2_live_voice",
                    state: "opening_suppressed",
                    message: "administrator_only=true; recognized_administrator=false"
                ))
            } else if openingAuthorization != nil, !options.l2LiveVoice {
                writer.write(RuntimeEvent(
                    event: "source.health",
                    monotonicNS: completedNS,
                    source: "l2_live_voice",
                    state: "opening_suppressed",
                    message: "local_transcript_admission_unavailable"
                ))
            }
            let strictConfirmedWindow = controlSettings
                .realtimeVoiceRequiresEyeContactForEveryTurn
                && evidence.active
                && speakerEpisode.state == .confirmed
            let shouldTraceSpeakerTransition = evidence.changed
                || speakerEpisode.didTransition
                || openingAuthorization != nil
                || strictConfirmedWindow
            if shouldTraceSpeakerTransition || evidence.active {
                let administratorTurnAllowed = !controlSettings.administratorOnlyConversations
                    || recognizedParticipant?.authority == .administrator
                let strictTurnAdmission = administratorTurnAllowed && (
                    !controlSettings.realtimeVoiceRequiresEyeContactForEveryTurn
                        || confirmedTrackedSpeaker
                )
                let duplexSpeakerVerified = LiveVoiceDuplexSpeakerPolicy.verifiesParticipant(
                    trackedFaceVisible: visualAdmission,
                    independentSpeakerEvidence: speakerEpisode.speakerEvidenceObserved,
                    speechEvidenceQualified: speakerEpisode.speechEvidence.qualified,
                    directContactConfirmed: confirmedTrackedSpeaker,
                    speakerAttributionRejected: speakerEpisode.state == .rejected,
                    requiresDirectGaze: controlSettings.realtimeVoiceRequiresEyeContactForEveryTurn
                )
                liveVoiceLauncher?.observeVoiceActivity(
                    evidence.active,
                    admitted: strictTurnAdmission && (
                        controlSettings.realtimeVoiceRequiresEyeContactForEveryTurn
                            ? confirmedTrackedSpeaker
                            : speakerSnapshot.assessment.admitsAudio
                    ),
                    duplexSpeakerVerified: duplexSpeakerVerified,
                    discardBufferedEpisode: !evidence.active && (
                        speakerEpisode.endedState == .pending
                            || speakerEpisode.endedState == .rejected
                    ) || (
                        evidence.active
                            && speakerEpisode.didTransition
                            && speakerEpisode.state == .rejected
                    ),
                    onsetCaptureNS: isVoiceOnset ? resolvedVoiceOnsetNS : nil,
                    assessedThroughCaptureNS: evidence.windowEndNS,
                    preserveDetectorHistoryFromCaptureNS: evidence.discontinuityReset
                        ? frame.captureNS
                        : nil,
                    at: completedNS
                )
                if evidence.active, shouldTraceSpeakerTransition {
                    writer.write(RuntimeEvent(
                        event: "human.interaction",
                        monotonicNS: completedNS,
                        source: "audio_visual_speaker",
                        state: speakerSnapshot.assessment.classification.rawValue,
                        message: String(
                            format: "probability=%.3f; episode=%@; direct_contact=%@; speaker_evidence=%@; speech_qualified=%@; strong_windows=%d; supporting_windows=%d; direct_gaze=%@; mouth_motion=%@; mouth_samples=%d; direction_match=%@; strict_every_turn=%@",
                            speakerSnapshot.assessment.probability,
                            speakerEpisode.state.rawValue,
                            speakerEpisode.directContactObserved ? "true" : "false",
                            speakerEpisode.speakerEvidenceObserved ? "true" : "false",
                            speakerEpisode.speechEvidence.qualified ? "true" : "false",
                            speakerEpisode.speechEvidence.strongWindowCount,
                            speakerEpisode.speechEvidence.supportingWindowCount,
                            speakerSnapshot.evidence.directGaze ? "true" : "false",
                            speakerSnapshot.evidence.mouthMotion.map { String(format: "%.3f", $0) } ?? "na",
                            speakerSnapshot.evidence.mouthSampleCount,
                            speakerSnapshot.evidence.directionMatchesFace.map { $0 ? "true" : "false" } ?? "na",
                            controlSettings.realtimeVoiceRequiresEyeContactForEveryTurn ? "true" : "false"
                        )
                    ))
                }
            }
            if !evidence.active { visualSpeakerAttribution.endEpisode() }
            if let speechInteraction {
                let sessionCapability = liveSessionCapabilities.issue(
                    personEntityID: interactionParticipant.entityID,
                    authority: interactionParticipant.authority,
                    at: completedNS
                )
                guard let context = speechInteractionContext(
                    from: belief,
                    identityReference: interactionIdentityReference,
                    participant: interactionParticipant,
                    personContextAvailable: personContextAvailable,
                    sessionCapability: sessionCapability,
                    personMemoryMission: recognizedPersonEntityID.flatMap {
                        l1MemoryContext.cachedPersonMemoryMission(for: $0)
                    },
                    preferredLanguageTag: preferredLanguageTag,
                    languageStartInstruction: languageStartInstruction,
                    memorySummaries: interactionMemorySummaries
                ) else { return }
                let wake = openingAuthorization.flatMap {
                    speechInteractionWake(
                        model: eventImportanceModel,
                        belief: belief,
                        voiceConfidence: evidence.probability,
                        authorization: $0,
                        at: completedNS
                    )
                }
                speechInteraction.observeVAD(
                    active: evidence.active,
                    at: completedNS,
                    authorizedWake: wake,
                    context: context
                )
            }
            guard evidence.changed else { return }
            writer.write(VoiceEvent(
                monotonicNS: completedNS,
                source: "coreml_vad",
                active: evidence.active,
                confidence: evidence.probability,
                levelDB: frame.levelDB
            ))
            publisher.publish(
                belief,
                reason: evidence.active ? "voice_onset" : "voice_offset",
                force: true
            )
        },
        onError: { message in
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: monotonicNanoseconds(),
                source: "neural_vad",
                state: "runtime_error",
                message: message
            ))
        }
    )
    let audioAnalyzer = AudioAnalyzer(
        worldModel: worldModel,
        publisher: publisher,
        writer: writer,
        counters: counters,
        voiceWorker: voiceWorker,
        directionEstimator: loadedDirectionCalibration.map { StereoTDOAEstimator(calibration: $0) },
        calibrationRecorder: calibrationRecorder,
        speechInteraction: speechInteraction,
        liveVoiceLauncher: liveVoiceLauncher,
        visualSpeakerAttribution: visualSpeakerAttribution,
        auditoryOnsetHandler: { [weak attentionGimbalBridge] evidence in
            recentAcousticOnset.record(evidence)
            attentionGimbalBridge?.ingestAuditoryOnset(evidence)
        }
    )
    let session = AVCaptureSession()

    let videoInput = try AVCaptureDeviceInput(device: videoDevice)
    let audioInput = try AVCaptureDeviceInput(device: audioDevice)
    let videoOutput = AVCaptureVideoDataOutput()
    let audioOutput = AVCaptureAudioDataOutput()
    videoOutput.alwaysDiscardsLateVideoFrames = true
    videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]

    session.beginConfiguration()
    guard session.canAddInput(videoInput), session.canAddInput(audioInput),
          session.canAddOutput(videoOutput), session.canAddOutput(audioOutput) else {
        throw RuntimeError.configuration("Cannot create an OBSBOT video/audio capture session")
    }
    session.addInput(videoInput)
    session.addInput(audioInput)
    session.addOutput(videoOutput)
    session.addOutput(audioOutput)
    if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }

    let delegate = CaptureDelegate(
        worldModel: worldModel,
        publisher: publisher,
        visionWorker: visionWorker,
        audioAnalyzer: audioAnalyzer,
        counters: counters,
        videoOutput: videoOutput,
        audioOutput: audioOutput,
        diagnosticSnapshotURL: options.diagnosticSnapshotURL,
        l1AuxiliarySemanticBridge: l1AuxiliarySemanticBridge,
        embodimentViewCaptureStore: embodimentViewCaptureStore
    )
    let videoQueue = DispatchQueue(label: "soma.subconscious.video", qos: .userInteractive)
    let audioQueue = DispatchQueue(label: "soma.subconscious.audio", qos: .userInteractive)
    videoOutput.setSampleBufferDelegate(delegate, queue: videoQueue)
    audioOutput.setSampleBufferDelegate(delegate, queue: audioQueue)
    session.commitConfiguration()
    let observer = SessionObserver(session: session, writer: writer, videoDevice: videoDevice, audioDevice: audioDevice)

    writer.write(RuntimeEvent(
        event: "source.health",
        monotonicNS: monotonicNanoseconds(),
        source: "video",
        state: selectedFormat.applied ? "selected" : "configuration_fallback",
        message: "\(identity(videoDevice).name); requested=\(selectedFormat.requested); \(selectedFormat.detail)"
    ))
    writer.write(RuntimeEvent(event: "source.health", monotonicNS: monotonicNanoseconds(), source: "audio", state: "selected", message: "\(identity(audioDevice).name)"))
    if let directoryURL = options.faceLockDiagnosticDirectoryURL {
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: monotonicNanoseconds(),
            source: "face_lock_diagnostics",
            state: "enabled",
            message: "jpeg_dir=\(directoryURL.path); nonface_sample_ms=500; face_candidate_max_hz=10; maximum_images=60"
        ))
    }
    let neuralVADConfiguration = String(
        format: "model=silero_vad_unified_256ms_v6.2.1; compute_units=%@; warmup_ms=%.2f; window_ms=260; threshold=%.2f",
        voiceWorker.computeUnits,
        voiceWorker.warmupMS,
        voiceVADThreshold
    )
    writer.write(RuntimeEvent(
        event: "source.health",
        monotonicNS: monotonicNanoseconds(),
        source: "neural_vad",
        state: "configured",
        message: neuralVADConfiguration
    ))
    if loadedDirectionCalibration != nil {
        writer.write(RuntimeEvent(event: "source.health", monotonicNS: monotonicNanoseconds(), source: "audio_tdoa", state: "configured", message: "calibrated_stereo_tdoa"))
    } else if calibrationRecorder != nil {
        writer.write(RuntimeEvent(event: "source.health", monotonicNS: monotonicNanoseconds(), source: "audio_tdoa", state: "calibrating", message: "three_positions=left,center,right"))
    } else {
        writer.write(RuntimeEvent(event: "source.health", monotonicNS: monotonicNanoseconds(), source: "audio_tdoa", state: "calibration_required", message: "direction remains unknown until a three-position calibration is supplied"))
    }
    visionWorker.start()
    session.startRunning()
    let startedNS = monotonicNanoseconds()
    if options.guidedScenario, let firstPhase = GuidedScenarioPhase.phases.first {
        writer.write(RuntimeEvent(
            event: "scenario.phase",
            monotonicNS: startedNS,
            source: "guided_scenario",
            state: firstPhase.state,
            message: firstPhase.instruction
        ))
    }
    if let calibrationRecorder, let firstPhase = TDOACalibrationPhase.phases.first {
        calibrationRecorder.setPosition(firstPhase.position)
        writer.write(RuntimeEvent(
            event: "scenario.phase",
            monotonicNS: startedNS,
            source: "tdoa_calibration",
            state: firstPhase.position.rawValue,
            message: firstPhase.instruction
        ))
    }
    var nextScenarioPhaseIndex = options.guidedScenario ? 1 : GuidedScenarioPhase.phases.count
    var nextTDOAPhaseIndex = calibrationRecorder == nil ? TDOACalibrationPhase.phases.count : 1
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "soma.subconscious.metrics"))
    timer.schedule(deadline: .now() + 1, repeating: 1)
    timer.setEventHandler {
        let now = monotonicNanoseconds()
        let elapsed = Double(now - startedNS) / 1_000_000_000
        while nextScenarioPhaseIndex < GuidedScenarioPhase.phases.count,
              elapsed >= GuidedScenarioPhase.phases[nextScenarioPhaseIndex].startsAfterSeconds {
            let phase = GuidedScenarioPhase.phases[nextScenarioPhaseIndex]
            writer.write(RuntimeEvent(
                event: "scenario.phase",
                monotonicNS: now,
                source: "guided_scenario",
                state: phase.state,
                message: phase.instruction
            ))
            nextScenarioPhaseIndex += 1
        }
        while nextTDOAPhaseIndex < TDOACalibrationPhase.phases.count,
              elapsed >= TDOACalibrationPhase.phases[nextTDOAPhaseIndex].startsAfterSeconds {
            let phase = TDOACalibrationPhase.phases[nextTDOAPhaseIndex]
            calibrationRecorder?.setPosition(phase.position)
            writer.write(RuntimeEvent(
                event: "scenario.phase",
                monotonicNS: now,
                source: "tdoa_calibration",
                state: phase.position.rawValue,
                message: phase.instruction
            ))
            nextTDOAPhaseIndex += 1
        }
        writer.write(counters.snapshot(at: now))
        // Re-emit the current primary-face identity so it never scrolls out of
        // the menu bar's short trace-tail read window while the face is present.
        if let identity = latestPrimaryIdentity.snapshot() {
            writer.write(FaceIdentityEvent(
                monotonicNS: identity.observedNS,
                state: identity.state,
                subject: identity.subject,
                confidence: identity.confidence,
                inferenceMS: 0
            ))
        }
        publisher.publish(worldModel.snapshot(at: now), reason: "periodic")
        if options.duration > 0, elapsed >= options.duration {
            if options.guidedScenario {
                writer.write(RuntimeEvent(
                    event: "scenario.completed",
                    monotonicNS: now,
                    source: "guided_scenario",
                    state: "capture_accepting_stopped",
                    message: "scheduled_seconds=50"
                ))
            }
            delegate.stopAccepting()
            timer.cancel()
            complete.signal()
        }
    }
    timer.resume()
    complete.wait()
    timer.cancel()
    session.stopRunning()
    delegate.stopAccepting()
    videoQueue.sync {}
    audioQueue.sync {}
    visionWorker.stop()
    audioAnalyzer.stop()
    l1AuxiliarySemanticBridge?.stop()
    observer.stop()
    // Finalize a live conversation while the runtime writer and L1 relay are
    // still available; the later defer remains the error-path backstop.
    liveVoiceLauncher?.stop()
    let stoppedNS = monotonicNanoseconds()
    if let calibrationRecorder, let calibrationOutputURL = options.tdoaCalibrationOutputURL {
        let diagnosticSummary = calibrationRecorder.summary()
        writer.write(RuntimeEvent(
            event: "source.health",
            monotonicNS: stoppedNS,
            source: "audio_tdoa",
            state: "calibration_summary",
            message: diagnosticSummary
        ))
        if let calibration = calibrationRecorder.makeCalibration() {
            try write(calibration, to: calibrationOutputURL)
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: stoppedNS,
                source: "audio_tdoa",
                state: "calibration_written",
                message: "\(calibrationOutputURL.path); sample_rate_hz=\(calibration.sampleRateHz)"
            ))
        } else {
            writer.write(RuntimeEvent(
                event: "source.health",
                monotonicNS: stoppedNS,
                source: "audio_tdoa",
                state: "calibration_failed",
                message: "Need at least three high-correlation speech measurements at left, center, and right; \(diagnosticSummary)"
            ))
        }
    }
    writer.write(counters.snapshot(at: stoppedNS))
    publisher.publish(worldModel.snapshot(at: stoppedNS), reason: "stopped", force: true)
    let lateEventsDropped = writer.drain()
    writer.write(RuntimeEvent(
        event: "source.health",
        monotonicNS: stoppedNS,
        source: "session",
        state: "stopped",
        message: "late_events_dropped=\(lateEventsDropped)"
    ))
    withExtendedLifetime(observer) {}
    print("Wrote subconscious trace: \(options.outputURL.path)")
}

private func write(_ calibration: StereoDirectionCalibration, to url: URL) throws {
    guard !FileManager.default.fileExists(atPath: url.path) else {
        throw RuntimeError.invalidArgument("TDOA calibration output already exists: \(url.path)")
    }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(calibration).write(to: url, options: .atomic)
}

private func requestLowLatencyFormat(on device: AVCaptureDevice) throws -> VideoConfiguration {
    let candidates = device.formats.compactMap { format -> (AVCaptureDevice.Format, Int32, Int32, Double)? in
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let maximumFPS = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
        guard dimensions.width == 1280, dimensions.height == 720, maximumFPS >= 30 else { return nil }
        return (format, dimensions.width, dimensions.height, maximumFPS)
    }
    guard let selected = candidates.max(by: { $0.3 < $1.3 }) else {
        throw RuntimeError.configuration("The OBSBOT camera does not expose 1280x720 at 30 fps")
    }
    let requested = "\(selected.1)x\(selected.2)@30fps"
    do {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeFormat = selected.0
        let frameDuration = selected.0.videoSupportedFrameRateRanges
            .min(by: { abs($0.maxFrameRate - 30) < abs($1.maxFrameRate - 30) })?
            .minFrameDuration ?? CMTime(value: 1, timescale: 30)
        device.activeVideoMinFrameDuration = frameDuration
        device.activeVideoMaxFrameDuration = frameDuration
        return VideoConfiguration(requested: requested, applied: true, detail: "active_format_applied")
    } catch {
        return VideoConfiguration(
            requested: requested,
            applied: false,
            detail: "active_format_unavailable=\(error.localizedDescription)"
        )
    }
}

private func obsbotDevice(for mediaType: AVMediaType, uniqueID: String) -> AVCaptureDevice? {
    // The OBSBOT is matched by name first, then by requested unique ID. The
    // unique ID prefix (bus/port portion) can change across reboots or USB
    // replugs while the product suffix stays stable, so the ID is a preference,
    // not a hard requirement: prefer the exact ID, fall back to any OBSBOT.
    let isObsbot: (AVCaptureDevice) -> Bool = {
        $0.localizedName.range(of: "obsbot", options: .caseInsensitive) != nil
    }
    let devices: [AVCaptureDevice]
    if mediaType == .video {
        devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.externalUnknown],
            mediaType: mediaType,
            position: .unspecified
        ).devices
    } else if #available(macOS 14.0, *) {
        devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: mediaType,
            position: .unspecified
        ).devices
    } else {
        devices = AVCaptureDevice.devices(for: mediaType)
    }
    let obsbots = devices.filter(isObsbot)
    if !uniqueID.isEmpty, let exact = obsbots.first(where: { $0.uniqueID == uniqueID }) {
        return exact
    }
    return obsbots.first
}

private func requestAccess(for mediaType: AVMediaType, label: String) throws {
    switch AVCaptureDevice.authorizationStatus(for: mediaType) {
    case .authorized:
        return
    case .notDetermined:
        let semaphore = DispatchSemaphore(value: 0)
        let result = AccessResult()
        AVCaptureDevice.requestAccess(for: mediaType) { granted in
            result.set(granted)
            semaphore.signal()
        }
        semaphore.wait()
        guard result.value else { throw RuntimeError.unauthorized("Access to the \(label) was not granted") }
    case .denied, .restricted:
        throw RuntimeError.unauthorized("Access to the \(label) is denied or restricted")
    @unknown default:
        throw RuntimeError.unauthorized("Access to the \(label) has an unknown authorization state")
    }
}

private func speechInteractionWake(
    model: EventImportanceModel,
    belief: BeliefSnapshot,
    voiceConfidence: Double,
    authorization: ConversationOpeningAuthorization,
    at monotonicNS: UInt64
) -> HumanInteractionWakeRequest? {
    let target = belief.targetStatus == .tracked ? belief.target : nil
    let eventID = "voice-contact-\(monotonicNS)"
    let visualConfidence = target?.confidence ?? belief.presenceProbability
    let decision = model.evaluate(EventImportanceInput(
        eventID: eventID,
        monotonicNS: monotonicNS,
        evidenceIDs: [
            "voice:\(monotonicNS)",
            "contact:\(authorization.rawValue)",
            target.map { "vision:\(String($0.id.prefix(96)))" } ?? "vision:not_required_for_active_contact",
        ],
        features: EventImportanceFeatures(
            explicitContact: max(0.80, min(visualConfidence, voiceConfidence)),
            socialSalience: visualConfidence,
            persistence: min((target?.stabilityMilliseconds ?? 1_000) / 1_000, 1),
            crossModalCorroboration: min(visualConfidence, voiceConfidence),
            humanPresence: belief.presenceProbability
        )
    ))
    return try? HumanInteractionWakeRequest(
        decision: decision,
        audioPreRollMilliseconds: 900
    )
}

private func speechInteractionContext(
    from belief: BeliefSnapshot,
    identityReference: String? = nil,
    participant: InteractionParticipant? = nil,
    personContextAvailable: Bool? = nil,
    sessionCapability: String? = nil,
    personMemoryMission: PersonContextMission? = nil,
    preferredLanguageTag: String? = nil,
    languageStartInstruction: String? = nil,
    memorySummaries: [String] = []
) -> CodexInteractionContext? {
    let targetSummary: String
    if let target = belief.target {
        targetSummary = "L0 tracks a \(target.kind.rawValue) hypothesis labelled \(target.label ?? "unlabelled") with confidence \(String(format: "%.2f", target.confidence))."
    } else {
        targetSummary = "L0 has no current visual target."
    }
    let situationSummary = targetSummary
    return makeL2InteractionContext(
        situationSummary: situationSummary,
        identityReference: identityReference,
        personEntityID: participant?.entityID,
        personContextAvailable: personContextAvailable,
        sessionCapability: sessionCapability,
        interactionAuthority: participant?.authority,
        personMemoryMission: personMemoryMission,
        preferredLanguageTag: preferredLanguageTag,
        languageStartInstruction: languageStartInstruction,
        activeTaskSummaries: [],
        memorySummaries: memorySummaries,
        embodimentSummary: "Camera policy is \(belief.policy.rawValue); interaction readiness is \(String(format: "%.2f", belief.readyProbability))."
    )
}

/// Builds the deliberately bounded semantic projection sent to L2. Local
/// memory is open-ended, while a live interaction packet is not: a single
/// verbose recollection must never discard the current person's voice turn.
private func makeL2InteractionContext(
    situationSummary: String? = nil,
    identityReference: String? = nil,
    personEntityID: UUID? = nil,
    personContextAvailable: Bool? = nil,
    sessionCapability: String? = nil,
    interactionAuthority: SOMAInteractionAuthority? = nil,
    personMemoryMission: PersonContextMission? = nil,
    preferredLanguageTag: String? = nil,
    languageStartInstruction: String? = nil,
    rapportSummary: String? = nil,
    activeTaskSummaries: [String] = [],
    memorySummaries: [String] = [],
    embodimentSummary: String? = nil,
    privacyScope: String = "interaction_scoped"
) -> CodexInteractionContext? {
    func text(_ value: String?, maximumCount: Int) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(maximumCount))
    }

    func list(_ values: [String], maximumItems: Int, maximumCount: Int) -> [String] {
        Array(values.compactMap { text($0, maximumCount: maximumCount) }.prefix(maximumItems))
    }

    return try? CodexInteractionContext(
        situationSummary: text(situationSummary, maximumCount: 8_192),
        identityReference: text(identityReference, maximumCount: 512),
        personEntityID: personEntityID,
        personContextAvailable: personContextAvailable,
        sessionCapability: sessionCapability,
        interactionAuthority: interactionAuthority,
        personMemoryMission: personMemoryMission,
        preferredLanguageTag: text(preferredLanguageTag, maximumCount: 35),
        languageStartInstruction: text(languageStartInstruction, maximumCount: 1_024),
        rapportSummary: text(rapportSummary, maximumCount: 2_048),
        activeTaskSummaries: list(activeTaskSummaries, maximumItems: 16, maximumCount: 1_024),
        memorySummaries: list(memorySummaries, maximumItems: 24, maximumCount: 1_024),
        embodimentSummary: text(embodimentSummary, maximumCount: 2_048),
        privacyScope: text(privacyScope, maximumCount: 96) ?? "interaction_scoped"
    )
}

private func l2IdentityReference(
    base: String?,
    explicitPreferences: String
) -> String? {
    guard let base else { return nil }
    let preferences = explicitPreferences.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !preferences.isEmpty else { return base }
    return String((base + ". Explicit stored preferences: " + preferences).prefix(512))
}

private func l1ProactiveInteractionContext(
    request: L1ExecutiveRequest,
    decision: L1SocialDecision,
    purpose: L1PurposefulOpening,
    languageStartInstruction: String?,
    sessionCapability: String?,
    interactionAuthority: SOMAInteractionAuthority,
    personMemoryMission: PersonContextMission?
) -> CodexInteractionContext? {
    let objective = "Conversation objective: \(purpose.objective)"
    let completion = "Conversation completion condition: \(purpose.completionCondition)"
    let situation = "L1 has opened a brief conversation. The private objective and completion condition are the only proactive reason."
    let identity = "Locally recognized conversation participant; do not infer an identity beyond supplied context. Person context is available only through the supplied local MCP reference."
    let rapport: String
    if let value = request.rapport {
        rapport = String(
            format: "L1 rapport estimate: familiarity %.2f; interaction comfort %.2f; communication alignment %.2f; proactive-contact preference %@.",
            value.familiarity,
            value.interactionComfort,
            value.communicationAlignment,
            value.proactiveContact.rawValue
        )
    } else {
        rapport = "L1 has no established rapport record; keep the first exchange light, reciprocal, and easy to decline."
    }
    let language = request.preferredLanguageTag.map {
        "The person's explicitly stated preferred language is \($0); use it when naturally appropriate."
    }
    let preferences = request.personPreferences.map {
        "The person's explicitly stated durable preferences — honor these as binding rules in how you engage them: \($0)"
    }
    return makeL2InteractionContext(
        situationSummary: situation,
        identityReference: identity,
        personEntityID: decision.entityID,
        sessionCapability: sessionCapability,
        interactionAuthority: interactionAuthority,
        personMemoryMission: personMemoryMission,
        preferredLanguageTag: request.preferredLanguageTag,
        languageStartInstruction: languageStartInstruction,
        rapportSummary: rapport,
        // The opening already carries this one selected motive verbatim. Do
        // not inject the same question again as a generic acquisition mission:
        // duplicate semantic context makes the voice model repeat itself.
        activeTaskSummaries: [objective, completion]
            + (language.map { [$0] } ?? [])
            + (preferences.map { [$0] } ?? []),
        memorySummaries: request.memorySummaries + request.recalledEpisodes,
        embodimentSummary: "L0 is maintaining visual attention while L2 leads the interaction. Do not issue camera-control instructions as part of ordinary conversation."
    )
}

/// Weak holder for the live-voice launcher so the @Sendable event closure can
/// append context to the active conversation without capturing the not-yet-
/// initialized local `let`.
private final class LiveVoiceLauncherBox: @unchecked Sendable {
    weak var launcher: AppServerLiveVoiceLauncher?
}

private final class SpeechInteractionBox: @unchecked Sendable {
    weak var coordinator: LocalSpeechInteractionCoordinator?
}

private final class L1AuxiliaryBridgeBox: @unchecked Sendable {
    weak var bridge: L1AuxiliarySemanticBridge?
}

private final class PoseStoreBox: @unchecked Sendable {
    weak var store: GimbalPoseStore?
}

private final class MemoryContextBox: @unchecked Sendable {
    weak var provider: L1MemoryContextProvider?
}

/// Bounded FIFO queue for parallel L1 object identifications. Detections are
/// enqueued (never dropped by a hard cooldown gate) and drained one at a time
/// by a single worker with a pacing pause between inferences, so the robot
/// does not hammer the model but also does not skip a queued object.
private final class ObjectRecognitionQueue: @unchecked Sendable {
    struct Item {
        let jpeg: Data
        let panDegrees: Double?
        let tiltDegrees: Double?
        let summary: String
        let objectLabel: String
        let personEntityID: UUID?
    }
    private let lock = NSLock()
    private var pending: [Item] = []
    private var draining = false
    private var recentLabels: [(label: String, atNS: UInt64)] = []
    private let maxPending: Int
    private let cooldownSeconds: Double
    private let dedupSeconds: Double
    private let process: @Sendable (Item) -> Void

    init(
        maxPending: Int = 4,
        cooldownMilliseconds: Int = 20_000,
        dedupMilliseconds: Int = 90_000,
        process: @escaping @Sendable (Item) -> Void
    ) {
        self.maxPending = max(1, maxPending)
        self.cooldownSeconds = Double(max(1_000, cooldownMilliseconds)) / 1_000.0
        self.dedupSeconds = Double(max(0, dedupMilliseconds)) / 1_000.0
        self.process = process
    }

    func enqueue(_ item: Item) {
        let nowNS = DispatchTime.now().uptimeNanoseconds
        let label = item.objectLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        // Skip if the same object label was already enqueued (still pending) or
        // processed recently — avoids re-identifying the same object on loop.
        if !label.isEmpty {
            let isPending = pending.contains { $0.objectLabel.caseInsensitiveCompare(label) == .orderedSame }
            let recentlyDone = recentLabels.contains { recent in
                recent.label.caseInsensitiveCompare(label) == .orderedSame
                    && nowNS >= recent.atNS
                    && nowNS - recent.atNS < UInt64(dedupSeconds * 1_000_000_000)
            }
            if isPending || recentlyDone {
                lock.unlock()
                return
            }
        }
        guard pending.count < maxPending else { lock.unlock(); return }
        pending.append(item)
        lock.unlock()
        pump()
    }

    private func pump() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.drain()
        }
    }

    private func drain() {
        lock.lock()
        guard !draining else { lock.unlock(); return }
        draining = true
        lock.unlock()
        defer {
            lock.lock()
            draining = false
            lock.unlock()
        }
        while true {
            lock.lock()
            guard !pending.isEmpty else { return }
            let item = pending.removeFirst()
            lock.unlock()
            process(item)
            let label = item.objectLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            if !label.isEmpty {
                lock.lock()
                recentLabels.append((label, DispatchTime.now().uptimeNanoseconds))
                if recentLabels.count > 12 { recentLabels.removeFirst(recentLabels.count - 12) }
                lock.unlock()
            }
            if cooldownSeconds > 0 {
                Thread.sleep(forTimeInterval: cooldownSeconds)
            }
        }
    }
}

/// Thread-safe store of recently identified objects, injected into the L2
/// conversation context so Codex can reference objects the robot has seen.
/// Used by object-based exploration: each identified object is recorded with
/// the camera pan/tilt it was observed at, building a spatial inventory.
private final class ObjectKnowledgeStore: @unchecked Sendable {
    private struct Entry {
        let name: String
        let category: String
        let description: String
        let panDegrees: Double?
        let tiltDegrees: Double?
        let atNS: UInt64
    }
    private let lock = NSLock()
    private var entries: [Entry] = []

    func record(
        name: String,
        category: String,
        description: String,
        panDegrees: Double?,
        tiltDegrees: Double?,
        atNS: UInt64
    ) {
        lock.lock()
        defer { lock.unlock() }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Avoid immediately repeating the same named object.
        if entries.last?.name.caseInsensitiveCompare(trimmed) == .orderedSame { return }
        entries.append(Entry(
            name: trimmed,
            category: category,
            description: description,
            panDegrees: panDegrees,
            tiltDegrees: tiltDegrees,
            atNS: atNS
        ))
        if entries.count > 16 { entries.removeFirst(entries.count - 16) }
    }

    func recentSummaries(limit: Int = 6) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries.suffix(limit).map { entry in
            var parts = [entry.name]
            if !entry.category.isEmpty { parts.append("category: \(entry.category)") }
            if !entry.description.isEmpty { parts.append(entry.description) }
            if let pan = entry.panDegrees, let tilt = entry.tiltDegrees,
               pan.isFinite, tilt.isFinite {
                parts.append(String(format: "seen at pan %.0f°, tilt %.0f°", pan, tilt))
            }
            return parts.joined(separator: "; ")
        }
    }
}

private final class AccessResult: @unchecked Sendable {
    private let lock = NSLock()
    private var granted = false
    func set(_ granted: Bool) { lock.lock(); self.granted = granted; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return granted }
}

private final class SynchronousResultBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Result<Value, Error>?

    func set(_ value: Result<Value, Error>) {
        lock.lock()
        storage = value
        lock.unlock()
    }

    func get() -> Result<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private struct MonoAudio {
    let samples: [Float]
    let sampleRateHz: Double
    let durationNS: UInt64
    let levelDB: Double
}

private func normalizedSigned24BitSample(
    _ raw: UnsafeRawPointer,
    sampleIndex: Int,
    bigEndian: Bool
) -> Float {
    let bytes = raw.assumingMemoryBound(to: UInt8.self).advanced(by: sampleIndex * 3)
    let packed: UInt32
    if bigEndian {
        packed = UInt32(bytes[2]) | UInt32(bytes[1]) << 8 | UInt32(bytes[0]) << 16
    } else {
        packed = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16
    }
    let signed = Int32(bitPattern: (packed & 0x0080_0000) == 0 ? packed : packed | 0xff00_0000)
    return Float(signed) / 8_388_607
}

private func describeAudioFormat(_ sampleBuffer: CMSampleBuffer) -> String {
    guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else {
        return "audio_stream_description_unavailable"
    }
    let hasBlockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) != nil
    return String(
        format: "format_id=0x%08x; sample_rate_hz=%.0f; channels=%u; bits=%u; bytes_per_frame=%u; bytes_per_packet=%u; frames_per_packet=%u; flags=0x%08x; block_buffer=%@",
        asbd.mFormatID,
        asbd.mSampleRate,
        asbd.mChannelsPerFrame,
        asbd.mBitsPerChannel,
        asbd.mBytesPerFrame,
        asbd.mBytesPerPacket,
        asbd.mFramesPerPacket,
        asbd.mFormatFlags,
        hasBlockBuffer ? "present" : "absent"
    )
}

private func monoAudio(from sampleBuffer: CMSampleBuffer) -> MonoAudio? {
    guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
          asbd.mFormatID == kAudioFormatLinearPCM,
          let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
        return nil
    }
    var lengthAtOffset = 0
    var totalLength = 0
    var dataPointer: UnsafeMutablePointer<Int8>?
    guard CMBlockBufferGetDataPointer(
        blockBuffer,
        atOffset: 0,
        lengthAtOffsetOut: &lengthAtOffset,
        totalLengthOut: &totalLength,
        dataPointerOut: &dataPointer
    ) == kCMBlockBufferNoErr,
          let dataPointer,
          totalLength > 0 else {
        return nil
    }

    let bytesPerSample = Int(asbd.mBitsPerChannel / 8)
    let bytesPerFrame = Int(asbd.mBytesPerFrame)
    guard bytesPerSample > 0, bytesPerFrame >= bytesPerSample else { return nil }
    let scalarStride = max(1, bytesPerFrame / bytesPerSample)
    let valuesPerFrame = min(max(1, Int(asbd.mChannelsPerFrame)), scalarStride)
    let frameCount = totalLength / bytesPerFrame
    guard frameCount > 0, asbd.mSampleRate > 0 else { return nil }
    let durationNS = UInt64((Double(frameCount) / asbd.mSampleRate * 1_000_000_000).rounded())
    guard durationNS > 0 else { return nil }

    let flags = asbd.mFormatFlags
    let isFloat = (flags & kAudioFormatFlagIsFloat) != 0
    let isSignedInteger = (flags & kAudioFormatFlagIsSignedInteger) != 0
    let isBigEndian = (flags & kAudioFormatFlagIsBigEndian) != 0
    let raw = UnsafeRawPointer(dataPointer)
    var samples: [Float] = []
    samples.reserveCapacity(frameCount)
    if isFloat, asbd.mBitsPerChannel == 32 {
        let input = raw.bindMemory(to: Float.self, capacity: totalLength / MemoryLayout<Float>.size)
        for frame in 0..<frameCount {
            let base = frame * scalarStride
            var sum: Float = 0
            for channel in 0..<valuesPerFrame {
                sum += input[base + channel]
            }
            samples.append(sum / Float(valuesPerFrame))
        }
    } else if isSignedInteger, asbd.mBitsPerChannel == 16 {
        let input = raw.bindMemory(to: Int16.self, capacity: totalLength / MemoryLayout<Int16>.size)
        for frame in 0..<frameCount {
            let base = frame * scalarStride
            var sum: Float = 0
            for channel in 0..<valuesPerFrame {
                sum += Float(input[base + channel]) / Float(Int16.max)
            }
            samples.append(sum / Float(valuesPerFrame))
        }
    } else if isSignedInteger, asbd.mBitsPerChannel == 24, bytesPerSample == 3 {
        for frame in 0..<frameCount {
            let base = frame * scalarStride
            var sum: Float = 0
            for channel in 0..<valuesPerFrame {
                sum += normalizedSigned24BitSample(raw, sampleIndex: base + channel, bigEndian: isBigEndian)
            }
            samples.append(sum / Float(valuesPerFrame))
        }
    } else {
        return nil
    }
    guard !samples.isEmpty else { return nil }
    let rms = sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count))
    return MonoAudio(
        samples: samples,
        sampleRateHz: asbd.mSampleRate,
        durationNS: durationNS,
        levelDB: 20 * log10(max(rms, 0.000_001))
    )
}

private struct StereoSamples {
    let left: [Float]
    let right: [Float]
    let sampleRateHz: Double
}

private enum StereoSampleOutcome {
    case samples(StereoSamples)
    case rejected(StereoTDOARejection)
}

private func stereoSamples(from sampleBuffer: CMSampleBuffer) -> StereoSampleOutcome {
    guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
          asbd.mFormatID == kAudioFormatLinearPCM,
          asbd.mChannelsPerFrame >= 2,
          asbd.mSampleRate > 0,
          let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
        return .rejected(.invalidInput)
    }
    var lengthAtOffset = 0
    var totalLength = 0
    var dataPointer: UnsafeMutablePointer<Int8>?
    guard CMBlockBufferGetDataPointer(
        blockBuffer,
        atOffset: 0,
        lengthAtOffsetOut: &lengthAtOffset,
          totalLengthOut: &totalLength,
          dataPointerOut: &dataPointer
    ) == kCMBlockBufferNoErr,
          let dataPointer else {
        return .rejected(.invalidInput)
    }
    let bytesPerSample = Int(asbd.mBitsPerChannel / 8)
    let bytesPerFrame = Int(asbd.mBytesPerFrame)
    guard bytesPerSample > 0, bytesPerFrame >= bytesPerSample * 2 else { return .rejected(.invalidInput) }
    let scalarStride = bytesPerFrame / bytesPerSample
    let frameCount = totalLength / bytesPerFrame
    guard scalarStride >= 2, frameCount >= 64 else { return .rejected(.invalidInput) }

    var left: [Float] = []
    var right: [Float] = []
    left.reserveCapacity(frameCount)
    right.reserveCapacity(frameCount)
    let raw = UnsafeRawPointer(dataPointer)
    let flags = asbd.mFormatFlags
    if (flags & kAudioFormatFlagIsFloat) != 0, asbd.mBitsPerChannel == 32 {
        let samples = raw.bindMemory(to: Float.self, capacity: totalLength / MemoryLayout<Float>.size)
        for frame in 0..<frameCount {
            let offset = frame * scalarStride
            left.append(samples[offset])
            right.append(samples[offset + 1])
        }
    } else if (flags & kAudioFormatFlagIsSignedInteger) != 0, asbd.mBitsPerChannel == 16 {
        let samples = raw.bindMemory(to: Int16.self, capacity: totalLength / MemoryLayout<Int16>.size)
        for frame in 0..<frameCount {
            let offset = frame * scalarStride
            left.append(Float(samples[offset]) / Float(Int16.max))
            right.append(Float(samples[offset + 1]) / Float(Int16.max))
        }
    } else if (flags & kAudioFormatFlagIsSignedInteger) != 0,
              asbd.mBitsPerChannel == 24,
              bytesPerSample == 3 {
        let isBigEndian = (flags & kAudioFormatFlagIsBigEndian) != 0
        for frame in 0..<frameCount {
            let offset = frame * scalarStride
            left.append(normalizedSigned24BitSample(raw, sampleIndex: offset, bigEndian: isBigEndian))
            right.append(normalizedSigned24BitSample(raw, sampleIndex: offset + 1, bigEndian: isBigEndian))
        }
    } else {
        return .rejected(.invalidInput)
    }
    return .samples(StereoSamples(left: left, right: right, sampleRateHz: asbd.mSampleRate))
}

private extension SOMACore.NormalizedRect {
    init(_ rect: CGRect) {
        self.init(x: Double(rect.origin.x), y: Double(rect.origin.y), width: Double(rect.width), height: Double(rect.height))
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

private func identity(_ device: AVCaptureDevice) -> DeviceIdentity {
    DeviceIdentity(name: device.localizedName, uniqueID: device.uniqueID, modelID: device.modelID)
}

private func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }

private func milliseconds(from earlier: UInt64, to later: UInt64) -> Double {
    guard later >= earlier else { return 0 }
    return Double(later - earlier) / 1_000_000
}

/// AVCapture video timestamps normally share the macOS host-time epoch. Keep
/// the measured presentation timestamp only when it agrees with Dispatch
/// uptime; a different session clock falls back to callback time rather than
/// corrupting the spatial map.
private func hostAlignedPresentationTimestamp(
    sampleBuffer: CMSampleBuffer,
    fallbackNS: UInt64
) -> UInt64 {
    let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    let seconds = CMTimeGetSeconds(timestamp)
    guard timestamp.isValid,
          !timestamp.isIndefinite,
          seconds.isFinite,
          seconds >= 0,
          seconds <= Double(UInt64.max) / 1_000_000_000 else {
        return fallbackNS
    }
    let candidate = UInt64((seconds * 1_000_000_000).rounded())
    let difference = candidate > fallbackNS ? candidate - fallbackNS : fallbackNS - candidate
    return difference <= 1_000_000_000 ? candidate : fallbackNS
}

private func monotonicNanoseconds() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

private func printUsage() {
    print("Usage: soma-subconscious --video-id <OBSBOT video ID> --audio-id <OBSBOT audio ID> [--duration seconds] [--soma-settings /absolute/settings.json] [--guided-scenario] [--tdoa-calibration calibration.json | --tdoa-calibrate calibration.json --duration 45] [--output trace.jsonl [--trace-max-megabytes MB --trace-retained-files count] [--important-output important.jsonl --important-max-megabytes MB --important-retained-files count]] [--diagnostic-snapshot frame.jpg | --face-lock-diagnostics jpeg-directory] [--panorama-output /absolute/panorama.jpg [--panorama-place-memory /absolute/place-memory.json] [--camera-geometry-calibration /absolute/calibration.json] [--capture-camera-geometry /absolute/new-directory | --panorama-strip-scan]] [--l2-live-voice | --local-speech-recognition locale [--l2-codex-bridge /absolute/soma-codex-bridge]] [--l1-auxiliary-vlm-python python --l1-auxiliary-vlm-worker worker.py --l1-auxiliary-vlm-model local-model-directory] [--embodiment-shadow-socket /absolute/path.sock [--allow-embodiment-motor-control --embodiment-view-directory /absolute/private-directory]] [--allow-camera-motion --native-gimbal-helper /path/to/soma-native-track [--native-gimbal-shutdown-helper /path/to/soma-native-track] --gimbal-output actuator.jsonl [--gimbal-trace-max-megabytes MB --gimbal-trace-retained-files count] --duration 0=continuous|positive-seconds] [--allow-external-gimbal-control --external-gimbal-calibration calibration.json [--allow-autonomous-scan] | --calibrate-external-gimbal calibration.json --duration 12..30] [--allow-native-human-tracking]")
    print("       soma-subconscious --speech-recognition-status [locale]")
    print("       soma-subconscious --speech-recognition-file <locale> <absolute-audio-path>")
    print("       soma-subconscious --speech-synthesis-test <locale> <text>")
    print("       soma-subconscious --live-voice-test")
    print("       soma-subconscious --hermes-agent-test")
    print("       soma-subconscious --face-identity-status")
    print("       soma-subconscious --promote-anonymous-face <anon_handle>")
    print("       soma-subconscious --remove-face-identity <entity_uuid>")
}

let somaArguments = Array(CommandLine.arguments.dropFirst())
if somaArguments.first == "--speech-recognition-status" {
    let localeIdentifier = somaArguments.count > 1
        ? somaArguments[1]
        : Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
    let capability = localSpeechCapability(localeIdentifier: localeIdentifier)
    print("engine=speech_analyzer")
    print("locale=\(capability.localeIdentifier)")
    print("supported=\(capability.supported)")
    print("installed=\(capability.installed)")
    print("on_device=true")
    Foundation.exit(capability.supported && capability.installed ? EXIT_SUCCESS : EXIT_FAILURE)
} else if somaArguments.first == "--speech-recognition-file" {
    guard somaArguments.count == 3, somaArguments[2].hasPrefix("/") else {
        fputs("soma-subconscious: --speech-recognition-file requires a locale and absolute audio path\n", stderr)
        Foundation.exit(EXIT_FAILURE)
    }
    do {
        let startedNS = monotonicNanoseconds()
        let result = try transcribeLocalSpeechFile(
            at: URL(fileURLWithPath: somaArguments[2]),
            localeIdentifier: somaArguments[1]
        )
        print("engine=speech_analyzer")
        print("locale=\(result.localeIdentifier)")
        print("latency_ms=\(milliseconds(from: startedNS, to: result.completedNS))")
        print("transcript=\(result.transcript)")
        Foundation.exit(result.transcript.isEmpty ? EXIT_FAILURE : EXIT_SUCCESS)
    } catch {
        fputs("soma-subconscious: \(error.localizedDescription)\n", stderr)
        Foundation.exit(EXIT_FAILURE)
    }
} else if somaArguments.first == "--speech-synthesis-test" {
    guard somaArguments.count == 3 else {
        fputs("soma-subconscious: --speech-synthesis-test requires a locale and text\n", stderr)
        Foundation.exit(EXIT_FAILURE)
    }
    do {
        let durationMilliseconds = try testLocalSpeechOutput(
            text: somaArguments[2],
            localeIdentifier: somaArguments[1]
        )
        print("engine=av_speech_synthesizer")
        print("locale=\(somaArguments[1])")
        print("duration_ms=\(durationMilliseconds)")
        Foundation.exit(EXIT_SUCCESS)
    } catch {
        fputs("soma-subconscious: \(error.localizedDescription)\n", stderr)
        Foundation.exit(EXIT_FAILURE)
    }
} else if somaArguments.first == "--live-voice-test" {
    guard somaArguments.count == 1 else {
        fputs("soma-subconscious: --live-voice-test takes no additional arguments\n", stderr)
        Foundation.exit(EXIT_FAILURE)
    }
    let result = testAppServerLiveVoiceLauncher()
    print("live_voice=\(result)")
        Foundation.exit(result == "active" ? EXIT_SUCCESS : EXIT_FAILURE)
} else if somaArguments.first == "--hermes-agent-test" {
    guard somaArguments.count == 1 else {
        fputs("soma-subconscious: --hermes-agent-test takes no additional arguments\n", stderr)
        Foundation.exit(EXIT_FAILURE)
    }
    do {
        let result = try await testHermesAgentProtocolBridge()
        print("hermes_agent=\(result)")
        Foundation.exit(result == "SOMA_HERMES_BRIDGE_OK" ? EXIT_SUCCESS : EXIT_FAILURE)
    } catch {
        fputs("soma-subconscious: \(error.localizedDescription)\n", stderr)
        Foundation.exit(EXIT_FAILURE)
    }
} else if somaArguments.first == "--face-identity-status" {
    guard somaArguments.count == 1 else {
        fputs("soma-subconscious: --face-identity-status takes no additional arguments\n", stderr)
        Foundation.exit(EXIT_FAILURE)
    }
    do {
        let counts = try await FaceIdentityRuntime.referenceCounts()
        print("known_profiles=\(counts.knownProfileReferenceCounts.count)")
        print("known_references_per_profile=\(counts.knownProfileReferenceCounts.map(String.init).joined(separator: ","))")
        print("anonymous_clusters=\(counts.anonymousClusterReferenceCounts.count)")
        print("anonymous_references_per_cluster=\(counts.anonymousClusterReferenceCounts.map(String.init).joined(separator: ","))")
        Foundation.exit(EXIT_SUCCESS)
    } catch {
        fputs("soma-subconscious: \(error.localizedDescription)\n", stderr)
        Foundation.exit(EXIT_FAILURE)
    }
} else if somaArguments.first == "--promote-anonymous-face" {
    guard somaArguments.count == 2,
          let handle = try? AnonymousFaceHandle(rawValue: somaArguments[1]) else {
        fputs("soma-subconscious: --promote-anonymous-face requires an anon handle\n", stderr)
        Foundation.exit(EXIT_FAILURE)
    }
    do {
        let result = try await FaceIdentityRuntime.promoteAnonymousIdentity(handle: handle)
        print("entity_id=\(result.entityID.uuidString.lowercased())")
        print("references=\(result.referenceCount)")
        print("profile=encrypted_local_v2")
        Foundation.exit(EXIT_SUCCESS)
    } catch {
        fputs("soma-subconscious: \(error.localizedDescription)\n", stderr)
        Foundation.exit(EXIT_FAILURE)
    }
} else if somaArguments.first == "--remove-face-identity" {
    guard somaArguments.count == 2,
          let entityID = UUID(uuidString: somaArguments[1]) else {
        fputs("soma-subconscious: --remove-face-identity requires a profile UUID\n", stderr)
        Foundation.exit(EXIT_FAILURE)
    }
    do {
        try await FaceIdentityRuntime.removeKnownIdentity(entityID: entityID)
        print("entity_id=\(entityID.uuidString.lowercased())")
        print("profile=removed")
        Foundation.exit(EXIT_SUCCESS)
    } catch {
        fputs("soma-subconscious: \(error.localizedDescription)\n", stderr)
        Foundation.exit(EXIT_FAILURE)
    }
} else {
    do {
        try run(Options.parse(somaArguments))
    } catch {
        fputs("soma-subconscious: \(error.localizedDescription)\n", stderr)
        Foundation.exit(EXIT_FAILURE)
    }
}
