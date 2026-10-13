import CryptoKit
import Foundation
import Testing
import NGTable
import NGTableICU
import _NGCollationICU

/// The ICU's data is cut down to collation's (a few MB, not 34): every
/// collator ICU has, for every locale and collation type, still makes the
/// same keys as with all of ICU's data. `CollationKeys.txt` holds a hash of
/// each one's keys, recorded with the whole data:
///
///     Scripts/vendor-icu.py --all-data
///     NGTABLE_ICU_RECORD=1 swift test --filter NGCollationDataTests
///     Scripts/vendor-icu.py
@Suite("Collation data")
struct NGCollationDataTests {
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("CollationKeys.txt")

    /// Letters of many scripts, accents, case, numbers, punctuation, symbols.
    static let texts: [String] = {
        let words = ["Keto", "keto", "кето", "Кето", "Ёлка", "елка", "їжак", "ґанок", "Ελλάδα", "ελλάδα", "Éclair", "école",
                     "Ångström", "Æble", "Øl", "Müller", "Mueller", "straße", "Strasse", "ĳsland", "Łódź", "Čapek", "chata",
                     "Ñandú", "llama", "café", "Cafe", "naïve", "广告", "東京", "北京", "中國", "ひらがな", "カタカナ", "ｶﾀｶﾅ",
                     "한국어", "조선", "עברית", "العربية", "ไทย", "हिन्दी", "বাংলা", "தமிழ்", "ქართული", "Հայերեն", "ᎠᏍᎦᏯ",
                     "Tiếng Việt", "ạ", "(copy)", "#tag", "@home", "file2", "file10", "file１０", "½", "Ⅻ", "😀", "👍🏽", "ﬁle",
                     "a-b", "a b", "ab", "A.B", "", " ", "x\u{301}", "ǅ", "Ǆ", "ꙮ", "𝔘𝔫𝔦𝔠𝔬𝔡𝔢"]
        return words + words.map { $0 + " 7" } + zip(words, words.dropFirst(3)).map { $0 + $1 }
    }()

    /// Each collator ICU has (the available locales, each with its collation
    /// types), each that a locale of Foundation's asks for (NGTable opens
    /// `Locale.current.collatorIdentifier`), and language tags.
    static func identifiers() -> [String] {
        var identifiers = ["", "root", "en_US_POSIX", "ru_RU", "uk_UA", "zh_Hans_CN", "zh_Hant_TW", "ja_JP", "sr_Latn", "pa_Arab", "und",
                           "en-US", "zh-Hant-TW", "zh-TW", "de-u-co-phonebk", "es-u-co-trad", "sr-Latn-RS", "iw", "in", "no", "sh", "tl", "mo"]
        identifiers += Locale.availableIdentifiers.compactMap { Locale(identifier: $0).collatorIdentifier }
        for index in 0..<ucol_countAvailable() {
            guard let locale = ucol_getAvailable(index) else { continue }
            let name = String(cString: locale)
            identifiers.append(name)
            var status = U_ZERO_ERROR
            guard let types = ucol_getKeywordValuesForLocale("collation", name, 0, &status), status.rawValue <= 0 else { continue }
            defer { uenum_close(types) }
            while let type = uenum_next(types, nil, &status), status.rawValue <= 0 {
                identifiers.append("\(name)@collation=\(String(cString: type))")
            }
        }
        return Array(Set(identifiers)).sorted()
    }

    /// The collator's actual locale and a hash of its keys at the default
    /// strength and as NGTable makes them.
    static func line(_ identifier: String) -> String {
        var status = U_ZERO_ERROR
        guard let collator = ucol_open(identifier, &status), status.rawValue <= 0 else { return "\(identifier)\tfails \(status.rawValue)" }
        defer { ucol_close(collator) }
        let actual = ucol_getLocaleByType(collator, ULOC_ACTUAL_LOCALE, &status).map { String(cString: $0) } ?? "?"
        var hash = SHA256()
        let maker = NGBundledICUCollation().makeKeyMaker(collatorIdentifier: identifier)
        for text in texts {
            let utf16 = Array(text.utf16)
            var key = [UInt8](repeating: 0, count: 4096)
            let length = Int(ucol_getSortKey(collator, utf16, Int32(utf16.count), &key, Int32(key.count)))
            hash.update(data: key.prefix(length))
            var ngKey: [UInt8] = []
            utf16.withUnsafeBufferPointer { maker?.makeKey(of: $0, into: &ngKey) }
            hash.update(data: ngKey + [0xFF])
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        return "\(identifier)\t\(actual)\t\(digest)"
    }

    /// The data linked in is collation's: its items (the table of contents
    /// of ICU's common data, after its header) are a few hundred of the 4,855.
    @Test func onlyCollationsDataIsLinked() throws {
        let data = try #require(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "icudt76_dat"))   // RTLD_DEFAULT
        let headerSize = Int(data.loadUnaligned(as: UInt16.self))
        let items = Int(data.loadUnaligned(fromByteOffset: headerSize, as: UInt32.self))
        #expect(items > 100 && items < 300, "\(items) items")
    }

    @Test func everyCollatorMakesTheSameKeys() throws {
        let lines = Self.identifiers().map(Self.line)
        if ProcessInfo.processInfo.environment["NGTABLE_ICU_RECORD"] != nil {
            try (lines.joined(separator: "\n") + "\n").write(to: Self.fixture, atomically: true, encoding: .utf8)
            return
        }
        let recorded = try String(contentsOf: Self.fixture, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines.count == recorded.count)
        #expect(lines.count > 1_500)
        for (line, expected) in zip(lines, recorded) where line != expected {
            Issue.record("\(line) instead of \(expected)")
        }
    }
}
