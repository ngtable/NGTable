import Foundation

/// Which rows a table shows, e.g. from a search field and "active only" switch.
///
/// Search text matches like Finder and Mail: every word of it must be the
/// beginning of a word (ignoring case and diacritics) in the displayed value of
/// some searched column, so "Анна" finds "Анна #1" but not "Избранная". By
/// default the text, tag and mark columns are searched; list `columnIDs` to
/// search others (such as formatted numbers) too.
///
/// `isIncluded` receives data source row indexes, so it can test the app's
/// own model directly.
public struct NGRowFilter {
    /// What the user typed; empty matches every row.
    public var searchText: String
    /// Columns searched for `searchText`, whether shown or hidden. `nil`
    /// searches the shown text, tag and mark columns.
    public var columnIDs: Set<String>?
    /// Whether a data source row is shown, e.g. "active campaigns only".
    /// Combined with the search: a row must pass both. The table keeps the
    /// closure; capture `self` weakly in it.
    public var isIncluded: (@MainActor (Int) -> Bool)?

    public init(searchText: String = "", columnIDs: Set<String>? = nil, isIncluded: (@MainActor (Int) -> Bool)? = nil) {
        self.searchText = searchText
        self.columnIDs = columnIDs
        self.isIncluded = isIncluded
    }

    /// Whether the filter lets every row through.
    public var isEmpty: Bool {
        searchWords.isEmpty && isIncluded == nil
    }

    /// The folded words that must all be found.
    public var searchWords: [String] {
        Self.words(in: searchText)
    }

    /// Text split into words (letters and digits) with case and diacritics
    /// removed, so repeated searches only compare prefixes.
    /// The words of many rows' texts, split on all cores.
    static func words(of entries: [(handle: Int32, texts: [String], textColumns: UInt64)]) -> [[String]] {
        var result = [[String]](repeating: [], count: entries.count)
        let chunks = min(NGParallelism.backgroundWorkers, max(1, entries.count / 4096))
        result.withUnsafeMutableBufferPointer { result in
            nonisolated(unsafe) let result = result
            DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                for index in (chunk * entries.count / chunks)..<((chunk + 1) * entries.count / chunks) {
                    let texts = entries[index].texts
                    result[index] = texts.count == 1 ? words(in: texts[0]) : texts.flatMap(words(in:))
                }
            }
        }
        return result
    }

    public static func words(in text: String) -> [String] {
        // ASCII (most names, codes and numbers) in one pass over the bytes:
        // nothing to fold but case. Building the search index of 200,000
        // rows is mostly this.
        // Russian letters too, folded like Foundation folds them (ё to е,
        // й to и), decoded from UTF-8 by hand; any other text goes to
        // Foundation.
        var words: [String] = []
        var word: [UInt8] = []
        word.reserveCapacity(text.utf8.count)
        func flush() {
            guard !word.isEmpty else { return }
            words.append(String(decoding: word, as: UTF8.self))
            word.removeAll(keepingCapacity: true)
        }
        var utf8 = text.utf8.makeIterator()
        while let byte = utf8.next() {
            switch byte {
            case 0x41...0x5A:   // A-Z
                word.append(byte + 0x20)
            case 0x61...0x7A, 0x30...0x39:   // a-z, 0-9
                word.append(byte)
            case 0xD0, 0xD1:
                // U+0400-U+047F: Cyrillic.
                guard let next = utf8.next(), next & 0xC0 == 0x80 else { return foldedWords(in: text) }
                var value = UInt32(byte & 0x1F) << 6 | UInt32(next & 0x3F)
                switch value {
                case 0x410...0x42F: value += 0x20   // А-Я
                case 0x430...0x44F: break   // а-я
                case 0x401, 0x451: value = 0x435   // Ё, ё
                default: return foldedWords(in: text)
                }
                if value == 0x439 { value = 0x438 }   // й
                word.append(0xC0 | UInt8(value >> 6))
                word.append(0x80 | UInt8(value & 0x3F))
            case 0x80...:
                return foldedWords(in: text)
            default:
                flush()
            }
        }
        flush()
        return words
    }

    /// Other text: folded by Foundation, split at scalars that are neither
    /// letters nor digits. Marks that folding keeps (a virama in Hindi,
    /// Tamil or Khmer) and joiners (ZWNJ in Persian) belong to the letter
    /// before them, like in `Character`s: they don't split a word.
    static func foldedWords(in text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        var words: [String] = []
        var word = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars {
            if scalar.properties.isAlphabetic || scalar.properties.numericType != nil
                || (!word.isEmpty && Self.continuesWord(scalar)) {
                word.append(scalar)
            } else if !word.isEmpty {
                words.append(String(word))
                word = String.UnicodeScalarView()
            }
        }
        if !word.isEmpty { words.append(String(word)) }
        return words
    }

    /// A combining mark or a zero-width (non-)joiner: part of the letter before it.
    private static func continuesWord(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: true
        default: scalar.value == 0x200C || scalar.value == 0x200D
        }
    }

    /// Whether every search word begins one of a row's words.
    public static func matches(searchWords: [String], rowWords: [String]) -> Bool {
        searchWords.allSatisfy { word in rowWords.contains { $0.hasPrefix(word) } }
    }
}

