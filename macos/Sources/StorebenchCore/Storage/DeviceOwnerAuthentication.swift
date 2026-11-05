import Foundation
import LocalAuthentication

public protocol WorkspaceAuthenticating: Sendable {
    func authenticate() async throws
}

public enum WorkspaceAuthenticationFailure: Error, Equatable {
    case cancelled, unavailable, denied
    public var message: String {
        switch self {
        case .cancelled: "Unlock was cancelled. Saved data remains locked; try again when you are ready."
        case .unavailable: "Mac authentication is unavailable. Check your Mac login password or Touch ID in System Settings and try again."
        case .denied: "Your Mac could not authenticate this unlock. Try Touch ID or your Mac login password again."
        }
    }
}

public struct DeviceOwnerAuthentication: WorkspaceAuthenticating {
    public init() {}
    public func authenticate() async throws {
        // Executed native fixtures must never access system authentication or credentials.
        guard !Network.testMode else { throw WorkspaceAuthenticationFailure.unavailable }
        try Task.checkCancellation()
        let request = Request()
        var error: NSError?
        guard request.context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { throw WorkspaceAuthenticationFailure.unavailable }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                request.context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Storebench's saved data and credentials.") { accepted, error in
                    if accepted { continuation.resume() }
                    else {
                        let code = (error as? LAError)?.code
                        continuation.resume(throwing: code == .userCancel || code == .appCancel || code == .systemCancel ? WorkspaceAuthenticationFailure.cancelled : WorkspaceAuthenticationFailure.denied)
                    }
                }
            }
        } onCancel: { request.context.invalidate() }
        try Task.checkCancellation()
    }
    private final class Request: @unchecked Sendable {
        let context = LAContext()
        init() { context.localizedCancelTitle = "Cancel"; context.localizedFallbackTitle = "Use Mac Password" }
        deinit { context.invalidate() }
    }
}
