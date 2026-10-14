#if os(macOS)
import AppKit

// The popover a column header's filter button opens. Number columns get a
// range ("from", "to"); other columns get their values with checkboxes and
// counts, narrowed by a search field. Changes apply as the user makes them;
// "Clear Filter" shows every row again.

@MainActor
final class NGColumnFilterViewController: NSViewController, NSTextFieldDelegate, NSSearchFieldDelegate,
    NSTableViewDataSource, NSTableViewDelegate {
    private weak var table: NGTableView?
    private let column: NGTableColumn
    /// Value filters: every value the column offers, and those checked.
    private var values: [(value: String, count: Int)] = []
    private var checked: Set<String> = []
    /// Whether the column has more values than the list shows.
    private var isTruncated = false
    /// Values a filter excluded that the list doesn't show: they stay excluded.
    private var excludedElsewhere: Set<String> = []
    /// A list that doesn't show every value either shows only the values
    /// checked (`true`: opened over such a filter, or after everything was
    /// unchecked) or hides the ones unchecked, so values not listed stay.
    private var showsOnlyChecked = false
    /// The values matching the search, in the list.
    private var shownValues: [(value: String, count: Int)] = []
    private let allBox = NSButton(checkboxWithTitle: String(localized: "Select All", bundle: .module,
                                                            comment: "Column filter: checks every value."), target: nil, action: nil)
    /// The values with their checkboxes: only those in view are made (a
    /// stack of a thousand took seconds to lay out).
    private let list = NSTableView()
    private let searchField = NSSearchField()
    /// Range filters.
    private let minField = NSTextField()
    private let maxField = NSTextField()
    private let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.isLenient = true
        // Bounds as set, not rounded to three digits.
        formatter.maximumFractionDigits = 12
        return formatter
    }()

    /// Percent columns hold fractions but show and take percents: 25 is 0.25.
    private var shownScale: Double {
        if case .percent = column.format { 100 } else { 1 }
    }

    init(table: NGTableView, column: NGTableColumn) {
        self.table = table
        self.column = column
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let title = NSTextField(labelWithString: column.menuTitle)
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let clear = NSButton(title: String(localized: "Clear Filter", bundle: .module, comment: "Column filter: shows every row again."),
                             target: self, action: #selector(clearFilter(_:)))
        clear.bezelStyle = .rounded
        let body = column.isNumeric ? makeRangeBody() : makeValuesBody()
        let stack = NSStackView(views: [title, body, clear])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.widthAnchor.constraint(equalToConstant: 260).isActive = true
        body.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        view = stack
    }

    // MARK: Range

    private func makeRangeBody() -> NSView {
        for (field, placeholder) in [(minField, String(localized: "From", bundle: .module, comment: "Column filter: the smallest number shown.")),
                                     (maxField, String(localized: "To", bundle: .module, comment: "Column filter: the largest number shown."))] {
            field.placeholderString = placeholder
            field.delegate = self
            field.translatesAutoresizingMaskIntoConstraints = false
        }
        if case .range(let min, let max) = table?.columnFilters[column.id] {
            minField.stringValue = min.flatMap { numberFormatter.string(from: NSNumber(value: $0 * shownScale)) } ?? ""
            maxField.stringValue = max.flatMap { numberFormatter.string(from: NSNumber(value: $0 * shownScale)) } ?? ""
        }
        let row = NSStackView(views: [minField, NSTextField(labelWithString: "–"), maxField])
        row.distribution = .fill
        minField.widthAnchor.constraint(equalTo: maxField.widthAnchor).isActive = true
        return row
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSSearchField === searchField {
            showValues()
            return
        }
        func bound(_ field: NSTextField) -> Double? {
            let text = field.stringValue.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
            return numberFormatter.number(from: text).map { $0.doubleValue / shownScale }
        }
        // Only the field being typed in changes its bound (the other keeps its exact value).
        var (min, max): (Double?, Double?) = (bound(minField), bound(maxField))
        if case .range(let oldMin, let oldMax) = table?.columnFilters[column.id] {
            if notification.object as? NSTextField === maxField { min = oldMin }
            if notification.object as? NSTextField === minField { max = oldMax }
        }
        table?.setColumnFilter(.range(min: min, max: max), forColumnID: column.id)
    }

    // MARK: Values

    private func makeValuesBody() -> NSView {
        let offered = table?.filterValueList(forColumnID: column.id, limit: 1_000)
        values = offered?.values ?? []
        isTruncated = offered?.isTruncated ?? false
        let listed = Set(values.map(\.value))
        switch table?.columnFilters[column.id] {
        case .values(let selected)?:
            checked = selected
            showsOnlyChecked = true
        case .excluding(let excluded)?:
            checked = listed.subtracting(excluded)
            excludedElsewhere = excluded.subtracting(listed)
        default:
            checked = listed
        }
        searchField.placeholderString = String(localized: "Search", bundle: .module, comment: "Column filter: narrows the list of values.")
        searchField.delegate = self
        allBox.target = self
        allBox.action = #selector(toggleAll(_:))
        allBox.allowsMixedState = true
        let listColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value"))
        listColumn.resizingMask = .autoresizingMask
        list.addTableColumn(listColumn)
        list.headerView = nil
        list.style = .plain
        // The old stack's pitch: a check box and 4 points between them.
        list.rowHeight = 20
        list.intercellSpacing = .zero
        list.backgroundColor = .clear
        list.selectionHighlightStyle = .none
        list.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        list.dataSource = self
        list.delegate = self
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = list
        scroll.heightAnchor.constraint(equalToConstant: min(260, CGFloat(max(1, values.count)) * 20)).isActive = true
        showValues()
        let stack = NSStackView(views: [searchField, allBox, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        // The rows center their check boxes: the first one where the stack had it.
        stack.setCustomSpacing(6, after: allBox)
        for view in [searchField, scroll] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    /// The values matching the search, with their checkboxes.
    private func showValues() {
        let search = searchField.stringValue
        shownValues = values.filter { value, _ in
            search.isEmpty || value.range(of: search, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        list.reloadData()
        updateAllBox()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shownValues.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("check")
        let button = tableView.makeView(withIdentifier: identifier, owner: self) as? NSButton ?? {
            let button = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleValue(_:)))
            button.identifier = identifier
            return button
        }()
        let (value, count) = shownValues[row]
        let noValue = String(localized: "No Value", bundle: .module, comment: "Group header for rows without a value in the grouping column.")
        button.title = "\(value.isEmpty ? noValue : value)  (\(count.formatted(.number.locale(table?.formattingLocale ?? .current))))"
        button.state = checked.contains(value) ? .on : .off
        button.tag = row
        return button
    }

    private func updateAllBox() {
        let count = shownValues.lazy.filter { self.checked.contains($0.value) }.count
        allBox.state = count == 0 ? .off : count == shownValues.count ? .on : .mixed
    }

    @objc private func toggleValue(_ sender: NSButton) {
        guard shownValues.indices.contains(sender.tag) else { return }
        let value = shownValues[sender.tag].value
        if sender.state == .on { checked.insert(value) } else { checked.remove(value) }
        updateAllBox()
        applyValues()
    }

    @objc private func toggleAll(_ sender: NSButton) {
        // A mixed box checks everything shown.
        let on = sender.state != .off
        sender.state = on ? .on : .off
        for (value, _) in shownValues {
            if on { checked.insert(value) } else { checked.remove(value) }
        }
        list.reloadData()
        applyValues()
    }

    /// Every value checked: no filter. A list that doesn't show every value
    /// hides the unchecked ones (values not listed, or arriving later, stay
    /// shown), unless it shows only the checked ones: opened over such a
    /// filter, or once nothing is checked. A full list: whichever is shorter.
    private func applyValues() {
        let all = Set(values.map(\.value))
        let unchecked = all.subtracting(checked)
        let filter: NGColumnFilter?
        if unchecked.isEmpty, excludedElsewhere.isEmpty {
            filter = nil
            showsOnlyChecked = false
        } else if isTruncated || !excludedElsewhere.isEmpty {
            if checked.isEmpty { showsOnlyChecked = true }
            filter = showsOnlyChecked ? .values(checked) : .excluding(unchecked.union(excludedElsewhere))
        } else {
            filter = unchecked.count <= checked.count ? .excluding(unchecked) : .values(checked)
        }
        table?.setColumnFilter(filter, forColumnID: column.id)
    }

    @objc private func clearFilter(_ sender: Any?) {
        table?.setColumnFilter(nil, forColumnID: column.id)
        table?.columnFilterPopover?.close()
    }
}
/// A plain view with its origin at the top.
final class NGFlippedView: NSView {
    override var isFlipped: Bool { true }
}
#endif