extension NGCellValue {
    /// Whether a search without explicit columns looks at the value (text,
    /// not numbers).
    var givesSearchWords: Bool {
        switch self {
        case .text, .tags, .mark, .media: true
        default: false
        }
    }
}

/// The searchable words of every data source row (see `NGTableView.searchIndex`),
/// by row handle (`NGRowHandles`): rows inserted and removed around a row
/// don't move its words. Rows hold slots into the word lists; a changed row
/// takes a new slot, and the lists are compacted when half of them are old.
struct NGSearchIndex {
    let columnIDs: Set<String>
    let explicit: Bool
    /// The searched columns; `textColumns` bits are positions here.
    let columns: [NGTableColumn]
    private var lists: [[String]]
    private var slots: [Int32]
    /// Without explicit columns (and up to 64 columns), per row: the
    /// columns whose values gave words. Empty otherwise.
    private(set) var textColumns: [UInt64]
    private let tracks: Bool

    /// - Parameter words: The words by handle.
    init(columnIDs: Set<String>, explicit: Bool, columns: [NGTableColumn], words: [[String]], textColumns: [UInt64]) {
        self.columnIDs = columnIDs
        self.explicit = explicit
        self.columns = columns
        lists = [[]] + words
        slots = (1..<Int32(words.count + 1)).map { $0 }
        self.textColumns = textColumns
        tracks = !textColumns.isEmpty && textColumns.count == words.count
    }

    /// An index with no words yet, for building it row by row; `rowCount`
    /// is the capacity of handles.
    init(columnIDs: Set<String>, explicit: Bool, columns: [NGTableColumn], rowCount: Int, tracksTextColumns: Bool) {
        self.columnIDs = columnIDs
        self.explicit = explicit
        self.columns = columns
        lists = [[]]
        slots = [Int32](repeating: 0, count: rowCount)
        textColumns = tracksTextColumns ? [UInt64](repeating: 0, count: rowCount) : []
        tracks = tracksTextColumns
    }

    /// The number of handles it has room for.
    var rowCount: Int { slots.count }
    var tracksTextColumns: Bool { tracks }

    func words(ofRow row: Int) -> [String] {
        row < slots.count ? lists[Int(slots[row])] : []
    }

    mutating func set(_ words: [String], textColumns columns: UInt64, row: Int) {
        if row >= slots.count { grow(to: row + 1) }
        if lists.count >= 2 * max(slots.count, 1024) {
            // Mostly old lists: keep the current ones only (slot 0 stays empty).
            var compacted: [[String]] = [[]]
            compacted.reserveCapacity(slots.count + 1)
            for index in slots.indices {
                let slot = Int(slots[index])
                if slot == 0 { continue }
                slots[index] = Int32(compacted.count)
                compacted.append(lists[slot])
            }
            lists = compacted
        }
        slots[row] = Int32(lists.count)
        lists.append(words)
        if tracks { textColumns[row] = columns }
    }

    /// Room for handles up to `capacity` (new rows have no words until read).
    mutating func grow(to capacity: Int) {
        guard capacity > slots.count else { return }
        slots.append(contentsOf: repeatElement(0, count: capacity - slots.count))
        if tracks { textColumns.append(contentsOf: repeatElement(0, count: capacity - textColumns.count)) }
    }

    /// A removed row's words go (its handle may be reused).
    mutating func clear(_ row: Int) {
        guard row < slots.count else { return }
        slots[row] = 0
        if tracks { textColumns[row] = 0 }
    }
}
