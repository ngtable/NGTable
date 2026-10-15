#if os(iOS)
import UIKit

// Context menus on the iPad (a long press, or a secondary click with a
// pointer), the Mac's right-click menus as UIMenus:
// - rows: the delegate's menu, for the selection when the pressed row is in
//   it, otherwise for the pressed row, outlined while the menu is open;
// - a group header: collapse or expand it, or all groups;
// - a column's title: sort, the saved views, pinning, grouping, and the
//   columns to show (a tap sorts; there is no right-click on a finger);
// - the summary row: which rows it sums.

extension NGTableView {
    /// What a press at a point of the table opens, `nil` for nothing.
    func contextMenu(at point: CGPoint) -> UIMenu? {
        guard !ignoresUserInput, !isEditingCell, numberOfRows > 0 || point.y < layoutMetrics.headerHeight else { return nil }
        if point.y < layoutMetrics.headerHeight {
            return hidesHeader ? nil : headerMenu(at: point)
        }
        if showsSummaryBar, point.y >= bounds.height - layoutMetrics.summaryHeight {
            return summaryScopeMenu()
        }
        let location = convert(point, to: nil)
        let row = row(atWindowLocation: location)
        if let node = groupNode(atDisplayRow: row) {
            clickedRow = -1
            clickedColumn = -1
            return groupMenu(forNode: node)
        }
        let clicked = row >= 0 && row < numberOfRows ? row : nil
        let rows: IndexSet = clicked.map { displaySelection.contains($0) ? displaySelection : [$0] } ?? []
        let sourceClicked = clicked.map(sourceRow)
        let columnID = columnID(atWindowLocation: location)
        let column = columnID.flatMap { columnLayout.columnsByID[$0] }
        clickedRow = sourceClicked ?? -1
        clickedColumn = columnID.flatMap { id in tableColumns.firstIndex { $0.id == id } } ?? -1
        guard let menu = delegate?.tableView(self, menuForRows: IndexSet(rows.map(sourceRow)), clickedRow: sourceClicked,
                                             column: clicked == nil ? nil : column) else { return nil }
        if let clicked, !displaySelection.contains(clicked) { showMenuOutline(forRow: clicked) }
        return menu
    }

    /// The menu of a column's title.
    func headerMenu(at point: CGPoint) -> UIMenu? {
        guard !columns.isEmpty else { return nil }
        var sections: [UIMenuElement] = []
        if let column = column(atViewportPoint: point)?.frame.column, column.isSortable, let prototype = column.sortDescriptorPrototype {
            let current = sortDescriptors.first?.key == prototype.key ? sortDescriptors.first?.ascending : nil
            let ascending = UIAction(title: String(localized: "Sort Ascending", bundle: .module, comment: "Header menu on the iPad: sorts by the column."),
                                     image: UIImage(systemName: "arrow.up"), state: current == true ? .on : .off) { [weak self] _ in
                self?.sort(by: column, ascending: true)
            }
            let descending = UIAction(title: String(localized: "Sort Descending", bundle: .module, comment: "Header menu on the iPad: sorts by the column."),
                                      image: UIImage(systemName: "arrow.down"), state: current == false ? .on : .off) { [weak self] _ in
                self?.sort(by: column, ascending: false)
            }
            sections.append(UIMenu(options: .displayInline, children: [ascending, descending]))
        }
        if let views = namedViewsMenu() { sections.append(views) }
        if let (itemID, choices) = pinChoices(at: point) {
            sections.append(UIMenu(options: .displayInline, children: choices.map { choice in
                UIAction(title: choice.title) { [weak self] _ in self?.setPin(choice.pin, forItemID: itemID) }
            }))
        }
        let grouping = groupingChoices(at: point)
        if !grouping.isEmpty {
            sections.append(UIMenu(options: .displayInline, children: grouping.map { choice in
                UIAction(title: choice.title) { [weak self] _ in self?.setRowGrouping(choice.columnIDs) }
            }))
        }
        if allowsColumnHiding {
            let entries = columnVisibilityEntries().map { entry in
                UIAction(title: entry.indentation > 0 ? "    " + entry.title : entry.title,
                         attributes: entry.isEnabled ? [.keepsMenuPresented] : [.disabled, .keepsMenuPresented],
                         state: entry.state == .visible ? .on : entry.state == .partiallyVisible ? .mixed : .off) { [weak self] _ in
                    self?.toggleColumnVisibility(id: entry.id)
                }
            }
            sections.append(UIMenu(title: String(localized: "Columns", bundle: .module, comment: "Header menu on the iPad: the columns to show."),
                                   image: UIImage(systemName: "tablecells"), children: entries))
        }
        return sections.isEmpty ? nil : UIMenu(children: sections)
    }

    /// Sorts by a column from the header menu, as the user.
    func sort(by column: NGTableColumn, ascending: Bool) {
        guard let prototype = column.sortDescriptorPrototype, let key = prototype.key else { return }
        let descriptor = NSSortDescriptor(key: key, ascending: ascending, selector: prototype.selector)
        isSortingByClick = true
        sortDescriptors = [descriptor] + sortDescriptors.filter { $0.key != key }
        isSortingByClick = false
        sortReversedByUser = nil
    }

