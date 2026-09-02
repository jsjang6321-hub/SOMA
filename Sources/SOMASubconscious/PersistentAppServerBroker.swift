import Foundation
import SOMACore

private final class PersistentAppServerReadiness: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set(_ value: Bool) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Keeps SOMA's dedicated App Server alive without creating a thread, a
/// realtime transport, or a model turn. Live Voice opens a loopback WebSocket
/// only after L0 admits a conversation.
final class PersistentAppServerBroker: @unchecked Sendable {
    enum BrokerError: LocalizedError {
        case codexNotFound
        case endpointUnavailable
        case launchFailed(String)

        var errorDescription: String? {
            switch self {
            case .codexNotFound: "codex_app_server_not_found"
            case .endpointUnavailable: "persistent_app_server_endpoint_unavailable"
            case let .launchFailed(reason): "persistent_app_server_launch_failed_\(reason)"
            }
        }
    }

    typealias HealthHandler = @Sendable (_ state: String, _ message: String) -> Void

    let capability: String

    private let lock = NSLock()
    private let onHealth: HealthHandler
    private var process: ParentBoundProcess?
    private var endpoint: URL?

    init(capability: String, onHealth: @escaping HealthHandler) throws {
        guard capability.count == 36,
              capability.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || $0 == "-"
              }) else {
            throw BrokerError.launchFailed("invalid_capability")
        }
        self.capability = capability.lowercased()
        self.onHealth = onHealth
    }

    deinit { stop() }

    func ensureReady(timeout: TimeInterval = 5) -> Result<URL, Error> {
        lock.lock()
        defer { lock.unlock() }
        if let endpoint, let process, process.isRunning, Self.isReady(endpoint) {
            return .success(endpoint)
        }
        process?.stop()
        process = nil
        endpoint = nil
        guard let installation = SOMACodexLocator.locate() else {
            return .failure(BrokerError.codexNotFound)
        }
        let executable = installation.executableURL

        guard let guardianURL = ParentBoundProcess.installedGuardianURL() else {
            return .failure(BrokerError.launchFailed("child_guardian_unavailable"))
        }
        guard let mcpConfig = Self.embodimentMCPConfig(capability: capability) else {
            return .failure(BrokerError.launchFailed("embodiment_mcp_unavailable"))
        }

        let basePort = Int.random(in: 38_000...48_000)
        for offset in 0..<8 {
            let port = basePort + offset
            guard let endpoint = URL(string: "ws://127.0.0.1:\(port)") else { continue }
            let arguments = [
                "app-server",
                "--listen", endpoint.absoluteString,
                "--enable", "realtime_conversation",
                "--config", mcpConfig,
            ]
            let guardianProcess: ParentBoundProcess
            do {
                guardianProcess = try ParentBoundProcess(
                    guardianURL: guardianURL,
                    executableURL: executable,
                    arguments: arguments
                )
                try guardianProcess.run()
            } catch {
                continue
            }
            let deadline = Date().addingTimeInterval(max(0.1, timeout / 8))
            while Date() < deadline {
                if Self.isReady(endpoint) {
                    self.process = guardianProcess
                    self.endpoint = endpoint
                    onHealth(
                        "ready",
                        "transport=dedicated_persistent_app_server; realtime_active=false; model_turn_active=false; codex_source=\(installation.source.rawValue); codex_path=\(executable.path)"
                    )
                    return .success(endpoint)
                }
                if !guardianProcess.isRunning { break }
                Thread.sleep(forTimeInterval: 0.025)
            }
            guardianProcess.stop()
        }
        return .failure(BrokerError.endpointUnavailable)
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        process?.stop()
        process = nil
        endpoint = nil
    }

    private static func isReady(_ endpoint: URL) -> Bool {
        guard let readinessURL = URL(string: "/readyz", relativeTo: endpoint) else { return false }
        let semaphore = DispatchSemaphore(value: 0)
        let readiness = PersistentAppServerReadiness()
        URLSession.shared.dataTask(with: readinessURL) { _, response, _ in
            readiness.set((response as? HTTPURLResponse)?.statusCode == 200)
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 0.15)
        return readiness.get()
    }

    private static func embodimentMCPConfig(capability: String) -> String? {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let appRoot = environment["SOMA_APP_ROOT"]
            ?? "\(home)/Library/Application Support/SOMA/Applications/SOMA Subconscious.app"
        let runtimeRoot = environment["SOMA_RUNTIME_ROOT"]
            ?? "\(environment["SOMA_ROOT"] ?? FileManager.default.currentDirectoryPath)/artifacts/subconscious/runtime"
        let executable = "\(appRoot)/Contents/Helpers/soma-embodiment"
        let socket = "\(runtimeRoot)/ipc/embodiment-shadow.sock"
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        func quoted(_ value: String) -> String {
            "\"" + value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return "mcp_servers.soma_embodiment={command=\(quoted(executable)),args=[\(quoted("--socket")),\(quoted(socket))],env={SOMA_SESSION_TOKEN=\(quoted(capability))}}"
    }
}
