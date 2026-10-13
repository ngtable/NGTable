import Foundation

/// How many threads background work (sorting, comparing, searching) runs
/// on: one core is left to the main thread. On all of them, a sort of a
/// million texts kept the main thread waiting 8–16 ms at a time (44 ms for
/// a frame in a window drawing), though it ran nothing of the sort itself.
enum NGParallelism {
    static let backgroundWorkers = min(16, max(1, ProcessInfo.processInfo.activeProcessorCount - 1))
}

// Comparing text the way the table sorts it (`localizedStandardCompare`, like
// Finder) on all cores, and the collation keys that sort it faster still.
//
// `localizedStandardCompare` fetches the current locale through a lock on
// every call, so more cores comparing text made a sort slower. Foundation
// compares by the locale's collator identifier only, and keeps one locale
// object per identifier: workers each get their own object with the same
// collator (an identifier with keywords that don't touch collation, like the
// first day of the week), and compare without contending. Whether that still
// gives Foundation's answers is checked on tricky pairs when the workers are
// made; if not, text compares on one core as before.
//
// Collation keys (bytes whose order is the text's order, from ICU) sort much
// faster, but `localizedStandardCompare` isn't a pure ICU collation (it folds
// case and compares ASCII digit runs itself), so keys only order the rows
// roughly: rows with equal keys are ordered by the real comparison, and
// every pair of neighbors is checked with it at the end (a sorted order).
// NGTable has no keys of its own: an app plugs a provider in
// (`NGTableView.collationKeyProvider`), such as the bundled ICU of the
// optional NGTableICU library (about 9 MB per architecture; macOS's own ICU
// has no public collation API).

/// Makes collation keys for the table's text sorts (see
/// `NGTableView.collationKeyProvider`).
public protocol NGCollationKeyProvider: Sendable {
    /// A key maker for one worker thread (it is never shared between
    /// threads), for a collator identifier such as `Locale.current.collatorIdentifier`;
    /// `nil` if it can't make keys (the table compares text instead).
    ///
    /// The keys should order text like `localizedStandardCompare` at the
    /// primary strength (letters, not case or accents) with numbers by value:
    /// for ICU, the collator of that identifier with numeric collation on,
    /// primary strength, non-ignorable punctuation and normalization on.
    /// Keys may tie where the text differs (the table orders those rows by
    /// comparing them); they must not order two texts the other way round
    /// from `localizedStandardCompare`, or the table finds out and sorts by
    /// comparing.
    func makeKeyMaker(collatorIdentifier: String) -> (any NGCollationKeyMaker)?
}

/// Makes the collation keys of texts on one thread.
public protocol NGCollationKeyMaker: AnyObject {
    /// Appends the key of a text (UTF-16) to `key`, which is empty.
    func makeKey(of text: UnsafeBufferPointer<UInt16>, into key: inout [UInt8])
}

/// How the table compares text on several threads: one locale object per
/// worker, each with the current collator.
final class NGTextCollation: @unchecked Sendable {
    /// `localizedStandardCompare`'s options.
    static let options: NSString.CompareOptions = [.caseInsensitive, .numeric, .widthInsensitive, .forcedOrdering]

    /// The collator Foundation compares by (the list sort order of Language
    /// & Region, else the first preferred language).
    let collatorIdentifier: String
    /// One per worker; a single one (comparing on one core) if distinct
    /// objects didn't compare like Foundation.
    let locales: [NSLocale]

    var workerCount: Int { locales.count }

    private init(collatorIdentifier: String, locales: [NSLocale]) {
        self.collatorIdentifier = collatorIdentifier
        self.locales = locales
    }

    /// Compares two texts like `localizedStandardCompare` (or another
    /// comparison), with a worker's locale.
    func compare(_ lhs: String, _ rhs: String, worker: Int, comparison: NGTextComparison = .standard) -> ComparisonResult {
        let text = lhs as NSString
        return text.compare(rhs, options: comparison.options, range: NSRange(location: 0, length: text.length),
                            locale: comparison.isLocalized ? locales[worker % locales.count] : nil)
    }

    // MARK: The current one

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: NGTextCollation?
    nonisolated(unsafe) private static var observer: NSObjectProtocol?

    /// Forgets the workers: the locale changed. Tables call it before they
    /// sort again (their observers may run before this type's own).
    static func localeDidChange() {
        lock.lock()
        cached = nil
        lock.unlock()
    }

    /// The workers for the current locale, made once (again when the locale changes).
    static var current: NGTextCollation {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let made = make()
        cached = made
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: NSLocale.currentLocaleDidChangeNotification,
                                                              object: nil, queue: nil) { _ in
                lock.lock()
                cached = nil
                lock.unlock()
            }
        }
        return made
    }

    private static func make() -> NGTextCollation {
        let identifier = Locale.current.collatorIdentifier ?? Locale.current.identifier
        let count = NGParallelism.backgroundWorkers
        // Keywords that don't change how text compares make distinct objects.
        let days = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"], hours = ["h23", "h12", "h11", "h24"]
        let separator = identifier.contains("@") ? ";" : "@"
        let locales = (0..<count).map { index in
            NSLocale(localeIdentifier: identifier + separator + "fw=\(days[index % 7]);hours=\(hours[index / 7 % 4])")
        }
        let workers = NGTextCollation(collatorIdentifier: identifier, locales: locales)
        guard workers.agreesWithFoundation() else {
            return NGTextCollation(collatorIdentifier: identifier, locales: [Locale.current as NSLocale])
        }
        return workers
    }

    /// Whether every worker compares tricky pairs like `localizedStandardCompare`.
    private func agreesWithFoundation() -> Bool {
        let samples = Self.samples
        for worker in locales.indices {
            for (index, lhs) in samples.enumerated() {
                // Every pair for the first worker, a stride of them for the others.
                for rhs in samples[index...] where worker == 0 || (lhs.count + rhs.count + worker) % 5 == 0 {
                    guard compare(lhs, rhs, worker: worker) == lhs.localizedStandardCompare(rhs) else { return false }
                }
            }
        }
        return true
    }

    /// Texts where collations differ: case, accents, digits by value and
    /// leading zeros, ß and ss, Ё and Е, widths, ligatures, scripts, punctuation.
    static let samples: [String] = [
        "", " ", "a", "A", "á", "Á", "ä", "Ä", "æ", "Æ", "b", "z", "Z", "ß", "ss", "SS", "ﬁ", "fi", "İ", "ı", "i",
        "file1", "file2", "file10", "file02", "File 2", "file-2", "file_2", "09", "9", "0009", "10", "1.5", "1,5", "-3",
        "е", "ё", "Ё", "Е", "ж", "Ж", "елка", "Ёлка", "яблоко", "Яблоко", "Straße", "Strasse", "STRASSE",
        "Müller", "Mueller", "école", "Éclair", "Ångström", "Œuvre", "oeuvre", "naïve", "nai\u{308}ve", "e\u{301}", "é",
        "Ｃａｍｐａｉｇｎ", "Campaign", "campaign 9", "Campaign 10", "４０", "40", "Ⅳ", "IV", "①", "1",
        "广告", "東京", "حملة", "Ελλάδα", "😀", "#tag", "@user", "$5", "€5", "(copy)", "–", "a b", "ab", "a-b", "a.b",
    ]
}
