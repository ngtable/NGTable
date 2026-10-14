#if os(macOS)
import AppKit
import UniformTypeIdentifiers

// Exporting the table to a file (see NGTableExport.swift for the formats):
// the visible columns in display order, the rows shown (or selected) in
// display order, and the summary row. Values are read on the main actor in
// slices of a few milliseconds by row handle, so a live feed moving rows
// meanwhile doesn't mix records up, and handed in chunks to a writer off the
// main thread, which formats and writes one while the next is read: the
// export holds a chunk or two, not the whole table. A file is written beside
// the destination and moved over it when done.

/// Rows read for an export or a copy (see `NGTableView.readValues`).
enum NGReadChunk: Sendable {
    /// What came before is dropped: the rows are read again.
    case restart
    /// The next rows, a value for each column.
    case values([NGCellValue])
}

extension NGTableView {
    /// The table as a file's contents: CSV or an Excel workbook of the
    /// visible columns and the rows the options pick, as shown. Large tables
    /// are read in slices, keeping the app responsive (`isExporting`).
    /// Empty when nothing could be exported: no data source, the task
    /// cancelled, or a workbook of 4 GB or more (`export(to:as:options:)`
    /// throws then). The file is built in memory: for a large table,
    /// `export(to:as:options:)` writes it as it goes instead.
    public func exportedData(as format: NGExportFormat, options: NGExportOptions = NGExportOptions()) async -> Data {
        let sink = NGExportSink()
        guard (try? await export(into: sink, as: format, options: options)) != nil else { return Data() }
        return sink.contents
    }

    /// Writes the table to a file (see `exportedData(as:options:)`), as the
    /// rows are read: a chunk of rows at a time in memory. The file appears
    /// when it is done; until then (and if the export fails) a file already
    /// there stays as it was. Throws when nothing could be written (a
    /// workbook of 4 GB or more, no data source, the task cancelled, or the
    /// file system's error).
    public func export(to url: URL, as format: NGExportFormat, options: NGExportOptions = NGExportOptions()) async throws {
        let files = FileManager.default
        let directory = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
        defer { try? files.removeItem(at: directory) }
        let written = directory.appendingPathComponent(url.lastPathComponent)
        guard files.createFile(atPath: written.path, contents: nil) else { throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: url]) }
        let file = try FileHandle(forWritingTo: written)
        do {
            try await export(into: NGExportSink(file: file), as: format, options: options)
            try file.close()
        } catch {
            try? file.close()
            throw error is NGExportError ? CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: url]) : error
        }
        if files.fileExists(atPath: url.path) {
            _ = try files.replaceItemAt(url, withItemAt: written)
        } else {
            try files.moveItem(at: written, to: url)
        }
    }

    /// Asks where to save the rows shown, as an Excel workbook or CSV, and
    /// exports them there: an action for an "Export…" menu item, which goes
    /// to the table through the responder chain.
    @IBAction public func exportDocument(_ sender: Any?) {
        guard let window, !isExporting else { return }
        let panel = NSSavePanel()
        let formats: [(format: NGExportFormat, title: String)] = [
            (.xlsx, String(localized: "Excel Workbook", bundle: .module, comment: "Export: the .xlsx format.")),
            (.csv, String(localized: "CSV (Comma-Separated Values)", bundle: .module, comment: "Export: the .csv format.")),
        ]
        let chooser = NGExportFormatChooser(panel: panel, formats: formats.map(\.format))
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: formats.map(\.title))
        popup.target = chooser
        popup.action = #selector(NGExportFormatChooser.formatChanged(_:))
        let label = NSTextField(labelWithString: String(localized: "Format:", bundle: .module, comment: "Export: the label of the file format menu."))
        let accessory = NSStackView(views: [label, popup])
        accessory.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        panel.accessoryView = accessory
        panel.nameFieldStringValue = exportFileName ?? autosaveName ?? String(localized: "Table", bundle: .module,
                                                                               comment: "Export: the file name when the table has none.")
        panel.canCreateDirectories = true
        chooser.formatChanged(popup)
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            let format = chooser.format
            Task { @MainActor [weak self] in
                do {
                    try await self?.export(to: url, as: format)
                } catch {
                    // Like a document's save: the error in a sheet on the window.
                    if let window = self?.window { self?.presentError(error, modalFor: window, delegate: nil, didPresent: nil, contextInfo: nil) }
                }
            }
        }
    }

    /// Reads the rows and writes them into `sink`: a chunk written off the
    /// main thread while the next is read, the summary row last.
    private func export(into sink: NGExportSink, as format: NGExportFormat, options: NGExportOptions) async throws {
        guard dataSource != nil else { throw CocoaError(.fileWriteUnknown) }
        let columns = columnLayout.allColumns
        let selectedOnly = options.rows == .selected
        // (Exports at once each count: the first to end doesn't say it's over.)
        exportsRunning += 1
        isExporting = true
        defer {
            exportsRunning -= 1
            isExporting = exportsRunning > 0
        }
        let layout = NGExportLayout(
            columns: columns.map { column in
                let isCount = if case .aggregate(.count, _) = column.summary { true } else { false }
                return NGExportLayout.Column(title: column.menuTitle, format: column.format, width: width(ofColumnID: column.id) ?? column.width,
                                             isCount: isCount)
            },
            maxRowsPerSheet: exportMaxRowsPerSheet, locale: formattingLocale)
        let writer = NGTableExport.writer(for: format, layout: layout, sink: sink)
        // The chunk being written, and the first error writing.
        var writing: Task<Void, any Error>?
        var failure: (any Error)?
        let read = await readValues(columns: columns, rows: { table in
            selectedOnly ? table.rowHandles.refs(atIndexes: table.inDisplayOrder(table.selectedRowIndexes)) : table.shownRowRefs()
        }, chunkRows: max(1, exportChunkCells / max(1, columns.count))) { chunk in
            // One chunk at a time: the one before written first.
            do { try await writing?.value } catch {
                failure = error
                return false
            }
            writing = Task.detached(priority: .userInitiated) {
                switch chunk {
                case .restart: try writer.restart()
                case .values(let values): try writer.write(rows: values)
                }
            }
            return true
        }
        try await writing?.value
        if let failure { throw failure }
        guard read else { throw CocoaError(.userCancelled) }
        let summary = options.includesSummaryRow && showsSummaryRow
            ? NGExportSummary(texts: columns.map { summaryText(forColumnID: $0.id) ?? "" }, values: columns.map { summaryValue(forColumnID: $0.id) })
            : nil
        try await Task.detached(priority: .userInitiated) { try writer.finish(summary: summary) }.value
    }
}
/// The save panel's format menu: sets the panel's file type.
@MainActor
final class NGExportFormatChooser: NSObject {
    private weak var panel: NSSavePanel?
    private let formats: [NGExportFormat]
    private(set) var format: NGExportFormat

    init(panel: NSSavePanel, formats: [NGExportFormat]) {
        self.panel = panel
        self.formats = formats
        format = formats.first ?? .xlsx
    }

    @objc func formatChanged(_ sender: NSPopUpButton) {
        format = formats[max(0, min(formats.count - 1, sender.indexOfSelectedItem))]
        if let type = UTType(filenameExtension: format.fileExtension) {
            panel?.allowedContentTypes = [type]
        }
    }
}
#endif
