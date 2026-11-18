import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension NSPasteboard.PasteboardType {
    /// Server path when dragging from the right column (FileHub internal only).
    static let fileHubRemote = NSPasteboard.PasteboardType("local.filehub.remote-path")
}

enum DropPayload {
    case local([URL])
    case remote([String])
}

/// An entry of a list's context menu; nil entries in a menu are separators.
struct FileMenuItem {
    let title: String
    let symbol: String
    var enabled = true
    let action: @MainActor () -> Void
}

/// File list based on NSTableView: multiple selection, sorting, dragging several rows, dropping
/// on the list (current folder) or on a folder row (into that folder). The Mac side provides file
/// URLs (Finder can drag into the server column too); the server side provides server paths that
/// only the Mac list accepts.
struct FileTable: NSViewRepresentable {
    let side: Pane
    let rows: [FileRow]
    @Binding var selection: Set<String>
    var dropEnabled: Bool
    var onOpen: (FileRow) -> Void
    var onDrop: (DropPayload, FileRow?) -> Void
    var onDelete: (() -> Void)?
    var onFocus: () -> Void = {}
    /// Context menu for the rows it applies to (the clicked row joins or replaces the selection
    /// like in the Finder); empty for a click on free space.
    var menu: ([FileRow]) -> [FileMenuItem?] = { _ in [] }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> FileScrollView {
        let table = FileTableView()
        table.coordinator = context.coordinator
        // Darcula: row lines on the window background instead of alternating rows.
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = Darcula.background
        table.gridStyleMask = .solidHorizontalGridLineMask
        table.gridColor = Darcula.raised
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsColumnReordering = false
        table.style = .fullWidth
        table.rowHeight = 26
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        var columns = [("name", "Name", 280.0, 140.0), ("size", "Größe", 80.0, 60.0), ("date", "Geändert", 112.0, 90.0)]
        if side == .remote { columns.append(("mode", "Rechte", 52.0, 44.0)) }
        for (id, title, width, minimum) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = minimum
            column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            if id == "size" { column.headerCell.alignment = .right }
            table.addTableColumn(column)
        }
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        table.autosaveName = side == .local ? "FileTableMac" : "FileTableServer"
        table.autosaveTableColumns = true
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.registerForDraggedTypes(side == .remote ? [.fileURL] : [.fileHubRemote])
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        // FileTableView draws its own drop target in petrol: the system one is graphite here.
        table.draggingDestinationFeedbackStyle = .none
        let menu = NSMenu()
        menu.delegate = context.coordinator
        menu.autoenablesItems = false
        table.menu = menu

