#if os(macOS)
import AppKit
import Testing
import os
@testable import NGTable

// Export benchmark: a table of 20 columns (names, statuses, numbers, a date,
// a check mark) written to a file as CSV and as a workbook: how long it
// takes, how much more memory the process takes at most meanwhile (its
// footprint sampled every few milliseconds), and the longest the main
// thread is held. Skipped unless NGTABLE_BENCH is set; meant for release
// builds:
//
//     NGTABLE_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter NGExportBenchmark

@MainActor
private final class Campaigns: NGTableViewDataSource {
    static let statuses = ["Active", "Paused", "Archived", "Draft"]
    let names: [String]
    let numbers: [Double]
    static let numberColumns = 16

    init(count: Int) {
        var generator = SplitMix(seed: 5)
        names = (0..<count).map { "Campaign \($0) — \(generator.next() % 100_000)" }
        numbers = (0..<(count * Self.numberColumns)).map { _ in Double(generator.next() % 10_000_000) / 100 }
    }

    func numberOfRows(in tableView: NGTableView) -> Int { names.count }
    func tableView(_ tableView: NGTableView, valueFor column: NGTableColumn, row: Int) -> NGCellValue {
        switch column.id {
        case "name": .text(names[row])
        case "status": .text(Self.statuses[row % Self.statuses.count])
        case "date": .date(Date(timeIntervalSince1970: 1_700_000_000 + Double(row) * 60))
        case "on": .bool(row % 3 == 0)
        default: .number(numbers[row * Self.numberColumns + (Int(column.id.dropFirst()) ?? 0)])
        }
    }
}

/// The process's footprint, its largest since `start`, sampled on a thread
/// of its own.
private final class FootprintSampler: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (running: true, peak: UInt64(0)))

    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    func start() {
        Thread.detachNewThread { [self] in
            while state.withLock({ $0.running }) {
                let now = Self.footprint()
                state.withLock { $0.peak = max($0.peak, now) }
                usleep(2_000)
            }
        }
    }

    func stop() -> UInt64 {
        state.withLock {
            $0.running = false
            return $0.peak
        }
    }
}

extension NGBenchmarks {
    @Suite("Export benchmark", .enabled(if: ProcessInfo.processInfo.environment["NGTABLE_BENCH"] != nil), .serialized)
    @MainActor
    struct NGExportBenchmark {
        static let rows = Int(ProcessInfo.processInfo.environment["NGTABLE_BENCH_ROWS"] ?? "") ?? 300_000

        @Test(arguments: [NGExportFormat.csv, .xlsx])
        func exportingToAFile(_ format: NGExportFormat) async throws {
            let campaigns = Campaigns(count: Self.rows)
            let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
            defer { withExtendedLifetime(campaigns) {} }
            table.columns = [.column(NGTableColumn("name", title: "Name", width: 200)),
                             .column(NGTableColumn("status", title: "Status", width: 80)),
                             .column(NGTableColumn("date", title: "Created", width: 120, format: .date(includesTime: true))),
                             .column(NGTableColumn("on", title: "On", width: 40))]
                + (0..<Campaigns.numberColumns).map { .column(NGTableColumn("n\($0)", title: "Number \($0)", width: 90,
                                                                            format: $0 % 4 == 0 ? .currency(code: "USD") : .number(fractionDigits: 2),
                                                                            summary: .aggregate(.sum))) }
            table.dataSource = campaigns
            table.layoutSubtreeIfNeeded()
            // The summaries' values (a Double a row and summed column) taken before.
            while table.isComputingSummary { try await Task.sleep(for: .milliseconds(5)) }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("NGExportBenchmark-\(UUID().uuidString).\(format.fileExtension)")
            defer { try? FileManager.default.removeItem(at: url) }

            let before = FootprintSampler.footprint()
            let sampler = FootprintSampler()
            sampler.start()
            let start = ContinuousClock.now
            let export = Task { try await table.export(to: url, as: format) }
            var longest = Duration.zero
            while table.isExporting || longest == .zero {
                let tick = ContinuousClock.now
                try await Task.sleep(for: .milliseconds(1))
                longest = max(longest, ContinuousClock.now - tick - .milliseconds(1))
            }
            try await export.value
            let elapsed = ContinuousClock.now - start
            let peak = sampler.stop()
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
            let cells = Self.rows * table.columns.count
            let extra = Double(peak > before ? peak - before : 0)
            print("BENCH export \(format.fileExtension): \(Self.rows) rows × \(table.columns.count) columns in \(elapsed), "
                  + "\(size / 1_000_000) MB, memory +\(Int(extra / 1_000_000)) MB (\(Int(extra / Double(cells))) bytes a cell), "
                  + "main thread held at most \(longest) at once")
        }
    }
}
#endif
