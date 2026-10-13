import Foundation
import NGTable
@_implementationOnly import _NGCollationICU

// Collation keys from an ICU built into the app (swift-foundation-icu's, with
// only collation's data: Vendor/CollationICU), for NGTable's text sorts
// (`NGTableView.collationKeyProvider`). With them the table sorts a million texts in under half a second instead of seconds,
// still in `localizedStandardCompare`'s order (it compares rows whose keys
// are equal and checks every pair of neighbors).
//
// Unlike the ICU of macOS, whose collation functions aren't public API, this
// one is linked into the app: fine for the Mac App Store. It costs about
// 9 MB of the app's size per architecture.

/// Collation keys from the bundled ICU.
///
/// ```swift
/// import NGTableICU
/// NGTableView.defaultCollationKeyProvider = NGBundledICUCollation()
/// ```
public struct NGBundledICUCollation: NGCollationKeyProvider {
    public init() {}

    public func makeKeyMaker(collatorIdentifier: String) -> (any NGCollationKeyMaker)? {
        ICUKeyMaker(collatorIdentifier: collatorIdentifier)
    }
}

/// A collator of one worker thread (ICU collators aren't thread-safe).
private final class ICUKeyMaker: NGCollationKeyMaker {
    private let collator: OpaquePointer

    init?(collatorIdentifier: String) {
        var status = U_ZERO_ERROR
        guard let collator = ucol_open(collatorIdentifier, &status), status.rawValue <= 0 else { return nil }
        // Like localizedStandardCompare's first level: letters, numbers by value.
        ucol_setAttribute(collator, UCOL_NUMERIC_COLLATION, UCOL_ON, &status)
        ucol_setAttribute(collator, UCOL_ALTERNATE_HANDLING, UCOL_NON_IGNORABLE, &status)
        ucol_setAttribute(collator, UCOL_STRENGTH, UCOL_PRIMARY, &status)
        ucol_setAttribute(collator, UCOL_NORMALIZATION_MODE, UCOL_ON, &status)
        guard status.rawValue <= 0 else {
            ucol_close(collator)
            return nil
        }
        self.collator = collator
    }

    deinit { ucol_close(collator) }

    func makeKey(of text: UnsafeBufferPointer<UInt16>, into key: inout [UInt8]) {
        guard text.count > 0 else { return }
        var capacity = text.count * 4 + 16
        while true {
            key = [UInt8](repeating: 0, count: capacity)
            let length = Int(key.withUnsafeMutableBufferPointer {
                ucol_getSortKey(collator, text.baseAddress, Int32(text.count), $0.baseAddress, Int32(capacity))
            })
            if length <= capacity {
                // Without the terminating zero.
                key.removeSubrange(max(0, length - 1)...)
                return
            }
            capacity = length
        }
    }
}
