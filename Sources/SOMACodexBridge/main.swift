import Darwin
import Foundation
import SOMACore

private enum BridgeFailure: Error, LocalizedError {
    case invalidArgument(String)
    case codexNotFound
    case chatGPTLoginRequired
    case requestTooLarge
    case unsupportedSchema
    case codexTimedOut
    case codexFailed(Int32)
    case outputTooLarge

    var errorDescription: String? {
        switch self {
        case let .invalidArgument(message): message
        case .codexNotFound: "Codex CLI was not found"
        case .chatGPTLoginRequired: "Codex CLI is not signed in with ChatGPT"
        case .requestTooLarge: "request exceeds 1 MiB"
        case .unsupportedSchema: "unsupported bridge request schema"
        case .codexTimedOut: "Codex turn timed out"
        case let .codexFailed(status): "Codex exited with status \(status)"
        case .outputTooLarge: "Codex output exceeded 4 MiB"
        }
    }
}

private struct Options {
    let codexURL: URL
    let workingDirectory: URL
    let timeoutSeconds: Double

    static func parse(_ arguments: [String]) throws -> Options {
        var codexPath: String?
        var workingDirectoryPath: String?
        var timeoutSeconds = 45.0
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--codex":
                index += 1
                guard index < arguments.count else {
                    throw BridgeFailure.invalidArgument("--codex requires an executable path")
                }
                codexPath = arguments[index]
            case "--working-directory":
                index += 1
                guard index < arguments.count else {
                    throw BridgeFailure.invalidArgument("--working-directory requires a path")
                }
                workingDirectoryPath = arguments[index]
            case "--timeout":
                index += 1
                guard index < arguments.count,
                      let value = Double(arguments[index]),
                      value >= 5, value <= 120 else {
                    throw BridgeFailure.invalidArgument("--timeout must be between 5 and 120 seconds")
                }
                timeoutSeconds = value
            case "--help", "-h":
                usage()
                exit(0)
            default:
                throw BridgeFailure.invalidArgument("unknown argument: \(arguments[index])")
            }
            index += 1
        }

        let codexURL: URL
        if let codexPath {
            codexURL = URL(fileURLWithPath: codexPath)
        } else if let discovered = SOMACodexLocator.locate() {
            codexURL = discovered.executableURL
        } else {
            throw BridgeFailure.codexNotFound
        }
        guard FileManager.default.isExecutableFile(atPath: codexURL.path) else {
            throw BridgeFailure.codexNotFound
        }

        let workingDirectory: URL
        if let workingDirectoryPath {
            workingDirectory = URL(fileURLWithPath: workingDirectoryPath, isDirectory: true)
        } else {
            workingDirectory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/SOMA/L2Codex", isDirectory: true)
        }
        try FileManager.default.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: workingDirectory.path
        )
        return Options(
            codexURL: codexURL,
            workingDirectory: workingDirectory,
            timeoutSeconds: timeoutSeconds
        )
    }

}

private final class BoundedPipeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let readers = DispatchGroup()
    private let maximumBytes: Int
    private var storage = Data()
    private var limitExceeded = false

    var exceededLimit: Bool {
        lock.lock()
        defer { lock.unlock() }
        return limitExceeded
    }

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    func start(_ handle: FileHandle) {
        readers.enter()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer { self?.readers.leave() }
            while true {
                do {
                    guard let chunk = try handle.read(upToCount: 64 * 1_024),
                          !chunk.isEmpty else { return }
                    self?.append(chunk)
                } catch {
                    return
                }
            }
        }
    }

    func finish() -> Data {
        _ = readers.wait(timeout: .now() + 5)
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    private func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard storage.count < maximumBytes else {
            limitExceeded = true
            return
        }
        let remaining = maximumBytes - storage.count
        storage.append(data.prefix(remaining))
        if data.count > remaining { limitExceeded = true }
    }
}

private struct ProcessResult {
    let stdout: Data
    let stderr: Data
    let status: Int32
    let timedOut: Bool
}

private enum ChildProcessRunner {
    static func run(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL,
        stdin: Data = Data(),
        timeoutSeconds: Double
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let output = BoundedPipeCollector(maximumBytes: 4 * 1_024 * 1_024)
        let errors = BoundedPipeCollector(maximumBytes: 512 * 1_024)
        output.start(outputPipe.fileHandleForReading)
        errors.start(errorPipe.fileHandleForReading)

        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        try process.run()
        if !stdin.isEmpty { try inputPipe.fileHandleForWriting.write(contentsOf: stdin) }
        try inputPipe.fileHandleForWriting.close()

        var timedOut = terminated.wait(timeout: .now() + timeoutSeconds) == .timedOut
        if timedOut {
            process.terminate()
            if terminated.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = terminated.wait(timeout: .now() + 2)
            }
        }
        timedOut = timedOut || process.isRunning
        let stdout = output.finish()
        let stderr = errors.finish()
        guard !output.exceededLimit, !errors.exceededLimit else {
            throw BridgeFailure.outputTooLarge
        }
        let status: Int32 = process.isRunning ? -1 : process.terminationStatus
        return ProcessResult(
            stdout: stdout,
            stderr: stderr,
            status: status,
            timedOut: timedOut
        )
    }
}

private struct ReadyEvent: Encodable {
    let event = "bridge.ready"
    let schemaVersion = 1
    let authentication = "chatgpt"
    let transport = "codex_exec"
    let monotonicNS: UInt64
}

