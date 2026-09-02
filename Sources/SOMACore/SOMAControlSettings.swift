import Foundation

/// Listening-oriented grouping curated for SOMA's supported realtime voices.
public enum SOMARealtimeVoicePresentation: String, CaseIterable, Sendable {
    case female
    case male

    public var displayName: String { rawValue.capitalized }
}

/// Voices accepted by the Codex app-server v3 realtime transport. This list is
/// intentionally narrower than the protocol-wide `RealtimeVoice` enum: the
/// backend rejects the additional voice IDs when a v3 WebRTC session starts.
public enum SOMARealtimeVoice: String, CaseIterable, Codable, Sendable {
    case arbor
    case breeze
    case cove
    case ember
    case juniper
    case maple
    case sol
    case spruce
    case vale

    public var displayName: String { rawValue.capitalized }

    public var presentation: SOMARealtimeVoicePresentation {
        switch self {
        case .juniper, .maple, .vale, .sol:
            .female
        case .spruce, .ember, .breeze, .arbor, .cove:
            .male
        }
    }

    public static func voices(
        with presentation: SOMARealtimeVoicePresentation
    ) -> [SOMARealtimeVoice] {
        switch presentation {
        case .female: [.juniper, .maple, .vale, .sol]
        case .male: [.spruce, .ember, .breeze, .arbor, .cove]
        }
    }
}

/// A presentation policy for the OBSBOT's built-in indicator. The device
/// owns its colour palette; SOMA selects when and how prominently it reacts.
public enum SOMALEDResponseMode: String, CaseIterable, Codable, Sendable {
    case expressive
    case contextual
    case quiet
    case off

    public var displayName: String {
        switch self {
        case .expressive: "Expressive"
        case .contextual: "Contextual"
        case .quiet: "Quiet"
        case .off: "Off"
        }
    }

    public func permits(_ state: SubconsciousIndicatorState) -> Bool {
        switch self {
        case .expressive:
            true
        case .contextual:
            state != .exploring && state != .humanDetected
        case .quiet:
            state.configurationState == .conversation
        case .off:
            false
        }
    }
}

/// A user-facing semantic colour available from the connected OBSBOT
/// indicator. The active device contract resolves it to a validated firmware
/// state or the device's verified default presentation.
public enum SOMALEDColor: String, CaseIterable, Codable, Sendable {
    case yellow
    case green
    case blue

    public var displayName: String {
        switch self {
        case .yellow, .green, .blue:
            rawValue.capitalized
        }
    }

    /// The setting surface stays semantic. The connected product profile
    /// resolves each colour to its own firmware palette entry at runtime.
    public static let selectableCases: [Self] = allCases

}

/// A device-specific status-indicator rendering. Palette state IDs and
/// the firmware-owned default are separate presentations.
public struct SOMALEDDeviceRendering: Equatable, Sendable {
    public let stateID: Int?
    public let directColor: SOMALEDColor?
    public let usesFirmwareDefault: Bool
    public let pattern: SOMALEDPattern

    public init(stateID: Int, pattern: SOMALEDPattern) {
        self.stateID = stateID
        directColor = nil
        usesFirmwareDefault = false
        self.pattern = pattern
    }

    public init(firmwareDefaultPattern pattern: SOMALEDPattern = .steady) {
        stateID = nil
        directColor = nil
        usesFirmwareDefault = true
        self.pattern = pattern
    }

    public init(directColor: SOMALEDColor, pattern: SOMALEDPattern) {
        stateID = nil
        self.directColor = directColor
        usesFirmwareDefault = false
        self.pattern = pattern
    }

    public var pulseEnabled: Bool { pattern != .steady }
}

/// Internal calibration entries for Tiny devices. These describe the
/// firmware's state IDs and are deliberately kept out of the user settings
/// surface: names such as `tracking` are device implementation details, not
/// meaningful LED choices.
public enum SOMALEDFirmwarePreset: String, CaseIterable, Codable, Sendable {
    case targetLost
    case targetLock
    case gesture
    case normalWork
    case tracking

    public var colorName: String {
        switch self {
        case .targetLost: "Yellow"
        case .targetLock, .gesture: "Green"
        case .normalWork: "Blue"
        case .tracking: "Green"
        }
    }

