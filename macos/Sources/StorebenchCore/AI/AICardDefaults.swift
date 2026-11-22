import Foundation

/// How a new AI card set starts: Quick, where AI writes the cards from the screenshots and the app's own App Store text, or
/// Guided, with a brief, a message per card and creative directions. Remembered on this Mac and changed in Settings.
public struct AICardDefaults: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        case quick, guided
        public var title: String { self == .quick ? "Quick" : "Guided" }
        public var detail: String {
            self == .quick ? "Choose screenshots and generate. AI writes each card from the screenshot and the app's App Store text."
                : "Write a brief and a message for each card, and choose the style, before generating."
        }
    }
    public var mode: Mode
    public var language: String
    public var targetId: String
    /// Sends the app's own App Store text with the screenshots, so the cards stay about this app.
    public var useListing: Bool

    public init(mode: Mode = .quick, language: String = "en-US", targetId: String = MediaCards.defaultTarget.id, useListing: Bool = true) {
        self.mode = mode
        self.language = StoreLocales.codes.contains(language) ? language : "en-US"
        self.targetId = MediaCards.targets.contains { $0.id == targetId } ? targetId : MediaCards.defaultTarget.id
        self.useListing = useListing
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(mode: (try? values.decode(Mode.self, forKey: .mode)) ?? .quick, language: (try? values.decode(String.self, forKey: .language)) ?? "en-US",
                  targetId: (try? values.decode(String.self, forKey: .targetId)) ?? MediaCards.defaultTarget.id,
                  useListing: (try? values.decode(Bool.self, forKey: .useListing)) ?? true)
    }

    public static let defaultsKey = "aiCards.defaults"
    public static func stored(in defaults: UserDefaults) -> AICardDefaults {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(AICardDefaults.self, from: $0) } ?? AICardDefaults()
    }
    public func save(in defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
