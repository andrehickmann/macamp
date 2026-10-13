import AppKit
import MacAmpCore

/// Sonos rooms in a gen.bmp frame: one row per group with its rooms below, what each group plays, volumes
/// and grouping. The selected row is the output MacAmp plays on.
@MainActor
final class RoomsView: GenWindowView, NSTableViewDataSource, NSTableViewDelegate {
    private enum Row: Equatable {
        case thisMac
        case group(SonosGroup)
        case room(SonosRoom, SonosGroup)

        var group: SonosGroup? {
            switch self {
            case .thisMac: nil
            case .group(let group), .room(_, let group): group
            }
        }
    }

    /// "playing" takes whatever width the others leave.
    private static let columns: [(id: String, width: CGFloat)] = [
        ("output", 20), ("name", 110), ("state", 16), ("playing", 100), ("volume", 90),
    ]

    private let table = NSTableView()
    private let status = NSTextField(labelWithString: "")
    private let groupButton = NSButton(title: "Group", target: nil, action: nil)
    private let connectButton = NSButton(title: "Connect Sonos", target: nil, action: nil)
    private var rows: [Row] = [.thisMac]
    /// Progress or result of Connect Sonos; shown instead of the room count while set.
    private var message: String?

    private var sonos: SonosClient { app.sonos }

    override init(app: AppController) {
        super.init(app: app)
        buildContent()
        applySkinColors()
        roomsChanged()
    }

    override var title: String { "ROOMS" }
    override var logicalSize: CGSize { app.roomsSize }
    override func resize(to size: CGSize) { app.setRoomsSize(size) }
    override func close() { app.toggleRooms() }

    // MARK: Content

    private func buildContent() {
        for column in Self.columns {
            let tableColumn = NSTableColumn(identifier: .init(column.id))
            tableColumn.width = column.width
            table.addTableColumn(tableColumn)
        }
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 20
        table.style = .plain
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.target = self
        table.doubleAction = #selector(togglePlay)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let playButton = NSButton(title: "Play/Pause", target: self, action: #selector(togglePlay))
        groupButton.target = self
        groupButton.action = #selector(showGroupMenu)
        connectButton.target = self
        connectButton.action = #selector(connectSonos)
        connectButton.toolTip = "Finds your Spotify account in Sonos. Play a song in Spotify on your phone or Mac first: "
            + "a muted test track then plays on the chosen room until Sonos takes over your account (your phone stops)"
        for button in [playButton, groupButton, connectButton] {
            button.bezelStyle = .push
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
        }
        status.alignment = .right
        status.lineBreakMode = .byTruncatingHead
        status.font = .systemFont(ofSize: 11)

        let pane = ManualLayoutView(frame: contentRect)
        pane.appearance = NSAppearance(named: .darkAqua)
        for view in [scroll, playButton, groupButton, connectButton, status] { pane.addSubview(view) }
        pane.layoutSubviews = { [table, status] size in
            scroll.frame = CGRect(x: 0, y: 28, width: size.width, height: max(0, size.height - 28))
            let others = Self.columns.filter { $0.id != "playing" }.reduce(0) { $0 + $1.width }
            let spacing = table.intercellSpacing.width * CGFloat(Self.columns.count)
            table.tableColumns.first { $0.identifier.rawValue == "playing" }?.width = max(60, size.width - others - spacing - 4)
            playButton.frame = CGRect(x: 4, y: 3, width: 84, height: 22)
            self.groupButton.frame = CGRect(x: 92, y: 3, width: 70, height: 22)
            self.connectButton.frame = CGRect(x: 166, y: 3, width: 106, height: 22)
            status.frame = CGRect(x: 278, y: 6, width: max(0, size.width - 282), height: 16)
            status.toolTip = status.stringValue
        }
        pane.layoutSubviews?(pane.bounds.size)
        addSubview(pane)
    }

    override func layout() {
        super.layout()
        subviews.first?.frame = contentRect
    }

    /// Re-applies list colors from the skin's pledit.txt.
    func applySkinColors() {
        let background = NSColor(cgColor: skin.playlistStyle.normalBackground) ?? .black
        table.backgroundColor = background
        table.enclosingScrollView?.backgroundColor = background
        table.reloadData()
        needsDisplay = true
    }

    /// Rebuilds the rows from the latest poll.
    func roomsChanged() {
        // Rebuilding while a slider is dragged would end the drag.
        guard NSEvent.pressedMouseButtons & 1 == 0 || window?.isKeyWindow != true else { return }
        rows = [.thisMac] + sonos.groups.flatMap { group -> [Row] in
            [.group(group)] + (group.members.count > 1 ? group.members.map { .room($0, group) } : [])
        }
        table.reloadData()
        let output = rows.firstIndex { if case .room = $0 { false } else { isOutput($0) } }
        table.selectRowIndexes(output.map { [$0] } ?? [], byExtendingSelection: false)
        let roomCount = sonos.groups.reduce(0) { $0 + $1.members.count }
        status.stringValue = message ?? sonos.lastError.map { "Sonos: \($0)" }
            ?? (sonos.groups.isEmpty ? "Searching for Sonos…"
                : sonos.isSpotifyConnected ? "\(roomCount) rooms" : "Spotify: click Connect Sonos")
        status.toolTip = status.stringValue
        connectButton.isEnabled = !sonos.groups.isEmpty && message?.hasSuffix("…") != true
        status.textColor = NSColor(cgColor: skin.playlistStyle.normal) ?? .green
        groupButton.isEnabled = selectedRow?.group != nil
    }

