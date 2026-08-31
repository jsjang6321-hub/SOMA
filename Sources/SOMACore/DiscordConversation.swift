import CryptoKit
import Foundation

public enum SOMADiscordInvocationMention: String, Codable, CaseIterable, Equatable, Sendable {
    case botUser
    case managedRole
}

public struct SOMADiscordSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var channelID: String
    public var labmanagerBotUserID: String
    public var labmanagerRoleID: String
    public var invocationMention: SOMADiscordInvocationMention
    public var forwardAdministratorSpeech: Bool
    public var readLabmanagerRepliesAloud: Bool
    public var responseTimeoutSeconds: Int

    public init(
        enabled: Bool = false,
        channelID: String = "",
        labmanagerBotUserID: String = "",
        labmanagerRoleID: String = "",
        invocationMention: SOMADiscordInvocationMention = .botUser,
        forwardAdministratorSpeech: Bool = true,
        readLabmanagerRepliesAloud: Bool = true,
        responseTimeoutSeconds: Int = 90
    ) {
        self.enabled = enabled
        self.channelID = Self.normalizedSnowflake(channelID) ?? ""
        self.labmanagerBotUserID = Self.normalizedSnowflake(labmanagerBotUserID) ?? ""
        self.labmanagerRoleID = Self.normalizedSnowflake(labmanagerRoleID) ?? ""
        self.invocationMention = invocationMention
        self.forwardAdministratorSpeech = forwardAdministratorSpeech
        self.readLabmanagerRepliesAloud = readLabmanagerRepliesAloud
        self.responseTimeoutSeconds = min(max(responseTimeoutSeconds, 15), 300)
    }

    public var isConfigured: Bool {
        enabled
            && Self.normalizedSnowflake(channelID) != nil
            && Self.normalizedSnowflake(labmanagerBotUserID) != nil
            && (invocationMention == .botUser || Self.normalizedSnowflake(labmanagerRoleID) != nil)
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case channelID
        case labmanagerBotUserID
        case labmanagerRoleID
        case invocationMention
        case forwardAdministratorSpeech
        case readLabmanagerRepliesAloud
        case responseTimeoutSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
            channelID: try container.decodeIfPresent(String.self, forKey: .channelID) ?? "",
            labmanagerBotUserID: try container.decodeIfPresent(String.self, forKey: .labmanagerBotUserID) ?? "",
            labmanagerRoleID: try container.decodeIfPresent(String.self, forKey: .labmanagerRoleID) ?? "",
            invocationMention: try container.decodeIfPresent(SOMADiscordInvocationMention.self, forKey: .invocationMention) ?? .botUser,
            forwardAdministratorSpeech: try container.decodeIfPresent(Bool.self, forKey: .forwardAdministratorSpeech) ?? true,
            readLabmanagerRepliesAloud: try container.decodeIfPresent(Bool.self, forKey: .readLabmanagerRepliesAloud) ?? true,
            responseTimeoutSeconds: try container.decodeIfPresent(Int.self, forKey: .responseTimeoutSeconds) ?? 90
        )
    }

    public static func normalizedSnowflake(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (5...24).contains(trimmed.count),
              trimmed.allSatisfy(\.isNumber),
              UInt64(trimmed) != nil else { return nil }
        return trimmed
    }
}

public enum SOMADiscordSecretStoreError: LocalizedError, Equatable, Sendable {
    case invalidToken
    case corruptSecret
    case insecurePermissions

    public var errorDescription: String? {
        switch self {
        case .invalidToken: "Discord bot token is empty or invalid"
        case .corruptSecret: "Discord bot token could not be decrypted"
        case .insecurePermissions: "Discord credential files must be owner-only"
        }
    }
}

public struct SOMADiscordSecretStore: Sendable {
    public let directoryURL: URL
    private let keyURL: URL
    private let sealedTokenURL: URL

