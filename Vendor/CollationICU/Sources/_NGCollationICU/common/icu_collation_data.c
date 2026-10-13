// Made by NGTable's Scripts/vendor-icu.py: ICU's common data, only collation's,
// embedded from icudt76l-collation.dat (ICU finds it as U_ICUDATA_ENTRY_POINT). In C, not C++:
// Xcode 26.0's clang gives #embed's bytes the type char, which C++ won't narrow.

#include <stdint.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wc23-extensions"
#pragma clang diagnostic ignored "-Wconstant-conversion"
__attribute__((visibility("default"), aligned(16)))
const uint8_t icudt76_dat[] = {
#embed "icudt76l-collation.dat"
};
#pragma clang diagnostic pop
