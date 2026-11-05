import StorebenchCore
import SwiftUI

struct StorebenchTracks {
    let frames: [CGRect]
    let height: CGFloat
}

/// A component that measures its copy and places each child in an explicit track, such as a card with a
/// heading, copy and a command. Conforming layouts describe only their geometry; sizing and placement are shared.
///
/// `minimumHeight` is the height offered by the container. Layouts that set `fillsRow` receive a grid row's
/// height there, so cards sharing a row keep their commands and dividers on one bottom edge.
protocol StorebenchTrackLayout: Layout where Cache == Void {
    func tracks(width: CGFloat, minimumHeight: CGFloat, subviews: Subviews) -> StorebenchTracks
    /// Whether a finite offered height becomes the minimum height, as in an equal-height grid row.
    var fillsRow: Bool { get }
    /// The width used when the container leaves it unspecified.
    var unspecifiedWidth: CGFloat { get }
}

extension StorebenchTrackLayout {
    var fillsRow: Bool { false }
    var unspecifiedWidth: CGFloat { 640 }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.usableWidth(unspecifiedWidth)
        let offered = fillsRow ? proposal.height.flatMap { $0.isFinite ? $0 : nil } ?? 0 : 0
        return CGSize(width: width, height: tracks(width: width, minimumHeight: offered, subviews: subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = tracks(width: bounds.width, minimumHeight: fillsRow ? bounds.height : 0, subviews: subviews)
        for (subview, frame) in zip(subviews, layout.frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }
}

extension LayoutSubviews {
    /// The size of the subview at `offset`, or zero when the content produced fewer views than the layout has slots,
    /// as when an optional command or detail is empty. Layouts never index subviews directly.
    func size(_ offset: Int, _ proposal: ProposedViewSize) -> CGSize {
        offset >= 0 && offset < count ? self[index(startIndex, offsetBy: offset)].sizeThatFits(proposal) : .zero
    }
    func place(_ offset: Int, at point: CGPoint, proposal: ProposedViewSize) {
        guard offset >= 0, offset < count else { return }
        self[index(startIndex, offsetBy: offset)].place(at: point, proposal: proposal)
    }
}

extension ProposedViewSize {
    /// A finite proposed width. SwiftUI proposes an infinite width when it probes a view's largest size;
    /// that and a missing width use `fallback`, so layouts never turn infinity into a column count.
    func usableWidth(_ fallback: CGFloat = 640) -> CGFloat {
        CGFloat(ComponentLayout.usableWidth(width.map(Double.init), fallback: Double(fallback)))
    }
}
