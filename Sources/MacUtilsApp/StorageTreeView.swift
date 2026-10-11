import AppKit
import MacUtilsCore
import SwiftUI

/// Native disclosure rows backed by explicitly paged, saved metadata.
struct StorageTreeView: NSViewRepresentable {
    @ObservedObject var model: StorageModel
    let snapshotID: UUID
    let text: AppText

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        let outline = NSOutlineView()
        outline.rowHeight = 25
        outline.usesAlternatingRowBackgroundColors = true
        outline.allowsMultipleSelection = true
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        for (name, width) in [("name", 300.0), ("logical", 110.0), ("allocated", 110.0), ("share", 90.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(name))
            column.width = width; column.minWidth = name == "name" ? 180 : 70
            outline.addTableColumn(column)
        }
        outline.outlineTableColumn = outline.tableColumns.first
        outline.autoresizesOutlineColumn = false
        outline.dataSource = context.coordinator; outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.doubleAction = #selector(Coordinator.doubleClick(_:))
        outline.setAccessibilityIdentifier("storage-items")
        scroll.documentView = outline
        context.coordinator.outline = outline
        context.coordinator.update(snapshotID: snapshotID, text: text)
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.update(snapshotID: snapshotID, text: text)
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        private final class Item: NSObject {
            let id: Int
            let isMore: Bool
            init(id: Int, isMore: Bool = false) { self.id = id; self.isMore = isMore }
        }
        private struct PageState: Equatable {
            let parent: Int; let count: Int; let total: Int; let first: Int?; let last: Int?
        }
        let model: StorageModel
        weak var outline: NSOutlineView?
        private var snapshotID: UUID?
        private var text = AppText(language: .system)
        private var items: [String: Item] = [:]
        private var pages: [PageState] = []
        private var mode: StorageBrowserMode?
        private var metric: StorageSizeMetric?
        private var descending: Bool?
        private var language: AppLanguage?
        private var largestIDs: [Int] = []
        private var selectedIDs: Set<Int> = []
        private var synchronizing = false

        init(model: StorageModel) { self.model = model }

        private func item(_ id: Int, more: Bool = false) -> Item {
            let key = "\(more ? "more" : "node").\(id)"
            if let existing = items[key] { return existing }
            let value = Item(id: id, isMore: more); items[key] = value
            return value
        }

        func update(snapshotID: UUID, text: AppText) {
            guard let outline else { return }
            let nextPages = model.childPages.map { parent, page in
                PageState(parent: parent, count: page.rows.count, total: page.totalCount,
                    first: page.rows.first?.id, last: page.rows.last?.id)
            }.sorted { $0.parent < $1.parent }
            let nextLargest = model.browserMode == .largestFiles ? model.visibleNodes.map(\.id) : []
            let selectionChanged = selectedIDs != model.selection
            selectedIDs = model.selection
            let changed = self.snapshotID != snapshotID || pages != nextPages || mode != model.browserMode
                || metric != model.metric || descending != model.sortDescending || language != text.language
                || largestIDs != nextLargest
            synchronizing = true
            defer { synchronizing = false }
            if self.snapshotID != snapshotID { items = [:] }
            self.snapshotID = snapshotID; self.text = text
            pages = nextPages; mode = model.browserMode; metric = model.metric
            descending = model.sortDescending; language = text.language; largestIDs = nextLargest
            let titles = ["storage.name", "storage.logical", "storage.allocated", "storage.tree.share"]
            for (column, key) in zip(outline.tableColumns, titles) {
                column.title = text(key)
                column.headerToolTip = text(key == "storage.tree.share" ? "storage.tree.share.help"
                    : key == "storage.name" ? "storage.tree.help" : key + ".help")
            }
            outline.setAccessibilityHelp(text("storage.tree.help"))
            if changed { outline.reloadData() }
            if model.browserMode == .hierarchy {
                // Parents are retained in the model; expanding only loaded branches avoids
                // recursively creating objects for every indexed item on the disk.
                for id in model.expandedIDs.sorted(by: { depth($0) < depth($1) }) where model.childPages[id] != nil {
                    outline.expandItem(item(id), expandChildren: false)
                }
                for value in items.values where !value.isMore && !model.expandedIDs.contains(value.id) {
                    if outline.isItemExpanded(value) { outline.collapseItem(value, collapseChildren: false) }
                }
            }
            var indexes = IndexSet()
            for id in model.selection {
                let row = outline.row(forItem: item(id))
                if row >= 0 { indexes.insert(row) }
            }
            if outline.selectedRowIndexes != indexes { outline.selectRowIndexes(indexes, byExtendingSelection: false) }
            if selectionChanged, let selected = indexes.first {
                outline.scrollRowToVisible(selected)
            }
        }

        private func depth(_ id: Int) -> Int {
            var depth = 0; var current = model.row(id: id); var seen = Set<Int>()
            while let row = current, let parent = row.parentID, seen.insert(row.id).inserted {
                depth += 1; current = model.row(id: parent)
            }
            return depth
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem object: Any?) -> Int {
            if model.browserMode == .largestFiles { return object == nil ? model.visibleNodes.count : 0 }
            guard let object = object as? Item else { return model.rootRow == nil ? 0 : 1 }
            guard !object.isMore else { return 0 }
            return model.children(of: object.id).count + (model.hasMoreChildren(of: object.id) ? 1 : 0)
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem object: Any?) -> Any {
            if model.browserMode == .largestFiles { return item(model.visibleNodes[index].id) }
            guard let object = object as? Item else { return item(0) }
            let children = model.children(of: object.id)
            return index < children.count ? item(children[index].id) : item(object.id, more: true)
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable object: Any) -> Bool {
            guard model.browserMode == .hierarchy, !model.treeUnavailable,
                  let object = object as? Item, !object.isMore else { return false }
            return model.row(id: object.id)?.isExpandable == true
        }