        let scroll = FileScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.backgroundColor = Darcula.background
        table.dropRing = scroll.dropRing
        context.coordinator.table = table
        context.coordinator.update(rows: rows, selection: selection)
        return scroll
    }

    func updateNSView(_ nsView: FileScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(rows: rows, selection: selection)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: FileTable
        weak var table: NSTableView?
        private var source: [FileRow] = []
        private var sorted: [FileRow] = []
        private var applying = false
        private var icons: [String: NSImage] = [:]

        init(_ parent: FileTable) { self.parent = parent }

        func update(rows: [FileRow], selection: Set<String>) {
            if rows != source {
                source = rows
                resort()
                applying = true
                table?.reloadData()
                applying = false
            }
            apply(selection)
        }

        private func resort() {
            let descriptor = table?.sortDescriptors.first
            let key = descriptor?.key ?? "name"
            let ascending = descriptor?.ascending ?? true
            sorted = source.sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                let order: ComparisonResult
                switch key {
                case "size": order = Self.compare(a.size ?? -1, b.size ?? -1)
                case "date": order = Self.compare(a.modified ?? .distantPast, b.modified ?? .distantPast)
                case "mode": order = Self.compare(a.mode ?? -1, b.mode ?? -1)
                default: order = a.name.localizedStandardCompare(b.name)
                }
                if order == .orderedSame { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
                return ascending ? order == .orderedAscending : order == .orderedDescending
            }
        }

        private static func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
            a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
        }

        private func apply(_ selection: Set<String>) {
            guard let table else { return }
            let indexes = IndexSet(sorted.indices.filter { selection.contains(sorted[$0].id) })
            guard indexes != table.selectedRowIndexes else { return }
            applying = true
            table.selectRowIndexes(indexes, byExtendingSelection: false)
            applying = false
        }

        var selectedRows: [FileRow] {
            guard let table else { return [] }
            return table.selectedRowIndexes.compactMap { $0 < sorted.count ? sorted[$0] : nil }
        }

        // MARK: Data

        func numberOfRows(in tableView: NSTableView) -> Int { sorted.count }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            resort()
            applying = true
            tableView.reloadData()
            applying = false
            apply(parent.selection)
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let column = tableColumn, row < sorted.count else { return nil }
            let item = sorted[row]
            let id = column.identifier
            let cell = tableView.makeView(withIdentifier: id, owner: self) as? FileCell ?? makeCell(id)
            switch id.rawValue {
            case "name":
                cell.textField?.stringValue = item.name
                cell.imageView?.image = icon(item)
                cell.color = item.isSystem ? Darcula.faint : Darcula.text
            case "size":
                cell.textField?.stringValue = item.isDirectory ? "–" : item.size.map(Fmt.size) ?? ""
                cell.color = item.isSystem ? Darcula.faint : Darcula.muted
            case "mode":
                cell.textField?.stringValue = item.mode.map(FileMode.octal) ?? ""
                cell.color = item.isSystem ? Darcula.faint : Darcula.muted
                cell.toolTip = item.mode.map(FileMode.symbolic)
                return cell
            default:
                cell.textField?.stringValue = Fmt.date(item.modified)
                cell.color = item.isSystem ? Darcula.faint : Darcula.muted
            }
            cell.toolTip = item.isSystem ? "Systemdatei – FileHub überträgt sie nie. Auf dem Server kann sie gelöscht werden." : nil
            return cell
        }

        private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> FileCell {
            let cell = FileCell()
            cell.identifier = id
            let text = NSTextField(labelWithString: "")
            text.translatesAutoresizingMaskIntoConstraints = false
            text.lineBreakMode = .byTruncatingMiddle
            text.cell?.truncatesLastVisibleLine = true
            cell.addSubview(text)
            cell.textField = text
            if id.rawValue == "name" {
                let image = NSImageView()
                image.translatesAutoresizingMaskIntoConstraints = false
                image.imageScaling = .scaleProportionallyUpOrDown
                cell.addSubview(image)
                cell.imageView = image
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 20),
                    image.heightAnchor.constraint(equalToConstant: 20),
                    text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 7),
                ])
            } else {
                text.alignment = id.rawValue == "size" ? .right : .left
                if id.rawValue == "mode" { text.lineBreakMode = .byClipping }
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2).isActive = true
                text.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .regular)
            }
            NSLayoutConstraint.activate([
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        /// Icon by kind and extension on both sides. FileHub never reads the files for it (no parsing
        /// of foreign app icons, no waiting on slow volumes on the main thread).
        private func icon(_ item: FileRow) -> NSImage {
            let ext = (item.name as NSString).pathExtension.lowercased()
            let package = item.isDirectory && !ext.isEmpty && UTType(filenameExtension: ext)?.conforms(to: .package) == true
            let key = package ? "/paket." + ext : item.isDirectory ? "/ordner" : item.isLink ? "/link" : ext
            if let cached = icons[key] { return cached }
            let image: NSImage
            if package, let type = UTType(filenameExtension: ext) {
                image = NSWorkspace.shared.icon(for: type)
            } else if item.isDirectory {
                image = NSWorkspace.shared.icon(for: .folder)
            } else if item.isLink {
                image = NSWorkspace.shared.icon(for: .symbolicLink)
            } else {
                image = NSWorkspace.shared.icon(for: UTType(filenameExtension: key) ?? .data)
            }
            icons[key] = image
            return image
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            SelectedRowView()
        }

        func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
            (tableView as? FileTableView)?.style(rowView, row: row)
        }

        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            tableColumn?.identifier.rawValue == "name" && row < sorted.count ? sorted[row].name : nil
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table else { return }
            let row = table.clickedRow
            if row >= 0, row < sorted.count {
                if !table.selectedRowIndexes.contains(row) { table.selectRowIndexes([row], byExtendingSelection: false) }
            } else {
                table.deselectAll(nil)
            }
            // The actions read the selection from the model right after the menu closes.
            let rows = selectedRows
            let ids = Set(rows.map(\.id))
            if ids != parent.selection { parent.selection = ids }
            parent.onFocus()
            for entry in parent.menu(rows) {
                guard let entry else {
                    if menu.items.last.map({ !$0.isSeparatorItem }) == true { menu.addItem(.separator()) }
                    continue
                }
                let item = NSMenuItem(title: entry.title, action: #selector(choose(_:)), keyEquivalent: "")
                item.target = self
                item.isEnabled = entry.enabled
                item.image = NSImage(systemSymbolName: entry.symbol, accessibilityDescription: nil)
                item.representedObject = MenuAction(entry.action)
                menu.addItem(item)
            }
            if menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
        }

        @objc private func choose(_ sender: NSMenuItem) {
            guard let action = sender.representedObject as? MenuAction else { return }
            MainActor.assumeIsolated { action.run() }
        }

        // MARK: Selection and opening

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applying else { return }
            let ids = Set(selectedRows.map(\.id))
            guard ids != parent.selection else { return }
            let binding = parent.$selection
            DispatchQueue.main.async { binding.wrappedValue = ids }
        }

        @objc func doubleClicked(_ sender: Any?) {
            guard let table, table.clickedRow >= 0, table.clickedRow < sorted.count else { return }
            parent.onOpen(sorted[table.clickedRow])
        }

        func focused() {
            let onFocus = parent.onFocus
            DispatchQueue.main.async { onFocus() }
        }

        func openSelected() {
            let rows = selectedRows
            if rows.count == 1 { parent.onOpen(rows[0]) }
        }

        func deleteSelected() -> Bool {
            guard let onDelete = parent.onDelete, !selectedRows.isEmpty else { return false }
            onDelete()
            return true
        }

        // MARK: Dragging

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard row < sorted.count else { return nil }
            let item = sorted[row]
            switch parent.side {
            case .local:
                return NSURL(fileURLWithPath: item.id)
            case .remote:
                guard !item.isSystem else { return nil }
                let pasteboardItem = NSPasteboardItem()
                pasteboardItem.setString(item.id, forType: .fileHubRemote)
                return pasteboardItem
            }
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                       proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            let table = tableView as? FileTableView
            guard parent.dropEnabled, payload(info) != nil,
                  (info.draggingSource as? NSTableView) !== tableView else {
                table?.dropRow = nil
                return []
            }
            if dropOperation == .on, row >= 0, row < sorted.count, sorted[row].isDirectory {
                table?.dropRow = row
                return .copy
            }
            tableView.setDropRow(-1, dropOperation: .on)
            table?.dropRow = -1
            return .copy
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                       dropOperation: NSTableView.DropOperation) -> Bool {
            guard parent.dropEnabled, let payload = payload(info) else { return false }
            let target = dropOperation == .on && row >= 0 && row < sorted.count && sorted[row].isDirectory ? sorted[row] : nil
            let handler = parent.onDrop
            DispatchQueue.main.async { handler(payload, target) }
            return true
        }

        private func payload(_ info: NSDraggingInfo) -> DropPayload? {
            let pasteboard = info.draggingPasteboard
            switch parent.side {
            case .remote:
                let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
                return urls.isEmpty ? nil : .local(urls)
            case .local:
                let paths = pasteboard.pasteboardItems?.compactMap { $0.string(forType: .fileHubRemote) } ?? []
                return paths.isEmpty ? nil : .remote(paths)
            }
        }
    }
}

