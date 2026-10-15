//
//  FeedStoreTests.swift
//  NGTable Mac Bench Tests
//
//  The feed client's rows: found by their ids' keys, written in place, the last row taking a
//  removed one's place; the table shows the same rows as the store.
//

import AppKit
import Foundation
import NGTable
import Testing
@testable import NGTable_Mac_Bench

@MainActor
struct FeedStoreTests {
    @Test func rowsFollowTheirKeysThroughUpdatesInsertsAndDeletes() throws {
        let decoder = FeedDecoder()
        let hello = #"{"type":"hello","schema":[{"name":"id","type":"string"},{"name":"bid","type":"f64"},{"name":"note","type":"string","nullable":true}],"params":{}}"#
        guard case .hello(let schema, _) = try decoder.decode(Data(hello.utf8)) else { Issue.record("no hello"); return }
        let store = FeedStore()
        store.reset(schema: schema)
        let table = NGTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        table.columns = store.tableColumns()
        table.dataSource = store
        let rows = (0..<50).map { #"{"id":"R\#($0)","bid":\#($0),"note":"n\#($0)"}"# }.joined(separator: ",")
        guard case .snapshot(let snapshot) = try decoder.decode(Data(#"{"type":"snapshot","seq":1,"part":1,"parts":1,"rows":[\#(rows)]}"#.utf8)) else {
            Issue.record("no snapshot")
            return
        }
        store.load(snapshot)
        table.reloadData()
        // The reference: id → (bid, note), in the store's row order.
        var reference = (0..<50).map { (id: "R\($0)", bid: Double($0), note: Optional("n\($0)")) }
        func apply(_ json: String) throws {
            table.beginUpdates()
            switch try decoder.decode(Data(json.utf8)) {
            case .update(_, _, let rows, _)?: store.update(rows)
            case .insert(_, _, let rows, _)?: store.insert(rows, table: table)
            case .delete(_, _, let keys, _)?: store.delete(keys, table: table)
            default: Issue.record("not a change: \(json)")
            }
            store.flushUpdates(table: table)
            table.endUpdates()
        }
        func expectSame(_ context: String) {
            #expect(table.numberOfRows == reference.count, "\(context)")
            let bid = table.tableColumns.first { $0.id == "bid" }!, note = table.tableColumns.first { $0.id == "note" }!
            for (row, record) in reference.enumerated() {
                #expect(table.dataSource?.tableView(table, identifierForRow: row) == AnyHashable(record.id), "\(context): row \(row)")
                #expect(store.tableView(table, valueFor: bid, row: row) == .number(record.bid), "\(context): bid of \(record.id)")
                #expect(store.tableView(table, valueFor: note, row: row) == (record.note.map { .text($0) } ?? .empty), "\(context): note of \(record.id)")
            }
        }
        try apply(#"{"type":"update","seq":2,"gen_ts":1,"rows":[{"id":"R3","bid":30.5},{"id":"R7","note":null}]}"#)
        reference[3].bid = 30.5
        reference[7].note = nil
        expectSame("update")
        try apply(#"{"type":"insert","seq":3,"gen_ts":1,"rows":[{"id":"N1","bid":-1,"note":"new"}]}"#)
        reference.append((id: "N1", bid: -1, note: "new"))
        expectSame("insert")
        // The last row (N1) takes R3's place, then R49 (last again) takes R10's.
        try apply(#"{"type":"delete","seq":4,"gen_ts":1,"ids":["R3","R10"]}"#)
        reference[3] = reference.removeLast()
        reference[10] = reference.removeLast()
        expectSame("delete")
        // The moved rows are found by their keys still.
        try apply(#"{"type":"update","seq":5,"gen_ts":1,"rows":[{"id":"N1","bid":7},{"id":"R49","bid":49.5},{"id":"R3","bid":1}]}"#)
        reference[3].bid = 7
        reference[10].bid = 49.5
        expectSame("update after moves (R3 is gone)")
    }
}
