#if os(macOS)
import AppKit

// Named views: layouts the user saves under a name and switches between, like
// a spreadsheet's or a mail app's saved views. A view is the column layout
// state (order, widths, hidden columns, pins, sort, column filters) and the
// grouping columns. Views are kept in UserDefaults under the table's
// `autosaveName` (in memory without one), and offered in the header's
// context menu with `allowsNamedViews`.

/// What a named view saves.
struct NGNamedView: Codable, Sendable, Hashable {
    var layout: NGColumnLayoutState
    /// The grouping columns, empty when not grouped.
    var grouping: [String]
    /// Whether the groups start collapsed.
    var groupsStartCollapsed = false

    init(layout: NGColumnLayoutState, grouping: [String], groupsStartCollapsed: Bool = false) {
        self.layout = layout
        self.grouping = grouping
        self.groupsStartCollapsed = groupsStartCollapsed
    }

    private enum CodingKeys: String, CodingKey { case layout, grouping, groupsStartCollapsed }

    /// Views saved before `groupsStartCollapsed` load too.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        layout = try container.decode(NGColumnLayoutState.self, forKey: .layout)
        grouping = try container.decodeIfPresent([String].self, forKey: .grouping) ?? []
        groupsStartCollapsed = try container.decodeIfPresent(Bool.self, forKey: .groupsStartCollapsed) ?? false
    }
}

extension NGTableView {
    private var namedViewsKey: String? {
        autosaveName.map { "NGTableView Views \($0)" }
    }

    /// The saved views by name, in the order they were first saved.
    private var namedViews: [(name: String, view: NGNamedView)] {
        get {
            guard let key = namedViewsKey else { return unsavedNamedViews }
            guard let data = UserDefaults.standard.data(forKey: key),
                  let entries = try? PropertyListDecoder().decode([NamedViewEntry].self, from: data) else { return [] }
            return entries.map { ($0.name, $0.view) }
        }
        set {
            guard let key = namedViewsKey else {
                unsavedNamedViews = newValue
                return
            }
            // Views this version can't read (saved by another one) are kept
            // aside, not overwritten by the ones it can.
            if let data = UserDefaults.standard.data(forKey: key), (try? PropertyListDecoder().decode([NamedViewEntry].self, from: data)) == nil {
                UserDefaults.standard.set(data, forKey: key + " (unreadable)")
            }
            let entries = newValue.map { NamedViewEntry(name: $0.name, view: $0.view) }
            if let data = try? PropertyListEncoder().encode(entries) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }

    private struct NamedViewEntry: Codable {
        var name: String
        var view: NGNamedView
    }

    /// The names of the saved views, in the order they were first saved.
    public var savedViewNames: [String] {
        namedViews.map(\.name)
    }

    /// Saves the current columns, sort, column filters and grouping as a view
    /// (replacing a view of the same name).
    public func saveView(named name: String) {
        let view = NGNamedView(layout: columnLayoutState, grouping: rowGrouping?.columnIDs ?? [],
                               groupsStartCollapsed: rowGrouping?.startsCollapsed ?? false)
        var views = namedViews
        if let index = views.firstIndex(where: { $0.name == name }) {
            views[index].view = view
        } else {
            views.append((name, view))
        }
        namedViews = views
        currentViewName = name
    }

    /// Shows a saved view: its columns, sort, column filters and grouping.
    /// The delegate hears of what changed, as when the user changes it.
    /// Returns `false` if there's no view of that name.
    @discardableResult
    public func applyView(named name: String) -> Bool {
        guard let view = namedViews.first(where: { $0.name == name })?.view else { return false }
        let before = (columns: columns, hidden: hiddenColumnIDs, filters: columnFilters, grouping: rowGrouping)
        columnLayoutState = view.layout
        if view.layout.filters == nil { columnFilters = [:] }
        let grouping = view.grouping.filter { id in tableColumns.contains { $0.id == id } }
        // The same columns: the grouping stays as it is (options, collapsed groups).
        if grouping != (rowGrouping?.columnIDs ?? []) {
            rowGrouping = regrouped(by: grouping, startsCollapsed: view.groupsStartCollapsed)
        }
        autosaveLayoutState()
        currentViewName = name
        if columns != before.columns { delegate?.tableView(self, didReorderColumns: columns) }
        if hiddenColumnIDs != before.hidden { delegate?.tableView(self, didChangeHiddenColumns: hiddenColumnIDs) }
        if columnFilters != before.filters { delegate?.tableView(self, didChangeColumnFilters: columnFilters) }
        if rowGrouping != before.grouping { delegate?.tableView(self, didChangeRowGrouping: rowGrouping) }
        return true
    }

    /// A grouping by other columns with the current one's options (the
    /// app's, like `showsRowCount`), `nil` for none.
    func regrouped(by columnIDs: [String], startsCollapsed: Bool? = nil) -> NGRowGrouping? {
        guard !columnIDs.isEmpty else { return nil }
        var grouping = rowGrouping ?? NGRowGrouping(columnIDs: columnIDs)
        grouping.columnIDs = columnIDs
        if let startsCollapsed { grouping.startsCollapsed = startsCollapsed }
        return grouping
    }

    /// Deletes a saved view.
    public func removeView(named name: String) {
        namedViews = namedViews.filter { $0.name != name }
        if currentViewName == name { currentViewName = nil }
    }

    // MARK: Header menu

    /// The "Views" submenu of the header's context menu.
    func namedViewsMenuItem() -> NSMenuItem? {
        guard allowsNamedViews else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for name in savedViewNames {
            let item = NSMenuItem(title: name, action: #selector(applyNamedView(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            item.state = name == currentViewName ? .on : .off
            menu.addItem(item)
        }
        if !savedViewNames.isEmpty { menu.addItem(.separator()) }
        let save = NSMenuItem(title: String(localized: "Save View…", bundle: .module, comment: "Header menu: saves the columns as a named view."),
                              action: #selector(saveNamedView(_:)), keyEquivalent: "")
        save.target = self
        menu.addItem(save)
        if !savedViewNames.isEmpty {
            let delete = NSMenu()
            for name in savedViewNames {
                let item = NSMenuItem(title: name, action: #selector(removeNamedView(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = name
                delete.addItem(item)
            }
            let deleteItem = NSMenuItem(title: String(localized: "Delete View", bundle: .module, comment: "Header menu: deletes a named view."),
                                        action: nil, keyEquivalent: "")
            deleteItem.submenu = delete
            menu.addItem(deleteItem)
        }
        let item = NSMenuItem(title: String(localized: "Views", bundle: .module, comment: "Header menu: the named views."),
                              action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    @objc private func applyNamedView(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        applyView(named: name)
    }

    @objc private func removeNamedView(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        removeView(named: name)
    }

    /// Asks for a name, then saves the view.
    @objc private func saveNamedView(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Save View", bundle: .module, comment: "Save view dialog: title.")
        alert.informativeText = String(localized: "The columns, sort, filters and grouping are saved under this name.",
                                       bundle: .module, comment: "Save view dialog: what is saved.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = currentViewName ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Save", bundle: .module, comment: "Save view dialog: the default button."))
        alert.addButton(withTitle: String(localized: "Cancel", bundle: .module, comment: "Save view dialog: cancels."))
        alert.window.initialFirstResponder = field
        let save = { [weak self, weak field] (response: NSApplication.ModalResponse) in
            guard response == .alertFirstButtonReturn,
                  let name = field?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return }
            self?.saveView(named: name)
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: save)
        } else {
            save(alert.runModal())
        }
    }
}
#endif