    /// The native bridge validates this small fixed set before it ever reaches
    /// the device transport. The firmware maps each entry to its own RGB palette.
    public var firmwareStateID: Int {
        switch self {
        case .targetLost: 16
        case .targetLock: 17
        case .gesture: 18
        case .normalWork: 54
        case .tracking: 57
        }
    }
}

public enum SOMALEDPattern: String, CaseIterable, Codable, Sendable {
    case steady
    case firmwareAnimation = "firmware_animation"
    case beacon
    case doubleBlink
    case longPulse
    case heartbeat
    case blink

    public var displayName: String {
        switch self {
        case .steady: "Steady"
        case .firmwareAnimation: "Contact pulse"
        case .beacon: "Beacon"
        case .doubleBlink: "Double blink"
        case .longPulse: "Long pulse"
        case .heartbeat: "Heartbeat"
        case .blink: "Blink"
        }
    }

    public func isPhysicallySupported(for color: SOMALEDColor) -> Bool {
        // Timing is host-controlled; any firmware palette position can carry
        // the same temporal pattern even before its colour is visually named.
        true
    }

    public var indicatorPattern: SubconsciousIndicatorPattern {
        switch self {
        case .steady:
            .init(name: "steady", phases: [
                .init(illuminated: true, durationMilliseconds: nil),
            ])
        case .firmwareAnimation:
            .init(name: "firmware_animation", phases: [
                .init(illuminated: true, durationMilliseconds: nil),
            ])
        case .beacon:
            .init(name: "beacon", phases: [
                .init(illuminated: true, durationMilliseconds: 180),
                .init(illuminated: false, durationMilliseconds: 1_320),
            ])
        case .doubleBlink:
            .init(name: "double_blink", phases: [
                .init(illuminated: true, durationMilliseconds: 140),
                .init(illuminated: false, durationMilliseconds: 110),
                .init(illuminated: true, durationMilliseconds: 140),
                .init(illuminated: false, durationMilliseconds: 610),
            ])
        case .longPulse:
            .init(name: "long_pulse", phases: [
                .init(illuminated: true, durationMilliseconds: 800),
                .init(illuminated: false, durationMilliseconds: 200),
            ])
        case .heartbeat:
            .init(name: "heartbeat", phases: [
                .init(illuminated: true, durationMilliseconds: 300),
                .init(illuminated: false, durationMilliseconds: 700),
            ])
        case .blink:
            .init(name: "blink", phases: [
                .init(illuminated: true, durationMilliseconds: 400),
                .init(illuminated: false, durationMilliseconds: 400),
            ])
        }
    }
}

public struct SOMALEDSignalSettings: Codable, Equatable, Sendable {
    public var color: SOMALEDColor
    public var pattern: SOMALEDPattern

    public init(color: SOMALEDColor, pattern: SOMALEDPattern) {
        self.color = color
        self.pattern = pattern
    }

    public func deviceRendering(for contract: OBSBOTDeviceContract) -> SOMALEDDeviceRendering? {
        if contract.supportsDirectIndicatorColor(color) {
            return .init(
                directColor: color,
                pattern: contract.indicatorPattern(for: pattern)
            )
        }
        if contract.usesFirmwareDefaultIndicator(for: color) {
            // Clearing all SOMA-owned states returns Tiny 3 Lite to its stable
            // firmware green. It is not an addressable palette state, so it
            // cannot carry a host-generated cadence.
            return .init(firmwareDefaultPattern: .steady)
        }
        guard contract.capabilities.supportsFirmwareIndicatorPalette,
              let stateID = contract.firmwareIndicatorStateID(for: color) else {
            return nil
        }
        return .init(
            stateID: stateID,
            pattern: contract.indicatorPattern(for: pattern)
        )
    }

    public func normalizedForDevice() -> Self {
        guard pattern.isPhysicallySupported(for: color) else {
            return .init(color: color, pattern: .steady)
        }
        return self
    }

