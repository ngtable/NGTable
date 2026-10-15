//
//  FeedJSON.swift
//  NGTable Mac Bench
//
//  a JSON reader over the bytes of a frame, for the frames that carry rows. It reads
//  strings and numbers straight into the feed's values, without the objects of JSONSerialization
//  and the casts from them (those decoded `firehose`, 25 MB a second, with a whole core). Numbers
//  that aren't small integers go through `strtod`, so every Double is the one the server sent.
//

import Foundation

nonisolated struct FeedJSONReader {
    struct Malformed: Error {
        let position: Int
    }

    private let bytes: UnsafeBufferPointer<UInt8>
    private(set) var position = 0

    init(_ bytes: UnsafeBufferPointer<UInt8>) {
        self.bytes = bytes
    }

    private static let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\")

    /// The next byte that isn't white space, not taken; 0 at the end.
    mutating func peek() -> UInt8 {
        while position < bytes.count {
            switch bytes[position] {
            case 0x20, 0x09, 0x0A, 0x0D: position += 1
            default: return bytes[position]
            }
        }
        return 0
    }

    mutating func expect(_ byte: UInt8) throws {
        guard peek() == byte else { throw Malformed(position: position) }
        position += 1
    }

    /// The members of an object, by key: `body` reads or skips each value.
    mutating func readObject(_ body: (inout FeedJSONReader, String) throws -> Void) throws {
        try expect(UInt8(ascii: "{"))
        if peek() == UInt8(ascii: "}") { position += 1; return }
        while true {
            let key = try readString()
            try expect(UInt8(ascii: ":"))
            try body(&self, key)
            switch peek() {
            case UInt8(ascii: ","): position += 1
            case UInt8(ascii: "}"): position += 1; return
            default: throw Malformed(position: position)
            }
        }
    }

    /// The elements of an array: `body` reads or skips each one.
    mutating func readArray(_ body: (inout FeedJSONReader) throws -> Void) throws {
        try expect(UInt8(ascii: "["))
        if peek() == UInt8(ascii: "]") { position += 1; return }
        while true {
            try body(&self)
            switch peek() {
            case UInt8(ascii: ","): position += 1
            case UInt8(ascii: "]"): position += 1; return
            default: throw Malformed(position: position)
            }
        }
    }

    mutating func readString() throws -> String {
        try expect(Self.quote)
        let start = position
        // Most strings have no escapes: taken as they are.
        while position < bytes.count {
            let byte = bytes[position]
            if byte == Self.quote {
                position += 1
                return String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<position - 1]), as: UTF8.self)
            }
            if byte == Self.backslash { break }
            position += 1
        }
        var utf8 = Array(bytes[start..<position])
        while position < bytes.count {
            let byte = bytes[position]
            position += 1
            if byte == Self.quote { return String(decoding: utf8, as: UTF8.self) }
            guard byte == Self.backslash else { utf8.append(byte); continue }
            guard position < bytes.count else { break }
            let escaped = bytes[position]
            position += 1
            switch escaped {
            case UInt8(ascii: "b"): utf8.append(0x08)
            case UInt8(ascii: "f"): utf8.append(0x0C)
            case UInt8(ascii: "n"): utf8.append(0x0A)
            case UInt8(ascii: "r"): utf8.append(0x0D)
            case UInt8(ascii: "t"): utf8.append(0x09)
            case UInt8(ascii: "u"):
                var scalar = try readHex4()
                // A surrogate pair is one character.
                if (0xD800..<0xDC00).contains(scalar), position + 1 < bytes.count,
                   bytes[position] == Self.backslash, bytes[position + 1] == UInt8(ascii: "u") {
                    position += 2
                    let low = try readHex4()
                    scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                }
                utf8.append(contentsOf: String(Unicode.Scalar(scalar) ?? "\u{FFFD}").utf8)
            default: utf8.append(escaped)   // \" \\ \/
            }
        }
        throw Malformed(position: position)
    }

    private mutating func readHex4() throws -> UInt32 {
        guard position + 4 <= bytes.count else { throw Malformed(position: position) }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let byte = bytes[position]
            position += 1
            let digit: UInt8 = switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
            default: throw Malformed(position: position)
            }
            value = value << 4 | UInt32(digit)
        }
        return value
    }

    mutating func readNumber() throws -> Double {
        _ = peek()
        let start = position
        var isInteger = true
        while position < bytes.count {
            switch bytes[position] {
            case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"): break
            case UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E"), UInt8(ascii: "+"): isInteger = false
            default: return try number(start..<position, isInteger: isInteger)
            }
            position += 1
        }
        return try number(start..<position, isInteger: isInteger)
    }

    /// A number written as a string (`"62000.01000000"`, as Binance sends prices), or a number.
    mutating func readQuotedNumber() throws -> Double {
        guard peek() == Self.quote else { return try readNumber() }
        position += 1
        let start = position
        var isInteger = true
        while position < bytes.count, bytes[position] != Self.quote {
            switch bytes[position] {
            case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"): break
            case UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E"), UInt8(ascii: "+"): isInteger = false
            default: throw Malformed(position: position)
            }
            position += 1
        }
        guard position < bytes.count else { throw Malformed(position: position) }
        position += 1
        return try number(start..<(position - 1), isInteger: isInteger)
    }

    /// `true` or `false`.
    mutating func readBool() throws -> Bool {
        switch peek() {
        case UInt8(ascii: "t"): try skipWord(4); return true
        case UInt8(ascii: "f"): try skipWord(5); return false
        default: throw Malformed(position: position)
        }
    }

    private func number(_ range: Range<Int>, isInteger: Bool) throws -> Double {
        guard !range.isEmpty, range.count < 64 else { throw Malformed(position: range.lowerBound) }
        // Integers of up to 15 digits are exact as they are.
        if isInteger, range.count <= 16 {
            var value = 0
            var negative = false
            for index in range {
                let byte = bytes[index]
                if byte == UInt8(ascii: "-") { negative = true; continue }
                value = value * 10 + Int(byte - UInt8(ascii: "0"))
            }
            return Double(negative ? -value : value)   // An integer -0 is 0 (f64 -0 comes as -0.0).
        }
        if let value = Self.clingerFastPath(bytes, range) { return value }
        return withUnsafeTemporaryAllocation(of: CChar.self, capacity: range.count + 1) { buffer in
            for (offset, index) in range.enumerated() { buffer[offset] = CChar(bitPattern: bytes[index]) }
            buffer[range.count] = 0
            return strtod(buffer.baseAddress!, nil)
        }
    }

    private static let powersOfTen: [Double] = (0...22).map { exponent in
        var value = 1.0
        for _ in 0..<exponent { value *= 10 }   // Exact up to 10^22.
        return value
    }

    /// A decimal of at most 15 significant digits and a power of ten up to 22 either way: one
    /// exact operation on two exact doubles, so rounded as `strtod` rounds (Clinger's fast
    /// path). Most of a feed's numbers, without `strtod`, which reads the locale under a lock.
    private static func clingerFastPath(_ bytes: UnsafeBufferPointer<UInt8>, _ range: Range<Int>) -> Double? {
        var index = range.lowerBound
        var negative = false
        if bytes[index] == UInt8(ascii: "-") {
            negative = true
            index += 1
        }
        var mantissa: UInt64 = 0
        var digits = 0, exponent = 0
        var seenPoint = false, seenDigit = false
        while index < range.upperBound {
            let byte = bytes[index]
            if byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") {
                seenDigit = true
                // Leading zeros aren't significant.
                if mantissa != 0 || byte != UInt8(ascii: "0") { digits += 1 }
                guard digits <= 15 else { return nil }
                mantissa = mantissa * 10 + UInt64(byte - UInt8(ascii: "0"))
                if seenPoint { exponent -= 1 }
            } else if byte == UInt8(ascii: "."), !seenPoint {
                seenPoint = true
            } else if byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E") {
                index += 1
                var sign = 1, value = 0, exponentDigits = 0
                if index < range.upperBound, bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") {
                    if bytes[index] == UInt8(ascii: "-") { sign = -1 }
                    index += 1
                }
                while index < range.upperBound, bytes[index] >= UInt8(ascii: "0"), bytes[index] <= UInt8(ascii: "9") {
                    value = value * 10 + Int(bytes[index] - UInt8(ascii: "0"))
                    exponentDigits += 1
                    guard exponentDigits <= 4 else { return nil }
                    index += 1
                }
                guard exponentDigits > 0, index == range.upperBound else { return nil }
                exponent += sign * value
                break
            } else {
                return nil
            }
            index += 1
        }
        guard seenDigit, exponent >= -22, exponent <= 22 else { return nil }
        var value = Double(mantissa)
        value = exponent < 0 ? value / powersOfTen[-exponent] : value * powersOfTen[exponent]
        return negative ? -value : value
    }

    /// A value of a row: a number, text or null (`true`/`false` as 1/0; arrays and objects,
    /// which rows don't have, as null).
    mutating func readValue() throws -> FeedValue {
        switch peek() {
        case Self.quote: return .text(try readString())
        case UInt8(ascii: "n"): try skipWord(4); return .null
        case UInt8(ascii: "t"): try skipWord(4); return .number(1)
        case UInt8(ascii: "f"): try skipWord(5); return .number(0)
        case UInt8(ascii: "["), UInt8(ascii: "{"): try skipValue(); return .null
        default: return .number(try readNumber())
        }
    }

    mutating func skipValue() throws {
        switch peek() {
        case Self.quote: _ = try readString()
        case UInt8(ascii: "{"): try readObject { reader, _ in try reader.skipValue() }
        case UInt8(ascii: "["): try readArray { reader in try reader.skipValue() }
        case UInt8(ascii: "n"), UInt8(ascii: "t"): try skipWord(4)
        case UInt8(ascii: "f"): try skipWord(5)
        default: _ = try readNumber()
        }
    }

    private mutating func skipWord(_ length: Int) throws {
        guard position + length <= bytes.count else { throw Malformed(position: position) }
        position += length
    }
}
