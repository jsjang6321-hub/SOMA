import AppKit
import Darwin
import Foundation
import LocalAuthentication
import SOMACore
import SwiftUI

/// Deep dark blue accent color used across the Control Center UI.
enum SOMAAccent {
    static let color = Color(red: 0.13, green: 0.27, blue: 0.56)
    static let nsColor = NSColor(red: 0.13, green: 0.27, blue: 0.56, alpha: 1)
}

private enum SOMAPaths {
    static let runtimeRoot = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SOMA_RUNTIME_ROOT"]
        ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("artifacts/subconscious/runtime", isDirectory: true).path,
        isDirectory: true)
    static let serviceLabel = "com.soma.reactive-l0"
    static let servicePlist = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/com.soma.reactive-l0.plist")
    static let menuBarPlist = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/com.soma.menu-bar.plist")
    static let menuBarInstanceLock = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/SOMA/menu-bar.lock")

    static var serviceTarget: String {
        "gui/\(getuid())/\(serviceLabel)"
    }

    static var subconsciousExecutable: URL {
        URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .appendingPathComponent("soma-subconscious")
    }
}

private final class SOMAMenuBarInstanceLease {
    static let openSettingsNotification = Notification.Name("com.soma.menu-bar.open-settings")

    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquire() -> SOMAMenuBarInstanceLease? {
        let fileManager = FileManager.default
        let directoryURL = SOMAPaths.menuBarInstanceLock.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directoryURL.path
            )
        } catch {
            return nil
        }

        let descriptor = Darwin.open(
            SOMAPaths.menuBarInstanceLock.path,
            O_CREAT | O_RDWR | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        _ = fchmod(descriptor, S_IRUSR | S_IWUSR)
        return SOMAMenuBarInstanceLease(descriptor: descriptor)
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}

private struct IdentityObservation: Equatable {
    let subject: String
    let state: String
    let confidence: Double
    let label: String?
}

private struct SOMARuntimeSnapshot: Equatable {
    let isLive: Bool
    let lastActivity: Date?
    let indicatorState: String?
    let sources: [String: String]
    let identity: IdentityObservation?
    let administratorVerified: Bool

    static let empty = SOMARuntimeSnapshot(
        isLive: false,
        lastActivity: nil,
        indicatorState: nil,
        sources: [:],
        identity: nil,
        administratorVerified: false
    )