    private enum CodingKeys: String, CodingKey {
        case color
        case pattern
        // Read-only migration key for settings schema 2.
        case preset
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        pattern = try values.decode(SOMALEDPattern.self, forKey: .pattern)
        if let color = try values.decodeIfPresent(SOMALEDColor.self, forKey: .color) {
            self.color = color
            return
        }
        let legacyPreset = try values.decode(SOMALEDFirmwarePreset.self, forKey: .preset)
        switch legacyPreset {
        case .targetLost:
            color = .yellow
        case .targetLock, .gesture, .normalWork, .tracking:
            color = .green
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(color, forKey: .color)
        try values.encode(pattern, forKey: .pattern)
    }
}

public struct SOMALEDSettings: Codable, Equatable, Sendable {
    public var responseMode: SOMALEDResponseMode
    /// OBSBOT exposes four discrete brightness levels, 0 through 3.
    public var brightness: Int
    /// Each meaningful interaction state has an independently selected colour
    /// and a physically supported device behavior.
    public var signals: [SubconsciousIndicatorState: SOMALEDSignalSettings]
    /// Pre-unification conversation settings retained only while decoding an
    /// older owner configuration. They are folded into `conversation` before
    /// the settings are persisted again.
    private var legacyConversationSignal: SOMALEDSignalSettings?

    public init(
        responseMode: SOMALEDResponseMode = .expressive,
        brightness: Int = 2,
        signals: [SubconsciousIndicatorState: SOMALEDSignalSettings]? = nil
    ) {
        self.responseMode = responseMode
        self.brightness = min(max(brightness, 0), 3)
        let suppliedSignals = signals ?? [:]
        self.legacyConversationSignal = Self.legacyConversationSignal(in: suppliedSignals)
        self.signals = Self.normalized(suppliedSignals)
    }

    public func signal(for state: SubconsciousIndicatorState) -> SOMALEDSignalSettings {
        let canonical = state.configurationState
        if let signal = signals[canonical] {
            return signal
        }
        if canonical == .conversation {
            return signals[.working]
                ?? signals[.speaking]
                ?? signals[.listening]
                ?? Self.defaultSignal(for: canonical)
        }
        return Self.defaultSignal(for: canonical)
    }

    /// Conversation owns the indicator colour while verified eye contact owns
    /// its cadence. This keeps the session affordance stable (for example,
    /// yellow) while still exposing whether the camera currently sees direct
    /// visual contact.
    public func deviceRendering(
        for state: SubconsciousIndicatorState,
        on contract: OBSBOTDeviceContract,
        eyeContactActive: Bool = false
    ) -> SOMALEDDeviceRendering? {
        var presentation = signal(for: state)
        if state.configurationState == .conversation && eyeContactActive {
            presentation.pattern = .blink
        }
        return presentation.deviceRendering(for: contract)
    }

    private static func normalized(
        _ signals: [SubconsciousIndicatorState: SOMALEDSignalSettings]
    ) -> [SubconsciousIndicatorState: SOMALEDSignalSettings] {
        Dictionary(uniqueKeysWithValues: SubconsciousIndicatorState.configurationStates.map { state in
            let selected = signal(for: state, from: signals)
            return (state, selected.normalizedForDevice())
        })
    }

    private static func signal(
        for state: SubconsciousIndicatorState,
        from signals: [SubconsciousIndicatorState: SOMALEDSignalSettings]
    ) -> SOMALEDSignalSettings {
        if let signal = signals[state] { return signal }
        if state == .conversation {
            return signals[.working]
                ?? signals[.speaking]
                ?? signals[.listening]
                ?? defaultSignal(for: state)
        }
        return defaultSignal(for: state)
    }

    private static func defaultSignal(
        for state: SubconsciousIndicatorState
    ) -> SOMALEDSignalSettings {
        switch state {
        case .exploring: .init(color: .green, pattern: .steady)
        case .humanDetected: .init(color: .blue, pattern: .steady)
        case .contactReady: .init(color: .blue, pattern: .firmwareAnimation)
        case .conversation, .working, .listening, .speaking: .init(color: .yellow, pattern: .steady)
        }
    }

    private static func legacyConversationSignal(
        in signals: [SubconsciousIndicatorState: SOMALEDSignalSettings]
    ) -> SOMALEDSignalSettings? {
        signals[.working] ?? signals[.speaking] ?? signals[.listening]
    }

