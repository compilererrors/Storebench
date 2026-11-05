import Foundation

/// About content depends only on public bundle metadata, so it also works before unlocking a workspace.
public struct ApplicationAbout: Sendable, Equatable {
    public let name: String
    public let version, build: String?
    public let contact: SupportContact?
    public static let summary = "Prepare, review and publish App Store releases from your Mac."

    public init(info: [String: String]) {
        func text(_ key: String) -> String? {
            guard let value = info[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
                  value.utf8.count <= 200, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
            return value
        }
        name = text("CFBundleDisplayName") ?? text("CFBundleName") ?? "Storebench"
        version = text("CFBundleShortVersionString")
        build = text("CFBundleVersion")
        contact = try? SupportContact(info: info)
    }
}
