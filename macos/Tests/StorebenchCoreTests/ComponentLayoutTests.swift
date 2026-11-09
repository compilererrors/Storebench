import Foundation
import Testing
@testable import StorebenchCore

@Suite struct ComponentLayoutTests {
    init() throws { _ = try TestIsolation.require() }

    @Test func reportSearchAndCommandsShareHeightWithoutCollidingAtAnyWidth() {
        for width in [0.0, 42, 180, 310, 390, 402, 424, 640, 650, 768, 1440] {
            for pageSize in [false, true] {
                let layout = ComponentLayout.tableControls(width: width, pageSize: pageSize)
                #expect(layout.frames.count == (pageSize ? 3 : 2))
                for (index, frame) in layout.frames.enumerated() {
                    #expect(Double(frame.height) == StorebenchDesign.shared.number("control-height"), "Synthetic track at width \(width): \(frame.height) points")
                    #expect(frame.minX >= 0 && frame.maxX <= width && frame.maxY <= layout.height)
                    for earlier in layout.frames.prefix(index) { #expect(!frame.intersects(earlier)) }
                }
                if width >= (pageSize ? 650 : 488) { #expect(layout.frames.allSatisfy { $0.minY == 0 }) }
                else { #expect(layout.frames[1].minY >= layout.frames[0].maxY + 8) }
            }
        }
    }

    @Test func assetCardsReserveIdentityAndMetadataWhilePreviewAndActionsStayContained() {
        let design = StorebenchDesign.shared
        for width in [0.0, 20, 180, 260, 360, 720] {
            let ordinary = ComponentLayout.assetCard(width: width, actionsHeight: 42)
            for controls in [0.0, 42, 140, 240] {
                let card = ComponentLayout.assetCard(width: width, actionsHeight: controls)
                #expect(card.preview == ordinary.preview && card.title == ordinary.title && card.metadata == ordinary.metadata)
                #expect(card.actions.minY == ordinary.actions.minY)
                #expect(Double(card.preview.height) == design.dimension("assetPreviewHeight"))
                for frame in [card.preview, card.identity, card.title, card.metadata, card.divider, card.actions] {
                    #expect(frame.minX >= 0 && frame.maxX <= width && frame.minY >= 0 && frame.maxY <= card.height)
                }
                #expect(card.actions.height >= max(design.number("control-height"), controls))
            }
        }
        let image = ComponentLayout.assetCard(width: 320, actionsHeight: 42)
        let video = ComponentLayout.assetCard(width: 320, actionsHeight: 140, previewHeight: 312)
        #expect(image.height == 413)
        #expect(image.title.height == 40 && image.metadata.height == 20 && image.identity.height == 24)
        #expect(video.title.minY - image.title.minY == 92)
        #expect(video.height - image.height == 190)
        for width in [260.0, 540, 820, 1090, 1400] {
            let grid = ComponentLayout.grid(width: width, heights: Array(repeating: image.height, count: 10), maximum: 4, minimumWidth: 260, spacing: 16)
            #expect((1...4).contains(grid.columns))
            #expect(Double(grid.columns) * grid.cellWidth + Double(grid.columns - 1) * 16 <= width + 0.001)
            #expect(grid.rowHeights.allSatisfy { $0 == image.height })
        }
    }

    @Test func workspaceHeaderHasBreathingRoomAndContentSharesItsHorizontalInsets() {
        let design = StorebenchDesign.shared, toolbar = design.number("workspace-toolbar-height"), control = design.number("control-height")
        #expect((toolbar - control) / 2 >= design.number("space-2"))
        #expect(design.number("space-4") + 32 / 2 == toolbar / 2)
        for width in [1920.0, 1440, 1001, 1000, 768, 701, 700, 390] {
            let insets = ComponentLayout.pageInsets(viewportWidth: width)
            #expect(insets.horizontal == (width > 1000 ? 48 : width > 700 ? 28 : 20))
            #expect(insets.top == (width > 700 ? 32 : 24))
            #expect(insets.top >= design.number("space-6"))
        }
    }

    @Test func headerCommandsKeepTheTrailingEdgeWithOneOrTwoTracksAndLongCopy() {
        for width in [1096.0, 761, 760, 424, 310, 180, 20, 0] {
            for actionWidth in [192.0, 396, 1200] {
                for height in [60.0, 2200] {
                    let header = ComponentLayout.header(width: width, copyHeight: height, actionWidth: actionWidth, actionHeight: 42)
                    #expect(Double(header.actions.maxX) == width)
                    #expect(header.actions.width <= 396 && header.actions.width <= width)
                    for frame in [header.copy, header.actions] {
                        #expect(frame.minX >= 0 && frame.maxX <= width && frame.width >= 0)
                        #expect(frame.minY >= 0 && frame.maxY <= header.height)
                    }
                    if width > 760 { #expect(header.copy.maxX < header.actions.minX && header.actions.minY == 0) }
                    else { #expect(Double(header.copy.width) == width && header.actions.minY > header.copy.maxY) }
                }
            }
        }
        let single = ComponentLayout.header(width: 1096, copyHeight: 60, actionWidth: 192, actionHeight: 42)
        #expect(single.actions.minX == 904 && single.copy.width == 880)
    }

    @Test func actionRowsKeepEqualWidthsAndAlignIncompleteRowsWithoutCollisions() {
        for width in [1096.0, 600, 396, 395, 310, 180, 20, 0] {
            for trailing in [false, true] {
                for count in [0, 1, 2, 3, 7] {
                    let layout = ComponentLayout.actionGrid(width: width, heights: Array(repeating: 42, count: count), trailing: trailing)
                    #expect(layout.frames.count == count)
                    for (index, frame) in layout.frames.enumerated() {
                        #expect(frame.width == min(width, 192) && frame.height == 42)
                        #expect(frame.minX >= 0 && frame.maxX <= width && frame.maxY <= layout.height)
                        if index > 0 { #expect(!frame.intersects(layout.frames[index - 1])) }
                    }
                    if count > 0 && trailing { #expect(layout.frames.last.map { Double($0.maxX) } == width) }
                    if count == 0 { #expect(layout.height == 0) }
                }
            }
        }
    }

    @Test func wrappedCommandsNeverLeaveAnIsolatedFinalButton() {
        for width in [280.0, 436, 600, 804, 1096] {
            for count in 2...15 {
                let layout = ComponentLayout.actionGrid(width: width, heights: (0..<count).map { $0.isMultiple(of: 2) ? 32 : 44 }, trailing: true)
                let rows = Dictionary(grouping: layout.frames, by: \.minY).sorted { $0.key < $1.key }.map(\.value)
                #expect(rows.allSatisfy { $0.count == 1 } || rows.allSatisfy { $0.count >= 2 })
                #expect((rows.map(\.count).max() ?? 0) - (rows.map(\.count).min() ?? 0) <= 1)
                #expect(layout.frames.allSatisfy { $0.width == min(width, 192) && $0.maxX <= width && $0.maxY <= layout.height })
                for index in 1..<layout.frames.count {
                    #expect(!layout.frames[index].intersects(layout.frames[index - 1]))
                }
            }
        }
        let compact = ComponentLayout.actionGrid(width: 436, heights: [32, 32, 32])
        #expect(Set(compact.frames.map(\.minY)).count == 3)
        let four = ComponentLayout.actionGrid(width: 600, heights: [32, 32, 32, 32])
        #expect(Dictionary(grouping: four.frames, by: \.minY).values.allSatisfy { $0.count == 2 })
    }

    @Test func compactToolsWrapLongLabelsWithinNestedPanelMargins() {
        let inset = StorebenchDesign.shared.number("panel-padding")
        for panelWidth in [1380.0, 1096, 888, 760, 424, 310, 180, 80] {
            let width = max(0, panelWidth - 2 * inset)
            for trailing in [false, true] {
                let sizes = [CGSize(width: 42, height: 42), CGSize(width: 72, height: 42), CGSize(width: 2800, height: 126), CGSize(width: 192, height: 42), CGSize(width: 42, height: 42)]
                let tools = ComponentLayout.flow(width: width, sizes: sizes, spacing: 8, trailing: trailing)
                #expect(tools.frames.count == sizes.count)
                for (index, frame) in tools.frames.enumerated() {
                    #expect(frame.minX >= 0 && frame.maxX <= width && frame.maxY <= tools.height)
                    let placed = frame.offsetBy(dx: inset, dy: inset)
                    #expect(placed.minX >= inset && placed.maxX <= panelWidth - inset)
                    if index > 0 { #expect(!frame.intersects(tools.frames[index - 1])) }
                }
                #expect(tools.frames[2].height == 126)
                #expect(tools.frames[3].minY >= tools.frames[2].maxY + 8)
            }
        }
        let empty = ComponentLayout.flow(width: 0, sizes: [])
        #expect(empty.frames.isEmpty && empty.height == 0)
        let narrow = ComponentLayout.flow(width: 20, sizes: [CGSize(width: 42, height: 42), CGSize(width: 192, height: 84)])
        #expect(narrow.frames[0].width == 20 && narrow.frames[1].minY == 46 && narrow.height == 130)
    }

    @Test func headerContainsEveryCommandWhenAnActionGroupWraps() {
        for width in [1096.0, 761, 760, 600, 424, 310, 180, 20, 0] {
            for count in [1, 2, 3, 7, 15] {
                let actionWidth = min(width, 396)
                let commands = ComponentLayout.actionGrid(width: actionWidth, heights: Array(repeating: 42, count: count), trailing: true)
                let header = ComponentLayout.header(width: width, copyHeight: 108, actionWidth: actionWidth, actionHeight: commands.height)
                #expect(commands.frames.count == count)
                for frame in commands.frames {
                    let placed = frame.offsetBy(dx: header.actions.minX, dy: header.actions.minY)
                    #expect(placed.minX >= 0 && placed.maxX <= width && placed.maxY <= header.height)
                    #expect(!placed.intersects(header.copy))
                }
                #expect(header.actions.height >= commands.height)
            }
        }
    }

    @Test func navigationColumnsAndTypographyUseSharedRolesAtEveryWindowWidth() {
        let design = StorebenchDesign.shared
        #expect(design.number("font-size-body") == 13 && design.number("font-size-caption") == 11)
        #expect(design.number("font-size-section") > design.number("font-size-body"))
        #expect(design.dimension("pageTitleFont") == design.number("font-size-page"))
        for (width, expected) in [(1096.0, 4), (514.0, 3), (424.0, 2), (310.0, 1)] {
            let grid = ComponentLayout.grid(width: width - 18, heights: Array(repeating: 42, count: 7), minimumWidth: design.number("navigation-minimum-width"), spacing: design.number("navigation-gap"))
            #expect(grid.columns == expected)
            #expect(Double(grid.columns) * grid.cellWidth + Double(grid.columns - 1) * 8 <= width - 18 + 0.001)
            #expect(grid.rowHeights.allSatisfy { $0 == 42 })
        }
    }

    @Test func navigationCardsKeepIconsAndActionsCenteredWithContainedTextAndStableControlHeights() {
        for width in [1088.0, 520, 480, 310, 180, 42, 20, 0] {
            for tile in [false, true] {
                for height in [61.0, 97, 237] {
                    let row = ComponentLayout.navigationRow(width: width, textHeight: height, tile: tile)
                    for frame in [row.icon, row.text, row.action] {
                        #expect(frame.minX >= 0 && frame.maxX <= width && frame.width >= 0)
                        #expect(frame.minY >= 0 && frame.maxY <= row.height)
                    }
                    let control = StorebenchDesign.shared.number("control-height")
                    #expect(Double(row.icon.height) == control && Double(row.action.height) == control)
                    #expect(row.icon.midY == row.text.midY)
                    if width > 480 && !tile { #expect(row.action.midY == row.text.midY && row.text.maxX < row.action.minX) }
                    else { #expect(row.action.minY == row.text.maxY + 16) }
                }
            }
        }
        #expect(ComponentLayout.navigationRow(width: 1088, textHeight: 61).height + 40 == 112)
    }

    @Test func adaptiveGridsPreserveRowsWhenTextOrRecordsExpand() {
        let initial = ComponentLayout.grid(width: 424, heights: [108, 108, 108, 108], maximum: 2)
        let expanded = ComponentLayout.grid(width: 424, heights: [108, 108, 210, 108, 108], maximum: 2)
        #expect(initial.columns == 2 && expanded.columns == 2)
        #expect(initial.cellWidth == 204 && expanded.cellWidth == initial.cellWidth)
        #expect(initial.rowOffsets[1] == expanded.rowOffsets[1])
        #expect(expanded.rowHeights == [108, 210, 108])
        #expect(expanded.rowOffsets == [0, 124, 350])
        #expect(expanded.height == 458)
    }

    @Test func gridsFitDesktopTabletAndNarrowTracksWithoutNegativeWidths() {
        for (width, columns) in [(1088.0, 4), (424.0, 2), (310.0, 2), (180.0, 1)] {
            let grid = ComponentLayout.grid(width: width, heights: Array(repeating: 140, count: 4), balanced: true)
            #expect(grid.columns == columns)
            #expect(Double(columns) * grid.cellWidth + Double(columns - 1) * 16 <= width + 0.001)
        }
        let empty = ComponentLayout.grid(width: 0, heights: [])
        #expect(empty.height == 0 && empty.cellWidth == 0)
        let tiny = ComponentLayout.grid(width: -1, heights: [-1, 108], maximum: 0)
        #expect(tiny.columns == 1 && tiny.cellWidth == 0 && tiny.height == 124)
        #expect(ComponentLayout.columns(width: 888, count: 3, workflow: true) == 3)
        #expect(ComponentLayout.columns(width: 887, count: 3, workflow: true) == 1)
    }

    @Test func labelsHintsAndTableTextHaveReservedFootprints() {
        #expect(ComponentLayout.fieldHeight() == 108)
        #expect(ComponentLayout.fieldHeight(hint: false) == 67)
        #expect(ComponentLayout.fieldHeight(hintHeight: 17) == 91)
        #expect(ComponentLayout.fieldHeight(control: 110) == 176)
        #expect(ComponentLayout.fieldHeight(label: false, hint: false) == 42)
        #expect(ComponentLayout.tableRowHeight(lines: 2) == 53)
        #expect(ComponentLayout.tableRowHeight(lines: 3) == 53)
        #expect(ComponentLayout.tableRowHeight(lines: 4) == 53)
        #expect(abs(ComponentLayout.textareaHeight() - 105.2) < 0.001)
        #expect(abs(ComponentLayout.textareaHeight(rows: 2) - 63.6) < 0.001)
    }

    @Test func workflowCardsKeepStatusAboveBottomTrailingCommandsAtEveryWidth() {
        for width in [1088.0, 424, 310, 246, 180, 34, 0] {
            for accessory in [false, true] {
                let card = ComponentLayout.workflowCard(width: width, accessory: accessory)
                #expect(card.height == 176 + StorebenchDesign.shared.number("control-height"))
                #expect(card.heading.maxY < card.description.minY)
                #expect(card.description.maxY < card.feedback.minY)
                #expect(card.feedback.maxY < card.action.minY)
                #expect(Double(card.action.height) == StorebenchDesign.shared.number("control-height"))
                for frame in [card.heading, card.description, card.feedback, card.action] {
                    #expect(frame.minX >= 0 && frame.maxX <= width && frame.width >= 0)
                    #expect(frame.minY >= 0 && frame.maxY <= card.height)
                }
                #expect(card.action.maxX == card.heading.maxX)
                #expect(Double(card.action.maxY) == card.height - 17)
                let design = StorebenchDesign.shared
                if width >= 280 { #expect(Double(card.action.width) == design.number("action-width") + (accessory ? design.number("control-height") + design.number("action-gap") : 0)) }
            }
        }
    }

    @Test func workflowCardsGrowWithCopyAndShareTheirNeighboursBottomCommandTrack() {
        let reserved = ComponentLayout.workflowCard(width: 410, accessory: true)
        for (description, feedback) in [(0.0, 0.0), (34, 52), (51, 69), (68, 120)] {
            let grown = ComponentLayout.workflowCard(width: 410, accessory: true, descriptionHeight: description, feedbackHeight: feedback)
            #expect(grown.description.height >= max(34, description) && grown.feedback.height >= max(42, feedback))
            #expect(grown.feedback.minY >= grown.description.maxY && grown.action.minY >= grown.feedback.maxY)
            #expect(grown.height >= reserved.height)
            // A neighbour in the same grid row receives the taller row and keeps its command on the shared bottom edge.
            let neighbour = ComponentLayout.workflowCard(width: 410, minimumHeight: grown.height)
            #expect(neighbour.height == grown.height && neighbour.action.maxY == grown.action.maxY)
            #expect(neighbour.feedback.maxY <= neighbour.action.minY && neighbour.heading == reserved.heading)
        }
    }

    @Test func textTracksReserveTheirMinimumAndGrowUntilTheirScrollLimit() {
        for content in [0.0, 17, 34, 51, 159, 160, 7200] {
            let height = ComponentLayout.textTrackFrame(minimumHeight: 24, contentHeight: content, maximumHeight: 160)
            #expect(height == min(max(24, content), 160))
            // A fixed track offered by a container still keeps the reserved minimum and scrolls the rest.
            #expect(ComponentLayout.textTrackFrame(minimumHeight: 24, contentHeight: content, maximumHeight: 160, offeredHeight: 42) == max(24, min(height, 42)))
            #expect(ComponentLayout.textTrackFrame(minimumHeight: 24, contentHeight: content, maximumHeight: 160, offeredHeight: 8) == 24)
            #expect(ComponentLayout.textTrackFrame(minimumHeight: 24, contentHeight: content, maximumHeight: 160, offeredHeight: .infinity) == height)
        }
        #expect(ComponentLayout.textTrackFrame(minimumHeight: 200, contentHeight: 20, maximumHeight: 160) == 200)
    }

    @Test func compactAssetCardsKeepLongNamesAndEqualRowActionsWithoutTheStatusTrack() {
        for width in [0.0, 180, 260, 360, 720] {
            let compact = ComponentLayout.assetCard(width: width, actionsHeight: 32, compact: true)
            let long = ComponentLayout.assetCard(width: width, actionsHeight: 32, titleHeight: 96, metadataHeight: 48, compact: true)
            let neighbour = ComponentLayout.assetCard(width: width, actionsHeight: 32, minimumHeight: long.height, compact: true)
            #expect(compact.identity.height == 0 && compact.title.minY == compact.identity.minY)
            #expect(compact.height < ComponentLayout.assetCard(width: width, actionsHeight: 32).height)
            #expect(long.metadata.minY >= long.title.maxY && long.divider.minY > long.metadata.maxY)
            #expect(neighbour.actions == long.actions && neighbour.divider == long.divider)
            for frame in [long.preview, long.title, long.metadata, long.divider, long.actions] {
                #expect(frame.minX >= 0 && frame.maxX <= width && frame.minY >= 0 && frame.maxY <= long.height)
            }
        }
    }

    @Test func assetCardsGrowWithLongNamesWithoutMovingNeighbourDividersOrCommands() {
        let ordinary = ComponentLayout.assetCard(width: 320, actionsHeight: 42)
        let long = ComponentLayout.assetCard(width: 320, actionsHeight: 42, titleHeight: 80, metadataHeight: 34)
        #expect(long.title.height == 80 && long.metadata.minY >= long.title.maxY && long.divider.minY > long.metadata.maxY)
        #expect(long.actions.minY > long.divider.maxY && long.height > ordinary.height)
        let neighbour = ComponentLayout.assetCard(width: 320, actionsHeight: 42, minimumHeight: long.height)
        #expect(neighbour.height == long.height && neighbour.divider.minY == long.divider.minY && neighbour.actions == long.actions)
        #expect(neighbour.title == ordinary.title && neighbour.metadata == ordinary.metadata)
    }

    @Test func disclosureLabelsCenterWithoutLosingTheBeginningOfLongText() {
        let reserved = StorebenchDesign.shared.dimension("disclosureLabel")
        for content in [0.0, 14, 18, 34, 72, 7200] {
            let track = ComponentLayout.textTrack(minimumHeight: reserved, contentHeight: content, centered: true)
            #expect(track.height >= reserved && track.height >= content)
            if content <= reserved { #expect(abs(track.contentOffset + content / 2 - reserved / 2) < 0.001) }
            else { #expect(track.contentOffset == 0 && track.height == content) }
            #expect(ComponentLayout.textTrack(minimumHeight: reserved, contentHeight: content).contentOffset == 0)
        }
        let design = StorebenchDesign.shared
        #expect(design.dimension("disclosureControl") == reserved + 2 * design.dimension("disclosurePaddingY"))
        #expect(design.dimension("disclosureRadius") == design.dimension("inputRadius"))
    }

    @Test func sourceRowsKeepTheirActionsContainedWhenTheWindowNarrows() {
        for width in [1088.0, 424, 422, 421, 390, 310, 180, 74, 20, 0] {
            let row = ComponentLayout.statusRow(width: width, headingHeight: 60, statusHeight: 22, actionHeight: 42)
            for frame in [row.heading, row.status, row.action, row.details] {
                #expect(frame.minX >= 0 && frame.maxX <= width && frame.width >= 0)
                #expect(frame.minY >= 0 && frame.maxY <= row.height)
            }
            #expect(Double(row.action.maxX) == width)
            #expect(row.status.maxX <= row.action.minX)
            if width >= 422 {
                #expect(!row.stacked && row.heading.width >= 240 && row.height == 60)
                #expect(row.heading.maxX < row.status.minX && row.heading.midY == row.action.midY)
            } else {
                #expect(row.stacked && row.heading.width == width)
                #expect(row.heading.maxY < row.status.minY && row.status.midY == row.action.midY)
            }
        }
    }

    @Test func expandingErrorDetailsUsesTheWholeRowWithoutMovingTheHeader() {
        for width in [1088.0, 424, 310, 180] {
            let idle = ComponentLayout.statusRow(width: width, headingHeight: 60, statusHeight: 22, actionHeight: 42)
            for detailsHeight in [42.0, 92, 360, 7200] {
                let expanded = ComponentLayout.statusRow(width: width, headingHeight: 60, statusHeight: 22, actionHeight: 42, detailsHeight: detailsHeight)
                #expect(expanded.heading == idle.heading && expanded.status == idle.status && expanded.action == idle.action)
                #expect(expanded.details.minX == 0 && expanded.details.width == width)
                #expect(expanded.details.minY == idle.height + 8 && expanded.details.maxY == expanded.height)
                #expect(expanded.height - idle.height == detailsHeight + 8)
            }
        }
    }

    @Test func statusAndOpenCommandsStayAlignedThroughEveryDisclosureStateAndLongDetail() {
        let design = StorebenchDesign.shared, control = design.number("control-height")
        let heading = design.dimension("sectionTitle") + design.dimension("sectionGap") + design.dimension("fieldHint")
        for width in [1380.0, 1088, 768, 514, 390, 310, 180] {
          for actionWidth in [74.0, design.number("action-width")] {
            let base = ComponentLayout.statusRow(width: width, headingHeight: heading, statusHeight: 30, actionHeight: control, statusWidth: 124, actionWidth: actionWidth)
            for details in [0.0, 28, 70, 212, 7200, 28, 0] {
                let row = ComponentLayout.statusRow(width: width, headingHeight: heading, statusHeight: 30, actionHeight: control, detailsHeight: details, statusWidth: 124, actionWidth: actionWidth)
                #expect(row.status.midY == row.action.midY)
                #expect(row.action.height == control && row.status.height == 30)
                #expect(row.heading == base.heading && row.status == base.status && row.action == base.action)
                #expect(row.details.minY >= max(row.heading.maxY, max(row.status.maxY, row.action.maxY)))
                #expect(!row.details.intersects(row.action) && !row.details.intersects(row.status))
                let separatorY = row.height + design.number("space-3")
                #expect(row.action.maxY < separatorY && row.status.maxY < separatorY && row.details.maxY < separatorY)
                for frame in [row.heading, row.status, row.action, row.details] {
                    #expect(frame.minX >= 0 && frame.maxX <= width && frame.maxY <= row.height)
                }
            }
          }
        }
    }

    @Test func smallDialogFieldsFollowTheActualWebMinimumAndSubgridSpacing() {
        let design = StorebenchDesign.shared
        let grid = ComponentLayout.grid(width: 436, heights: Array(repeating: ComponentLayout.fieldHeight() + design.dimension("formBottomPadding"), count: 6), maximum: 2, minimumWidth: design.dimension("formMinimumWidth"), rowSpacing: design.dimension("formRowGap"))
        #expect(grid.columns == 1)
        #expect(grid.rowHeights == Array(repeating: 116, count: 6))
        #expect(grid.rowOffsets == [0, 123, 246, 369, 492, 615])
    }

    @Test func wideAndOrdinaryDialogsRemainInsideTheirOwningViewport() {
        for width in [390.0, 760.0, 1280.0, 1920.0] {
            for height in [480.0, 840.0, 1000.0] {
                for wide in [false, true] {
                    let dialog = ComponentLayout.dialog(viewportWidth: width, viewportHeight: height, wide: wide, preferredHeight: 780)
                    #expect(dialog.width <= width - 32 && dialog.height <= height - 48)
                    #expect(dialog.width <= (wide ? 1040 : 480))
                }
            }
        }
        #expect(ComponentLayout.dialog(viewportWidth: 10, viewportHeight: 10) == .zero)
    }
}
