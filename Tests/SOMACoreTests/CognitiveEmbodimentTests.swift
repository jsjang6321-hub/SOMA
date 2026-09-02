#if canImport(XCTest)
import Foundation
import XCTest
@testable import SOMACore

final class CognitiveEmbodimentTests: XCTestCase {
    func testGimbalExpressionsExcludeGreetingAndNodMotions() throws {
        XCTAssertEqual(
            SocialGimbalExpression.allCases.map(\.rawValue),
            ["attentive_reframe", "thinking_glance"]
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                SocialGimbalExpression.self,
                from: Data("\"nod\"".utf8)
            )
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                SocialGimbalExpression.self,
                from: Data("\"greeting\"".utf8)
            )
        )
    }

    func testRuntimeShutdownIPCIsLocalAndPayloadFree() throws {
        let suffix = UUID().uuidString.prefix(8)
        let directory = URL(fileURLWithPath: "/private/tmp/soma-runtime-stop-ipc-\(suffix)", isDirectory: true)
        let socketURL = directory.appendingPathComponent("shadow.sock")
        let shutdownRequested = LockedValue(false)
        let server = EmbodimentShadowSocketServer(
            socketURL: socketURL,
            runtimeShutdownHandler: {
                shutdownRequested.set(true)
                return .success(())
            }
        )
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: directory)
        }

        let accepted = try EmbodimentShadowSocketClient.send(
            .init(kind: .runtimeShutdown),
            socketURL: socketURL
        )
        XCTAssertTrue(accepted.ok)
        XCTAssertTrue(shutdownRequested.value)

        let rejected = try EmbodimentShadowSocketClient.send(
            .init(kind: .runtimeShutdown, requestID: "unexpected"),
            socketURL: socketURL
        )
        XCTAssertFalse(rejected.ok)
    }

    func testParticipantCapabilityIsBoundToOwnContextAndAllowsEmbodiedConversation() {
        let store = SOMASessionCapabilityStore(lifetimeSeconds: 60)
        let participant = UUID()
        let someoneElse = UUID()
        let token = store.issue(
            personEntityID: participant,
            authority: .participant,
            at: 1_000_000_000
        )

        switch store.authorize(token: token, scope: .personContext(participant), at: 1_000_000_001) {
        case .success: break
        case let .failure(error): XCTFail("own context unexpectedly denied: \(error)")
        }
        switch store.authorize(token: token, scope: .personContext(someoneElse), at: 1_000_000_001) {
        case .success: XCTFail("participant accessed another person's context")
        case .failure(.personContextDenied): break
        case let .failure(error): XCTFail("wrong context error: \(error)")
        }
        switch store.authorize(token: token, scope: .embodimentControl, at: 1_000_000_001) {
        case .success: break
        case let .failure(error): XCTFail("ordinary embodied conversation unexpectedly denied: \(error)")
        }
        switch store.authorize(token: token, scope: .conversationControl, at: 1_000_000_001) {
        case .success: break
        case let .failure(error): XCTFail("participant could not end their own conversation: \(error)")
        }
        switch store.authorize(token: token, scope: .cognitiveEvidence, at: 1_000_000_001) {
        case .success: break
        case let .failure(error): XCTFail("session could not return its cognitive evidence: \(error)")
        }
    }

    func testHostComputerAuthorityIsAdministratorOnly() {
        let store = SOMASessionCapabilityStore(lifetimeSeconds: 60)
        let participant = store.issue(personEntityID: UUID(), authority: .participant)
        let administrator = store.issue(personEntityID: UUID(), authority: .administrator)

        if case let .failure(error) = store.authorize(token: participant, scope: .hostScreenObservation) {
            XCTAssertEqual(error, .hostScreenObservationDenied)
        } else {
            XCTFail("participant observed the host screen")
        }
        if case let .failure(error) = store.authorize(token: participant, scope: .hostInputControl) {
            XCTAssertEqual(error, .hostInputControlDenied)
        } else {
            XCTFail("participant controlled host input")
        }
        if case .failure = store.authorize(token: administrator, scope: .hostScreenObservation) {
            XCTFail("administrator host-screen authority was denied")
        }
        if case .failure = store.authorize(token: administrator, scope: .hostInputControl) {
            XCTFail("administrator host-input authority was denied")
        }
    }

    func testHostComputerInputSchemaRejectsAmbiguousActions() throws {
        XCTAssertNoThrow(try HostComputerInputAction(
            kind: .click,
            x: 0.25,
            y: 0.75,
            button: .left
        ).validate())
        XCTAssertNoThrow(try HostComputerInputAction(
            kind: .pressKey,
            key: .returnKey,
            modifiers: [.command]
        ).validate())
        XCTAssertThrowsError(try HostComputerInputAction(kind: .click, x: 1.5, y: 0.5).validate())
        XCTAssertThrowsError(try HostComputerInputAction(kind: .scroll, deltaY: 0).validate())
        XCTAssertThrowsError(try HostComputerInputAction(
            kind: .typeText,
            text: "private",
            modifiers: [.command]
        ).validate())
    }

    func testHostComputerInputDecodingDefaultsOptionalModifiers() throws {
        let action = try JSONDecoder().decode(
            HostComputerInputAction.self,
            from: Data(#"{"kind":"click","x":0.25,"y":0.75}"#.utf8)
        )

        XCTAssertEqual(action.kind, .click)
        XCTAssertEqual(action.modifiers, [])
        XCTAssertNoThrow(try action.validate())
    }

    func testHostComputerRequestRejectsInputOnScreenObservation() {
        let request = HostComputerIPCRequest(
            operation: .observeScreen,
            input: .init(kind: .pressKey, key: .escape)
        )

        XCTAssertThrowsError(try request.validate())
    }

    func testHostComputerIPCRequiresExplicitCurrentAdministratorTurn() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soma-host-ipc-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let socketURL = directory.appendingPathComponent("host.sock")
        let store = SOMASessionCapabilityStore(lifetimeSeconds: 60)
        let token = store.issue(personEntityID: UUID(), authority: .administrator)
        let handled = LockedValue(false)
        let server = EmbodimentShadowSocketServer(
            socketURL: socketURL,
            sessionAuthorizationProvider: { supplied, scope in
                store.authorize(token: supplied, scope: scope).mapError { $0 as Error }
            },
            hostComputerProvider: { request in
                handled.set(true)
                return .success(.init(action: request.input.map {
                    HostComputerActionReceipt(kind: $0.kind, performedAtNS: 1)
                }))
            }
        )
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: directory)
        }

        let request = HostComputerIPCRequest(
            operation: .performInput,
            input: .init(kind: .pressKey, key: .escape)
        )
        let withoutTurn = try EmbodimentShadowSocketClient.send(
            .init(
                kind: .hostComputer,
                cognitiveAuthorizationBasis: .explicitRequest,
                hostComputer: request,
                sessionAuthorization: token
            ),
            socketURL: socketURL
        )
        XCTAssertFalse(withoutTurn.ok)
        XCTAssertFalse(handled.value)

        _ = store.observeParticipantTurn(token: token, active: true)
        let accepted = try EmbodimentShadowSocketClient.send(
            .init(
                kind: .hostComputer,
                cognitiveAuthorizationBasis: .explicitRequest,
                hostComputer: request,
                sessionAuthorization: token
            ),
            socketURL: socketURL
        )
        XCTAssertTrue(accepted.ok)
        XCTAssertEqual(accepted.hostComputer?.action?.kind, .pressKey)
        XCTAssertTrue(handled.value)
    }

    func testExplicitCognitiveBasisRequiresCurrentParticipantTurn() {
        let start: UInt64 = 1_000_000_000
        let store = SOMASessionCapabilityStore(
            lifetimeSeconds: 60,
            participantTurnLifetimeSeconds: 10
        )
        let token = store.issue(
            personEntityID: UUID(),
            authority: .participant,
            at: start
        )

        if case .failure(.currentParticipantTurnRequired) = store.authorize(
            token: token,
            scope: .cognitiveBasis(.explicitRequest),
            at: start + 1
        ) {} else {
            XCTFail("explicit request was accepted without current participant speech")
        }
        if case .success = store.authorize(
            token: token,
            scope: .cognitiveBasis(.autonomousGoal),
            at: start + 1
        ) {} else {
            XCTFail("autonomous goal was denied inside a valid session")
        }
        if case .failure(let error) = store.observeParticipantTurn(
            token: token,
            active: true,
            at: start + 2
        ) {
            XCTFail("participant turn could not be bound: \(error)")
        }
        for basis in [
            L2CognitiveAuthorizationBasis.explicitStatement,
            .explicitConsent,
            .explicitRequest,
        ] {
            if case .failure(let error) = store.authorize(
                token: token,
                scope: .cognitiveBasis(basis),
                at: start + 3
            ) {
                XCTFail("current turn did not authorize \(basis): \(error)")
            }
        }
        _ = store.observeParticipantTurn(token: token, active: false, at: start + 4)
        if case .failure(.currentParticipantTurnRequired) = store.authorize(
            token: token,
            scope: .cognitiveBasis(.explicitStatement),
            at: start + 5
        ) {} else {
            XCTFail("completed turn still authorized an explicit statement")
        }
    }

    func testCognitiveTurnBindingAndAuthorizationUseSeparateIPCCommands() throws {
        let suffix = UUID().uuidString.prefix(8)
        let directory = URL(fileURLWithPath: "/private/tmp/soma-cognitive-turn-ipc-\(suffix)", isDirectory: true)
        let socketURL = directory.appendingPathComponent("shadow.sock")
        let token = UUID().uuidString.lowercased()
        let store = SOMASessionCapabilityStore(lifetimeSeconds: 60)
        let issued = store.issue(personEntityID: UUID(), authority: .participant)
        let server = EmbodimentShadowSocketServer(
            socketURL: socketURL,
            cognitiveTurnHandler: { supplied, active in
                store.observeParticipantTurn(token: supplied, active: active)
                    .mapError { $0 as Error }
            },
            sessionAuthorizationProvider: { supplied, scope in
                store.authorize(token: supplied, scope: scope).mapError { $0 as Error }
            }
        )
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: directory)
        }

        let denied = try EmbodimentShadowSocketClient.send(
            .init(
                kind: .cognitiveAuthorization,
                cognitiveAuthorizationBasis: .explicitRequest,
                sessionAuthorization: issued
            ),
            socketURL: socketURL
        )
        XCTAssertFalse(denied.ok)
        let wrong = try EmbodimentShadowSocketClient.send(
            .init(kind: .cognitiveTurnStarted, sessionAuthorization: token),
            socketURL: socketURL
        )
        XCTAssertFalse(wrong.ok)
        let started = try EmbodimentShadowSocketClient.send(
            .init(kind: .cognitiveTurnStarted, sessionAuthorization: issued),
            socketURL: socketURL
        )
        XCTAssertTrue(started.ok)
        let accepted = try EmbodimentShadowSocketClient.send(
            .init(
                kind: .cognitiveAuthorization,
                cognitiveAuthorizationBasis: .explicitRequest,
                sessionAuthorization: issued
            ),
            socketURL: socketURL
        )
        XCTAssertTrue(accepted.ok)
    }

    func testCognitiveActionOutcomeRequiresSessionCapabilityAndReturnsNoExtraAuthority() throws {
        let suffix = UUID().uuidString.prefix(8)
        let directory = URL(fileURLWithPath: "/private/tmp/soma-cognitive-action-ipc-\(suffix)", isDirectory: true)
        let socketURL = directory.appendingPathComponent("shadow.sock")
        let token = UUID().uuidString.lowercased()
        let received = LockedCognitiveAction()
        let goalID = UUID()
        let query = CognitiveActionQuery(
            goalEpisodeID: goalID,
            toolName: "capture_view",
            requestFingerprint: "semantic-capture",
            evidenceIDs: ["turn:visual-reference"]
        )
        let server = EmbodimentShadowSocketServer(
            socketURL: socketURL,
            cognitiveActionQueryProvider: { $0 == query },
            cognitiveActionHandler: {
                received.set($0)
                return true
            },
            sessionAuthorizationProvider: { supplied, scope in
                guard supplied == token, scope == .cognitiveEvidence else {
                    return .failure(EmbodimentIPCError.permissionDenied)
                }
                return .success(())
            }
        )
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: directory)
        }
        let episode = CognitiveActionEpisode(
            goalEpisodeID: goalID,
            sourceLayer: .l2,
            toolName: "capture_view",
            effect: .reversibleEmbodiment,
            purpose: "Resolve the participant's current visual reference.",
            expectedInformationGain: 0.9,
            evidenceIDs: ["turn:visual-reference"],
            status: .succeeded,
            resultFingerprint: "feedface",
            requestFingerprint: "semantic-capture",
            resultSummary: "Current visual evidence was acquired."
        )

        let deniedLookup = try EmbodimentShadowSocketClient.send(
            .init(kind: .cognitiveActionQuery, cognitiveActionQuery: query),
            socketURL: socketURL
        )
        XCTAssertFalse(deniedLookup.ok)

        let acceptedLookup = try EmbodimentShadowSocketClient.send(
            .init(
                kind: .cognitiveActionQuery,
                cognitiveActionQuery: query,
                sessionAuthorization: token
            ),
            socketURL: socketURL
        )
        XCTAssertTrue(acceptedLookup.ok)
        XCTAssertEqual(acceptedLookup.cognitiveActionDuplicate, true)
        XCTAssertNil(acceptedLookup.snapshot)

        let denied = try EmbodimentShadowSocketClient.send(
            .init(kind: .cognitiveActionOutcome, cognitiveAction: episode),
            socketURL: socketURL
        )
        XCTAssertFalse(denied.ok)
        XCTAssertNil(received.value)

        let accepted = try EmbodimentShadowSocketClient.send(
            .init(
                kind: .cognitiveActionOutcome,
                cognitiveAction: episode,
                sessionAuthorization: token
            ),
            socketURL: socketURL
        )
        XCTAssertTrue(accepted.ok)
        XCTAssertEqual(received.value, episode)
        XCTAssertNil(accepted.snapshot)
        XCTAssertNil(accepted.personContext)
    }

    func testConversationTerminationIPCRequiresCurrentCapability() throws {
        let suffix = UUID().uuidString.prefix(8)
        let directory = URL(fileURLWithPath: "/private/tmp/soma-conversation-end-ipc-\(suffix)", isDirectory: true)
        let socketURL = directory.appendingPathComponent("shadow.sock")
        let currentToken = UUID().uuidString.lowercased()
        let terminated = LockedValue(false)
        let server = EmbodimentShadowSocketServer(
            socketURL: socketURL,
            conversationTerminationHandler: { token in
                guard token == currentToken else {
                    return .failure(EmbodimentIPCError.permissionDenied)
                }
                terminated.set(true)
                return .success(())
            },
            sessionAuthorizationProvider: { token, scope in
                guard token == currentToken, scope == .conversationControl else {
                    return .failure(EmbodimentIPCError.permissionDenied)
                }
                return .success(())
            }
        )
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: directory)
        }

        let rejected = try EmbodimentShadowSocketClient.send(
            .init(kind: .endConversation, sessionAuthorization: UUID().uuidString.lowercased()),
            socketURL: socketURL
        )
        XCTAssertFalse(rejected.ok)
        XCTAssertFalse(terminated.value)

        let accepted = try EmbodimentShadowSocketClient.send(
            .init(kind: .endConversation, sessionAuthorization: currentToken),
            socketURL: socketURL
        )
        XCTAssertTrue(accepted.ok)
        XCTAssertTrue(terminated.value)
    }

    func testAdministratorCanManageIdentityRosterAndRegisteredContexts() {
        let store = SOMASessionCapabilityStore(lifetimeSeconds: 60)
        let administrator = UUID()
        let registeredPerson = UUID()
        let administratorToken = store.issue(
            personEntityID: administrator,
            authority: .administrator,
            at: 1_000_000_000
        )
        let participantToken = store.issue(
            personEntityID: registeredPerson,
            authority: .participant,
            at: 1_000_000_000
        )

        for scope in [
            SOMASessionCapabilityScope.personContext(registeredPerson),
            .identityRoster,
            .identityManagement,
        ] {
            switch store.authorize(token: administratorToken, scope: scope, at: 1_000_000_001) {
            case .success: break
            case let .failure(error): XCTFail("administrator unexpectedly denied: \(error)")
            }
        }
        switch store.authorize(token: participantToken, scope: .identityRoster, at: 1_000_000_001) {
        case .success: XCTFail("participant accessed the identity roster")
        case .failure(.identityRosterDenied): break
        case let .failure(error): XCTFail("wrong roster error: \(error)")
        }
        switch store.authorize(token: participantToken, scope: .identityManagement, at: 1_000_000_001) {
        case .success: XCTFail("participant managed a persistent identity")
        case .failure(.identityManagementDenied): break
        case let .failure(error): XCTFail("wrong identity-management error: \(error)")
        }
    }

    func testEveryCognitiveLayerCanIssueTheSameLeasedTrackingGoal() throws {
        for layer in CognitiveControlLayer.allCases {
            let request = makeRequest(
                layer: layer,
                operation: .trackTarget(
                    TrackTargetGoal(
                        targetReference: "target:cup",
                        reacquireIfOccluded: true,
                        motionStyle: .attentive
                    )
                )
            )
            XCTAssertNoThrow(try request.validate())
        }
    }

    func testCognitiveAuthorityHasOnlyL1AndL2() {
        XCTAssertEqual(CognitiveControlLayer.allCases, [.l1, .l2])
    }

    func testTargetLabelsAndAttentionPriorsRoundTripAsStableJSON() throws {
        let registration = makeRequest(
            layer: .l1,
            operation: .registerTarget(
                SemanticTargetRegistration(
                    targetReference: "target:red-cup",
                    sceneID: "scene-42",
                    label: "red cup",
                    aliases: ["cup", "mug"],
                    visualQuery: "the red cup beside the keyboard",
                    expectedKind: .object,
                    initialSelectionLogPrior: 2.5
                )
            )
        )
        try registration.validate()
        let data = try JSONEncoder().encode(registration)
        let decoded = try JSONDecoder().decode(CognitiveEmbodimentRequest.self, from: data)
        XCTAssertEqual(decoded, registration)

        let policy = AttentionPolicyGoal(
            targets: [
                TargetAttentionDirective(
                    targetReference: "target:red-cup",
                    selectionLogPrior: 2,
                    trackingCommitment: 0.9
                ),
                TargetAttentionDirective(
                    targetReference: "target:door",
                    selectionLogPrior: -1,
                    trackingCommitment: 0.2
                ),
            ],
            selectionTemperature: 0.7,
            noveltyStrength: 0.8,
            habituationStrength: 0.6
        )
        XCTAssertEqual(policy.normalizedTargetPriors.values.reduce(0, +), 1, accuracy: 1e-12)
        XCTAssertGreaterThan(
            policy.normalizedTargetPriors["target:red-cup"] ?? 0,
            policy.normalizedTargetPriors["target:door"] ?? 1
        )
    }

    func testExplorationPolicyControlsRegionsDirectionsAndMotionCharacter() throws {
        let policy = ExplorationPolicyGoal(
            mode: .memoryGap,
            regions: [
                SphericalSearchRegion(
                    center: GimbalRelativeBearing(azimuthDegrees: -45, elevationDegrees: 5),
                    azimuthRadiusDegrees: 35,
                    elevationRadiusDegrees: 20,
                    preference: 0.9
                )
            ],
            preferredDirections: [
                DirectionalPreference(
                    bearing: GimbalRelativeBearing(azimuthDegrees: -60, elevationDegrees: 0),
                    concentration: 4,
                    weight: 3
                ),
                DirectionalPreference(
                    bearing: GimbalRelativeBearing(azimuthDegrees: 40, elevationDegrees: 10),
                    concentration: 2,
                    weight: 1
                ),
            ],
            coverageStrength: 0.4,
            noveltyStrength: 0.7,
            memoryGapStrength: 1,
            motionContinuity: 0.95,
            tempo: 0.65,
            dwellMilliseconds: 500
        )
        let request = makeRequest(layer: .l1, operation: .explore(policy))
        XCTAssertNoThrow(try request.validate())
        XCTAssertEqual(policy.normalizedDirectionWeights, [0.75, 0.25])
    }

    func testInvalidOrUnboundedLeaseIsRejected() {
        let request = CognitiveEmbodimentRequest(
            requestID: "invalid",
            layer: .l2,
            reason: "track requested object",
            evidenceIDs: [],
            lease: EmbodimentLease(
                ownerID: "l2:session",
                priority: 100,
                issuedAtNS: 1,
                durationMilliseconds: 600_001,
                cancellationToken: "cancel:invalid"
            ),
            operation: .trackTarget(TrackTargetGoal(targetReference: "target:object"))
        )
        XCTAssertThrowsError(try request.validate())
    }

    func testShadowArbiterRequiresRegistrationAndPreemptsOnlyByPriority() {
        let now: UInt64 = 5_000_000_000
        let arbiter = ShadowEmbodimentArbiter()
        let unknown = shadowRequest(
            id: "track-unknown",
            layer: .l1,
            owner: "l1:e4b",
            priority: 40,
            now: now,
            operation: .trackTarget(TrackTargetGoal(targetReference: "target:person"))
        )
        XCTAssertEqual(arbiter.submit(unknown, at: now).reason, "tracking_target_unknown")

        let registration = shadowRequest(
            id: "register-person",
            layer: .l1,
            owner: "l1:e4b",
            priority: 40,
            now: now,
            operation: .registerTarget(
                SemanticTargetRegistration(
                    targetReference: "target:person",
                    sceneID: "scene:person",
                    label: "person",
                    expectedKind: .human
                )
            )
        )
        XCTAssertEqual(arbiter.submit(registration, at: now).status, .accepted)

        let tracking = shadowRequest(
            id: "track-person",
            layer: .l1,
            owner: "l1:e4b",
            priority: 40,
            now: now,
            operation: .trackTarget(TrackTargetGoal(targetReference: "target:person"))
        )
        XCTAssertEqual(arbiter.submit(tracking, at: now).status, .accepted)

        let lowerPriority = shadowRequest(
            id: "explore-lower",
            layer: .l1,
            owner: "l1:situation",
            priority: 40,
            now: now,
            operation: .explore(ExplorationPolicyGoal(mode: .noveltySeeking))
        )
        XCTAssertEqual(arbiter.submit(lowerPriority, at: now).status, .rejected)

        let higherPriority = shadowRequest(
            id: "orient-higher",
            layer: .l2,
            owner: "l2:dialogue",
            priority: 90,
            now: now,
            operation: .orient(OrientGoal(bearing: .init(azimuthDegrees: 20, elevationDegrees: 5)))
        )
        let preempted = arbiter.submit(higherPriority, at: now)
        XCTAssertEqual(preempted.status, .accepted)
        XCTAssertEqual(preempted.preemptedRequestID, "track-person")
        XCTAssertEqual(preempted.snapshot.activeRequestID, "orient-higher")
        XCTAssertFalse(preempted.snapshot.physicalActuationEnabled)
    }

    func testShadowArbiterExpiresOwnedStateAndReleaseIsOwnerScoped() {
        let now: UInt64 = 9_000_000_000
        let arbiter = ShadowEmbodimentArbiter()
        let registration = shadowRequest(
            id: "register",
            layer: .l1,
            owner: "l1:context",
            priority: 50,
            now: now,
            durationMilliseconds: 100,
            operation: .registerTarget(
                SemanticTargetRegistration(
                    targetReference: "target:door",
                    sceneID: "scene:door",
                    label: "door"
                )
            )
        )
        XCTAssertEqual(arbiter.submit(registration, at: now).status, .accepted)
        XCTAssertEqual(arbiter.snapshot(at: now + 99_000_000).registeredTargets.count, 1)
        XCTAssertTrue(arbiter.snapshot(at: now + 100_000_000).registeredTargets.isEmpty)

        let release = shadowRequest(
            id: "release",
            layer: .l1,
            owner: "l1:context",
            priority: 50,
            now: now + 200_000_000,
            operation: .release
        )
        XCTAssertEqual(arbiter.submit(release, at: now + 200_000_000).status, .released)
    }

    func testShadowUnixSocketRoundTripIsOwnerOnlyAndNonActuating() throws {
        let suffix = UUID().uuidString.prefix(8)
        let directory = URL(fileURLWithPath: "/private/tmp/soma-ipc-\(suffix)", isDirectory: true)
        let socketURL = directory.appendingPathComponent("shadow.sock")
        let server = EmbodimentShadowSocketServer(socketURL: socketURL)
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: directory)
        }

        let snapshotReply = try EmbodimentShadowSocketClient.send(
            EmbodimentIPCCommand(kind: .snapshot),
            socketURL: socketURL
        )
        XCTAssertTrue(snapshotReply.ok)
        XCTAssertEqual(snapshotReply.snapshot?.mode, "shadow")
        XCTAssertEqual(snapshotReply.snapshot?.physicalActuationEnabled, false)

        let attributes = try FileManager.default.attributesOfItem(atPath: socketURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)

        let now = DispatchTime.now().uptimeNanoseconds
        let registration = shadowRequest(
            id: "socket-register",
            layer: .l1,
            owner: "l1:e4b-socket",
            priority: 45,
            now: now,
            operation: .registerTarget(
                SemanticTargetRegistration(
                    targetReference: "target:socket-person",
                    sceneID: "scene:socket-person",
                    label: "person",
                    expectedKind: .human
                )
            )
        )
        let reply = try EmbodimentShadowSocketClient.send(
            EmbodimentIPCCommand(kind: .submit, request: registration),
            socketURL: socketURL
        )
        XCTAssertTrue(reply.ok)
        XCTAssertEqual(reply.decision?.status, .accepted)
        XCTAssertEqual(reply.snapshot?.registeredTargets.first?.targetReference, "target:socket-person")
        XCTAssertEqual(reply.snapshot?.physicalActuationEnabled, false)
    }

    func testPersonContextUsesTheOwnerOnlySocketInsteadOfASecondMemoryStore() throws {
        let suffix = UUID().uuidString.prefix(8)
        let directory = URL(fileURLWithPath: "/private/tmp/soma-person-context-ipc-\(suffix)", isDirectory: true)
        let socketURL = directory.appendingPathComponent("shadow.sock")
        let personID = UUID()
        let server = EmbodimentShadowSocketServer(
            socketURL: socketURL,
            personContextProvider: { request in
                guard request.operation == .setPreferredLanguage,
                      request.confirmedByUser,
                      request.personEntityID == personID,
                      request.languageTag == "zh-Hans" else {
                    return .failure(EmbodimentIPCError.malformedMessage)
                }
                return .success(PersonContextSnapshot(
                    personEntityID: personID,
                    preferredLanguageTag: "zh-Hans",
                    proactiveContactPreference: .unknown,
                    rapport: nil,
                    facts: ["preferred_language": "zh-Hans"]
        ))
    }

        )
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: directory)
        }

        let reply = try EmbodimentShadowSocketClient.send(
            .init(kind: .personContext, personContext: PersonContextIPCRequest(
                operation: .setPreferredLanguage,
                personEntityID: personID,
                languageTag: "zh-Hans",
                confirmedByUser: true
            )),
            socketURL: socketURL
        )
        XCTAssertTrue(reply.ok)
        XCTAssertEqual(reply.personContext?.preferredLanguageTag, "zh-Hans")
        XCTAssertNil(reply.snapshot)
    }

    func testInformationNeedsRoundTripAndAnswerRemainBoundToOnePerson() throws {
        let suffix = UUID().uuidString.prefix(8)
        let directory = URL(fileURLWithPath: "/private/tmp/soma-information-needs-ipc-\(suffix)", isDirectory: true)
        let socketURL = directory.appendingPathComponent("shadow.sock")
        let personID = UUID()
        let motiveID = UUID()
        let server = EmbodimentShadowSocketServer(
            socketURL: socketURL,
            informationNeedsProvider: { request in
                guard request.personEntityID == personID else {
                    return .failure(EmbodimentIPCError.permissionDenied)
                }
                switch request.operation {
                case .list:
                    guard request.motiveID == nil, request.acquiredFact == nil else {
                        return .failure(EmbodimentIPCError.malformedMessage)
                    }
                    return .success(.init(items: [
                        .init(
                            motiveID: motiveID,
                            question: "What kind of music do they enjoy?",
                            expectedInformationGain: 0.91
                        ),
                    ]))
                case .recordAnswer:
                    guard request.motiveID == motiveID,
                          request.acquiredFact == "They enjoy jazz." else {
                        return .failure(EmbodimentIPCError.malformedMessage)
                    }
                    return .success(.init(recordedMotiveID: motiveID))
                }
            }
        )
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: directory)
        }

        let listed = try EmbodimentShadowSocketClient.send(
            .init(
                kind: .informationNeeds,
                informationNeeds: .init(operation: .list, personEntityID: personID)
            ),
            socketURL: socketURL
        )
        XCTAssertTrue(listed.ok)
        XCTAssertEqual(listed.informationNeeds?.items.map(\.motiveID), [motiveID])
        XCTAssertEqual(listed.informationNeeds?.items.first?.expectedInformationGain, 0.91)

        let recorded = try EmbodimentShadowSocketClient.send(
            .init(
                kind: .informationNeeds,
                informationNeeds: .init(
                    operation: .recordAnswer,
                    personEntityID: personID,
                    motiveID: motiveID,
                    acquiredFact: "They enjoy jazz."
                )
            ),
            socketURL: socketURL
        )
        XCTAssertTrue(recorded.ok)
        XCTAssertEqual(recorded.informationNeeds?.recordedMotiveID, motiveID)
    }

    func testSemanticTargetBindingPreservesExplicitSceneIdentityOffscreen() {
        var binder = SemanticTargetBindingEngine()
        let registration = SemanticTargetRegistration(
            targetReference: "target:known-person",
            sceneID: "scene-person-7",
            label: "known person",
            expectedKind: .human
        )
        let visible = sceneEntity(
            id: "scene-person-7",
            kind: .human,
            label: "person",
            observed: true
        )
        let bound = binder.resolve(registrations: [registration], entities: [visible])
        XCTAssertEqual(bound.first?.status, .bound)
        XCTAssertEqual(bound.first?.sceneID, "scene-person-7")
        XCTAssertEqual(bound.first?.posteriorProbability, 1)

        let offscreen = sceneEntity(
            id: "scene-person-7",
            kind: .human,
            label: "person",
            observed: false,
            lastSeenMilliseconds: 45_000
        )
        let retained = binder.resolve(registrations: [registration], entities: [offscreen])
        XCTAssertEqual(retained.first?.status, .retained)
        XCTAssertEqual(retained.first?.sceneID, "scene-person-7")
        XCTAssertEqual(retained.first?.reason, "explicit_scene_retained")
    }

    func testDescriptorBindingSurfacesAmbiguityInsteadOfInventingIdentity() {
        var binder = SemanticTargetBindingEngine()
        let registration = SemanticTargetRegistration(
            targetReference: "target:visitor",
            label: "visitor",
            aliases: ["person"],
            visualQuery: "the visitor in front of the camera",
            expectedKind: .human,
            initialSelectionLogPrior: 2
        )
        let bindings = binder.resolve(
            registrations: [registration],
            entities: [
                sceneEntity(id: "scene-person-a", kind: .human, label: "person", observed: true),
                sceneEntity(id: "scene-person-b", kind: .human, label: "person", observed: true),
            ]
        )
        XCTAssertEqual(bindings.first?.status, .ambiguous)
        XCTAssertNil(bindings.first?.sceneID)
        XCTAssertGreaterThan(bindings.first?.normalizedEntropy ?? 0, 0.5)
    }

    func testDescriptorAliasesAreExplicitAndLanguageAgnostic() {
        var binder = SemanticTargetBindingEngine()
        let registration = SemanticTargetRegistration(
            targetReference: "target:guest",
            label: "손님",
            aliases: ["PERSON", "visiteur"],
            visualQuery: "the current guest",
            expectedKind: .human,
            initialSelectionLogPrior: 3
        )
        let binding = binder.resolve(
            registrations: [registration],
            entities: [sceneEntity(id: "scene-guest", kind: .human, label: "person", observed: true)]
        ).first
        XCTAssertEqual(binding?.status, .bound)
        XCTAssertEqual(binding?.sceneID, "scene-guest")
    }

    func testArbiterPublishesOnlySemanticBindingTransitions() {
        let now: UInt64 = 20_000_000_000
        let arbiter = ShadowEmbodimentArbiter()
        let registration = shadowRequest(
            id: "binding-register",
            layer: .l1,
            owner: "l1:binding",
            priority: 60,
            now: now,
            operation: .registerTarget(
                SemanticTargetRegistration(
                    targetReference: "target:cup",
                    sceneID: "scene-cup",
                    label: "cup",
                    expectedKind: .object
                )
            )
        )
        XCTAssertEqual(arbiter.submit(registration, at: now).status, .accepted)
        let entity = sceneEntity(id: "scene-cup", kind: .object, label: "cup", observed: true)
        let first = arbiter.updateScene([entity], at: now + 1)
        XCTAssertEqual(first.map(\.status), [.bound])
        XCTAssertTrue(arbiter.updateScene([entity], at: now + 2).isEmpty)
        let snapshot = arbiter.snapshot(at: now + 3)
        XCTAssertEqual(snapshot.sceneEntityCount, 1)
        XCTAssertEqual(snapshot.targetBindings.first?.sceneID, "scene-cup")
        XCTAssertFalse(snapshot.physicalActuationEnabled)
    }

    func testArbiterPublishesSharedSphericalAtlasAndRememberedBearings() {
        let now: UInt64 = 25_000_000_000
        let atlas = SphericalSceneAtlasStore()
        let panorama = PanoramaMapStatusStore()
        let arbiter = ShadowEmbodimentArbiter(spatialAtlas: atlas, panoramaStatus: panorama)
        panorama.update(PanoramaMapStatus(
            state: "ready",
            imagePath: "/tmp/panorama.jpg",
            metadataPath: "/tmp/panorama.json",
            width: 1024,
            height: 256,
            minimumElevationDegrees: -45,
            maximumElevationDegrees: 45,
            revision: 2,
            acceptedFrames: 8,
            poseInterpolationMisses: 1,
            dynamicallyMaskedPixels: 32,
            coverageFraction: 0.4,
            lastUpdatedNS: now
        ))
        atlas.observe(
            pose: GimbalPose(pitchDegrees: 0, panDegrees: 0, monotonicNS: now),
            horizontalFieldOfViewDegrees: 86,
            at: now
        )
        _ = arbiter.updateScene([
            sceneEntity(
                id: "scene:offscreen-person",
                kind: .human,
                label: "person",
                observed: false,
                lastSeenMilliseconds: 120_000
            )
        ], at: now + 1)

        let snapshot = arbiter.snapshot(at: now + 2)
        XCTAssertEqual(snapshot.schemaVersion, 4)
        XCTAssertEqual(snapshot.spatialAtlas.schemaVersion, 4)
        XCTAssertEqual(snapshot.spatialAtlas.restoredPlaceCount, 0)
        XCTAssertEqual(snapshot.spatialAtlas.persistedPlaceCount, 0)
        XCTAssertGreaterThan(snapshot.spatialAtlas.observedCellCount, 0)
        XCTAssertTrue(snapshot.spatialAtlas.cells.contains { abs($0.bearing.azimuthDegrees) > 110 })
        XCTAssertTrue(snapshot.spatialAtlas.cells.allSatisfy {
            (0...1).contains($0.expectedInformationGain)
        })
        XCTAssertEqual(snapshot.spatialAtlas.entities.first?.sceneID, "scene:offscreen-person")
        XCTAssertEqual(
            snapshot.spatialAtlas.kinematicEnvelope,
            GimbalKinematicEnvelope.obsbotTiny2Lite
        )
        XCTAssertEqual(snapshot.panorama?.revision, 2)
        XCTAssertEqual(snapshot.panorama?.schemaVersion, 8)
        XCTAssertEqual(snapshot.panorama?.coverageFraction ?? 0, 0.4, accuracy: 0.000_001)
    }

    func testPhysicalMotorCoordinatorPreemptsAndExpiresWithoutBypassingL0() {
        let now: UInt64 = 30_000_000_000
        let arbiter = ShadowEmbodimentArbiter(physicalActuationEnabled: true)
        var coordinator = EmbodimentMotorCoordinator()
        let first = shadowRequest(
            id: "orient-first",
            layer: .l1,
            owner: "l1:situation",
            priority: 40,
            now: now,
            durationMilliseconds: 200,
            operation: .orient(OrientGoal(
                bearing: .init(azimuthDegrees: 25, elevationDegrees: 4),
                motionStyle: .smooth
            ))
        )
        let firstDecision = arbiter.submit(first, at: now)
        XCTAssertTrue(firstDecision.snapshot.physicalActuationEnabled)
        XCTAssertEqual(firstDecision.snapshot.mode, "active")
        guard case let .orient(requestID, bearing, _, _, expiresAtNS, _) = coordinator.apply(
            request: first,
            decision: firstDecision,
            at: now
        ) else {
            return XCTFail("accepted orientation must become an L0 semantic motor intent")
        }
        XCTAssertEqual(requestID, first.requestID)
        XCTAssertEqual(bearing.azimuthDegrees, 25)
        XCTAssertEqual(expiresAtNS, now + 200_000_000)

        let second = shadowRequest(
            id: "orient-second",
            layer: .l2,
            owner: "l2:dialogue",
            priority: 90,
            now: now + 1,
            durationMilliseconds: 100,
            operation: .orient(OrientGoal(
                bearing: .init(azimuthDegrees: -15, elevationDegrees: 0),
                motionStyle: .attentive
            ))
        )
        let secondDecision = arbiter.submit(second, at: now + 1)
        XCTAssertEqual(secondDecision.preemptedRequestID, first.requestID)
        guard case let .orient(requestID, bearing, _, _, _, _) = coordinator.apply(
            request: second,
            decision: secondDecision,
            at: now + 1
        ) else {
            return XCTFail("higher-priority goal must replace the current semantic intent")
        }
        XCTAssertEqual(requestID, second.requestID)
        XCTAssertEqual(bearing.azimuthDegrees, -15)
        XCTAssertNil(coordinator.expire(at: now + 100_000_000))
        XCTAssertEqual(
            coordinator.expire(at: now + 100_000_001),
            .release(requestID: second.requestID, reason: "lease_expired")
        )
    }

    func testPhysicalTrackingSuspendsUntilOneRegisteredSceneBindingIsGrounded() {
        let now: UInt64 = 40_000_000_000
        let arbiter = ShadowEmbodimentArbiter(physicalActuationEnabled: true)
        var coordinator = EmbodimentMotorCoordinator()
        let registration = shadowRequest(
            id: "register-cup",
            layer: .l1,
            owner: "l1:context",
            priority: 50,
            now: now,
            operation: .registerTarget(SemanticTargetRegistration(
                targetReference: "target:cup",
                sceneID: "scene:cup",
                label: "cup",
                expectedKind: .object
            ))
        )
        XCTAssertEqual(arbiter.submit(registration, at: now).status, .accepted)
        let track = shadowRequest(
            id: "track-cup",
            layer: .l1,
            owner: "l1:context",
            priority: 50,
            now: now + 1,
            operation: .trackTarget(TrackTargetGoal(targetReference: "target:cup"))
        )
        let ungroundedDecision = arbiter.submit(track, at: now + 1)
        XCTAssertEqual(
            coordinator.apply(request: track, decision: ungroundedDecision, at: now + 1),
            .suspend(
                requestID: track.requestID,
                reason: "target_binding_unavailable",
                expiresAtNS: track.lease.expiresAtNS
            )
        )

        _ = arbiter.updateScene([
            EmbodimentSceneEntity(
                sceneID: "scene:cup",
                kind: .object,
                label: "cup",
                confidence: 0.91,
                observedThisFrame: true,
                actionEligible: false,
                bearing: .init(azimuthDegrees: 35, elevationDegrees: -3),
                spatialConfidence: 0.92,
                lastSeenMilliseconds: 0
            )
        ], at: now + 2)
        guard case let .track(_, reference, sceneID, bearing, observed, _, _, _) = coordinator.update(
            snapshot: arbiter.snapshot(at: now + 3),
            at: now + 3
        ) else {
            return XCTFail("an explicit high-level target may move only after one scene binding is grounded")
        }
        XCTAssertEqual(reference, "target:cup")
        XCTAssertEqual(sceneID, "scene:cup")
        XCTAssertEqual(bearing.azimuthDegrees, 35)
        XCTAssertTrue(observed)
    }

    func testRegistrationBindsImmediatelyToAlreadyObservedSceneEvidence() {
        let now: UInt64 = 45_000_000_000
        let arbiter = ShadowEmbodimentArbiter(physicalActuationEnabled: true)
        _ = arbiter.updateScene([
            EmbodimentSceneEntity(
                sceneID: "scene:book",
                kind: .object,
                label: "book",
                confidence: 0.88,
                observedThisFrame: true,
                actionEligible: true,
                bearing: .init(azimuthDegrees: -18, elevationDegrees: 4),
                spatialConfidence: 0.9,
                lastSeenMilliseconds: 0
            )
        ], at: now)
        let registration = shadowRequest(
            id: "register-visible-book",
            layer: .l1,
            owner: "l1:context",
            priority: 60,
            now: now + 1,
            operation: .registerTarget(SemanticTargetRegistration(
                targetReference: "target:book",
                sceneID: "scene:book",
                label: "book",
                expectedKind: .object
            ))
        )
        let decision = arbiter.submit(registration, at: now + 1)
        XCTAssertEqual(decision.status, .accepted)
        XCTAssertEqual(
            decision.snapshot.targetBindings.first?.status,
            .bound,
            "registration must bind against the current scene, not wait for another frame"
        )
        XCTAssertEqual(decision.snapshot.targetBindings.first?.sceneID, "scene:book")
    }

    func testTrackFramingProducesCompositionAwareIntent() {
        let now: UInt64 = 46_000_000_000
        let arbiter = ShadowEmbodimentArbiter(physicalActuationEnabled: true)
        _ = arbiter.updateScene([
            EmbodimentSceneEntity(
                sceneID: "scene:lamp",
                kind: .object,
                label: "lamp",
                confidence: 0.9,
                observedThisFrame: true,
                actionEligible: true,
                bearing: .init(azimuthDegrees: 20, elevationDegrees: 3),
                spatialConfidence: 0.9,
                lastSeenMilliseconds: 0
            )
        ], at: now)
        let registration = shadowRequest(
            id: "register-lamp",
            layer: .l1,
            owner: "l1:composition",
            priority: 60,
            now: now + 1,
            operation: .registerTarget(SemanticTargetRegistration(
                targetReference: "target:lamp",
                sceneID: "scene:lamp",
                label: "lamp",
                expectedKind: .object
            ))
        )
        _ = arbiter.submit(registration, at: now + 1)
        let framing = NormalizedRect(x: 0.68, y: 0.40, width: 0.12, height: 0.12)
        let request = shadowRequest(
            id: "frame-lamp-right",
            layer: .l1,
            owner: "l1:composition",
            priority: 60,
            now: now + 2,
            operation: .trackTarget(TrackTargetGoal(
                targetReference: "target:lamp",
                framing: framing,
                motionStyle: .smooth
            ))
        )
        var coordinator = EmbodimentMotorCoordinator()
        guard case let .track(_, _, _, _, _, emittedFraming, _, _) = coordinator.apply(
            request: request,
            decision: arbiter.submit(request, at: now + 2),
            at: now + 2
        ) else {
            return XCTFail("grounded composition target did not reach the L0 motor coordinator")
        }
        XCTAssertEqual(emittedFraming, framing)

        let projection = CameraProjectionModel.pinhole(horizontalFieldOfViewDegrees: 86)
        let centered = projection.cameraBearing(
            placing: .init(azimuthDegrees: 20, elevationDegrees: 3),
            at: .init(x: 0.44, y: 0.44, width: 0.12, height: 0.12),
            poseProjection: .obsbotTiny2Lite
        )
        let rightFramed = projection.cameraBearing(
            placing: .init(azimuthDegrees: 20, elevationDegrees: 3),
            at: framing,
            poseProjection: .obsbotTiny2Lite
        )
        XCTAssertNotNil(centered)
        XCTAssertNotNil(rightFramed)
        XCTAssertNotEqual(centered?.azimuthDegrees, rightFramed?.azimuthDegrees)
    }

    func testPhysicalReleaseIsOwnerScoped() {
        let now: UInt64 = 50_000_000_000
        let arbiter = ShadowEmbodimentArbiter(physicalActuationEnabled: true)
        var coordinator = EmbodimentMotorCoordinator()
        let orient = shadowRequest(
            id: "owner-orient",
            layer: .l1,
            owner: "l1:owner",
            priority: 50,
            now: now,
            operation: .orient(OrientGoal(bearing: .init(azimuthDegrees: 10, elevationDegrees: 0)))
        )
        _ = coordinator.apply(request: orient, decision: arbiter.submit(orient, at: now), at: now)

        let foreignRelease = shadowRequest(
            id: "foreign-release",
            layer: .l2,
            owner: "l2:other",
            priority: 90,
            now: now + 1,
            operation: .release
        )
        XCTAssertNil(coordinator.apply(
            request: foreignRelease,
            decision: arbiter.submit(foreignRelease, at: now + 1),
            at: now + 1
        ))
        XCTAssertEqual(coordinator.activeRequestID, orient.requestID)

        let ownerRelease = shadowRequest(
            id: "owner-release",
            layer: .l1,
            owner: "l1:owner",
            priority: 50,
            now: now + 2,
            operation: .release
        )
        XCTAssertEqual(
            coordinator.apply(
                request: ownerRelease,
                decision: arbiter.submit(ownerRelease, at: now + 2),
                at: now + 2
            ),
            .release(requestID: orient.requestID, reason: "owner_released")
        )
    }

    func testCaptureViewIsAOneShotMotorGoalThatPreservesOwnerMemory() {
        let now: UInt64 = 60_000_000_000
        let arbiter = ShadowEmbodimentArbiter(physicalActuationEnabled: true)
        var coordinator = EmbodimentMotorCoordinator()
        let registration = shadowRequest(
            id: "capture-register",
            layer: .l1,
            owner: "l1:context",
            priority: 60,
            now: now,
            durationMilliseconds: 20_000,
            operation: .registerTarget(SemanticTargetRegistration(
                targetReference: "target:desk",
                sceneID: "scene:desk",
                label: "desk"
            ))
        )
        XCTAssertEqual(arbiter.submit(registration, at: now).status, .accepted)
        let capture = shadowRequest(
            id: "capture-bearing",
            layer: .l1,
            owner: "l1:context",
            priority: 60,
            now: now + 1,
            durationMilliseconds: 5_000,
            operation: .captureView(CaptureViewGoal(
                bearing: .init(azimuthDegrees: -32, elevationDegrees: 7),
                fieldOfViewDegrees: 40
            ))
        )
        let decision = arbiter.submit(capture, at: now + 1)
        guard case let .capture(requestID, reference, sceneID, bearing, fov, expiresAtNS) = coordinator.apply(
            request: capture,
            decision: decision,
            at: now + 1
        ) else {
            return XCTFail("capture must retain its own alignment and frame-acquisition intent")
        }
        XCTAssertEqual(requestID, capture.requestID)
        XCTAssertNil(reference)
        XCTAssertNil(sceneID)
        XCTAssertEqual(bearing.azimuthDegrees, -32)
        XCTAssertEqual(fov, 40)
        XCTAssertEqual(expiresAtNS, capture.lease.expiresAtNS)

        XCTAssertTrue(arbiter.completeMotorGoal(requestID: capture.requestID, at: now + 2))
        XCTAssertNil(arbiter.snapshot(at: now + 3).activeRequestID)
        XCTAssertEqual(arbiter.snapshot(at: now + 3).registeredTargets.count, 1)
        XCTAssertEqual(
            coordinator.complete(requestID: capture.requestID),
            .release(requestID: capture.requestID, reason: "capture_completed")
        )
    }

    func testCurrentFrameCaptureDoesNotClaimOrPreemptTheMotorLease() {
        let now: UInt64 = 70_000_000_000
        let arbiter = ShadowEmbodimentArbiter(physicalActuationEnabled: true)
        var coordinator = EmbodimentMotorCoordinator()
        let current = shadowRequest(
            id: "capture-current",
            layer: .l2,
            owner: "l2:conversation",
            priority: 100,
            now: now,
            durationMilliseconds: 2_000,
            operation: .captureView(CaptureViewGoal(currentFrame: true))
        )

        let decision = arbiter.submit(current, at: now)
        XCTAssertEqual(decision.status, .accepted)
        XCTAssertEqual(decision.reason, "current_frame_capture_ready")
        XCTAssertNil(decision.snapshot.activeRequestID)
        XCTAssertEqual(
            coordinator.apply(request: current, decision: decision, at: now),
            .captureCurrent(
                requestID: current.requestID,
                fieldOfViewDegrees: 70,
                expiresAtNS: current.lease.expiresAtNS
            )
        )
    }

    func testOpticalZoomReachesL0WithoutPreemptingAnActiveGimbalLease() throws {
        let now: UInt64 = 71_000_000_000
        let arbiter = ShadowEmbodimentArbiter(physicalActuationEnabled: true)
        var coordinator = EmbodimentMotorCoordinator()
        let orientation = shadowRequest(
            id: "orient-for-detail",
            layer: .l1,
            owner: "l1:situation",
            priority: 50,
            now: now,
            durationMilliseconds: 5_000,
            operation: .orient(OrientGoal(
                bearing: .init(azimuthDegrees: 18, elevationDegrees: 3),
                motionStyle: .smooth
            ))
        )
        let orientationDecision = arbiter.submit(orientation, at: now)
        XCTAssertEqual(orientationDecision.status, .accepted)
        guard case .orient = coordinator.apply(
            request: orientation,
            decision: orientationDecision,
            at: now
        ) else {
            return XCTFail("orientation should hold the active gimbal lease")
        }

        let zoom = shadowRequest(
            id: "zoom-for-detail",
            layer: .l2,
            owner: "l2:conversation",
            priority: 90,
            now: now + 1,
            operation: .setOpticalZoom(OpticalZoomGoal(factor: 1.25))
        )
        XCTAssertNoThrow(try zoom.validate())
        let zoomDecision = arbiter.submit(zoom, at: now + 1)

        XCTAssertEqual(zoomDecision.status, .accepted)
        XCTAssertEqual(zoomDecision.reason, "optical_zoom_ready_l0_adapter")
        XCTAssertEqual(zoomDecision.snapshot.activeRequestID, orientation.requestID)
        XCTAssertEqual(
            coordinator.apply(request: zoom, decision: zoomDecision, at: now + 1),
            .opticalZoom(requestID: zoom.requestID, factor: 1.25)
        )
    }

    func testAudioCaptureModeReachesL0WithoutPreemptingAnActiveGimbalLease() throws {
        let now: UInt64 = 72_000_000_000
        let arbiter = ShadowEmbodimentArbiter(physicalActuationEnabled: true)
        var coordinator = EmbodimentMotorCoordinator()
        let orientation = shadowRequest(
            id: "orient-while-listening",
            layer: .l1,
            owner: "l1:situation",
            priority: 50,
            now: now,
            durationMilliseconds: 5_000,
            operation: .orient(OrientGoal(
                bearing: .init(azimuthDegrees: -12, elevationDegrees: 1),
                motionStyle: .smooth
            ))
        )
        let orientationDecision = arbiter.submit(orientation, at: now)
        guard case .orient = coordinator.apply(
            request: orientation,
            decision: orientationDecision,
            at: now
        ) else {
            return XCTFail("orientation should hold the active gimbal lease")
        }

        let audioMode = shadowRequest(
            id: "front-conversation-audio",
            layer: .l2,
            owner: "l2:conversation",
            priority: 90,
            now: now + 1,
            operation: .setAudioCaptureMode(.init(mode: .conversationFront))
        )
        XCTAssertNoThrow(try audioMode.validate())
        let decision = arbiter.submit(audioMode, at: now + 1)

        XCTAssertEqual(decision.status, .accepted)
        XCTAssertEqual(decision.reason, "audio_capture_mode_ready_l0_adapter")
        XCTAssertEqual(decision.snapshot.activeRequestID, orientation.requestID)
        XCTAssertEqual(
            coordinator.apply(request: audioMode, decision: decision, at: now + 1),
            .audioCaptureMode(requestID: audioMode.requestID, mode: .conversationFront)
        )
    }

    func testAudioInputGainReachesL0WithoutPreemptingAnActiveGimbalLease() throws {
        let now: UInt64 = 72_500_000_000
        let arbiter = ShadowEmbodimentArbiter(physicalActuationEnabled: true)
        var coordinator = EmbodimentMotorCoordinator()
        let orientation = shadowRequest(
            id: "orient-while-adjusting-input-gain",
            layer: .l1,
            owner: "l1:situation",
            priority: 50,
            now: now,
            durationMilliseconds: 5_000,
            operation: .orient(OrientGoal(
                bearing: .init(azimuthDegrees: -12, elevationDegrees: 1),
                motionStyle: .smooth
            ))
        )
        let orientationDecision = arbiter.submit(orientation, at: now)
        guard case .orient = coordinator.apply(
            request: orientation,
            decision: orientationDecision,
            at: now
        ) else {
            return XCTFail("orientation should hold the active gimbal lease")
        }

        let inputGain = shadowRequest(
            id: "conversation-input-gain",
            layer: .l2,
            owner: "l2:conversation",
            priority: 90,
            now: now + 1,
            operation: .setAudioInputGain(.init(percent: 60))
        )
        XCTAssertNoThrow(try inputGain.validate())
        let decision = arbiter.submit(inputGain, at: now + 1)

        XCTAssertEqual(decision.status, .accepted)
        XCTAssertEqual(decision.reason, "audio_input_gain_ready_l0_adapter")
        XCTAssertEqual(decision.snapshot.activeRequestID, orientation.requestID)
        XCTAssertEqual(
            coordinator.apply(request: inputGain, decision: decision, at: now + 1),
            .audioInputGain(requestID: inputGain.requestID, percent: 60)
        )
    }

    func testCameraWhiteBalanceReachesL0WithoutPreemptingAnActiveGimbalLease() throws {
        let now: UInt64 = 73_000_000_000
        let arbiter = ShadowEmbodimentArbiter(physicalActuationEnabled: true)
        var coordinator = EmbodimentMotorCoordinator()
        let orientation = shadowRequest(
            id: "orient-while-white-balance-changes",
            layer: .l1,
            owner: "l1:situation",
            priority: 50,
            now: now,
            durationMilliseconds: 5_000,
            operation: .orient(OrientGoal(
                bearing: .init(azimuthDegrees: 10, elevationDegrees: 2),
                motionStyle: .smooth
            ))
        )
        let orientationDecision = arbiter.submit(orientation, at: now)
        guard case .orient = coordinator.apply(
            request: orientation,
            decision: orientationDecision,
            at: now
        ) else {
            return XCTFail("orientation should hold the active gimbal lease")
        }

        let whiteBalance = shadowRequest(
            id: "manual-panorama-white-balance",
            layer: .l2,
            owner: "l2:panorama",
            priority: 90,
            now: now + 1,
            operation: .setCameraWhiteBalance(.init(mode: .manual, temperatureKelvin: 5_000))
        )
        XCTAssertNoThrow(try whiteBalance.validate())
        let decision = arbiter.submit(whiteBalance, at: now + 1)

        XCTAssertEqual(decision.status, .accepted)
        XCTAssertEqual(decision.reason, "camera_white_balance_ready_l0_adapter")
        XCTAssertEqual(decision.snapshot.activeRequestID, orientation.requestID)
        XCTAssertEqual(
            coordinator.apply(request: whiteBalance, decision: decision, at: now + 1),
            .cameraWhiteBalance(
                requestID: whiteBalance.requestID,
                mode: .manual,
                temperatureKelvin: 5_000
            )
        )

        let invalidAutomatic = shadowRequest(
            id: "invalid-auto-temperature",
            layer: .l2,
            owner: "l2:panorama",
            priority: 90,
            now: now + 2,
            operation: .setCameraWhiteBalance(.init(mode: .auto, temperatureKelvin: 5_000))
        )
        XCTAssertThrowsError(try invalidAutomatic.validate())
    }

    func testCameraExposureLockReachesL0WithoutPreemptingAnActiveGimbalLease() throws {
        let now: UInt64 = 73_500_000_000
        let arbiter = ShadowEmbodimentArbiter(physicalActuationEnabled: true)
        var coordinator = EmbodimentMotorCoordinator()
        let orientation = shadowRequest(
            id: "orient-while-exposure-lock-changes",
            layer: .l1,
            owner: "l1:situation",
            priority: 50,
            now: now,
            durationMilliseconds: 5_000,
            operation: .orient(OrientGoal(
                bearing: .init(azimuthDegrees: 10, elevationDegrees: 2),
                motionStyle: .smooth
            ))
        )
        let orientationDecision = arbiter.submit(orientation, at: now)
        guard case .orient = coordinator.apply(
            request: orientation,
            decision: orientationDecision,
            at: now
        ) else {
            return XCTFail("orientation should hold the active gimbal lease")
        }

        let exposureLock = shadowRequest(
            id: "lock-exposure-for-panorama",
            layer: .l2,
            owner: "l2:panorama",
            priority: 90,
            now: now + 1,
            operation: .setCameraExposureLock(.init(locked: true))
        )
        XCTAssertNoThrow(try exposureLock.validate())
        let decision = arbiter.submit(exposureLock, at: now + 1)

        XCTAssertEqual(decision.status, .accepted)
        XCTAssertEqual(decision.reason, "camera_exposure_lock_ready_l0_adapter")
        XCTAssertEqual(decision.snapshot.activeRequestID, orientation.requestID)
        XCTAssertEqual(
            coordinator.apply(request: exposureLock, decision: decision, at: now + 1),
            .cameraExposureLock(requestID: exposureLock.requestID, locked: true)
        )
    }

    func testManualFocusAndExposureReachL0WithoutPreemptingAnActiveGimbalLease() throws {
        let now: UInt64 = 73_600_000_000
        let arbiter = ShadowEmbodimentArbiter(physicalActuationEnabled: true)
        var coordinator = EmbodimentMotorCoordinator()
        let orientation = shadowRequest(
            id: "orient-while-lens-controls-change",
            layer: .l1,
            owner: "l1:situation",
            priority: 50,
            now: now,
            durationMilliseconds: 5_000,
            operation: .orient(OrientGoal(
                bearing: .init(azimuthDegrees: 10, elevationDegrees: 2),
                motionStyle: .smooth
            ))
        )
        let orientationDecision = arbiter.submit(orientation, at: now)
        guard case .orient = coordinator.apply(
            request: orientation,
            decision: orientationDecision,
            at: now
        ) else {
            return XCTFail("orientation should hold the active gimbal lease")
        }

        let focus = shadowRequest(
            id: "fixed-focus-for-close-inspection",
            layer: .l2,
            owner: "l2:inspection",
            priority: 90,
            now: now + 1,
            operation: .setCameraFocus(.init(mode: .manual, position: 50))
        )
        XCTAssertNoThrow(try focus.validate())
        let focusDecision = arbiter.submit(focus, at: now + 1)
        XCTAssertEqual(focusDecision.status, .accepted)
        XCTAssertEqual(focusDecision.reason, "camera_focus_ready_l0_adapter")
        XCTAssertEqual(focusDecision.snapshot.activeRequestID, orientation.requestID)
        XCTAssertEqual(
            coordinator.apply(request: focus, decision: focusDecision, at: now + 1),
            .cameraFocus(requestID: focus.requestID, mode: .manual, position: 50)
        )

        let exposure = shadowRequest(
            id: "fixed-exposure-for-close-inspection",
            layer: .l2,
            owner: "l2:inspection",
            priority: 90,
            now: now + 2,
            operation: .setCameraAbsoluteExposure(.init(mode: .manual, shutterCode: 33))
        )
        XCTAssertNoThrow(try exposure.validate())
        let exposureDecision = arbiter.submit(exposure, at: now + 2)
        XCTAssertEqual(exposureDecision.status, .accepted)
        XCTAssertEqual(exposureDecision.reason, "camera_absolute_exposure_ready_l0_adapter")
        XCTAssertEqual(exposureDecision.snapshot.activeRequestID, orientation.requestID)
        XCTAssertEqual(
            coordinator.apply(request: exposure, decision: exposureDecision, at: now + 2),
            .cameraAbsoluteExposure(requestID: exposure.requestID, mode: .manual, shutterCode: 33)
        )

        let invalidAutomaticFocus = shadowRequest(
            id: "invalid-auto-focus-position",
            layer: .l2,
            owner: "l2:inspection",
            priority: 90,
            now: now + 3,
            operation: .setCameraFocus(.init(mode: .auto, position: 50))
        )
        XCTAssertThrowsError(try invalidAutomaticFocus.validate())

        let invalidExposureRange = shadowRequest(
            id: "invalid-exposure-code",
            layer: .l2,
            owner: "l2:inspection",
            priority: 90,
            now: now + 4,
            operation: .setCameraAbsoluteExposure(.init(mode: .manual, shutterCode: 101))
        )
        XCTAssertThrowsError(try invalidExposureRange.validate())
    }

    func testNativeHumanTrackingPolicyReachesL0WithoutPreemptingAnActiveGimbalLease() throws {
        let now: UInt64 = 73_750_000_000
        let arbiter = ShadowEmbodimentArbiter(physicalActuationEnabled: true)
        var coordinator = EmbodimentMotorCoordinator()
        let orientation = shadowRequest(
            id: "orient-while-native-policy-changes",
            layer: .l1,
            owner: "l1:situation",
            priority: 50,
            now: now,
            durationMilliseconds: 5_000,
            operation: .orient(OrientGoal(
                bearing: .init(azimuthDegrees: 10, elevationDegrees: 2),
                motionStyle: .smooth
            ))
        )
        let orientationDecision = arbiter.submit(orientation, at: now)
        guard case .orient = coordinator.apply(
            request: orientation,
            decision: orientationDecision,
            at: now
        ) else {
            return XCTFail("orientation should hold the active gimbal lease")
        }

        let policy = shadowRequest(
            id: "native-policy-fast-retentive",
            layer: .l2,
            owner: "l2:conversation",
            priority: 90,
            now: now + 1,
            operation: .setNativeHumanTrackingPolicy(.init(
                speed: .fast,
                motionTracking: true,
                foreTarget: true,
                adaptiveComposition: false,
                adaptivePanGain: false,
                adaptivePitchGain: false,
                panGain: 0.55,
                pitchGain: 0.75
            ))
        )
        XCTAssertNoThrow(try policy.validate())
        let decision = arbiter.submit(policy, at: now + 1)

        XCTAssertEqual(decision.status, .accepted)
        XCTAssertEqual(decision.reason, "native_human_tracking_policy_ready_l0_adapter")
        XCTAssertEqual(decision.snapshot.activeRequestID, orientation.requestID)
        XCTAssertEqual(
            coordinator.apply(request: policy, decision: decision, at: now + 1),
            .nativeHumanTrackingPolicy(
                requestID: policy.requestID,
                speed: .fast,
                motionTracking: true,
                foreTarget: true,
                adaptiveComposition: false,
                adaptivePanGain: false,
                adaptivePitchGain: false,
                panGain: 0.55,
                pitchGain: 0.75
            )
        )
    }

    func testNativeHumanTrackingPolicyRejectsPartialOrConflictingFixedGains() throws {
        let now: UInt64 = 73_800_000_000
        let partialGain = shadowRequest(
            id: "native-policy-partial-fixed-gain",
            layer: .l2,
            owner: "l2:conversation",
            priority: 90,
            now: now,
            operation: .setNativeHumanTrackingPolicy(.init(
                panGain: 0.55
            ))
        )
        XCTAssertThrowsError(try partialGain.validate())

        let conflictingGain = shadowRequest(
            id: "native-policy-adaptive-fixed-gain",
            layer: .l2,
            owner: "l2:conversation",
            priority: 90,
            now: now + 1,
            operation: .setNativeHumanTrackingPolicy(.init(
                adaptivePanGain: true,
                panGain: 0.55,
                pitchGain: 0.75
            ))
        )
        XCTAssertThrowsError(try conflictingGain.validate())
    }

    func testCameraFacePriorityReachesL0WithoutPreemptingAnActiveGimbalLease() throws {
        let now: UInt64 = 73_900_000_000
        let arbiter = ShadowEmbodimentArbiter(physicalActuationEnabled: true)
        var coordinator = EmbodimentMotorCoordinator()
        let orientation = shadowRequest(
            id: "orient-while-face-priority-changes",
            layer: .l1,
            owner: "l1:situation",
            priority: 50,
            now: now,
            durationMilliseconds: 5_000,
            operation: .orient(OrientGoal(
                bearing: .init(azimuthDegrees: 10, elevationDegrees: 2),
                motionStyle: .smooth
            ))
        )
        let orientationDecision = arbiter.submit(orientation, at: now)
        guard case .orient = coordinator.apply(
            request: orientation,
            decision: orientationDecision,
            at: now
        ) else {
            return XCTFail("orientation should hold the active gimbal lease")
        }

        let facePriority = shadowRequest(
            id: "face-priority-social-tracking",
            layer: .l2,
            owner: "l2:conversation",
            priority: 90,
            now: now + 1,
            operation: .setCameraFacePriority(.init(enabled: true))
        )
        XCTAssertNoThrow(try facePriority.validate())
        let decision = arbiter.submit(facePriority, at: now + 1)

        XCTAssertEqual(decision.status, .accepted)
        XCTAssertEqual(decision.reason, "camera_face_priority_ready_l0_adapter")
        XCTAssertEqual(decision.snapshot.activeRequestID, orientation.requestID)
        XCTAssertEqual(
            coordinator.apply(request: facePriority, decision: decision, at: now + 1),
            .cameraFacePriority(requestID: facePriority.requestID, enabled: true)
        )
    }

    func testCameraAntiFlickerReachesL0WithoutPreemptingAnActiveGimbalLease() throws {
        let now: UInt64 = 73_950_000_000
        let arbiter = ShadowEmbodimentArbiter(physicalActuationEnabled: true)
        var coordinator = EmbodimentMotorCoordinator()
        let orientation = shadowRequest(
            id: "orient-while-anti-flicker-changes",
            layer: .l1,
            owner: "l1:situation",
            priority: 50,
            now: now,
            durationMilliseconds: 5_000,
            operation: .orient(OrientGoal(
                bearing: .init(azimuthDegrees: 10, elevationDegrees: 2),
                motionStyle: .smooth
            ))
        )
        let orientationDecision = arbiter.submit(orientation, at: now)
        guard case .orient = coordinator.apply(
            request: orientation,
            decision: orientationDecision,
            at: now
        ) else {
            return XCTFail("orientation should hold the active gimbal lease")
        }

        let antiFlicker = shadowRequest(
            id: "anti-flicker-local-mains",
            layer: .l2,
            owner: "l2:visual-observation",
            priority: 90,
            now: now + 1,
            operation: .setCameraAntiFlicker(.init(mode: .hz60))
        )
        XCTAssertNoThrow(try antiFlicker.validate())
        let decision = arbiter.submit(antiFlicker, at: now + 1)

        XCTAssertEqual(decision.status, .accepted)
        XCTAssertEqual(decision.reason, "camera_anti_flicker_ready_l0_adapter")
        XCTAssertEqual(decision.snapshot.activeRequestID, orientation.requestID)
        XCTAssertEqual(
            coordinator.apply(request: antiFlicker, decision: decision, at: now + 1),
            .cameraAntiFlicker(requestID: antiFlicker.requestID, mode: .hz60)
        )
    }

    func testCameraImageTuningReachesL0WithoutPreemptingAnActiveGimbalLease() throws {
        let now: UInt64 = 73_975_000_000
        let arbiter = ShadowEmbodimentArbiter(physicalActuationEnabled: true)
        var coordinator = EmbodimentMotorCoordinator()
        let orientation = shadowRequest(
            id: "orient-while-image-tuning-changes",
            layer: .l1,
            owner: "l1:situation",
            priority: 50,
            now: now,
            durationMilliseconds: 5_000,
            operation: .orient(OrientGoal(
                bearing: .init(azimuthDegrees: 10, elevationDegrees: 2),
                motionStyle: .smooth
            ))
        )
        let orientationDecision = arbiter.submit(orientation, at: now)
        guard case .orient = coordinator.apply(
            request: orientation,
            decision: orientationDecision,
            at: now
        ) else {
            return XCTFail("orientation should hold the active gimbal lease")
        }

        let tuningGoal = CameraImageTuningGoal(brightness: 55, saturation: 45)
        let tuning = shadowRequest(
            id: "image-tuning-observation",
            layer: .l2,
            owner: "l2:visual-observation",
            priority: 90,
            now: now + 1,
            operation: .setCameraImageTuning(tuningGoal)
        )
        XCTAssertNoThrow(try tuning.validate())
        let decision = arbiter.submit(tuning, at: now + 1)

        XCTAssertEqual(decision.status, .accepted)
        XCTAssertEqual(decision.reason, "camera_image_tuning_ready_l0_adapter")
        XCTAssertEqual(decision.snapshot.activeRequestID, orientation.requestID)
        XCTAssertEqual(
            coordinator.apply(request: tuning, decision: decision, at: now + 1),
            .cameraImageTuning(requestID: tuning.requestID, goal: tuningGoal)
        )
    }

    func testCameraFieldOfViewReachesL0WithoutPreemptingAnActiveGimbalLease() throws {
        let now: UInt64 = 74_000_000_000
        let arbiter = ShadowEmbodimentArbiter(physicalActuationEnabled: true)
        var coordinator = EmbodimentMotorCoordinator()
        let orientation = shadowRequest(
            id: "orient-while-fov-changes",
            layer: .l1,
            owner: "l1:situation",
            priority: 50,
            now: now,
            durationMilliseconds: 5_000,
            operation: .orient(OrientGoal(
                bearing: .init(azimuthDegrees: -8, elevationDegrees: 1),
                motionStyle: .smooth
            ))
        )
        let orientationDecision = arbiter.submit(orientation, at: now)
        guard case .orient = coordinator.apply(
            request: orientation,
            decision: orientationDecision,
            at: now
        ) else {
            return XCTFail("orientation should hold the active gimbal lease")
        }

        let fieldOfView = shadowRequest(
            id: "narrow-detail-field-of-view",
            layer: .l2,
            owner: "l2:observation",
            priority: 90,
            now: now + 1,
            operation: .setCameraFieldOfView(.init(degrees: 65))
        )
        XCTAssertNoThrow(try fieldOfView.validate())
        let decision = arbiter.submit(fieldOfView, at: now + 1)

        XCTAssertEqual(decision.status, .accepted)
        XCTAssertEqual(decision.reason, "camera_field_of_view_ready_l0_adapter")
        XCTAssertEqual(decision.snapshot.activeRequestID, orientation.requestID)
        XCTAssertEqual(
            coordinator.apply(request: fieldOfView, decision: decision, at: now + 1),
            .cameraFieldOfView(requestID: fieldOfView.requestID, degrees: 65)
        )

        let invalidFieldOfView = shadowRequest(
            id: "invalid-field-of-view",
            layer: .l2,
            owner: "l2:observation",
            priority: 90,
            now: now + 2,
            operation: .setCameraFieldOfView(.init(degrees: 70))
        )
        XCTAssertThrowsError(try invalidFieldOfView.validate())
    }

    func testCaptureResultIPCReturnsOnlyTheRequestedTTLResource() throws {
        let suffix = UUID().uuidString.prefix(8)
        let directory = URL(fileURLWithPath: "/private/tmp/soma-capture-ipc-\(suffix)", isDirectory: true)
        let socketURL = directory.appendingPathComponent("capture.sock")
        let ready = EmbodimentViewResource(
            requestID: "capture-1",
            state: .ready,
            imagePath: "/private/tmp/capture-1.jpg",
            mimeType: "image/jpeg",
            width: 640,
            height: 360,
            capturedAtNS: 100,
            resourceExpiresAtNS: 60_000_000_100,
            bearing: .init(azimuthDegrees: 12, elevationDegrees: 3),
            cameraBearing: .init(azimuthDegrees: 11.8, elevationDegrees: 3.1),
            fieldOfViewDegrees: 50
        )
        let server = EmbodimentShadowSocketServer(
            socketURL: socketURL,
            captureResultProvider: { requestID, _ in
                requestID == ready.requestID ? ready : nil
            }
        )
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: directory)
        }

        let reply = try EmbodimentShadowSocketClient.send(
            .init(kind: .captureResult, requestID: ready.requestID),
            socketURL: socketURL
        )
        XCTAssertTrue(reply.ok)
        XCTAssertEqual(reply.viewResource, ready)

        let unknown = try EmbodimentShadowSocketClient.send(
            .init(kind: .captureResult, requestID: "capture-other"),
            socketURL: socketURL
        )
        XCTAssertFalse(unknown.ok)
        XCTAssertEqual(unknown.error, "capture_result_unknown")
    }

    func testCaptureAlignmentUsesHysteresisAcrossBrakingOvershoot() {
        let start: UInt64 = 70_000_000_000
        XCTAssertEqual(
            CaptureAlignmentHysteresis.evaluate(
                errorDegrees: 2.1,
                stableSinceNS: nil,
                at: start
            ).phase,
            .drive
        )
        let entered = CaptureAlignmentHysteresis.evaluate(
            errorDegrees: 1.9,
            stableSinceNS: nil,
            at: start + 1
        )
        XCTAssertEqual(entered.phase, .beginSettling)
        XCTAssertEqual(
            CaptureAlignmentHysteresis.evaluate(
                errorDegrees: 3.8,
                stableSinceNS: entered.stableSinceNS,
                at: start + 179_000_001
            ).phase,
            .awaitSettling
        )
        XCTAssertEqual(
            CaptureAlignmentHysteresis.evaluate(
                errorDegrees: 4.4,
                stableSinceNS: entered.stableSinceNS,
                at: start + 180_000_001
            ).phase,
            .capture
        )
        XCTAssertEqual(
            CaptureAlignmentHysteresis.evaluate(
                errorDegrees: 4.6,
                stableSinceNS: entered.stableSinceNS,
                at: start + 180_000_001
            ),
            CaptureAlignmentDecision(phase: .drive, stableSinceNS: nil)
        )
    }

    private func makeRequest(
        layer: CognitiveControlLayer,
        operation: CognitiveEmbodimentOperation
    ) -> CognitiveEmbodimentRequest {
        CognitiveEmbodimentRequest(
            requestID: "request:\(layer.rawValue)",
            layer: layer,
            reason: "semantic attention goal",
            evidenceIDs: ["evidence:1"],
            lease: EmbodimentLease(
                ownerID: "owner:\(layer.rawValue)",
                priority: 50,
                issuedAtNS: 1_000_000_000,
                durationMilliseconds: 5_000,
                cancellationToken: "cancel:\(layer.rawValue)"
            ),
            operation: operation
        )
    }

    private func shadowRequest(
        id: String,
        layer: CognitiveControlLayer,
        owner: String,
        priority: UInt8,
        now: UInt64,
        durationMilliseconds: UInt64 = 5_000,
        operation: CognitiveEmbodimentOperation
    ) -> CognitiveEmbodimentRequest {
        CognitiveEmbodimentRequest(
            requestID: id,
            layer: layer,
            reason: "shadow test",
            evidenceIDs: ["test:evidence"],
            lease: EmbodimentLease(
                ownerID: owner,
                priority: priority,
                issuedAtNS: now,
                durationMilliseconds: durationMilliseconds,
                cancellationToken: "cancel:\(id)"
            ),
            operation: operation
        )
    }

    private func sceneEntity(
        id: String,
        kind: AttentionTargetKind,
        label: String?,
        observed: Bool,
        lastSeenMilliseconds: Double = 0
    ) -> EmbodimentSceneEntity {
        EmbodimentSceneEntity(
            sceneID: id,
            kind: kind,
            label: label,
            confidence: 0.9,
            observedThisFrame: observed,
            actionEligible: kind == .human,
            bearing: GimbalRelativeBearing(azimuthDegrees: 10, elevationDegrees: 2),
            spatialConfidence: 0.9,
            lastSeenMilliseconds: lastSeenMilliseconds
        )
    }
}

private final class LockedValue: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Bool

    init(_ value: Bool) {
        storedValue = value
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func set(_ value: Bool) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }
}

private final class LockedCognitiveAction: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: CognitiveActionEpisode?

    var value: CognitiveActionEpisode? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func set(_ value: CognitiveActionEpisode) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }
}
#endif
