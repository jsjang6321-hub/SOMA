import Foundation
import SOMACore

private struct DailyWorldMemoryJSON: @unchecked Sendable {
    let value: [String: Any]
}

private enum DailyWorldMemoryCollectorError: LocalizedError {
    case codexNotFound
    case appServer(String)
    case invalidBrief

    var errorDescription: String? {
        switch self {
        case .codexNotFound:
            return "codex_app_server_not_found"
        case let .appServer(message):
            return "app_server_\(String(message.prefix(192)))"
        case .invalidBrief:
            return "daily_world_memory_invalid_brief"
        }
    }
}

/// Collects one compact, public-world brief for a local calendar day. The
/// App Server request is ephemeral and receives no camera, identity, memory,
/// or transcript data. A separate local L1 step decides whether any topic is
/// relevant to an observed person.
final class AppServerDailyWorldMemoryCollector: @unchecked Sendable {
    typealias WorldMemoryHandler = @Sendable (L1DailyWorldMemory) -> Void
    typealias HealthHandler = @Sendable (String, String) -> Void

    private let queue = DispatchQueue(label: "soma.daily-world-memory", qos: .utility)
    private let workingDirectory: URL
    private let onWorldMemory: WorldMemoryHandler
    private let onHealth: HealthHandler
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var error: FileHandle?
    private var outputBuffer = Data()
    private var nextRequestID = 1
    private var responseHandlers: [Int: @Sendable (DailyWorldMemoryJSON) -> Void] = [:]
    private var activeThreadID: String?
    private var latestAgentMessage: String?
    private var activeDay: String?
    private var attemptedDay: String?
    private var generation: UInt64 = 0
    private var running = false

    init(
        workingDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SOMA/world-memory", isDirectory: true),
        onWorldMemory: @escaping WorldMemoryHandler,
        onHealth: @escaping HealthHandler
    ) {
        self.workingDirectory = workingDirectory
        self.onWorldMemory = onWorldMemory
        self.onHealth = onHealth
    }

    func collectIfNeeded(current: L1DailyWorldMemory?, at date: Date = Date()) {
        queue.async { [weak self] in
            guard let self else { return }
            let day = Self.localDayKey(for: date)
            guard current?.localDay != day,
                  attemptedDay != day,
                  !running else {
                return
            }
            attemptedDay = day
            launch(for: day, at: date)
        }
    }

    func stop() {
        queue.sync {
            finish(generation: generation, result: nil, failure: nil)
        }
    }

    private func launch(for day: String, at date: Date) {
        guard let executable = SOMACodexLocator.locate()?.executableURL else {
            onHealth("unavailable", "reason=codex_app_server_not_found")
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: workingDirectory,
                withIntermediateDirectories: true
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: workingDirectory.path
            )
        } catch {
            onHealth("unavailable", "reason=working_directory")
            return
        }