        func outlineView(_ outlineView: NSOutlineView, shouldExpandItem object: Any) -> Bool {
            guard let object = object as? Item, !object.isMore, let snapshotID else { return false }
            if model.childPages[object.id] != nil { return true }
            if !synchronizing {
                Task { @MainActor [weak self] in self?.model.expandFolder(object.id, in: snapshotID) }
            }
            return false
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard !synchronizing, let object = notification.userInfo?["NSObject"] as? Item, let snapshotID else { return }
            Task { @MainActor [weak self] in self?.model.expandFolder(object.id, in: snapshotID) }
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !synchronizing, let object = notification.userInfo?["NSObject"] as? Item, let snapshotID else { return }
            Task { @MainActor [weak self] in self?.model.collapseFolder(object.id, in: snapshotID) }
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem object: Any) -> Bool {
            (object as? Item)?.isMore == false
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !synchronizing, let outline, let snapshotID else { return }
            let ids = Set(outline.selectedRowIndexes.compactMap { index -> Int? in
                guard let value = outline.item(atRow: index) as? Item, !value.isMore else { return nil }
                return value.id
            })
            Task { @MainActor [weak self] in self?.model.selectItems(ids, in: snapshotID) }
        }

        @objc func doubleClick(_ sender: NSOutlineView) {
            guard sender.clickedRow >= 0, let object = sender.item(atRow: sender.clickedRow) as? Item,
                  let snapshotID else { return }
            if object.isMore { model.loadMoreChildren(of: object.id, in: snapshotID) }
            else { model.openFolder(object.id, in: snapshotID) }
        }

        @objc private func more(_ sender: NSButton) {
            guard let snapshotID else { return }
            model.loadMoreChildren(of: sender.tag, in: snapshotID)
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor column: NSTableColumn?, item object: Any) -> NSView? {
            guard let object = object as? Item, let column else { return nil }
            if object.isMore {
                guard column.identifier.rawValue == "name" else { return nil }
                let identifier = NSUserInterfaceItemIdentifier("more")
                let button = (outlineView.makeView(withIdentifier: identifier, owner: self) as? NSButton)
                    ?? NSButton(title: "", target: self, action: #selector(more(_:)))
                button.identifier = identifier
                // The stable parent is carried separately from the reusable cell identifier.
                button.target = self; button.action = #selector(more(_:))
                button.title = text.format("storage.tree.more", max(0,
                    (model.childPages[object.id]?.totalCount ?? 0) - model.children(of: object.id).count))
                button.toolTip = text("storage.tree.more.help")
                button.setAccessibilityHelp(text("storage.tree.more.help"))
                button.tag = object.id
                button.isEnabled = !model.loadingChildren.contains(object.id)
                return button
            }
            guard let row = model.row(id: object.id) else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("cell.\(column.identifier.rawValue)")
            let cell = (outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? makeCell(name: column.identifier.rawValue == "name")
            cell.identifier = identifier
            let value: String
            switch column.identifier.rawValue {
            case "name":
                let name = row.id == 0 ? model.selectedVolume?.name ?? row.name : row.name
                value = name + (row.isIncomplete ? " ⚠︎" : "") + (row.isCloudPlaceholder ? " ☁︎" : "")
            case "logical": value = StorageFormatting.bytes(row.totals.logicalBytes, text: text)
            case "allocated": value = StorageFormatting.bytes(row.totals.allocatedBytes, text: text)
            default:
                let total = model.snapshot?.root?.bytes(for: model.metric) ?? 0
                value = total > 0 ? (Double(row.bytes(for: model.metric)) / Double(total))
                    .formatted(.percent.locale(Locale(identifier: text.language.resourceCode)).precision(.fractionLength(1))) : "—"
            }
            cell.textField?.stringValue = value
            cell.imageView?.image = NSImage(systemSymbolName: StorageFormatting.symbol(row.kind), accessibilityDescription: nil)
            cell.toolTip = model.displayPath(for: row.id) + "\n" + text("storage.tree.help")
            if row.isIncomplete { cell.toolTip = (cell.toolTip ?? "") + "\n" + text("storage.incomplete.help") }
            if row.isCloudPlaceholder { cell.toolTip = (cell.toolTip ?? "") + "\n" + text("storage.cloud") }
            if row.isInsidePackage { cell.toolTip = (cell.toolTip ?? "") + "\n" + text("storage.tree.packageProtected") }
            cell.setAccessibilityHelp(cell.toolTip)
            return cell
        }

        private func makeCell(name: Bool) -> NSTableCellView {
            let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: 250, height: 25))
            let label = NSTextField(labelWithString: "")
            label.frame = NSRect(x: name ? 23 : 2, y: 4, width: name ? 225 : 246, height: 18)
            label.autoresizingMask = [.width]
            label.lineBreakMode = .byTruncatingMiddle
            label.alignment = name ? .left : .right
            if !name { label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular) }
            cell.textField = label; cell.addSubview(label)
            if name {
                let image = NSImageView(frame: NSRect(x: 2, y: 4, width: 16, height: 16))
                cell.imageView = image; cell.addSubview(image)
            }
            return cell
        }
    }
}
