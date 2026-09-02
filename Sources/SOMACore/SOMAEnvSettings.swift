import Foundation

public enum SOMACameraVerticalPlacement: String, Codable, CaseIterable, Equatable, Sendable {
    case belowEyeLevel = "below_eye_level"
    case eyeLevel = "eye_level"
    case aboveEyeLevel = "above_eye_level"

    /// Expected signed vertical pupil displacement for a person looking at the
    /// lens. Vision coordinates are positive toward the upper eyelid.
    public var expectedDirectPupilOffsetY: Double {
        switch self {
        case .belowEyeLevel: -0.10
        case .eyeLevel: 0
        case .aboveEyeLevel: 0.10
        }
    }

    public var displayName: String {
        switch self {
        case .belowEyeLevel: "Below eye level"
        case .eyeLevel: "At eye level"
        case .aboveEyeLevel: "Above eye level"
        }
    }
}

/// Layer (L0/L2/L3) and Ollama configuration that is managed as a plain
/// `.env` file so it can be sourced by the launch agent shell script before
/// the runtime binary starts. Keeping these as environment variables means the
/// running process can read them directly with no extra plumbing, and the
/// secret (Ollama API key) is held in an owner-only file rather than a JSON
/// settings blob.
///
/// Each field maps to a `KEY=VALUE` line. Values are written verbatim and read
/// back line-by-line. Runtime and hardware keys outside this typed control
/// surface are preserved when the Control Center saves the file.
public struct SOMAEnvSettings: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let defaultOllamaHost = "http://127.0.0.1:11434"
    public static let defaultL1Model = "gemma4:31b-cloud"
    public static let defaultEyeContactFreshnessMilliseconds = 450.0
    public static let supportedCuriosityIntervals: Set<Double> = [6, 12, 24, 168]

    public var schemaVersion: Int

    // MARK: Ollama — cloud access
    /// Ollama API key used by the hosted web_search / web_fetch endpoints.
    public var ollamaAPIKey: String
    /// Base HTTP host for the local Ollama server.
    public var ollamaHost: String
    /// The L1 conscious-stream model served by Ollama.
    public var l1Model: String

    // MARK: L0 — perception & attention
    /// Whether the gimbal may track a verified human face (native tracking).
    public var l0TrackingEnabled: Bool
    /// Whether the gimbal may autonomously explore when no verified target is
    /// present.
    public var l0ExploreEnabled: Bool
    /// Whether to time-limit a face fixation that never becomes engagement.
    /// 0 (default) keeps gazing indefinitely; a positive value tolerates
    /// non-response for that many seconds before releasing the face lock and
    /// resuming scanning. The judgment-based E2B release is unaffected.
    public var l0FaceFixationReleaseSeconds: Double

    // MARK: L1 — conscious stream
    /// The single baseline interval (seconds) for L1 situation reasoning.
    /// Event-driven local-vision wake proposals remain independent of this
    /// interval.
    public var l1ReasoningCadenceSeconds: Double
    /// Whether the L1 curiosity collector performs periodic web collection on
    /// the topics the model is curious about and feeds them back into openers.
    public var l1CuriosityCollectionEnabled: Bool
    /// How often (hours) the curiosity collector re-searches its topics.
    public var l1CollectionIntervalHours: Double
    /// How readily L1 opens a spoken conversation despite the person appearing
    /// busy/focused. 0 = conservative (stay quiet when busy), 1 = talkative
    /// (open even when the person looks focused on something).
    public var l1SpokenOpeningTendency: Double
    /// BCP-47 language tag L1 uses to address a person who has no stored
    /// preferred language. Defaults to "ko" (Korean).
    public var l1DefaultLanguage: String
    /// Minimum local-vision (E2B) wake score (0...1) for a wake proposal to
    /// reach L1. E2B is the low-latency on-device vision layer (L0).
    public var l0E2BWakeScore: Double
    /// Minimum local-vision (E2B) confidence (0...1) for a wake proposal to
    /// reach L1.
    public var l0E2BWakeConfidence: Double
    /// Maximum interval (ms) before the on-device semantic observer refreshes
    /// an otherwise stable scene. Workspace deltas, not this sampling interval,
    /// decide whether L1a is awakened.
    public var l0E2BWakeIntervalMilliseconds: Double
    /// Whether the local-vision (E2B) layer is launched at all. E2B is a core
    /// dependency: it supplies the auxiliary semantic cues, low-social-presence
    /// judgment releases, object recognition, space transitions, and L1 wake
    /// proposals. Defaults to true.
    public var l05Enabled: Bool
    /// How long (ms) a fresh directed eye-contact observation remains valid for
    /// authorizing a spoken opening. Lower = stricter (requires very recent
    /// gaze); higher = more lenient. Defaults to 450.
    public var l0EyeContactFreshnessMilliseconds: Double
    /// Scales the pupil-centering thresholds that decide directed eye contact.
    /// 1.0 uses the classifier's base limits. Lower = stricter (pupil must be
    /// more centered); higher = more lenient. Defaults to 0.9.
    public var l0EyeContactPupilThreshold: Double
    /// Lens position relative to the participant's eyes. This shifts the
    /// expected vertical pupil ray without weakening downward-gaze rejection.
    public var l0CameraVerticalPlacement: SOMACameraVerticalPlacement
    /// Minimum confidence (0...1) for the on-device YOLO object detector to
    /// report an object. Higher = fewer false positives (e.g. phantom
    /// toothbrushes), lower = more recall. Defaults to 0.5.
    public var l0YoloConfidenceThreshold: Double
    /// How long (hours) raw short-term conversation transcripts are retained
    /// before L1 consolidation. Defaults to 24.
    public var memoryShortTermRetentionHours: Double

    // MARK: L2 — human interaction & conversation
    /// Whether L1 may initiate proactive spoken openings that hand off to the
    /// L2 live-voice conversation runtime.
    public var l2ProactiveOpeningsEnabled: Bool
    /// When true, L1 may proactively open a spoken conversation with a person
    /// it has not yet recognized (an unknown face), treating them as a
    /// pseudonymous participant. Defaults to false.
    public var l1OpenWithUnknownIdentity: Bool
    /// The Codex app-server sandbox level used for L2 live-voice sessions.
    /// One of "read-only", "workspace-write", or "danger-full-access".
    public var l2CodexSandbox: String
    /// When true, only the local administrator gets the configured Codex
    /// sandbox; every other participant is restricted to read-only.
    public var l2CodexAdminOnly: Bool

    public init(
        schemaVersion: Int = SOMAEnvSettings.currentSchemaVersion,
        ollamaAPIKey: String = "",
        ollamaHost: String = SOMAEnvSettings.defaultOllamaHost,
        l1Model: String = SOMAEnvSettings.defaultL1Model,
        l0TrackingEnabled: Bool = true,
        l0ExploreEnabled: Bool = true,
        l0FaceFixationReleaseSeconds: Double = 0,
        l1ReasoningCadenceSeconds: Double = 150,
        l1CuriosityCollectionEnabled: Bool = true,
        l1CollectionIntervalHours: Double = 24,
        l1SpokenOpeningTendency: Double = 0.7,
        l1DefaultLanguage: String = "ko",
        l0E2BWakeScore: Double = 0.65,
        l0E2BWakeConfidence: Double = 0.55,
        l0E2BWakeIntervalMilliseconds: Double = 5_000,
        l05Enabled: Bool = true,
        l0EyeContactFreshnessMilliseconds: Double = SOMAEnvSettings.defaultEyeContactFreshnessMilliseconds,
        l0EyeContactPupilThreshold: Double = 0.9,
        l0CameraVerticalPlacement: SOMACameraVerticalPlacement = .eyeLevel,
        l0YoloConfidenceThreshold: Double = 0.5,
        memoryShortTermRetentionHours: Double = 24,
        l2ProactiveOpeningsEnabled: Bool = true,
        l1OpenWithUnknownIdentity: Bool = false,
        l2CodexSandbox: String = "danger-full-access",
        l2CodexAdminOnly: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.ollamaAPIKey = ollamaAPIKey
        self.ollamaHost = ollamaHost
        self.l1Model = l1Model
        self.l0TrackingEnabled = l0TrackingEnabled
        self.l0ExploreEnabled = l0ExploreEnabled
        self.l0FaceFixationReleaseSeconds = l0FaceFixationReleaseSeconds
        self.l1ReasoningCadenceSeconds = l1ReasoningCadenceSeconds
        self.l1CuriosityCollectionEnabled = l1CuriosityCollectionEnabled
        self.l1CollectionIntervalHours = l1CollectionIntervalHours
        self.l1SpokenOpeningTendency = l1SpokenOpeningTendency
        self.l1DefaultLanguage = l1DefaultLanguage
        self.l0E2BWakeScore = l0E2BWakeScore
        self.l0E2BWakeConfidence = l0E2BWakeConfidence
        self.l0E2BWakeIntervalMilliseconds = l0E2BWakeIntervalMilliseconds
        self.l05Enabled = l05Enabled
        self.l0EyeContactFreshnessMilliseconds = l0EyeContactFreshnessMilliseconds
        self.l0EyeContactPupilThreshold = l0EyeContactPupilThreshold
        self.l0CameraVerticalPlacement = l0CameraVerticalPlacement
        self.l0YoloConfidenceThreshold = l0YoloConfidenceThreshold
        self.memoryShortTermRetentionHours = memoryShortTermRetentionHours
        self.l2ProactiveOpeningsEnabled = l2ProactiveOpeningsEnabled
        self.l1OpenWithUnknownIdentity = l1OpenWithUnknownIdentity
        self.l2CodexSandbox = l2CodexSandbox
        self.l2CodexAdminOnly = l2CodexAdminOnly
    }

    public func validate() throws {
        let host = ollamaHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeHostCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".:_-[]/"))
        guard host == ollamaHost,
              host.unicodeScalars.allSatisfy(safeHostCharacters.contains),
              let components = URLComponents(string: host),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.port.map({ (1 ... 65_535).contains($0) }) ?? true,
              components.path.isEmpty || components.path == "/" else {
            throw SOMAEnvStoreError.invalidValue("Enter an Ollama base URL such as http://127.0.0.1:11434")
        }
        let model = l1Model.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowedModelCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._/:@-"))
        guard model == l1Model,
              !model.isEmpty,
              model.count <= 96,
              model.unicodeScalars.allSatisfy(allowedModelCharacters.contains) else {
            throw SOMAEnvStoreError.invalidValue("Enter a valid Ollama model name")
        }
        let safeSecretCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard ollamaAPIKey.isEmpty
                || ollamaAPIKey.unicodeScalars.allSatisfy(safeSecretCharacters.contains) else {
            throw SOMAEnvStoreError.invalidValue("The Ollama API key contains unsupported characters")
        }
        let languagePattern = #"^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$"#
        guard l1DefaultLanguage.range(of: languagePattern, options: .regularExpression) != nil else {
            throw SOMAEnvStoreError.invalidValue("Enter a valid default language tag")
        }
        guard Self.supportedCuriosityIntervals.contains(l1CollectionIntervalHours) else {
            throw SOMAEnvStoreError.invalidValue("Choose a supported curiosity collection interval")
        }
        guard l0FaceFixationReleaseSeconds.isFinite,
              (0 ... 120).contains(l0FaceFixationReleaseSeconds),
              l1ReasoningCadenceSeconds.isFinite,
              (30 ... 600).contains(l1ReasoningCadenceSeconds),
              l1SpokenOpeningTendency.isFinite,
              (0 ... 1).contains(l1SpokenOpeningTendency),
              l0E2BWakeScore.isFinite,
              (0.1 ... 0.95).contains(l0E2BWakeScore),
              l0E2BWakeConfidence.isFinite,
              (0.1 ... 0.95).contains(l0E2BWakeConfidence),
              l0E2BWakeIntervalMilliseconds.isFinite,
              (2_000 ... 60_000).contains(l0E2BWakeIntervalMilliseconds),
              l0EyeContactFreshnessMilliseconds.isFinite,
              (100 ... 2_000).contains(l0EyeContactFreshnessMilliseconds),
              l0EyeContactPupilThreshold.isFinite,
              (0.5 ... 2).contains(l0EyeContactPupilThreshold),
              l0YoloConfidenceThreshold.isFinite,
              (0.1 ... 0.95).contains(l0YoloConfidenceThreshold),
              memoryShortTermRetentionHours.isFinite,
              (1 ... 24).contains(memoryShortTermRetentionHours),
              ["read-only", "workspace-write", "danger-full-access"].contains(l2CodexSandbox) else {
            throw SOMAEnvStoreError.invalidValue("One or more layer settings are outside their supported range")
        }
    }

    public func canonicalizedForPersistence() -> SOMAEnvSettings {
        var normalized = self
        normalized.ollamaHost = ollamaHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.ollamaHost.hasSuffix("/") {
            normalized.ollamaHost.removeLast()
        }
        normalized.l1Model = l1Model.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.l1DefaultLanguage = l1DefaultLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized
    }

    /// Lines written to the `.env` file. Keys that have no value (empty secret)
    /// are still written as `KEY=` so the file stays self-documenting.
    func lines() -> [String] {
        [
            "# SOMA layer (L0/L1/L2) and Ollama configuration.",
            "# Managed by the SOMA Control Center. Restart SOMA to apply changes.",
            "OLLAMA_API_KEY=\(ollamaAPIKey)",
            "OLLAMA_HOST=\(ollamaHost)",
            "SOMA_L1_MODEL=\(l1Model)",
            "SOMA_L0_TRACKING_ENABLED=\(l0TrackingEnabled ? "true" : "false")",
            "SOMA_L0_EXPLORE_ENABLED=\(l0ExploreEnabled ? "true" : "false")",
            "SOMA_L0_FIXATION_RELEASE_SECONDS=\(String(format: "%g", l0FaceFixationReleaseSeconds))",
            "SOMA_L1_REASONING_CADENCE_SECONDS=\(String(format: "%g", l1ReasoningCadenceSeconds))",
            "SOMA_L1_CURIOSITY_ENABLED=\(l1CuriosityCollectionEnabled ? "true" : "false")",
            "SOMA_L1_CURIOSITY_INTERVAL_HOURS=\(String(format: "%g", l1CollectionIntervalHours))",
            "SOMA_L1_SPOKEN_OPENING_TENDENCY=\(String(format: "%g", l1SpokenOpeningTendency))",
            "SOMA_L1_DEFAULT_LANGUAGE=\(l1DefaultLanguage)",
            "SOMA_L0_E2B_WAKE_SCORE=\(String(format: "%g", l0E2BWakeScore))",
            "SOMA_L0_E2B_WAKE_CONFIDENCE=\(String(format: "%g", l0E2BWakeConfidence))",
            // Retain the deployed key for settings migration; it now controls
            // perception refresh rather than a consciousness wake cooldown.
            "SOMA_L0_E2B_WAKE_INTERVAL_MS=\(String(format: "%g", l0E2BWakeIntervalMilliseconds))",
            "SOMA_ENABLE_L05_VLM=\(l05Enabled ? "1" : "0")",
            "SOMA_L0_EYE_CONTACT_FRESHNESS_MS=\(String(format: "%g", l0EyeContactFreshnessMilliseconds))",
            "SOMA_L0_EYE_CONTACT_PUPIL_THRESHOLD=\(String(format: "%g", l0EyeContactPupilThreshold))",
            "SOMA_L0_CAMERA_VERTICAL_PLACEMENT=\(l0CameraVerticalPlacement.rawValue)",
            "SOMA_YOLO_CONFIDENCE_THRESHOLD=\(String(format: "%g", l0YoloConfidenceThreshold))",
            "SOMA_MEMORY_SHORT_TERM_RETENTION_HOURS=\(String(format: "%g", memoryShortTermRetentionHours))",
            "SOMA_L2_PROACTIVE_OPENINGS=\(l2ProactiveOpeningsEnabled ? "true" : "false")",
            "SOMA_L1_OPEN_WITH_UNKNOWN=\(l1OpenWithUnknownIdentity ? "true" : "false")",
            "SOMA_L2_CODEX_SANDBOX=\(l2CodexSandbox)",
            "SOMA_L2_CODEX_ADMIN_ONLY=\(l2CodexAdminOnly ? "true" : "false")",
        ]
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case ollamaAPIKey
        case ollamaHost
        case l1Model
        case l0TrackingEnabled
        case l0ExploreEnabled
        case l0FaceFixationReleaseSeconds
        case l1ReasoningCadenceSeconds
        case l1CuriosityCollectionEnabled
        case l1CollectionIntervalHours
        case l1SpokenOpeningTendency
        case l1DefaultLanguage
        case l0E2BWakeScore
        case l0E2BWakeConfidence
        case l0E2BWakeIntervalMilliseconds
        case l05Enabled
        case l0EyeContactFreshnessMilliseconds
        case l0EyeContactPupilThreshold
        case l0CameraVerticalPlacement
        case l0YoloConfidenceThreshold
        case memoryShortTermRetentionHours
        case l2ProactiveOpeningsEnabled
        case l1OpenWithUnknownIdentity
        case l2CodexSandbox
        case l2CodexAdminOnly
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        ollamaAPIKey = try values.decodeIfPresent(String.self, forKey: .ollamaAPIKey) ?? ""
        ollamaHost = try values.decodeIfPresent(String.self, forKey: .ollamaHost) ?? Self.defaultOllamaHost
        l1Model = try values.decodeIfPresent(String.self, forKey: .l1Model) ?? Self.defaultL1Model
        l0TrackingEnabled = try values.decodeIfPresent(Bool.self, forKey: .l0TrackingEnabled) ?? true
        l0ExploreEnabled = try values.decodeIfPresent(Bool.self, forKey: .l0ExploreEnabled) ?? true
        l0FaceFixationReleaseSeconds = try values.decodeIfPresent(Double.self, forKey: .l0FaceFixationReleaseSeconds) ?? 0
        l1ReasoningCadenceSeconds = try values.decodeIfPresent(Double.self, forKey: .l1ReasoningCadenceSeconds) ?? 150
        l1CuriosityCollectionEnabled = try values.decodeIfPresent(Bool.self, forKey: .l1CuriosityCollectionEnabled) ?? true
        l1CollectionIntervalHours = try values.decodeIfPresent(Double.self, forKey: .l1CollectionIntervalHours) ?? 24
        l1SpokenOpeningTendency = try values.decodeIfPresent(Double.self, forKey: .l1SpokenOpeningTendency) ?? 0.7
        l1DefaultLanguage = try values.decodeIfPresent(String.self, forKey: .l1DefaultLanguage) ?? "ko"
        l0E2BWakeScore = try values.decodeIfPresent(Double.self, forKey: .l0E2BWakeScore) ?? 0.65
        l0E2BWakeConfidence = try values.decodeIfPresent(Double.self, forKey: .l0E2BWakeConfidence) ?? 0.55
        l0E2BWakeIntervalMilliseconds = try values.decodeIfPresent(Double.self, forKey: .l0E2BWakeIntervalMilliseconds) ?? 5_000
        l05Enabled = try values.decodeIfPresent(Bool.self, forKey: .l05Enabled) ?? true
        l0EyeContactFreshnessMilliseconds = try values.decodeIfPresent(Double.self, forKey: .l0EyeContactFreshnessMilliseconds) ?? Self.defaultEyeContactFreshnessMilliseconds
        l0EyeContactPupilThreshold = try values.decodeIfPresent(Double.self, forKey: .l0EyeContactPupilThreshold) ?? 0.9
        l0CameraVerticalPlacement = try values.decodeIfPresent(
            SOMACameraVerticalPlacement.self,
            forKey: .l0CameraVerticalPlacement
        ) ?? .eyeLevel
        l0YoloConfidenceThreshold = try values.decodeIfPresent(Double.self, forKey: .l0YoloConfidenceThreshold) ?? 0.5
        memoryShortTermRetentionHours = try values.decodeIfPresent(Double.self, forKey: .memoryShortTermRetentionHours) ?? 24
        l2ProactiveOpeningsEnabled = try values.decodeIfPresent(Bool.self, forKey: .l2ProactiveOpeningsEnabled) ?? true
        l1OpenWithUnknownIdentity = try values.decodeIfPresent(Bool.self, forKey: .l1OpenWithUnknownIdentity) ?? false
        let sandbox = try values.decodeIfPresent(String.self, forKey: .l2CodexSandbox) ?? "danger-full-access"
        l2CodexSandbox = sandbox
        l2CodexAdminOnly = try values.decodeIfPresent(Bool.self, forKey: .l2CodexAdminOnly) ?? false
        try validate()
    }
}

