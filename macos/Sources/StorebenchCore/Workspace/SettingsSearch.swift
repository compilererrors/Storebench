import Foundation

/// Searchable setting labels and their destinations. Account names, credentials and saved values are never indexed.
public enum SettingsSearch {
    public struct Result: Identifiable, Sendable, Equatable {
        public let id, title, summary: String
        public let pane: SettingsNavigation.Pane
        let keywords: String
    }
    public static let catalog: [Result] = [
        .init(id: "general-appearance", title: "Appearance", summary: "Theme, light and dark mode, and contrast.", pane: .general, keywords: "system colors display accessibility"),
        .init(id: "general-storage", title: "Local Storage", summary: "Find the encrypted data folder on this Mac.", pane: .general, keywords: "database location folder finder history reports drafts"),
        .init(id: "general-display", title: "Display Currency", summary: "Choose the currency used to estimate proceeds.", pane: .general, keywords: "money exchange rates USD EUR SEK revenue"),
        .init(id: "general-release-cards", title: "Release Cards", summary: "Expand or minimize new release cards and manage the suggestion.", pane: .general, keywords: "overview continue preparing remember collapsed expanded new releases minimize all default ask later minimera expandera releaser"),
        .init(id: "general-sample", title: "Sample Data", summary: "Explore Storebench with synthetic apps and reports.", pane: .general, keywords: "demo examples load remove"),
        .init(id: "general-preparation", title: "Background Preparation", summary: "Choose how many apps to prepare for Release and Quick Release.", pane: .general, keywords: "refresh sync app list status automatic ahead limit"),
        .init(id: "general-cleanup", title: "Storage Cleanup", summary: "Remove unsent reviews and the images of older AI requests after a number of days.", pane: .general, keywords: "delete old reviews AI images history retention days disk space database size clean"),
        .init(id: "general-performance", title: "Performance", summary: "Cache, memory budget, how long Apple reads are reused and background activity.", pane: .general, keywords: "speed clear cache lifetime RAM storage slow lag battery low power heat requests animation background activity"),
        .init(id: "periods-defaults", title: "Period Defaults", summary: "Remember date ranges, comparison windows, download periods and sync history.", pane: .periods, keywords: "days dates default time range sales analytics finance ASO forget choices"),
        .init(id: "editing-drafts", title: "Local Drafts", summary: "Automatically save listing text and media layouts.", pane: .editing, keywords: "autosave automatic save editing screenshots previews language"),
        .init(id: "editing-confirmations", title: "Confirmations", summary: "Choose which local removal and discard questions to show.", pane: .editing, keywords: "delete remove discard ask again warnings"),
        .init(id: "ai-default", title: "Default AI Service", summary: "Choose the starting service for new cards and translations.", pane: .ai, keywords: "provider model default artificial intelligence"),
        .init(id: "ai-cards", title: "Screenshot Cards", summary: "Choose how new AI card sets start: Quick or Guided, language, size and the app's App Store text.", pane: .ai, keywords: "create media cards screenshots quick guided defaults language display size listing"),
        .init(id: "ai-chatgpt", title: "ChatGPT Plan", summary: "Sign in, select an account and choose its default model.", pane: .ai, keywords: "OpenAI connection login subscription reconnect disconnect"),
        .init(id: "ai-claude", title: "Claude", summary: "Connect an API key and choose a default model.", pane: .ai, keywords: "Anthropic billing connection disconnect"),
        .init(id: "ai-apple", title: "Apple Intelligence", summary: "Check on-device AI and Apple Translation availability.", pane: .ai, keywords: "local offline models language macOS"),
        .init(id: "ai-api", title: "Other API Services", summary: "Connect OpenAI or Google Gemini for cards and translations.", pane: .ai, keywords: "API key connection model billing disconnect"),
        .init(id: "ai-history", title: "AI History", summary: "Inspect saved requests, prompts, instructions and earlier results.", pane: .ai, keywords: "cards variants generations translations screenshots response"),
        .init(id: "security-storage", title: "Encrypted Local Storage", summary: "Change the Storebench password or credential protection.", pane: .security, keywords: "security encryption keychain repeat password lock unlock"),
        .init(id: "security-authentication", title: "Mac Authentication", summary: "Manage Mac authentication and protected Keychain access.", pane: .security, keywords: "Touch ID biometrics password security protection"),
        .init(id: "accounts-connected", title: "Connected Apple Accounts", summary: "Connect or reconnect an App Store Connect API key.", pane: .accounts, keywords: "account issuer key ID p8 team individual disconnect access permissions"),
        .init(id: "accounts-help", title: "Credential Storage and Connection Help", summary: "Understand credential storage and recover a connection.", pane: .accounts, keywords: "Apple account keychain retry reconnect encrypted password"),
        .init(id: "pricing-profiles", title: "Pricing Profiles", summary: "Save shared price models and choose the default profile.", pane: .pricing, keywords: "country percentages index purchasing power PPP Big Mac currency guide price model rename delete"),
        .init(id: "backups-automatic", title: "Automatic Backups", summary: "Choose a folder, schedule, retention and restore passphrase.", pane: .backups, keywords: "backup restore frequency encrypted export recovery copies keep"),
        .init(id: "shortcuts-keyboard", title: "Keyboard Shortcuts", summary: "Find, change or restore keyboard combinations.", pane: .shortcuts, keywords: "command control key navigation hotkey record reset"),
        .init(id: "help-topics", title: "Help and Data Sources", summary: "Find guidance for setup, pricing, protection, reports and publishing.", pane: .help, keywords: "support troubleshooting questions answers permissions sources"),
    ]
    public static func results(for query: String) -> [Result] {
        func normalized(_ value: String) -> String { value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
        let words = normalized(query).split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard !words.isEmpty else { return [] }
        return catalog.enumerated().compactMap { index, result -> (Int, Int, Result)? in
            let title = normalized(result.title), all = normalized([result.title, result.summary, result.pane.title, result.keywords].joined(separator: " "))
            guard words.allSatisfy({ all.contains($0) }) else { return nil }
            let score = words.reduce(0) { $0 + (title.hasPrefix($1) ? 4 : title.contains($1) ? 2 : 0) }
            return (score, index, result)
        }.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 > $1.0 }.map(\.2)
    }
}
