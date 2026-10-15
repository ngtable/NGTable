#if os(iOS)
import UIKit

// A column's filter on the iPad, in a popover at its title (from the header
// menu's Filter item, or the filter button a filtered column shows): number
// columns take a range or the top or bottom rows by count, date columns a
// period, other columns their values checked, narrowed by a search field.
// Changes apply as they're made, like the Mac's popover (both edit an
// NGFilterValueChoice and the table's filters); Clear Filter shows every
// row again.

@MainActor
final class NGColumnFilterController: UITableViewController, UISearchBarDelegate, UITextFieldDelegate {
    private weak var table: NGTableView?
    private let column: NGTableColumn
    private enum Kind { case values, numbers, dates }
    private let kind: Kind
    /// Value filters.
    private var choice: NGFilterValueChoice?
    private var shownValues: [(value: String, count: Int)] = []
    private let searchBar = UISearchBar()
    /// Number filters: the mode (range, top, bottom) and the fields.
    private let numberMode = UISegmentedControl(items: [
        String(localized: "Range", bundle: .module, comment: "Column filter: numbers between two bounds."),
        String(localized: "Top", bundle: .module, comment: "Column filter: the rows with the largest numbers."),
        String(localized: "Bottom", bundle: .module, comment: "Column filter: the rows with the smallest numbers."),
    ])
    let minField = UITextField()
    let maxField = UITextField()
    let countField = UITextField()
    /// Date filters: the period chosen, and the two days of the last one.
    private var periodIndex = 0
    private let fromDay = UIDatePicker()
    private let toDay = UIDatePicker()
    private let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.isLenient = true
        formatter.maximumFractionDigits = 12
        return formatter
    }()

    init(table: NGTableView, column: NGTableColumn) {
        self.table = table
        self.column = column
        kind = column.format.isDate ? .dates : column.isNumeric ? .numbers : .values
        super.init(style: .insetGrouped)
        title = column.menuTitle
        numberFormatter.locale = table.formattingLocale
        switch kind {
        case .values:
            choice = NGFilterValueChoice(table: table, columnID: column.id)
            shownValues = choice?.values ?? []
        case .numbers:
            setUpNumbers(table.columnFilters[column.id])
        case .dates:
            setUpDates(table.columnFilters[column.id], calendar: table.calendar)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("made in code") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        if kind == .values {
            searchBar.placeholder = String(localized: "Search", bundle: .module, comment: "Column filter: narrows the list of values.")
            searchBar.delegate = self
            searchBar.searchBarStyle = .minimal
            searchBar.sizeToFit()
            tableView.tableHeaderView = searchBar
        }
        preferredContentSize = CGSize(width: 320, height: kind == .values ? 480 : 320)
    }

    // MARK: Numbers

    private func setUpNumbers(_ filter: NGColumnFilter?) {
        let scale: Double = if case .percent = column.format { 100 } else { 1 }
        for (field, placeholder) in [(minField, String(localized: "From", bundle: .module, comment: "Column filter: the smallest number shown.")),
                                     (maxField, String(localized: "To", bundle: .module, comment: "Column filter: the largest number shown.")),
                                     (countField, "10")] {
            field.placeholder = placeholder
            field.keyboardType = .numbersAndPunctuation
            field.clearButtonMode = .whileEditing
            field.delegate = self
            field.addTarget(self, action: #selector(numbersChanged(_:)), for: .editingChanged)
        }
        countField.text = "10"
        numberMode.selectedSegmentIndex = 0
        switch filter {
        case .range(let min, let max)?:
            minField.text = min.flatMap { numberFormatter.string(from: NSNumber(value: $0 * scale)) }
            maxField.text = max.flatMap { numberFormatter.string(from: NSNumber(value: $0 * scale)) }
        case .top(let count)?:
            numberMode.selectedSegmentIndex = 1
            countField.text = "\(count)"
        case .bottom(let count)?:
            numberMode.selectedSegmentIndex = 2
            countField.text = "\(count)"
        default:
            break
        }
        numberMode.addTarget(self, action: #selector(numberModeChanged), for: .valueChanged)
    }

    @objc private func numberModeChanged() {
        tableView.reloadData()
        applyNumbers(changed: nil)
    }

    @objc private func numbersChanged(_ field: UITextField) {
        applyNumbers(changed: field)
    }

    /// The range, or the top or bottom rows by the count typed.
    func applyNumbers(changed field: UITextField?) {
        guard let table else { return }
        if numberMode.selectedSegmentIndex > 0 {
            let count = max(0, Int((countField.text ?? "").trimmingCharacters(in: .whitespaces)) ?? 10)
            table.setColumnFilter(numberMode.selectedSegmentIndex == 1 ? .top(count) : .bottom(count), forColumnID: column.id)
            return
        }
        func bound(_ field: UITextField) -> Double? {
            NGFilterValueChoice.bound(field.text ?? "", format: column.format, formatter: numberFormatter)
        }
        // Only the field being typed in changes its bound (the other keeps its exact value).
        var (min, max) = (bound(minField), bound(maxField))
        if case .range(let oldMin, let oldMax) = table.columnFilters[column.id] {
            if field === maxField { min = oldMin }
            if field === minField { max = oldMax }
        }
        table.setColumnFilter(.range(min: min, max: max), forColumnID: column.id)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    // MARK: Dates

    private func setUpDates(_ filter: NGColumnFilter?, calendar: Calendar) {
        for picker in [fromDay, toDay] {
            picker.datePickerMode = .date
            picker.preferredDatePickerStyle = .compact
            picker.calendar = calendar
            picker.timeZone = calendar.timeZone
            picker.date = Date()
            picker.addTarget(self, action: #selector(daysChanged), for: .valueChanged)
        }
        guard case .dates(let period)? = filter else { return }
        if case .between(let start, let end) = period {
            periodIndex = NGFilterValueChoice.periods.count - 1
            if let start { fromDay.date = start }
            // The last day shown: the one before the end.
            if let end { toDay.date = calendar.date(byAdding: .day, value: -1, to: end) ?? end }
        } else if let index = NGFilterValueChoice.periods.firstIndex(where: { $0.period == period }) {
            periodIndex = index
        }
    }

    private var isBetween: Bool { periodIndex == NGFilterValueChoice.periods.count - 1 }

    func choosePeriod(_ index: Int) {
        periodIndex = index
        tableView.reloadData()
        if isBetween { return daysChanged() }
        table?.setColumnFilter(NGFilterValueChoice.periods[index].period.map { .dates($0) }, forColumnID: column.id)
    }

    @objc private func daysChanged() {
        guard let table else { return }
        table.setColumnFilter(NGFilterValueChoice.days(from: fromDay.date, to: toDay.date, calendar: table.calendar), forColumnID: column.id)
    }

    // MARK: Values

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        shownValues = choice?.shown(matching: searchText) ?? []
        tableView.reloadData()
    }

    /// Checks or unchecks a value shown, or (`nil`) every value shown.
    func toggle(_ index: Int?) {
        guard var choice else { return }
        if let index, shownValues.indices.contains(index) {
            let value = shownValues[index].value
            choice.set(value, checked: !choice.checked.contains(value))
        } else {
            let checkAll = !shownValues.allSatisfy { choice.checked.contains($0.value) }
            for (value, _) in shownValues { choice.set(value, checked: checkAll) }
        }
        let filter = choice.filter()
        self.choice = choice
        table?.setColumnFilter(filter, forColumnID: column.id)
        tableView.reloadData()
    }

    // MARK: The list

    /// The sections: the editor's, then Clear Filter.
    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard section == 0 else { return 1 }
        switch kind {
        case .values: return shownValues.count + 1
        case .numbers: return numberMode.selectedSegmentIndex == 0 ? 3 : 2
        case .dates: return NGFilterValueChoice.periods.count + (isBetween ? 2 : 0)
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        if indexPath.section == 1 {
            cell.textLabel?.text = String(localized: "Clear Filter", bundle: .module, comment: "Column filter: shows every row again.")
            cell.textLabel?.textColor = .systemRed
            return cell
        }
        switch kind {
        case .values:
            let checked = choice?.checked ?? []
            if indexPath.row == 0 {
                cell.textLabel?.text = String(localized: "Select All", bundle: .module, comment: "Column filter: checks every value.")
                let count = shownValues.lazy.filter { checked.contains($0.value) }.count
                cell.accessoryType = count == shownValues.count && count > 0 ? .checkmark : .none
                cell.detailTextLabel?.text = count > 0 && count < shownValues.count ? "–" : nil
            } else {
                let (value, count) = shownValues[indexPath.row - 1]
                let noValue = String(localized: "No Value", bundle: .module, comment: "Group header for rows without a value in the grouping column.")
                cell.textLabel?.text = value.isEmpty ? noValue : value
                cell.detailTextLabel?.text = count.formatted(.number.locale(table?.formattingLocale ?? .current))
                cell.accessoryType = checked.contains(value) ? .checkmark : .none
            }
        case .numbers:
            let control: UIView = switch indexPath.row {
            case 0: numberMode
            case 1: numberMode.selectedSegmentIndex == 0 ? minField : countField
            default: maxField
            }
            embed(control, in: cell)
            cell.selectionStyle = .none
        case .dates:
            if indexPath.row < NGFilterValueChoice.periods.count {
                cell.textLabel?.text = NGFilterValueChoice.periods[indexPath.row].title
                cell.accessoryType = indexPath.row == periodIndex ? .checkmark : .none
            } else {
                let isFirst = indexPath.row == NGFilterValueChoice.periods.count
                cell.textLabel?.text = isFirst ? String(localized: "From", bundle: .module, comment: "Column filter: the smallest number shown.")
                    : String(localized: "To", bundle: .module, comment: "Column filter: the largest number shown.")
                cell.accessoryView = isFirst ? fromDay : toDay
                cell.selectionStyle = .none
            }
        }
        return cell
    }

    private func embed(_ control: UIView, in cell: UITableViewCell) {
        control.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            control.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            control.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor),
            cell.contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 1 {
            table?.setColumnFilter(nil, forColumnID: column.id)
            dismiss(animated: true)
            return
        }
        switch kind {
        case .values: toggle(indexPath.row == 0 ? nil : indexPath.row - 1)
        case .dates where indexPath.row < NGFilterValueChoice.periods.count: choosePeriod(indexPath.row)
        default: break
        }
    }
}

extension NGTableView {
    /// Opens the filter of a column in a popover at its title.
    func showColumnFilter(for column: NGTableColumn, relativeTo rect: CGRect, of view: NGPlatformView) {
        guard let presenter = nearestViewController else { return }
        let controller = NGColumnFilterController(table: self, column: column)
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .popover
        navigation.popoverPresentationController?.sourceView = view
        navigation.popoverPresentationController?.sourceRect = rect
        if let showForTesting = Self.columnFilterShownForTesting {
            showForTesting(controller)
            return
        }
        presenter.present(navigation, animated: true)
    }
}
#endif