public enum SOMAEnvStoreError: LocalizedError, Equatable, Sendable {
    case corruptEnv
    case insecurePermissions
    case invalidValue(String)

    public var errorDescription: String? {
        switch self {
        case .corruptEnv:
            "SOMA .env could not be read"
        case .insecurePermissions:
            "SOMA .env permissions must be owner-only"
        case let .invalidValue(message):
            message
        }
    }
}

/// Reads and writes the SOMA layer configuration as a `.env` file with
/// owner-only permissions. The typed settings replace their managed keys while
/// other valid environment assignments are retained verbatim.
public struct SOMAEnvStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL = Self.defaultURL()) {
        self.fileURL = fileURL
    }

    public static func defaultURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SOMA/.env")
    }

    public func load() throws -> SOMAEnvSettings {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else { return .init() }
        try requireOwnerOnlyPermissions()
        let raw: String
        do {
            raw = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            throw SOMAEnvStoreError.corruptEnv
        }
        var values: [String: String] = [:]
        for rawLine in raw.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let equalIndex = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equalIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: equalIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            // Strip surrounding quotes if present.
            var clean = value
            if clean.count >= 2, clean.first == "\"", clean.last == "\"" {
                clean = String(clean.dropFirst().dropLast())
            }
            values[key] = clean
        }
        let settings = SOMAEnvSettings(
            ollamaAPIKey: values["OLLAMA_API_KEY"] ?? "",
            ollamaHost: values["OLLAMA_HOST"] ?? SOMAEnvSettings.defaultOllamaHost,
            l1Model: values["SOMA_L1_MODEL"] ?? SOMAEnvSettings.defaultL1Model,
            l0TrackingEnabled: try boolValue(values["SOMA_L0_TRACKING_ENABLED"], key: "SOMA_L0_TRACKING_ENABLED", default: true),
            l0ExploreEnabled: try boolValue(values["SOMA_L0_EXPLORE_ENABLED"], key: "SOMA_L0_EXPLORE_ENABLED", default: true),
            l0FaceFixationReleaseSeconds: try doubleValue(values["SOMA_L0_FIXATION_RELEASE_SECONDS"], key: "SOMA_L0_FIXATION_RELEASE_SECONDS", default: 0),
            l1ReasoningCadenceSeconds: try doubleValue(
                values["SOMA_L1_REASONING_CADENCE_SECONDS"] ?? values["SOMA_L1_IDLE_CADENCE_SECONDS"],
                key: "SOMA_L1_REASONING_CADENCE_SECONDS",
                default: 150
            ),
            l1CuriosityCollectionEnabled: try boolValue(values["SOMA_L1_CURIOSITY_ENABLED"], key: "SOMA_L1_CURIOSITY_ENABLED", default: true),
            l1CollectionIntervalHours: try doubleValue(values["SOMA_L1_CURIOSITY_INTERVAL_HOURS"], key: "SOMA_L1_CURIOSITY_INTERVAL_HOURS", default: 24),
            l1SpokenOpeningTendency: try doubleValue(values["SOMA_L1_SPOKEN_OPENING_TENDENCY"], key: "SOMA_L1_SPOKEN_OPENING_TENDENCY", default: 0.7),
            l1DefaultLanguage: values["SOMA_L1_DEFAULT_LANGUAGE"] ?? "ko",
            l0E2BWakeScore: try doubleValue(values["SOMA_L0_E2B_WAKE_SCORE"], key: "SOMA_L0_E2B_WAKE_SCORE", default: 0.65),
            l0E2BWakeConfidence: try doubleValue(values["SOMA_L0_E2B_WAKE_CONFIDENCE"], key: "SOMA_L0_E2B_WAKE_CONFIDENCE", default: 0.55),
            l0E2BWakeIntervalMilliseconds: try doubleValue(values["SOMA_L0_E2B_WAKE_INTERVAL_MS"], key: "SOMA_L0_E2B_WAKE_INTERVAL_MS", default: 5_000),
            l05Enabled: try boolValue(values["SOMA_ENABLE_L05_VLM"], key: "SOMA_ENABLE_L05_VLM", default: true),
            l0EyeContactFreshnessMilliseconds: try doubleValue(
                values["SOMA_L0_EYE_CONTACT_FRESHNESS_MS"],
                key: "SOMA_L0_EYE_CONTACT_FRESHNESS_MS",
                default: SOMAEnvSettings.defaultEyeContactFreshnessMilliseconds
            ),
            l0EyeContactPupilThreshold: try doubleValue(values["SOMA_L0_EYE_CONTACT_PUPIL_THRESHOLD"], key: "SOMA_L0_EYE_CONTACT_PUPIL_THRESHOLD", default: 0.9),
            l0CameraVerticalPlacement: try cameraVerticalPlacement(
                values["SOMA_L0_CAMERA_VERTICAL_PLACEMENT"]
            ),
            l0YoloConfidenceThreshold: try doubleValue(values["SOMA_YOLO_CONFIDENCE_THRESHOLD"], key: "SOMA_YOLO_CONFIDENCE_THRESHOLD", default: 0.5),
            memoryShortTermRetentionHours: try doubleValue(values["SOMA_MEMORY_SHORT_TERM_RETENTION_HOURS"], key: "SOMA_MEMORY_SHORT_TERM_RETENTION_HOURS", default: 24),
            l2ProactiveOpeningsEnabled: try boolValue(values["SOMA_L2_PROACTIVE_OPENINGS"], key: "SOMA_L2_PROACTIVE_OPENINGS", default: true),
            l1OpenWithUnknownIdentity: try boolValue(values["SOMA_L1_OPEN_WITH_UNKNOWN"], key: "SOMA_L1_OPEN_WITH_UNKNOWN", default: false),
            l2CodexSandbox: values["SOMA_L2_CODEX_SANDBOX"] ?? "danger-full-access",
            l2CodexAdminOnly: try boolValue(values["SOMA_L2_CODEX_ADMIN_ONLY"], key: "SOMA_L2_CODEX_ADMIN_ONLY", default: false)
        )
        try settings.validate()
        return settings
    }

    public func save(_ settings: SOMAEnvSettings) throws {
        let settings = settings.canonicalizedForPersistence()
        try settings.validate()
        let fileManager = FileManager.default
        let directoryURL = fileURL.deletingLastPathComponent()
        var unmanagedLines: [String] = []
        if fileManager.fileExists(atPath: fileURL.path) {
            try requireOwnerOnlyPermissions()
            let existing: String
            do {
                existing = try String(contentsOf: fileURL, encoding: .utf8)
            } catch {
                throw SOMAEnvStoreError.corruptEnv
            }
            let managedKeys = Set(settings.lines().compactMap(Self.assignmentKey))
                .union(["SOMA_L1_IDLE_CADENCE_SECONDS"])
            unmanagedLines = existing
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
                .filter { line in
                    guard let key = Self.assignmentKey(line) else { return false }
                    return !managedKeys.contains(key)
                }
        }
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        var outputLines = settings.lines()
        if !unmanagedLines.isEmpty {
            outputLines.append("")
            outputLines.append("# Runtime and hardware settings retained outside Control Center.")
            outputLines.append(contentsOf: unmanagedLines)
        }
        let content = outputLines.joined(separator: "\n") + "\n"
        try Data(content.utf8).write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    public func delete() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    private func requireOwnerOnlyPermissions() throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o077 == 0 else {
            throw SOMAEnvStoreError.insecurePermissions
        }
    }

    private static func assignmentKey(_ rawLine: String) -> String? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !line.hasPrefix("#"), let equalIndex = line.firstIndex(of: "=") else {
            return nil
        }
        let key = String(line[..<equalIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty,
              key.allSatisfy({ $0 == "_" || $0.isNumber || ($0.isLetter && $0.isASCII) }) else {
            return nil
        }
        return key
    }

    private func boolValue(_ raw: String?, key: String, default defaultValue: Bool) throws -> Bool {
        guard let raw else { return defaultValue }
        switch raw.lowercased() {
        case "true", "1", "yes", "on": return true
        case "false", "0", "no", "off": return false
        default: throw SOMAEnvStoreError.invalidValue("\(key) must be true or false")
        }
    }

    private func doubleValue(_ raw: String?, key: String, default defaultValue: Double) throws -> Double {
        guard let raw else { return defaultValue }
        guard let value = Double(raw), value.isFinite else {
            throw SOMAEnvStoreError.invalidValue("\(key) must be a finite number")
        }
        return value
    }

    private func cameraVerticalPlacement(_ raw: String?) throws -> SOMACameraVerticalPlacement {
        guard let raw else { return .eyeLevel }
        guard let placement = SOMACameraVerticalPlacement(rawValue: raw) else {
            throw SOMAEnvStoreError.invalidValue(
                "SOMA_L0_CAMERA_VERTICAL_PLACEMENT must be below_eye_level, eye_level, or above_eye_level"
            )
        }
        return placement
    }
}
