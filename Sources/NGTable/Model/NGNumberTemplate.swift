import Foundation
import os

// Numbers as FormatStyle writes them, without FormatStyle for each one: it
// took ~0.7 µs a number and scaled poorly on all cores (CSV export and copy
// of a million rows spent most of their time there). A template of a format
// and locale is learned once from FormatStyle's own output: the digits
// (Latin or the locale's), the grouping separator and group sizes (Indian
// 3;2, no grouping of four-digit numbers in Spanish), the decimal separator,
// the fraction digits, and what goes before and after the digits of positive
// and negative numbers (signs, currency symbols, percent signs, bidi marks).
// A number is then written from its shortest decimal digits (Swift's
// `description`), rounded half to even, as ICU does (2.675 → 2.68,
// 0.125 → 0.12). A template is used only if it gives FormatStyle's text for
// a set of check values; otherwise (or for NaN and infinity) FormatStyle
// writes the number. Templates are kept by format and locale for all
// threads, behind a lock.

/// How a format writes numbers in a locale, learned from FormatStyle. Its
/// texts are in one buffer read in place, and a number's digits are worked
/// on the stack: writers on every core share a template without touching
/// reference counts (shared arrays retained per number made ten cores
/// slower than one).
struct NGNumberTemplate: Sendable {
    /// The UTF-8 of the digits 0 to 9 (`digitLength` bytes each), the
    /// separators, prefixes and suffixes, at the ranges below.
    private let storage: [UInt8]
    private let digitLength: Int
    private let groupSeparator: Range<Int>
    private let decimalSeparator: Range<Int>
    private let positivePrefix: Range<Int>, positiveSuffix: Range<Int>
    private let negativePrefix: Range<Int>, negativeSuffix: Range<Int>
    /// Digits of the group nearest the separator, and of the groups beyond.
    private let primaryGroup: Int
    private let secondaryGroup: Int
    /// Integer digits a number has at least for its digits to be grouped
    /// (`.max`: never grouped).
    private let groupingFrom: Int
    /// Fraction digits: exactly `maximumFraction`, or up to it with
    /// trailing zeros left out.
    private let minimumFraction: Int
    private let maximumFraction: Int
    /// Powers of ten the value is multiplied by (2 for percent).
    private let scale: Int

    /// The text of a finite number, or `nil` for NaN and infinity.
    func string(for number: Double) -> String? {
        guard number.isFinite else { return nil }
        var text = number.magnitude.description
        return text.withUTF8 { shortest in
            // Room for the digits and a carry before them.
            withUnsafeTemporaryAllocation(of: UInt8.self, capacity: shortest.count + 2) { buffer in
                var digits = Digits(buffer: buffer, shortest: shortest)
                if !digits.isZero { digits.point += scale }
                digits.round(toFractionDigits: maximumFraction)
                return write(digits, isNegative: number.sign == .minus && !digits.isZero)
            }
        }
    }

    private func write(_ digits: Digits, isNegative: Bool) -> String {
        var fraction = maximumFraction
        // Trailing zeros left out (down to the minimum).
        while fraction > minimumFraction, digits.digit(at: digits.point + fraction - 1) == 0 { fraction -= 1 }
        let integerDigits = max(1, digits.point)
        let grouped = !groupSeparator.isEmpty && integerDigits >= groupingFrom
        let separators = grouped && integerDigits > primaryGroup ? 1 + (integerDigits - primaryGroup - 1) / secondaryGroup : 0
        let prefix = isNegative ? negativePrefix : positivePrefix
        let suffix = isNegative ? negativeSuffix : positiveSuffix
        let length = prefix.count + integerDigits * digitLength + separators * groupSeparator.count
            + (fraction > 0 ? decimalSeparator.count + fraction * digitLength : 0) + suffix.count
        return storage.withUnsafeBufferPointer { storage in
            String(unsafeUninitializedCapacity: length) { output in
                var at = 0
                func put(_ range: Range<Int>) {
                    for index in range {
                        output[at] = storage[index]
                        at += 1
                    }
                }
                func putDigit(_ digit: Int) {
                    let start = digit * digitLength
                    for index in start..<(start + digitLength) {
                        output[at] = storage[index]
                        at += 1
                    }
                }
                put(prefix)
                for position in stride(from: integerDigits, to: 0, by: -1) {
                    // Its place from the point: 1 for the ones.
                    putDigit(digits.digit(at: digits.point - position))
                    let left = position - 1
                    if grouped, left > 0, left == primaryGroup || (left > primaryGroup && (left - primaryGroup) % secondaryGroup == 0) {
                        put(groupSeparator)
                    }
                }
                if fraction > 0 {
                    put(decimalSeparator)
                    for index in 0..<fraction { putDigit(digits.digit(at: digits.point + index)) }
                }
                put(suffix)
                return at
            }
        }
    }

