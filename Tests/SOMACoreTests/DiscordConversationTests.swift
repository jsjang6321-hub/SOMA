#if canImport(XCTest)
import Foundation
import XCTest
@testable import SOMACore

final class DiscordConversationTests: XCTestCase {
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
