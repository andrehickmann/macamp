import AppKit
import AuthenticationServices
import AVFoundation
import MacAmpCore
import UniformTypeIdentifiers

/// Owns the player, the playlist, the three skinned windows and the persisted settings.
@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    struct TrackInfo {
        let kbps: Int
        let kHz: Int
    }

    let player = Player()
    let spotify = SpotifyClient()
    let sonos = SonosClient()
    /// The source the windows control.
    var transport: any Transport {
        if sonos.isActive { return sonos }
        return spotify.isActive ? spotify : player
    }
    private(set) var spotifyPlaylists: [SpotifyPlaylist] = []
    /// Spotify tracks seen in the library, so dropped `spotify:` URLs get a title and length.
    private var spotifyTracks: [URL: LibraryTrack] = [:]
    /// Playlist index of the first track of the run handed to Spotify.
    private var spotifyRunStart = 0
    /// Playlist index of the first track of the run queued on Sonos.
    private var sonosRunStart = 0
    private(set) var skin: Skin!
    private var skinURL: URL?
    var playlist = Playlist() {
        didSet {
            playlistView?.needsDisplay = true
            if oldValue.current != playlist.current { libraryView?.playlistChanged() }
        }
    }
    var equalizer = EqualizerSettings() {
        didSet {
            player.apply(equalizer)
            rememberAutoPreset(oldValue)
            equalizerView?.needsDisplay = true
        }
    }
    var shuffle = false
    var repeatAll = false
    private(set) var trackInfo: TrackInfo?
    /// kbps/kHz for the main window. Spotify's DRM-protected streams can't be measured, so they show Spotify's
    /// nominal Premium quality: AAC 256 kbps in the web player, 320 kbps on Sonos. The Spotify app's quality
    /// depends on its own settings and stays blank.
    var displayedTrackInfo: TrackInfo? {
        if sonos.isActive, sonos.playback?.uri?.hasPrefix("x-sonos-spotify:") == true, sonos.state != .stopped {
            return TrackInfo(kbps: 320, kHz: 44)
        }
        if spotify.isActive, spotify.state != .stopped, spotify.playback?.device?.name == WebPlayer.deviceName {
            return TrackInfo(kbps: 256, kHz: 44)
        }
        return trackInfo
    }
    /// "[Connecting]" and similar while a stream or Spotify has no title yet.
    private(set) var statusMessage: String?
    private(set) var mainShade = false
    private(set) var equalizerShade = false
    private(set) var playlistShade = false
    private(set) var doubleSize = false
    private(set) var playlistSize = CGSize(width: 275, height: 232)
    private(set) var librarySize = CGSize(width: 550, height: 348)
    private(set) var roomsSize = CGSize(width: 500, height: 203)
    private(set) var artistSize = CGSize(width: 500, height: 232)
    private(set) var library = Library() {
        didSet { libraryView?.libraryChanged() }
    }
    /// "Scanning 120/5000" while the library folders are being read.
    private(set) var libraryScanStatus: String?

    private var mainWindow: SkinWindow!
    private var equalizerWindow: SkinWindow!
    private var playlistWindow: SkinWindow!
    private var libraryWindow: SkinWindow!
    private var roomsWindow: SkinWindow!
    private var artistWindow: SkinWindow!
    private var mainView: MainWindowView!
    private var equalizerView: EqualizerView?
    private var playlistView: PlaylistView?
    private var libraryView: LibraryView?
    private var roomsView: RoomsView?
    private var artistView: ArtistView?
    private var nowPlaying: NowPlaying?
    private var windowDrag: (mouse: CGPoint, primary: NSWindow, origins: [(NSWindow, CGPoint)])?
    /// Per-file equalizer curves for EQ "Auto": path → [preamp] + bands.
    private var autoPresets: [String: [Float]] = [:]
    private var isApplyingAutoPreset = false
    private var launched = false
    private var pendingFiles: [URL] = []
    private var tick = 0
    /// `SystemAudioTap` on macOS 14.2+ (stored untyped because of its availability).
    private var audioTap: AnyObject?
    private var audioTapFailed = false

    private var skinWindows: [SkinWindow] { [mainWindow, equalizerWindow, playlistWindow, libraryWindow, roomsWindow, artistWindow].compactMap { $0 } }
    var equalizerVisible: Bool { equalizerWindow?.isVisible ?? false }
    var playlistVisible: Bool { playlistWindow?.isVisible ?? false }
    var libraryVisible: Bool { libraryWindow?.isVisible ?? false }
    var roomsVisible: Bool { roomsWindow?.isVisible ?? false }
    var artistVisible: Bool { artistWindow?.isVisible ?? false }
    /// Snapshot runs must not touch the user's settings, window positions or library.
    private var isSnapshotRun: Bool { UserDefaults.standard.string(forKey: "snapshot") != nil }
    private static let supportFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MacAmp")
    private static let libraryFile = supportFolder.appendingPathComponent("library.json")
    /// Skins the user added; they show up in the Skins menu next to the bundled ones.
    private static let userSkinsFolder = supportFolder.appendingPathComponent("Skins")
    /// Bundled skins (Contents/Resources/Skins in the app, Resources/Skins under `swift run`), then the user's.
    private static let skinFolders: [URL] = [
        Bundle.main.resourceURL?.appendingPathComponent("Skins"),
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Resources/Skins").standardized,
        userSkinsFolder,
    ].compactMap { $0 }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let skin = loadInitialSkin() else {
            NSApp.terminate(nil)
            return
        }
        self.skin = skin
        restoreSettings()
        loadLibrary()

        mainView = MainWindowView(app: self)
        let equalizerView = EqualizerView(app: self)
        let playlistView = PlaylistView(app: self)
        self.equalizerView = equalizerView
        self.playlistView = playlistView
        let (main, mainRestored) = makeWindow(mainView, name: "MainWindow", title: "MacAmp")
        let (equalizer, equalizerRestored) = makeWindow(equalizerView, name: "EqualizerWindow", title: "MacAmp Equalizer")
        let (playlist, playlistRestored) = makeWindow(playlistView, name: "PlaylistWindow", title: "MacAmp Playlist")
        let libraryView = LibraryView(app: self)
        self.libraryView = libraryView
        let (library, libraryRestored) = makeWindow(libraryView, name: "LibraryWindow", title: "MacAmp Library")
        libraryWindow = library
        let roomsView = RoomsView(app: self)
        self.roomsView = roomsView
        let (rooms, roomsRestored) = makeWindow(roomsView, name: "RoomsWindow", title: "MacAmp Rooms")
        roomsWindow = rooms
        let artistView = ArtistView(app: self)
        self.artistView = artistView
        let (artist, artistRestored) = makeWindow(artistView, name: "ArtistWindow", title: "MacAmp Artist")
        artistWindow = artist
        mainWindow = main
        equalizerWindow = equalizer
        playlistWindow = playlist
        for view in [mainView, equalizerView, playlistView, libraryView, roomsView, artistView] as [SkinView] { updateSize(of: view) }

        // First launch: stack equalizer and playlist below the main window, like the original.
        if !mainRestored { main.center() }
        if !equalizerRestored { equalizer.setFrameTopLeftPoint(CGPoint(x: main.frame.minX, y: main.frame.minY)) }
        if !playlistRestored { playlist.setFrameTopLeftPoint(CGPoint(x: equalizer.frame.minX, y: equalizer.frame.minY)) }
        if !libraryRestored { library.setFrameTopLeftPoint(CGPoint(x: main.frame.maxX, y: main.frame.maxY)) }
        if !roomsRestored { rooms.setFrameTopLeftPoint(CGPoint(x: library.frame.minX, y: library.frame.minY)) }
        if !artistRestored { artist.setFrameTopLeftPoint(CGPoint(x: rooms.frame.minX, y: rooms.frame.minY)) }

        main.makeKeyAndOrderFront(nil)
        main.makeFirstResponder(mainView)
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "equalizerVisible") as? Bool ?? true { equalizer.orderFront(nil) }
        if defaults.object(forKey: "playlistVisible") as? Bool ?? true { playlist.orderFront(nil) }
        if defaults.bool(forKey: "libraryVisible") { library.orderFront(nil) }
        if defaults.bool(forKey: "roomsVisible") { rooms.orderFront(nil) }
        if defaults.bool(forKey: "artistVisible") { artist.orderFront(nil) }
        artistView.trackChanged()
        NSApp.mainMenu = makeMainMenu()
        NSApp.activate()

        nowPlaying = NowPlaying(app: self)
        player.onTrackEnd = { [weak self] in self?.trackEnded() }
        player.onChange = { [weak self] in self?.nowPlaying?.update() }
        player.onStreamTitle = { [weak self] title in self?.streamTitleChanged(title) }
        spotify.onChange = { [weak self] in
            self?.refreshViews()
            self?.nowPlaying?.update()
        }
        spotify.onRunIndex = { [weak self] offset in self?.spotifyRunMoved(to: offset) }
        spotify.onRunFinished = { [weak self] in self?.trackEnded() }
        spotify.onStartFailed = { [weak self] in
            self?.statusMessage = "[Spotify did not start playback – try playing once in the Spotify app]"
            self?.refreshViews()
        }
        if spotify.isConnected { loadSpotifyPlaylists() }
        sonos.onChange = { [weak self] in
            self?.refreshViews()
            self?.roomsView?.roomsChanged()
        }
        sonos.onRunIndex = { [weak self] offset in self?.sonosRunMoved(to: offset) }
        sonos.isWatched = roomsVisible
        player.onStreamInfo = { [weak self] info in self?.streamInfoChanged(info) }
        player.onStreamFailure = { [weak self] message in
            NSLog("MacAmp: stream failed: \(message)")
            self?.statusMessage = "[\(message)]"
        }
        player.apply(self.equalizer)
        loadInfo(for: self.playlist.entries)

        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.animate() }
        }
        RunLoop.main.add(timer, forMode: .common)

        launched = true
        let files = pendingFiles + Self.fileArguments()
        pendingFiles = []
        if !files.isEmpty { open(files, replacing: true) }
        if let folder = defaults.string(forKey: "libraryFolder") { addLibraryFolders([URL(fileURLWithPath: folder)]) }
        if let path = defaults.string(forKey: "snapshot") { writeSnapshots(to: path) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        guard launched, !isSnapshotRun else { return }
        saveSettings()
        saveLibrary()
    }

    /// Files opened from Finder replace the playlist; skins are added and applied.
    func application(_ application: NSApplication, open urls: [URL]) {
        open(urls, replacing: true)
    }

    private func animate() {
        tick += 1
        if tick % 15 == 0 { updateVisualizerTap() }
        mainView.animate()
        if tick % 10 == 0 { playlistView?.needsDisplay = true }
    }

    /// Bars for the spectrum analyzer: the local player's, or Spotify's captured from the system while it plays here.
    var visualizerBars: [Float]? {
        if player.state == .playing { return player.analyzer.bars }
        if #available(macOS 14.2, *), let tap = audioTap as? SystemAudioTap, tap.isRunning { return tap.analyzer.bars }
        return nil
    }

    /// Runs the system audio tap only while Spotify plays and Sonos isn't the output (on another device the tap
    /// just hears nothing). Gives up after a failure, e.g. denied permission.
    private func updateVisualizerTap() {
        guard #available(macOS 14.2, *) else { return }
        let wanted = spotify.isActive && !sonos.isActive && spotify.state == .playing
        let tap = audioTap as? SystemAudioTap
        if wanted, tap?.isRunning != true, !audioTapFailed {
            let tap = tap ?? SystemAudioTap()
            audioTap = tap
            do {
                try tap.start()
            } catch {
                audioTapFailed = true
                NSLog("MacAmp: visualizer tap unavailable: \(error.localizedDescription)")
            }
        } else if !wanted, let tap, tap.isRunning {
            tap.stop()
        }
    }

    // MARK: Playlist and playback

    /// Adds files, folders and playlist files; `replacing` starts a new list and plays it.
    /// `.wsz` skins are added to the Skins menu and applied right away, even before launch.
    func open(_ urls: [URL], replacing: Bool) {
        if let skinURL = urls.last(where: Self.isSkinFile) { addSkin(skinURL) }
        let urls = urls.filter { !Self.isSkinFile($0) }
        guard !urls.isEmpty else { return }
        guard launched else {
            pendingFiles += urls
            return
        }
        let entries = expand(urls)
        guard !entries.isEmpty else { return }
        if replacing {
            player.stop()
            playlist = Playlist(entries: entries)
            playTrack(at: 0)
        } else {
            playlist.entries += entries
        }
        loadInfo(for: entries)
    }

    /// The `spotify:track:` URI playing in the Spotify app or on Sonos from the playlist.
    var currentSpotifyTrack: String? {
        if spotify.isActive { return spotify.playback?.item?.uri }
        guard let current = playlist.current, playlist.entries.indices.contains(current),
              playlist.entries[current].url.scheme == "spotify" else { return nil }
        return playlist.entries[current].url.absoluteString
    }

    var currentTitle: String {
        guard let current = playlist.current, playlist.entries.indices.contains(current) else { return "MacAmp" }
        return playlist.entries[current].displayTitle
    }

    /// "1. Artist - Title (3:45)" as shown in the main window; streams show no length.
    var marqueeText: String {
        if sonos.isActive, !sonos.isPlayingRunItem, let playback = sonos.playback, playback.state != .stopped,
           let title = playback.displayTitle {
            return playback.duration > 0 ? "\(title) (\(TimeDisplay.string(seconds: playback.duration)))" : title
        }
        if spotify.isActive, !spotify.isPlayingRunItem, let item = spotify.playback?.item?.libraryTrack {
            return "\(item.displayTitle) (\(TimeDisplay.string(seconds: item.duration ?? 0)))"
        }
        guard let current = playlist.current, playlist.entries.indices.contains(current) else { return "MACAMP" }
        let entry = playlist.entries[current]
        if let statusMessage { return "\(current + 1). \(statusMessage)" }
        guard let duration = entry.duration ?? (player.file != nil ? player.duration : nil) else {
            return "\(current + 1). \(entry.displayTitle)"
        }
        return "\(current + 1). \(entry.displayTitle) (\(TimeDisplay.string(seconds: duration)))"
    }

    func play() {
        if sonos.isActive {
            return sonos.state == .paused ? sonos.resume() : playTrack(at: playlist.current ?? playlist.selection.first ?? 0)
        }
        if spotify.isActive, spotify.state == .paused { return spotify.resume() }
        if (player.file == nil && player.streamURL == nil) || playlist.current == nil {
            playTrack(at: playlist.current ?? playlist.selection.first ?? 0)
        } else {
            player.play()
        }
    }

    func next() {
        if sonos.isActive, !sonos.isFollowingRun { return sonos.skip(forward: true) }
        if spotify.isActive, !spotify.isFollowingRun { return spotify.skip(forward: true) }
        if let index = playlist.index(after: playlist.current, shuffle: shuffle, repeatAll: true) { playTrack(at: index) }
    }

    func previous() {
        if sonos.isActive, !sonos.isFollowingRun { return sonos.skip(forward: false) }
        if spotify.isActive, !spotify.isFollowingRun { return spotify.skip(forward: false) }
        if let index = playlist.index(before: playlist.current, repeatAll: true) { playTrack(at: index) }
    }

    private func trackEnded() {
        if let index = playlist.index(after: playlist.current, shuffle: shuffle, repeatAll: repeatAll) {
            playTrack(at: index)
        }
    }

    func playTrack(at index: Int) {
        guard playlist.entries.indices.contains(index) else { return }
        playlist.current = index
        let url = playlist.entries[index].url
        statusMessage = nil
        if sonos.isActive { return playOnSonos(at: index) }
        if url.scheme == "spotify" { return playSpotify(at: index) }
        spotify.release()
        guard url.isFileURL else { return playStream(url, at: index) }
        do {
            try player.load(url)
        } catch {
            NSLog("MacAmp: cannot open \(url.path): \(error)")
            trackInfo = nil
            return
        }
        applyAutoPreset(for: url)
        library.recordPlay(of: url)
        player.play()
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let duration = player.duration
        trackInfo = TrackInfo(kbps: duration > 0 ? Int(Double(size) * 8 / duration / 1000) : 0,
                              kHz: Int(((player.file?.processingFormat.sampleRate ?? 0) / 1000).rounded()))
        if playlist.entries[index].duration == nil { playlist.entries[index].duration = duration }
        nowPlaying?.update()
    }

    /// Hands this entry and the Spotify entries directly after it to Spotify (one entry when shuffling).
    private func playSpotify(at index: Int) {
        player.stop()
        trackInfo = nil
        guard spotify.isConnected else {
            statusMessage = "[Spotify not connected]"
            return
        }
        let uris = playlist.entries[index...].prefix { $0.url.scheme == "spotify" }.prefix(shuffle ? 1 : 100).map(\.url.absoluteString)
        spotifyRunStart = index
        statusMessage = "[Connecting to Spotify]"
        Task {
            do {
                try await spotify.play(uris: uris)
                statusMessage = nil
            } catch {
                statusMessage = "[Spotify: \(error.localizedDescription)]"
            }
            refreshViews()
        }
    }

    /// Plays the entry on the Sonos output: Spotify entries go into the group's queue (a run of them, like
    /// `playSpotify`), radio streams play directly. Local files would need MacAmp to serve them over HTTP.
    private func playOnSonos(at index: Int) {
        player.stop()
        spotify.release()
        trackInfo = nil
        let entry = playlist.entries[index]
        guard !entry.url.isFileURL else {
            statusMessage = "[Local files can't play on Sonos]"
            return
        }
        if entry.url.scheme == "spotify", let offset = sonos.runOffset(of: entry.url.absoluteString), sonosRunStart + offset == index {
            return sonos.playRunItem(at: offset)
        }
        statusMessage = "[Connecting to Sonos]"
        Task {
            do {
                if entry.url.scheme == "spotify" {
                    let run = playlist.entries[index...].prefix { $0.url.scheme == "spotify" }.prefix(shuffle ? 1 : 100)
                    sonosRunStart = index
                    try await sonos.play(spotify: run.map { ($0.url.absoluteString, $0.title) })
                } else {
                    try await sonos.play(radio: await Self.resolveStream(entry.url), title: entry.title)
                }
                statusMessage = nil
            } catch {
                statusMessage = "[Sonos: \(error.localizedDescription)]"
            }
            refreshViews()
        }
    }

    private func sonosRunMoved(to offset: Int) {
        let index = sonosRunStart + offset
        guard playlist.entries.indices.contains(index), playlist.current != index else { return }
        playlist.current = index
        library.recordPlay(of: playlist.entries[index].url)
    }

    /// Sets up Spotify playback on Sonos with the user's account (see `SonosClient.connectSpotify`), testing on
    /// the output group or else the first one.
    func connectSonos() {
        guard spotify.isConnected else {
            roomsView?.showMessage("Connect Spotify first (File › Connect Spotify…)")
            return
        }
        guard let group = sonos.outputGroup ?? sonos.groups.first else { return }
        let spotify = spotify
        Task {
            do {
                try await sonos.connectSpotify(on: group, isOwnAccountPlaying: { await spotify.isAccountPlaying() }) { account in
                    roomsView?.showMessage("Connecting on \(group.name) (muted), account \(account)…")
                }
                roomsView?.showMessage("Connected – Spotify plays on Sonos with your account")
                try? await Task.sleep(for: .seconds(6))
                roomsView?.showMessage(nil)
            } catch {
                roomsView?.showMessage("Connect Sonos: \(error.localizedDescription)")
            }
        }
    }

    /// Chooses where MacAmp plays: a Sonos room (with its group) or this Mac (nil).
    func setSonosOutput(_ room: String?) {
        guard room != sonos.outputRoom else { return }
        if room != nil {
            player.stop()
            spotify.release()
        }
        sonos.outputRoom = room
        statusMessage = nil
        refreshViews()
        nowPlaying?.update()
    }

    private func spotifyRunMoved(to offset: Int) {
        let index = spotifyRunStart + offset
        guard playlist.entries.indices.contains(index), playlist.current != index else { return }
        playlist.current = index
        library.recordPlay(of: playlist.entries[index].url)
    }

    private func playStream(_ url: URL, at index: Int) {
        player.stop()
        trackInfo = nil
        statusMessage = "[Connecting]"
        Task {
            let resolved = await Self.resolveStream(url)
            guard playlist.current == index, playlist.entries.indices.contains(index), playlist.entries[index].url == url else { return }
            player.playStream(resolved)
        }
    }

    /// Shoutcast directories hand out .pls/.m3u files; play their first entry.
    private nonisolated static func resolveStream(_ url: URL) async -> URL {
        let fileExtension = url.pathExtension.lowercased()
        guard ["pls", "m3u"].contains(fileExtension),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return url }
        return PlaylistFile.parse(text, extension: fileExtension, relativeTo: url.deletingLastPathComponent()).first?.url ?? url
    }

    private func streamTitleChanged(_ title: String) {
        statusMessage = nil
        if let current = playlist.current, playlist.entries.indices.contains(current) { playlist.entries[current].title = title }
        nowPlaying?.update()
    }

    private func streamInfoChanged(_ info: StreamDecoder.Info) {
        let kbps = info.bitrate ?? trackInfo?.kbps ?? 0
        let kHz = info.sampleRate.map { Int(($0 / 1000).rounded()) } ?? trackInfo?.kHz ?? 0
        trackInfo = TrackInfo(kbps: kbps, kHz: kHz)
        if let name = info.name, let current = playlist.current, playlist.entries.indices.contains(current),
           playlist.entries[current].title == nil {
            playlist.entries[current].title = name
        }
        if info.sampleRate != nil, statusMessage == "[Connecting]" { statusMessage = nil }
    }

    func handle(_ command: NowPlaying.Command) {
        switch command {
        case .play: play()
        case .pause: if transport.state == .playing { transport.pause() }
        case .toggle: transport.state == .stopped ? play() : transport.pause()
        case .stop: transport.stop()
        case .next: next()
        case .previous: previous()
        case .seek(let seconds): transport.seek(to: seconds)
        }
        refreshViews()
    }

    func rememberSpotifyTracks(_ tracks: [LibraryTrack]) {
        for track in tracks { spotifyTracks[track.url] = track }
    }

    private func expand(_ urls: [URL]) -> [PlaylistEntry] {
        urls.flatMap { url -> [PlaylistEntry] in
            if url.scheme == "spotify" {
                let track = spotifyTracks[url]
                return [PlaylistEntry(url: url, title: track?.displayTitle, duration: track?.duration)]
            }
            let fileExtension = url.pathExtension.lowercased()
            if ["m3u", "m3u8", "pls"].contains(fileExtension) {
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) ?? ""
                return PlaylistFile.parse(text, extension: fileExtension, relativeTo: url.deletingLastPathComponent())
            }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
                return files.filter(Self.isAudio)
                    .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                    .map { PlaylistEntry(url: $0) }
            }
            return [PlaylistEntry(url: url)]
        }
    }

    private static func isAudio(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) ?? false
    }

    /// Fills in tag titles and durations in the background, one file at a time.
    private func loadInfo(for entries: [PlaylistEntry]) {
        let urls = entries.filter { $0.url.isFileURL && ($0.title == nil || $0.duration == nil) }.map(\.url)
        guard !urls.isEmpty else { return }
        Task {
            for url in urls {
                let tags = await Tags.read(from: url)
                for index in playlist.entries.indices where playlist.entries[index].url == url {
                    if playlist.entries[index].title == nil { playlist.entries[index].title = tags.displayTitle }
                    if playlist.entries[index].duration == nil { playlist.entries[index].duration = tags.duration }
                }
            }
        }
    }

    // MARK: Equalizer

    func applyPreset(_ bands: [Float]) {
        equalizer.bands = bands
    }

    private func applyAutoPreset(for url: URL) {
        guard equalizer.auto, let values = autoPresets[url.path], values.count == 11 else { return }
        isApplyingAutoPreset = true
        var settings = equalizer
        settings.preamp = values[0]
        settings.bands = Array(values.dropFirst())
        equalizer = settings
        isApplyingAutoPreset = false
    }

    private func rememberAutoPreset(_ old: EqualizerSettings) {
        guard equalizer.auto, !isApplyingAutoPreset, old.bands != equalizer.bands || old.preamp != equalizer.preamp,
              let current = playlist.current, playlist.entries.indices.contains(current) else { return }
        autoPresets[playlist.entries[current].url.path] = [equalizer.preamp] + equalizer.bands
    }

    // MARK: Windows

    private func makeWindow(_ view: SkinView, name: String, title: String) -> (SkinWindow, restored: Bool) {
        let window = SkinWindow(contentRect: CGRect(origin: .zero, size: view.logicalSize),
                                styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = title
        window.contentView = view
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        let restored = window.setFrameUsingName(name)
        // Snapshot runs must not overwrite the user's window positions.
        if UserDefaults.standard.string(forKey: "snapshot") == nil { window.setFrameAutosaveName(name) }
        return (window, restored)
    }

    /// Applies a view's size (shade, double size, playlist size), keeping its top-left corner
    /// and moving windows docked below it along with its bottom edge.
    private func updateSize(of view: SkinView) {
        guard let window = view.window else { return }
        let scale: CGFloat = view.followsDoubleSize && doubleSize ? 2 : 1
        let size = CGSize(width: view.logicalSize.width * scale, height: view.logicalSize.height * scale)
        let old = window.frame
        if old.size != size {
            let others = skinWindows.filter { $0 !== window && $0.isVisible }
            let group = WindowSnapping.docked(to: 0, in: [old] + others.map(\.frame))
            let followers = others.enumerated()
                .filter { group.contains($0.offset + 1) && $0.element.frame.maxY <= old.minY + 1 }
                .map(\.element)
            window.setFrame(CGRect(x: old.minX, y: old.maxY - size.height, width: size.width, height: size.height), display: false)
            let dy = window.frame.minY - old.minY
            for follower in followers { follower.setFrameOrigin(CGPoint(x: follower.frame.minX, y: follower.frame.minY + dy)) }
        }
        view.setBoundsSize(view.logicalSize)
        view.needsDisplay = true
        DispatchQueue.main.async { window.invalidateShadow() }
    }

    func toggleMainShade() {
        mainShade.toggle()
        updateSize(of: mainView)
    }

    func toggleEqualizerShade() {
        equalizerShade.toggle()
        if let equalizerView { updateSize(of: equalizerView) }
    }

    func togglePlaylistShade() {
        playlistShade.toggle()
        if let playlistView { updateSize(of: playlistView) }
    }

    func setPlaylistSize(_ size: CGSize) {
        guard size != playlistSize else { return }
        playlistSize = size
        if let playlistView { updateSize(of: playlistView) }
    }

    func setLibrarySize(_ size: CGSize) {
        guard size != librarySize else { return }
        librarySize = size
        if let libraryView { updateSize(of: libraryView) }
    }

    func setArtistSize(_ size: CGSize) {
        guard size != artistSize else { return }
        artistSize = size
        if let artistView { updateSize(of: artistView) }
    }

    @objc func toggleArtist() {
        toggleVisibility(of: artistWindow)
        artistView?.trackChanged()
    }

    func setRoomsSize(_ size: CGSize) {
        guard size != roomsSize else { return }
        roomsSize = size
        if let roomsView { updateSize(of: roomsView) }
    }

    @objc func toggleRooms() {
        toggleVisibility(of: roomsWindow)
        sonos.isWatched = roomsVisible
        if roomsVisible { roomsWindow.makeKey() }
    }

    @objc func toggleLibrary() {
        toggleVisibility(of: libraryWindow)
        if libraryVisible { libraryWindow.makeKey() }
    }

    @objc func toggleMainShadeAction() { toggleMainShade() }

    @objc func toggleDoubleSize() {
        doubleSize.toggle()
        updateSize(of: mainView)
        if let equalizerView { updateSize(of: equalizerView) }
    }

    @objc func toggleEqualizer() { toggleVisibility(of: equalizerWindow) }
    @objc func togglePlaylist() { toggleVisibility(of: playlistWindow) }

    private func toggleVisibility(of window: NSWindow) {
        if window.isVisible { window.orderOut(nil) } else { window.orderFront(nil) }
        mainView.needsDisplay = true
    }

    func beginWindowDrag(_ window: NSWindow) {
        let visible = skinWindows.filter(\.isVisible)
        var group: [NSWindow] = [window]
        // Dragging the main window moves everything docked to it; other windows move alone.
        if window === mainWindow, let root = visible.firstIndex(where: { $0 === window }) {
            group = WindowSnapping.docked(to: root, in: visible.map(\.frame)).map { visible[$0] }
        }
        windowDrag = (NSEvent.mouseLocation, window, group.map { ($0, $0.frame.origin) })
    }

    func continueWindowDrag() {
        guard let drag = windowDrag, let start = drag.origins.first(where: { $0.0 === drag.primary })?.1 else { return }
        let mouse = NSEvent.mouseLocation
        var proposed = drag.primary.frame
        proposed.origin = CGPoint(x: start.x + mouse.x - drag.mouse.x, y: start.y + mouse.y - drag.mouse.y)
        let others = skinWindows.filter { window in window.isVisible && !drag.origins.contains { $0.0 === window } }
        let snapped = WindowSnapping.snap(proposed, to: others.map(\.frame), screen: drag.primary.screen?.visibleFrame)
        let offset = CGPoint(x: snapped.minX - start.x, y: snapped.minY - start.y)
        for (window, origin) in drag.origins {
            window.setFrameOrigin(CGPoint(x: origin.x + offset.x, y: origin.y + offset.y))
        }
    }

    private func refreshViews() {
        for window in skinWindows { window.contentView?.needsDisplay = true }
        artistView?.trackChanged()
    }

    // MARK: Media library

    func isCurrent(_ url: URL) -> Bool {
        guard let current = playlist.current, playlist.entries.indices.contains(current) else { return false }
        return playlist.entries[current].url.standardizedFileURL.path == url.standardizedFileURL.path
    }

    private func entries(for tracks: [LibraryTrack]) -> [PlaylistEntry] {
        tracks.map { PlaylistEntry(url: $0.url, title: $0.title == nil ? nil : $0.displayTitle, duration: $0.duration) }
    }

    func playLibraryTracks(_ tracks: [LibraryTrack], startingAt index: Int = 0) {
        guard tracks.indices.contains(index) else { return }
        player.stop()
        playlist = Playlist(entries: entries(for: tracks))
        playTrack(at: index)
    }

    func enqueueLibraryTracks(_ tracks: [LibraryTrack]) {
        playlist.entries += entries(for: tracks)
    }

    func addLibraryFolder() {
        if let folders = chooseFiles(directories: true) { addLibraryFolders(folders) }
    }

    func addLibraryFolders(_ folders: [URL]) {
        let new = folders.map(\.standardizedFileURL).filter { !library.folders.contains($0) }
        guard !new.isEmpty else { return }
        library.folders += new
        rescanLibrary()
    }

    func rescanLibrary() {
        guard libraryScanStatus == nil else { return }
        libraryScanStatus = "Scanning…"
        libraryView?.updateStatus()
        let folders = library.folders
        let known = Dictionary(library.tracks.compactMap { track in track.fileModified.map { (track.url, $0) } },
                               uniquingKeysWith: { first, _ in first })
        Task {
            let result = await LibraryScanner.scan(folders: folders, known: known) { done, total in
                Task { @MainActor in
                    self.libraryScanStatus = "Scanning \(done)/\(total)"
                    self.libraryView?.updateStatus()
                }
            }
            library.merge(result.tracks, present: result.present, scannedFolders: folders)
            libraryScanStatus = nil
            libraryView?.updateStatus()
            saveLibrary()
        }
    }

    func rate(_ urls: [URL], stars: Int) {
        for url in urls { if let index = library.index(of: url) { library.tracks[index].rating = stars } }
        saveLibrary()
    }

    func removeFromLibrary(_ urls: [URL]) {
        let paths = Set(urls.map { $0.standardizedFileURL.path })
        library.tracks.removeAll { paths.contains($0.url.standardizedFileURL.path) }
        saveLibrary()
    }

    func savePlaylistToLibrary() {
        guard !playlist.entries.isEmpty,
              let name = askForText("Save Playlist to Library", "Name of the playlist:", placeholder: "My Playlist", button: "Save") else { return }
        library.playlists.append(SavedPlaylist(name: name, entries: playlist.entries))
        saveLibrary()
    }

    /// Where tracks can be added: Spotify's Liked Songs, a library playlist or one of the user's Spotify playlists.
    enum PlaylistTarget {
        case liked
        case library(Int)
        case spotify(SpotifyPlaylist)
    }

    /// Targets for an "Add to Playlist" menu; Spotify targets only take Spotify tracks.
    func playlistTargets(acceptingSpotify: Bool) -> [(title: String, target: PlaylistTarget?)] {
        var targets: [(String, PlaylistTarget?)] = library.playlists.enumerated().map { ($1.name, .library($0)) }
        if spotify.isConnected {
            targets.append(("Liked Songs", acceptingSpotify ? .liked : nil))
            targets += spotifyPlaylists.filter(spotify.canEdit).map { ($0.name, acceptingSpotify ? .spotify($0) : nil) }
        }
        return targets
    }

    /// "Add to Playlist" items for `urls`; disabled where a target can't take them.
    func addToPlaylistItems(for urls: [URL]) -> [NSMenuItem] {
        let targets = playlistTargets(acceptingSpotify: urls.contains { $0.absoluteString.hasPrefix("spotify:track:") })
        guard !targets.isEmpty else { return [NSMenuItem(title: "No Playlists", action: nil, keyEquivalent: "")] }
        return targets.map { title, target in
            let item = NSMenuItem(title: title, action: target == nil ? nil : #selector(addToPlaylist(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = target.map { ($0, urls) }
            return item
        }
    }

    @objc private func addToPlaylist(_ sender: NSMenuItem) {
        guard let (target, urls) = sender.representedObject as? (PlaylistTarget, [URL]) else { return }
        add(urls, to: target)
    }

    /// Adds tracks; local files only go into library playlists.
    func add(_ urls: [URL], to target: PlaylistTarget) {
        if case .library(let index) = target {
            guard library.playlists.indices.contains(index) else { return }
            library.playlists[index].entries += expand(urls)
            return saveLibrary()
        }
        let uris = urls.filter { $0.absoluteString.hasPrefix("spotify:track:") }.map(\.absoluteString)
        let skipped = urls.count - uris.count
        let name = if case .spotify(let playlist) = target { playlist.name } else { "Liked Songs" }
        guard !uris.isEmpty else {
            libraryView?.showStatus("Only Spotify tracks can be added to \(name)")
            return
        }
        Task {
            do {
                switch target {
                case .spotify(let playlist):
                    try await spotify.add(uris, toPlaylist: playlist.id)
                    libraryView?.spotifyPlaylistChanged(playlist.id)
                default:
                    try await spotify.like(uris)
                    libraryView?.likedSongsChanged()
                }
                libraryView?.showStatus("Added \(uris.count) to \(name)" + (skipped > 0 ? " (\(skipped) local skipped)" : ""))
            } catch {
                libraryView?.showStatus("Spotify: \(error.localizedDescription)")
            }
        }
    }

    func deleteLibraryPlaylist(at index: Int) {
        guard library.playlists.indices.contains(index) else { return }
        library.playlists.remove(at: index)
        saveLibrary()
    }

    private func loadLibrary() {
        guard let data = try? Data(contentsOf: Self.libraryFile) else { return }
        do {
            library = try JSONDecoder().decode(Library.self, from: data)
        } catch {
            NSLog("MacAmp: cannot read library \(Self.libraryFile.path): \(error)")
        }
    }

    private func saveLibrary() {
        guard !isSnapshotRun else { return }
        do {
            try FileManager.default.createDirectory(at: Self.libraryFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(library).write(to: Self.libraryFile, options: .atomic)
        } catch {
            NSLog("MacAmp: cannot save library: \(error)")
        }
    }

    // MARK: Spotify

    @objc func toggleSpotifyConnection() {
        if spotify.isConnected {
            spotify.disconnect()
            spotifyPlaylists = []
            libraryView?.libraryChanged()
            return
        }
        Task {
            do {
                try await spotify.connect()
                loadSpotifyPlaylists()
            } catch {
                if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin { return }
                NSAlert(error: error).runModal()
            }
        }
    }

    @objc func setSpotifyClientID() {
        let saved = UserDefaults.standard.string(forKey: "spotifyClientID") ?? ""
        guard let id = askForText("Spotify Client ID",
                                  "Create an app at developer.spotify.com (Web API and Web Playback SDK, redirect URI "
                                  + "macamp://callback) and paste its Client ID. Leave empty to use MacAmp's default app.",
                                  placeholder: "Default", value: saved, button: "Save", allowEmpty: true),
              id != saved else { return }
        guard id.isEmpty || (id.count == 32 && id.allSatisfy(\.isHexDigit)) else {
            let alert = NSAlert()
            alert.messageText = "Invalid Client ID"
            alert.informativeText = "A Spotify Client ID has 32 hexadecimal characters."
            alert.runModal()
            return
        }
        if id.isEmpty { UserDefaults.standard.removeObject(forKey: "spotifyClientID") }
        else { UserDefaults.standard.set(id, forKey: "spotifyClientID") }
        // The refresh token belongs to the old app.
        if spotify.isConnected { toggleSpotifyConnection() }
    }

    func playSpotifyPlaylist(_ uri: String) {
        player.stop()
        trackInfo = nil
        Task {
            do {
                try await spotify.play(context: uri)
            } catch {
                statusMessage = "[Spotify: \(error.localizedDescription)]"
            }
            refreshViews()
        }
    }

    private var isLoadingSpotifyPlaylists = false

    func loadSpotifyPlaylists() {
        guard spotify.isConnected, !isLoadingSpotifyPlaylists else { return }
        isLoadingSpotifyPlaylists = true
        Task {
            defer { isLoadingSpotifyPlaylists = false }
            do {
                spotifyPlaylists = try await spotify.playlists()
                libraryView?.libraryChanged()
            } catch {
                NSLog("MacAmp: loading Spotify playlists failed: \(error.localizedDescription)")
                libraryView?.showStatus("Spotify playlists: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Main window actions and keys

    func perform(_ control: MainWindowView.Control, event: NSEvent, in view: NSView) {
        switch control {
        case .options: NSMenu.popUpContextMenu(makeContextMenu(), with: event, for: view)
        case .minimize: mainWindow.miniaturize(nil)
        case .close: NSApp.terminate(nil)
        case .shade: toggleMainShade()
        case .previous: previous()
        case .play: play()
        case .pause: transport.pause()
        case .stop: transport.stop()
        case .next: next()
        case .eject: openFiles()
        case .shuffle: shuffle.toggle()
        case .repeatMode: repeatAll.toggle()
        case .equalizer: toggleEqualizer()
        case .playlist: togglePlaylist()
        case .position, .volume, .balance: break
        }
        refreshViews()
    }

    /// Shortcuts shared by all windows; returns false for keys it doesn't handle.
    func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "z": previous()
        case "x": play()
        case "c": transport.pause()
        case "v": transport.stop()
        case "b": next()
        case "l": openFiles()
        case "r": repeatAll.toggle()
        case "s": shuffle.toggle()
        default:
            switch Int(event.keyCode) {
            case 123: transport.seek(to: transport.currentTime - 5)
            case 124: transport.seek(to: transport.currentTime + 5)
            case 125: transport.volume = max(0, transport.volume - 0.05)
            case 126: transport.volume = min(1, transport.volume + 0.05)
            default: return false
            }
        }
        refreshViews()
        return true
    }

    @objc func openFiles() {
        if let urls = chooseFiles(directories: false) { open(urls, replacing: true) }
    }

    @objc func openFolder() {
        if let urls = chooseFiles(directories: true) { open(urls, replacing: true) }
    }

    func addFiles() {
        if let urls = chooseFiles(directories: false) { open(urls, replacing: false) }
    }

    @objc func openURL() {
        if let url = askForURL() { open([url], replacing: true) }
    }

    func addURL() {
        if let url = askForURL() { open([url], replacing: false) }
    }

    private func askForURL() -> URL? {
        guard let text = askForText("Open URL", "Shoutcast/Icecast stream (MP3 or AAC) or a .pls/.m3u link:", placeholder: "https://"),
              let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    private func askForText(_ title: String, _ message: String, placeholder: String, value: String = "",
                            button: String = "Open", allowEmpty: Bool = false) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = placeholder
        field.stringValue = value
        alert.accessoryView = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        return text.isEmpty && !allowEmpty ? nil : text
    }

    func addFolder() {
        if let urls = chooseFiles(directories: true) { open(urls, replacing: false) }
    }

    private func chooseFiles(directories: Bool) -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = directories
        panel.canChooseFiles = !directories
        if !directories {
            panel.allowedContentTypes = [.audio] + ["m3u", "m3u8", "pls"].compactMap { UTType(filenameExtension: $0) }
        }
        return panel.runModal() == .OK ? panel.urls : nil
    }

    // MARK: Skins

    private static func isSkinFile(_ url: URL) -> Bool { url.pathExtension.lowercased() == "wsz" }

    @objc func chooseSkin() {
        if let url = pickSkinFile() { addSkin(url) }
    }

    @objc private func selectSkin(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        do {
            setSkin(try Skin(contentsOf: url), from: url)
        } catch {
            showSkinError(error, for: url)
        }
    }

    @objc private func showSkinsFolder() {
        try? FileManager.default.createDirectory(at: Self.userSkinsFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Self.userSkinsFolder)
    }

    /// Copies a valid skin into the user's skins folder and applies it.
    func addSkin(_ url: URL) {
        do {
            let skin = try Skin(contentsOf: url)
            setSkin(skin, from: try installSkin(url))
        } catch {
            showSkinError(error, for: url)
        }
    }

    /// Copies a skin file or folder into the user's skins folder, replacing one with the same name.
    private func installSkin(_ url: URL) throws -> URL {
        let target = Self.userSkinsFolder.appendingPathComponent(url.lastPathComponent)
        guard url.standardizedFileURL.path != target.standardizedFileURL.path else { return url }
        try FileManager.default.createDirectory(at: Self.userSkinsFolder, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: url, to: target)
        return target
    }

    private func setSkin(_ skin: Skin, from url: URL) {
        self.skin = skin
        skinURL = url
        UserDefaults.standard.set(url.path, forKey: "skinPath")
        libraryView?.applySkinColors()
        roomsView?.applySkinColors()
        artistView?.applySkinColors()
        for window in skinWindows {
            window.contentView?.needsDisplay = true
            DispatchQueue.main.async { window.invalidateShadow() }
        }
    }

    /// A skin opened from Finder before launch, else the saved one, else the first available; asks only when there is none.
    private func loadInitialSkin() -> Skin? {
        if let skin { return skin }
        let saved = UserDefaults.standard.string(forKey: "skinPath").map { URL(fileURLWithPath: $0) }
        for candidate in [saved].compactMap({ $0 }) + Skin.available(in: Self.skinFolders).map(\.url) {
            if let skin = try? Skin(contentsOf: candidate) {
                skinURL = candidate
                if candidate != saved, !isSnapshotRun { UserDefaults.standard.set(candidate.path, forKey: "skinPath") }
                return skin
            }
        }
        while skin == nil, let url = pickSkinFile() { addSkin(url) }
        return skin
    }

    /// Lets the user choose a .wsz file or an unpacked skin folder.
    private func pickSkinFile() -> URL? {
        let panel = NSOpenPanel()
        panel.message = "Choose a classic skin (.wsz file or skin folder)"
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [UTType(filenameExtension: "wsz") ?? .zip, .zip, .folder]
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func showSkinError(_ error: Error, for url: URL) {
        let alert = NSAlert()
        if error is SkinError {
            alert.messageText = "This is not a classic skin."
            alert.informativeText = "\(url.lastPathComponent) is no .wsz archive or folder with a main.bmp."
        } else {
            alert.messageText = "The skin could not be added."
            alert.informativeText = error.localizedDescription
        }
        alert.runModal()
    }

    /// Fills the Skins submenu each time it opens, so newly added skins appear.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for (name, url) in Skin.available(in: Self.skinFolders) {
            let item = addItem(to: menu, name, #selector(selectSkin(_:)))
            item.representedObject = url
            item.state = url.path == skinURL?.path ? .on : .off
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        addItem(to: menu, "Add Skin…", #selector(chooseSkin))
        addItem(to: menu, "Show Skins Folder", #selector(showSkinsFolder))
    }

    private func addSkinsMenu(to menu: NSMenu) {
        let skins = NSMenu(title: "Skins")
        skins.delegate = self
        menu.addItem(withTitle: skins.title, action: nil, keyEquivalent: "").submenu = skins
    }

    // MARK: About

    @objc func showAbout() {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "development build"
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 6
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
        ]
        let small = body.merging([.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]) { _, new in new }
        let credits = NSMutableAttributedString()
        func add(_ text: String, _ attributes: [NSAttributedString.Key: Any], link: String? = nil) {
            var attributes = attributes
            if let link { attributes[.link] = URL(string: link) }
            credits.append(NSAttributedString(string: text, attributes: attributes))
        }
        add("A native Mac player in the spirit of Winamp 2.x: classic skins, equalizer, playlist, media library, internet radio and Spotify.\n", body)
        add("Website", body, link: "https://andrehickmann.github.io/macamp/")
        add("  ·  ", body)
        add("GitHub", body, link: "https://github.com/andrehickmann/macamp")
        add("\n\nSkins AndAmp Dark, Light and Spot by ", small)
        add("Mattix", small, link: "https://mattix.nl")
        add(", licensed under ", small)
        add("CC BY 4.0", small, link: "https://creativecommons.org/licenses/by/4.0/")
        add(".\nSpotify playback uses the Spotify Web API; Spotify is a trademark of Spotify AB.\n", small)
        add("MacAmp is an independent project, not affiliated with Winamp, Nullsoft or Llama Group.", small)

        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "MacAmp",
            .applicationVersion: version,
            .version: "",
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "© 2026 André Hickmann Kuschnereit · MIT License",
        ])
        NSApp.activate()
    }

    // MARK: Menus

    private func makeMainMenu() -> NSMenu {
        let appMenu = NSMenu(title: "MacAmp")
        addItem(to: appMenu, "About MacAmp", #selector(showAbout))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit MacAmp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileMenu = NSMenu(title: "File")
        addItem(to: fileMenu, "Open File…", #selector(openFiles), key: "o")
        addItem(to: fileMenu, "Open Folder…", #selector(openFolder), key: "O")
        addItem(to: fileMenu, "Open URL…", #selector(openURL), key: "l")
        addSkinsMenu(to: fileMenu)
        fileMenu.addItem(.separator())
        addItem(to: fileMenu, "Connect Spotify…", #selector(toggleSpotifyConnection))
        addItem(to: fileMenu, "Spotify Client ID…", #selector(setSpotifyClientID))

        let windowMenu = NSMenu(title: "Window")
        addWindowItems(to: windowMenu)

        let menu = NSMenu()
        for submenu in [appMenu, fileMenu, windowMenu] {
            menu.addItem(withTitle: submenu.title, action: nil, keyEquivalent: "").submenu = submenu
        }
        return menu
    }

    func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        addItem(to: menu, "Open File…", #selector(openFiles))
        addItem(to: menu, "Open Folder…", #selector(openFolder))
        addItem(to: menu, "Open URL…", #selector(openURL))
        addSkinsMenu(to: menu)
        menu.addItem(.separator())
        addWindowItems(to: menu)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit MacAmp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        return menu
    }

    func makePresetsMenu() -> NSMenu {
        let menu = NSMenu()
        for (index, preset) in EqualizerSettings.presets.enumerated() {
            addItem(to: menu, preset.name, #selector(choosePreset(_:))).tag = index
        }
        return menu
    }

    @objc private func choosePreset(_ sender: NSMenuItem) {
        applyPreset(EqualizerSettings.presets[sender.tag].bands)
    }

    private func addWindowItems(to menu: NSMenu) {
        addItem(to: menu, "Equalizer", #selector(toggleEqualizer), key: "g", modifiers: .option)
        addItem(to: menu, "Playlist Editor", #selector(togglePlaylist), key: "e", modifiers: .option)
        addItem(to: menu, "Media Library", #selector(toggleLibrary), key: "l", modifiers: .option)
        addItem(to: menu, "Rooms", #selector(toggleRooms), key: "r", modifiers: .option)
        addItem(to: menu, "Artist", #selector(toggleArtist), key: "a", modifiers: .option)
        addItem(to: menu, "Window Shade", #selector(toggleMainShadeAction), key: "w", modifiers: .control)
        addItem(to: menu, "Double Size", #selector(toggleDoubleSize), key: "d", modifiers: .control)
    }

    @discardableResult
    private func addItem(to menu: NSMenu, _ title: String, _ action: Selector, key: String = "",
                         modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        return item
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let on: Bool? = switch menuItem.action {
        case #selector(toggleEqualizer): equalizerVisible
        case #selector(togglePlaylist): playlistVisible
        case #selector(toggleLibrary): libraryVisible
        case #selector(toggleRooms): roomsVisible
        case #selector(toggleArtist): artistVisible
        case #selector(toggleMainShadeAction): mainShade
        case #selector(toggleDoubleSize): doubleSize
        default: nil
        }
        if let on { menuItem.state = on ? .on : .off }
        if menuItem.action == #selector(toggleSpotifyConnection) {
            menuItem.title = spotify.isConnected ? "Disconnect Spotify" : "Connect Spotify…"
        }
        return true
    }

    // MARK: Settings

    private func restoreSettings() {
        let defaults = UserDefaults.standard
        if let volume = defaults.object(forKey: "volume") as? Float { player.volume = volume }
        player.balance = defaults.float(forKey: "balance")
        shuffle = defaults.bool(forKey: "shuffle")
        repeatAll = defaults.bool(forKey: "repeat")
        mainShade = defaults.bool(forKey: "mainShade")
        equalizerShade = defaults.bool(forKey: "equalizerShade")
        playlistShade = defaults.bool(forKey: "playlistShade")
        doubleSize = defaults.bool(forKey: "doubleSize")
        if let size = defaults.array(forKey: "playlistSize") as? [Double], size.count == 2 {
            playlistSize = CGSize(width: max(275, size[0]), height: max(116, size[1]))
        }
        if let size = defaults.array(forKey: "librarySize") as? [Double], size.count == 2 {
            librarySize = CGSize(width: max(275, size[0]), height: max(116, size[1]))
        }
        if let size = defaults.array(forKey: "roomsSize") as? [Double], size.count == 2 {
            roomsSize = CGSize(width: max(275, size[0]), height: max(116, size[1]))
        }
        if let size = defaults.array(forKey: "artistSize") as? [Double], size.count == 2 {
            artistSize = CGSize(width: max(275, size[0]), height: max(116, size[1]))
        }
        autoPresets = defaults.dictionary(forKey: "autoPresets") as? [String: [Float]] ?? [:]
        let decoder = JSONDecoder()
        if let data = defaults.data(forKey: "equalizer"), let settings = try? decoder.decode(EqualizerSettings.self, from: data) {
            equalizer = settings
        }
        if let data = defaults.data(forKey: "playlist"), let entries = try? decoder.decode([PlaylistEntry].self, from: data) {
            playlist = Playlist(entries: entries)
            let current = defaults.integer(forKey: "current")
            if entries.indices.contains(current) {
                playlist.current = current
                playlist.selection = [current]
            }
        }
    }

    private func saveSettings() {
        let defaults = UserDefaults.standard
        let encoder = JSONEncoder()
        defaults.set(player.volume, forKey: "volume")
        defaults.set(player.balance, forKey: "balance")
        defaults.set(shuffle, forKey: "shuffle")
        defaults.set(repeatAll, forKey: "repeat")
        defaults.set(mainShade, forKey: "mainShade")
        defaults.set(equalizerShade, forKey: "equalizerShade")
        defaults.set(playlistShade, forKey: "playlistShade")
        defaults.set(doubleSize, forKey: "doubleSize")
        defaults.set([playlistSize.width, playlistSize.height], forKey: "playlistSize")
        defaults.set(equalizerVisible, forKey: "equalizerVisible")
        defaults.set(playlistVisible, forKey: "playlistVisible")
        defaults.set(libraryVisible, forKey: "libraryVisible")
        defaults.set([librarySize.width, librarySize.height], forKey: "librarySize")
        defaults.set(roomsVisible, forKey: "roomsVisible")
        defaults.set([roomsSize.width, roomsSize.height], forKey: "roomsSize")
        defaults.set(artistVisible, forKey: "artistVisible")
        defaults.set([artistSize.width, artistSize.height], forKey: "artistSize")
        defaults.set(autoPresets, forKey: "autoPresets")
        defaults.set(try? encoder.encode(equalizer), forKey: "equalizer")
        defaults.set(try? encoder.encode(playlist.entries), forKey: "playlist")
        defaults.set(playlist.current ?? 0, forKey: "current")
    }

    // MARK: Development helpers

    /// Audio files passed on the command line, skipping `-key value` user-default pairs.
    private static func fileArguments() -> [URL] {
        var files: [URL] = []
        var arguments = CommandLine.arguments.dropFirst().makeIterator()
        while let argument = arguments.next() {
            if argument.hasPrefix("-") {
                _ = arguments.next()
            } else if argument.contains("://"), let url = URL(string: argument) {
                files.append(url)
            } else {
                files.append(URL(fileURLWithPath: argument))
            }
        }
        return files
    }

    /// `-snapshot out.png` renders each window to out-main.png, out-equalizer.png and
    /// out-playlist.png after 1.5 s (or `-snapshotDelay` seconds) and quits; used to verify rendering.
    private func writeSnapshots(to path: String) {
        let delay = max(1.5, UserDefaults.standard.double(forKey: "snapshotDelay"))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            let base = URL(fileURLWithPath: path).deletingPathExtension().path
            let views: [(String, NSView?)] = [("main", mainView), ("equalizer", equalizerView), ("playlist", playlistView),
                                              ("library", libraryView), ("rooms", roomsView), ("artist", artistView)]
            for (name, view) in views {
                guard let view, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(base)-\(name).png"))
            }
            NSApp.terminate(nil)
        }
    }
}
