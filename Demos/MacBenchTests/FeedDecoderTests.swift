//
//  FeedDecoderTests.swift
//  NGTable Mac Bench Tests
//
//  The ngfeed client's decoding: frames with rows are read from the bytes (FeedJSONReader) and
//  must give what JSONSerialization gives, to the bit of every Double.
//

import Foundation
import Testing
@testable import NGTable_Mac_Bench

struct FeedDecoderTests {
    private static let hello = #"""
    {"type":"hello","protocol":1,"schema":[{"name":"id","type":"string"},{"name":"bid","type":"f64"},
    {"name":"trades","type":"i64"},{"name":"updated","type":"time"},{"name":"m1","type":"f64","nullable":true},
    {"name":"note","type":"string","nullable":true}],"params":{"rows":"3"}}
    """#

    private func decoder() throws -> FeedDecoder {
        let decoder = FeedDecoder()
        guard case .hello(let schema, _) = try decoder.decode(Data(Self.hello.utf8)) else {
            Issue.record("no hello")
            return decoder
        }
        #expect(schema.map(\.name) == ["id", "bid", "trades", "updated", "m1", "note"])
        return decoder
    }

    /// Values as bits: NaN, -0 and the last digit count.
    private func bits(_ rows: [FeedRow]) -> [[String]] {
        rows.map { row in
            [row.id] + row.fields.sorted { $0.index < $1.index }.map { field in
                switch field.value {
                case .number(let number): "\(field.index):\(String(number.bitPattern, radix: 16))"
                case .text(let text): "\(field.index):'\(text)'"
                case .null: "\(field.index):null"
                }
            }
        }
    }

    @Test func updatesReadLikeJSONSerialization() throws {
        var generator = SystemRandomNumberGenerator()
        var rows: [String] = []
        for index in 0..<500 {
            let bid = Double.random(in: -1e6...1e6, using: &generator)
            let small = Double.random(in: -1e-6...1e-6, using: &generator)
            let trades = Int.random(in: -1_000_000_000_000...1_000_000_000_000, using: &generator)
            // Numbers as Rust's serde_json writes them: the shortest digits that round-trip.
            rows.append(#"{"id":"R\#(index)","bid":\#(bid),"trades":\#(trades),"updated":1728550000130102,"m1":\#(index % 7 == 0 ? "null" : "\(small)"),"note":\#(index % 3 == 0 ? "null" : #""n\#(index)""#)}"#)
        }
        rows.append(#"{"id":"edge","bid":-0.0,"trades":-0,"m1":1e300,"updated":0,"note":"\"q\" \\ \/ \n\t é 😀 юникод"}"#)
        rows.append(#"{"id":"exp","bid":1.5E-7,"m1":-2.5e+10,"trades":9007199254740993}"#)
        let frame = #"{"type":"update","seq":42,"ts":1,"gen_ts":1728550000130102,"rows":[\#(rows.joined(separator: ","))]}"#
        let data = Data(frame.utf8)
        guard case .update(let seq, let genTs, let fast, let conflated) = try decoder().decode(data),
              case .update(_, _, let slow, _) = try decoder().decodeWithFoundation(data) else {
            Issue.record("not an update")
            return
        }
        #expect(seq == 42 && genTs == 1728550000130102 && conflated == nil)
        #expect(fast.count == 502)
        #expect(fast.count == slow.count)
        if let (read, expected) = zip(bits(fast), bits(slow)).first(where: { $0 != $1 }) {
            Issue.record("read \(read), JSONSerialization \(expected)")
        }
        let edge = try #require(fast.first { $0.id == "edge" })
        let note = edge.fields.first { $0.index == 5 }
        guard case .text(let text) = note?.value else {
            Issue.record("no note")
            return
        }
        #expect(text == "\"q\" \\ / \n\t é 😀 юникод")
        guard case .number(let zero) = edge.fields.first(where: { $0.index == 1 })?.value else { return }
        #expect(zero.sign == .minus && zero == 0)
    }

    /// Decimals of up to 15 digits, any point and exponent (read without `strtod`): the same
    /// bits as JSONSerialization's.
    @Test func shortDecimalsReadExactly() throws {
        var generator = SystemRandomNumberGenerator()
        var rows: [String] = []
        for index in 0..<3_000 {
            let digits = String(UInt64.random(in: 1...999_999_999_999_999, using: &generator))
            let point = Int.random(in: 0...digits.count, using: &generator)
            var literal = point == digits.count ? digits : String(digits.prefix(point).isEmpty ? "0" : digits.prefix(point)) + "." + digits.dropFirst(point)
            if index % 3 == 0 { literal += "e\(Int.random(in: -25...25, using: &generator))" }
            if index % 2 == 0 { literal = "-" + literal }
            rows.append(#"{"id":"R\#(index)","bid":\#(literal)}"#)
        }
        let data = Data(#"{"type":"update","seq":1,"gen_ts":1,"rows":[\#(rows.joined(separator: ","))]}"#.utf8)
        guard case .update(_, _, let fast, _) = try decoder().decode(data),
              case .update(_, _, let slow, _) = try decoder().decodeWithFoundation(data) else {
            Issue.record("not an update")
            return
        }
        #expect(fast.count == 3_000)
        if let (read, expected) = zip(bits(fast), bits(slow)).first(where: { $0 != $1 }) {
            Issue.record("read \(read), JSONSerialization \(expected)")
        }
    }

    /// A snapshot in parts comes as one, by column; inserts, deletes, a checksum and a
    /// conflated update read too, with the keys in any order.
    @Test func snapshotsAndOtherFrames() throws {
        let decoder = try decoder()
        let first = #"{"type":"snapshot","seq":7,"part":1,"parts":2,"rows":[{"id":"A","bid":1.5,"trades":2,"updated":3,"m1":null,"note":"x"}]}"#
        let second = #"{"rows":[{"id":"B","bid":2.5,"trades":4,"updated":5}],"parts":2,"part":2,"seq":7,"type":"snapshot"}"#
        #expect(try decoder.decode(Data(first.utf8)) == nil)
        guard case .snapshot(let snapshot) = try decoder.decode(Data(second.utf8)) else {
            Issue.record("no snapshot")
            return
        }
        #expect(snapshot.seq == 7 && snapshot.ids == ["A", "B"])
        guard case .numbers(let bids) = snapshot.columns[1], case .numbers(let m1) = snapshot.columns[4],
              case .texts(let notes) = snapshot.columns[5] else {
            Issue.record("columns of the wrong kind")
            return
        }
        #expect(bids == [1.5, 2.5] && m1[0].isNaN && m1[1].isNaN && notes == ["x", nil])

        let insert = #"{"type":"insert","seq":8,"gen_ts":9,"rows":[{"id":"C","bid":3}]}"#
        guard case .insert(8, 9, let rows, nil) = try decoder.decode(Data(insert.utf8)) else {
            Issue.record("no insert")
            return
        }
        // Keys: the snapshot's rows are 0 and 1, the new id the next.
        #expect(rows.map(\.id) == ["C"] && rows.map(\.key) == [2])
        guard case .delete(9, _, let keys, nil) = try decoder.decode(Data(#"{"type":"delete","seq":9,"gen_ts":1,"ids":["B","A","C"]}"#.utf8)) else {
            Issue.record("no delete")
            return
        }
        #expect(keys == [1, 0, 2])
        guard case .checksum(10, 2, "605841cc0c50362a") = try decoder.decode(Data(#"{"type":"checksum","seq":10,"rows":2,"hash":"605841cc0c50362a"}"#.utf8)) else {
            Issue.record("no checksum")
            return
        }
        guard case .update(12, _, _, 3) = try decoder.decode(Data(#"{"type":"update","conflated":3,"seq":12,"gen_ts":1,"rows":[]}"#.utf8)) else {
            Issue.record("no conflated update")
            return
        }
        guard case .end("shutdown") = try decoder.decode(Data(#"{"type":"end","reason":"shutdown"}"#.utf8)) else {
            Issue.record("no end")
            return
        }
        #expect(throws: FeedDecodingError.self) { try decoder.decode(Data(#"{"type":"update","seq":1,"rows":[{"id":"A","bid":}]}"#.utf8)) }
        #expect(throws: FeedDecodingError.self) { try decoder.decode(Data(#"{"type":"update","seq":1,"rows":[{"id":"A","nope":1}]}"#.utf8)) }
    }
}