    private var selectedRow: Row? { table.selectedRow >= 0 ? rows[table.selectedRow] : nil }

    /// Before the first poll the output room has no group yet; then no row is the output, not even This Mac.
    private func isOutput(_ row: Row) -> Bool {
        switch row {
        case .thisMac: sonos.outputRoom == nil
        case .group(let group): group.id == sonos.outputGroup?.id
        case .room(let room, _): room.id == sonos.outputRoom
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SkinRowView(selection: NSColor(cgColor: skin.playlistStyle.selectedBackground) ?? .blue)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        let row = rows[index]
        let style = skin.playlistStyle
        let font = NSFont(name: style.fontName, size: 11) ?? .systemFont(ofSize: 11)
        let color = NSColor(cgColor: style.normal) ?? .green
        func label(_ text: String, dim: Bool = false) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.font = font
            field.textColor = dim ? color.withAlphaComponent(0.6) : color
            field.lineBreakMode = .byTruncatingTail
            return field
        }
        let playback = row.group.flatMap { sonos.playbacks[$0.id] }

        switch (tableColumn?.identifier.rawValue, row) {
        case ("output", .thisMac), ("output", .group):
            let button = NSButton(radioButtonWithTitle: "", target: self, action: #selector(chooseOutput(_:)))
            button.tag = index
            button.state = isOutput(row) ? .on : .off
            button.toolTip = "Play MacAmp here"
            return button
        case ("name", .thisMac):
            return label("This Mac")
        case ("name", .group(let group)):
            return label(group.name)
        case ("name", .room(let room, _)):
            return label("    " + room.name, dim: true)
        case ("state", .group):
            let symbol = switch playback?.state {
            case .playing: "▶"
            case .paused: "❚❚"
            default: "■"
            }
            let field = label(symbol)
            field.textColor = NSColor(cgColor: style.current) ?? .white
            return field
        case ("playing", .thisMac):
            return label("MacAmp player", dim: true)
        case ("playing", .group):
            guard let playback, playback.state != .stopped, let title = playback.displayTitle else { return label("Stopped", dim: true) }
            return label(title)
        case ("volume", .group(let group)):
            return volumeSlider(sonos.volumes["group:" + group.id], tag: index)
        case ("volume", .room(let room, _)):
            return volumeSlider(sonos.volumes[room.id], tag: index)
        default:
            return nil
        }
    }

    private func volumeSlider(_ value: Int?, tag: Int) -> NSSlider {
        let slider = NSSlider(value: Double(value ?? 0), minValue: 0, maxValue: 100, target: self, action: #selector(volumeChanged(_:)))
        slider.controlSize = .small
        slider.tag = tag
        slider.isEnabled = value != nil
        slider.toolTip = value.map { "Volume \($0)" }
        return slider
    }

    /// Choosing a row makes it the output; a room row remembers that room rather than its group.
    func tableViewSelectionDidChange(_ notification: Notification) {
        groupButton.isEnabled = selectedRow?.group != nil
        guard let row = selectedRow, !isOutput(row) else { return }
        switch row {
        case .thisMac: app.setSonosOutput(nil)
        case .group(let group): app.setSonosOutput(group.coordinator.id)
        case .room(let room, _): app.setSonosOutput(room.id)
        }
        roomsChanged()
    }

    // MARK: Actions

    @objc private func chooseOutput(_ sender: NSButton) {
        table.selectRowIndexes([sender.tag], byExtendingSelection: false)
    }

    @objc private func volumeChanged(_ sender: NSSlider) {
        let percent = Int(sender.doubleValue.rounded())
        sender.toolTip = "Volume \(percent)"
        switch rows[sender.tag] {
        case .group(let group): sonos.setVolume(of: group, to: percent)
        case .room(let room, _): sonos.setVolume(of: room, to: percent)
        case .thisMac: break
        }
    }

    @objc private func togglePlay() {
        let row = table.clickedRow >= 0 ? rows[table.clickedRow] : selectedRow
        if let group = row?.group { sonos.togglePlay(group) }
    }

    /// Every room with a check mark when it belongs to the selected group; choosing one adds or removes it.
    @objc private func showGroupMenu() {
        guard let group = selectedRow?.group else { return }
        let menu = NSMenu()
        for room in sonos.groups.flatMap(\.members).sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            let item = menu.addItem(withTitle: room.name, action: #selector(toggleMember(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = room.id
            item.state = group.members.contains(room) ? .on : .off
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Ungroup All", action: #selector(ungroupAll), keyEquivalent: "").target = self
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: groupButton.isFlipped ? groupButton.bounds.height : 0), in: groupButton)
    }

    @objc private func toggleMember(_ sender: NSMenuItem) {
        guard let group = selectedRow?.group, let room = sonos.groups.flatMap(\.members).first(where: { $0.id == sender.representedObject as? String })
        else { return }
        sonos.set(room, in: group, included: sender.state == .off)
    }

    @objc private func ungroupAll() { sonos.ungroupAll() }

    @objc private func connectSonos() { app.connectSonos() }

    /// Shows Connect Sonos progress or its result; nil returns to the room count.
    func showMessage(_ text: String?) {
        message = text
        roomsChanged()
    }
}
