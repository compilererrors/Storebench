import StorebenchCore
import SwiftUI

/// The same word markings are used in listing drafts and saved listing history.
func diffText(_ segments: [AsoTextSegment]) -> Text {
    segments.reduce(Text("")) { text, segment in
        switch segment.kind {
        case .same: text + Text(segment.text)
        case .added: text + Text(segment.text).foregroundColor(StorebenchTheme.color("color-success")).bold()
        case .removed: text + Text(segment.text).foregroundColor(StorebenchTheme.color("color-danger")).strikethrough()
        }
    }
}

struct StorebenchTextDifference: View {
    let segments: [AsoTextSegment]
    private var text: Text {
        segments.enumerated().reduce(Text("")) { result, item in
            let previous = item.offset > 0 ? segments[item.offset - 1] : nil
            let separate = previous.map { $0.kind != .same && item.element.kind != .same && $0.kind != item.element.kind
                && $0.text.last?.isWhitespace != true && item.element.text.first?.isWhitespace != true } == true
            return result + Text(separate ? " " : "") + diffText([item.element])
        }
    }
    var body: some View {
        text.font(.sbCallout).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }
}
