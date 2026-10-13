//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

#if USE_PACKAGE_DATA

#include <stdint.h>
#include <_foundation_unicode/utypes.h>

// Changed by NGTable's Scripts/vendor-icu.py: only collation's data, from a file.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wc23-extensions"
extern "C" U_EXPORT uint8_t const U_ICUDATA_ENTRY_POINT[] __attribute__ ((aligned (16))) = {
#embed "icudt76l-collation.dat"
};
#pragma clang diagnostic pop

#endif
