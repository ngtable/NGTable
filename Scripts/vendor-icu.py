#!/usr/bin/env python3
# Makes Vendor/CollationICU: swift-foundation-icu's ICU (code as it is, at the
# revision below) with only the data collation needs, a few MB instead of the
# 34 MB of all of ICU's data that swift-foundation-icu builds in. NGTableICU
# only makes collation keys, so converters, time zones, names of languages,
# currencies and units, break rules, transliterators stay out.
#
#   Scripts/vendor-icu.py [--all-data] [swift-foundation-icu checkout]
#
# Without a checkout it clones the revision into a temporary folder.
# --all-data keeps all of ICU's data, to record CollationKeys.txt anew
# (NGTABLE_ICU_RECORD=1 swift test --filter NGCollationDataTests); then run
# it again without. The data is a package of ICU's common data format, kept
# as a file the code embeds (`#embed`). Tests/NGTableICUTests/CollationKeys.txt
# checks that every collator still makes the keys it made with all the data.
#
# swift-foundation-icu's build settings go into NGTable's Package.swift (its
# `_NGCollationICU` target; a package that others depend on by version can't
# depend on a local one) and into Vendor/CollationICU/Package.swift, a package
# of its own for the XCFramework's build (XCFramework/ICU/project.yml).
import os, re, shutil, struct, subprocess, sys, tempfile

REVISION = "f986d0728da0766cf81f371521b909d4a11681d2"   # swift-6.4.0-RELEASE: ICU 76.1
URL = "https://github.com/swiftlang/swift-foundation-icu.git"
DATA = "icudt76l-collation.dat"
MODULE = "_NGCollationICU"

here = os.path.dirname(os.path.abspath(__file__))
root = os.path.dirname(here)
out = os.path.join(root, "Vendor", "CollationICU")


ALL_DATA = "--all-data" in sys.argv[1:]
ARGUMENTS = [argument for argument in sys.argv[1:] if argument != "--all-data"]


def kept(name):
    """The data collation reads: the collation tree (its locales, aliases,
    parents and the root's data are all in it), and the keys and types of
    language tags' extensions ("de-u-co-phonebk"; ICU loads the time zones'
    with them)."""
    item = name.split("/", 1)[1]
    return ALL_DATA or item.startswith("coll/") or item in ("keyTypeData.res", "timezoneTypes.res")


def checkout():
    if ARGUMENTS:
        path = ARGUMENTS[0]
    else:
        path = os.path.join(tempfile.mkdtemp(), "swift-foundation-icu")
        subprocess.run(["git", "clone", "--quiet", "--filter=blob:none", "--no-checkout", URL, path], check=True)
        subprocess.run(["git", "-C", path, "checkout", "--quiet", REVISION], check=True)
    head = subprocess.run(["git", "-C", path, "rev-parse", "HEAD"], check=True, capture_output=True, text=True).stdout.strip()
    if head != REVISION:
        sys.exit(f"{path} is at {head}, not {REVISION}")
    return path


def packaged_data(common):
    """ICU's common data, from swift-foundation-icu's generated headers."""
    data = bytearray()
    for index in range(4):
        text = open(os.path.join(common, f"icu_packaged_main_data.{index}.inc.h")).read()
        body = text.split("#define", 1)[1].split(None, 1)[1]
        data += bytes(int(byte, 16) for byte in re.findall(r"0x[0-9A-Fa-f]{2}", body))
    return bytes(data)


def items(data):
    """(name, bytes) of each item of a common data package, in its order."""
    header_size = struct.unpack_from("<H", data, 0)[0]
    count = struct.unpack_from("<I", data, header_size)[0]
    entries = [struct.unpack_from("<II", data, header_size + 4 + 8 * index) for index in range(count)]
    result = []
    for index, (name_offset, data_offset) in enumerate(entries):
        start = header_size + name_offset
        name = data[start:data.index(0, start)].decode()
        end = header_size + (entries[index + 1][1] if index + 1 < count else len(data) - header_size)
        result.append((name, data[header_size + data_offset:end]))
    return data[:header_size], result


def package(header, kept_items):
    """A common data package of the items (names sorted, as ICU looks them up)."""
    kept_items = sorted(kept_items, key=lambda item: item[0].encode())
    count = len(kept_items)
    names = b"".join(name.encode() + b"\0" for name, _ in kept_items)
    toc_size = 4 + 8 * count
    name_offsets, offset = [], toc_size
    for name, _ in kept_items:
        name_offsets.append(offset)
        offset += len(name.encode()) + 1
    body = bytearray(names)
    offset = toc_size + len(body)
    data_offsets = []
    for _, item in kept_items:
        padding = (-(len(header) + offset)) % 16
        body += b"\0" * padding
        offset += padding
        data_offsets.append(offset)
        body += item
        offset += len(item)
    toc = struct.pack("<I", count) + b"".join(struct.pack("<II", n, d) for n, d in zip(name_offsets, data_offsets))
    return header + toc + bytes(body)