    var explicitLegacyConversationSignal: SOMALEDSignalSettings? {
        legacyConversationSignal
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.responseMode == rhs.responseMode
            && lhs.brightness == rhs.brightness
            && lhs.signals == rhs.signals
    }

    private enum CodingKeys: String, CodingKey {
        case responseMode
        case brightness
        case signals
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        responseMode = try values.decodeIfPresent(SOMALEDResponseMode.self, forKey: .responseMode) ?? .expressive
        brightness = min(max(try values.decodeIfPresent(Int.self, forKey: .brightness) ?? 2, 0), 3)
        let decodedSignals = try values.decodeIfPresent(
            [SubconsciousIndicatorState: SOMALEDSignalSettings].self,
            forKey: .signals
        ) ?? [:]
        legacyConversationSignal = Self.legacyConversationSignal(in: decodedSignals)
        signals = Self.normalized(decodedSignals)
    }
}

/// Personal metadata deliberately kept apart from the encrypted face
/// embedding store. A face match identifies a local entity ID; only this
/// mapping grants that entity the local administrator label.
public struct SOMAAdministratorIdentity: Codable, Equatable, Sendable {
    public let entityID: UUID
    public var displayName: String
    public var preferredAddress: String?

    public init(entityID: UUID, displayName: String, preferredAddress: String? = nil) {
        self.entityID = entityID
        self.displayName = Self.clean(displayName, limit: 96, fallback: "Administrator")
        let cleanedAddress = preferredAddress.map { Self.clean($0, limit: 96, fallback: "") }
        self.preferredAddress = cleanedAddress?.isEmpty == true ? nil : cleanedAddress
    }

    private static func clean(_ value: String, limit: Int, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : String(trimmed.prefix(limit))
    }
}

/// User-controlled settings consumed by the local runtime at process launch.
/// None of the fields contain face embeddings or other raw biometric material.
public struct SOMAControlSettings: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 14
    public static let defaultRealtimeVoiceSilenceTimeoutSeconds = 60
    public static let realtimeVoiceSilenceTimeoutRange = 15...600

    public var schemaVersion: Int
    public var realtimeVoiceEnabled: Bool
    public var realtimeVoice: SOMARealtimeVoice
    /// When enabled, an already-open session receives a participant turn only
    /// while current eye contact and audiovisual speaker evidence agree.
    public var realtimeVoiceRequiresEyeContactForEveryTurn: Bool
    /// When enabled, a newly opened spoken conversation must be bound to the
    /// enrolled local administrator. Unknown and ordinary participant faces
    /// remain visible to perception but cannot open L2 voice.
    public var administratorOnlyConversations: Bool
    /// User silence closes the account-backed realtime session so an idle
    /// microphone never holds conversation resources indefinitely.
    public var realtimeVoiceSilenceTimeoutSeconds: Int
    /// Enables durable asynchronous work delegated by the administrator's L2
    /// session to a local Hermes Agent worker.
    public var hermesAgentDelegationEnabled: Bool
    /// Default filesystem context for delegated work. A task may override it
    /// only with another existing absolute directory.
    public var hermesAgentWorkspace: String?
    public var discord: SOMADiscordSettings
    public var led: SOMALEDSettings
    /// These settings only narrow the launch-agent capabilities; they can
    /// never grant motion authority that the service was not launched with.
    public var nativeHumanTrackingEnabled: Bool
    public var autonomousExplorationEnabled: Bool
    public var administrator: SOMAAdministratorIdentity?

