# NGTable is now Gingham

NGTable has moved and is now called **Gingham**:

### → [github.com/digitalglobeby/Gingham](https://github.com/digitalglobeby/Gingham)

It is the same table view for business data on the Mac, iPad and iPhone,
with the same API, renamed:

- the module is `Gingham` (and `GinghamICU`): `import Gingham`;
- types begin with `GH` instead of `NG`: `NGTableView` is `GHTableView`,
  `NGTableColumn` is `GHTableColumn`, `NGCellValue` is `GHCellValue`, and so
  on;
- layouts saved with `autosaveName` stay.

```swift
.package(url: "https://github.com/digitalglobeby/Gingham", from: "1.0.1"),
```

Gingham is free for any use, commercial too, with up to 10,000 rows a table;
a license key shows every row. See its
[documentation](https://digitalglobeby.github.io/Gingham/documentation/gingham/)
and [release notes](https://digitalglobeby.github.io/Gingham/documentation/gingham/releasenotes).

This repository only keeps this notice.
