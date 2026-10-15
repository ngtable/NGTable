//
//  FeedMessages.swift
//  NGTable Mac Bench
//
//  the messages of an ngfeed server (../ngfeed, a live market-like feed over WebSocket)
//  and their decoding off the main thread. A snapshot comes in parts and is put together here, by
//  column, so the main thread only swaps it in. See ngfeed's README for the protocol. Frames
//  with rows are read by FeedJSONReader; the rare others (`hello`, `error`…) by JSONSerialization.
//

import Foundation

/// A field of the feed's rows, from `hello`'s schema.
nonisolated struct FeedField: Sendable, Hashable {
    enum Kind: Sendable, Hashable {
        case string, f64, i64, time
    }

    let name: String
    let kind: Kind
    let nullable: Bool

    var isNumber: Bool { kind != .string }
}

/// A value as the feed sends it (numbers of every kind as `Double`).
nonisolated enum FeedValue: Sendable {
    case number(Double)
    case text(String)
    case null
}

/// One row as sent: its id, the decoder's number for the id (`FeedDecoder.key(of:)`: found
/// without hashing the string on the main thread) and the given fields by schema index.
nonisolated struct FeedRow: Sendable {
    let id: String
    var key: Int32 = -1
    let fields: [(index: Int, value: FeedValue)]
}

/// The values of a column of every row: numbers (NaN for null) or text.
nonisolated enum FeedColumn: Sendable {
    case numbers([Double])
    case texts([String?])
}

/// A whole snapshot, by column.
nonisolated struct FeedSnapshot: Sendable {
    let seq: Int
    let ids: [String]
    let columns: [FeedColumn]
    /// The key of each row's id (`FeedRow.key`): a snapshot numbers its ids anew, in order, so
    /// row `i` has key `i`.
    var keyCount: Int { ids.count }
}

nonisolated enum FeedMessage: Sendable {
    case hello(schema: [FeedField], params: [String: String])
    case snapshot(FeedSnapshot)
    case update(seq: Int, genTs: Int64, rows: [FeedRow], conflated: Int?)
    case insert(seq: Int, genTs: Int64, rows: [FeedRow], conflated: Int?)
    case delete(seq: Int, genTs: Int64, keys: [Int32], conflated: Int?)
    case checksum(seq: Int, rows: Int, hash: String)
    case heartbeat(seq: Int)
    case end(reason: String)
    case error(code: String, message: String)
    case pong(clientTs: Int64, ts: Int64)
    /// The connection closed or failed.
    case closed(String)

    /// When the server generated a change (µs since 1970), for its latency.
    var genTs: Int64? {
        switch self {
        case .update(_, let genTs, _, _), .insert(_, let genTs, _, _), .delete(_, let genTs, _, _): genTs
        default: nil
        }
    }
}

nonisolated enum FeedDecodingError: Error {
    case notAnObject
    case unknownField(String)
    case malformed(position: Int)
}

