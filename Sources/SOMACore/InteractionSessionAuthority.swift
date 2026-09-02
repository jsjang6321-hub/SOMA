import Foundation

/// The authority attached to one live human interaction. It is deliberately
/// separate from face recognition: recognition selects an opaque local person
/// reference, while this role determines what that person may ask SOMA to do.
public enum SOMAInteractionAuthority: String, Codable, CaseIterable, Sendable {
    case administrator
    case participant
}

public enum SOMASessionCapabilityScope: Equatable, Sendable {
    /// End only the live conversation that owns this capability. This is
    /// separate from embodiment authority: every participant may end their
    /// own conversation, but no capability may end another person's session.
    case conversationControl
    case personContext(UUID)
    /// A bounded projection of the people SOMA currently recognizes and the
    /// administrator's registered-person memory. This never includes face
    /// embeddings, raw frames, or transcript text.
    case identityRoster
    case identityManagement
    /// External work may read or change resources outside SOMA's embodied
    /// sensor loop, so only the local administrator can delegate or inspect it.
    case externalTaskDelegation
    /// A current host-screen image can expose private desktop content. Only a
    /// locally recognized administrator may authorize this bounded read.
    case hostScreenObservation
    /// Pointer and keyboard synthesis changes the host computer and therefore
    /// remains administrator-only in addition to requiring a current explicit
    /// participant turn through `cognitiveBasis`.
    case hostInputControl
    case embodimentControl
    /// Records a privacy-bounded outcome from a tool call made by this live
    /// session. It grants no additional read, write, or motor authority.
    case cognitiveEvidence
    /// Validates whether an L2 authorization basis is grounded in the current
    /// participant turn. Autonomous goals need only a valid live session;
    /// explicit bases additionally require fresh speech evidence owned by L0.
    case cognitiveBasis(L2CognitiveAuthorizationBasis)
    /// Recall of SOMA's own episodic memory. It is the owner's memory, so any
    /// valid session may query it; which person a memory relates to is inferred
    /// from context rather than required up front.
    case episodicRecall
}

public enum SOMASessionCapabilityError: Error, Equatable, LocalizedError {
    case required
    case invalid
    case expired
    case personContextDenied
    case identityRosterDenied
    case identityManagementDenied
    case externalTaskDelegationDenied
    case hostScreenObservationDenied
    case hostInputControlDenied
    case embodimentDenied
    case currentParticipantTurnRequired

    public var errorDescription: String? {
        switch self {
        case .required: "A SOMA interaction capability is required"
        case .invalid: "The SOMA interaction capability is invalid"
        case .expired: "The SOMA interaction capability has expired"
        case .personContextDenied: "This session may access only its own person context"
        case .identityRosterDenied: "Only the local administrator may read the identity roster"
        case .identityManagementDenied: "Only the local administrator may enroll or remove local identities"
        case .externalTaskDelegationDenied: "Only the local administrator may delegate or inspect external tasks"
        case .hostScreenObservationDenied: "Only the local administrator may observe the host screen"
        case .hostInputControlDenied: "Only the local administrator may control host input"
        case .embodimentDenied: "Only the local administrator may control SOMA embodiment"
        case .currentParticipantTurnRequired: "This cognitive action requires the current participant turn"
        }
    }
}

/// Issues short-lived, opaque capabilities for one Live Voice participant.
/// The token is passed only in developer context to the local MCP child and is
/// never written to trace output. L0 remains the authority that validates it.
public final class SOMASessionCapabilityStore: @unchecked Sendable {
    private struct Grant {
        let personEntityID: UUID
        let authority: SOMAInteractionAuthority
        let expiresAtNS: UInt64
        var participantTurnExpiresAtNS: UInt64?
    }

    private let lock = NSLock()
    private var grants: [String: Grant] = [:]
    private let maximumGrants: Int
    private let defaultLifetimeNS: UInt64
    private let participantTurnLifetimeNS: UInt64

