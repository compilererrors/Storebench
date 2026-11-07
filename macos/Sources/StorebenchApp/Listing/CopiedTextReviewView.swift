import StorebenchCore
import SwiftUI

struct CopiedTextReviewView: View {
    let review: CopiedText.Review
    let disabled: Bool
    let acknowledge: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(review.needsReview ? "Source \(review.sourceLocale.isEmpty ? "unavailable" : review.sourceLocale) changed · compare the destination wording." : "\(review.marker.translated ? "Translated" : "Copied") from \(StoreLocales.name(review.sourceLocale)) · \(review.marker.translated ? "read the translation before sending it." : "source reviewed.")")
                .font(.sbCaption).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
            if review.needsReview {
                DisclosureGroup("Compare destination with current source") {
                    VStack(alignment: .leading, spacing: 8) {
                        StorebenchReadOnlyText(title: "Saved destination", text: review.targetValue, height: 90)
                        StorebenchReadOnlyText(title: "Current saved source", text: review.sourceValue, height: 90)
                        Button("Confirm Wording") { acknowledge() }.help("Confirm Destination Wording").accessibilityLabel("Confirm Destination Wording").storebenchWorking(!(!disabled && review.canAcknowledge))
                    }.padding(.top, 6)
                }
            }
        }.frame(maxWidth: .infinity, minHeight: 28, alignment: .topLeading)
    }
}