    public init(
        schemaVersion: Int = SOMAControlSettings.currentSchemaVersion,
        realtimeVoiceEnabled: Bool = true,
        realtimeVoice: SOMARealtimeVoice = .maple,
        realtimeVoiceRequiresEyeContactForEveryTurn: Bool = true,
        administratorOnlyConversations: Bool = true,
        realtimeVoiceSilenceTimeoutSeconds: Int = SOMAControlSettings.defaultRealtimeVoiceSilenceTimeoutSeconds,
        hermesAgentDelegationEnabled: Bool = true,
        hermesAgentWorkspace: String? = nil,
        discord: SOMADiscordSettings = .init(),
        led: SOMALEDSettings = .init(),
        nativeHumanTrackingEnabled: Bool = true,
        autonomousExplorationEnabled: Bool = true,
        administrator: SOMAAdministratorIdentity? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.realtimeVoiceEnabled = realtimeVoiceEnabled
        self.realtimeVoice = realtimeVoice
        self.realtimeVoiceRequiresEyeContactForEveryTurn = realtimeVoiceRequiresEyeContactForEveryTurn
        self.administratorOnlyConversations = administratorOnlyConversations
        self.realtimeVoiceSilenceTimeoutSeconds = min(
            max(realtimeVoiceSilenceTimeoutSeconds, Self.realtimeVoiceSilenceTimeoutRange.lowerBound),
            Self.realtimeVoiceSilenceTimeoutRange.upperBound
        )
        self.hermesAgentDelegationEnabled = hermesAgentDelegationEnabled
        self.hermesAgentWorkspace = Self.normalizedAbsolutePath(hermesAgentWorkspace)
        self.discord = discord
        self.led = led
        self.nativeHumanTrackingEnabled = nativeHumanTrackingEnabled
        self.autonomousExplorationEnabled = autonomousExplorationEnabled
        self.administrator = administrator
    }

    public var isCurrentSchema: Bool { schemaVersion == Self.currentSchemaVersion }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case realtimeVoiceEnabled
        case realtimeVoice
        case realtimeVoiceRequiresEyeContactForEveryTurn
        case administratorOnlyConversations
        case realtimeVoiceSilenceTimeoutSeconds
        case hermesAgentDelegationEnabled
        case hermesAgentWorkspace
        case discord
        case led
        case nativeHumanTrackingEnabled
        case autonomousExplorationEnabled
        case administrator
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let sourceVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard (1...Self.currentSchemaVersion).contains(sourceVersion) else {
            throw SOMAControlSettingsStoreError.unsupportedSchema(sourceVersion)
        }
        schemaVersion = Self.currentSchemaVersion
        realtimeVoiceEnabled = try values.decodeIfPresent(Bool.self, forKey: .realtimeVoiceEnabled) ?? true
        let persistedVoice = try values.decodeIfPresent(String.self, forKey: .realtimeVoice)
        realtimeVoice = persistedVoice.flatMap(SOMARealtimeVoice.init(rawValue:)) ?? .maple
        realtimeVoiceRequiresEyeContactForEveryTurn = try values.decodeIfPresent(
            Bool.self,
            forKey: .realtimeVoiceRequiresEyeContactForEveryTurn
        ) ?? true
        administratorOnlyConversations = try values.decodeIfPresent(
            Bool.self,
            forKey: .administratorOnlyConversations
        ) ?? true
        let decodedSilenceTimeout = try values.decodeIfPresent(
            Int.self,
            forKey: .realtimeVoiceSilenceTimeoutSeconds
        ) ?? Self.defaultRealtimeVoiceSilenceTimeoutSeconds
        realtimeVoiceSilenceTimeoutSeconds = min(
            max(decodedSilenceTimeout, Self.realtimeVoiceSilenceTimeoutRange.lowerBound),
            Self.realtimeVoiceSilenceTimeoutRange.upperBound
        )
        hermesAgentDelegationEnabled = try values.decodeIfPresent(
            Bool.self,
            forKey: .hermesAgentDelegationEnabled
        ) ?? true
        hermesAgentWorkspace = Self.normalizedAbsolutePath(
            try values.decodeIfPresent(String.self, forKey: .hermesAgentWorkspace)
        )
        discord = try values.decodeIfPresent(SOMADiscordSettings.self, forKey: .discord) ?? .init()
        var decodedLED = try values.decodeIfPresent(SOMALEDSettings.self, forKey: .led) ?? .init()
        if sourceVersion < 6,
           decodedLED.signal(for: .contactReady).pattern == .steady {
            let contactSignal = decodedLED.signal(for: .contactReady)
            decodedLED.signals[.contactReady] = .init(
                color: contactSignal.color,
                pattern: .blink
            )
        }
        if sourceVersion < 7 {
            // These are social meanings, not a device fallback palette:
            // visible person = blue, direct mutual attention = blue blink,
            // and an active spoken session = green.
            decodedLED.signals[.exploring] = .init(color: .yellow, pattern: .steady)
            decodedLED.signals[.humanDetected] = .init(color: .blue, pattern: .steady)
            decodedLED.signals[.contactReady] = .init(color: .blue, pattern: .blink)
            decodedLED.signals[.conversation] = .init(color: .green, pattern: .steady)
            if let legacyConversationSignal = decodedLED.explicitLegacyConversationSignal {
                decodedLED.signals[.conversation] = legacyConversationSignal.normalizedForDevice()
            }
        }
        // A persisted signal is an operator-owned interaction contract. Older
        // schema versions may legitimately contain the explicit blue blink
        // used for direct contact, so decoding must never replace it with a
        // later default cadence.
        led = decodedLED
        nativeHumanTrackingEnabled = try values.decodeIfPresent(Bool.self, forKey: .nativeHumanTrackingEnabled) ?? true
        autonomousExplorationEnabled = try values.decodeIfPresent(Bool.self, forKey: .autonomousExplorationEnabled) ?? true
        administrator = try values.decodeIfPresent(SOMAAdministratorIdentity.self, forKey: .administrator)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try values.encode(realtimeVoiceEnabled, forKey: .realtimeVoiceEnabled)
        try values.encode(realtimeVoice, forKey: .realtimeVoice)
        try values.encode(
            realtimeVoiceRequiresEyeContactForEveryTurn,
            forKey: .realtimeVoiceRequiresEyeContactForEveryTurn
        )
        try values.encode(administratorOnlyConversations, forKey: .administratorOnlyConversations)
        try values.encode(
            realtimeVoiceSilenceTimeoutSeconds,
            forKey: .realtimeVoiceSilenceTimeoutSeconds
        )
        try values.encode(hermesAgentDelegationEnabled, forKey: .hermesAgentDelegationEnabled)
        try values.encodeIfPresent(
            Self.normalizedAbsolutePath(hermesAgentWorkspace),
            forKey: .hermesAgentWorkspace
        )
        try values.encode(discord, forKey: .discord)
        try values.encode(led, forKey: .led)
        try values.encode(nativeHumanTrackingEnabled, forKey: .nativeHumanTrackingEnabled)
        try values.encode(autonomousExplorationEnabled, forKey: .autonomousExplorationEnabled)
        try values.encodeIfPresent(administrator, forKey: .administrator)
    }

    public static func normalizedAbsolutePath(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), !trimmed.contains("\n"), !trimmed.contains("\0") else {
            return nil
        }
        return String(URL(fileURLWithPath: trimmed).standardizedFileURL.path.prefix(1_024))
    }
}

