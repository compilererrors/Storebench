import StorebenchCore
import SwiftUI

struct ReviewsDashboardView: View {
    let reviews: [CustomerReview]
    var onRelease: () -> Void = {}
    @Binding var evidence: Set<String>
    @State private var filters = ReviewsPresentation.Filters()

    private func country(_ code: String) -> String { code == "UNKNOWN" ? "Unknown territory" : WorkspaceSession.countryName(code) }
    private var filtersCard: some View {
        Card(title: "Find reviews", subtitle: "Search written feedback and filter its UTC creation dates. All statistics below follow these filters.") {
            StorebenchTextField("Search title and review text", text: $filters.query)
            StorebenchFormGrid(maximumColumns: 3, minimumWidth: 180) { ratingField; territoryField; orderField }
            StorebenchHeader {
                StorebenchFormGrid { dateFields }
            } actions: { Button("Reset Filters") { filters = .init() } }
            Text(filters.validDates ? "Dates are inclusive. Leave either date empty for an open range." : "Use valid YYYY-MM-DD dates with the start no later than the end.")
                .font(.sbCallout).foregroundStyle(StorebenchTheme.muted).frame(height: 36, alignment: .topLeading)
        }
    }
    private var ratingField: some View {
        StorebenchPicker("Rating", selection: $filters.rating) {
            SelectionOption("All ratings", value: ""); SelectionOption("Low ratings (1–2)", value: "low")
            selectionOptions(1...5) { SelectionOption("\($0) / 5", value: String($0)) }
        }
    }
    private var territoryField: some View {
        StorebenchPicker("Territory", selection: $filters.territory) {
            SelectionOption("All territories", value: "")
            selectionOptions(Set(reviews.map(\.territory)).sorted()) { SelectionOption(country($0), value: $0) }
        }
    }
    private var orderField: some View {
        StorebenchPicker("Order", selection: $filters.sort) { SelectionOption("Newest first", value: "newest"); SelectionOption("Lowest rating", value: "lowest"); SelectionOption("Highest rating", value: "highest") }
    }
    private var dateFields: some View {
        Group {
            StorebenchTextField("From (YYYY-MM-DD)", text: $filters.begin)
            StorebenchTextField("Through (YYYY-MM-DD)", text: $filters.end)
        }
    }

    var body: some View {
        let rows = ReviewsPresentation.filter(reviews, filters), summary = ReviewsPresentation.summarize(rows)
        VStack(alignment: .leading, spacing: 20) {
            filtersCard
            Card(title: "Written review sample", subtitle: "Written reviews are a sample of feedback. These averages are not the overall App Store rating, and review counts do not measure sales.") {
                StorebenchMetricGrid { facts(summary) }
                ForEach(1...5, id: \.self) { rating in
                    HStack { Text("\(rating) / 5").frame(width: 52, alignment: .leading); Text(filters.validDates ? "\(summary.ratings[rating - 1]) reviews" : "Unknown").monospacedDigit(); Spacer() }
                }
            }
            if filters.rating.isEmpty, summary.shouldReadLowFeedback {
                Card(title: "Read the low-rated feedback before planning changes", subtitle: "\(summary.low) of \(summary.count) matching reviews have 1–2 stars. Read recurring issues before choosing a fix. This is a sample of written feedback and does not change prices or release settings.") {
                    StorebenchFormFooter {
                        Button("Show 1–2 Stars") { filters.rating = "low" }.help("Show 1–2 Star Reviews").accessibilityLabel("Show 1–2 Star Reviews")
                        Button("Prepare a Release", action: onRelease)
                    }
                }
            }
            Card(title: "Reviews by territory", subtitle: "Counts, written-review averages and low ratings in this filtered sample.") {
                StorebenchCollection(items: summary.territories, title: { country($0.territory) }, subtitle: { "\($0.count) reviews · \($0.average.formatted(.number.precision(.fractionLength(1)))) / 5" }, sorts: [
                    .init(id: "count", label: "Review count", less: { $0.count < $1.count }),
                    .init(id: "average", label: "Sample average", less: { $0.average < $1.average }),
                    .init(id: "low", label: "Low-rating count", less: { $0.low < $1.low })
                ], preferenceID: "review-territories", empty: "No territories match these filters.") { row in
                    Text("\(row.low) low ratings in this sample").font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
                }
            }
            if rows.isEmpty { Card(title: "No reviews match", subtitle: "Adjust the search, rating, territory or date range.") { EmptyView() } }
            Card(title: "Customer review text", subtitle: "View options remember your sort, page size and default expansion. All matching reviews remain available through pages.") {
                StorebenchCollection(items: rows, title: { $0.title.isEmpty ? "Untitled review" : $0.title }, subtitle: { "\($0.rating) / 5 · \(country($0.territory)) · " + (AppStoreNames.date($0.createdDate) ?? String($0.createdDate.prefix(10)) + " UTC") }, sorts: [
                    .init(id: "date", label: "Created", less: { $0.createdDate < $1.createdDate }),
                    .init(id: "rating", label: "Rating", less: { $0.rating < $1.rating }),
                    .init(id: "territory", label: "Territory", less: { $0.territory < $1.territory })
                ], preferenceID: "customer-reviews", empty: "No reviews match these filters.") { review in
                    Text(review.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Toggle("Include in feedback follow-up", isOn: Binding(get: { evidence.contains(review.id) }, set: { if $0 { if evidence.count < 50 { evidence.insert(review.id) } } else { evidence.remove(review.id) } }))
                        .toggleStyle(StorebenchToggleStyle())
                        .opacity(!evidence.contains(review.id) && evidence.count >= 50 ? 0 : 1).allowsHitTesting(evidence.contains(review.id) || evidence.count < 50).accessibilityHidden(!evidence.contains(review.id) && evidence.count >= 50)
                }
            }
        }
        .historyValue("reviews-dashboard", $filters)
    }
    @ViewBuilder private func facts(_ summary: ReviewsPresentation.Summary) -> some View {
        Fact(title: "Written reviews", value: filters.validDates ? String(summary.count) : "Unknown")
        Fact(title: "Sample average", value: summary.average.map { $0.formatted(.number.precision(.fractionLength(1))) + " / 5" } ?? "Unknown", info: "The average rating of the written reviews shown here, not the app's overall rating.")
        Fact(title: "Low ratings (1–2)", value: filters.validDates ? String(summary.low) : "Unknown")
        Fact(title: "Known territories", value: filters.validDates ? String(summary.territories.filter { $0.territory != "UNKNOWN" }.count) : "Unknown")
    }
}