    static func read(settings: SOMAControlSettings) -> SOMARuntimeSnapshot {
        guard let traceURL = latestTraceURL() else { return .empty }
        let modifiedAt = (try? traceURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let isLive = modifiedAt.map { Date().timeIntervalSince($0) < 8 } ?? false
        let events = tailLines(from: traceURL, maximumBytes: 196_608)
        let healthURL = SOMAPaths.runtimeRoot.appendingPathComponent("runtime-health.json")
        let durableHealth = try? RuntimeHealthSnapshot.load(from: healthURL)
        var sources = durableHealth?.sources.mapValues(\.state) ?? [:]
        var indicatorState = sources["social_indicator"]
        var identity = isLive
            ? currentIdentityObservation(notBeforeEpochMS: durableHealth?.startedAtEpochMS)
            : nil
        var administratorVerified = identity.map {
            $0.state == "known_recognized"
                && $0.subject == settings.administrator?.entityID.uuidString.lowercased()
        } ?? false

        for line in events.reversed() {
            guard let data = line.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let eventName = event["event"] as? String else { continue }
            if eventName == "source.health",
               let source = event["source"] as? String,
               let state = event["state"] as? String,
               sources[source] == nil {
                sources[source] = state
            }
            if isLive, eventName == "identity.observation", identity == nil,
               let subject = event["subject"] as? String,
               let state = event["state"] as? String {
                identity = IdentityObservation(
                    subject: subject,
                    state: state,
                    confidence: event["confidence"] as? Double ?? 0,
                    label: event["label"] as? String
                )
                if state == "known_recognized",
                   subject == settings.administrator?.entityID.uuidString.lowercased() {
                    administratorVerified = true
                }
            }
            if isLive, eventName == "administrator.identity",
               ["verified", "verified_presence"].contains(event["state"] as? String ?? "") {
                administratorVerified = true
            }
            if event["source"] as? String == "social_indicator", indicatorState == nil {
                indicatorState = event["state"] as? String
            }
        }
        return SOMARuntimeSnapshot(
            isLive: isLive,
            lastActivity: modifiedAt,
            indicatorState: indicatorState,
            sources: sources,
            identity: identity,
            administratorVerified: administratorVerified
        )
    }

    func sourceIsOperational(_ source: String) -> Bool {
        guard isLive, let state = sources[source] else { return false }
        let inactiveStates: Set<String> = [
            "color_unsupported_for_profile", "disabled", "fault", "lifecycle_shutdown_failed",
            "palette_unverified_for_profile", "rejected", "runtime_error", "runtime_stalled",
            "stopped", "suppressed", "unavailable",
        ]
        return !inactiveStates.contains(state)
    }

    private static func currentIdentityObservation(notBeforeEpochMS: Int64?) -> IdentityObservation? {
        let url = SOMAPaths.runtimeRoot.appendingPathComponent("identity-current.json")
        if let notBeforeEpochMS {
            guard let modifiedAt = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  Int64(modifiedAt.timeIntervalSince1970 * 1_000) >= notBeforeEpochMS else { return nil }
        }
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subject = object["subject"] as? String,
              let state = object["state"] as? String else { return nil }
        return IdentityObservation(
            subject: subject,
            state: state,
            confidence: object["confidence"] as? Double ?? 0,
            label: object["label"] as? String
        )
    }

    private static func latestTraceURL() -> URL? {
        let detailURL = SOMAPaths.runtimeRoot.appendingPathComponent("detail", isDirectory: true)
        guard let candidates = try? FileManager.default.contentsOfDirectory(
            at: detailURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return candidates
            .filter { $0.pathExtension == "jsonl" }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .max {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return left < right
            }
    }

    private static func tailLines(from url: URL, maximumBytes: Int) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(maximumBytes) ? size - UInt64(maximumBytes) : 0
        try? handle.seek(toOffset: offset)
        guard let text = String(data: (try? handle.readToEnd()) ?? Data(), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }
}

private enum OllamaConnectionState: Equatable {
    case unchecked
    case checking
    case available(String)
    case unavailable(String)
}

private enum ExternalDependencyAuditState: Equatable {
    case unchecked
    case checking
    case loaded(ExternalDependencyAudit)
    case unavailable(String)
}

@MainActor
private final class SOMAControlModel: ObservableObject {
    @Published var settings: SOMAControlSettings
    @Published var envSettings: SOMAEnvSettings
    @Published private(set) var runtime = SOMARuntimeSnapshot.empty
    @Published private(set) var message: String?
    @Published private(set) var ollamaConnection: OllamaConnectionState = .unchecked
    @Published private(set) var externalDependencyAudit: ExternalDependencyAuditState = .unchecked
    @Published var discordTokenDraft = ""
    @Published private(set) var discordTokenConfigured = false
    @Published private(set) var discordConnectionMessage: String?
    private var ollamaValidationGeneration = UUID()
    // Administrator identity fields stay locked until the Mac login password
    // (or Touch ID) unlocks them, so changing or removing the owner is not a
    // silent, unauthenticated action.
    @Published var administratorProfileUnlocked = false
    @Published var administratorDraftName = ""
    @Published var administratorDraftAddress = ""

    private let store: SOMAControlSettingsStore
    private let envStore: SOMAEnvStore
    private let discordSecretStore = SOMADiscordSecretStore()
    init(store: SOMAControlSettingsStore = .init()) {
        self.store = store
        self.envStore = .init()
        do {
            settings = try store.load()
        } catch {
            settings = .init()
            message = error.localizedDescription
        }
        do {
            envSettings = try envStore.load()
        } catch {
            envSettings = .init()
            message = message ?? error.localizedDescription
        }
        administratorDraftName = settings.administrator?.displayName ?? ""
        administratorDraftAddress = settings.administrator?.preferredAddress ?? ""
        discordTokenConfigured = ((try? discordSecretStore.loadToken()) ?? nil) != nil
        refresh()
        _ = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    var latestAnonymousFace: String? {
        guard let identity = runtime.identity,
              identity.state == "anonymous_recognized" || identity.state == "unknown_candidate",
              identity.subject.hasPrefix("anon_") else { return nil }
        return identity.subject
    }

    func refresh() {
        runtime = SOMARuntimeSnapshot.read(settings: settings)
    }

    func clearMessage() {
        message = nil
    }

    func invalidateOllamaConnection() {
        ollamaValidationGeneration = UUID()
        ollamaConnection = .unchecked
    }

    func validateOllamaConnection() async {
        let generation = UUID()
        ollamaValidationGeneration = generation
        let host = envSettings.ollamaHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = envSettings.l1Model.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try envSettings.validate()
        } catch {
            ollamaConnection = .unavailable(error.localizedDescription)
            return
        }
        guard let baseURL = URL(string: host) else {
            ollamaConnection = .unavailable("Invalid Ollama host")
            return
        }
        ollamaConnection = .checking
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 4
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard isCurrentOllamaQuery(host: host, model: model, generation: generation) else { return }
            guard let http = response as? HTTPURLResponse,
                  (200 ... 299).contains(http.statusCode) else {
                ollamaConnection = .unavailable("Ollama did not accept the connection")
                return
            }
            struct TagsResponse: Decodable {
                struct Model: Decodable {
                    let name: String?
                    let model: String?
                }
                let models: [Model]
            }
            let tags = try JSONDecoder().decode(TagsResponse.self, from: data)
            guard isCurrentOllamaQuery(host: host, model: model, generation: generation) else { return }
            let available = Set(tags.models.flatMap { [$0.name, $0.model].compactMap { $0 } })
            ollamaConnection = available.contains(model)
                ? .available("Connected · model available")
                : .unavailable("Connected, but this model is not available")
        } catch {
            guard isCurrentOllamaQuery(host: host, model: model, generation: generation) else { return }
            ollamaConnection = .unavailable("Could not reach Ollama")
        }
    }

    func checkExternalDependencies() {
        guard externalDependencyAudit != .checking else { return }
        guard let root = ProcessInfo.processInfo.environment["SOMA_ROOT"], root.hasPrefix("/") else {
            externalDependencyAudit = .unavailable("SOMA source root is unavailable")
            return
        }
        let doctor = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("scripts/soma-doctor.zsh")
        guard FileManager.default.isExecutableFile(atPath: doctor.path) else {
            externalDependencyAudit = .unavailable("Dependency checker is unavailable")
            return
        }
        externalDependencyAudit = .checking
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Self.runProcessBlocking(at: doctor, arguments: ["--runtime"])
            }.value
            guard let self else { return }
            let audit = ExternalDependencyAudit.parse(
                output: result.output,
                exitStatus: result.status
            )
            externalDependencyAudit = audit.checks.isEmpty
                ? .unavailable(result.output.isEmpty ? "Dependency check returned no result" : result.output)
                : .loaded(audit)
        }
    }

    private func isCurrentOllamaQuery(host: String, model: String, generation: UUID) -> Bool {
        ollamaValidationGeneration == generation
            && envSettings.ollamaHost.trimmingCharacters(in: .whitespacesAndNewlines) == host
            && envSettings.l1Model.trimmingCharacters(in: .whitespacesAndNewlines) == model
    }

    /// Prompts for the Mac login password / Touch ID (system dialog) and
    /// returns true only on success. Fully asynchronous so the main thread is
    /// never blocked while the system dialog is up.
    @discardableResult
    func authenticateMacLogin(reason: String) async -> Bool {
        let context = LAContext()
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            message = "Mac login authentication unavailable: \(policyError?.localizedDescription ?? "unknown")"
            return false
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    var isSOMARunning: Bool {
        isSOMALoaded()
    }

    func save() {
        do {
            let normalizedEnvSettings = envSettings.canonicalizedForPersistence()
            try normalizedEnvSettings.validate()
            settings.hermesAgentWorkspace = SOMAControlSettings.normalizedAbsolutePath(
                settings.hermesAgentWorkspace
            )
            try store.save(settings)
            try envStore.save(normalizedEnvSettings)
            let pendingDiscordToken = discordTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            if !pendingDiscordToken.isEmpty {
                try discordSecretStore.saveToken(pendingDiscordToken)
                discordTokenConfigured = true
                discordTokenDraft = ""
            }
            envSettings = normalizedEnvSettings
            message = "Saved locally. Restart SOMA to apply runtime changes."
            refresh()
        } catch {
            message = error.localizedDescription
        }
    }

    func validateDiscordConnection() async {
        guard settings.discord.isConfigured else {
            discordConnectionMessage = "Enter a valid channel and Labmanager invocation IDs."
            return
        }
        do {
            let token = try discordSecretStore.loadToken()
            guard let token else {
                discordConnectionMessage = "Save a Discord bot token first."
                return
            }
            discordConnectionMessage = "Checking Discord…"
            let client = SOMADiscordConversationClient(settings: settings.discord, token: token)
            let username = try await client.validateConnection()
            discordConnectionMessage = "Connected as \(username)."
        } catch {
            discordConnectionMessage = error.localizedDescription
        }
    }

    func removeDiscordToken() async {
        guard await authenticateMacLogin(reason: "Remove SOMA's Discord bot token") else { return }
        do {
            try discordSecretStore.deleteToken()
            discordTokenDraft = ""
            discordTokenConfigured = false
            discordConnectionMessage = "Discord bot token removed."
        } catch {
            message = error.localizedDescription
        }
    }

    @discardableResult
    func saveAndRestart() -> Bool {
        save()
        guard message?.hasPrefix("Saved locally") == true else { return false }
        let result = startSOMA(restart: true)
        message = result.status == 0
            ? "Saved and SOMA is restarting."
            : (result.output.isEmpty ? "Could not restart SOMA." : result.output)
        return result.status == 0
    }

    func startSOMA(restart: Bool = false) -> (status: Int32, output: String) {
        if !isSOMALoaded() {
            guard FileManager.default.fileExists(atPath: SOMAPaths.servicePlist.path) else {
                return (1, "SOMA service definition is unavailable.")
            }
            return runLaunchctl([
                "bootstrap",
                "gui/\(getuid())",
                SOMAPaths.servicePlist.path,
            ])
        }
        guard restart else {
            return (0, "SOMA is already running.")
        }
        return runLaunchctl(["kickstart", "-k", SOMAPaths.serviceTarget])
    }

    func stopSOMA() -> (status: Int32, output: String) {
        guard isSOMALoaded() else {
            runtime = .empty
            return (0, "SOMA is already stopped.")
        }
        let result = runLaunchctl([
            "bootout",
            "gui/\(getuid())",
            SOMAPaths.servicePlist.path,
        ])
        if result.status == 0 {
            runtime = .empty
        }
        return result
    }

    private func isSOMALoaded() -> Bool {
        let result = runLaunchctl(["print", SOMAPaths.serviceTarget])
        return result.status == 0 && result.output.contains("\(SOMAPaths.serviceTarget) = {")
    }

    func enrollLatestFace() async {
        let enrollmentName = (
            settings.administrator?.displayName ?? administratorDraftName
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !enrollmentName.isEmpty else {
            message = "Enter the administrator display name before enrolling the face."
            return
        }
        let enrollmentAddress = (
            settings.administrator?.preferredAddress ?? administratorDraftAddress
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let handle = latestAnonymousFace else {
            message = "Stand in view until SOMA shows a recognized local face."
            return
        }
        // Enrolling a new face replaces the administrator mapping, so it is
        // also gated behind the Mac login password when a profile exists.
        if settings.administrator != nil {
            guard await authenticateMacLogin(
                reason: "Replacing the SOMA administrator enrollment requires your Mac login password."
            ) else { return }
        }
        let confirmation = NSAlert()
        confirmation.messageText = "Enroll administrator face?"
        confirmation.informativeText = "SOMA will capture several different views of your face so it recognizes you reliably. Stay facing the camera."
        confirmation.addButton(withTitle: "Start")
        confirmation.addButton(withTitle: "Cancel")
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }

        // Guided multi-pose capture: while this progress panel is up the running
        // SOMA process is already watching the camera and accumulating distinct
        // face samples into the anonymous cluster, so we let the person turn
        // their head for a few seconds, then promote the enriched cluster.
        GuidedEnrollmentPanel.present(
            handle: handle,
            guide: "Move your head slowly — turn left, right, up, and down — until progress finishes.",
            sampleWindowSeconds: 6
        ) { [weak self] in
            guard let self else { return (false, "SOMA is unavailable.") }
            let result = self.runSubconscious(["--promote-anonymous-face", handle])
            guard result.status == 0,
                  let entityID = parseValue("entity_id", from: result.output).flatMap(UUID.init(uuidString:)) else {
                return (false, result.output.isEmpty ? "Could not enroll this face." : result.output)
            }
            let references = Int(parseValue("references", from: result.output) ?? "?") ?? 0
            settings.administrator = SOMAAdministratorIdentity(
                entityID: entityID,
                displayName: enrollmentName,
                preferredAddress: enrollmentAddress.isEmpty ? nil : enrollmentAddress
            )
            do {
                try store.save(settings)
                let restart = startSOMA(restart: true)
                refresh()
                if restart.status == 0 {
                    message = "Administrator enrolled and SOMA is restarting."
                    return (true, "Enrolled with \(references) samples. SOMA is loading the profile.")
                }
                let detail = restart.output.isEmpty ? "service restart failed" : restart.output
                message = "Administrator enrolled, but SOMA could not restart: \(detail)"
                return (true, "Enrolled with \(references) samples. Restart SOMA manually to load it.")
            } catch {
                return (false, error.localizedDescription)
            }
        }
    }

    func removeAdministrator() {
        guard let administrator = settings.administrator else { return }
        Task {
            guard await authenticateMacLogin(
                reason: "Removing the SOMA administrator enrollment requires your Mac login password."
            ) else { return }
            self.finishRemoveAdministrator(administrator)
        }
    }

    @MainActor
    private func finishRemoveAdministrator(_ administrator: SOMAAdministratorIdentity) {
        let confirmation = NSAlert()
        confirmation.messageText = "Remove administrator enrollment?"
        confirmation.informativeText = "This permanently removes the encrypted local face template and its administrator mapping from this Mac."
        confirmation.alertStyle = .warning
        confirmation.addButton(withTitle: "Remove")
        confirmation.addButton(withTitle: "Cancel")
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }

        let result = runSubconscious(["--remove-face-identity", administrator.entityID.uuidString.lowercased()])
        guard result.status == 0 else {
            message = result.output.isEmpty ? "Could not remove the administrator profile." : result.output
            return
        }
        settings.administrator = nil
        administratorDraftName = administrator.displayName
        administratorDraftAddress = administrator.preferredAddress ?? ""
        do {
            try store.save(settings)
            message = "Administrator enrollment removed. Restart SOMA to clear the active profile."
        } catch {
            message = error.localizedDescription
        }
    }

    func revealRuntime() {
        NSWorkspace.shared.open(SOMAPaths.runtimeRoot)
    }

    func stopControlCenter() {
        _ = runLaunchctl([
            "bootout",
            "gui/\(getuid())",
            SOMAPaths.menuBarPlist.path,
        ])
    }

    private func runSubconscious(_ arguments: [String]) -> (status: Int32, output: String) {
        runProcess(at: SOMAPaths.subconsciousExecutable, arguments: arguments)
    }

    private func runLaunchctl(_ arguments: [String]) -> (status: Int32, output: String) {
        runProcess(at: URL(fileURLWithPath: "/bin/launchctl"), arguments: arguments)
    }

    private func runProcess(at executable: URL, arguments: [String]) -> (status: Int32, output: String) {
        Self.runProcessBlocking(at: executable, arguments: arguments)
    }

    nonisolated private static func runProcessBlocking(
        at executable: URL,
        arguments: [String]
    ) -> (status: Int32, output: String) {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            return (1, "Required SOMA executable is unavailable: \(executable.lastPathComponent)")
        }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (1, error.localizedDescription)
        }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        return (process.terminationStatus, output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func parseValue(_ name: String, from output: String) -> String? {
        output.split(separator: "\n").first { $0.hasPrefix("\(name)=") }.map {
            String($0.dropFirst(name.count + 1))
        }
    }
}

