import AppKit
import MacAmpCore

/// The artist of the Spotify track that is playing, in a gen.bmp frame: album cover, genres and three tabs:
/// Wikipedia intro, the tracks of an album and the artist's albums. Each part shows as soon as it has loaded.
@MainActor
final class ArtistView: GenWindowView, NSTableViewDataSource, NSTableViewDelegate {
    private enum Tab: Int { case about, album, albums }
    private enum Row {
        case track(LibraryTrack, index: Int, of: [LibraryTrack])
        case album(SpotifyAlbum)
        case message(String)
    }

    private let cover = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let details = NSTextField(wrappingLabelWithString: "")
    private let tabs = NSSegmentedControl(labels: ["About", "Album", "Albums"], trackingMode: .selectOne, target: nil, action: nil)
    private let spotifyButton = NSButton(title: "Spotify ↗", target: nil, action: nil)
    private let intro = NSTextView()
    private let introScroll = NSScrollView()
    private let table = NSTableView()

    /// Track whose artist is shown (or loading); nil while no Spotify track plays.
    private var trackURI: String?
    private var track: SpotifyTrack?
    private var artist: SpotifyArtist?
    /// The album in the Album tab: the playing track's, or one opened from the Albums tab.
    private var album: SpotifyAlbum?
    private var albumRows: [Row] = []
    private var albumsRows: [Row] = []
    private var tasks: [Task<Void, Never>] = []
    // ponytail: unbounded per-session cache (covers, artists, albums, intros); evict if memory ever matters.
    private var cache: [String: Any] = [:]

    override init(app: AppController) {
        super.init(app: app)
        buildContent()
        applySkinColors()
        update()
    }

    override var title: String { "ARTIST" }
    override var logicalSize: CGSize { app.artistSize }
    override func resize(to size: CGSize) { app.setArtistSize(size) }
    override func close() { app.toggleArtist() }

    // MARK: Content