public enum SOMAControlSettingsStoreError: LocalizedError, Equatable, Sendable {
    case unsupportedSchema(Int)
    case corruptSettings
    case insecurePermissions

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version):
            "Unsupported SOMA settings schema: \(version)"
        case .corruptSettings:
            "SOMA settings could not be decoded"
        case .insecurePermissions:
            "SOMA settings permissions must be owner-only"
        }
    }
}

public struct SOMAControlSettingsStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL = Self.defaultURL()) {
        self.fileURL = fileURL
    }

    public static func defaultURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SOMA/settings.json")
    }

    public func load() throws -> SOMAControlSettings {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else { return .init() }
        try requireOwnerOnlyPermissions()
        do {
            let settings = try JSONDecoder().decode(
                SOMAControlSettings.self,
                from: Data(contentsOf: fileURL, options: .mappedIfSafe)
            )
            guard settings.isCurrentSchema else {
                throw SOMAControlSettingsStoreError.unsupportedSchema(settings.schemaVersion)
            }
            return settings
        } catch let error as SOMAControlSettingsStoreError {
            throw error
        } catch {
            throw SOMAControlSettingsStoreError.corruptSettings
        }
    }

    public func save(_ settings: SOMAControlSettings) throws {
        guard settings.isCurrentSchema else {
            throw SOMAControlSettingsStoreError.unsupportedSchema(settings.schemaVersion)
        }
        let fileManager = FileManager.default
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func requireOwnerOnlyPermissions() throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o077 == 0 else {
            throw SOMAControlSettingsStoreError.insecurePermissions
        }
    }
}
