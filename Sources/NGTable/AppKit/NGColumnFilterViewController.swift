#if os(macOS)
import AppKit

// The popover a column header's filter button opens. Number columns get a
// range ("from", "to") or the top or bottom rows by count; date columns a
// period (today, this week, the last 30 days, between two days); other
// columns their values with checkboxes and counts, narrowed by a search
// field. Changes apply as the user makes them; "Clear Filter" shows every
// row again. By keyboard: Tab between the controls, Down Arrow from the
// search field into the values, Space checks or unchecks the selected ones.

@MainActor
final class NGColumnFilterViewController: NSViewController, NSTextFieldDelegate, NSSearchFieldDelegate,
    NSTableViewDataSource, NSTableViewDelegate {
    private weak var table: NGTableView?
    private let column: NGTableColumn
    /// Value filters: the values offered and those checked (see NGFilterValueChoice.swift).
    private var choice: NGFilterValueChoice?
    private var values: [(value: String, count: Int)] { choice?.values ?? [] }
    /// The values matching the search, in the list.
    private var shownValues: [(value: String, count: Int)] = []
    private let allBox = NSButton(checkboxWithTitle: String(localized: "Select All", bundle: .module,
                                                            comment: "Column filter: checks every value."), target: nil, action: nil)
    /// The values with their checkboxes: only those in view are made (a
    /// stack of a thousand took seconds to lay out).
    private let list = NGFilterValueList()
    private let searchField = NSSearchField()
    /// Range filters.
    private let minField = NSTextField()
    private let maxField = NSTextField()
    /// Number filters: a range, or the top or bottom rows by count.
    private let numberMode = NSSegmentedControl(labels: [
        String(localized: "Range", bundle: .module, comment: "Column filter: numbers between two bounds."),
        String(localized: "Top", bundle: .module, comment: "Column filter: the rows with the largest numbers."),
        String(localized: "Bottom", bundle: .module, comment: "Column filter: the rows with the smallest numbers."),
    ], trackingMode: .selectOne, target: nil, action: nil)
    private let rangeRow = NSStackView()
    private let countRow = NSStackView()
    private let countField = NSTextField()
    /// Date filters: the periods offered, the last one two days chosen.
    private let periodMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fromDay = NSDatePicker()
    private let toDay = NSDatePicker()
    private let daysRow = NSStackView()
    private static var periods: [(period: NGDatePeriod?, title: String)] { NGFilterValueChoice.periods }
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
        let body = column.format.isDate ? makeDateBody() : column.isNumeric ? makeNumberBody() : makeValuesBody()
        let stack = NSStackView(views: [title, body, clear])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.widthAnchor.constraint(equalToConstant: 260).isActive = true
        body.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        view = stack
    }

    // MARK: Numbers

    private func makeNumberBody() -> NSView {
        for (field, placeholder) in [(minField, String(localized: "From", bundle: .module, comment: "Column filter: the smallest number shown.")),
                                     (maxField, String(localized: "To", bundle: .module, comment: "Column filter: the largest number shown."))] {
            field.placeholderString = placeholder
            field.delegate = self
            field.translatesAutoresizingMaskIntoConstraints = false
        }
        countField.delegate = self
        countField.placeholderString = "10"
        countField.stringValue = "10"
        switch table?.columnFilters[column.id] {
        case .range(let min, let max)?:
            minField.stringValue = min.flatMap { numberFormatter.string(from: NSNumber(value: $0 * shownScale)) } ?? ""
            maxField.stringValue = max.flatMap { numberFormatter.string(from: NSNumber(value: $0 * shownScale)) } ?? ""
        case .top(let count)?:
            numberMode.selectedSegment = 1
            countField.stringValue = "\(count)"
        case .bottom(let count)?:
            numberMode.selectedSegment = 2
            countField.stringValue = "\(count)"
        default:
            break
        }
        if numberMode.selectedSegment < 0 { numberMode.selectedSegment = 0 }
        numberMode.target = self
        numberMode.action = #selector(numberModeChanged(_:))
        rangeRow.setViews([minField, NSTextField(labelWithString: "–"), maxField], in: .leading)
        rangeRow.distribution = .fill
        minField.widthAnchor.constraint(equalTo: maxField.widthAnchor).isActive = true
        let rows = NSTextField(labelWithString: String(localized: "rows", bundle: .module, comment: "Column filter: after the count of top or bottom rows."))
        countRow.setViews([countField, rows], in: .leading)
        countField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        let stack = NSStackView(views: [numberMode, rangeRow, countRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        rangeRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        showNumberMode()
        return stack
    }

    private func showNumberMode() {
        rangeRow.isHidden = numberMode.selectedSegment != 0
        countRow.isHidden = numberMode.selectedSegment == 0
    }

    @objc private func numberModeChanged(_ sender: NSSegmentedControl) {
        showNumberMode()
        applyNumbers(changed: nil)
    }

    /// The range, or the top or bottom rows by the count typed.
    private func applyNumbers(changed field: NSTextField?) {
        if numberMode.selectedSegment > 0 {
            let count = max(0, Int(countField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 10)
            table?.setColumnFilter(numberMode.selectedSegment == 1 ? .top(count) : .bottom(count), forColumnID: column.id)
            return
        }
        func bound(_ field: NSTextField) -> Double? {
            NGFilterValueChoice.bound(field.stringValue, format: column.format, formatter: numberFormatter)
        }
        // Only the field being typed in changes its bound (the other keeps its exact value).
        var (min, max): (Double?, Double?) = (bound(minField), bound(maxField))
        if case .range(let oldMin, let oldMax) = table?.columnFilters[column.id] {
            if field === maxField { min = oldMin }
            if field === minField { max = oldMax }
        }
        table?.setColumnFilter(.range(min: min, max: max), forColumnID: column.id)
    }

    // MARK: Dates

    private func makeDateBody() -> NSView {
        periodMenu.addItems(withTitles: Self.periods.map(\.title))
        periodMenu.target = self
        periodMenu.action = #selector(periodChanged(_:))
        let calendar = table?.calendar ?? .current
        for picker in [fromDay, toDay] {
            picker.datePickerStyle = .textFieldAndStepper
            picker.datePickerElements = .yearMonthDay
            picker.calendar = calendar
            picker.timeZone = calendar.timeZone
            picker.locale = table?.formattingLocale
            picker.dateValue = Date()
            picker.target = self
            picker.action = #selector(daysChanged(_:))
        }
        if case .dates(let period)? = table?.columnFilters[column.id] {
            if case .between(let start, let end) = period {
                periodMenu.selectItem(at: Self.periods.count - 1)
                if let start { fromDay.dateValue = start }
                // The last day shown: the one before the end.
                if let end { toDay.dateValue = calendar.date(byAdding: .day, value: -1, to: end) ?? end }
            } else if let index = Self.periods.firstIndex(where: { $0.period == period }) {
                periodMenu.selectItem(at: index)
            }
        }
        daysRow.setViews([fromDay, NSTextField(labelWithString: "–"), toDay], in: .leading)
        let stack = NSStackView(views: [periodMenu, daysRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        daysRow.isHidden = periodMenu.indexOfSelectedItem != Self.periods.count - 1
        return stack
    }

    @objc private func periodChanged(_ sender: NSPopUpButton) {
        let isBetween = sender.indexOfSelectedItem == Self.periods.count - 1
        daysRow.isHidden = !isBetween
        if isBetween { return daysChanged(nil) }
        table?.setColumnFilter(Self.periods[sender.indexOfSelectedItem].period.map { .dates($0) }, forColumnID: column.id)
    }

    /// From the first day's start to the end of the last.
    @objc private func daysChanged(_ sender: Any?) {
        let calendar = table?.calendar ?? .current
        table?.setColumnFilter(NGFilterValueChoice.days(from: fromDay.dateValue, to: toDay.dateValue, calendar: calendar), forColumnID: column.id)
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSSearchField === searchField {
            showValues()
            return
        }
        applyNumbers(changed: notification.object as? NSTextField)
    }

    /// Down Arrow in the search field goes on to the values.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === searchField, selector == #selector(NSResponder.moveDown(_:)), !shownValues.isEmpty else { return false }
        view.window?.makeFirstResponder(list)
        list.selectRowIndexes([list.selectedRow >= 0 ? list.selectedRow : 0], byExtendingSelection: false)
        return true
    }

    // MARK: Values

    private func makeValuesBody() -> NSView {
        choice = table.map { NGFilterValueChoice(table: $0, columnID: column.id) }
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
        // Selected by the keyboard (Space checks or unchecks the selected values).
        list.allowsMultipleSelection = true
        list.onSpace = { [weak self] in self?.toggleSelectedValues() }
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
        shownValues = choice?.shown(matching: searchField.stringValue) ?? []
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
        button.state = choice?.checked.contains(value) == true ? .on : .off
        button.tag = row
        return button
    }

    private func updateAllBox() {
        let checked = choice?.checked ?? []
        let count = shownValues.lazy.filter { checked.contains($0.value) }.count
        allBox.state = count == 0 ? .off : count == shownValues.count ? .on : .mixed
    }

    @objc private func toggleValue(_ sender: NSButton) {
        guard shownValues.indices.contains(sender.tag) else { return }
        let value = shownValues[sender.tag].value
        choice?.set(value, checked: sender.state == .on)
        updateAllBox()
        applyValues()
    }

    /// Space in the list: the selected values all checked, or all unchecked
    /// if they were.
    private func toggleSelectedValues() {
        let selected = list.selectedRowIndexes.filter { shownValues.indices.contains($0) }.map { shownValues[$0].value }
        guard !selected.isEmpty else { return }
        let checked = choice?.checked ?? []
        let check = !selected.allSatisfy { checked.contains($0) }
        for value in selected { choice?.set(value, checked: check) }
        list.reloadData(forRowIndexes: list.selectedRowIndexes, columnIndexes: [0])
        updateAllBox()
        applyValues()
    }

    @objc private func toggleAll(_ sender: NSButton) {
        // A mixed box checks everything shown.
        let on = sender.state != .off
        sender.state = on ? .on : .off
        for (value, _) in shownValues { choice?.set(value, checked: on) }
        list.reloadData()
        applyValues()
    }

    /// The filter the checked values make.
    private func applyValues() {
        table?.setColumnFilter(choice?.filter(), forColumnID: column.id)
    }

    @objc private func clearFilter(_ sender: Any?) {
        table?.setColumnFilter(nil, forColumnID: column.id)
        table?.columnFilterPopover?.close()
    }
}
/// The filter's list of values: Space goes to the controller (the check
/// boxes of the selected values), the arrows select.
final class NGFilterValueList: NSTableView {
    var onSpace: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " ", event.modifierFlags.isDisjoint(with: [.command, .control, .option]) {
            onSpace?()
            return
        }
        super.keyDown(with: event)
    }
}

/// A plain view with its origin at the top.
final class NGFlippedView: NSView {
    override var isFlipped: Bool { true }
}
#endif
