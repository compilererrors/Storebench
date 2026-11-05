import AppKit
import StorebenchCore

@MainActor enum StorebenchAbout {
    static func show() {
        let bundle = Bundle.main
        let metadata = ApplicationAbout(info: bundle.infoDictionary?.compactMapValues { $0 as? String } ?? [:])
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: metadata.name,
            .credits: credits(metadata),
        ]
        if let icon = NSApplication.shared.applicationIconImage { options[.applicationIcon] = icon }
        if let version = metadata.version { options[.applicationVersion] = version }
        if let build = metadata.build { options[.version] = build }
        NSApplication.shared.orderFrontStandardAboutPanel(options: options)
    }

    private static func credits(_ metadata: ApplicationAbout) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: StorebenchTheme.nativeColor("color-text-muted"),
            .paragraphStyle: paragraph,
        ]
        let result = NSMutableAttributedString(string: ApplicationAbout.summary, attributes: attributes)
        func append(_ title: String, url: URL) {
            var values = attributes
            values[.link] = url
            result.append(NSAttributedString(string: "\n" + title, attributes: values))
        }
        if let contact = metadata.contact {
            result.append(NSAttributedString(string: "\n", attributes: attributes))
            if let website = URL(string: contact.website) { append("Website", url: website) }
            append("Support", url: contact.support)
        }
        return result
    }
}