/// Holds a menu entry's closure for `NSMenuItem.representedObject`.
private final class MenuAction: NSObject {
    let run: @MainActor () -> Void
    init(_ run: @escaping @MainActor () -> Void) { self.run = run }
}

/// A cell whose text turns white on a selected row.
final class FileCell: NSTableCellView {
    var color = Darcula.text {
        didSet { updateColor() }
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColor() }
    }

    private func updateColor() {
        textField?.textColor = backgroundStyle == .emphasized ? .white : color
    }
}

/// Row states in Darcula colors: the selection is petrol in the list being worked in and grey in
/// the other one, the row under the pointer lightens, and a folder that takes a drop gets a petrol
/// frame. The cells of selected rows and drop targets get the emphasized style (white text).
final class SelectedRowView: NSTableRowView {
    var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }
    var isDropTarget = false {
        didSet {
            guard isDropTarget != oldValue else { return }
            needsDisplay = true
            for case let cell as NSTableCellView in subviews { cell.backgroundStyle = interiorBackgroundStyle }
        }
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        isSelected || isDropTarget ? .emphasized : .normal
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if isHovered, !isSelected {
            Darcula.raised.setFill()
            bounds.fill()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        (isEmphasized ? Darcula.selection : Darcula.border).setFill()
        bounds.fill()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isDropTarget else { return }
        Darcula.main.withAlphaComponent(0.45).setFill()
        bounds.fill()
        let frame = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 4, yRadius: 4)
        frame.lineWidth = 2
        Darcula.ink.setStroke()
        frame.stroke()
    }
}

