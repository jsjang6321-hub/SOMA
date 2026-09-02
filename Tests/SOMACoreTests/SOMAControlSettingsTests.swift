#if canImport(XCTest)
import Foundation
import XCTest
@testable import SOMACore

final class SOMAControlSettingsTests: XCTestCase {
    func testOwnerOnlySettingsPersistRuntimeChoicesAndAdministratorMapping() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soma-control-settings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        let administrator = SOMAAdministratorIdentity(
            entityID: UUID(),
            displayName: "SOMA Owner",
            preferredAddress: "Chief"
        )
        let expected = SOMAControlSettings(
            realtimeVoiceEnabled: true,
            realtimeVoice: .maple,
            realtimeVoiceRequiresEyeContactForEveryTurn: true,
            realtimeVoiceSilenceTimeoutSeconds: 90,
            hermesAgentDelegationEnabled: true,
            hermesAgentWorkspace: "/tmp/soma-worker",
            led: .init(responseMode: .contextual, brightness: 3),
            nativeHumanTrackingEnabled: true,
            autonomousExplorationEnabled: false,
            administrator: administrator
        )
        let store = SOMAControlSettingsStore(fileURL: file)

        try store.save(expected)

        XCTAssertEqual(try store.load(), expected)
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue,
            0o600
        )
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue,
            0o700
        )
    }

    func testRealtimeVoiceSafetySettingsDefaultOnForExistingSettings() throws {
        let legacy = """
        {
          "schemaVersion": 8,
          "realtimeVoiceEnabled": true,
          "realtimeVoice": "maple"
        }
        """
        let migrated = try JSONDecoder().decode(
            SOMAControlSettings.self,
            from: Data(legacy.utf8)
        )
        XCTAssertTrue(migrated.realtimeVoiceRequiresEyeContactForEveryTurn)
        XCTAssertTrue(migrated.administratorOnlyConversations)
        XCTAssertEqual(migrated.realtimeVoiceSilenceTimeoutSeconds, 60)
        XCTAssertTrue(migrated.hermesAgentDelegationEnabled)
        XCTAssertNil(migrated.hermesAgentWorkspace)
        XCTAssertEqual(migrated.schemaVersion, SOMAControlSettings.currentSchemaVersion)
    }

    func testDiscordSettingsPersistWithoutEmbeddingBotToken() throws {
        let settings = SOMAControlSettings(
            discord: .init(
                enabled: true,
                channelID: "123456789012345678",
                labmanagerBotUserID: "987654321098765432",
                labmanagerRoleID: "876543210987654321",
                invocationMention: .managedRole,
                forwardAdministratorSpeech: true,
                readLabmanagerRepliesAloud: true,
                responseTimeoutSeconds: 120
            )
        )
        let data = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(SOMAControlSettings.self, from: data)

        XCTAssertEqual(restored.discord, settings.discord)
        XCTAssertTrue(restored.discord.isConfigured)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("bot-token"))
    }

    func testDiscordConversationFormattingMentionsOnlyAllowlistedBotAndSanitizesSpeech() {
        let text = SOMADiscordConversationClient.normalizedOutboundText(
            "  회의 내용을 정리해 줘  ",
            settings: .init(
                enabled: true,
                channelID: "123456789012345678",
                labmanagerBotUserID: "987654321098765432"
            ),
            conversationID: "thread/unsafe 42",
            correlationID: "vc-0123456789ab"
        )
        XCTAssertEqual(
            text,
            "<@987654321098765432> 🎙️ voice [voice-corr:vc-0123456789ab] [SOMA session:threadunsafe42] 회의 내용을 정리해 줘"
        )
        XCTAssertEqual(
            SOMADiscordConversationClient.spokenReply(
                from: "<@123456789012345678> 결과는 `완료`입니다. [voice-corr:vc-0123456789ab] https://example.com/x"
            ),
            "결과는 완료입니다. 링크"
        )
        XCTAssertNil(SOMADiscordSettings.normalizedSnowflake("../../secret"))
        XCTAssertFalse(SOMADiscordConversationClient.shouldForwardTranscript(
            "SOMA_DISCORD_LABMANAGER_REPLY\nreply: do not loop"
        ))
        XCTAssertTrue(SOMADiscordConversationClient.shouldForwardTranscript("실제 사용자 발화"))
    }

    func testRealtimeVoiceSilenceTimeoutIsPersistedAndBounded() throws {
        var settings = SOMAControlSettings(realtimeVoiceSilenceTimeoutSeconds: 120)
        let restored = try JSONDecoder().decode(
            SOMAControlSettings.self,
            from: JSONEncoder().encode(settings)
        )
        XCTAssertEqual(restored.realtimeVoiceSilenceTimeoutSeconds, 120)

        settings.realtimeVoiceSilenceTimeoutSeconds = 10_000
        let bounded = try JSONDecoder().decode(
            SOMAControlSettings.self,
            from: JSONEncoder().encode(settings)
        )
        XCTAssertEqual(bounded.realtimeVoiceSilenceTimeoutSeconds, 600)
    }

    func testHermesAgentSettingsPersistAndNormalizeWorkspace() throws {
        let settings = SOMAControlSettings(
            hermesAgentDelegationEnabled: true,
            hermesAgentWorkspace: "/tmp/../tmp/soma-worker"
        )
        let restored = try JSONDecoder().decode(
            SOMAControlSettings.self,
            from: JSONEncoder().encode(settings)
        )

        XCTAssertTrue(restored.hermesAgentDelegationEnabled)
        XCTAssertEqual(restored.hermesAgentWorkspace, "/tmp/soma-worker")
        XCTAssertNil(SOMAControlSettings.normalizedAbsolutePath("relative/path"))
    }

    func testRealtimeVoicePickerMatchesCodexAppServerV3Contract() {
        XCTAssertEqual(
            Set(SOMARealtimeVoice.allCases.map(\.rawValue)),
            Set(["juniper", "maple", "spruce", "ember", "vale", "breeze", "arbor", "sol", "cove"])
        )
        XCTAssertEqual(
            SOMARealtimeVoice.voices(with: .female),
            [.juniper, .maple, .vale, .sol]
        )
        XCTAssertEqual(
            SOMARealtimeVoice.voices(with: .male),
            [.spruce, .ember, .breeze, .arbor, .cove]
        )
    }

    func testUnsupportedLegacyRealtimeVoiceMigratesWithoutCorruptingSettings() throws {
        let legacy = """
        {
          "schemaVersion": 9,
          "realtimeVoiceEnabled": true,
          "realtimeVoice": "marin",
          "nativeHumanTrackingEnabled": false
        }
        """
        let migrated = try JSONDecoder().decode(
            SOMAControlSettings.self,
            from: Data(legacy.utf8)
        )

        XCTAssertEqual(migrated.realtimeVoice, .maple)
        XCTAssertFalse(migrated.nativeHumanTrackingEnabled)
        XCTAssertEqual(migrated.schemaVersion, SOMAControlSettings.currentSchemaVersion)
    }

    func testLEDPolicyKeepsReactionBoundedToItsConfiguredStates() {
        XCTAssertTrue(SOMALEDResponseMode.expressive.permits(.exploring))
        XCTAssertFalse(SOMALEDResponseMode.contextual.permits(.humanDetected))
        XCTAssertTrue(SOMALEDResponseMode.contextual.permits(.conversation))
        XCTAssertTrue(SOMALEDResponseMode.quiet.permits(.working))
        XCTAssertTrue(SOMALEDResponseMode.quiet.permits(.conversation))
        XCTAssertFalse(SOMALEDResponseMode.off.permits(.conversation))
    }

    func testLEDSignalsPersistPerStateColorAndCadence() throws {
        let contract = tiny3LiteTestContract()
        var settings = SOMAControlSettings()
        settings.led.signals[.conversation] = .init(color: .green, pattern: .steady)

        let decoded = try JSONDecoder().decode(
            SOMAControlSettings.self,
            from: JSONEncoder().encode(settings)
        )

        XCTAssertEqual(decoded.led.signal(for: .conversation).color, .green)
        XCTAssertEqual(decoded.led.signal(for: .conversation).pattern, .steady)
        XCTAssertEqual(decoded.led.signal(for: .exploring).color, .green)
        XCTAssertEqual(decoded.led.signal(for: .exploring).pattern, .steady)
        XCTAssertEqual(SOMALEDColor.yellow.displayName, "Yellow")
        XCTAssertEqual(SOMALEDColor.green.displayName, "Green")
        XCTAssertEqual(SOMALEDColor.blue.displayName, "Blue")
        XCTAssertEqual(contract.firmwareIndicatorStateID(for: .green), 54)
        XCTAssertFalse(contract.usesFirmwareDefaultIndicator(for: .green))
        XCTAssertEqual(contract.firmwareIndicatorStateID(for: .yellow), 16)
        XCTAssertEqual(contract.firmwareIndicatorStateID(for: .blue), 57)
        XCTAssertEqual(
            decoded.led.signal(for: .contactReady).deviceRendering(for: contract),
            .init(stateID: 57, pattern: .blink)
        )
    }

    func testBlueContactBlinkPreservesItsDevicePalettePosition() {
        let settings = SOMALEDSettings(
            signals: [.contactReady: .init(color: .blue, pattern: .blink)]
        )
        XCTAssertEqual(
            settings.signal(for: .contactReady),
            .init(color: .blue, pattern: .blink)
        )
    }

    func testVoiceSessionDoesNotManufactureContactReadyBlink() {
        let contract = tiny3LiteTestContract()
        let settings = SOMALEDSettings(
            signals: [
                .exploring: .init(color: .green, pattern: .steady),
                .humanDetected: .init(color: .blue, pattern: .steady),
                .contactReady: .init(color: .blue, pattern: .steady),
            ]
        )

        XCTAssertEqual(settings.deviceRendering(for: .humanDetected, on: contract), .init(stateID: 57, pattern: .steady))
        XCTAssertEqual(settings.deviceRendering(for: .contactReady, on: contract), .init(stateID: 57, pattern: .steady))

        let expressiveContact = SOMALEDSettings(
            signals: [.contactReady: .init(color: .blue, pattern: .heartbeat)]
        )
        XCTAssertEqual(expressiveContact.deviceRendering(for: .contactReady, on: contract), .init(stateID: 57, pattern: .heartbeat))
    }

    func testVersionOneSettingsMigrateToStateSignals() throws {
        let legacy = """
        {
          "schemaVersion": 1,
          "realtimeVoiceEnabled": true,
          "realtimeVoice": "maple",
          "led": { "responseMode": "contextual", "brightness": 3 },
          "nativeHumanTrackingEnabled": true,
          "autonomousExplorationEnabled": false
        }
        """

        let migrated = try JSONDecoder().decode(
            SOMAControlSettings.self,
            from: Data(legacy.utf8)
        )

        XCTAssertEqual(migrated.schemaVersion, SOMAControlSettings.currentSchemaVersion)
        XCTAssertEqual(migrated.led.signals.count, SubconsciousIndicatorState.configurationStates.count)
        XCTAssertEqual(migrated.led.signal(for: .conversation).color, .green)
        XCTAssertEqual(migrated.led.signal(for: .conversation).pattern, .steady)
    }

    func testVersionTwoPresetSettingsMigrateToExplicitContactBlink() throws {
        let legacy = """
        {
          "schemaVersion": 2,
          "led": {
            "responseMode": "expressive",
            "brightness": 2,
            "signals": [
              "contact_ready",
              { "preset": "tracking", "pattern": "doubleBlink" }
            ]
          }
        }
        """

        let migrated = try JSONDecoder().decode(
            SOMAControlSettings.self,
            from: Data(legacy.utf8)
        )

        XCTAssertEqual(migrated.schemaVersion, SOMAControlSettings.currentSchemaVersion)
        XCTAssertEqual(migrated.led.signal(for: .contactReady).color, .blue)
        XCTAssertEqual(migrated.led.signal(for: .contactReady).pattern, .blink)
    }

    func testVisibleHostCadenceSurvivesMigrationToTheDevice() throws {
        let legacy = """
        {
          "schemaVersion": 3,
          "led": {
            "signals": [
              "working",
              { "color": "green", "pattern": "heartbeat" }
            ]
          }
        }
        """

        let migrated = try JSONDecoder().decode(
            SOMAControlSettings.self,
            from: Data(legacy.utf8)
        )

        XCTAssertEqual(migrated.led.signal(for: .working).color, .green)
        XCTAssertEqual(migrated.led.signal(for: .working).pattern, .heartbeat)
    }

    func testSchemaFiveSteadyContactReadyMigratesToBlink() throws {
        let legacy = """
        {
          "schemaVersion": 5,
          "led": {
            "signals": [
              "contact_ready",
              { "color": "green", "pattern": "steady" }
            ]
          }
        }
        """

        let migrated = try JSONDecoder().decode(
            SOMAControlSettings.self,
            from: Data(legacy.utf8)
        )

        XCTAssertEqual(migrated.schemaVersion, SOMAControlSettings.currentSchemaVersion)
        XCTAssertEqual(
            migrated.led.signal(for: .contactReady).deviceRendering(for: tiny3LiteTestContract()),
            .init(stateID: 57, pattern: .blink)
        )
    }

    func testSchemaSevenExplicitContactBlinkIsNotOverwrittenByMigration() throws {
        let legacy = """
        {
          "schemaVersion": 7,
          "led": {
            "signals": [
              "contact_ready",
              { "color": "blue", "pattern": "blink" }
            ]
          }
        }
        """

        let migrated = try JSONDecoder().decode(
            SOMAControlSettings.self,
            from: Data(legacy.utf8)
        )

        XCTAssertEqual(
            migrated.led.signal(for: .contactReady),
            .init(color: .blue, pattern: .blink)
        )
    }

    func testLegacyListeningAndSpeakingMigrateToOneConversationSignal() throws {
        let legacy = """
        {
          "schemaVersion": 4,
          "led": {
            "signals": [
              "listening",
              { "color": "blue", "pattern": "steady" },
              "speaking",
              { "color": "green", "pattern": "steady" }
            ]
          }
        }
        """

        let migrated = try JSONDecoder().decode(
            SOMAControlSettings.self,
            from: Data(legacy.utf8)
        )

        XCTAssertEqual(migrated.led.signals.count, SubconsciousIndicatorState.configurationStates.count)
        XCTAssertEqual(migrated.led.signal(for: .conversation).color, .green)
        XCTAssertNil(migrated.led.signals[.listening])
        XCTAssertNil(migrated.led.signals[.speaking])
    }
}
#endif
