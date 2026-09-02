#if canImport(XCTest)
import Foundation
import XCTest
@testable import SOMACore

final class DiscordConversationTests: XCTestCase {
    func testConfiguredDiscordRoundTripWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["SOMA_RUN_LIVE_DISCORD_SMOKE"] == "1" else {
            throw XCTSkip("live Discord smoke test requires explicit opt-in")
        }
        let settings = try SOMAControlSettingsStore().load().discord
        let token = try XCTUnwrap(try SOMADiscordSecretStore().loadToken())
        let client = SOMADiscordConversationClient(settings: settings, token: token)

        let username = try await client.validateConnection()
        XCTAssertFalse(username.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty)
        let reply = try await client.forwardAdministratorTranscript(
            "SOMA 로컬 우선 Discord 후속응답 시운전입니다. voice-corr 표식을 그대로 포함해 '연동 확인'이라고 짧게 회신해 주세요.",
            conversationID: "discord-follow-up-smoke"
        )
        XCTAssertNotNil(reply)
    }

    func testFollowUpWaitsForPrimaryLocalResponseAndCarriesTurnContext() throws {
        var coordinator = SOMADiscordFollowUpCoordinator()
        let turnID = try XCTUnwrap(coordinator.registerUserTurn(
            threadID: "thread-1",
            text: "오늘 운영 상태를 확인해 줘"
        ))

        coordinator.recordAssistantTranscript("제가 확인한 로컬 상태는 정상입니다.")
        XCTAssertTrue(coordinator.acceptReply(
            turnID: turnID,
            messageID: "123456789012345678",
            reply: "Labmanager 기준으로 배포 작업은 아직 진행 중입니다."
        ))
        XCTAssertNil(coordinator.nextDelivery(canDeliver: true))

        coordinator.responseFinished()
        let delivery = try XCTUnwrap(coordinator.nextDelivery(canDeliver: true))
        XCTAssertEqual(delivery.turnID, turnID)
        XCTAssertEqual(delivery.messageID, "123456789012345678")
        XCTAssertTrue(delivery.controllerText.hasPrefix("SOMA_DISCORD_LABMANAGER_REPLY\n{"))
        XCTAssertTrue(delivery.controllerText.contains("오늘 운영 상태를 확인해 줘"))
        XCTAssertTrue(delivery.controllerText.contains("제가 확인한 로컬 상태는 정상입니다."))
        XCTAssertTrue(delivery.controllerText.contains("아직 진행 중입니다."))
        XCTAssertNil(coordinator.nextDelivery(canDeliver: true))
    }

    func testFollowUpCanArriveBeforeLocalTranscriptAndStillDeliversAfterCompletion() throws {
        var coordinator = SOMADiscordFollowUpCoordinator()
        let turnID = try XCTUnwrap(coordinator.registerUserTurn(
            threadID: "thread-2",
            text: "Labmanager에게 물어봐"
        ))
        XCTAssertTrue(coordinator.acceptReply(
            turnID: turnID,
            messageID: "223456789012345678",
            reply: "확인했습니다."
        ))
        XCTAssertNil(coordinator.nextDelivery(canDeliver: true))

        coordinator.responseFinished()
        let delivery = try XCTUnwrap(coordinator.nextDelivery(canDeliver: true))
        XCTAssertTrue(delivery.controllerText.contains("\"local_response\""))
        XCTAssertTrue(delivery.controllerText.contains("Labmanager에게 물어봐"))
        coordinator.responseFinished()
        XCTAssertNil(coordinator.nextDelivery(canDeliver: true))
    }

    func testNewParticipantTurnReleasesAnInterruptedPrimaryTurnForLaterFollowUp() throws {
        var coordinator = SOMADiscordFollowUpCoordinator()
        let firstTurnID = try XCTUnwrap(coordinator.registerUserTurn(
            threadID: "thread-3",
            text: "첫 번째 질문"
        ))
        _ = coordinator.registerUserTurn(threadID: "thread-3", text: "두 번째 질문")
        XCTAssertTrue(coordinator.acceptReply(
            turnID: firstTurnID,
            messageID: "323456789012345678",
            reply: "첫 번째 질문의 외부 답변"
        ))

        XCTAssertNotNil(coordinator.nextDelivery(canDeliver: true))
    }

    func testRejectedRealtimeHandoffIsNotRetried() throws {
        var coordinator = SOMADiscordFollowUpCoordinator()
        let turnID = try XCTUnwrap(coordinator.registerUserTurn(
            threadID: "thread-4",
            text: "외부 상태를 확인해 줘"
        ))
        coordinator.responseFinished()
        XCTAssertTrue(coordinator.acceptReply(
            turnID: turnID,
            messageID: "423456789012345678",
            reply: "외부 상태 응답"
        ))
        XCTAssertNotNil(coordinator.nextDelivery(canDeliver: true))

        coordinator.discardInFlightDelivery()
        XCTAssertNil(coordinator.nextDelivery(canDeliver: true))
    }

    func testSecretStoreRoundTripsWithoutPersistingPlaintext() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("soma-discord-secret-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SOMADiscordSecretStore(directoryURL: root)
        let token = "test.discord.token.with-sufficient-length"

        try store.saveToken(token)

        XCTAssertEqual(try store.loadToken(), token)
        let sealed = try Data(contentsOf: root.appendingPathComponent("discord-token.sealed"))
        XCTAssertFalse(String(decoding: sealed, as: UTF8.self).contains(token))
        let directoryMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(directoryMode.intValue & 0o077, 0)
        try store.deleteToken()
        XCTAssertNil(try store.loadToken())
    }

    func testVerifiedTranscriptPostsWithBoundedMentionsAndAcceptsOnlyLabmanagerReply() async throws {
        let channelID = "123456789012345678"
        let labmanagerID = "987654321098765432"
        let labmanagerRoleID = "876543210987654321"
        let transport = DiscordMockTransport(responses: [
            .init(
                status: 200,
                json: """
                {"id":"100000000000000001","channel_id":"\(channelID)","author":{"id":"111111111111111111","bot":true},"content":"sent"}
                """
            ),
            .init(
                status: 200,
                json: """
                [{"id":"100000000000000002","channel_id":"\(channelID)","author":{"id":"222222222222222222","bot":true},"content":"ignore"},
                 {"id":"100000000000000004","channel_id":"\(channelID)","author":{"id":"\(labmanagerID)","bot":true},"content":"wrong request"},
                 {"id":"100000000000000003","channel_id":"\(channelID)","author":{"id":"\(labmanagerID)","bot":true},"content":"처리했습니다 {{CORRELATION}}"}]
                """
            ),
        ])
        let client = SOMADiscordConversationClient(
            settings: .init(
                enabled: true,
                channelID: channelID,
                labmanagerBotUserID: labmanagerID,
                labmanagerRoleID: labmanagerRoleID,
                responseTimeoutSeconds: 15
            ),
            token: "test-token-with-sufficient-length",
            transport: transport
        )

        let reply = try await client.forwardAdministratorTranscript(
            "다음 작업을 확인해 줘",
            conversationID: "conversation-1"
        )

        XCTAssertEqual(reply?.author.id, labmanagerID)
        XCTAssertTrue(reply?.content.hasPrefix("처리했습니다 [voice-corr:vc-") == true)
        let requests = transport.capturedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertTrue(requests[1].url?.absoluteString.contains("after=100000000000000001") == true)
        let body = try XCTUnwrap(requests[0].httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let content = try XCTUnwrap(object["content"] as? String)
        XCTAssertTrue(content.hasPrefix("<@\(labmanagerID)> 🎙️ voice [voice-corr:vc-") )
        let mentions = try XCTUnwrap(object["allowed_mentions"] as? [String: Any])
        XCTAssertEqual(mentions["users"] as? [String], [labmanagerID])
        XCTAssertEqual(mentions["parse"] as? [String], [])
    }
}

private final class DiscordMockTransport: SOMADiscordHTTPTransport, @unchecked Sendable {
    struct Response {
        let status: Int
        let json: String
    }

    private let lock = NSLock()
    private var responses: [Response]
    private var requests: [URLRequest] = []

    init(responses: [Response]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        var response = lock.withLock {
            requests.append(request)
            return responses.removeFirst()
        }
        if response.json.contains("{{CORRELATION}}") {
            let postedContent = lock.withLock { requests.first?.httpBody }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["content"] as? String
            let marker = postedContent.flatMap { content in
                content.range(
                    of: #"\[voice-corr:vc-[0-9a-f]{12}\]"#,
                    options: .regularExpression
                ).map { String(content[$0]) }
            } ?? ""
            response = Response(status: response.status, json: response.json.replacingOccurrences(of: "{{CORRELATION}}", with: marker))
        }
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: [:]
        )!
        return (Data(response.json.utf8), http)
    }

    func capturedRequests() -> [URLRequest] {
        lock.withLock { requests }
    }
}
#endif