/// Holds the drop ring above the list. NSScrollView only lays out its own subviews (clip view,
/// header, scrollers), so the ring gets its frame in `tile()`.
final class FileScrollView: NSScrollView {
    let dropRing = DropRingView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        dropRing.isHidden = true
        addSubview(dropRing, positioned: .above, relativeTo: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func tile() {
        super.tile()
        dropRing.frame = bounds
    }
}

/// Petrol frame and tint over a whole list while a drop lands in its folder.
final class DropRingView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        Darcula.main.withAlphaComponent(0.12).setFill()
        bounds.fill()
        let frame = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 4, yRadius: 4)
        frame.lineWidth = 3
        Darcula.ink.setStroke()
        frame.stroke()
    }
}

/// Return opens, Backspace/Delete deletes (with confirmation) where the list supports it. Tracks
/// the row under the pointer and the drop target for the row views.
final class FileTableView: NSTableView {
    weak var coordinator: FileTable.Coordinator?
    weak var dropRing: NSView?
    private var hoverArea: NSTrackingArea?

    /// Row under the pointer, -1 for none.
    private var hoveredRow = -1 {
        didSet { if hoveredRow != oldValue { restyleRows() } }
    }

    /// Where a drag would drop: a folder row, -1 for the folder shown, nil while nothing is dragged.
    var dropRow: Int? {
        didSet {
            guard dropRow != oldValue else { return }
            dropRing?.isHidden = dropRow != -1
            restyleRows()
        }
    }

    func style(_ rowView: NSTableRowView, row: Int) {
        guard let rowView = rowView as? SelectedRowView else { return }
        rowView.isHovered = row == hoveredRow && dropRow == nil
        rowView.isDropTarget = row == dropRow
    }

    private func restyleRows() {
        enumerateAvailableRowViews { rowView, row in style(rowView, row: row) }
    }

    private func updateHover() {
        guard let window, window.isKeyWindow else { hoveredRow = -1; return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        hoveredRow = visibleRect.contains(point) ? row(at: point) : -1
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHover()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        updateHover()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoveredRow = -1
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        updateHover()
    }

    override func reloadData() {
        super.reloadData()
        updateHover()
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        dropRow = nil
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        super.draggingEnded(sender)
        dropRow = nil
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        super.concludeDragOperation(sender)
        dropRow = nil
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { coordinator?.focused() }
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:
            coordinator?.openSelected()
        case 51, 117:
            if coordinator?.deleteSelected() != true { super.keyDown(with: event) }
        default:
            super.keyDown(with: event)
        }
    }
}
