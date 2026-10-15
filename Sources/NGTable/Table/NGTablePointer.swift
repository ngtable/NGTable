#if os(macOS) || os(iOS)
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// The cell under the pointer (`hoveredCell`) and the delegate's enter and exit
// calls. AppKit only reports pointer movement when the mouse moves, so the
// cell is also found again when the rows scroll or change under a resting
// pointer.

extension NGTableView {
    /// Finds the cell at a point of the window (`nil`: outside the rows).
    func updateHoveredCell(atWindowPoint windowPoint: CGPoint?) {
        pointerWindowLocation = windowPoint
        setHoveredCell(windowPoint.flatMap(cell(atWindowPoint:)))
    }

    /// The cell at a point of the window, by geometry only.
    private func cell(atWindowPoint windowPoint: CGPoint) -> NGCellPosition? {
        guard window != nil, !ignoresUserInput else { return nil }
        let point = convert(windowPoint, from: nil)
        let row = row(at: point), column = column(at: point)
        guard row >= 0, column >= 0 else { return nil }
        return NGCellPosition(row: row, columnID: tableColumns[column].id)
    }

    #if os(macOS)
    /// Finds the cell under a resting pointer again (the rows moved under it).
    /// Runs after every scroll step and layout pass: the window server is only
    /// asked whether another window covers the table when the cell changes.
    func updateHoveredCellFromPointer() {
        // In a layout pass the delegate isn't told yet: what it does about the
        // pointer (e.g. reloading the row) would change the cells while they
        // are placed, and its layout request would be lost in this pass.
        if isInLayoutPass {
            scheduleHoverUpdate()
            return
        }
        if let pointerLocationForTesting {
            updateHoveredCell(atWindowPoint: pointerLocationForTesting)
            return
        }
        guard let window, window.isVisible else {
            setHoveredCell(nil)
            return
        }
        let location = window.mouseLocationOutsideOfEventStream
        pointerWindowLocation = location
        let cell = bounds.contains(convert(location, from: nil)) ? cell(atWindowPoint: location) : nil
        guard cell != hoveredCell else {
            // The same cell, but its row may have been reloaded under the pointer.
            syncMediaPlayerWithHoveredCell()
            return
        }
        if cell != nil {
            // Another window over the table there? Asked once per pointer
            // position while scrolling (the answer is kept for half a second:
            // a window may move away from a resting pointer).
            let screenLocation = NSEvent.mouseLocation
            let now = CACurrentMediaTime()
            let isCovered: Bool
            if let check = pointerCoverCheck, check.location == screenLocation, now - check.time < 0.5 {
                isCovered = check.isCovered
            } else {
                isCovered = NSWindow.windowNumber(at: screenLocation, belowWindowWithWindowNumber: 0) != window.windowNumber
                pointerCoverCheck = (screenLocation, isCovered, now)
            }
            if isCovered {
                setHoveredCell(nil)
                return
            }
        }
        setHoveredCell(cell)
    }
    #endif

    /// The motion under the pointer follows the cell's value: a reloaded row
    /// that shows the same media keeps playing (in the new cell object),
    /// other media plays instead, none stops it.
    func syncMediaPlayerWithHoveredCell() {
        guard let hoveredCell, let displayRow = displayRow(forSourceRow: hoveredCell.row),
              let cell = visibleCells[NGCellKey(row: displayRow, column: columnOrdinal(of: hoveredCell.columnID))] else { return }
        let media: NGMedia? = if case .media(let media) = cell.content, media.motion != nil { media } else { nil }
        if let player = mediaPlayer, let media, player.media == media {
            if player.cell !== cell {
                player.cell = cell
                setNeedsMetalFrame()
            }
            return
        }
        guard mediaPlayer != nil || media != nil else { return }
        hoveredCellDidChange(from: hoveredCell)
    }

    /// Finds the cell under the pointer on the next run loop turn (in any
    /// mode, nested loops too).
    func scheduleHoverUpdate() {
        guard !isHoverUpdateScheduled else { return }
        isHoverUpdateScheduled = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isHoverUpdateScheduled = false
                self.updateHoveredCellFromPointer()
            }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    func setHoveredCell(_ cell: NGCellPosition?) {
        // The same row index can be another record after rows came or went
        // under a resting pointer: that's another cell.
        let ref = cell.map { rowRef(ofRow: $0.row) }
        guard cell != hoveredCell || ref != hoveredCellRef else {
            syncMediaPlayerWithHoveredCell()
            syncControlUnderPointer()
            return
        }
        let old = hoveredCell
        hoveredCell = cell
        hoveredCellRef = ref
        if let old, let column = columnLayout.columnsByID[old.columnID] {
            delegate?.tableView(self, pointerDidExitRow: old.row, column: column)
        }
        hoveredCellDidChange(from: old)
        syncControlUnderPointer()
        if let cell, let column = columnLayout.columnsByID[cell.columnID] {
            delegate?.tableView(self, pointerDidEnterRow: cell.row, column: column)
        }
    }
}
#endif
