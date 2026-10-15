import AppKit
import NGTable

// The log entries, by column (a million entries are arrays, not objects),
// and the table's data source over them. Entries arrive in batches at the
// end; the oldest go when there are more than `limit`.

/// A log entry's level, as `log` names it.
nonisolated enum LogLevel: String, CaseIterable, Sendable {
    case fault = "Fault", error = "Error", `default` = "Default", info = "Info", debug = "Debug"

    var tag: NGTag {
        switch self {
        case .fault: NGTag("Fault", color: .red)
        case .error: NGTag("Error", color: .orange)
        case .default: NGTag("Default", color: .gray)
        case .info: NGTag("Info", color: .blue)
        case .debug: NGTag("Debug", color: .purple)
        }
    }
}

/// Entries read, before they go to the table.
nonisolated struct LogBatch: Sendable {
    var dates: [Date] = []
    var levels: [LogLevel] = []
    var processes: [String] = []
    var processIDs: [Int] = []
    var subsystems: [String] = []
    var categories: [String] = []
    var messages: [String] = []
    var count: Int { dates.count }

    mutating func append(_ other: LogBatch) {
        dates += other.dates
        levels += other.levels
        processes += other.processes
        processIDs += other.processIDs
        subsystems += other.subsystems
        categories += other.categories
        messages += other.messages
    }
}

final class LogEntries: NGTableViewDataSource {
    private(set) var entries = LogBatch()
    /// The most entries kept: the oldest go beyond it.
    var limit = 1_000_000
    /// Tags made once per level (a value per row, not an object).
    private let tags = Dictionary(uniqueKeysWithValues: LogLevel.allCases.map { ($0, NGCellValue.tags([$0.tag])) })

    var count: Int { entries.count }

    /// Adds a batch at the end, dropping the oldest beyond the limit:
    /// returns how many went from the start.
    func append(_ batch: LogBatch) -> Int {
        entries.append(batch)
        let excess = entries.count - limit
        guard excess > 0 else { return 0 }
        // A tenth more at once, so the arrays move now and then, not every batch.
        let dropped = min(entries.count, excess + limit / 10)
        entries.dates.removeFirst(dropped)
        entries.levels.removeFirst(dropped)
        entries.processes.removeFirst(dropped)
        entries.processIDs.removeFirst(dropped)
        entries.subsystems.removeFirst(dropped)
        entries.categories.removeFirst(dropped)
        entries.messages.removeFirst(dropped)
        return dropped
    }

    func removeAll() { entries = LogBatch() }

    func numberOfRows(in tableView: NGTableView) -> Int { entries.count }

    func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
        switch column.id {
        case "time": .date(entries.dates[row])
        case "level": tags[entries.levels[row]] ?? .empty
        case "process": .text(entries.processes[row])
        case "pid": .number(Double(entries.processIDs[row]))
        case "subsystem": .text(entries.subsystems[row])
        case "category": .text(entries.categories[row])
        case "message": .text(entries.messages[row])
        default: .empty
        }
    }

    func tableView(_ tableView: NGTableView, sortValueFor column: NGTableColumn, row: Int) -> NGCellValue {
        // Levels sort by severity, not by name.
        if column.id == "level" { return .number(Double(LogLevel.allCases.firstIndex(of: entries.levels[row]) ?? 0)) }
        return self.tableView(tableView, valueFor: column, row: row)
    }
}