    public init(directoryURL: URL = Self.defaultDirectoryURL()) {
        self.directoryURL = directoryURL
        keyURL = directoryURL.appendingPathComponent("discord-token.key")
        sealedTokenURL = directoryURL.appendingPathComponent("discord-token.sealed")
    }

    public static func defaultDirectoryURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SOMA/secrets", isDirectory: true)
    }

    public func loadToken() throws -> String? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sealedTokenURL.path) else { return nil }
        try requireOwnerOnlyPermissions(of: directoryURL)
        try requireOwnerOnlyPermissions(of: keyURL)
        try requireOwnerOnlyPermissions(of: sealedTokenURL)
        let keyData = try Data(contentsOf: keyURL, options: .mappedIfSafe)
        let sealedData = try Data(contentsOf: sealedTokenURL, options: .mappedIfSafe)
        guard keyData.count == 32,
              let sealedBox = try? ChaChaPoly.SealedBox(combined: sealedData),
              let cleartext = try? ChaChaPoly.open(
                  sealedBox,
                  using: SymmetricKey(data: keyData)
              ),
              let token = String(data: cleartext, encoding: .utf8),
              token.count >= 20 else {
            throw SOMADiscordSecretStoreError.corruptSecret
        }
        return token
    }

    public func saveToken(_ rawToken: String) throws {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count >= 20, token.count <= 256, !token.contains("\n") else {
            throw SOMADiscordSecretStoreError.invalidToken
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        let keyData: Data
        if fileManager.fileExists(atPath: keyURL.path) {
            try requireOwnerOnlyPermissions(of: keyURL)
            keyData = try Data(contentsOf: keyURL, options: .mappedIfSafe)
            guard keyData.count == 32 else { throw SOMADiscordSecretStoreError.corruptSecret }
        } else {
            let key = SymmetricKey(size: .bits256)
            keyData = key.withUnsafeBytes { Data($0) }
            try keyData.write(to: keyURL, options: .withoutOverwriting)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        }
        let sealed = try ChaChaPoly.seal(Data(token.utf8), using: SymmetricKey(data: keyData))
        try sealed.combined.write(to: sealedTokenURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sealedTokenURL.path)
    }

    public func deleteToken() throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: sealedTokenURL.path) {
            try requireOwnerOnlyPermissions(of: sealedTokenURL)
            try fileManager.removeItem(at: sealedTokenURL)
        }
    }

    private func requireOwnerOnlyPermissions(of url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o077 == 0 else {
            throw SOMADiscordSecretStoreError.insecurePermissions
        }
    }
}

public struct SOMADiscordMessage: Codable, Equatable, Sendable {
    public struct Author: Codable, Equatable, Sendable {
        public let id: String
        public let bot: Bool?

        public init(id: String, bot: Bool? = nil) {
            self.id = id
            self.bot = bot
        }
    }

    public let id: String
    public let channelID: String
    public let author: Author
    public let content: String

    enum CodingKeys: String, CodingKey {
        case id
        case channelID = "channel_id"
        case author
        case content
    }

    public init(id: String, channelID: String, author: Author, content: String) {
        self.id = id
        self.channelID = channelID
        self.author = author
        self.content = content
    }
}

public protocol SOMADiscordHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

public struct SOMADiscordURLSessionTransport: SOMADiscordHTTPTransport, Sendable {
    public init() {}

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }
}

public enum SOMADiscordClientError: LocalizedError, Equatable, Sendable {
    case invalidConfiguration
    case invalidResponse
    case localRateLimit
    case rejected(Int, String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "Discord channel or Labmanager invocation IDs are invalid"
        case .invalidResponse: "Discord returned an invalid response"
        case .localRateLimit: "Discord voice forwarding is limited to three requests per minute"
        case let .rejected(status, message): "Discord rejected the request (\(status)): \(message)"
        }
    }
}