    public init(
        maximumGrants: Int = 128,
        lifetimeSeconds: TimeInterval = 15 * 60,
        participantTurnLifetimeSeconds: TimeInterval = 120
    ) {
        self.maximumGrants = max(8, maximumGrants)
        let boundedSeconds = min(max(lifetimeSeconds, 30), 60 * 60)
        defaultLifetimeNS = UInt64((boundedSeconds * 1_000_000_000).rounded())
        let boundedTurnSeconds = min(max(participantTurnLifetimeSeconds, 5), 5 * 60)
        participantTurnLifetimeNS = UInt64((boundedTurnSeconds * 1_000_000_000).rounded())
    }

    public func issue(
        personEntityID: UUID,
        authority: SOMAInteractionAuthority,
        at monotonicNS: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> String {
        lock.lock()
        defer { lock.unlock() }
        removeExpiredLocked(at: monotonicNS)
        if grants.count >= maximumGrants,
           let arbitrary = grants.keys.sorted().first {
            grants.removeValue(forKey: arbitrary)
        }
        let token = UUID().uuidString.lowercased()
        grants[token] = Grant(
            personEntityID: personEntityID,
            authority: authority,
            expiresAtNS: monotonicNS &+ defaultLifetimeNS,
            participantTurnExpiresAtNS: nil
        )
        return token
    }

    public func observeParticipantTurn(
        token: String?,
        active: Bool,
        at monotonicNS: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> Result<Void, SOMASessionCapabilityError> {
        guard let token,
              token.count == 36,
              token.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || $0 == "-"
              }) else {
            return .failure(.required)
        }
        lock.lock()
        defer { lock.unlock() }
        removeExpiredLocked(at: monotonicNS)
        guard var grant = grants[token] else { return .failure(.invalid) }
        guard monotonicNS < grant.expiresAtNS else {
            grants.removeValue(forKey: token)
            return .failure(.expired)
        }
        grant.participantTurnExpiresAtNS = active
            ? monotonicNS &+ participantTurnLifetimeNS
            : nil
        grants[token] = grant
        return .success(())
    }

    public func authorize(
        token: String?,
        scope: SOMASessionCapabilityScope,
        at monotonicNS: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> Result<Void, SOMASessionCapabilityError> {
        guard let token,
              token.count == 36,
              token.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || $0 == "-"
              }) else {
            return .failure(.required)
        }
        lock.lock()
        defer { lock.unlock() }
        removeExpiredLocked(at: monotonicNS)
        guard let grant = grants[token] else {
            return .failure(.invalid)
        }
        guard monotonicNS < grant.expiresAtNS else {
            grants.removeValue(forKey: token)
            return .failure(.expired)
        }
        switch scope {
        case .conversationControl, .cognitiveEvidence:
            return .success(())
        case let .cognitiveBasis(basis):
            if basis == .autonomousGoal { return .success(()) }
            guard let turnExpiry = grant.participantTurnExpiresAtNS,
                  monotonicNS < turnExpiry else {
                return .failure(.currentParticipantTurnRequired)
            }
            return .success(())
        case let .personContext(personEntityID):
            return grant.authority == .administrator || grant.personEntityID == personEntityID
                ? .success(())
                : .failure(.personContextDenied)
        case .identityRoster:
            return grant.authority == .administrator
                ? .success(())
                : .failure(.identityRosterDenied)
        case .identityManagement:
            return grant.authority == .administrator
                ? .success(())
                : .failure(.identityManagementDenied)
        case .externalTaskDelegation:
            return grant.authority == .administrator
                ? .success(())
                : .failure(.externalTaskDelegationDenied)
        case .hostScreenObservation:
            return grant.authority == .administrator
                ? .success(())
                : .failure(.hostScreenObservationDenied)
        case .hostInputControl:
            return grant.authority == .administrator
                ? .success(())
                : .failure(.hostInputControlDenied)
        case .embodimentControl:
            // Looking, tracking, exploring, and brief expression are SOMA's
            // ordinary embodied conversation, not administrator-only work.
            // L0 still bounds every request through its lease and actuator
            // policy. Administrator-only external work is not exposed here.
            return .success(())
        case .episodicRecall:
            // SOMA's own memory; any valid session may recall shared history.
            return .success(())
        }
    }

    private func removeExpiredLocked(at monotonicNS: UInt64) {
        grants = grants.filter { _, grant in monotonicNS < grant.expiresAtNS }
    }
}
