# Summaries

Show totals, averages and computed values in the summary row, for all rows or
just the selected ones.

## Overview

The summary row at the bottom of the table shows one value per column, aligned
with the column. What a column shows is its ``NGColumnSummary``:

```swift
NGTableColumn("spend", title: "Spend", format: .currency(code: "EUR"), summary: .aggregate(.sum))
```

The summary row holds values only, no captions; use the column's `toolTip` to
explain a less obvious one ("Average of campaigns that ran"). Values are
formatted with the column's format, except counts, which are whole numbers.
Hide the row with ``NGTableView/showsSummaryRow``.

Only `.number` values take part, and dates: a column of dates counts them,
and its minimum, maximum and average are dates (the earliest, the latest),
shown in the column's date format. Empty values, text, NaN and infinity are
left out, so a column where some rows have no value summarizes the others.

### Aggregates

`.aggregate(_:including:)` computes an ``NGAggregate`` of the column's own
values:

| Aggregate | Result | Without values |
| --- | --- | --- |
| `.sum` | The total, summed without rounding drift | Blank |
| `.average` | The mean | Blank |
| `.count` | How many rows have a number | 0 |
| `.min`, `.max` | The smallest or largest value | Blank |

An ``NGValueFilter`` limits the values: `.nonZero`, `.positive`,
`.nonNegative`, or your own:

```swift
// The average ROI of the campaigns that actually ran.
summary: .aggregate(.average, including: .nonZero)

// A custom filter: give it a unique name.
let large = NGValueFilter("atLeast1000") { $0 >= 1000 }
summary: .aggregate(.count, including: large)
```

Filters may be called off the main thread, so they must only look at the
value.

### Formulas

Many business totals are not an aggregate of the column's own values. The
total ROI of several campaigns is not the average of their ROIs: a small
campaign with +200 % would outweigh a big one with −10 %. It is the ratio of
the sums: (Σ revenue − Σ spend) / Σ spend. An ``NGSummaryFormula`` computes
such values from aggregates of other columns:

```swift
static let roi = NGSummaryFormula("roi", using: ["spend", "revenue"],
                                  otherwise: .average, including: .nonZero) { values in
    guard let spend = values.sum("spend"), spend != 0,
          let revenue = values.sum("revenue") else { return nil }
    return (revenue - spend) / spend
}

NGTableColumn("roi", title: "ROI", format: .percent(fractionDigits: 1), summary: .formula(roi))
```

Other examples:

| Metric | Formula |
| --- | --- |
| CTR | Σ clicks / Σ impressions |
| CPC | Σ spend / Σ clicks |
| CPA | Σ spend / Σ conversions |
| Conversion rate | Σ conversions / Σ clicks |
| Margin | (Σ revenue − Σ cost) / Σ revenue |

- `inputs` lists every column the formula reads. They don't need to be shown,
  or even defined: the data source is asked for their values by id like for any
  column, so a formula can use raw numbers the table doesn't display.
- ``NGSummaryValues`` gives each input's sum, average, count, min and max in the
  current scope; `nil` when the input has no numbers there.
- Return `nil` when the value can't be computed, for example when dividing by
  zero. The table then shows the `otherwise` aggregate of the column's own
  values (filtered by `including`), or nothing.
- Formulas are compared by name: give every different formula its own name,
  and keep it a pure function of its inputs (it may run off the main thread).

### Scopes

``NGTableView/summaryScope`` chooses the rows the summaries cover
(``NGSummaryScope``):

- `.allRows`: every row shown (after the filter);
- `.selectedRows`: the selected rows;
- `.excludingSelectedRows`: every row shown except the selected ones, for
  "what if we stopped these campaigns?".

Users change the scope from the summary row's context menu; the table reports
it with ``NGTableViewDelegate/tableView(_:summaryScopeDidChange:)``, so you can
update your own controls. The menu titles are localized in English and
Russian; change them with ``NGTableView/summaryScopeTitles``.

Summaries always cover the rows the filter shows, never rows it hides.

With ``NGTableView/rowGrouping``, every group header shows subtotals with
the same aggregates and formulas over the group's rows (see
<doc:GroupingRows>); the summary row keeps covering all rows of its scope.

### Reading summary values

``NGTableView/summaryValue(forColumnID:)`` returns the value of a column in the
current scope, and ``NGTableView/summaryText(forColumnID:)`` the text as
displayed, for example to show a total in a toolbar or to export it.

Summaries update by themselves when the data is reloaded, the filter or the
selection changes (for the selection scopes) or columns are shown. When only
the values changed and you don't need to reload cells, call
``NGTableView/reloadSummary()``.

### Large tables

Up to ``NGTableView/synchronousSummaryLimit`` values (rows × summarized
columns, 50,000 by default), summaries are computed during
``NGTableView/reloadData()``. Above it, the table shows the rows at once, reads
the values in short slices on the main thread, and computes the summaries in
the background, so the app stays responsive.

- While it computes, ``NGTableView/isComputingSummary`` is `true`. Totals over
  all rows show the previous values; values that depend on the selection are
  blank rather than wrong.
- If it takes more than a moment, a small spinner appears in the summary row
  and its values dim. Turn it off with ``NGTableView/showsSummaryProgress`` to
  show progress in your own UI.
- ``NGTableViewDelegate/tableViewDidUpdateSummary(_:)`` is called when the
  values computed in the background are shown.
- Reloading again during a computation cancels it and starts over, so a burst
  of reloads computes only once.

Once computed, the values are kept compactly, and changing the selection or
scope stays fast even with 100,000 rows: sums over most rows are taken as the
total minus the few other rows.
