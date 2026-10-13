#if os(macOS)
import AppKit
import Testing
@testable import NGTable

/// Controls drawn in cells: a plain click on a link (pressed and released in
/// its cell) calls the delegate, which opens its URL by default, and doesn't
/// select the row; dragged out, nothing happens; Command-click selects the
/// row. Under the pointer the link is underlined and the cursor is the
/// pointing hand. Space on the focused cell and VoiceOver's press work too.
@Suite("Cell controls")
@MainActor
struct NGCellControlsTests {
    @MainActor
    final class Links: NGTableViewDataSource, NGTableViewDelegate {
        var clicked: [(row: Int, link: NGLink)] = []
        var handlesClicks = true

        func numberOfRows(in tableView: NGTableView) -> Int { 10 }

        func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
            switch column.id {
            case "name": .text("Row \(row)")
            case "site": .link(NGLink("site\(row).example", url: URL(string: "https://site\(row).example")))
            default: .empty
            }
        }

        func tableView(_ tableView: NGTableView, didClickLink link: NGLink, in column: NGTableColumn, row: Int) {
            clicked.append((row, link))
        }
    }

    private func makeTable(_ source: Links, delegate: Bool = true) -> (NGTableView, NSWindow) {
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let window = NSWindow(contentRect: table.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        table.columns = [.column(NGTableColumn("name", title: "Name", width: 120)),
                         .column(NGTableColumn("site", title: "Site", width: 200))]
        window.contentView = table
        table.dataSource = source
        if delegate { table.delegate = source }
        table.navigatesByCell = true
        table.layoutSubtreeIfNeeded()
        window.makeFirstResponder(table)
        return (table, window)
    }

    private func point(_ table: NGTableView, row: Int, columnID: String) throws -> NSPoint {
        let frame = try #require(table.frameOfCell(row: row, columnID: columnID))
        return table.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
    }

    private func mouse(_ type: NSEvent.EventType, at location: NSPoint, in window: NSWindow,
                       modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifiers, timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    @Test func clickingALinkCallsTheDelegate() throws {
        let source = Links()
        let (table, window) = makeTable(source)
        defer { withExtendedLifetime((source, window)) {} }
        let link = try point(table, row: 3, columnID: "site")
        table.rowsMouseDown(try mouse(.leftMouseDown, at: link, in: window), in: table.centerRegion)
        #expect(table.visibleCell(sourceRow: 3, columnID: "site")?.isPressed == true)
        table.rowsMouseUp(try mouse(.leftMouseUp, at: link, in: window))
        #expect(source.clicked.map(\.row) == [3])
        #expect(source.clicked.first?.link.url?.host == "site3.example")
        #expect(table.selectedRowIndexes.isEmpty)
        #expect(table.visibleCell(sourceRow: 3, columnID: "site")?.isPressed == false)
        // Dragged out before the release: nothing.
        table.rowsMouseDown(try mouse(.leftMouseDown, at: link, in: window), in: table.centerRegion)
        let outside = try point(table, row: 5, columnID: "name")
        table.rowsMouseDragged(try mouse(.leftMouseDragged, at: outside, in: window))
        #expect(table.visibleCell(sourceRow: 3, columnID: "site")?.isPressed == false)
        table.rowsMouseUp(try mouse(.leftMouseUp, at: outside, in: window))
        #expect(source.clicked.count == 1)
        // Command-click selects the row, as anywhere.
        table.rowsMouseDown(try mouse(.leftMouseDown, at: link, in: window, modifiers: .command), in: table.centerRegion)
        table.rowsMouseUp(try mouse(.leftMouseUp, at: link, in: window, modifiers: .command))
        #expect(table.selectedRowIndexes == [3] && source.clicked.count == 1)
        // A click beside it, in another column, selects.
        table.rowsMouseDown(try mouse(.leftMouseDown, at: try point(table, row: 6, columnID: "name"), in: window), in: table.centerRegion)
        table.rowsMouseUp(try mouse(.leftMouseUp, at: try point(table, row: 6, columnID: "name"), in: window))
        #expect(table.selectedRowIndexes == [6])
    }

    @Test func spaceAndVoiceOverPressALink() throws {
        let source = Links()
        let (table, window) = makeTable(source)
        defer { withExtendedLifetime((source, window)) {} }
        table.focusedCell = NGCellPosition(row: 2, columnID: "site")
        table.keyDown(with: try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                          windowNumber: window.windowNumber, context: nil, characters: " ",
                                                          charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)))
        #expect(source.clicked.map(\.row) == [2])
        let rows = try #require(table.accessibilityRows() as? [NGAccessibilityRow])
        let cell = try #require((rows[4].accessibilityChildren() as? [NGAccessibilityCell])?.first { $0.column.id == "site" })
        #expect(cell.isAccessibilitySelectorAllowed(#selector(NSAccessibilityElement.accessibilityPerformPress)))
        #expect(cell.accessibilityRoleDescription() == NSAccessibility.Role.link.description(with: nil))
        #expect(cell.accessibilityPerformPress())
        #expect(source.clicked.map(\.row) == [2, 4])
        let name = try #require((rows[4].accessibilityChildren() as? [NGAccessibilityCell])?.first { $0.column.id == "name" })
        #expect(!name.isAccessibilitySelectorAllowed(#selector(NSAccessibilityElement.accessibilityPerformPress)))
    }

    /// Without a delegate (or one that doesn't take clicks), the link opens its URL.
    @Test func linksOpenTheirURLByDefault() throws {
        let source = Links()
        let (table, window) = makeTable(source, delegate: false)
        defer {
            withExtendedLifetime((source, window)) {}
            NGTableView.openURLForTesting = nil
        }
        var opened: [URL] = []
        NGTableView.openURLForTesting = { opened.append($0) }
        #expect(table.activateControl(row: 7, columnID: "site"))
        #expect(opened == [URL(string: "https://site7.example")!])
        #expect(!table.activateControl(row: 7, columnID: "name"))
    }

    @MainActor
    final class Buttons: NSObject, NGTableViewDataSource, NGTableViewDelegate {
        var pressed: [Int] = []
        var doubleActions = 0

        func numberOfRows(in tableView: NGTableView) -> Int { 6 }

        func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
            column.id == "name" ? .text("Row \(row)") : .button(NGCellButton("Open", isEnabled: row != 4))
        }

        func tableView(_ tableView: NGTableView, didPressButton button: NGCellButton, in column: NGTableColumn, row: Int) {
            pressed.append(row)
        }

        @objc func doubleClicked(_ sender: Any?) { doubleActions += 1 }
    }

    /// A press on the bezel (released there) presses the button; one beside
    /// it in the cell selects the row; a disabled one can't be pressed; a
    /// double click on it isn't the table's double action.
    @Test func pressingAButton() throws {
        let source = Buttons()
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let window = NSWindow(contentRect: table.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        table.columns = [.column(NGTableColumn("name", title: "Name", width: 100)),
                         .column(NGTableColumn("action", title: "Action", width: 200, alignment: .center))]
        window.contentView = table
        table.dataSource = source
        table.delegate = source
        table.target = source
        table.doubleAction = #selector(Buttons.doubleClicked(_:))
        table.navigatesByCell = true
        table.layoutSubtreeIfNeeded()
        window.makeFirstResponder(table)
        defer { withExtendedLifetime((source, window)) {} }
        let frame = try #require(table.frameOfCell(row: 2, columnID: "action"))
        let onBezel = table.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
        let beside = table.convert(NSPoint(x: frame.minX + 8, y: frame.midY), to: nil)
        table.rowsMouseDown(try mouse(.leftMouseDown, at: onBezel, in: window), in: table.centerRegion)
        #expect(table.visibleCell(sourceRow: 2, columnID: "action")?.isPressed == true)
        // Out of the bezel and back while held: released on it, it's pressed.
        table.rowsMouseDragged(try mouse(.leftMouseDragged, at: beside, in: window))
        #expect(table.visibleCell(sourceRow: 2, columnID: "action")?.isPressed == false)
        table.rowsMouseDragged(try mouse(.leftMouseDragged, at: onBezel, in: window))
        table.rowsMouseUp(try mouse(.leftMouseUp, at: onBezel, in: window))
        #expect(source.pressed == [2] && table.selectedRowIndexes.isEmpty)
        // Beside the bezel: the row.
        table.rowsMouseDown(try mouse(.leftMouseDown, at: beside, in: window), in: table.centerRegion)
        table.rowsMouseUp(try mouse(.leftMouseUp, at: beside, in: window))
        #expect(source.pressed == [2] && table.selectedRowIndexes == [2])
        // Disabled: the row too.
        let disabledFrame = try #require(table.frameOfCell(row: 4, columnID: "action"))
        let disabled = table.convert(NSPoint(x: disabledFrame.midX, y: disabledFrame.midY), to: nil)
        table.rowsMouseDown(try mouse(.leftMouseDown, at: disabled, in: window), in: table.centerRegion)
        table.rowsMouseUp(try mouse(.leftMouseUp, at: disabled, in: window))
        #expect(source.pressed == [2] && table.selectedRowIndexes == [4])
        // A double click on a button: pressed twice, no double action.
        for count in 1...2 {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(with: type, location: onBezel, modifierFlags: [], timestamp: 0,
                                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                            clickCount: count, pressure: 1))
                type == .leftMouseDown ? table.rowsMouseDown(event, in: table.centerRegion) : table.rowsMouseUp(event)
            }
        }
        #expect(source.pressed == [2, 2, 2] && source.doubleActions == 0)
        // Space and VoiceOver; not a disabled one.
        table.focusedCell = NGCellPosition(row: 1, columnID: "action")
        table.keyDown(with: try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                          windowNumber: window.windowNumber, context: nil, characters: " ",
                                                          charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)))
        #expect(source.pressed == [2, 2, 2, 1])
        let rows = try #require(table.accessibilityRows() as? [NGAccessibilityRow])
        func cell(_ row: Int) throws -> NGAccessibilityCell {
            try #require((rows[row].accessibilityChildren() as? [NGAccessibilityCell])?.first { $0.column.id == "action" })
        }
        #expect(try cell(0).accessibilityRoleDescription() == NSAccessibility.Role.button.description(with: nil))
        #expect(try cell(0).accessibilityPerformPress())
        #expect(!(try cell(4).isAccessibilitySelectorAllowed(#selector(NSAccessibilityElement.accessibilityPerformPress))))
        #expect(source.pressed == [2, 2, 2, 1, 0])
        // Buttons keep the arrow cursor.
        table.pointerLocationForTesting = onBezel
        table.updateHoveredCellFromPointer()
        #expect(!table.showsPointingHand)
    }

    /// Under the pointer: underlined, the pointing hand; elsewhere neither.
    @Test func thePointerOverALink() throws {
        let source = Links()
        let (table, window) = makeTable(source)
        defer { withExtendedLifetime((source, window)) {} }
        table.pointerLocationForTesting = try point(table, row: 1, columnID: "site")
        table.updateHoveredCellFromPointer()
        #expect(table.visibleCell(sourceRow: 1, columnID: "site")?.isPointerOver == true)
        #expect(table.showsPointingHand)
        table.pointerLocationForTesting = try point(table, row: 1, columnID: "name")
        table.updateHoveredCellFromPointer()
        #expect(table.visibleCell(sourceRow: 1, columnID: "site")?.isPointerOver == false)
        #expect(!table.showsPointingHand)
        // A link sorts and copies as its title.
        #expect(NGCellValue.link(NGLink("b")).sortsBefore(.link(NGLink("c"))))
        #expect(NGValueFormat.automatic.string(for: .link(NGLink("site.example"))) == "site.example")
    }
}
#endif