private enum SOMASettingsSection: String, CaseIterable, Identifiable {
    case experience = "Experience"
    case layers = "Layers"
    case administrator = "Administrator"
    case system = "System"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .experience: "waveform"
        case .layers: "square.stack.3d.up"
        case .administrator: "person.crop.circle.badge.checkmark"
        case .system: "heart.text.square"
        }
    }
}

private enum SOMABrand {
    private static let resourceBundle: Bundle = {
        let bundleName = "SOMA_SOMAMenuBar.bundle"
        let installedURL = Bundle.main.resourceURL?.appendingPathComponent(bundleName, isDirectory: true)
        let adjacentURL = Bundle.main.bundleURL.appendingPathComponent(bundleName, isDirectory: true)
        for candidate in [installedURL, adjacentURL].compactMap({ $0 }) {
            if let bundle = Bundle(url: candidate) {
                return bundle
            }
        }
        return Bundle.module
    }()

    private static let sourceMark: NSImage = {
        guard let url = resourceBundle.url(forResource: "SOMALogoMark", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            fatalError("SOMA brand mark is missing from the menu-bar resource bundle")
        }
        image.isTemplate = true
        return image
    }()

    static func mark(size: CGFloat) -> NSImage {
        guard let image = sourceMark.copy() as? NSImage else {
            fatalError("SOMA brand mark could not be copied")
        }
        image.size = NSSize(width: size, height: size)
        image.isTemplate = true
        return image
    }

    static func menuBarMark() -> NSImage {
        mark(size: 20)
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.46), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct StateDot: View {
    let active: Bool
    let color: Color

    var body: some View {
        Circle()
            .fill(active ? color : Color.secondary.opacity(0.32))
            .frame(width: 8, height: 8)
            .shadow(color: active ? color.opacity(0.45) : .clear, radius: 3)
    }
}

private enum SOMASettingsSidebarLayout {
    static let headerHorizontalInset: CGFloat = 14
    static let headerTopInset: CGFloat = 16
    static let navigationHorizontalInset: CGFloat = 8
    static let rowHorizontalInset: CGFloat = 12
    static let navigationSpacing: CGFloat = 6
    static let statusVerticalInset: CGFloat = 2
}

private struct SOMASettingsView: View {
    @ObservedObject var model: SOMAControlModel
    var onSuccessfulRestart: () -> Void = {}
    var onOpenDiagnostics: () -> Void = {}
    @State private var selection: SOMASettingsSection = .experience
    @State private var revealAPIKey = false
    @State private var revealOllamaAdvancedSettings = false
    @State private var revealDependencyChecks = false