    /// The saved views: apply one, save the columns as one, delete one.
    private func namedViewsMenu() -> UIMenu? {
        guard allowsNamedViews else { return nil }
        var children: [UIMenuElement] = savedViewNames.map { name in
            UIAction(title: name, state: name == currentViewName ? .on : .off) { [weak self] _ in self?.applyView(named: name) }
        }
        children.append(UIAction(title: String(localized: "Save View…", bundle: .module, comment: "Header menu: saves the columns as a named view."),
                                 image: UIImage(systemName: "square.and.arrow.down")) { [weak self] _ in self?.askToSaveView() })
        if !savedViewNames.isEmpty {
            children.append(UIMenu(title: String(localized: "Delete View", bundle: .module, comment: "Header menu: deletes a named view."),
                                   image: UIImage(systemName: "trash"), options: .destructive, children: savedViewNames.map { name in
                UIAction(title: name, attributes: .destructive) { [weak self] _ in self?.removeView(named: name) }
            }))
        }
        return UIMenu(title: String(localized: "Views", bundle: .module, comment: "Header menu: the named views."),
                      image: UIImage(systemName: "rectangle.stack"), children: children)
    }

    /// Asks for a name (an alert over the table's view controller), then saves the view.
    private func askToSaveView() {
        guard let presenter = nearestViewController else { return }
        let alert = UIAlertController(title: String(localized: "Save View", bundle: .module, comment: "Save view dialog: title."),
                                      message: String(localized: "The columns, sort, filters and grouping are saved under this name.",
                                                      bundle: .module, comment: "Save view dialog: what is saved."),
                                      preferredStyle: .alert)
        alert.addTextField { [currentViewName] field in field.text = currentViewName }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel", bundle: .module, comment: "Save view dialog: cancels."), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Save", bundle: .module, comment: "Save view dialog: the default button."),
                                      style: .default) { [weak self, weak alert] _ in
            let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespaces) ?? ""
            if !name.isEmpty { self?.saveView(named: name) }
        })
        presenter.present(alert, animated: true)
    }

    /// The view controller whose view the table is in.
    var nearestViewController: UIViewController? {
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let controller = next as? UIViewController { return controller }
            responder = next
        }
        return nil
    }

    /// Which rows the summary row sums.
    func summaryScopeMenu() -> UIMenu {
        UIMenu(children: NGSummaryScope.allCases.map { scope in
            UIAction(title: summaryScopeTitles[scope] ?? "\(scope)", state: scope == summaryScope ? .on : .off) { [weak self] _ in
                self?.setSummaryScopeByUser(scope)
            }
        })
    }

    /// A group header's menu.
    func groupMenu(forNode index: Int) -> UIMenu {
        let group = groupTree.nodes[index].group
        let expanded = isGroupExpanded(group)
        let toggle = UIAction(title: expanded
                                ? String(localized: "Collapse Group", bundle: .module, comment: "Group header context menu.")
                                : String(localized: "Expand Group", bundle: .module, comment: "Group header context menu.")) { [weak self] _ in
            if expanded { self?.collapseGroup(group) } else { self?.expandGroup(group) }
        }
        let collapseAll = UIAction(title: String(localized: "Collapse All Groups", bundle: .module, comment: "Group header context menu.")) { [weak self] _ in
            self?.collapseGroup(nil, collapseChildren: true)
        }
        let expandAll = UIAction(title: String(localized: "Expand All Groups", bundle: .module, comment: "Group header context menu.")) { [weak self] _ in
            self?.expandGroup(nil, expandChildren: true)
        }
        return UIMenu(children: [toggle, UIMenu(options: .displayInline, children: [collapseAll, expandAll])])
    }

    /// What lifts with the menu: the pressed row, the column's title or the
    /// summary row (a snapshot of it).
    func contextMenuPreview(at point: CGPoint) -> UITargetedPreview? {
        let metrics = layoutMetrics
        var rect: CGRect
        if point.y < metrics.headerHeight {
            guard let (frame, pin) = column(atViewportPoint: point) else { return nil }
            rect = CGRect(x: viewport.origin(of: pin) + CGFloat(frame.x), y: 0, width: CGFloat(frame.width), height: metrics.headerHeight)
        } else if showsSummaryBar, point.y >= bounds.height - metrics.summaryHeight {
            rect = summaryBar.frame
        } else {
            let row = row(atWindowLocation: convert(point, to: nil))
            guard row >= 0, row < numberOfRows else { return nil }
            rect = CGRect(x: 0, y: pixelAligned(metrics.headerHeight - renderedOffsetY) + rowGeometry.top(of: row),
                          width: bounds.width, height: rowGeometry.height(of: row))
        }
        rect = rect.intersection(bounds)
        guard !rect.isEmpty, let snapshot = resizableSnapshotView(from: rect, afterScreenUpdates: false, withCapInsets: .zero) else { return nil }
        // Only what lifts, where it is: a snapshot of the whole table, cut,
        // would be placed by its whole size (away from the finger).
        let parameters = UIPreviewParameters()
        parameters.visiblePath = UIBezierPath(roundedRect: CGRect(origin: .zero, size: rect.size), cornerRadius: 6)
        parameters.backgroundColor = metalStyle.background
        return UITargetedPreview(view: snapshot, parameters: parameters, target: UIPreviewTarget(container: self, center: CGPoint(x: rect.midX, y: rect.midY)))
    }
}

extension NGTouchScrollDelegate: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let table, let menu = table.contextMenu(at: location) else { return nil }
        menuLocation = location
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration,
                                highlightPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        guard let table, let menuLocation else { return nil }
        return table.contextMenuPreview(at: menuLocation)
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willEndFor configuration: UIContextMenuConfiguration,
                                animator: (any UIContextMenuInteractionAnimating)?) {
        menuLocation = nil
        if let animator {
            animator.addCompletion { [weak self] in self?.table?.rowsMenuDidClose() }
        } else {
            table?.rowsMenuDidClose()
        }
    }
}
#endif
