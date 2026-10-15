import Foundation
import Testing
@testable import NGTable

/// Numbers written by templates learned from FormatStyle
/// (NGNumberTemplate.swift) are FormatStyle's text, in every locale.
@Suite("Number templates")
struct NGNumberTemplateTests {
    static let formats: [NGValueFormat] = [.automatic, .number(fractionDigits: 0), .number(fractionDigits: 2), .number(fractionDigits: 4),
                                           .percent(fractionDigits: 0), .percent(fractionDigits: 1), .currency(code: "USD"),
                                           .currency(code: "EUR"), .currency(code: "JPY"), .currency(code: "RUB"), .currency(code: "BHD")]

    /// What FormatStyle writes (and a negative number rounding to zero as zero).
    static func expected(_ number: Double, _ format: NGValueFormat, _ locale: Locale) -> String {
        func formatted(_ number: Double) -> String {
            switch format {
            case .number(let digits): FloatingPointFormatStyle<Double>(locale: locale).precision(.fractionLength(digits)).format(number)
            case .currency(let code): FloatingPointFormatStyle<Double>.Currency(code: code, locale: locale).format(number)
            case .percent(let digits): FloatingPointFormatStyle<Double>.Percent(locale: locale).precision(.fractionLength(digits)).format(number)
            case .automatic, .date, .time: FloatingPointFormatStyle<Double>(locale: locale).format(number)
            }
        }
        let text = formatted(number)
        guard number.sign == .minus, number.isFinite, !text.contains(where: { ($0.wholeNumberValue ?? 0) != 0 }) else { return text }
        return formatted(0)
    }

    /// Values of every kind: integers, decimals, ties at every digit, carries,
    /// large and tiny, random bits.
    static func values(count: Int, seed: UInt64) -> [Double] {
        var generator = SplitMix(seed: seed)
        var values: [Double] = [0, -0.0, .nan, .infinity, -.infinity, 0.5, 0.05, 0.005, 0.0005, 9.9995, 999.5, 0.995, 1e16, 9.999999e20]
        while values.count < count {
            let random = generator.next()
            let sign: Double = random & 1 == 0 ? 1 : -1
            let value: Double = switch random % 7 {
            case 0: Double(Int(generator.next() % 10_000_000_000))
            case 1: Double(Int(generator.next() % 100_000_000)) / pow(10, Double(generator.next() % 7))
            // Ties: ...5 at the last place.
            case 2: (Double(Int(generator.next() % 1_000_000)) + 0.5) / pow(10, Double(generator.next() % 6))
            case 3: Double(bitPattern: generator.next() % 0x7FF0_0000_0000_0000)   // Any finite magnitude.
            case 4: Double(generator.next() % 1_000) / 1_000 * pow(10, Double(Int(generator.next() % 40) - 20))
            case 5: 1 - pow(10, -Double(generator.next() % 8))   // 0.9, 0.99, ...
            default: Double(generator.next() % 1_000_000) / 100
            }
            values.append(sign * value)
        }
        return values
    }

    @Test func sameAsFormatStyleInEveryLocale() {
        var mismatches: [String] = []
        var templates = 0, styles = 0
        let values = Self.values(count: 80, seed: 3)
        for identifier in Locale.availableIdentifiers.sorted() {
            let locale = Locale(identifier: identifier)
            for format in Self.formats {
                let style = NGNumberStyle(format, locale: locale)
                if style.usesTemplate { templates += 1 } else { styles += 1 }
                for value in values where style.string(for: value) != Self.expected(value, format, locale) {
                    if mismatches.count < 20 {
                        mismatches.append("\(identifier) \(format) \(value): \(style.string(for: value)) ≠ \(Self.expected(value, format, locale))")
                    }
                }
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.joined(separator: "\n"))")
        print("Number templates: \(templates) formats of locales by template, \(styles) by FormatStyle")
    }

    /// Common locales get templates (else the speed is lost without a word).
    @Test func commonLocalesHaveTemplates() {
        for identifier in ["en_US", "en_GB", "ru_RU", "de_DE", "fr_FR", "de_CH", "en_IN", "es_ES", "pt_BR", "ja_JP", "zh_CN",
                           "ko_KR", "it_IT", "nl_NL", "sv_SE", "pl_PL", "tr_TR", "uk_UA", "ar_EG", "fa_IR", "hi_IN"] {
            for format in Self.formats {
                #expect(NGNumberStyle(format, locale: Locale(identifier: identifier)).usesTemplate, "\(identifier) \(format)")
            }
        }
    }

    @Test func manyValuesInAFewLocales() {
        let values = Self.values(count: 20_000, seed: 9)
        for identifier in ["en_US", "ru_RU", "de_CH", "en_IN", "es_ES", "ar_EG"] {
            let locale = Locale(identifier: identifier)
            for format in Self.formats {
                let style = NGNumberStyle(format, locale: locale)
                let wrong = values.first { style.string(for: $0) != Self.expected($0, format, locale) }
                #expect(wrong == nil, "\(identifier) \(format) \(wrong ?? 0): \(style.string(for: wrong ?? 0)) ≠ \(Self.expected(wrong ?? 0, format, locale))")
            }
        }
    }
}