    private var selectedSection: SOMASettingsSection { selection }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 20) {
                    heading
                    Spacer(minLength: 20)
                    HStack(spacing: 10) {
                        Button("Save") { model.save() }
                        Button("Save & restart SOMA") {
                            if model.saveAndRestart() {
                                onSuccessfulRestart()
                            }
                        }
                            .buttonStyle(.borderedProminent)
                    }
                    .controlSize(.large)
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 16)

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        sectionContent
                        if let message = model.message {
                            Label(message, systemImage: "info.circle.fill")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 2)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(minWidth: 770, idealWidth: 820, minHeight: 580, idealHeight: 620)
        .tint(SOMAAccent.color)
        .onChange(of: selection) { _ in model.clearMessage() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: SOMABrand.mark(size: 34))
                    .resizable()
                    .renderingMode(.template)
                    .foregroundStyle(.primary)
                    .frame(width: 34, height: 34)
                Text("SOMA").font(.headline)
            }
            .padding(.horizontal, SOMASettingsSidebarLayout.headerHorizontalInset)
            .padding(.top, SOMASettingsSidebarLayout.headerTopInset)

            VStack(spacing: SOMASettingsSidebarLayout.navigationSpacing) {
                HStack(spacing: 8) {
                    StateDot(active: model.runtime.isLive, color: .green)
                    Text(model.runtime.isLive ? "Running locally" : "Waiting for runtime")
                    Spacer(minLength: 0)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(model.runtime.isLive ? .primary : .secondary)
                .padding(.horizontal, SOMASettingsSidebarLayout.rowHorizontalInset)
                .padding(.vertical, SOMASettingsSidebarLayout.statusVerticalInset)
                .frame(maxWidth: .infinity, alignment: .leading)

                ForEach(SOMASettingsSection.allCases) { item in
                    Button {
                        selection = item
                    } label: {
                        Label(item.rawValue, systemImage: item.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, SOMASettingsSidebarLayout.rowHorizontalInset)
                            .padding(.vertical, 8)
                            .background(
                                selection == item ? Color.primary.opacity(0.12) : .clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.rawValue)
                }

                Divider().padding(.vertical, 4)

                Button {
                    onOpenDiagnostics()
                } label: {
                    Label("Diagnostic", systemImage: "waveform.path.ecg")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, SOMASettingsSidebarLayout.rowHorizontalInset)
                        .padding(.vertical, 8)
                        .background(
                            SOMAAccent.color.opacity(0.15),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open diagnostic panel")
            }
            .padding(.horizontal, SOMASettingsSidebarLayout.navigationHorizontalInset)
            Spacer(minLength: 0)
        }
        .frame(width: 190)
    }

    private var heading: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(nsImage: SOMABrand.mark(size: 54))
                .resizable()
                .renderingMode(.template)
                .foregroundStyle(.primary)
                .frame(width: 54, height: 54)
            VStack(alignment: .leading, spacing: 4) {
                Text(selectedSection.rawValue).font(.system(size: 23, weight: .bold))
                Text(model.runtime.isLive ? "Live settings for your local companion." : "Settings are ready; SOMA will apply them after launch.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var sectionContent: some View {
        switch selectedSection {
        case .experience: experience
        case .layers: layers
        case .administrator: administrator
        case .system: system
        }
    }

    private var experience: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard(title: "Realtime voice", subtitle: "The voice used for account-backed spoken responses.") {
                Toggle("Enable spoken realtime conversations", isOn: binding(\.realtimeVoiceEnabled))
                Picker("Voice", selection: binding(\.realtimeVoice)) {
                    ForEach(SOMARealtimeVoicePresentation.allCases, id: \.self) { presentation in
                        Section(presentation.displayName) {
                            ForEach(SOMARealtimeVoice.voices(with: presentation), id: \.self) { voice in
                                Text(voice.displayName).tag(voice)
                            }
                        }
                    }
                }
                .disabled(!model.settings.realtimeVoiceEnabled)
                Text("Only voices accepted by the installed Codex realtime transport are shown; groups are curated by listening.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(
                    "Require eye contact for every spoken turn",
                    isOn: binding(\.realtimeVoiceRequiresEyeContactForEveryTurn)
                )
                .disabled(!model.settings.realtimeVoiceEnabled)
                Text("When enabled, an open conversation forwards a spoken turn only when current eye contact and audiovisual evidence identify the tracked person as the speaker.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(
                    "Only the enrolled administrator may start voice conversations",
                    isOn: binding(\.administratorOnlyConversations)
                )
                .disabled(!model.settings.realtimeVoiceEnabled)
                Text("Unknown people and registered participants remain available to local perception, but their speech cannot open L2 or reach connected services.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("End after user silence")
                    Spacer()
                    Stepper(
                        "\(model.settings.realtimeVoiceSilenceTimeoutSeconds) s",
                        value: realtimeVoiceSilenceTimeoutBinding,
                        in: SOMAControlSettings.realtimeVoiceSilenceTimeoutRange,
                        step: 15
                    )
                }
                .disabled(!model.settings.realtimeVoiceEnabled)
                Text("Only confirmed participant activity renews this timer; SOMA speaking does not. Save & Restart applies the new duration.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            SettingsCard(
                title: "Hermes agent delegation",
                subtitle: "Run administrator-delegated work asynchronously and return the result to L2."
            ) {
                Toggle(
                    "Enable delegated agent work",
                    isOn: binding(\.hermesAgentDelegationEnabled)
                )
                .disabled(!model.settings.realtimeVoiceEnabled)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("Default workspace")
                            .foregroundStyle(.secondary)
                        TextField("SOMA project root", text: hermesAgentWorkspaceBinding)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .disabled(
                    !model.settings.realtimeVoiceEnabled
                        || !model.settings.hermesAgentDelegationEnabled
                )
                Text("L2 submits an explicit job and receives a task ID immediately. The owner-only runtime keeps the job alive after voice closes, stores its result encrypted, and makes that result available for reporting in the current or next conversation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Jobs run through Hermes' primary computer-supervisor profile and remain attached to the selected workspace instead of falling into Home.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            SettingsCard(
                title: "Discord · @Labmanager",
                subtitle: "Forward verified administrator speech to one allowlisted Discord channel and read the existing bot's reply aloud."
            ) {
                Toggle("Enable Discord conversation bridge", isOn: discordEnabledBinding)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("Channel ID").foregroundStyle(.secondary)
                        TextField("Discord channel or thread ID", text: discordChannelIDBinding)
                            .textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("Labmanager bot ID").foregroundStyle(.secondary)
                        TextField("Bot user ID", text: discordLabmanagerIDBinding)
                            .textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("Managed role ID").foregroundStyle(.secondary)
                        TextField("Role mentioned for invocation", text: discordLabmanagerRoleIDBinding)
                            .textFieldStyle(.roundedBorder)
                            .disabled(model.settings.discord.invocationMention != .managedRole)
                    }
                    GridRow {
                        Text("Invoke with").foregroundStyle(.secondary)
                        Picker("", selection: discordInvocationMentionBinding) {
                            Text("Bot user mention").tag(SOMADiscordInvocationMention.botUser)
                            Text("Managed role mention").tag(SOMADiscordInvocationMention.managedRole)
                        }
                        .labelsHidden()
                    }
                    GridRow {
                        Text("Bot token").foregroundStyle(.secondary)
                        SecureField(
                            model.discordTokenConfigured ? "Saved in SOMA encrypted store" : "Discord bot token",
                            text: $model.discordTokenDraft
                        )
                        .textFieldStyle(.roundedBorder)
                    }
                }
                .disabled(!model.settings.discord.enabled)
                Toggle("Forward finalized administrator speech immediately", isOn: discordForwardSpeechBinding)
                    .disabled(!model.settings.discord.enabled)
                Toggle("Read @Labmanager replies aloud through Live Voice", isOn: discordReadRepliesBinding)
                    .disabled(!model.settings.discord.enabled)
                HStack {
                    Button("Check connection") {
                        Task { await model.validateDiscordConnection() }
                    }
                    .disabled(!model.settings.discord.isConfigured || !model.discordTokenConfigured)
                    if model.discordTokenConfigured {
                        Button("Remove token", role: .destructive) {
                            Task { await model.removeDiscordToken() }
                        }
                    }
                    if let status = model.discordConnectionMessage {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("The existing Labmanager contract uses Bot user mention. Managed role mention is available for other deployments. Replies must come from the configured bot in this channel and echo the request's voice-corr marker. The token is sealed in SOMA's owner-only local credential store and never enters settings.json or Git.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            SettingsCard(title: "LED response", subtitle: "Set global visibility and brightness for the hardware indicator.") {
                Picker("Reaction", selection: ledModeBinding) {
                    ForEach(SOMALEDResponseMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                HStack {
                    Text("Brightness")
                    Slider(value: ledBrightnessBinding, in: 0...3, step: 1)
                    Text("\(model.settings.led.brightness)")
                        .monospacedDigit().foregroundStyle(.secondary).frame(width: 14)
                }
                .disabled(model.settings.led.responseMode == .off)
            }
            SettingsCard(title: "LED signals", subtitle: "Choose a color and timing pattern for each attention state. Voice adds a blink only when the selected state is steady.") {
                LazyVStack(spacing: 8) {
                    ForEach(SubconsciousIndicatorState.configurationStates, id: \.self) { state in
                        LEDSignalRow(state: state, signal: ledSignalBinding(for: state))
                    }
                }
            }
        }
    }

    private var layers: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard(title: "L1 model runtime", subtitle: "SOMA automatically uses the configured local Ollama service.") {
                HStack(spacing: 8) {
                    ollamaConnectionStatus
                    Spacer()
                    Button("Check connection") {
                        Task { await model.validateOllamaConnection() }
                    }
                    .disabled(model.ollamaConnection == .checking)
                }
                HStack {
                    Text("Model").foregroundStyle(.secondary)
                    Spacer()
                    Text(model.envSettings.l1Model)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                DisclosureGroup(
                    "Advanced connection settings",
                    isExpanded: $revealOllamaAdvancedSettings
                ) {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                        GridRow {
                            Text("Host").foregroundStyle(.secondary)
                            TextField(SOMAEnvSettings.defaultOllamaHost, text: ollamaHostBinding)
                                .textFieldStyle(.roundedBorder)
                        }
                        GridRow {
                            Text("Model override").foregroundStyle(.secondary)
                            TextField(SOMAEnvSettings.defaultL1Model, text: l1ModelBinding)
                                .textFieldStyle(.roundedBorder)
                        }
                        GridRow {
                            Text("Web search key").foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                Group {
                                    if revealAPIKey {
                                        TextField("Optional", text: ollamaAPIKeyBinding)
                                    } else {
                                        SecureField("Optional", text: ollamaAPIKeyBinding)
                                    }
                                }
                                .textFieldStyle(.roundedBorder)
                                Button(action: { revealAPIKey.toggle() }) {
                                    Image(systemName: revealAPIKey ? "eye.slash.fill" : "eye.fill")
                                }
                                .buttonStyle(.plain)
                                .help(revealAPIKey ? "Hide API key" : "Show API key")
                            }
                        }
                    }
                    .padding(.top, 8)
                    Text("Use these only for a remote Ollama server, a non-default model, or hosted web search.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
            .task(id: "\(model.envSettings.ollamaHost)|\(model.envSettings.l1Model)") {
                try? await Task.sleep(nanoseconds: 450_000_000)
                guard !Task.isCancelled else { return }
                await model.validateOllamaConnection()
            }
            SettingsCard(title: "L0 — Perception & attention", subtitle: "What autonomous motion the attention controller may perform. These govern the gimbal and coverage scan.") {
                Toggle("Track a verified human face", isOn: l0TrackingBinding)
                Toggle("Explore when no verified target is present", isOn: l0ExploreBinding)
                Divider()
                HStack {
                    Text("Release fixation after no response")
                    Spacer()
                    Stepper(
                        model.envSettings.l0FaceFixationReleaseSeconds <= 0
                            ? "Keep gazing (no time limit)"
                            : "\(Int(model.envSettings.l0FaceFixationReleaseSeconds)) s",
                        value: l0FaceFixationReleaseBinding,
                        in: 0...120,
                        step: 15
                    )
                }
                HStack {
                    Toggle("Local semantic evidence (E2B)", isOn: l05EnabledBinding)
                        .toggleStyle(.switch)
                }
                HStack {
                    Text("Evidence proposal score")
                    Spacer()
                    Stepper("Score ≥ \(String(format: "%.2f", model.envSettings.l0E2BWakeScore))", value: l0E2BWakeScoreBinding, in: 0.1...0.95, step: 0.05)
                }
                HStack {
                    Text("Evidence confidence")
                    Spacer()
                    Stepper("Confidence ≥ \(String(format: "%.2f", model.envSettings.l0E2BWakeConfidence))", value: l0E2BWakeConfidenceBinding, in: 0.1...0.95, step: 0.05)
                }
                HStack {
                    Text("Stable-scene refresh")
                    Spacer()
                    Stepper("Every \(Int(model.envSettings.l0E2BWakeIntervalMilliseconds / 1000)) s", value: l0E2BWakeIntervalBinding, in: 2...60, step: 1)
                }
                Text("E2B contributes semantic evidence to the workspace. It does not speak, move the gimbal, or wake L1 by itself.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                HStack {
                    Text("Contact evidence lifetime")
                    Spacer()
                    Stepper("\(Int(model.envSettings.l0EyeContactFreshnessMilliseconds)) ms", value: l0EyeContactFreshnessBinding, in: 100...2000, step: 50)
                }
                HStack {
                    Text("Pupil-centering threshold")
                    Spacer()
                    Stepper(
                        "\(String(format: "%.2f", model.envSettings.l0EyeContactPupilThreshold))×",
                        value: l0EyeContactPupilThresholdBinding,
                        in: 0.5...2.0,
                        step: 0.05
                    )
                }
                HStack {
                    Text("Camera height")
                    Spacer()
                    Picker("Camera height", selection: l0CameraVerticalPlacementBinding) {
                        ForEach(SOMACameraVerticalPlacement.allCases, id: \.self) { placement in
                            Text(placement.displayName).tag(placement)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 150)
                }
                HStack {
                    Text("Object detection confidence")
                    Spacer()
                    Stepper("≥ \(String(format: "%.2f", model.envSettings.l0YoloConfidenceThreshold))", value: l0YoloConfidenceBinding, in: 0.1...0.95, step: 0.05)
                }
                Text("Contact lifetime controls how long a verified gaze remains current; lower is stricter. Camera height shifts the expected vertical eye ray without making downward phone gaze valid. Lower pupil scaling requires more centered eyes. Object confidence filters weak scene labels.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SettingsCard(title: "L1 — Conscious stream", subtitle: "Adaptive reflection, memory horizon, and curiosity.") {
                HStack {
                    Text("Quiet-state reflection baseline")
                    Spacer()
                    Stepper("≈ \(Int(model.envSettings.l1ReasoningCadenceSeconds)) s", value: l1ReasoningCadenceBinding, in: 30...600, step: 15)
                }
                Text("This is the expected interval while the scene is quiet. Meaningful workspace changes request reflection immediately; unresolved thoughts shorten the interval stochastically.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("Default language")
                    Spacer()
                    Picker("", selection: l1DefaultLanguageBinding) {
                        ForEach(SOMADefaultLanguage.allCases, id: \.self) { lang in
                            Text(lang.label).tag(lang.tag)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 120)
                }
                Text("Used to address a person who has no stored preferred language.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                HStack {
                    Text("Short-term memory retention")
                    Spacer()
                    Stepper("\(Int(model.envSettings.memoryShortTermRetentionHours)) h", value: memoryRetentionBinding, in: 1...24, step: 1)
                }
                Text("How long raw conversation transcripts are kept before L1 consolidation.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Toggle("Web curiosity collection", isOn: l1CuriosityEnabledBinding)
                HStack {
                    Text("Collection interval")
                    Picker("", selection: l1CollectionIntervalBinding) {
                        ForEach(SOMAEnvCollectionInterval.allCases, id: \.self) { interval in
                            Text(interval.label).tag(interval.hours)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 110)
                }
                .disabled(!model.envSettings.l1CuriosityCollectionEnabled)
                Divider()
                HStack {
                    Text("Spoken opening tendency")
                    Spacer()
                    Text("\(Int(model.envSettings.l1SpokenOpeningTendency * 100))%")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: l1SpokenOpeningTendencyBinding, in: 0...1, step: 0.1)
                Text("How readily L1 starts a spoken conversation when you look busy. Low = stays quiet, high = more talkative.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Toggle("Open with unknown identities", isOn: l1OpenWithUnknownBinding)
                Text("When on, L1 may proactively open a spoken conversation with a person it has not yet recognized, treating them as a pseudonymous participant.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SettingsCard(title: "L2 — Conversation & interaction", subtitle: "Whether SOMA may start a spoken conversation on its own. The live-voice voice itself is set under Experience.") {
                Toggle("Allow proactive spoken openings", isOn: l2ProactiveOpeningsBinding)
                Text("When on, L1 can hand a purposeful opening to the live-voice conversation runtime instead of staying silent.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                HStack {
                    Text("Codex file access")
                    Spacer()
                    Picker("", selection: l2CodexSandboxBinding) {
                        ForEach(SOMACodexSandbox.allCases, id: \.self) { level in
                            Text(level.label).tag(level.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 150)
                }
                Toggle("Restrict to administrator", isOn: l2CodexAdminOnlyBinding)
                Text("The conversation agent's file access. When restricted, only the administrator gets this level; everyone else is read-only.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var administrator: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard(title: "Administrator identity", subtitle: "Face embeddings are encrypted locally. Names and preferred address stay in this owner-only settings file.") {
                if model.settings.administrator == nil {
                    Label("No administrator face enrolled", systemImage: "person.crop.circle.badge.exclamationmark")
                        .foregroundStyle(.secondary)
                    TextField("Display name", text: $model.administratorDraftName)
                    TextField("Preferred address", text: $model.administratorDraftAddress)
                    Button("Enroll face currently in view") { Task { await model.enrollLatestFace() } }
                        .disabled(
                            model.latestAnonymousFace == nil
                                || model.administratorDraftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                    if model.latestAnonymousFace == nil {
                        Text("Keep your face visible until Identity changes from waiting to a recognized local face.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Toggle("Administrator profile enabled", isOn: Binding(
                        get: { model.settings.administrator != nil },
                        set: { enabled in if !enabled { model.removeAdministrator() } }
                    ))
                    if model.administratorProfileUnlocked {
                        TextField("Display name", text: administratorNameBinding)
                        TextField("Preferred address", text: administratorAddressBinding)
                        HStack(spacing: 8) {
                            Button("Lock profile", role: .cancel) {
                                model.administratorProfileUnlocked = false
                            }
                            Text("Press Save to keep profile edits.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Label("Profile locked", systemImage: "lock.fill")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                        Button("Unlock to edit name & address") {
                            Task {
                                if await model.authenticateMacLogin(
                                    reason: "Editing the SOMA administrator profile requires your Mac login password."
                                ) {
                                    model.administratorProfileUnlocked = true
                                }
                            }
                        }
                    }
                    HStack {
                        StateDot(active: model.runtime.administratorVerified, color: .green)
                        Text(model.runtime.administratorVerified ? "Administrator face verified" : "Waiting for a verified administrator face")
                            .foregroundStyle(.secondary)
                    }
                    Button("Remove administrator enrollment", role: .destructive) { model.removeAdministrator() }
                }
            }
            SettingsCard(title: "Recognition boundary", subtitle: "A visible face never grants remote or motor authority by itself.") {
                Text("SOMA labels the administrator only after repeated local profile matches. Raw embeddings remain encrypted on this Mac and are never written to the activity trace or sent as L2 context.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private var system: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard(title: model.runtime.isLive ? "SOMA is running" : "SOMA is not reporting activity", subtitle: runtimeSubtitle) {
                ActivityRow(name: "Indicator", state: model.runtime.indicatorState ?? "waiting", active: model.runtime.sourceIsOperational("social_indicator"))
                ActivityRow(name: "Settings", state: model.runtime.sources["control_settings"] ?? "not loaded", active: model.runtime.sourceIsOperational("control_settings"))
                ActivityRow(name: "Identity engine", state: model.runtime.sources["face_identity"] ?? "waiting", active: model.runtime.sourceIsOperational("face_identity"))
            }
            SettingsCard(title: "Runtime capabilities", subtitle: "Durable readiness from the current SOMA process.") {
                ActivityRow(name: "Vision", state: model.runtime.sources["face_neural_engine"] ?? "waiting", active: model.runtime.sourceIsOperational("face_neural_engine"))
                ActivityRow(name: "Voice", state: model.settings.realtimeVoiceEnabled ? (model.runtime.sources["l2_live_voice"] ?? "armed") : "off", active: model.settings.realtimeVoiceEnabled && model.runtime.sourceIsOperational("l2_live_voice"))
                ActivityRow(name: "Identity", state: identityState, active: model.runtime.isLive && model.runtime.identity != nil)
                ActivityRow(name: "Embodiment", state: model.runtime.sources["attention_gimbal_bridge"] ?? "waiting", active: model.runtime.sourceIsOperational("attention_gimbal_bridge"))
            }
            SettingsCard(title: "External dependencies", subtitle: "Check the host services, tools, models, and hardware SOMA depends on.") {
                HStack(spacing: 10) {
                    externalDependencyStatus
                    Spacer(minLength: 12)
                    Button(model.externalDependencyAudit == .unchecked ? "Run check" : "Check again") {
                        model.checkExternalDependencies()
                    }
                    .disabled(model.externalDependencyAudit == .checking)
                }
                if case let .loaded(audit) = model.externalDependencyAudit {
                    let issues = audit.checks.filter { $0.level != .passed }
                    if !issues.isEmpty {
                        Divider()
                        ForEach(issues) { check in
                            ExternalDependencyRow(check: check)
                        }
                    }
                    DisclosureGroup(
                        "All checks (\(audit.checks.count))",
                        isExpanded: $revealDependencyChecks
                    ) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(audit.checks) { check in
                                ExternalDependencyRow(check: check)
                            }
                        }
                        .padding(.top, 8)
                    }
                }
            }
            SettingsCard(title: "Apply changes", subtitle: "Runtime settings are read at startup to keep L0 deterministic.") {
                Text("Save writes settings to ~/Library/Application Support/SOMA/settings.json and layer/Ollama values to the owner-only .env beside it. Save & restart relaunches the existing local SOMA service so the layer values take effect.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private var identityState: String {
        if model.runtime.administratorVerified {
            return model.runtime.identity?.label ?? model.settings.administrator?.preferredAddress
                ?? model.settings.administrator?.displayName ?? "administrator verified"
        }
        return model.runtime.identity?.state.replacingOccurrences(of: "_", with: " ") ?? "waiting"
    }

    private var runtimeSubtitle: String {
        guard let date = model.runtime.lastActivity else { return "No local trace has been observed yet." }
        if abs(Date().timeIntervalSince(date)) < 1.5 { return "Last local activity just now." }
        let formatter = RelativeDateTimeFormatter()
        return "Last local activity \(formatter.localizedString(for: date, relativeTo: Date()))."
    }

    @ViewBuilder private var externalDependencyStatus: some View {
        switch model.externalDependencyAudit {
        case .unchecked:
            Label("Not checked", systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("Checking dependencies…")
            }
            .foregroundStyle(.secondary)
        case let .loaded(audit):
            let summary = "\(audit.passedCount) ready"
                + (audit.warningCount > 0 ? " · \(audit.warningCount) warning" : "")
                + (audit.failedCount > 0 ? " · \(audit.failedCount) failed" : "")
            Label(
                summary,
                systemImage: audit.isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(audit.isReady ? .green : .orange)
        case let .unavailable(reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder private var ollamaConnectionStatus: some View {
        switch model.ollamaConnection {
        case .unchecked:
            Label("Not checked", systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("Checking connection…")
            }
            .foregroundStyle(.secondary)
        case let .available(message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case let .unavailable(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<SOMAControlSettings, T>) -> Binding<T> {
        Binding(get: { model.settings[keyPath: keyPath] }, set: { model.settings[keyPath: keyPath] = $0 })
    }

    private var ledModeBinding: Binding<SOMALEDResponseMode> {
        Binding(get: { model.settings.led.responseMode }, set: { model.settings.led.responseMode = $0 })
    }

    private var realtimeVoiceSilenceTimeoutBinding: Binding<Int> {
        Binding(
            get: { model.settings.realtimeVoiceSilenceTimeoutSeconds },
            set: {
                model.settings.realtimeVoiceSilenceTimeoutSeconds = min(
                    max($0, SOMAControlSettings.realtimeVoiceSilenceTimeoutRange.lowerBound),
                    SOMAControlSettings.realtimeVoiceSilenceTimeoutRange.upperBound
                )
            }
        )
    }

    private var hermesAgentWorkspaceBinding: Binding<String> {
        Binding(
            get: { model.settings.hermesAgentWorkspace ?? "" },
            set: {
                model.settings.hermesAgentWorkspace = $0.isEmpty
                    ? nil
                    : String($0.prefix(1_024))
            }
        )
    }

    private var discordEnabledBinding: Binding<Bool> {
        Binding(
            get: { model.settings.discord.enabled },
            set: { model.settings.discord.enabled = $0 }
        )
    }

    private var discordChannelIDBinding: Binding<String> {
        Binding(
            get: { model.settings.discord.channelID },
            set: { model.settings.discord.channelID = $0.filter(\.isNumber).prefix(24).description }
        )
    }

    private var discordLabmanagerIDBinding: Binding<String> {
        Binding(
            get: { model.settings.discord.labmanagerBotUserID },
            set: { model.settings.discord.labmanagerBotUserID = $0.filter(\.isNumber).prefix(24).description }
        )
    }

    private var discordLabmanagerRoleIDBinding: Binding<String> {
        Binding(
            get: { model.settings.discord.labmanagerRoleID },
            set: { model.settings.discord.labmanagerRoleID = $0.filter(\.isNumber).prefix(24).description }
        )
    }

    private var discordInvocationMentionBinding: Binding<SOMADiscordInvocationMention> {
        Binding(
            get: { model.settings.discord.invocationMention },
            set: { model.settings.discord.invocationMention = $0 }
        )
    }

    private var discordForwardSpeechBinding: Binding<Bool> {
        Binding(
            get: { model.settings.discord.forwardAdministratorSpeech },
            set: { model.settings.discord.forwardAdministratorSpeech = $0 }
        )
    }

    private var discordReadRepliesBinding: Binding<Bool> {
        Binding(
            get: { model.settings.discord.readLabmanagerRepliesAloud },
            set: { model.settings.discord.readLabmanagerRepliesAloud = $0 }
        )
    }

    private var ledBrightnessBinding: Binding<Double> {
        Binding(
            get: { Double(model.settings.led.brightness) },
            set: { model.settings.led.brightness = Int($0.rounded()) }
        )
    }

    private func ledSignalBinding(
        for state: SubconsciousIndicatorState
    ) -> Binding<SOMALEDSignalSettings> {
        Binding(
            get: { model.settings.led.signal(for: state) },
            set: { model.settings.led.signals[state] = $0 }
        )
    }

    private var administratorNameBinding: Binding<String> {
        Binding(
            get: { model.settings.administrator?.displayName ?? "" },
            set: { value in
                guard var administrator = model.settings.administrator else { return }
                administrator.displayName = String(value.prefix(96))
                model.settings.administrator = administrator
                model.administratorDraftName = administrator.displayName
            }
        )
    }

    private var administratorAddressBinding: Binding<String> {
        Binding(
            get: { model.settings.administrator?.preferredAddress ?? "" },
            set: { value in
                guard var administrator = model.settings.administrator else { return }
                let normalized = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(96))
                administrator.preferredAddress = normalized.isEmpty ? nil : normalized
                model.settings.administrator = administrator
                model.administratorDraftAddress = administrator.preferredAddress ?? ""
            }
        )
    }

    private var ollamaAPIKeyBinding: Binding<String> {
        Binding(
            get: { model.envSettings.ollamaAPIKey },
            set: { model.envSettings.ollamaAPIKey = $0 }
        )
    }

    private var ollamaHostBinding: Binding<String> {
        Binding(
            get: { model.envSettings.ollamaHost },
            set: {
                model.envSettings.ollamaHost = String($0.prefix(256))
                model.invalidateOllamaConnection()
            }
        )
    }

    private var l0TrackingBinding: Binding<Bool> {
        Binding(
            get: { model.envSettings.l0TrackingEnabled },
            set: { model.envSettings.l0TrackingEnabled = $0 }
        )
    }

    private var l0ExploreBinding: Binding<Bool> {
        Binding(
            get: { model.envSettings.l0ExploreEnabled },
            set: { model.envSettings.l0ExploreEnabled = $0 }
        )
    }

    private var l2ProactiveOpeningsBinding: Binding<Bool> {
        Binding(
            get: { model.envSettings.l2ProactiveOpeningsEnabled },
            set: { model.envSettings.l2ProactiveOpeningsEnabled = $0 }
        )
    }

    private var l2CodexSandboxBinding: Binding<String> {
        Binding(
            get: { model.envSettings.l2CodexSandbox },
            set: { model.envSettings.l2CodexSandbox = $0 }
        )
    }

    private var l2CodexAdminOnlyBinding: Binding<Bool> {
        Binding(
            get: { model.envSettings.l2CodexAdminOnly },
            set: { model.envSettings.l2CodexAdminOnly = $0 }
        )
    }

    private var l1ModelBinding: Binding<String> {
        Binding(
            get: { model.envSettings.l1Model },
            set: {
                model.envSettings.l1Model = String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(96))
                model.invalidateOllamaConnection()
            }
        )
    }

    private var l1ReasoningCadenceBinding: Binding<Double> {
        Binding(
            get: { model.envSettings.l1ReasoningCadenceSeconds },
            set: { model.envSettings.l1ReasoningCadenceSeconds = min(max(30, $0), 600) }
        )
    }

    private var l1DefaultLanguageBinding: Binding<String> {
        Binding(
            get: { model.envSettings.l1DefaultLanguage },
            set: { model.envSettings.l1DefaultLanguage = $0 }
        )
    }

    private var l0E2BWakeScoreBinding: Binding<Double> {
        Binding(
            get: { model.envSettings.l0E2BWakeScore },
            set: { model.envSettings.l0E2BWakeScore = min(max($0, 0.1), 0.95) }
        )
    }
    private var l05EnabledBinding: Binding<Bool> {
        Binding(
            get: { model.envSettings.l05Enabled },
            set: { model.envSettings.l05Enabled = $0 }
        )
    }
    private var l0FaceFixationReleaseBinding: Binding<Double> {
        Binding(
            get: { model.envSettings.l0FaceFixationReleaseSeconds },
            set: { model.envSettings.l0FaceFixationReleaseSeconds = max($0, 0) }
        )
    }

    private var l0E2BWakeConfidenceBinding: Binding<Double> {
        Binding(
            get: { model.envSettings.l0E2BWakeConfidence },
            set: { model.envSettings.l0E2BWakeConfidence = min(max($0, 0.1), 0.95) }
        )
    }

    private var l0YoloConfidenceBinding: Binding<Double> {
        Binding(
            get: { model.envSettings.l0YoloConfidenceThreshold },
            set: { model.envSettings.l0YoloConfidenceThreshold = min(max($0, 0.1), 0.95) }
        )
    }

    private var l0E2BWakeIntervalBinding: Binding<Double> {
        Binding(
            get: { model.envSettings.l0E2BWakeIntervalMilliseconds },
            set: { model.envSettings.l0E2BWakeIntervalMilliseconds = max($0, 2_000) }
        )
    }

    private var l0EyeContactFreshnessBinding: Binding<Double> {
        Binding(
            get: { model.envSettings.l0EyeContactFreshnessMilliseconds },
            set: { model.envSettings.l0EyeContactFreshnessMilliseconds = min(max($0, 100), 2_000) }
        )
    }

    private var l0EyeContactPupilThresholdBinding: Binding<Double> {
        Binding(
            get: { model.envSettings.l0EyeContactPupilThreshold },
            set: { model.envSettings.l0EyeContactPupilThreshold = min(max($0, 0.5), 2.0) }
        )
    }

    private var l0CameraVerticalPlacementBinding: Binding<SOMACameraVerticalPlacement> {
        Binding(
            get: { model.envSettings.l0CameraVerticalPlacement },
            set: { model.envSettings.l0CameraVerticalPlacement = $0 }
        )
    }

    private var memoryRetentionBinding: Binding<Double> {
        Binding(
            get: { model.envSettings.memoryShortTermRetentionHours },
            set: { model.envSettings.memoryShortTermRetentionHours = min(max($0, 1), 24) }
        )
    }

    private var l1CuriosityEnabledBinding: Binding<Bool> {
        Binding(
            get: { model.envSettings.l1CuriosityCollectionEnabled },
            set: { model.envSettings.l1CuriosityCollectionEnabled = $0 }
        )
    }

    private var l1SpokenOpeningTendencyBinding: Binding<Double> {
        Binding(
            get: { model.envSettings.l1SpokenOpeningTendency },
            set: { model.envSettings.l1SpokenOpeningTendency = min(max($0, 0), 1) }
        )
    }

    private var l1OpenWithUnknownBinding: Binding<Bool> {
        Binding(
            get: { model.envSettings.l1OpenWithUnknownIdentity },
            set: { model.envSettings.l1OpenWithUnknownIdentity = $0 }
        )
    }

    private var l1CollectionIntervalBinding: Binding<Double> {
        Binding(
            get: { model.envSettings.l1CollectionIntervalHours },
            set: { model.envSettings.l1CollectionIntervalHours = $0 }
        )
    }

}

private enum SOMADefaultLanguage: String, CaseIterable {
    case korean = "ko"
    case english = "en"
    case japanese = "ja"
    case chinese = "zh"
    case spanish = "es"

    var tag: String { rawValue }

    var label: String {
        switch self {
        case .korean: "Korean"
        case .english: "English"
        case .japanese: "Japanese"
        case .chinese: "Chinese"
        case .spanish: "Spanish"
        }
    }
}

private enum SOMAEnvCollectionInterval: CaseIterable {
    case hourly6, hourly12, daily, weekly
    var hours: Double {
        switch self {
        case .hourly6: 6
        case .hourly12: 12
        case .daily: 24
        case .weekly: 168
        }
    }

    var label: String {
        switch self {
        case .hourly6: "6"
        case .hourly12: "12"
        case .daily: "24"
        case .weekly: "168"
        }
    }
}

private struct ActivityRow: View {
    let name: String
    let state: String
    let active: Bool

    var body: some View {
        HStack(spacing: 9) {
            StateDot(active: active, color: active ? .green : .orange)
            Text(name)
            Spacer()
            Text(state.replacingOccurrences(of: "_", with: " "))
                .foregroundStyle(.secondary)
                .textCase(.lowercase)
        }
        .font(.subheadline)
    }
}

private struct ExternalDependencyRow: View {
    let check: ExternalDependencyCheck

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 14)
            Text(check.detail)
                .font(.subheadline)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var symbol: String {
        switch check.level {
        case .passed: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failed: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch check.level {
        case .passed: .green
        case .warning: .orange
        case .failed: .red
        }
    }
}

private struct LEDSignalRow: View {
    let state: SubconsciousIndicatorState
    @Binding var signal: SOMALEDSignalSettings

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Circle()
                .fill(accent)
                .frame(width: 11, height: 11)
                .shadow(color: accent.opacity(0.45), radius: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(signal.pattern.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            HStack(spacing: 8) {
                Text("Color").foregroundStyle(.secondary)
                Picker("Color", selection: colorBinding) {
                    ForEach(SOMALEDColor.selectableCases, id: \.self) { color in
                        Text(color.displayName).tag(color)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 94)
                Picker("Pattern", selection: patternBinding) {
                    ForEach(SOMALEDPattern.allCases, id: \.self) { pattern in
                        Text(pattern.displayName).tag(pattern)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 108)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .background(accent.opacity(0.075), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var title: String {
        switch state {
        case .exploring: "Exploring"
        case .humanDetected: "Person noticed"
        case .contactReady: "Ready to talk"
        case .conversation: "Conversation"
        case .working, .listening, .speaking: "Conversation"
        }
    }

    private var accent: Color {
        switch signal.color {
        case .yellow: .yellow
        case .blue: .blue
        case .green: .green
        }
    }

    private var colorBinding: Binding<SOMALEDColor> {
        Binding(
            get: { signal.color },
            set: { color in
                signal.color = color
            }
        )
    }

    private var patternBinding: Binding<SOMALEDPattern> {
        Binding(
            get: { signal.pattern },
            set: { signal.pattern = $0 }
        )
    }
}

private enum SOMAStatusMenuLayout {
    static let width: CGFloat = 306
    static let inset: CGFloat = 16
}

private final class SOMAStatusMenuHeader: NSView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "SOMA")
    private let detailLabel = NSTextField(labelWithString: "")
    private let dotView = NSView()

    init(runtime: SOMARuntimeSnapshot, voice: SOMARealtimeVoice) {
        super.init(frame: NSRect(x: 0, y: 0, width: SOMAStatusMenuLayout.width, height: 50))
        iconView.image = SOMABrand.mark(size: 34)
        iconView.contentTintColor = .labelColor
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.frame = NSRect(x: 16, y: 8, width: 34, height: 34)
        addSubview(iconView)
        dotView.wantsLayer = true
        dotView.layer?.backgroundColor = (runtime.isLive ? NSColor.systemGreen : NSColor.systemOrange).cgColor
        dotView.layer?.cornerRadius = 4
        dotView.frame = NSRect(x: 59, y: 28, width: 8, height: 8)
        addSubview(dotView)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.alignment = .left
        titleLabel.frame = NSRect(x: 74, y: 24, width: 208, height: 17)
        addSubview(titleLabel)
        detailLabel.stringValue = runtime.isLive ? "Live · Voice \(voice.displayName)" : "Waiting for the local runtime"
        detailLabel.font = .systemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .left
        detailLabel.frame = NSRect(x: 74, y: 8, width: 208, height: 15)
        addSubview(detailLabel)
    }

    required init?(coder: NSCoder) { nil }
}

private final class SOMAStatusMenuSection: NSView {
    init(title: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: SOMAStatusMenuLayout.width, height: 28))
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.alignment = .left
        label.frame = NSRect(x: SOMAStatusMenuLayout.inset, y: 6, width: 220, height: 14)
        addSubview(label)
    }

    required init?(coder: NSCoder) { nil }
}

private final class SOMAStatusMenuActivityRow: NSView {
    init(name: String, state: String, active: Bool) {
        super.init(frame: NSRect(x: 0, y: 0, width: SOMAStatusMenuLayout.width, height: 28))
        let dot = NSView(frame: NSRect(x: SOMAStatusMenuLayout.inset, y: 10, width: 8, height: 8))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = (active ? NSColor.systemGreen : NSColor.tertiaryLabelColor).cgColor
        dot.layer?.cornerRadius = 4
        addSubview(dot)

        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.textColor = active ? .labelColor : .secondaryLabelColor
        nameLabel.alignment = .left
        nameLabel.frame = NSRect(x: 36, y: 6, width: 84, height: 16)
        addSubview(nameLabel)

        let stateLabel = NSTextField(labelWithString: state.replacingOccurrences(of: "_", with: " "))
        stateLabel.font = .systemFont(ofSize: 12, weight: .regular)
        stateLabel.textColor = active ? .labelColor : .secondaryLabelColor
        stateLabel.alignment = .left
        stateLabel.lineBreakMode = .byTruncatingTail
        stateLabel.frame = NSRect(x: 124, y: 6, width: 166, height: 16)
        addSubview(stateLabel)
    }

    required init?(coder: NSCoder) { nil }
}

private final class SOMAStatusMenuDivider: NSView {
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: SOMAStatusMenuLayout.width, height: 8))
        let line = NSView(frame: NSRect(x: SOMAStatusMenuLayout.inset, y: 3, width: SOMAStatusMenuLayout.width - SOMAStatusMenuLayout.inset * 2, height: 1))
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.separatorColor.cgColor
        addSubview(line)
    }

    required init?(coder: NSCoder) { nil }
}

/// Non-modal progress panel for guided multi-pose face enrollment. Shows the
/// pose guidance and a live countdown while the running SOMA process (which
/// owns the camera) accumulates distinct face samples, then runs the blocking
/// promotion and reports the outcome.
@MainActor
private final class GuidedEnrollmentPanel: NSObject {
    private let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 420, height: 190),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    private let guideLabel = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let totalSeconds: Double
    private let onEnroll: @MainActor () -> (Bool, String)
    private var timer: Timer?
    private var elapsed = 0.0
    private var finished = false
    private static var live: GuidedEnrollmentPanel?

    private init(
        totalSeconds: Double,
        onEnroll: @escaping @MainActor () -> (Bool, String)
    ) {
        self.totalSeconds = max(totalSeconds, 1)
        self.onEnroll = onEnroll
        super.init()
        build()
    }

    private func build() {
        panel.title = "Enroll Administrator Face"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.center()

        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = totalSeconds
        progress.doubleValue = 0

        guideLabel.font = .systemFont(ofSize: 13)
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [guideLabel, progress, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        panel.contentView = stack
    }

    static func present(
        handle: String,
        guide: String,
        sampleWindowSeconds: Double,
        onEnroll: @escaping @MainActor () -> (Bool, String)
    ) {
        let controller = GuidedEnrollmentPanel(totalSeconds: sampleWindowSeconds, onEnroll: onEnroll)
        GuidedEnrollmentPanel.live = controller
        controller.guideLabel.stringValue = guide
        controller.statusLabel.stringValue = "Capturing samples…"
        controller.panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.start()
    }

    private func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    private func tick() {
        guard !finished else { return }
        elapsed += 0.1
        let remaining = max(totalSeconds - elapsed, 0)
        progress.doubleValue = min(elapsed, totalSeconds)
        if remaining > 0 {
            statusLabel.stringValue = String(format: "%.0f s remaining — keep turning your head", remaining)
        } else {
            finished = true
            progress.isIndeterminate = true
            progress.startAnimation(nil)
            statusLabel.stringValue = "Enrolling samples…"
            // The promotion subprocess is short; run it here so we can update
            // the panel with the final result and keep self alive via `live`.
            let outcome = onEnroll()
            finish(success: outcome.0, message: outcome.1)
        }
    }

    private func finish(success: Bool, message: String) {
        finished = true
        timer?.invalidate()
        timer = nil
        progress.stopAnimation(nil)
        statusLabel.stringValue = message
        guideLabel.stringValue = success ? "Administrator face enrolled." : "Enrollment failed."
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.panel.orderOut(nil)
            self?.panel.close()
            GuidedEnrollmentPanel.live = nil
        }
    }
}

@MainActor
private final class SOMAStatusBar: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: 28)
    private let menu = NSMenu()
    private let model = SOMAControlModel()
    private let opensSettingsOnLaunch: Bool
    private var settingsWindow: NSWindow?
    private var diagnosticsPanel: NSPanel?
    private var openSettingsObserver: NSObjectProtocol?

    init(opensSettingsOnLaunch: Bool) {
        self.opensSettingsOnLaunch = opensSettingsOnLaunch
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        openSettingsObserver = DistributedNotificationCenter.default().addObserver(
            forName: SOMAMenuBarInstanceLease.openSettingsNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.openSettings() }
        }
        menu.delegate = self
        menu.minimumWidth = SOMAStatusMenuLayout.width
        statusItem.menu = menu
        if let button = statusItem.button {
            button.image = SOMABrand.menuBarMark()
            button.imageScaling = .scaleProportionallyDown
            button.imagePosition = .imageOnly
            button.toolTip = "SOMA Control Center"
        }
        if opensSettingsOnLaunch {
            DispatchQueue.main.async { [weak self] in self?.openSettings() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let openSettingsObserver {
            DistributedNotificationCenter.default().removeObserver(openSettingsObserver)
            self.openSettingsObserver = nil
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        model.refresh()
        menu.removeAllItems()
        let header = NSMenuItem()
        header.view = SOMAStatusMenuHeader(runtime: model.runtime, voice: model.settings.realtimeVoice)
        menu.addItem(header)
        addDivider(to: menu)
        addSection("LIVE ACTIVITY", to: menu)
        addStatus("Vision", state: model.runtime.sources["face_neural_engine"] ?? "waiting", active: model.runtime.sourceIsOperational("face_neural_engine"), to: menu)
        addStatus("Voice", state: model.settings.realtimeVoiceEnabled ? (model.runtime.sources["l2_live_voice"] ?? "armed") : "off", active: model.settings.realtimeVoiceEnabled && model.runtime.sourceIsOperational("l2_live_voice"), to: menu)
        let identityText = model.runtime.administratorVerified
            ? (model.runtime.identity?.label ?? model.settings.administrator?.preferredAddress
                ?? model.settings.administrator?.displayName ?? "administrator verified")
            : (model.runtime.identity?.state ?? "waiting")
        addStatus("Identity", state: identityText, active: model.runtime.isLive && model.runtime.identity != nil, to: menu)
        addStatus("Embodiment", state: model.runtime.sources["attention_gimbal_bridge"] ?? "waiting", active: model.runtime.sourceIsOperational("attention_gimbal_bridge"), to: menu)
        addDivider(to: menu)
        menu.addItem(item("Settings…", action: #selector(openSettings)))
        menu.addItem(item("Diagnostic panel…", action: #selector(openDiagnostics)))
        if model.isSOMARunning {
            menu.addItem(item("Stop SOMA", action: #selector(stopSOMA)))
        } else {
            menu.addItem(item("Start SOMA", action: #selector(startSOMA)))
        }
        menu.addItem(item("Restart SOMA", action: #selector(restartSOMA)))
        menu.addItem(item("Open runtime folder", action: #selector(openRuntime)))
        addDivider(to: menu)
        menu.addItem(item("Quit SOMA Control", action: #selector(quit)))
    }

    private func addSection(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem()
        item.view = SOMAStatusMenuSection(title: title)
        menu.addItem(item)
    }

    private func addStatus(_ name: String, state: String, active: Bool, to menu: NSMenu) {
        let item = NSMenuItem()
        item.view = SOMAStatusMenuActivityRow(name: name, state: state, active: active)
        menu.addItem(item)
    }

    private func addDivider(to menu: NSMenu) {
        let item = NSMenuItem()
        item.view = SOMAStatusMenuDivider()
        menu.addItem(item)
    }

    private func item(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openSettings() {
        NSApp.setActivationPolicy(.regular)
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "SOMA Settings"
        window.minSize = NSSize(width: 770, height: 580)
        window.level = .normal
        window.collectionBehavior = [.managed, .participatesInCycle]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: SOMASettingsView(
            model: model,
            onSuccessfulRestart: { [weak self] in
                self?.settingsWindow?.close()
            },
            onOpenDiagnostics: { [weak self] in self?.openDiagnostics() }
        ))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    @objc private func openDiagnostics() {
        if let diagnosticsPanel {
            diagnosticsPanel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // Ask the runtime to start writing live diagnostic files.
        let flagURL = SOMAPaths.runtimeRoot.appendingPathComponent("live-diagnostics.enabled")
        try? Data().write(to: flagURL, options: .atomic)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 660),
            styleMask: [.titled, .closable, .utilityWindow, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "SOMA Diagnostic"
        panel.minSize = NSSize(width: 700, height: 560)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.delegate = self
        let diagnosticsModel = SOMADiagnosticsModel(runtimeRoot: SOMAPaths.runtimeRoot)
        panel.contentViewController = NSHostingController(rootView: SOMADiagnosticsView(model: diagnosticsModel))
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        diagnosticsPanel = panel
    }

    @objc private func startSOMA() {
        let result = model.startSOMA()
        model.refresh()
        guard result.status != 0 else { return }
        NSAlert(error: NSError(
            domain: "SOMAControl",
            code: Int(result.status),
            userInfo: [NSLocalizedDescriptionKey: result.output.isEmpty ? "Could not start SOMA." : result.output]
        )).runModal()
    }

    @objc private func stopSOMA() {
        let result = model.stopSOMA()
        guard result.status != 0 else { return }
        NSAlert(error: NSError(
            domain: "SOMAControl",
            code: Int(result.status),
            userInfo: [NSLocalizedDescriptionKey: result.output.isEmpty ? "Could not stop SOMA." : result.output]
        )).runModal()
    }

    @objc private func restartSOMA() { model.saveAndRestart() }
    @objc private func openRuntime() { model.revealRuntime() }
    @objc private func quit() {
        model.stopControlCenter()
        NSApp.terminate(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === settingsWindow {
            settingsWindow = nil
            NSApp.setActivationPolicy(.accessory)
        }
        if notification.object as? NSWindow === diagnosticsPanel {
            // Stop the runtime's live-diagnostic writer.
            let flagURL = SOMAPaths.runtimeRoot.appendingPathComponent("live-diagnostics.enabled")
            try? FileManager.default.removeItem(at: flagURL)
            diagnosticsPanel = nil
        }
    }
}

private let opensSettingsOnLaunch = CommandLine.arguments.contains("--settings")
private let instanceLease = SOMAMenuBarInstanceLease.acquire()
if instanceLease == nil {
    if opensSettingsOnLaunch {
        DistributedNotificationCenter.default().postNotificationName(
            SOMAMenuBarInstanceLease.openSettingsNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }
    exit(EXIT_SUCCESS)
}
private let application = NSApplication.shared
private let delegate = SOMAStatusBar(opensSettingsOnLaunch: opensSettingsOnLaunch)
application.delegate = delegate
application.run()