        generation &+= 1
        let activeGeneration = generation
        activeDay = day
        latestAgentMessage = nil
        activeThreadID = nil
        outputBuffer.removeAll(keepingCapacity: true)
        responseHandlers.removeAll(keepingCapacity: true)
        nextRequestID = 1
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        let collector = self
        outputPipe.fileHandleForReading.readabilityHandler = { [weak collector] handle in
            let data = handle.availableData
            guard !data.isEmpty, let collector else { return }
            collector.queue.async {
                collector.consume(data, generation: activeGeneration)
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        process.terminationHandler = { [weak collector] exited in
            guard let collector else { return }
            collector.queue.async {
                guard activeGeneration == collector.generation, collector.running else { return }
                collector.finish(
                    generation: activeGeneration,
                    result: nil,
                    failure: DailyWorldMemoryCollectorError.appServer("exited_\(exited.terminationStatus)")
                )
            }
        }
        do {
            try process.run()
        } catch {
            onHealth("unavailable", "reason=app_server_launch_failed")
            return
        }
        self.process = process
        input = inputPipe.fileHandleForWriting
        output = outputPipe.fileHandleForReading
        error = errorPipe.fileHandleForReading
        running = true
        onHealth("collecting", "day=\(day); model=gpt-5.6-luna; privacy=public_world_only")
        request(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "soma-daily-world-memory",
                    "title": "SOMA Daily World Memory",
                    "version": "0.1.0",
                ],
                "capabilities": [
                    "experimentalApi": true,
                    "requestAttestation": false,
                ],
            ]
        ) { [weak self] response in
            guard let self else { return }
            guard response.value["error"] == nil else {
                self.finish(
                    generation: activeGeneration,
                    result: nil,
                    failure: DailyWorldMemoryCollectorError.appServer(Self.responseMessage(response.value))
                )
                return
            }
            self.notify(method: "initialized", params: [:])
            self.startThread(for: day, generation: activeGeneration)
        }
        queue.asyncAfter(deadline: .now() + 90) { [weak self] in
            guard let self,
                  self.running,
                  self.generation == activeGeneration else { return }
            self.finish(
                generation: activeGeneration,
                result: nil,
                failure: DailyWorldMemoryCollectorError.appServer("deadline_exceeded")
            )
        }
    }

    private func startThread(for day: String, generation: UInt64) {
        request(
            method: "thread/start",
            params: [
                "cwd": workingDirectory.path,
                "threadSource": "other",
                "ephemeral": true,
                "approvalPolicy": "never",
                "sandbox": "read-only",
                "model": "gpt-5.6-luna",
                "developerInstructions": "You are an isolated public-world research service for a local assistant. Use web research only. Do not inspect local files, camera data, identity records, conversations, processes, or MCP tools. Do not perform actions outside concise factual research.",
            ]
        ) { [weak self] response in
            guard let self else { return }
            guard response.value["error"] == nil,
                  let result = response.value["result"] as? [String: Any],
                  let thread = result["thread"] as? [String: Any],
                  let threadID = thread["id"] as? String else {
                self.finish(
                    generation: generation,
                    result: nil,
                    failure: DailyWorldMemoryCollectorError.appServer(Self.responseMessage(response.value))
                )
                return
            }
            self.activeThreadID = threadID
            self.startTurn(threadID: threadID, day: day, generation: generation)
        }
    }

    private func startTurn(threadID: String, day: String, generation: UInt64) {
        let prompt = """
        Today is \(day) in SOMA's local calendar. Research the current external world using web search. Return exactly one JSON object and nothing else:
        {"local_day":"\(day)","topics":[{"title":"brief factual title","summary":"two concise factual sentences","source_url":"https://direct-source.example/path","tags":["tag"]}]}

        Include exactly 3 genuinely current, high-signal topics across public affairs, science/technology, culture, or practical interest. Every topic must have a direct HTTPS source URL. Do not mention SOMA, private people, local data, or how you searched. Do not speculate, fabricate sources, or use a generic advice list.
        """
        request(
            method: "turn/start",
            params: [
                "threadId": threadID,
                "input": [["type": "text", "text": prompt]],
                "model": "gpt-5.6-luna",
                "effort": "low",
                "sandboxPolicy": ["type": "readOnly", "networkAccess": true],
            ]
        ) { [weak self] response in
            guard let self else { return }
            guard response.value["error"] == nil else {
                self.finish(
                    generation: generation,
                    result: nil,
                    failure: DailyWorldMemoryCollectorError.appServer(Self.responseMessage(response.value))
                )
                return
            }
        }
    }

    private func request(
        method: String,
        params: [String: Any],
        completion: @escaping @Sendable (DailyWorldMemoryJSON) -> Void
    ) {
        let requestID = nextRequestID
        nextRequestID += 1
        responseHandlers[requestID] = completion
        write(["id": requestID, "method": method, "params": params])
    }

    private func notify(method: String, params: [String: Any]) {
        write(["method": method, "params": params])
    }

    private func write(_ object: [String: Any]) {
        guard running,
              JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else {
            return
        }
        input?.write(data)
        input?.write(Data([0x0A]))
    }

    private func consume(_ data: Data, generation: UInt64) {
        guard running, generation == self.generation else { return }
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line),
                  let message = object as? [String: Any] else {
                continue
            }
            if let id = message["id"] as? Int,
               let completion = responseHandlers.removeValue(forKey: id) {
                completion(DailyWorldMemoryJSON(value: message))
                continue
            }
            guard let method = message["method"] as? String,
                  let params = message["params"] as? [String: Any] else {
                continue
            }
            handleNotification(method: method, params: params, generation: generation)
        }
    }

    private func handleNotification(
        method: String,
        params: [String: Any],
        generation: UInt64
    ) {
        switch method {
        case "item/completed":
            if let item = params["item"] as? [String: Any],
               item["type"] as? String == "agentMessage",
               let text = item["text"] as? String {
                latestAgentMessage = text
            }
        case "turn/completed":
            guard params["threadId"] as? String == activeThreadID else { return }
            let turn = params["turn"] as? [String: Any]
            let text = Self.lastAgentMessage(in: turn) ?? latestAgentMessage
            guard let text,
                  let day = activeDay,
                  let memory = Self.decodeWorldMemory(text, expectedDay: day) else {
                finish(generation: generation, result: nil, failure: DailyWorldMemoryCollectorError.invalidBrief)
                return
            }
            finish(generation: generation, result: memory, failure: nil)
        default:
            break
        }
    }

    private func finish(
        generation: UInt64,
        result: L1DailyWorldMemory?,
        failure: Error?
    ) {
        guard generation == self.generation else { return }
        let wasRunning = running
        running = false
        output?.readabilityHandler = nil
        error?.readabilityHandler = nil
        input = nil
        output = nil
        error = nil
        responseHandlers.removeAll(keepingCapacity: false)
        activeThreadID = nil
        activeDay = nil
        latestAgentMessage = nil
        let child = process
        process = nil
        if child?.isRunning == true {
            child?.terminate()
        }
        if let result {
            onWorldMemory(result)
            onHealth("collected", "day=\(result.localDay); topics=\(result.topics.count); model=gpt-5.6-luna")
        } else if wasRunning, let failure {
            onHealth("failed", String(failure.localizedDescription.prefix(192)))
        }
    }

    private static func lastAgentMessage(in turn: [String: Any]?) -> String? {
        let items = turn?["items"] as? [[String: Any]] ?? []
        return items.reversed().first { $0["type"] as? String == "agentMessage" }?["text"] as? String
    }

    private static func decodeWorldMemory(_ raw: String, expectedDay: String) -> L1DailyWorldMemory? {
        let text = normalizedJSON(raw)
        struct Payload: Decodable {
            let localDay: String
            let topics: [Topic]

            struct Topic: Decodable {
                let title: String
                let summary: String
                let sourceURL: String
                let tags: [String]

                enum CodingKeys: String, CodingKey {
                    case title
                    case summary
                    case sourceURL = "source_url"
                    case tags
                }
            }

            enum CodingKeys: String, CodingKey {
                case localDay = "local_day"
                case topics
            }
        }
        guard let data = text.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.localDay == expectedDay else {
            return nil
        }
        let memory = L1DailyWorldMemory(
            localDay: payload.localDay,
            collectedAt: Date(),
            topics: payload.topics.map {
                L1DailyWorldTopic(
                    title: $0.title,
                    summary: $0.summary,
                    sourceURL: $0.sourceURL,
                    tags: $0.tags
                )
            }
        )
        return memory.topics.count >= 3 ? memory : nil
    }

    private static func normalizedJSON(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```"),
              let firstNewline = trimmed.firstIndex(of: "\n"),
              trimmed.hasSuffix("```") else {
            return trimmed
        }
        let start = trimmed.index(after: firstNewline)
        let end = trimmed.index(trimmed.endIndex, offsetBy: -3)
        return String(trimmed[start..<end].trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func responseMessage(_ response: [String: Any]) -> String {
        if let error = response["error"] as? [String: Any],
           let message = error["message"] as? String {
            return String(message.prefix(256))
        }
        return "request_failed"
    }

    private static func localDayKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

}