public actor SOMADiscordConversationClient {
    private let settings: SOMADiscordSettings
    private let token: String
    private let transport: any SOMADiscordHTTPTransport
    private var deliveredMessageIDs = Set<String>()
    private var requestInFlight = false
    private var requestDates: [Date] = []

    public init(
        settings: SOMADiscordSettings,
        token: String,
        transport: any SOMADiscordHTTPTransport = SOMADiscordURLSessionTransport()
    ) {
        self.settings = settings
        self.token = token
        self.transport = transport
    }

    public func validateConnection() async throws -> String {
        guard settings.isConfigured else { throw SOMADiscordClientError.invalidConfiguration }
        let identityRequest = try makeRequest(path: "users/@me", method: "GET")
        let (data, response) = try await perform(identityRequest)
        guard (200...299).contains(response.statusCode),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let username = object["username"] as? String else {
            throw rejection(from: data, response: response)
        }

        for path in [
            "channels/\(settings.channelID)",
            "channels/\(settings.channelID)/messages?limit=1",
        ] {
            let accessRequest = try makeRequest(path: path, method: "GET")
            let (accessData, accessResponse) = try await perform(accessRequest)
            guard (200...299).contains(accessResponse.statusCode) else {
                throw rejection(from: accessData, response: accessResponse)
            }
        }
        return username
    }

    public func forwardAdministratorTranscript(
        _ rawText: String,
        conversationID: String?
    ) async throws -> SOMADiscordMessage? {
        guard settings.isConfigured else { throw SOMADiscordClientError.invalidConfiguration }
        while requestInFlight {
            try await Task.sleep(for: .milliseconds(250))
        }
        requestInFlight = true
        defer { requestInFlight = false }
        let now = Date()
        requestDates.removeAll { now.timeIntervalSince($0) >= 60 }
        guard requestDates.count < 3 else { throw SOMADiscordClientError.localRateLimit }
        let correlationID = "vc-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            .lowercased().prefix(12)
        let text = Self.normalizedOutboundText(
            rawText,
            settings: settings,
            conversationID: conversationID,
            correlationID: String(correlationID)
        )
        guard !text.isEmpty else { return nil }
        let sent = try await createMessage(text)
        requestDates.append(now)
        return try await waitForLabmanagerReply(after: sent.id, correlationID: String(correlationID))
    }

    public static func normalizedOutboundText(
        _ rawText: String,
        settings: SOMADiscordSettings,
        conversationID: String?,
        correlationID: String
    ) -> String {
        let normalized = rawText
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let correlation = correlationID.lowercased()
        guard !normalized.isEmpty,
              settings.isConfigured,
              correlation.range(of: #"^vc-[0-9a-f]{12}$"#, options: .regularExpression) != nil else { return "" }
        let mention: String
        switch settings.invocationMention {
        case .botUser:
            mention = "<@\(settings.labmanagerBotUserID)>"
        case .managedRole:
            mention = "<@&\(settings.labmanagerRoleID)>"
        }
        let session = conversationID
            .map { String($0.filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(24)) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let sessionTag = session.map { " [SOMA session:\($0)]" } ?? ""
        return String("\(mention) 🎙️ voice [voice-corr:\(correlation)]\(sessionTag) \(normalized)".prefix(1_900))
    }

    public static func spokenReply(from rawText: String) -> String {
        var text = rawText
        text = text.replacingOccurrences(
            of: #"<[@#&]!?[0-9]+>"#,
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(of: "```", with: " ")
        text = text.replacingOccurrences(of: "`", with: "")
        text = text.replacingOccurrences(
            of: #"\[voice-corr:vc-[0-9a-f]{12}\]"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(of: #"https?://\S+"#, with: "링크", options: .regularExpression)
        return String(
            text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(1_200)
        )
    }

    public static func shouldForwardTranscript(_ rawText: String) -> Bool {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        let controllerPrefixes = [
            "SOMA_DISCORD_LABMANAGER_REPLY",
            "SOMA_HERMES_TASK_RESULT",
            "SOMA_HERMES_DELEGATION_ACCEPTED",
            "SOMA_EXACT_OPENING",
        ]
        return !controllerPrefixes.contains { text.hasPrefix($0) }
    }

    private func createMessage(_ content: String) async throws -> SOMADiscordMessage {
        let allowedMentions: [String: Any]
        switch settings.invocationMention {
        case .botUser:
            allowedMentions = [
                "parse": [],
                "users": [settings.labmanagerBotUserID],
                "replied_user": false,
            ]
        case .managedRole:
            allowedMentions = [
                "parse": [],
                "roles": [settings.labmanagerRoleID],
                "replied_user": false,
            ]
        }
        let body: [String: Any] = [
            "content": content,
            "allowed_mentions": allowedMentions,
        ]
        let request = try makeRequest(
            path: "channels/\(settings.channelID)/messages",
            method: "POST",
            body: JSONSerialization.data(withJSONObject: body)
        )
        let (data, response) = try await perform(request)
        guard (200...299).contains(response.statusCode) else {
            throw rejection(from: data, response: response)
        }
        return try JSONDecoder().decode(SOMADiscordMessage.self, from: data)
    }

    private func waitForLabmanagerReply(
        after sentMessageID: String,
        correlationID: String
    ) async throws -> SOMADiscordMessage? {
        let deadline = Date().addingTimeInterval(TimeInterval(settings.responseTimeoutSeconds))
        let marker = "[voice-corr:\(correlationID)]"
        var cursor = sentMessageID
        while Date() < deadline {
            try await Task.sleep(for: .seconds(2))
            let request = try makeRequest(
                path: "channels/\(settings.channelID)/messages?after=\(cursor)&limit=50",
                method: "GET"
            )
            let (data, response) = try await perform(request)
            guard (200...299).contains(response.statusCode) else {
                throw rejection(from: data, response: response)
            }
            let messages = try JSONDecoder().decode([SOMADiscordMessage].self, from: data)
                .sorted { (UInt64($0.id) ?? 0) < (UInt64($1.id) ?? 0) }
            if let newest = messages.last { cursor = newest.id }
            if let reply = messages.first(where: {
                $0.channelID == settings.channelID
                    && $0.author.id == settings.labmanagerBotUserID
                    && $0.author.bot == true
                    && $0.content.localizedCaseInsensitiveContains(marker)
                    && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !deliveredMessageIDs.contains($0.id)
            }) {
                deliveredMessageIDs.insert(reply.id)
                if deliveredMessageIDs.count > 256 {
                    deliveredMessageIDs.removeAll(keepingCapacity: true)
                    deliveredMessageIDs.insert(reply.id)
                }
                return reply
            }
        }
        return nil
    }

    private func makeRequest(path: String, method: String, body: Data? = nil) throws -> URLRequest {
        guard let url = URL(string: "https://discord.com/api/v10/\(path)") else {
            throw SOMADiscordClientError.invalidConfiguration
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("SOMA (https://github.com/jsjang6321-hub/SOMA, 1.0)", forHTTPHeaderField: "User-Agent")
        request.httpBody = body
        return request
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = request
        for _ in 0..<3 {
            let (data, response) = try await transport.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw SOMADiscordClientError.invalidResponse
            }
            guard http.statusCode == 429 else { return (data, http) }
            let retry = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["retry_after"] as? Double
                ?? 1
            try await Task.sleep(for: .seconds(min(max(retry, 0.25), 30)))
            request.timeoutInterval = max(request.timeoutInterval, retry + 5)
        }
        throw SOMADiscordClientError.rejected(429, "rate limit retry exhausted")
    }

    private func rejection(from data: Data, response: HTTPURLResponse) -> SOMADiscordClientError {
        let message = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String)
            ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
        return .rejected(response.statusCode, String(message.prefix(240)))
    }
}