/// Decodes the frames of one connection, in order: knows the schema from `hello` and puts the
/// parts of a snapshot together. Used on one thread at a time.
nonisolated final class FeedDecoder {
    private(set) var schema: [FeedField] = []
    private var fieldIndex: [String: Int] = [:]
    /// The parts of a snapshot so far: ids, and the columns of numbers and of text, with the
    /// slot of each schema field among them.
    private var snapshotIDs: [String] = []
    private var numberColumns: [[Double]] = []
    private var textColumns: [[String?]] = []
    private var slots: [(isNumber: Bool, slot: Int)] = []
    private var expectedRows = 0
    /// Each id's number, from the last snapshot on (numbered anew by each).
    private var keyOfID: [String: Int32] = [:]

    /// An id's number: the one it has, or the next.
    private func key(of id: String) -> Int32 {
        if let key = keyOfID[id] { return key }
        let key = Int32(keyOfID.count)
        keyOfID[id] = key
        return key
    }

    /// The message of a frame, or `nil` for a snapshot part before the last.
    func decode(_ data: Data) throws -> FeedMessage? {
        let fast: FastResult
        do {
            fast = try data.withUnsafeBytes { raw in
                try decodeRows(FeedJSONReader(raw.bindMemory(to: UInt8.self)))
            }
        } catch let malformed as FeedJSONReader.Malformed {
            throw FeedDecodingError.malformed(position: malformed.position)
        }
        switch fast {
        case .decoded(let message): return message
        case .notHandled: return try decodeWithFoundation(data)
        }
    }

    private enum FastResult {
        case decoded(FeedMessage?)
        case notHandled
    }

    /// The frames with rows and the frequent small ones, read straight from the bytes.
    private func decodeRows(_ reader: FeedJSONReader) throws -> FastResult {
        var reader = reader
        var type = "", hash = ""
        var seq = 0, part = 0, parts = 0, rowCount = 0
        var genTs: Int64 = 0
        var conflated: Int?
        var rows: [FeedRow] = []
        var ids: [String] = []
        var handled = true
        try reader.readObject { reader, key in
            switch key {
            case "type":
                type = try reader.readString()
                switch type {
                case "update", "insert", "delete", "snapshot", "checksum", "heartbeat": break
                default: handled = false
                }
            case "seq": seq = Int(try reader.readNumber())
            case "gen_ts": genTs = Int64(try reader.readNumber())
            case "conflated": conflated = Int(try reader.readNumber())
            case "part": part = Int(try reader.readNumber())
            case "parts": parts = Int(try reader.readNumber())
            case "hash": hash = try reader.readString()
            case "ids": try reader.readArray { reader in ids.append(try reader.readString()) }
            case "rows" where reader.peek() == UInt8(ascii: "["):
                guard handled, !fieldIndex.isEmpty else { try reader.skipValue(); return }
                try reader.readArray { reader in rows.append(try readRow(&reader)) }
            case "rows": rowCount = Int(try reader.readNumber())   // Of a checksum.
            default: try reader.skipValue()
            }
        }
        guard handled else { return .notHandled }
        switch type {
        case "update": return .decoded(.update(seq: seq, genTs: genTs, rows: keyed(rows), conflated: conflated))
        case "insert": return .decoded(.insert(seq: seq, genTs: genTs, rows: keyed(rows), conflated: conflated))
        case "delete": return .decoded(.delete(seq: seq, genTs: genTs, keys: ids.map { key(of: $0) }, conflated: conflated))
        case "checksum": return .decoded(.checksum(seq: seq, rows: rowCount, hash: hash))
        case "heartbeat": return .decoded(.heartbeat(seq: seq))
        default:
            if part <= 1 { startSnapshot() }
            for row in rows { appendToSnapshot(row) }
            return .decoded(part >= parts ? finishSnapshot(seq: seq) : nil)
        }
    }

    private func readRow(_ reader: inout FeedJSONReader) throws -> FeedRow {
        var id = ""
        var fields: [(index: Int, value: FeedValue)] = []
        fields.reserveCapacity(schema.count)
        try reader.readObject { reader, name in
            if name == "id" {
                id = try reader.readString()
                return
            }
            guard let index = fieldIndex[name] else { throw FeedDecodingError.unknownField(name) }
            fields.append((index, try reader.readValue()))
        }
        return FeedRow(id: id, fields: fields)
    }

    /// Rows of an update or insert with their ids' keys (after the frame is read: its type may
    /// come after its rows).
    private func keyed(_ rows: [FeedRow]) -> [FeedRow] {
        rows.map { row in
            var row = row
            row.key = key(of: row.id)
            return row
        }
    }

    /// Any frame, by JSONSerialization.
    func decodeWithFoundation(_ data: Data) throws -> FeedMessage? {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { throw FeedDecodingError.notAnObject }
        func int(_ key: String) -> Int { (object[key] as? NSNumber)?.intValue ?? 0 }
        func int64(_ key: String) -> Int64 { (object[key] as? NSNumber)?.int64Value ?? 0 }
        let conflated = (object["conflated"] as? NSNumber)?.intValue
        switch type {
        case "hello":
            let fields = (object["schema"] as? [[String: Any]] ?? []).compactMap { field -> FeedField? in
                guard let name = field["name"] as? String else { return nil }
                let kind: FeedField.Kind = switch field["type"] as? String {
                case "f64": .f64
                case "i64": .i64
                case "time": .time
                default: .string
                }
                return FeedField(name: name, kind: kind, nullable: field["nullable"] as? Bool ?? false)
            }
            schema = fields
            fieldIndex = Dictionary(uniqueKeysWithValues: fields.enumerated().map { ($1.name, $0) })
            var params: [String: String] = [:]
            for (key, value) in object["params"] as? [String: Any] ?? [:] { params[key] = "\(value)" }
            expectedRows = Int(params["rows"] ?? "") ?? 0
            return .hello(schema: fields, params: params)
        case "snapshot":
            if int("part") <= 1 { startSnapshot() }
            for row in try rows(object["rows"]) { appendToSnapshot(row) }
            return int("part") >= int("parts") ? finishSnapshot(seq: int("seq")) : nil
        case "update":
            return .update(seq: int("seq"), genTs: int64("gen_ts"), rows: keyed(try rows(object["rows"])), conflated: conflated)
        case "insert":
            return .insert(seq: int("seq"), genTs: int64("gen_ts"), rows: keyed(try rows(object["rows"])), conflated: conflated)
        case "delete":
            return .delete(seq: int("seq"), genTs: int64("gen_ts"), keys: (object["ids"] as? [String] ?? []).map { key(of: $0) }, conflated: conflated)
        case "checksum":
            return .checksum(seq: int("seq"), rows: int("rows"), hash: object["hash"] as? String ?? "")
        case "heartbeat":
            return .heartbeat(seq: int("seq"))
        case "end":
            return .end(reason: object["reason"] as? String ?? "")
        case "error":
            return .error(code: object["code"] as? String ?? "", message: object["message"] as? String ?? "")
        case "pong":
            return .pong(clientTs: int64("client_ts"), ts: int64("ts"))
        default:
            return nil
        }
    }

    private func value(_ raw: Any?) -> FeedValue {
        switch raw {
        case let number as NSNumber: .number(number.doubleValue)
        case let text as String: .text(text)
        default: .null
        }
    }

    private func rows(_ raw: Any?) throws -> [FeedRow] {
        guard let rows = raw as? [[String: Any]] else { return [] }
        return try rows.map { row in
            var fields: [(index: Int, value: FeedValue)] = []
            fields.reserveCapacity(row.count)
            for (name, raw) in row where name != "id" {
                guard let index = fieldIndex[name] else { throw FeedDecodingError.unknownField(name) }
                fields.append((index, value(raw)))
            }
            return FeedRow(id: row["id"] as? String ?? "", fields: fields)
        }
    }

    private func startSnapshot() {
        // Its ids are numbered anew, in order: the rows read before it are gone.
        keyOfID = [:]
        keyOfID.reserveCapacity(expectedRows)
        snapshotIDs = []
        snapshotIDs.reserveCapacity(expectedRows)
        numberColumns = []
        textColumns = []
        slots = schema.map { field in
            if field.isNumber {
                numberColumns.append([])
                numberColumns[numberColumns.count - 1].reserveCapacity(expectedRows)
                return (true, numberColumns.count - 1)
            }
            textColumns.append([])
            textColumns[textColumns.count - 1].reserveCapacity(expectedRows)
            return (false, textColumns.count - 1)
        }
    }

    /// A row of a snapshot, onto the end of every column (null where it has no value).
    private func appendToSnapshot(_ row: FeedRow) {
        // Row i of a snapshot is key i.
        keyOfID[row.id] = Int32(snapshotIDs.count)
        snapshotIDs.append(row.id)
        for (isNumber, slot) in slots {
            if isNumber { numberColumns[slot].append(.nan) } else { textColumns[slot].append(nil) }
        }
        for (index, value) in row.fields {
            let (isNumber, slot) = slots[index]
            let last = snapshotIDs.count - 1
            if isNumber {
                if case .number(let number) = value { numberColumns[slot][last] = number }
            } else if case .text(let text) = value {
                textColumns[slot][last] = text
            }
        }
    }

    private func finishSnapshot(seq: Int) -> FeedMessage {
        let columns: [FeedColumn] = slots.map { $0.isNumber ? .numbers(numberColumns[$0.slot]) : .texts(textColumns[$0.slot]) }
        let snapshot = FeedSnapshot(seq: seq, ids: snapshotIDs, columns: columns)
        (snapshotIDs, numberColumns, textColumns) = ([], [], [])
        return .snapshot(snapshot)
    }
}
