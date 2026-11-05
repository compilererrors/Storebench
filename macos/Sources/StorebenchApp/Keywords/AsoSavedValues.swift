import SwiftUI

/// Complete saved values remain readable inside equal, bounded tracks.
struct AsoSavedValues: View {
    var beforeLabel = "Left", afterLabel = "Right"
    let before, after: String
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            value(beforeLabel, before); value(afterLabel, after)
        }
    }
    private func value(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
            ScrollView { Text(text).font(.sbCallout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 180)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