private struct CompletedEvent: Encodable {
    let event = "turn.completed"
    let schemaVersion = 1
    let interactionID: String
    let turnID: String
    let codexThreadID: String
    let assistantText: String
    let startedAtNS: UInt64
    let completedAtNS: UInt64
    let latencyMilliseconds: Double
    let usage: CodexCLIUsage?
}

private struct FailureEvent: Encodable {
    let event = "turn.failed"
    let schemaVersion = 1
    let interactionID: String?
    let turnID: String?
    let monotonicNS: UInt64
    let error: String
}

private final class CodexAccountBridge {
    private let options: Options
    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder
    private var threadByInteraction: [String: String] = [:]
    private var interactionOrder: [String] = []

    init(options: Options) {
        self.options = options
        encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    func run() throws {
        try requireChatGPTLogin()
        write(ReadyEvent(monotonicNS: DispatchTime.now().uptimeNanoseconds))
        while let line = readLine(strippingNewline: true) {
            guard line.lengthOfBytes(using: .utf8) <= 1_048_576 else {
                writeFailure(error: BridgeFailure.requestTooLarge)
                continue
            }
            let request: CodexAccountTurnRequest
            do {
                request = try decoder.decode(CodexAccountTurnRequest.self, from: Data(line.utf8))
            } catch {
                writeFailure(error: error)
                continue
            }
            do {
                guard request.schemaVersion == 1 else { throw BridgeFailure.unsupportedSchema }
                try request.validate()
                try handle(request)
            } catch {
                writeFailure(
                    error: error,
                    interactionID: request.turn.interactionID,
                    turnID: request.turn.turnID
                )
            }
        }
    }

    private func requireChatGPTLogin() throws {
        let result = try ChildProcessRunner.run(
            executableURL: options.codexURL,
            arguments: ["login", "status"],
            currentDirectoryURL: options.workingDirectory,
            timeoutSeconds: 10
        )
        guard !result.timedOut,
              result.status == 0,
              String(decoding: result.stdout + result.stderr, as: UTF8.self)
                .contains("Logged in using ChatGPT") else {
            throw BridgeFailure.chatGPTLoginRequired
        }
    }

    private func handle(_ request: CodexAccountTurnRequest) throws {
        let startedAtNS = DispatchTime.now().uptimeNanoseconds
        let resumeThreadID = request.resumeCodexThreadID
            ?? threadByInteraction[request.turn.interactionID]
        let arguments: [String]
        if let resumeThreadID {
            arguments = [
                "exec", "resume",
                "--ignore-user-config", "--ignore-rules", "--skip-git-repo-check",
                "--json", resumeThreadID, "-",
            ]
        } else {
            arguments = [
                "exec",
                "--ignore-user-config", "--ignore-rules", "--skip-git-repo-check",
                "--sandbox", "read-only", "--json",
                "-C", options.workingDirectory.path, "-",
            ]
        }
        let prompt = CodexAccountPromptBuilder.prompt(for: request) + "\n"
        let process = try ChildProcessRunner.run(
            executableURL: options.codexURL,
            arguments: arguments,
            currentDirectoryURL: options.workingDirectory,
            stdin: Data(prompt.utf8),
            timeoutSeconds: options.timeoutSeconds
        )
        guard !process.timedOut else { throw BridgeFailure.codexTimedOut }
        guard process.status == 0 else { throw BridgeFailure.codexFailed(process.status) }
        let result = try CodexCLIJSONLParser.parse(process.stdout)
        remember(threadID: result.threadID, for: request.turn.interactionID)
        let completedAtNS = DispatchTime.now().uptimeNanoseconds
        write(
            CompletedEvent(
                interactionID: request.turn.interactionID,
                turnID: request.turn.turnID,
                codexThreadID: result.threadID,
                assistantText: result.assistantText,
                startedAtNS: startedAtNS,
                completedAtNS: completedAtNS,
                latencyMilliseconds: Double(completedAtNS - startedAtNS) / 1_000_000,
                usage: result.usage
            )
        )
    }

    private func remember(threadID: String, for interactionID: String) {
        interactionOrder.removeAll { $0 == interactionID }
        interactionOrder.append(interactionID)
        threadByInteraction[interactionID] = threadID
        while interactionOrder.count > 64 {
            threadByInteraction.removeValue(forKey: interactionOrder.removeFirst())
        }
    }

    private func writeFailure(
        error: Error,
        interactionID: String? = nil,
        turnID: String? = nil
    ) {
        write(
            FailureEvent(
                interactionID: interactionID,
                turnID: turnID,
                monotonicNS: DispatchTime.now().uptimeNanoseconds,
                error: String(error.localizedDescription.prefix(512))
            )
        )
    }

    private func write<T: Encodable>(_ value: T) {
        guard let data = try? encoder.encode(value) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}

private func usage() {
    print("Usage: soma-codex-bridge [--codex /path/to/codex] [--working-directory /private/directory] [--timeout 5...120]")
    print("Reads CodexAccountTurnRequest JSONL from stdin and writes scalar response JSONL to stdout.")
}

do {
    let options = try Options.parse(CommandLine.arguments)
    try CodexAccountBridge(options: options).run()
} catch {
    FileHandle.standardError.write(Data("soma-codex-bridge: \(error.localizedDescription)\n".utf8))
    exit(2)
}
