import XCTest
@testable import SOMACore

final class SOMAEnvSettingsTests: XCTestCase {
    func testEnvStoreRoundTrip() throws {
        let dir = NSTemporaryDirectory() + "envstore-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let url = URL(fileURLWithPath: dir).appendingPathComponent(".env")

        let settings = SOMAEnvSettings(
            ollamaAPIKey: "sk-test-123",
            ollamaHost: "http://192.168.1.5:11434",
            l1Model: "gemma4:31b-cloud",
            l0TrackingEnabled: false,
            l0ExploreEnabled: true,
            l1ReasoningCadenceSeconds: 180,
            l1CuriosityCollectionEnabled: true,
            l1CollectionIntervalHours: 6,
            l0CameraVerticalPlacement: .belowEyeLevel,
            l2ProactiveOpeningsEnabled: false
        )
        let store = SOMAEnvStore(fileURL: url)
        try store.save(settings)
        let loaded = try store.load()
        XCTAssertEqual(loaded, settings)

        // Hand-edit tolerance: missing keys fall back to defaults.
        try store.save(.init())
        let defaults = try store.load()
        XCTAssertEqual(defaults.ollamaHost, "http://127.0.0.1:11434")
        XCTAssertEqual(defaults.l1ReasoningCadenceSeconds, 150)
        XCTAssertTrue(defaults.l1CuriosityCollectionEnabled)
        XCTAssertEqual(defaults.l1CollectionIntervalHours, 24)
        XCTAssertEqual(
            defaults.l0EyeContactFreshnessMilliseconds,
            SOMAEnvSettings.defaultEyeContactFreshnessMilliseconds
        )
        XCTAssertEqual(defaults.l0EyeContactPupilThreshold, 0.9)
        XCTAssertEqual(defaults.l0CameraVerticalPlacement, .eyeLevel)
    }

    func testZeroSpokenOpeningTendencyRoundTripsWithoutBecomingDefault() throws {
        let dir = NSTemporaryDirectory() + "envstore-zero-tendency-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let url = URL(fileURLWithPath: dir).appendingPathComponent(".env")
        var settings = SOMAEnvSettings()
        settings.l1SpokenOpeningTendency = 0

        let store = SOMAEnvStore(fileURL: url)
        try store.save(settings)

        XCTAssertEqual(try store.load().l1SpokenOpeningTendency, 0)
    }

    func testInvalidOllamaConfigurationIsRejectedBeforePersistence() throws {
        let dir = NSTemporaryDirectory() + "envstore-invalid-ollama-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let url = URL(fileURLWithPath: dir).appendingPathComponent(".env")
        let store = SOMAEnvStore(fileURL: url)

        var invalidHost = SOMAEnvSettings()
        invalidHost.ollamaHost = "http://"
        XCTAssertThrowsError(try store.save(invalidHost)) { error in
            guard case SOMAEnvStoreError.invalidValue = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        var invalidModel = SOMAEnvSettings()
        invalidModel.l1Model = ""
        XCTAssertThrowsError(try store.save(invalidModel)) { error in
            guard case SOMAEnvStoreError.invalidValue = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        var invalidPort = SOMAEnvSettings()
        invalidPort.ollamaHost = "http://127.0.0.1:99999"
        XCTAssertThrowsError(try store.save(invalidPort)) { error in
            guard case SOMAEnvStoreError.invalidValue = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        var shellUnsafeHost = SOMAEnvSettings()
        shellUnsafeHost.ollamaHost = "http://host$(id):11434"
        XCTAssertThrowsError(try store.save(shellUnsafeHost)) { error in
            guard case SOMAEnvStoreError.invalidValue = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testOllamaHostIsCanonicalizedBeforeWritingShellEnvironment() throws {
        let dir = NSTemporaryDirectory() + "envstore-canonical-ollama-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let url = URL(fileURLWithPath: dir).appendingPathComponent(".env")
        var settings = SOMAEnvSettings()
        settings.ollamaHost = "  http://127.0.0.1:11434/  "

        let store = SOMAEnvStore(fileURL: url)
        try store.save(settings)

        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(raw.contains("OLLAMA_HOST=http://127.0.0.1:11434\n"))
        XCTAssertEqual(try store.load().ollamaHost, SOMAEnvSettings.defaultOllamaHost)
    }

    func testMalformedOrOutOfRangeManagedValuesAreRejectedOnLoad() throws {
        let dir = NSTemporaryDirectory() + "envstore-invalid-managed-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let url = URL(fileURLWithPath: dir).appendingPathComponent(".env")
        let store = SOMAEnvStore(fileURL: url)

        for content in [
            "SOMA_L0_TRACKING_ENABLED=perhaps\n",
            "SOMA_L1_REASONING_CADENCE_SECONDS=5\n",
            "SOMA_L0_EYE_CONTACT_FRESHNESS_MS=not-a-number\n",
            "SOMA_L0_CAMERA_VERTICAL_PLACEMENT=under_the_desk\n",
            "SOMA_L2_CODEX_SANDBOX=unrestricted\n",
        ] {
            try content.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            XCTAssertThrowsError(try store.load(), "accepted invalid managed value: \(content)") { error in
                guard case SOMAEnvStoreError.invalidValue = error else {
                    return XCTFail("unexpected error: \(error)")
                }
            }
        }
    }

    func testEnvStoreMigratesLegacyReasoningCadence() throws {
        let dir = NSTemporaryDirectory() + "envstore-legacy-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let url = URL(fileURLWithPath: dir).appendingPathComponent(".env")
        try "SOMA_L1_IDLE_CADENCE_SECONDS=180\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        let loaded = try SOMAEnvStore(fileURL: url).load()

        XCTAssertEqual(loaded.l1ReasoningCadenceSeconds, 180)
    }

    func testEnvStorePreservesRuntimeAndHardwareAssignments() throws {
        let dir = NSTemporaryDirectory() + "envstore-runtime-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let url = URL(fileURLWithPath: dir).appendingPathComponent(".env")
        try """
        OLLAMA_HOST=http://old-host:11434
        SOMA_VIDEO_ID=auto
        SOMA_AUDIO_ID=auto
        SOMA_ENABLE_MOTION=0
        SOMA_ENABLE_L2_LIVE_VOICE=0
        SOMA_L05_VLM_MODEL="/path with spaces/model"
        SOMA_L1_IDLE_CADENCE_SECONDS=90
        """.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        let store = SOMAEnvStore(fileURL: url)
        var settings = try store.load()
        settings.ollamaHost = "http://new-host:11434"
        try store.save(settings)

        let saved = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(saved.contains("OLLAMA_HOST=http://new-host:11434"))
        XCTAssertTrue(saved.contains("SOMA_VIDEO_ID=auto"))
        XCTAssertTrue(saved.contains("SOMA_AUDIO_ID=auto"))
        XCTAssertTrue(saved.contains("SOMA_ENABLE_MOTION=0"))
        XCTAssertTrue(saved.contains("SOMA_ENABLE_L2_LIVE_VOICE=0"))
        XCTAssertTrue(saved.contains("SOMA_L05_VLM_MODEL=\"/path with spaces/model\""))
        XCTAssertFalse(saved.contains("SOMA_L1_IDLE_CADENCE_SECONDS"))
    }
}