def main():
    source = checkout()
    icu = os.path.join(source, "icuSources")
    header, all_items = items(packaged_data(os.path.join(icu, "common")))
    collation = [(name, item) for name, item in all_items if kept(name)]

    shutil.rmtree(out, ignore_errors=True)
    sources = os.path.join(out, "Sources", MODULE)
    shutil.copytree(icu, sources, ignore=shutil.ignore_patterns("stubdata", "icu_packaged_main_data.*.inc.h", "CMakeLists.txt"))
    for folder, _, files in os.walk(sources):
        for file in files:
            os.chmod(os.path.join(folder, file), 0o644)
    open(os.path.join(sources, "common", DATA), "wb").write(package(header, collation))

    # The data from the file, not from the four generated headers.
    path = os.path.join(sources, "common", "icu_packaged_data.cpp")
    code = open(path).read()
    start, end = code.index('#include "icu_packaged_main_data.0.inc.h"'), code.index("#endif", code.index("U_ICUDATA_ENTRY_POINT[]"))
    code = code[:start] + f'''#include <stdint.h>
#include <_foundation_unicode/utypes.h>

// Changed by NGTable's Scripts/vendor-icu.py: only collation's data, from a file.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wc23-extensions"
extern "C" U_EXPORT uint8_t const U_ICUDATA_ENTRY_POINT[] __attribute__ ((aligned (16))) = {{
#embed "{DATA}"
}};
#pragma clang diagnostic pop

''' + code[end:]
    open(path, "w").write(code)

    modulemap = os.path.join(sources, "include", "_foundation_unicode", "module.modulemap")
    text = open(modulemap).read()
    open(modulemap, "w").write("// Changed by NGTable's Scripts/vendor-icu.py: the module's name.\n"
                               + text.replace("module _FoundationICU {", f"module {MODULE} {{", 1))

    manifest = open(os.path.join(source, "Package.swift")).read()
    manifest = manifest.replace('name: "FoundationICU"', 'name: "CollationICU"')
    manifest = manifest.replace('"_FoundationICU"', f'"{MODULE}"')
    manifest = manifest.replace('path: "icuSources"', f'path: "Sources/{MODULE}"')
    manifest = manifest.replace('exclude: ["stubdata"]', f'exclude: ["common/{DATA}"]')
    assert manifest.count(MODULE) >= 2 and DATA in manifest, "swift-foundation-icu's Package.swift changed"
    tools, rest = manifest.split("\n", 1)
    open(os.path.join(out, "Package.swift"), "w").write(
        f"{tools}\n// Generated by NGTable's Scripts/vendor-icu.py from swift-foundation-icu {REVISION}.\n{rest}")
    # The same settings for NGTable's target.
    settings = manifest[manifest.index("var buildSettings"):manifest.index("let package = Package(")].rstrip() + "\n"
    settings = settings.replace("buildSettings", "collationICUSettings").replace("linkerSettings", "collationICULinkerSettings")
    begin, end = "// BEGIN: swift-foundation-icu's settings for its ICU, copied by Scripts/vendor-icu.py\n", "// END: swift-foundation-icu's settings"
    path = os.path.join(root, "Package.swift")
    text = open(path).read()
    text = text[:text.index(begin) + len(begin)] + settings + text[text.index(end):]
    open(path, "w").write(text)

    shutil.copy(os.path.join(source, "LICENSE.md"), os.path.join(out, "LICENSE.md"))
    open(os.path.join(out, "README.md"), "w").write(f"""# CollationICU

The ICU of [swift-foundation-icu]({URL}) at {REVISION} (ICU 76.1), with only
the data collation needs: {len(collation)} of its {len(all_items)} data items,
{sum(len(item) for _, item in collation) / 1e6:.1f} MB instead of
{sum(len(item) for _, item in all_items) / 1e6:.1f} MB. The code is as it is
there; the data is `Sources/{MODULE}/common/{DATA}`, and the module is
`{MODULE}` (not `_FoundationICU`, which an app may have too).

Generated by `Scripts/vendor-icu.py`; don't edit it by hand. License: LICENSE.md
(ICU's and the Swift project's).
""")
    print(f"{len(collation)} items, {sum(len(item) for _, item in collation) / 1e6:.2f} MB of data")


main()
