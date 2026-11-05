import Foundation
import Testing
@testable import StorebenchCore

/// The Apple ID transport reads through the guarded, bounded reader: bytes are counted as they arrive, redirects go only to
/// Apple's configured hosts, and a session without a synthetic transport reaches nothing. Synthetic hosts only.
@Suite(.serialized) struct AppleIDTransportTests {
    init() throws { _ = try TestIsolation.require() }

    private func flow(_ name: String, configuration: URLSessionConfiguration = AppleIDTests.configuration()) throws -> (AppleIDSignIn, identity: String, connect: String) {
        let identity = "\(name)-id.appleid.test", connect = "\(name)-connect.appleid.test"
        let origins = AppleIDOrigins(identity: URL(string: "https://\(identity)")!, connect: URL(string: "https://\(connect)")!)
        return (try AppleIDSignIn(appleId: "tester@example.com", origins: origins, configuration: configuration), identity, connect)
    }

    @Test func anAnswerLargerThanTheLimitIsRefusedWithoutAContentLength() async throws {
        let (flow, identity, connect) = try flow("transport-bytes")
        StubProtocol.handle(identity) { _ in (500, [:], Data()) }
        StubProtocol.handle(connect) { request in
            request.url?.path == "/olympus/v1/app/config" ? (200, ["Content-Type": "application/json"], Data(count: AppleIDTransport.signInBytes + 1)) : (404, [:], Data())
        }
        await #expect(throws: AppleIDFailure.unreadable) { try await flow.signIn(password: "synthetic password") }
        #expect(StubProtocol.requests(identity).isEmpty)
    }

    @Test func aRedirectIsFollowedOnlyToAppleHosts() async throws {
        let (refused, identity, connect) = try flow("transport-redirect")
        StubProtocol.handle(identity) { _ in (500, [:], Data()) }
        StubProtocol.handle("elsewhere.appleid.test") { _ in (200, ["Content-Type": "application/json"], Data(#"{"authServiceKey":"elsewherekey"}"#.utf8)) }
        StubProtocol.handle(connect) { request in
            request.url?.path == "/olympus/v1/app/config" ? (302, ["Location": "https://elsewhere.appleid.test/olympus/v1/app/config"], Data()) : (404, [:], Data())
        }
        await #expect(throws: AppleIDFailure.unreadable) { try await refused.signIn(password: "synthetic password") }
        #expect(StubProtocol.requests("elsewhere.appleid.test").isEmpty && StubProtocol.requests(identity).isEmpty)

        let (followed, movedIdentity, movedConnect) = try flow("transport-moved")
        StubProtocol.handle(movedIdentity) { _ in (400, ["Content-Type": "application/json"], Data("{}".utf8)) }
        StubProtocol.handle(movedConnect) { request in
            switch request.url?.path {
            case "/olympus/v1/app/config": (302, ["Location": "/olympus/v1/app/moved-config"], Data())
            case "/olympus/v1/app/moved-config": (200, ["Content-Type": "application/json"], Data(#"{"authServiceKey":"movedkey"}"#.utf8))
            default: (404, [:], Data())
            }
        }
        await #expect(throws: AppleIDFailure.rejected) { try await followed.signIn(password: "synthetic password") }
        #expect(StubProtocol.requests(movedIdentity).first?.url?.query?.contains("widgetKey=movedkey") == true)
    }

    @Test func aSessionWithoutASyntheticTransportReachesNothing() async throws {
        let (flow, identity, connect) = try flow("transport-unregistered", configuration: .ephemeral)
        StubProtocol.handle(connect) { _ in (200, ["Content-Type": "application/json"], Data(#"{"authServiceKey":"key"}"#.utf8)) }
        await #expect(throws: AppleIDFailure.network) { try await flow.signIn(password: "synthetic password") }
        #expect(StubProtocol.requests(connect).isEmpty && StubProtocol.requests(identity).isEmpty)
    }
}
