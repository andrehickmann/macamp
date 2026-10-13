import AppKit
import MacAmpCore

/// The media library: a gen.bmp window frame around native lists colored like the skin's playlist.
@MainActor
final class LibraryView: GenWindowView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private enum SidebarItem: Hashable {
        case header(String)
        case view(Library.View)
        case playlist(Int)
        case spotifyConnect, spotifyLiked, spotifySearch
        case spotifyPlaylist(String)

        var isSpotify: Bool {
            switch self {
            case .spotifyLiked, .spotifySearch, .spotifyPlaylist: true
            default: false
            }
        }
    }

    private static let columns: [(id: String, title: String, width: CGFloat)] = [
        ("position", "#", 34), ("artist", "Artist", 130), ("title", "Title", 170), ("album", "Album", 130), ("length", "Length", 50),
        ("track", "Track", 44), ("genre", "Genre", 80), ("year", "Year", 40), ("rating", "Rating", 55),
        ("plays", "Plays", 40), ("lastPlayed", "Last Played", 110),
    ]

    private let split = NSSplitView()
    private let sidebar = NSTableView()
    private let tracksTable = NSTableView()
    private let search = NSSearchField()
    private let status = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private var sidebarItems: [SidebarItem] = []
    private var selected = SidebarItem.view(.audio)
    private var rows: [LibraryTrack] = []
    private var didPlaceDivider = false
    /// Spotify rows per sidebar item, loaded on first selection.
    private var spotifyRows: [SidebarItem: [LibraryTrack]] = [:]
    private var spotifyTask: Task<Void, Never>?
    /// Spotify playlists whose tracks the API withholds (not owned by the user); Play starts them in Spotify.
    private var closedPlaylists: Set<String> = []
    private let playlistsMenu = NSMenu()

    override init(app: AppController) {
        super.init(app: app)
        buildContent()
        applySkinColors()
        libraryChanged()
    }

    override var title: String { "MEDIA LIBRARY" }
    override var logicalSize: CGSize { app.librarySize }
    override func resize(to size: CGSize) { app.setLibrarySize(size) }
    override func close() { app.toggleLibrary() }

    // MARK: Content

    private func buildContent() {
        // Start at the final size: a zero-sized split view logs layout warnings.
        split.frame = contentRect
        split.isVertical = true
        split.dividerStyle = .thin
        split.appearance = NSAppearance(named: .darkAqua)
        addSubview(split)

        let sidebarColumn = NSTableColumn(identifier: .init("name"))
        sidebarColumn.resizingMask = .autoresizingMask
        sidebar.addTableColumn(sidebarColumn)
        sidebar.headerView = nil
        split.addSubview(scrollView(for: sidebar, width: 130))

        for column in Self.columns {
            let tableColumn = NSTableColumn(identifier: .init(column.id))
            tableColumn.title = column.title
            tableColumn.width = column.width
            // The running number follows the displayed order, so sorting by it means nothing.
            if column.id != "position" { tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.id, ascending: true) }
            if column.id == "track" { tableColumn.headerToolTip = "Track number on the album" }
            tracksTable.addTableColumn(tableColumn)
        }
        tracksTable.allowsMultipleSelection = true
        tracksTable.target = self
        tracksTable.doubleAction = #selector(playSelection)
        tracksTable.menu = tracksMenu()
        tracksTable.setDraggingSourceOperationMask(.copy, forLocal: false)
        sidebar.menu = sidebarMenu()
        // Tracks dropped on a playlist in the sidebar are added to it.
        sidebar.registerForDraggedTypes([.URL, .fileURL])

        // Laid out by hand: NSSplitView briefly sizes panes to zero, which breaks autoresizing masks.
        let pane = ManualLayoutView()
        search.sendsSearchStringImmediately = true
        search.target = self
        search.action = #selector(searchChanged)
        status.alignment = .right
        status.lineBreakMode = .byTruncatingHead
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let tracksScroll = scrollView(for: tracksTable, width: 400)
        let buttons = [("Play", #selector(playSelection)), ("Enqueue", #selector(enqueueSelection)),
                       ("Add Folder…", #selector(addFolder)), ("Rescan", #selector(rescan))].map { title, action in
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .push
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            return button
        }
        for view in [search, status, spinner, tracksScroll] + buttons { pane.addSubview(view) }
        pane.layoutSubviews = { [search, status, spinner] size in
            search.frame = CGRect(x: 4, y: size.height - 25, width: min(200, size.width - 8), height: 22)
            spinner.frame = CGRect(x: 210, y: size.height - 22, width: 16, height: 16)
            status.frame = CGRect(x: 230, y: size.height - 21, width: max(0, size.width - 234), height: 16)
            tracksScroll.frame = CGRect(x: 0, y: 28, width: size.width, height: max(0, size.height - 56))
            let widths: [CGFloat] = [64, 80, 100, 64]
            let xs: [CGFloat] = [4, 72, size.width - 172, size.width - 68]
            for (index, button) in buttons.enumerated() {
                button.frame = CGRect(x: xs[index], y: 3, width: widths[index], height: 22)
            }
        }
        split.addSubview(pane)
    }

    private func scrollView(for table: NSTableView, width: CGFloat) -> NSScrollView {
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 16
        table.style = .plain
        table.columnAutoresizingStyle = table === sidebar ? .uniformColumnAutoresizingStyle : .noColumnAutoresizing
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: width, height: 300))
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.hasHorizontalScroller = table === tracksTable
        scroll.borderType = .noBorder
        return scroll
    }

    override func layout() {
        super.layout()
        split.frame = contentRect
        sidebar.tableColumns.first?.width = max(60, sidebar.enclosingScrollView?.contentSize.width ?? 115)
        if !didPlaceDivider {
            didPlaceDivider = true
            split.setPosition(130, ofDividerAt: 0)
        }
    }

    /// Re-applies list colors and font from the skin's pledit.txt.
    func applySkinColors() {
        let background = NSColor(cgColor: skin.playlistStyle.normalBackground) ?? .black
        for table in [sidebar, tracksTable] {
            table.backgroundColor = background
            table.enclosingScrollView?.backgroundColor = background
            table.reloadData()
        }
        needsDisplay = true
    }

    /// Redraws rows so the playing track is highlighted.
    func playlistChanged() {
        tracksTable.reloadData()
    }

    /// Rebuilds the sidebar and the visible rows after the library changed.
    func libraryChanged() {
        let library = app.library
        let spotify: [SidebarItem] = app.spotify.isConnected
            ? [.spotifyLiked, .spotifySearch] + app.spotifyPlaylists.map { .spotifyPlaylist($0.id) }
            : [.spotifyConnect]
        sidebarItems = [.header("Local Media")] + Library.View.allCases.map { .view($0) } + [.header("Playlists")]
            + library.playlists.indices.map { .playlist($0) } + [.header("Spotify")] + spotify
        if !app.spotify.isConnected { spotifyRows = [:] }
        if !sidebarItems.contains(selected) { selected = .view(.audio) }
        sidebar.reloadData()
        if let row = sidebarItems.firstIndex(of: selected) { sidebar.selectRowIndexes([row], byExtendingSelection: false) }
        reloadRows()
    }

    private func reloadRows() {
        if selected.isSpotify { return loadSpotifyRows(selected) }
        let library = app.library
        let unsorted: [LibraryTrack] = switch selected {
        case .view(let view):
            library.tracks(in: view, matching: search.stringValue)
        case .playlist(let index) where library.playlists.indices.contains(index):
            Library.filter(library.playlists[index].entries.map { entry in
                library.index(of: entry.url).map { library.tracks[$0] } ?? {
                    var track = LibraryTrack(url: entry.url)
                    track.title = entry.title
                    track.duration = entry.duration
                    return track
                }()
            }, query: search.stringValue)
        default:
            []
        }
        rows = sorted(unsorted)
        tracksTable.reloadData()
        updateStatus()
    }

    /// Shows cached Spotify rows (filtered by the search field) or fetches them; "Search" queries Spotify itself.
    private func loadSpotifyRows(_ item: SidebarItem) {
        if app.spotifyPlaylists.isEmpty { app.loadSpotifyPlaylists() }
        let query = search.stringValue
        if case .spotifyPlaylist(let id) = item, closedPlaylists.contains(id) {
            rows = []
            tracksTable.reloadData()
            return updateStatus()
        }
        if item != .spotifySearch, let cached = spotifyRows[item] {
            rows = sorted(Library.filter(cached, query: query))
            tracksTable.reloadData()
            return updateStatus()
        }
        rows = []
        tracksTable.reloadData()
        spotifyTask?.cancel()
        guard item != .spotifySearch || !query.trimmingCharacters(in: .whitespaces).isEmpty else { return updateStatus() }
        let name = sidebarTitle(item)
        status.stringValue = "Loading \(name)…"
        spinner.startAnimation(nil)
        spotifyTask = Task {
            defer { if !Task.isCancelled { spinner.stopAnimation(nil) } }
            if item == .spotifySearch { try? await Task.sleep(for: .milliseconds(400)) }
            guard !Task.isCancelled else { return }
            // Each loaded page is shown right away so long playlists fill in progressively.
            let progress: SpotifyClient.Progress = { loaded, total in
                guard !Task.isCancelled, self.selected == item else { return }
                self.app.rememberSpotifyTracks(loaded)
                self.rows = self.sorted(Library.filter(loaded, query: self.search.stringValue))
                self.tracksTable.reloadData()
                self.status.stringValue = "Loading \(name)… \(loaded.count)" + (total.map { " of \($0)" } ?? "")
            }
            do {
                let tracks: [LibraryTrack] = switch item {
                case .spotifyLiked: try await app.spotify.likedSongs(progress: progress)
                case .spotifySearch: try await app.spotify.search(query)
                case .spotifyPlaylist(let id): try await app.spotify.tracks(ofPlaylist: id, progress: progress)
                default: []
                }
                app.rememberSpotifyTracks(tracks)
                guard !Task.isCancelled, selected == item else { return }
                if item != .spotifySearch { spotifyRows[item] = tracks }
                rows = sorted(item == .spotifySearch ? tracks : Library.filter(tracks, query: search.stringValue))
                tracksTable.reloadData()
                updateStatus()
            } catch SpotifyError.http(403, _) where { if case .spotifyPlaylist = item { true } else { false } }() {
                guard case .spotifyPlaylist(let id) = item, !Task.isCancelled else { return }
                closedPlaylists.insert(id)
                updateStatus()
            } catch {
                guard !Task.isCancelled else { return }
                status.stringValue = "Spotify: \(error.localizedDescription)"
            }
        }
    }

    /// Shows a one-off message in the status line (e.g. a failed request).
    func showStatus(_ message: String) {
        status.stringValue = message
    }

    func updateStatus() {
        let total = rows.reduce(0) { $0 + ($1.duration ?? 0) }
        var text = "\(rows.count) items [\(TimeDisplay.string(seconds: total))]"
        if app.library.folders.isEmpty, case .view = selected { text = "Use “Add Folder…” to build your library" }
        if selected == .spotifySearch, rows.isEmpty { text = "Type to search Spotify" }
        if case .spotifyPlaylist(let id) = selected, closedPlaylists.contains(id) {
            text = "Spotify only lists tracks of your own playlists – Play starts it in Spotify"
        }
        if let scan = app.libraryScanStatus { text += "  –  \(scan)" }
        if app.libraryScanStatus != nil { spinner.startAnimation(nil) } else if spotifyTask == nil { spinner.stopAnimation(nil) }
        status.stringValue = text
        status.textColor = NSColor(cgColor: skin.playlistStyle.normal) ?? .green
    }

    private func sidebarTitle(_ item: SidebarItem) -> String {
        switch item {
        case .spotifyLiked: "Liked Songs"
        case .spotifySearch: "search results"
        case .spotifyPlaylist(let id): app.spotifyPlaylists.first { $0.id == id }?.name ?? "playlist"
        default: "library"
        }
    }

    private func sorted(_ tracks: [LibraryTrack]) -> [LibraryTrack] {
        guard let descriptor = tracksTable.sortDescriptors.first, let key = descriptor.key else { return tracks }
        return tracks.sorted { a, b in
            let order = Self.compare(a, b, key: key)
            return descriptor.ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    private static func compare(_ a: LibraryTrack, _ b: LibraryTrack, key: String) -> ComparisonResult {
        func numbers(_ x: Double, _ y: Double) -> ComparisonResult { x < y ? .orderedAscending : x > y ? .orderedDescending : .orderedSame }
        switch key {
        case "length": return numbers(a.duration ?? 0, b.duration ?? 0)
        case "track": return numbers(Double(a.trackNumber ?? 0), Double(b.trackNumber ?? 0))
        case "year": return numbers(Double(a.year ?? 0), Double(b.year ?? 0))
        case "rating": return numbers(Double(a.rating), Double(b.rating))
        case "plays": return numbers(Double(a.playCount), Double(b.playCount))
        case "lastPlayed": return numbers(a.lastPlayed?.timeIntervalSince1970 ?? 0, b.lastPlayed?.timeIntervalSince1970 ?? 0)
        default: return text(a, key: key).localizedStandardCompare(text(b, key: key))
        }
    }

    private static func text(_ track: LibraryTrack, key: String) -> String {
        switch key {
        case "artist": track.artist ?? ""
        case "title": track.title ?? track.url.deletingPathExtension().lastPathComponent
        case "album": track.album ?? ""
        case "length": track.duration.map { TimeDisplay.string(seconds: $0) } ?? ""
        case "track": track.trackNumber.map(String.init) ?? ""
        case "genre": track.genre ?? ""
        case "year": track.year.map(String.init) ?? ""
        case "rating": String(repeating: "★", count: track.rating)
        case "plays": track.playCount > 0 ? String(track.playCount) : ""
        case "lastPlayed": track.lastPlayed?.formatted(date: .numeric, time: .shortened) ?? ""
        default: ""
        }
    }

    // MARK: Table data

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === sidebar ? sidebarItems.count : rows.count
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        tableView === sidebar && { if case .header = sidebarItems[row] { true } else { false } }()
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        !self.tableView(tableView, isGroupRow: row)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SkinRowView(selection: NSColor(cgColor: skin.playlistStyle.selectedBackground) ?? .blue)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = tableColumn?.identifier ?? .init("name")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField ?? {
            let field = NSTextField(labelWithString: "")
            field.identifier = identifier
            field.lineBreakMode = .byTruncatingTail
            return field
        }()
        let style = skin.playlistStyle
        cell.font = NSFont(name: style.fontName, size: 11) ?? .systemFont(ofSize: 11)
        cell.textColor = NSColor(cgColor: style.normal) ?? .green
        if tableView === sidebar {
            switch sidebarItems[row] {
            case .header(let title):
                cell.stringValue = title.uppercased()
                cell.textColor = cell.textColor?.withAlphaComponent(0.6)
            case .view(let view):
                cell.stringValue = "  " + view.title
            case .playlist(let index):
                cell.stringValue = "  " + (app.library.playlists[safe: index]?.name ?? "")
            case .spotifyConnect:
                cell.stringValue = "  Connect Spotify…"
            case .spotifyLiked:
                cell.stringValue = "  Liked Songs"
            case .spotifySearch:
                cell.stringValue = "  Search"
            case .spotifyPlaylist(let id):
                cell.stringValue = "  " + (app.spotifyPlaylists.first { $0.id == id }?.name ?? "")
            }
        } else {
            let track = rows[row]
            cell.stringValue = identifier.rawValue == "position" ? String(row + 1) : Self.text(track, key: identifier.rawValue)
            if app.isCurrent(track.url) { cell.textColor = NSColor(cgColor: style.current) ?? .white }
            cell.alignment = ["position", "length", "track", "year", "plays"].contains(identifier.rawValue) ? .right : .left
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard notification.object as? NSTableView === sidebar, sidebar.selectedRow >= 0 else { return }
        if sidebarItems[sidebar.selectedRow] == .spotifyConnect {
            sidebar.selectRowIndexes(IndexSet(sidebarItems.firstIndex(of: selected).map { [$0] } ?? []), byExtendingSelection: false)
            return app.toggleSpotifyConnection()
        }
        selected = sidebarItems[sidebar.selectedRow]
        reloadRows()
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        reloadRows()
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        tableView === tracksTable ? rows[row].url as NSURL : nil
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard tableView === sidebar, dropOperation == .on, sidebarItems.indices.contains(row), playlistTarget(sidebarItems[row]) != nil
        else { return [] }
        return .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        guard !urls.isEmpty, sidebarItems.indices.contains(row) else { return false }
        add(urls, to: sidebarItems[row])
        return true
    }

    /// The playlist a sidebar row stands for, if tracks can be dropped on it.
    private func playlistTarget(_ item: SidebarItem) -> AppController.PlaylistTarget? {
        switch item {
        case .playlist(let index): .library(index)
        case .spotifyLiked: .liked
        case .spotifyPlaylist(let id): app.spotifyPlaylists.first { $0.id == id && app.spotify.canEdit($0) }.map { .spotify($0) }
        default: nil
        }
    }

    private func add(_ urls: [URL], to item: SidebarItem) {
        if let target = playlistTarget(item) { app.add(urls, to: target) }
    }

    /// Forgets a Spotify playlist's cached rows after tracks were added, reloading it when shown.
    func spotifyPlaylistChanged(_ id: String) {
        spotifyRows[.spotifyPlaylist(id)] = nil
        if selected == .spotifyPlaylist(id) { reloadRows() }
    }

    func likedSongsChanged() {
        spotifyRows[.spotifyLiked] = nil
        if selected == .spotifyLiked { reloadRows() }
    }

    // MARK: Actions

    /// Rows a context-menu or button action applies to: the clicked row unless it is part of the selection.
    private var targetTracks: [LibraryTrack] {
        let clicked = tracksTable.clickedRow
        let indices = clicked >= 0 && !tracksTable.selectedRowIndexes.contains(clicked)
            ? IndexSet(integer: clicked) : tracksTable.selectedRowIndexes
        return indices.isEmpty ? rows : indices.map { rows[$0] }
    }

    @objc private func searchChanged() { reloadRows() }
    @objc private func playSelection() {
        if case .spotifyPlaylist(let id) = selected, closedPlaylists.contains(id),
           let playlist = app.spotifyPlaylists.first(where: { $0.id == id }) {
            return app.playSpotifyPlaylist(playlist.uri)
        }
        app.playLibraryTracks(targetTracks)
    }
    @objc private func enqueueSelection() { app.enqueueLibraryTracks(targetTracks) }
    @objc private func addFolder() { app.addLibraryFolder() }
    @objc private func rescan() { app.rescanLibrary() }
    @objc private func showInFinder() { NSWorkspace.shared.activateFileViewerSelecting(targetTracks.map(\.url).filter(\.isFileURL)) }
    @objc private func removeFromLibrary() { app.removeFromLibrary(targetTracks.map(\.url)) }
    @objc private func rate(_ sender: NSMenuItem) { app.rate(targetTracks.map(\.url), stars: sender.tag) }

    @objc private func deletePlaylist() {
        guard sidebar.clickedRow >= 0, case .playlist(let index) = sidebarItems[sidebar.clickedRow] else { return }
        app.deleteLibraryPlaylist(at: index)
    }

    /// Tag of menu items that only apply to local files (rating, Finder, removal).
    private static let localOnlyTag = 1

    private func tracksMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        for (title, action) in [("Play", #selector(playSelection)), ("Enqueue", #selector(enqueueSelection))] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        let ratings = NSMenu()
        for stars in (0...5).reversed() {
            let item = ratings.addItem(withTitle: stars == 0 ? "No Rating" : String(repeating: "★", count: stars),
                                       action: #selector(rate(_:)), keyEquivalent: "")
            item.tag = stars
            item.target = self
        }
        let rate = menu.addItem(withTitle: "Rate", action: nil, keyEquivalent: "")
        rate.submenu = ratings
        menu.addItem(.separator())
        menu.addItem(withTitle: "Add to Playlist", action: nil, keyEquivalent: "").submenu = playlistsMenu
        playlistsMenu.delegate = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show in Finder", action: #selector(showInFinder), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Remove from Library", action: #selector(removeFromLibrary), keyEquivalent: "").target = self
        for item in menu.items.dropFirst(2) where item.submenu !== playlistsMenu { item.tag = Self.localOnlyTag }
        return menu
    }

    /// Hides the local-file actions when the clicked rows are Spotify tracks; fills "Add to Playlist".
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === playlistsMenu else {
            let hasFiles = targetTracks.contains { $0.url.isFileURL }
            for item in menu.items where item.tag == Self.localOnlyTag { item.isHidden = !hasFiles }
            return
        }
        menu.items = app.addToPlaylistItems(for: targetTracks.map(\.url))
    }

    private func sidebarMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Delete Playlist", action: #selector(deletePlaylist), keyEquivalent: "").target = self
        return menu
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { return playSelection() }
        super.keyDown(with: event)
    }

    override func dropped(_ urls: [URL], at point: CGPoint) {
        app.addLibraryFolders(urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true })
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
