# NGTableICU

Fast text sorts for NGTable: collation keys from an ICU built into the app,
in an optional library of NGTable's package. A table sorts a million shuffled texts in about **0.6 seconds**
instead of about 3 (NGTable alone, on all cores), in exactly the order of
`localizedStandardCompare` (Finder's).

> [!IMPORTANT]
> **This adds about 8.7 MB per architecture to your app** (ICU's code and its
> collation data): about 17 MB in a universal (Intel + Apple silicon) app,
> which the Mac App Store doesn't thin. From source it also adds about 30
> seconds to a clean build. Use it when your tables sort hundreds of
> thousands of texts (CSV viewers, logs, trading blotters). Tables of a few
> thousand rows sort in milliseconds without it: NGTable doesn't depend on
> it, and apps that don't add it don't build it.

It is safe for the Mac App Store: the ICU is linked into the app
(swift-foundation-icu's, `Vendor/CollationICU`) and imports nothing from the
system's ICU, whose collation functions aren't public API. With Xcode's
default for apps (Strip Linked Product: All Symbols), none of its function
names stay in the app either.

## Use

Add the library to your app's target, next to NGTable:

```swift
.target(name: "MyApp", dependencies: [
    .product(name: "NGTable", package: "NGTable"),
    .product(name: "NGTableICU", package: "NGTable"),
]),
```

Then at launch:

```swift
import NGTable
import NGTableICU

NGTableView.defaultCollationKeyProvider = NGBundledICUCollation()   // tables made from now on
// or for one table:
table.collationKeyProvider = NGBundledICUCollation()
```

That's all: tables that sort rows themselves (`sortsRows`) use the keys for
text columns. Rows whose keys are equal are compared, and every pair of
neighbors is checked with `localizedStandardCompare`, so the order never
differs from comparing (keys that disagree make the table sort by comparing).

## Why a separate library

It keeps NGTable free of the ICU's size and build time for everyone else.
Its version is NGTable's: NGTableICU 1.3 goes with NGTable 1.3.

## The ICU inside

`Vendor/CollationICU` is swift-foundation-icu's ICU 76.1 (the code as it is
there, at a pinned revision: it has no version numbers) with only the data
collation reads: the collation tree and two small files for language tags'
extensions, 4.3 MB of ICU's 34 MB. `Scripts/vendor-icu.py` makes it; the
tests check that every collator (1,713: each ICU has, with each collation
type, and each one a locale of Foundation's asks for) makes the same keys as
with all the data (`Tests/NGTableICUTests/CollationKeys.txt`). Its module is
`_NGCollationICU`, so an app with swift-foundation-icu's `_FoundationICU` can
have both.

## Binary

`XCFramework/ICU/build-xcframework.sh` builds `NGTableICU.xcframework` (arm64
+ x86_64, library evolution) against the binary `NGTable.xcframework` (built
first by `XCFramework/build-xcframework.sh`), with the ICU linked inside: the
framework exports only NGTableICU's own symbols and imports nothing from the
system's ICU. It then tests both frameworks as binary targets
(`XCFramework/ICU/Consumer`).

## License

Like NGTable: free for noncommercial use under the
[PolyForm Noncommercial License 1.0.0](LICENSE-NONCOMMERCIAL.md), and a
commercial license for use in a business (see [LICENSING.md](LICENSING.md)). The
ICU in `Vendor/CollationICU` keeps its own licenses (Unicode, Apache 2.0:
`Vendor/CollationICU/LICENSE.md`).
