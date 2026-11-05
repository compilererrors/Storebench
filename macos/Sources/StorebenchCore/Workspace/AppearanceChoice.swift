import Foundation

/// Device-local appearance identifiers; palette metadata comes from the shared design catalog.
public enum AppearanceChoice: String, CaseIterable, Sendable {
    case system, light, lightContrast = "light-contrast", dark, darkContrast = "dark-contrast", paper, midnight, forest
    public init(stored value: String?) { self = value.flatMap(Self.init(rawValue:)) ?? .light }
    public var title: String { self == .system ? "Follow system" : metadata.title }
    public var detail: String { self == .system ? "Follow your Mac’s light and dark appearance." : metadata.description }
    public var scheme: String? { self == .system ? nil : metadata.scheme }
    public var highContrast: Bool { self == .lightContrast || self == .darkContrast }
    private var metadata: StorebenchDesign.Appearance { StorebenchDesign.shared.appearances.first { $0.id == rawValue }! }
    public func palette(systemDark: Bool, increasedContrast: Bool, design: StorebenchDesign = .shared) -> [String: String] {
        let id = self == .system ? systemDark ? "dark" : "light" : rawValue
        let theme = design.appearances.first { $0.id == id }!
        return increasedContrast || theme.highContrast ? theme.increasedTokens : theme.tokens
    }
}

public enum AppearanceContrast {
    public enum Failure: Error { case invalidColor }
    public static func ratio(_ foreground: String, _ background: String) throws -> Double {
        func luminance(_ color: String) throws -> Double {
            guard color.first == "#" else { throw Failure.invalidColor }
            let text = String(color.dropFirst()), expanded = text.count == 3 ? text.map { "\($0)\($0)" }.joined() : text
            guard expanded.count == 6, expanded.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }), let value = UInt32(expanded, radix: 16) else { throw Failure.invalidColor }
            return zip([16, 8, 0], [0.2126, 0.7152, 0.0722]).reduce(0) { sum, pair in
                let channel = Double((value >> pair.0) & 255) / 255
                return sum + pair.1 * (channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4))
            }
        }
        let a = try luminance(foreground), b = try luminance(background)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
    public static func valid(_ palette: [String: String], pairs: [StorebenchDesign.ContrastPair]) -> Bool {
        !pairs.isEmpty && pairs.allSatisfy { pair in
            guard pair.minimum.isFinite, pair.minimum >= 3, pair.minimum <= 21, let foreground = palette[pair.foreground], let background = palette[pair.background], let ratio = try? ratio(foreground, background) else { return false }
            return ratio >= pair.minimum
        }
    }
}
