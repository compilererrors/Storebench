import Foundation

/// What a view shows about a signed-in Apple ID. The session and its cookies stay in Core.
public struct AppleIDAccount: Sendable, Equatable {
    public let appleId: String
    public let teams: [String]
    /// Changes with each new sign-in, so screens that need the Apple ID read again.
    public let signedInAt: String
    init(_ session: AppleWebSession) { appleId = session.appleId; teams = session.teams.map(\.name); signedInAt = session.signedInAt }
}

/// A sign-in Apple accepted the password for, waiting for its two-factor code.
public final class AppleIDPendingSignIn: Sendable {
    public struct Phone: Sendable, Equatable, Identifiable { public let id: Int; public let number: String }
    /// The trusted phone numbers Apple can text a code to.
    public let phones: [Phone]
    public let codeLength: Int
    /// True when Apple already sent a sign-in request to the trusted devices.
    public let deviceCode: Bool
    let flow: AppleIDSignIn, accountId: String
    init(flow: AppleIDSignIn, challenge: AppleIDChallenge, accountId: String) {
        self.flow = flow; self.accountId = accountId
        phones = challenge.phones.map { Phone(id: $0.id, number: $0.number) }; codeLength = challenge.codeLength; deviceCode = challenge.deviceCode
    }
}

/// The next step after the Apple ID and password: signed in, or a two-factor code to enter.
public enum AppleIDSignInStep: Sendable {
    case signedIn(AppleIDAccount)
    case verify(AppleIDPendingSignIn)
}

extension WorkspaceSession {
    /// The Apple ID signed in for this account, as views show it; nil when none is.
    public func appleIDAccount(accountId: String, writer: VaultWriter? = nil) throws -> AppleIDAccount? {
        try requireOwnWorkspace()
        return try appleIDSession(accountId: accountId, writer: writer).map(AppleIDAccount.init)
    }

    /// Sends the Apple ID and password. The password is saved for the next sign-in only after Apple accepted it, and only
    /// when `savePassword` is on. A sign-in that needs no code is kept for this account at once.
    public func signInAppleID(_ appleId: String, password: String, savePassword: Bool, accountId: String, writer: VaultWriter,
                              origins: AppleIDOrigins = .apple, configuration: URLSessionConfiguration = .ephemeral) async throws -> AppleIDSignInStep {
        try requireOwnWorkspace()
        guard try accounts().contains(where: { $0.id == accountId }) else { throw AccountFailure.notFound }
        let flow = try AppleIDSignIn(appleId: appleId, origins: origins, configuration: configuration)
        let challenge = try await flow.signIn(password: password)
        if savePassword { try? saveAppleIDPassword(password, appleId: appleId, accountId: accountId, writer: writer) }
        guard let challenge else { return .signedIn(try await keepAppleID(try await flow.finish(), accountId: accountId, writer: writer)) }
        return .verify(AppleIDPendingSignIn(flow: flow, challenge: challenge, accountId: accountId))
    }

    /// Checks the two-factor code, from a trusted device or the texted `phone`, and keeps the session for the sign-in's account.
    public func verifyAppleID(_ pending: AppleIDPendingSignIn, code: String, phone: Int?, writer: VaultWriter) async throws -> AppleIDAccount {
        try requireOwnWorkspace()
        return try await keepAppleID(try await pending.flow.verify(code: code, phone: phone), accountId: pending.accountId, writer: writer)
    }

    /// Asks Apple to text the two-factor code to one of the sign-in's trusted phone numbers.
    public func textAppleIDCode(_ pending: AppleIDPendingSignIn, phone: Int) async throws {
        try await pending.flow.requestText(phone: phone)
    }

    private func keepAppleID(_ value: AppleWebSession, accountId: String, writer: VaultWriter) throws -> AppleIDAccount {
        try saveAppleIDSession(value, accountId: accountId, writer: writer)
        return AppleIDAccount(value)
    }
}
