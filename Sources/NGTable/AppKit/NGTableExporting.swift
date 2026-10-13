#if os(macOS)
import AppKit
import UniformTypeIdentifiers

// Exporting the table to a file (see NGTableExport.swift for the formats):
// the visible columns in display order, the rows shown (or selected) in
// display order, and the summary row. Values are read on the main actor in
// slices of a few milliseconds by row handle, so a live feed moving rows
// meanwhile doesn't mix records up, then the file is written off the main
// thread.

extension NGTableView {
    /// The table as a file's contents: CSV or an Excel workbook of the
    /// visible columns and the rows the options pick, as shown. Large tables
    /// are read in slices, keeping the app responsive (`isExporting`).
    /// Empty when nothing could be exported: no data source, the task
    /// cancelled, or a workbook of 4 GB or more (`export(to:as:options:)`
    /// throws then).
    public func exportedData(as format: NGExportFormat, options: NGExportOptions = NGExportOptions()) async -> Data {
        guard let content = await exportContent(options: options) else { return Data() }
        return await Task.detached(priority: .userInitiated) {
            NGTableExport.data(content, as: format)
        }.value
    }

    /// Writes the table to a file (see `exportedData(as:options:)`).
    /// Throws when nothing could be written (a workbook of 4 GB or more,
    /// or no data source).
    public func export(to url: URL, as format: NGExportFormat, options: NGExportOptions = NGExportOptions()) async throws {
        let data = await exportedData(as: format, options: options)
        guard !data.isEmpty else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url, options: .atomic)
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

    /// Reads the values to export.
    private func exportContent(options: NGExportOptions) async -> NGExportContent? {
        guard dataSource != nil else { return nil }
        let columns = columnLayout.allColumns
        let selectedOnly = options.rows == .selected
        // (Exports at once each count: the first to end doesn't say it's over.)
        exportsRunning += 1
        isExporting = true
        defer {
            exportsRunning -= 1
            isExporting = exportsRunning > 0
        }
        guard let values = await readValues(columns: columns, rows: { table in
            if selectedOnly { return table.inDisplayOrder(table.selectedRowIndexes) }
            // Group headers have no data source row.
            return (0..<table.numberOfRows).map(table.sourceRow).filter { $0 >= 0 }
        }) else { return nil }
        let summary = options.includesSummaryRow && showsSummaryRow
        return NGExportContent(
            columns: columns.map { NGExportContent.Column(title: $0.menuTitle, format: $0.format, width: width(ofColumnID: $0.id) ?? $0.width) },
            values: values,
            summaryTexts: summary ? columns.map { summaryText(forColumnID: $0.id) ?? "" } : nil,
            summaryValues: summary ? columns.map { summaryValue(forColumnID: $0.id) } : nil,
            summaryIsCount: summary ? columns.map { if case .aggregate(.count, _) = $0.summary { true } else { false } } : nil,
            maxRowsPerSheet: exportMaxRowsPerSheet, locale: formattingLocale)
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