    /// A number's decimal digits, in a buffer on the stack: the shortest
    /// that read back as it (Swift's `description`, what ICU starts from
    /// too), the point after `point` of them (negative: zeros before them).
    struct Digits {
        private let buffer: UnsafeMutableBufferPointer<UInt8>
        /// The digits are `buffer[start..<end]`.
        private var start = 1
        private var end = 1
        var point = 0

        init(buffer: UnsafeMutableBufferPointer<UInt8>, shortest: UnsafeBufferPointer<UInt8>) {
            self.buffer = buffer
            var exponent = 0
            var sawPoint = false
            var index = 0
            while index < shortest.count {
                let byte = shortest[index]
                if byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") {
                    buffer[end] = byte - UInt8(ascii: "0")
                    end += 1
                    if !sawPoint { point += 1 }
                } else if byte == UInt8(ascii: ".") {
                    sawPoint = true
                } else if byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E") {
                    var sign = 1
                    index += 1
                    if index < shortest.count, shortest[index] == UInt8(ascii: "-") { sign = -1; index += 1 }
                    else if index < shortest.count, shortest[index] == UInt8(ascii: "+") { index += 1 }
                    var value = 0
                    while index < shortest.count { value = value * 10 + Int(shortest[index] - UInt8(ascii: "0")); index += 1 }
                    exponent = sign * value
                }
                index += 1
            }
            point += exponent
            // Leading zeros ("0.001") moved into the point, trailing ones dropped.
            while end - start > 1, buffer[start] == 0 {
                start += 1
                point -= 1
            }
            while end - start > 1, buffer[end - 1] == 0 { end -= 1 }
            if isZero { setZero() }
        }

        var isZero: Bool { end - start == 1 && buffer[start] == 0 }

        private mutating func setZero() {
            start = 1
            end = 2
            buffer[1] = 0
            point = 1
        }

        /// The digit at a place counted from the most significant (0), zero
        /// outside the digits.
        func digit(at index: Int) -> Int {
            index >= 0 && index < end - start ? Int(buffer[start + index]) : 0
        }

        /// Rounded half to even to `fraction` digits after the point.
        mutating func round(toFractionDigits fraction: Int) {
            let kept = point + fraction
            let count = end - start
            guard kept < count else { return }
            if kept < 0 { return setZero() }
            let next = buffer[start + kept]
            var beyond = false
            for index in (start + kept + 1)..<end where buffer[index] != 0 { beyond = true }
            let previousIsOdd = kept > 0 && buffer[start + kept - 1] % 2 == 1
            let up = next > 5 || (next == 5 && (beyond || previousIsOdd))
            end = start + kept
            if up {
                var index = end - 1
                while index >= start, buffer[index] == 9 {
                    buffer[index] = 0
                    index -= 1
                }
                if index >= start {
                    buffer[index] += 1
                } else {
                    // Carried past the first digit (there is room before it).
                    start -= 1
                    buffer[start] = 1
                    point += 1
                }
            }
            if end == start { setZero() }
        }
    }

    // MARK: Learning

    /// Learns the template of a style by writing numbers with it (with
    /// `fixedFraction`, as many fraction digits as it shows; otherwise up to
    /// six, trailing zeros left out, as FormatStyle's default); `nil` when
    /// its output isn't made of what a template has, or isn't reproduced
    /// for the check values.
    init?(fixedFraction: Bool, scale: Int, locale: Locale, format: (Double) -> String) {
        // The locale's digits, one scalar each.
        let plain = FloatingPointFormatStyle<Double>(locale: locale).precision(.fractionLength(0)).grouping(.never)
        var digits: [[UInt8]] = []
        var digitScalars: [Unicode.Scalar] = []
        for digit in 0...9 {
            let scalars = plain.format(Double(digit)).unicodeScalars
            guard scalars.count == 1, let scalar = scalars.first else { return nil }
            digitScalars.append(scalar)
            digits.append(Array(String(scalar).utf8))
        }
        func digitValue(_ scalar: Unicode.Scalar) -> Int? { digitScalars.firstIndex(of: scalar) }
        let power = pow(10, Double(scale))

        // Seven integer digits show the grouping; ".25" the decimal
        // separator and the fraction digits (".2", ".25", ".250").
        let probe = 1_234_567.25
        let positiveText = Array(format(probe / power).unicodeScalars)
        // The grouping separator: the first run between digits among the
        // seven integer ones ("1,234,567", "12,34,567").
        var groupSeparator: [Unicode.Scalar] = []
        do {
            var seen = 0
            var run: [Unicode.Scalar] = []
            for scalar in positiveText {
                if digitValue(scalar) != nil {
                    if seen > 0, !run.isEmpty {
                        if seen < 7 { groupSeparator = run }
                        break
                    }
                    seen += 1
                } else if seen > 0 {
                    run.append(scalar)
                }
            }
        }

        /// A written number in parts: before its digits, the integer digits
        /// (and the places of the group separators: integer digits before
        /// each), the decimal separator, the fraction digits, and after them.
        struct Parts: Equatable {
            var prefix: [Unicode.Scalar] = []
            var integer: [Int] = []
            var separatorPlaces: [Int] = []
            var decimal: [Unicode.Scalar] = []
            var fraction: [Int] = []
            var suffix: [Unicode.Scalar] = []
        }
        func parts(_ scalars: [Unicode.Scalar]) -> Parts? {
            guard let first = scalars.firstIndex(where: { digitValue($0) != nil }),
                  let last = scalars.lastIndex(where: { digitValue($0) != nil }) else { return nil }
            var result = Parts()
            result.prefix = Array(scalars[..<first])
            result.suffix = Array(scalars[(last + 1)...])
            var run: [Unicode.Scalar] = []
            var inFraction = false
            for scalar in scalars[first...last] {
                guard let value = digitValue(scalar) else {
                    run.append(scalar)
                    continue
                }
                if !run.isEmpty {
                    if inFraction { return nil }
                    if run == groupSeparator {
                        result.separatorPlaces.append(result.integer.count)
                    } else {
                        result.decimal = run
                        inFraction = true
                    }
                    run = []
                }
                if inFraction { result.fraction.append(value) } else { result.integer.append(value) }
            }
            return result
        }
        guard let positive = parts(positiveText), positive.integer == [1, 2, 3, 4, 5, 6, 7],
              var negative = parts(Array(format(-probe / power).unicodeScalars)) else { return nil }
        // The same number but its sign.
        negative.prefix = positive.prefix
        negative.suffix = positive.suffix
        guard negative == positive, let negativeParts = parts(Array(format(-probe / power).unicodeScalars)) else { return nil }

        // Group sizes from the separators' places.
        var primary = 3, secondary = 3
        var groupingFrom = Int.max
        if let lastPlace = positive.separatorPlaces.last {
            primary = 7 - lastPlace
            let places = positive.separatorPlaces
            secondary = places.count > 1 ? lastPlace - places[places.count - 2] : primary
            guard primary > 0, secondary > 0 else { return nil }
            // The fewest integer digits that are grouped (four-digit
            // numbers aren't in some locales).
            for count in (primary + 1)...7 {
                let value = Double(Int("1" + String(repeating: "2", count: count - 1))!)
                if let written = parts(Array(format(value / power).unicodeScalars)), !written.separatorPlaces.isEmpty {
                    groupingFrom = count
                    break
                }
            }
            guard groupingFrom != .max else { return nil }
        } else {
            groupSeparator = []
        }
        let maximumFraction = fixedFraction ? positive.fraction.count : 6
        guard positive.fraction.isEmpty || positive.fraction.first == 2 else { return nil }

        // Every text in one buffer: the digits (all of one length), then the rest.
        guard Set(digits.map(\.count)).count == 1 else { return nil }
        var storage = digits.flatMap { $0 }
        func stored(_ scalars: [Unicode.Scalar]) -> Range<Int> {
            var string = ""
            string.unicodeScalars.append(contentsOf: scalars)
            let start = storage.count
            storage += Array(string.utf8)
            return start..<storage.count
        }
        digitLength = digits[0].count
        self.groupSeparator = stored(groupSeparator)
        decimalSeparator = stored(positive.decimal)
        positivePrefix = stored(positive.prefix)
        positiveSuffix = stored(positive.suffix)
        negativePrefix = stored(negativeParts.prefix)
        negativeSuffix = stored(negativeParts.suffix)
        self.storage = storage
        primaryGroup = primary
        secondaryGroup = secondary
        self.groupingFrom = groupingFrom
        minimumFraction = fixedFraction ? maximumFraction : 0
        self.maximumFraction = maximumFraction
        self.scale = scale

        // Used only if it writes these as FormatStyle does (a negative
        // number rounding to zero as zero, as the table shows it).
        for value in Self.checkValues {
            let scaled = value / power
            var expected = format(scaled)
            if scaled.sign == .minus, !expected.unicodeScalars.contains(where: { (digitValue($0) ?? 0) > 0 }) { expected = format(0) }
            guard string(for: scaled) == expected else { return nil }
        }
    }

    /// Numbers a template must write as FormatStyle does: small and large,
    /// grouped and not, ties rounding up and down, carries, signs, zeros.
    static let checkValues: [Double] = [
        0, -0.0, 1, -1, 0.5, 1.5, 2.5, -2.5, 9.995, 0.125, 0.135, 2.675, 1.005, 0.0049, -0.004, 0.06, 7, 12, 123,
        1_234, 12_345, 123_456, 1_234_567.891, -1_234_567.891, 99_999.999, 999_999.5, 1e15, 123_456_789_012_345_680,
        1e21, 0.000123456789, 2.0 / 3.0, -2.0 / 3.0, 5e-324, 1e-7, 0.1 + 0.2, 1_000_000,
    ]

    // MARK: Kept templates

    private struct Key: Hashable {
        let format: NGValueFormat
        let locale: String
        // (The user's own separators keep the identifier.)
        let decimalSeparator: String?
        let groupingSeparator: String?
    }

    /// Templates by format and locale (`nil`: FormatStyle writes them), for all threads.
    private static let kept = OSAllocatedUnfairLock<[Key: NGNumberTemplate?]>(initialState: [:])

    /// The template of a format in a locale, learned once.
    static func template(for format: NGValueFormat, locale: Locale, learn: () -> NGNumberTemplate?) -> NGNumberTemplate? {
        let key = Key(format: format, locale: locale.identifier, decimalSeparator: locale.decimalSeparator,
                      groupingSeparator: locale.groupingSeparator)
        if let template = kept.withLock({ $0[key] }) { return template }
        let template = learn()
        kept.withLock { $0[key] = .some(template) }
        return template
    }
}
