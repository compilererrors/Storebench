import Foundation

public enum SettingsNavigation {
    public enum Pane: String, CaseIterable, Sendable {
        case general, periods, editing, security, accounts, pricing, backups, shortcuts, help
        public var title: String { rawValue.prefix(1).uppercased() + String(rawValue.dropFirst()) }
        public var icon: String {
            switch self {
            case .general: "display"
            case .periods: "calendar"
            case .editing: "edit"
            case .security: "security"
            case .accounts: "users"
            case .pricing: "pricing"
            case .backups: "backups"
            case .shortcuts: "keyboard"
            case .help: "help"
            }
        }
        public static func restored(_ key: String) -> Self { Self(rawValue: key) ?? .general }
    }
}
