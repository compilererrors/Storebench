import AppKit
import StorebenchCore
import SwiftUI

enum StorebenchTheme {
    static let design = StorebenchDesign.shared
    static func color(_ token: String) -> Color { Color(nsColor: nativeColor(token)) }
    static func nativeColor(_ token: String) -> NSColor {
        // Track UI changes while retaining a current, thread-safe snapshot for AppKit-owned windows.
        _ = StorebenchAppearancePreferences.shared.choice
        _ = StorebenchAppearancePreferences.shared.increasedContrast
        return NSColor(name: nil) { appearance in
            let (choice, increasedContrast) = StorebenchAppearancePreferences.shared.colorSnapshot()
            let match = appearance.bestMatch(from: [.accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua, .darkAqua, .aqua])
            let dark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
            let increased = increasedContrast || match == .accessibilityHighContrastDarkAqua || match == .accessibilityHighContrastAqua
            guard let color = choice.palette(systemDark: dark, increasedContrast: increased)[token] else { preconditionFailure("Shared color token is missing.") }
            let hex = color.replacingOccurrences(of: "#", with: "")
            guard let value = UInt32(hex.count == 3 ? hex.map { "\($0)\($0)" }.joined() : hex, radix: 16) else { preconditionFailure("Shared color token is invalid.") }
            return NSColor(srgbRed: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, alpha: 1)
        }
    }
    static var ink: Color { color("color-text") }; static var muted: Color { color("color-text-muted") }; static var subtle: Color { color("color-text-subtle") }
    static var page: Color { color("color-page") }; static var surface: Color { color("color-surface") }; static var border: Color { color("color-border") }
    static var accent: Color { color("color-control-accent") }; static var nav: Color { color("color-nav") }
    static let controlHeight = design.number("control-height"), actionWidth = design.number("action-width")
    static let actionMinWidth = design.number("action-min-width"), actionMaxWidth = design.number("action-max-width")
    static let controlRadius = design.dimension("inputRadius")
    static let toolbarHeight = design.number("workspace-toolbar-height")
    static let radius = design.number("panel-radius"), padding = design.number("panel-padding"), gap = design.number("layout-gap")
    /// Matches the workspace page margin at the Settings window's width.
    /// Settings fits its panes instead of leaving wide empty margins beside the toolbar.
    static let settingsWindow = CGSize(width: 720, height: 700)
    static let settingsInset = CGFloat(ComponentLayout.pageInsets(viewportWidth: settingsWindow.width).horizontal)
    static let settingsLabelWidth: CGFloat = 180, settingsControlWidth: CGFloat = 300
    static let textTrackLimit: CGFloat = 160
    static func measure(_ name: String) -> CGFloat { design.dimension(name) }
    static func space(_ size: Int) -> CGFloat { design.number("space-\(size)") }
    static func textarea(rows: Int = 4) -> CGFloat { ComponentLayout.textareaHeight(rows: rows, design: design) }
}

extension Font {
    static let sbBody = Font.system(size: StorebenchTheme.design.number("font-size-body"))
    static let sbCallout = sbBody
    static let sbSubheadline = sbBody
    static let sbCaption = Font.system(size: StorebenchTheme.design.number("font-size-caption"))
    static let sbCaption2 = sbCaption
    static let sbFootnote = sbCaption
    static let sbHeadline = sbBody.weight(.semibold)
    static let sbTitle3 = Font.system(size: StorebenchTheme.design.number("font-size-section")).weight(.semibold)
    static let sbTitle2 = Font.system(size: StorebenchTheme.design.number("font-size-title")).weight(.semibold)
    static let sbTitle = sbTitle2
    static let sbLargeTitle = Font.system(size: StorebenchTheme.design.number("font-size-page")).weight(.bold)
    static let sbMetric = Font.system(size: StorebenchTheme.design.number("font-size-value")).weight(.bold)
}

private struct WorkspaceWidthKey: EnvironmentKey { static let defaultValue: CGFloat = 1280 }
private struct SettingsPresentationKey: EnvironmentKey { static let defaultValue = false }
private struct FieldNeededKey: EnvironmentKey { static let defaultValue: String? = nil }
private struct FieldHintHeightKey: EnvironmentKey { static let defaultValue: CGFloat? = nil }
private struct NaturalActionsKey: EnvironmentKey { static let defaultValue = false }
private struct ActionFillKey: EnvironmentKey { static let defaultValue = false }
private struct ActionBusyKey: EnvironmentKey { static let defaultValue = false }
private struct WorkspaceHeightKey: EnvironmentKey { static let defaultValue: CGFloat = 840 }
extension EnvironmentValues {
    var settingsPresentation: Bool { get { self[SettingsPresentationKey.self] } set { self[SettingsPresentationKey.self] = newValue } }
    var naturalActions: Bool { get { self[NaturalActionsKey.self] } set { self[NaturalActionsKey.self] = newValue } }
    /// Set by action layouts that give each command a shared cell; the command fills that cell.
    var actionFill: Bool { get { self[ActionFillKey.self] } set { self[ActionFillKey.self] = newValue } }
    var actionBusy: Bool { get { self[ActionBusyKey.self] } set { self[ActionBusyKey.self] = newValue } }
    var fieldHintHeight: CGFloat? { get { self[FieldHintHeightKey.self] } set { self[FieldHintHeightKey.self] = newValue } }
    /// Why this field is the one to fill in next; the field shows it in red in its hint track, with a red outline.
    var fieldNeeded: String? { get { self[FieldNeededKey.self] } set { self[FieldNeededKey.self] = newValue } }
    var workspaceWidth: CGFloat { get { self[WorkspaceWidthKey.self] } set { self[WorkspaceWidthKey.self] = newValue } }
    var workspaceHeight: CGFloat { get { self[WorkspaceHeightKey.self] } set { self[WorkspaceHeightKey.self] = newValue } }
}

struct StorebenchViewport: ViewModifier {
    func body(content: Content) -> some View {
        GeometryReader { geometry in content.environment(\.workspaceWidth, geometry.size.width).environment(\.workspaceHeight, geometry.size.height) }
    }
}

struct StorebenchAppearance: ViewModifier {
    func body(content: Content) -> some View {
        content.font(.sbBody).foregroundStyle(StorebenchTheme.ink).tint(StorebenchTheme.accent)
            .buttonStyle(StorebenchButtonStyle()).textFieldStyle(StorebenchTextFieldStyle())
            .menuStyle(.button)
            .toggleStyle(StorebenchToggleStyle())
            .disclosureGroupStyle(StorebenchDisclosureStyle()).progressViewStyle(StorebenchProgressStyle())
            .preferredColorScheme(StorebenchAppearancePreferences.shared.choice.scheme.map { $0 == "dark" ? .dark : .light }).background(StorebenchTheme.page)
    }
}

extension View {
    /// Marks the field to fill in next: a red outline and `reason` in its hint track. Pass nil when nothing is missing here.
    func storebenchNeeded(_ reason: String?) -> some View { environment(\.fieldNeeded, reason) }
}
