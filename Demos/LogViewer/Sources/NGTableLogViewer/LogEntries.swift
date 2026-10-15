import AppKit
import NGTable
import os

// The log entries, by column, and the table's data source over them. A
// million entries are a few arrays, not a million objects: messages are one
// buffer of UTF-8 with where each ends, processes, subsystems and categories
// numbers into a table of the strings (a string object a row, among the JSON
// objects read meanwhile, took ~1.3 KB an entry; now ~160 bytes). Entries
// arrive in batches at the end; the oldest go when there are more than
// `limit`.

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

/// The strings that repeat (processes, subsystems, categories), each once,
/// by number: filled on the reading thread, read on the main actor.
nonisolated final class LogStrings: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (strings: [""], numbers: ["": Int32(0)]))

    func number(of text: String) -> Int32 {
        state.withLock { state in
            if let number = state.numbers[text] { return number }
            // Native, not the bridged JSON string (it keeps its object).
            let native = String(decoding: Array(text.utf8), as: UTF8.self)
            let number = Int32(state.strings.count)
            state.strings.append(native)
            state.numbers[native] = number
            return number
        }
    }

    func string(_ number: Int32) -> String {
        state.withLock { Int(number) < $0.strings.count ? $0.strings[Int(number)] : "" }
    }
}

/// Entries by column, as read (a batch) or kept (the table's).
nonisolated struct LogBatch: Sendable {
    var dates: [Date] = []
    var levels: [LogLevel] = []
    var processes: [Int32] = []
    var processIDs: [Int32] = []
    var subsystems: [Int32] = []
    var categories: [Int32] = []
    /// The messages' UTF-8, one after another, and where each ends.
    var messageBytes: [UInt8] = []
    var messageEnds: [Int] = []
    var count: Int { dates.count }

    mutating func append(_ other: LogBatch) {
        dates += other.dates
        levels += other.levels
        processes += other.processes
        processIDs += other.processIDs
        subsystems += other.subsystems
        categories += other.categories
        let base = messageBytes.count
        messageBytes += other.messageBytes
        messageEnds += other.messageEnds.lazy.map { $0 + base }
    }

    /// The first `count` entries gone.
    mutating func removeFirst(_ count: Int) {
        guard count > 0 else { return }
        let bytes = messageEnds[count - 1]
        dates.removeFirst(count)
        levels.removeFirst(count)
        processes.removeFirst(count)
        processIDs.removeFirst(count)
        subsystems.removeFirst(count)
        categories.removeFirst(count)
        messageBytes.removeFirst(bytes)
        messageEnds.removeFirst(count)
        for index in messageEnds.indices { messageEnds[index] -= bytes }
    }

    func message(_ row: Int) -> String {
        let start = row > 0 ? messageEnds[row - 1] : 0
        return String(decoding: messageBytes[start..<messageEnds[row]], as: UTF8.self)
    }
}

final class LogEntries: NGTableViewDataSource {
    private(set) var entries = LogBatch()
    let strings: LogStrings
    /// The most entries kept: the oldest go beyond it.
    var limit = 1_000_000
    /// Tags made once per level (a value per row, not an object).
    private let tags = Dictionary(uniqueKeysWithValues: LogLevel.allCases.map { ($0, NGCellValue.tags([$0.tag])) })

    init(strings: LogStrings) {
        self.strings = strings
    }

    var count: Int { entries.count }

    /// Adds a batch at the end, dropping the oldest beyond the limit:
    /// returns how many went from the start.
    func append(_ batch: LogBatch) -> Int {
        entries.append(batch)
        let excess = entries.count - limit
        guard excess > 0 else { return 0 }
        // A tenth more at once, so the arrays move now and then, not every batch.
        let dropped = min(entries.count, excess + limit / 10)
        entries.removeFirst(dropped)
        return dropped
    }

    func removeAll() { entries = LogBatch() }

    func numberOfRows(in tableView: NGTableView) -> Int { entries.count }

    func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
        switch column.id {
        case "time": .date(entries.dates[row])
        case "level": tags[entries.levels[row]] ?? .empty
        case "process": .text(strings.string(entries.processes[row]))
        case "pid": .number(Double(entries.processIDs[row]))
        case "subsystem": .text(strings.string(entries.subsystems[row]))
        case "category": .text(strings.string(entries.categories[row]))
        case "message": .text(entries.message(row))
        default: .empty
        }
    }

    func tableView(_ tableView: NGTableView, sortValueFor column: NGTableColumn, row: Int) -> NGCellValue {
        // Levels sort by severity, not by name.
        if column.id == "level" { return .number(Double(LogLevel.allCases.firstIndex(of: entries.levels[row]) ?? 0)) }
        return self.tableView(tableView, valueFor: column, row: row)
    }
}
