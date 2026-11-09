import Foundation

public enum ComponentLayout {
    /// A usable layout width. SwiftUI proposes an infinite width when it probes a view's largest size,
    /// and an infinite or missing width falls back so column counts never convert infinity to an integer.
    /// Widths are capped far beyond any display, so every derived count fits an integer.
    public static func usableWidth(_ value: Double?, fallback: Double = 640) -> Double {
        let limit = 1_000_000.0
        guard let value, value.isFinite else { return fallback.isFinite ? min(limit, max(0, fallback)) : 640 }
        return min(limit, max(0, value))
    }
    public struct AssetCard: Sendable {
        public let preview, identity, title, metadata, divider, actions: CGRect
        public let height: Double
    }
    /// Title and metadata reserve their tracks and grow with long copy. A taller grid row keeps the divider and
    /// commands on the bottom edge shared by neighbouring cards, never between copy lines.
    public static func assetCard(width: Double, actionsHeight: Double, previewHeight: Double? = nil, titleHeight: Double = 0, metadataHeight: Double = 0,
                                 minimumHeight: Double = 0, compact: Bool = false, design: StorebenchDesign = .shared) -> AssetCard {
        let width = usableWidth(width), border = min(width / 2, design.dimension("assetBorder"))
        let padding = design.dimension("assetPadding"), inset = min(width / 2, border + padding)
        let available = max(0, width - 2 * inset), gap = compact ? design.number("space-1") : design.dimension("assetGap")
        let preview = CGRect(x: border, y: border, width: max(0, width - 2 * border), height: previewHeight ?? design.dimension("assetPreviewHeight"))
        let identity = CGRect(x: inset, y: preview.maxY + padding, width: available, height: compact ? 0 : design.dimension("assetBadgeHeight"))
        let title = CGRect(x: inset, y: compact ? identity.minY : identity.maxY + gap, width: available, height: max(design.dimension(compact ? "assetCompactTitleHeight" : "assetTitleHeight"), titleHeight))
        let metadata = CGRect(x: inset, y: title.maxY + gap, width: available, height: max(design.dimension("assetMetadataHeight"), metadataHeight))
        let actionsHeight = max(design.number("control-height"), actionsHeight)
        let height = max(metadata.maxY + gap + 1 + gap + actionsHeight + padding + border, minimumHeight)
        let actions = CGRect(x: inset, y: height - border - padding - actionsHeight, width: available, height: actionsHeight)
        let divider = CGRect(x: inset, y: actions.minY - gap - 1, width: available, height: 1)
        return AssetCard(preview: preview, identity: identity, title: title, metadata: metadata, divider: divider, actions: actions, height: height)
    }
    public struct PageInsets: Sendable {
        public let horizontal, top: Double
    }
    public static func pageInsets(viewportWidth: Double, design: StorebenchDesign = .shared) -> PageInsets {
        PageInsets(horizontal: viewportWidth > 1000 ? 48 : viewportWidth > 700 ? 28 : design.number("space-5"),
                   top: design.number(viewportWidth > 700 ? "space-8" : "space-6"))
    }
    public struct WorkflowCard: Sendable {
        public let heading, description, feedback, action: CGRect
        public let height: Double
    }
    /// Related cards share text tracks and a trailing action at the bottom, including before status arrives.
    /// Reserved tracks grow with their content; a taller row keeps the command on the card's bottom edge.
    public static func workflowCard(width: Double, accessory: Bool = false, headingHeight measuredHeading: Double = 0, descriptionHeight measuredDescription: Double = 0,
                                    feedbackHeight measuredFeedback: Double = 0, minimumHeight: Double = 0, design: StorebenchDesign = .shared) -> WorkflowCard {
        let width = usableWidth(width), padding = design.dimension("workflowPadding") + design.dimension("workflowBorder")
        let inset = min(width / 2, padding), available = max(0, width - 2 * inset), gap = design.dimension("workflowGap")
        let headingHeight = max(design.dimension("workflowHeading"), measuredHeading), descriptionHeight = max(design.dimension("workflowDescription"), measuredDescription)
        let feedbackHeight = max(design.dimension("workflowFeedback"), measuredFeedback), actionHeight = design.dimension("workflowAction")
        let actionWidth = min(available, design.number("action-width") + (accessory ? design.number("control-height") + design.number("action-gap") : 0))
        let descriptionY = padding + headingHeight + gap, feedbackY = descriptionY + descriptionHeight + gap
        let height = max(feedbackY + feedbackHeight + gap + actionHeight + padding, minimumHeight)
        return WorkflowCard(heading: CGRect(x: inset, y: padding, width: available, height: headingHeight),
                            description: CGRect(x: inset, y: descriptionY, width: available, height: descriptionHeight),
                            feedback: CGRect(x: inset, y: feedbackY, width: available, height: feedbackHeight),
                            action: CGRect(x: width - inset - actionWidth, y: height - padding - actionHeight, width: actionWidth, height: actionHeight),
                            height: height)
    }
    public struct Header: Sendable {
        public let copy, actions: CGRect
        public let height: Double
    }
    /// A single command uses one track; extra commands use at most two. Stacked commands retain the trailing edge.
    public static func header(width: Double, copyHeight: Double, actionWidth: Double, actionHeight: Double, stackAt: Double = 760, design: StorebenchDesign = .shared) -> Header {
        let width = usableWidth(width), copyHeight = max(0, copyHeight), actionHeight = max(0, actionHeight)
        let actionWidth = min(width, max(0, min(actionWidth, (2 * design.number("action-width") + design.number("action-gap")))))
        let stacked = width <= stackAt
        let gap = design.number(stacked ? "space-3" : "space-6")
        return Header(copy: CGRect(x: 0, y: 0, width: stacked ? width : max(0, width - actionWidth - gap), height: copyHeight),
                      actions: CGRect(x: width - actionWidth, y: stacked ? copyHeight + gap : 0, width: actionWidth, height: actionHeight),
                      height: stacked ? copyHeight + gap + actionHeight : max(copyHeight, actionHeight))
    }
    public struct ActionGrid: Sendable {
        public let frames: [CGRect]
        public let height: Double
    }
    /// Commands keep a shared width, including the final incomplete row, without stretching to fill a module.
    /// `cell` is the group's shared command width (its widest label); without it commands use the shared action width.
    public static func actionGrid(width: Double, heights: [Double], trailing: Bool = false, cell preferred: Double? = nil, design: StorebenchDesign = .shared) -> ActionGrid {
        let width = usableWidth(width), gap = design.number("action-gap"), cell = min(width, max(0, preferred ?? design.number("action-width")))
        let ratio = (width + gap) / max(1, cell + gap)
        let columns = ratio.isFinite ? max(1, min(heights.count, Int(min(ratio, 10_000)))) : 1
        var frames: [CGRect] = [], y = 0.0
        for start in stride(from: 0, to: heights.count, by: columns) {
            let row = heights[start..<min(start + columns, heights.count)].map { max(0, $0) }
            let rowWidth = Double(row.count) * cell + Double(max(0, row.count - 1)) * gap
            let x = trailing ? width - rowWidth : 0
            for (index, height) in row.enumerated() { frames.append(CGRect(x: x + Double(index) * (cell + gap), y: y, width: cell, height: height)) }
            y += (row.max() ?? 0) + gap
        }
        return ActionGrid(frames: frames, height: heights.isEmpty ? 0 : y - gap)
    }
    public struct NavigationRow: Sendable {
        public let icon, text, action: CGRect
        public let height: Double
    }
    public struct Flow: Sendable {
        public let frames: [CGRect]
        public let height: Double
    }
    /// Table search, ordering and page size share a control height and wrap as complete tracks.
    public static func tableControls(width: Double, pageSize: Bool = true, design: StorebenchDesign = .shared) -> Flow {
        let width = usableWidth(width), gap = design.number("space-2"), height = design.number("control-height")
        let tools = pageSize ? [240.0, 154.0] : [240.0]
        let toolsWidth = tools.reduce(0, +) + Double(tools.count - 1) * gap
        if width >= 240 + gap + toolsWidth {
            let search = width - gap - toolsWidth
            var x = search + gap
            return Flow(frames: [CGRect(x: 0, y: 0, width: search, height: height)] + tools.map { tool in
                defer { x += tool + gap }; return CGRect(x: x, y: 0, width: tool, height: height)
            }, height: height)
        }
        let controls = flow(width: width, sizes: tools.map { CGSize(width: min(width, $0), height: height) }, spacing: gap)
        return Flow(frames: [CGRect(x: 0, y: 0, width: width, height: height)] + controls.frames.map { $0.offsetBy(dx: 0, dy: height + gap) }, height: height + gap + controls.height)
    }
    /// Compact tools wrap inside their actual container, including long labels and incomplete rows.
    public static func flow(width: Double, sizes: [CGSize], spacing: Double = 4, trailing: Bool = false) -> Flow {
        let width = usableWidth(width), spacing = max(0, spacing)
        var rows: [[CGSize]] = [], row: [CGSize] = [], used = 0.0
        for size in sizes {
            let size = CGSize(width: min(width, max(0, size.width)), height: max(0, size.height))
            if !row.isEmpty && used + spacing + size.width > width {
                rows.append(row); row = []; used = 0
            }
            used += (row.isEmpty ? 0 : spacing) + size.width; row.append(size)
        }
        if !row.isEmpty { rows.append(row) }
        var frames: [CGRect] = [], y = 0.0
        for row in rows {
            let rowWidth = row.reduce(0.0) { $0 + $1.width } + Double(max(0, row.count - 1)) * spacing
            var x = trailing ? max(0, width - rowWidth) : 0
            for size in row { frames.append(CGRect(x: x, y: y, width: size.width, height: size.height)); x += size.width + spacing }
            y += (row.map(\.height).max() ?? 0) + spacing
        }
        return Flow(frames: frames, height: rows.isEmpty ? 0 : y - spacing)
    }
    public static func navigationRow(width: Double, textHeight: Double, tile: Bool = false, design: StorebenchDesign = .shared) -> NavigationRow {
        let width = usableWidth(width), gap = design.number("space-4"), control = design.number("control-height")
        let icon = min(control, width), inset = min(width, icon + gap), stacked = tile || width <= 480
        let actionWidth = stacked && !tile ? min(design.number("action-width"), max(0, width - inset)) : min(design.number("action-width"), width)
        let textWidth = max(0, width - inset - (stacked ? 0 : actionWidth + gap))
        let height = max(design.dimension("navigationMinimumHeight") - 2 * design.number("panel-padding"), max(control, max(0, textHeight)))
        return NavigationRow(icon: CGRect(x: 0, y: (height - control) / 2, width: icon, height: control),
            text: CGRect(x: inset, y: 0, width: textWidth, height: height),
            action: CGRect(x: width - actionWidth, y: stacked ? height + gap : (height - control) / 2, width: actionWidth, height: control),
            height: height + (stacked ? gap + control : 0))
    }
    public struct TextTrack: Sendable {
        public let height, contentOffset: Double
    }
    public struct StatusRow: Sendable {
        public let heading, status, action, details: CGRect
        public let height: Double
        public let stacked: Bool
    }
    /// Short text centers in its reserved track; overflow starts at the top and remains scrollable.
    public static func textTrack(minimumHeight: Double, contentHeight: Double, centered: Bool = false) -> TextTrack {
        let content = max(0, contentHeight), height = max(max(0, minimumHeight), content)
        return TextTrack(height: height, contentOffset: centered ? (height - content) / 2 : 0)
    }
    /// The visible height of a text track: it reserves its minimum, grows to show complete copy and
    /// scrolls only beyond `maximumHeight` or a smaller fixed track offered by its container.
    public static func textTrackFrame(minimumHeight: Double, contentHeight: Double, maximumHeight: Double, offeredHeight: Double? = nil) -> Double {
        let reserved = max(0, minimumHeight), limit = max(reserved, maximumHeight)
        let natural = min(max(reserved, max(0, contentHeight)), limit)
        guard let offered = offeredHeight, offered.isFinite else { return natural }
        return max(reserved, min(natural, offered))
    }
    /// Details below this header occupy the whole row, independent of status and action tracks.
    public static func statusRow(width: Double, headingHeight: Double, statusHeight: Double, actionHeight: Double, detailsHeight: Double = 0, statusWidth: Double = 84, actionWidth: Double = 74, gap: Double = 12, detailsGap: Double = 8, minimumHeadingWidth: Double = 240) -> StatusRow {
        let width = usableWidth(width), gap = max(0, gap)
        let headingHeight = max(0, headingHeight), statusHeight = max(0, statusHeight), actionHeight = max(0, actionHeight)
        let actionWidth = min(width, max(0, actionWidth)), statusWidth = max(0, statusWidth)
        let detailsHeight = max(0, detailsHeight), detailsGap = detailsHeight > 0 ? max(0, detailsGap) : 0
        let stacked = width < max(0, minimumHeadingWidth) + statusWidth + actionWidth + 2 * gap
        if stacked {
            let actualGap = min(gap, max(0, width - actionWidth))
            let actualStatusWidth = min(statusWidth, max(0, width - actionWidth - actualGap))
            let y = headingHeight + gap
            let headerHeight = y + max(statusHeight, actionHeight)
            return StatusRow(heading: CGRect(x: 0, y: 0, width: width, height: headingHeight),
                             status: CGRect(x: 0, y: y + (max(statusHeight, actionHeight) - statusHeight) / 2, width: actualStatusWidth, height: statusHeight),
                             action: CGRect(x: width - actionWidth, y: y + (max(statusHeight, actionHeight) - actionHeight) / 2, width: actionWidth, height: actionHeight),
                             details: CGRect(x: 0, y: headerHeight + detailsGap, width: width, height: detailsHeight),
                             height: headerHeight + detailsGap + detailsHeight, stacked: true)
        }
        let headingWidth = width - statusWidth - actionWidth - 2 * gap
        let headerHeight = max(headingHeight, max(statusHeight, actionHeight))
        return StatusRow(heading: CGRect(x: 0, y: 0, width: headingWidth, height: headingHeight),
                         status: CGRect(x: headingWidth + gap, y: (headerHeight - statusHeight) / 2, width: statusWidth, height: statusHeight),
                         action: CGRect(x: width - actionWidth, y: (headerHeight - actionHeight) / 2, width: actionWidth, height: actionHeight),
                         details: CGRect(x: 0, y: headerHeight + detailsGap, width: width, height: detailsHeight),
                         height: headerHeight + detailsGap + detailsHeight, stacked: false)
    }
    public struct Grid: Sendable {
        public let columns: Int
        public let cellWidth, height: Double
        public let rowHeights, rowOffsets: [Double]
    }
    /// `evenRows` spreads items that wrap evenly over the rows they need, so no row holds a lone leftover.
    /// `keepColumns` keeps every column even with fewer items, so a lone field takes one column like the fields of other grids.
    public static func columns(width: Double, count: Int, maximum: Int = 4, minimumWidth: Double = 190, spacing: Double = 16, balanced: Bool = false, workflow: Bool = false, evenRows: Bool = false, keepColumns: Bool = false) -> Int {
        let width = usableWidth(width), spacing = spacing.isFinite ? max(0, spacing) : 0
        let ratio = (width + spacing) / (max(1, minimumWidth.isFinite ? minimumWidth : 190) + spacing)
        let available = workflow ? (width >= 888 ? 3 : 1) : balanced ? (width > 640 ? 4 : width > 295 ? 2 : 1) : ratio.isFinite ? max(1, Int(min(ratio, 1_000))) : 1
        let columns = max(1, min(max(1, maximum), keepColumns ? max(1, maximum) : max(1, count), available))
        guard evenRows, count > columns else { return columns }
        let rows = (count + columns - 1) / columns
        return max(1, (count + rows - 1) / rows)
    }
    public static func grid(width: Double, heights: [Double], maximum: Int = 4, minimumWidth: Double = 190, spacing: Double = 16, balanced: Bool = false, workflow: Bool = false, evenRows: Bool = false, rowSpacing: Double? = nil, keepColumns: Bool = false) -> Grid {
        let width = usableWidth(width), spacing = max(0, spacing)
        let count = columns(width: width, count: heights.count, maximum: maximum, minimumWidth: minimumWidth, spacing: spacing, balanced: balanced, workflow: workflow, evenRows: evenRows, keepColumns: keepColumns)
        var rows: [Double] = []
        for start in stride(from: 0, to: heights.count, by: count) { rows.append(heights[start..<min(start + count, heights.count)].map { max(0, $0) }.max() ?? 0) }
        let verticalGap = max(0, rowSpacing ?? spacing)
        var offset = 0.0, offsets: [Double] = []
        for row in rows { offsets.append(offset); offset += row + verticalGap }
        return Grid(columns: count, cellWidth: max(0, (width - Double(count - 1) * spacing) / Double(count)), height: max(0, offset - (rows.isEmpty ? 0 : verticalGap)), rowHeights: rows, rowOffsets: offsets)
    }
    public static func fieldHeight(control: Double = 42, label: Bool = true, hint: Bool = true, hintHeight: Double? = nil, design: StorebenchDesign = .shared) -> Double {
        max(0, control) + (label ? design.dimension("fieldLabel") + design.dimension("fieldGap") : 0) + (hint ? (hintHeight ?? design.dimension("fieldHint")) + design.dimension("fieldGap") : 0)
    }
    public static func tableRowHeight(lines: Int, design: StorebenchDesign = .shared) -> Double {
        design.dimension("tableRow")
    }
    public static func textareaHeight(rows: Int = 4, design: StorebenchDesign = .shared) -> Double {
        Double(max(1, rows)) * design.dimension("textareaLineHeight") + 2 * design.dimension("textareaPaddingY") + 2
    }
    public static func dialog(viewportWidth: Double, viewportHeight: Double, wide: Bool = false, preferredHeight: Double = 720, design: StorebenchDesign = .shared) -> CGSize {
        CGSize(width: min(max(0, viewportWidth - 32), design.dimension(wide ? "dialogWide" : "dialogWidth")), height: min(max(0, viewportHeight - 48), max(0, preferredHeight)))
    }
    public static func boundedTextHeight(measured: Double, maximum: Double, empty: Bool = false) -> Double {
        empty ? 0 : min(max(0, measured), max(0, maximum))
    }
}