    private func buildContent() {
        cover.imageScaling = .scaleProportionallyUpOrDown
        name.font = .boldSystemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingTail
        details.font = .systemFont(ofSize: 11)
        tabs.controlSize = .small
        tabs.font = .systemFont(ofSize: 11)
        tabs.selectedSegment = Tab.about.rawValue
        tabs.target = self
        tabs.action = #selector(tabChanged)
        spotifyButton.bezelStyle = .push
        spotifyButton.controlSize = .small
        spotifyButton.font = .systemFont(ofSize: 11)
        spotifyButton.target = self
        spotifyButton.action = #selector(openShownInSpotify)
        spotifyButton.toolTip = "Open the album (Album tab) or the artist in Spotify"

        intro.isEditable = false
        intro.font = .systemFont(ofSize: 11)
        intro.textContainerInset = .zero
        intro.textContainer?.lineFragmentPadding = 0
        intro.autoresizingMask = .width
        intro.drawsBackground = false
        introScroll.documentView = intro

        for (id, width) in [("title", 200.0), ("info", 44.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.width = width
            table.addTableColumn(column)
        }
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 18
        table.style = .plain
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.backgroundColor = .clear
        table.target = self
        table.doubleAction = #selector(openRow)
        table.menu = rowMenu()
        let tableScroll = NSScrollView()
        tableScroll.documentView = table
        for scroll in [introScroll, tableScroll] {
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.borderType = .noBorder
            scroll.drawsBackground = false
        }

        let pane = ManualLayoutView(frame: contentRect)
        pane.appearance = NSAppearance(named: .darkAqua)
        for view in [cover, name, details, tabs, spotifyButton, introScroll, tableScroll] { pane.addSubview(view) }
        pane.layoutSubviews = { [cover, name, details, tabs, spotifyButton, introScroll, table] size in
            let side = min(size.height - 8, size.width * 0.4)
            cover.frame = CGRect(x: 4, y: 4, width: side, height: side)
            let x = side + 12, width = max(0, size.width - x - 4)
            name.frame = CGRect(x: x, y: size.height - 22, width: width, height: 18)
            details.frame = CGRect(x: x, y: size.height - 50, width: width, height: 28)
            tabs.frame = CGRect(x: x, y: size.height - 76, width: min(180, max(0, width - 80)), height: 22)
            spotifyButton.frame = CGRect(x: x + width - 74, y: size.height - 77, width: 76, height: 24)
            let content = CGRect(x: x, y: 4, width: width, height: max(0, size.height - 84))
            introScroll.frame = content
            tableScroll.frame = content
            table.tableColumns.first?.width = max(60, width - 44 - table.intercellSpacing.width * 2 - 4)
        }
        pane.layoutSubviews?(pane.bounds.size)
        addSubview(pane)
    }

    override func layout() {
        super.layout()
        subviews.first?.frame = contentRect
    }

    /// Re-applies colors from the skin's pledit.txt.
    func applySkinColors() {
        let text = NSColor(cgColor: skin.playlistStyle.normal) ?? .green
        for label in [name, details] { label.textColor = text }
        intro.textColor = text
        table.reloadData()
        needsDisplay = true
    }

    private var tab: Tab { Tab(rawValue: tabs.selectedSegment) ?? .about }
    private var rows: [Row] { tab == .albums ? albumsRows : albumRows }

    /// Shows what has loaded so far.
    private func update() {
        name.stringValue = artist?.name ?? track?.artists?.first?.name ?? (trackURI == nil ? "No Spotify track" : "Loading…")
        name.toolTip = name.stringValue
        let album = [track?.album?.name, track?.album?.releaseDate.map { "(\($0.prefix(4)))" }].compactMap { $0 }
        details.stringValue = [album.joined(separator: " "), artist?.genres?.joined(separator: ", ") ?? ""]
            .filter { !$0.isEmpty }.joined(separator: "\n")
        introScroll.isHidden = tab != .about
        table.enclosingScrollView?.isHidden = tab == .about
        spotifyButton.isEnabled = track != nil
        applySkinColors()
    }

    // MARK: Loading

    /// Loads the artist when the playing Spotify track changed; only while the window is visible.
    func trackChanged() {
        guard window?.isVisible == true else { return }
        let uri = app.currentSpotifyTrack
        guard uri != trackURI else { return }
        trackURI = uri
        for task in tasks { task.cancel() }
        tasks = []
        track = nil
        artist = nil
        album = nil
        cover.image = nil
        intro.string = ""
        albumRows = []
        albumsRows = []
        update()
        guard let uri else { return }
        tasks.append(Task { await load(uri) })
    }

    private func load(_ uri: String) async {
        // While the Spotify app plays, the polled state already has the track; Sonos needs a request.
        var track = app.spotify.playback?.item
        if track?.uri != uri {
            do {
                track = try await cached("track:" + uri) { try await self.app.spotify.track(uri) }
            } catch {
                // Not retried until the track changes, so a lasting error doesn't repeat on every poll.
                guard trackURI == uri else { return }
                name.stringValue = "Spotify: \(error.localizedDescription)"
                return
            }
        }
        guard trackURI == uri, let track else { return }
        self.track = track
        update()
        if let url = track.album?.images?.first.flatMap({ URL(string: $0.url) }) {
            part("cover:" + url.absoluteString, load: { try await Self.image(url) }) { [cover] in cover.image = $0 }
        }
        if let albumID = track.album?.id { showAlbum(id: albumID) }
        guard let artistID = track.artists?.first?.id else { return }
        part("artist:" + artistID, load: { try await self.app.spotify.artist(id: artistID) }) { self.artist = $0 }
        intro.string = "Loading…"
        part("intro:" + artistID, load: { await Self.wikipediaIntro(spotifyArtistID: artistID) ?? "" }) { [intro] text in
            intro.string = text.flatMap { $0.isEmpty ? nil : $0 } ?? "No Wikipedia article found."
        }
        albumsRows = [.message("Loading…")]
        part("albums:" + artistID, load: { try await self.app.spotify.albums(ofArtist: artistID) }) { albums in
            let sorted = (albums ?? []).sorted { ($0.releaseDate ?? "") > ($1.releaseDate ?? "") }
            self.albumsRows = sorted.isEmpty ? [.message("No albums available")] : sorted.map(Row.album)
        }
    }

    /// Loads one part in its own task and applies it (nil on failure) unless the track changed meanwhile.
    private func part<T>(_ key: String, load: @escaping () async throws -> T, apply: @escaping (T?) -> Void) {
        let uri = trackURI
        tasks.append(Task {
            let value = try? await cached(key, load)
            guard trackURI == uri, !Task.isCancelled else { return }
            apply(value)
            update()
        })
    }

    private func cached<T>(_ key: String, _ load: () async throws -> T) async throws -> T {
        if let value = cache[key] as? T { return value }
        let value = try await load()
        cache[key] = value
        return value
    }

    /// Fills the Album tab with an album's tracks.
    private func showAlbum(id: String) {
        albumRows = [.message("Loading…")]
        part("album:" + id, load: { try await self.app.spotify.album(id: id) }) { album in
            self.album = album
            guard let album else { return self.albumRows = [.message("Album not available")] }
            let tracks = album.libraryTracks
            let year = album.releaseDate.map { " (\($0.prefix(4)))" } ?? ""
            self.albumRows = [.message(album.name + year)] + tracks.indices.map { .track(tracks[$0], index: $0, of: tracks) }
        }
    }

    private nonisolated static func image(_ url: URL) async throws -> NSImage {
        guard let data = await data(url), let image = NSImage(data: data) else { throw URLError(.cannotDecodeContentData) }
        return image
    }

    /// Wikimedia asks clients to identify themselves; the header doesn't hurt Spotify's image CDN.
    private nonisolated static func data(_ url: URL?) async -> Data? {
        guard let url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("MacAmp (https://github.com/andrehickmann/macamp)", forHTTPHeaderField: "User-Agent")
        return try? await URLSession.shared.data(for: request).0
    }

    /// Intro of the artist's Wikipedia article in the user's language, else English.
    private nonisolated static func wikipediaIntro(spotifyArtistID id: String?) async -> String? {
        struct Summary: Decodable { var extract: String? }
        let languages = Locale.preferredLanguages.compactMap { Locale(identifier: $0).language.languageCode?.identifier } + ["en"]
        guard let id, let query = ArtistWiki.articlesQuery(spotifyArtistID: id, languages: languages),
              let result = await data(query), let summary = ArtistWiki.summaryURL(fromQueryResult: result, languages: languages),
              let json = await data(summary) else { return nil }
        return try? JSONDecoder().decode(Summary.self, from: json).extract
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SkinRowView(selection: NSColor(cgColor: skin.playlistStyle.selectedBackground) ?? .blue)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        let style = skin.playlistStyle
        let isInfo = tableColumn?.identifier.rawValue == "info"
        let text: String
        var color = NSColor(cgColor: style.normal) ?? .green
        switch rows[index] {
        case .track(let track, let number, _):
            text = isInfo ? TimeDisplay.string(seconds: track.duration ?? 0) : "\(number + 1). \(track.title ?? "")"
            if track.url.absoluteString == trackURI { color = NSColor(cgColor: style.current) ?? .white }
        case .album(let album):
            let type = album.albumType == "single" ? " · Single" : ""
            text = isInfo ? String((album.releaseDate ?? "").prefix(4)) : album.name + type
        case .message(let message):
            text = isInfo ? "" : message
            color = color.withAlphaComponent(0.6)
        }
        let field = NSTextField(labelWithString: text)
        field.font = NSFont(name: style.fontName, size: 11) ?? .systemFont(ofSize: 11)
        field.textColor = color
        field.alignment = isInfo ? .right : .left
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    // MARK: Actions

    @objc private func tabChanged() { update() }

    private var targetRow: Row? {
        let index = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        return rows.indices.contains(index) ? rows[index] : nil
    }

    /// Double-click: a track plays its album from there, an album opens in the Album tab.
    @objc private func openRow() {
        switch targetRow {
        case .track(_, let index, let tracks): app.playLibraryTracks(tracks, startingAt: index)
        case .album(let album):
            guard let id = album.id else { return }
            showAlbum(id: id)
            tabs.selectedSegment = Tab.album.rawValue
            update()
        default: break
        }
    }

    private func rowMenu() -> NSMenu {
        let menu = NSMenu()
        for (title, action) in [("Play", #selector(playRow)), ("Enqueue", #selector(enqueueRow)),
                                ("Open in Spotify", #selector(openRowInSpotify))] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        return menu
    }

    /// The clicked track, or all tracks of the clicked album once loaded.
    private func withTargetTracks(_ use: @escaping ([LibraryTrack]) -> Void) {
        switch targetRow {
        case .track(let track, _, _): use([track])
        case .album(let album):
            guard let id = album.id else { return }
            Task { if let album = try? await cached("album:" + id, { try await self.app.spotify.album(id: id) }) { use(album.libraryTracks) } }
        default: break
        }
    }

    @objc private func playRow() {
        if case .track(_, let index, let tracks) = targetRow { return app.playLibraryTracks(tracks, startingAt: index) }
        withTargetTracks { [app] in app.playLibraryTracks($0) }
    }

    @objc private func enqueueRow() { withTargetTracks { [app] in app.enqueueLibraryTracks($0) } }

    @objc private func openRowInSpotify() {
        switch targetRow {
        case .track(let track, _, _): Self.openInSpotify(track.url.absoluteString)
        case .album(let album): album.uri.map(Self.openInSpotify)
        default: break
        }
    }

    @objc private func openShownInSpotify() {
        let artistURI = (artist?.id ?? track?.artists?.first?.id).map { "spotify:artist:" + $0 }
        if let uri = tab == .album ? album?.uri ?? track?.album?.uri : artistURI { Self.openInSpotify(uri) }
    }

    /// Opens a `spotify:` URI in the Spotify app, else on open.spotify.com.
    private static func openInSpotify(_ uri: String) {
        guard let url = URL(string: uri) else { return }
        if NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
        } else if let web = URL(string: "https://open.spotify.com/" + uri.split(separator: ":").dropFirst().joined(separator: "/")) {
            NSWorkspace.shared.open(web)
        }
    }
}
