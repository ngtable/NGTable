import Foundation
import os

// Reads the Mac's logs from the `log` tool as JSON lines (`--style ndjson`):
// `log stream` as they come, or `log show --last` for a stretch of the past.
// A thread of its own reads and parses them; every tenth of a second the
// entries read so far go to the main actor in one batch.

nonisolated final class LogReader: @unchecked Sendable {   // (Its process is only started and stopped.)
    enum Source: Sendable {
        /// From now on, as they come.
        case live
        /// The entries of the last minutes (then it ends).
        case last(minutes: Int)
    }

    private let process = Process()
    private let pending = OSAllocatedUnfairLock(initialState: (batch: LogBatch(), ended: false))
    private let timer: DispatchSourceTimer

    /// Starts reading; `deliver` gets the batches on the main actor, and
    /// `finished` once the tool has ended (`log show`) or was stopped.
    init(_ source: Source, deliver: @escaping @MainActor @Sendable (LogBatch) -> Void,
         finished: @escaping @MainActor @Sendable () -> Void) {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        switch source {
        case .live: process.arguments = ["stream", "--style", "ndjson", "--level", "info"]
        case .last(let minutes): process.arguments = ["show", "--style", "ndjson", "--info", "--last", "\(minutes)m"]
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        timer = DispatchSource.makeTimerSource(queue: .main)
        let pending = pending
        let timer = timer
        timer.setEventHandler {
            let (batch, ended) = pending.withLock { state in
                defer { state.batch = LogBatch() }
                return (state.batch, state.ended)
            }
            MainActor.assumeIsolated {
                if batch.count > 0 { deliver(batch) }
                if ended {
                    timer.cancel()
                    finished()
                }
            }
        }
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.resume()
        let handle = pipe.fileHandleForReading
        Thread.detachNewThread {
            var parser = LogLineParser()
            var buffer = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                var batch = LogBatch()
                // Whole lines; the rest waits for the next chunk. (The JSON
                // objects go with each chunk: without a pool of its own the
                // thread kept a million lines' objects, 3 GB, to the end.)
                var start = buffer.startIndex
                autoreleasepool {
                    while let newline = buffer[start...].firstIndex(of: 0x0A) {
                        parser.parse(buffer[start..<newline], into: &batch)
                        start = buffer.index(after: newline)
                    }
                }
                buffer.removeSubrange(buffer.startIndex..<start)
                guard batch.count > 0 else { continue }
                let read = batch
                pending.withLock { $0.batch.append(read) }
            }
            pending.withLock { $0.ended = true }
        }
        try? process.run()
    }

    func stop() {
        if process.isRunning { process.terminate() }
    }

    deinit {
        timer.cancel()
        if process.isRunning { process.terminate() }
    }
}

/// One JSON line of `log` into an entry (lines that aren't entries are skipped).
nonisolated struct LogLineParser {
    /// Process names by path: a few hundred processes write most lines.
    private var names: [String: String] = [:]
    /// Subsystems and categories repeat: each kept once (a string a row
    /// cost more than the rest of the entry).
    private var strings: Set<String> = []

    private mutating func interned(_ text: String) -> String {
        if let kept = strings.firstIndex(of: text) { return strings[kept] }
        // Native, not the bridged JSON string (its own object per row).
        let native = String(decoding: Array(text.utf8), as: UTF8.self)
        strings.insert(native)
        return native
    }

    mutating func parse(_ line: Data, into batch: inout LogBatch) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["eventType"] as? String == "logEvent",
              let timestamp = object["timestamp"] as? String, let date = Self.date(timestamp) else { return }
        let path = object["processImagePath"] as? String ?? ""
        let process: String
        if let known = names[path] {
            process = known
        } else {
            process = String(decoding: Array((path as NSString).lastPathComponent.utf8), as: UTF8.self)
            names[path] = process
        }
        batch.dates.append(date)
        batch.levels.append(LogLevel(rawValue: object["messageType"] as? String ?? "") ?? .default)
        batch.processes.append(process)
        batch.processIDs.append(object["processID"] as? Int ?? 0)
        batch.subsystems.append(interned(object["subsystem"] as? String ?? ""))
        batch.categories.append(interned(object["category"] as? String ?? ""))
        // A native string: the bridged one keeps its JSON object's storage.
        batch.messages.append(String(decoding: Array((object["eventMessage"] as? String ?? "").utf8), as: UTF8.self))
    }

    /// "2026-10-15 09:55:44.895142+0300", read by hand (a formatter took
    /// longer than the rest of the line).
    static func date(_ text: String) -> Date? {
        let bytes = Array(text.utf8)
        guard bytes.count >= 19 else { return nil }
        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for index in range {
                guard index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 else { return nil }
                value = value * 10 + Int(bytes[index] - 48)
            }
            return value
        }
        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19) else { return nil }
        var index = 19
        var fraction = 0.0, scale = 0.1
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            index += 1
            while index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 {
                fraction += Double(bytes[index] - 48) * scale
                scale /= 10
                index += 1
            }
        }
        var offset = 0
        if index + 5 <= bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-"),
           let hours = number((index + 1)..<(index + 3)), let minutes = number((index + 3)..<(index + 5)) {
            offset = (hours * 3_600 + minutes * 60) * (bytes[index] == UInt8(ascii: "-") ? -1 : 1)
        }
        // Days since 1970 (civil from days, Howard Hinnant's).
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146_097 + dayOfEra - 719_468
        let seconds = days * 86_400 + hour * 3_600 + minute * 60 + second - offset
        return Date(timeIntervalSince1970: Double(seconds) + fraction)
    }
}
