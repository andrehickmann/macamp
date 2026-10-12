import AppKit
import AVFoundation
import MacAmpCore
import UniformTypeIdentifiers

/// Owns the player, the playlist, the three skinned windows and the persisted settings.
@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    struct TrackInfo {
        let kbps: Int
        let kHz: Int
    }

    let player = Player()
    private(set) var skin: Skin!
    var playlist = Playlist() {
        didSet { playlistView?.needsDisplay = true }
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
    private(set) var mainShade = false
    private(set) var equalizerShade = false
    private(set) var playlistShade = false
    private(set) var doubleSize = false
    private(set) var playlistSize = CGSize(width: 275, height: 232)

    private var mainWindow: SkinWindow!
    private var equalizerWindow: SkinWindow!
    private var playlistWindow: SkinWindow!
    private var mainView: MainWindowView!
    private var equalizerView: EqualizerView?
    private var playlistView: PlaylistView?
    private var nowPlaying: NowPlaying?
    private var windowDrag: (mouse: CGPoint, primary: NSWindow, origins: [(NSWindow, CGPoint)])?
    /// Per-file equalizer curves for EQ "Auto": path → [preamp] + bands.
    private var autoPresets: [String: [Float]] = [:]
    private var isApplyingAutoPreset = false
    private var launched = false
    private var pendingFiles: [URL] = []
    private var pendingSkin: URL?
    private var tick = 0

    private var skinWindows: [SkinWindow] { [mainWindow, equalizerWindow, playlistWindow].compactMap { $0 } }
    var equalizerVisible: Bool { equalizerWindow?.isVisible ?? false }
    var playlistVisible: Bool { playlistWindow?.isVisible ?? false }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let skin = loadInitialSkin() else {
            NSApp.terminate(nil)
            return
        }
        self.skin = skin
        restoreSettings()

        mainView = MainWindowView(app: self)
        let equalizerView = EqualizerView(app: self)
        let playlistView = PlaylistView(app: self)
        self.equalizerView = equalizerView
        self.playlistView = playlistView
        let (main, mainRestored) = makeWindow(mainView, name: "MainWindow", title: "MacAmp")
        let (equalizer, equalizerRestored) = makeWindow(equalizerView, name: "EqualizerWindow", title: "MacAmp Equalizer")
        let (playlist, playlistRestored) = makeWindow(playlistView, name: "PlaylistWindow", title: "MacAmp Playlist")
        mainWindow = main
        equalizerWindow = equalizer
        playlistWindow = playlist
        for view in [mainView, equalizerView, playlistView] as [SkinView] { updateSize(of: view) }

        // First launch: stack equalizer and playlist below the main window, like the original.
        if !mainRestored { main.center() }
        if !equalizerRestored { equalizer.setFrameTopLeftPoint(CGPoint(x: main.frame.minX, y: main.frame.minY)) }
        if !playlistRestored { playlist.setFrameTopLeftPoint(CGPoint(x: equalizer.frame.minX, y: equalizer.frame.minY)) }

        main.makeKeyAndOrderFront(nil)
        main.makeFirstResponder(mainView)
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "equalizerVisible") as? Bool ?? true { equalizer.orderFront(nil) }
        if defaults.object(forKey: "playlistVisible") as? Bool ?? true { playlist.orderFront(nil) }
        NSApp.mainMenu = makeMainMenu()
        NSApp.activate()

        nowPlaying = NowPlaying(app: self)
        player.onTrackEnd = { [weak self] in self?.trackEnded() }
        player.onChange = { [weak self] in self?.nowPlaying?.update() }
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
        if let path = defaults.string(forKey: "snapshot") { writeSnapshots(to: path) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        guard launched, UserDefaults.standard.string(forKey: "snapshot") == nil else { return }
        saveSettings()
    }

    /// Files opened from Finder; skins are applied, everything else replaces the playlist.
    func application(_ application: NSApplication, open urls: [URL]) {
        let skins = urls.filter { $0.pathExtension.lowercased() == "wsz" }
        let media = urls.filter { $0.pathExtension.lowercased() != "wsz" }
        if let skinURL = skins.last {
            if launched, let skin = try? Skin(contentsOf: skinURL) {
                setSkin(skin, from: skinURL)
            } else {
                pendingSkin = skinURL
            }
        }
        if !media.isEmpty { open(media, replacing: true) }
    }

    private func animate() {
        tick += 1
        mainView.animate()
        if tick % 10 == 0 { playlistView?.needsDisplay = true }
    }

    // MARK: Playlist and playback

    /// Adds files, folders and playlist files; `replacing` starts a new list and plays it.
    func open(_ urls: [URL], replacing: Bool) {
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

    var currentTitle: String {
        guard let current = playlist.current, playlist.entries.indices.contains(current) else { return "MacAmp" }
        return playlist.entries[current].displayTitle
    }

    /// "1. Artist - Title (3:45)" as shown in the main window.
    var marqueeText: String {
        guard let current = playlist.current, playlist.entries.indices.contains(current) else { return "MACAMP" }
        let entry = playlist.entries[current]
        return "\(current + 1). \(entry.displayTitle) (\(TimeDisplay.string(seconds: entry.duration ?? player.duration)))"
    }

    func play() {
        if player.file == nil || playlist.current == nil {
            playTrack(at: playlist.current ?? playlist.selection.first ?? 0)
        } else {
            player.play()
        }
    }

    func next() {
        if let index = playlist.index(after: playlist.current, shuffle: shuffle, repeatAll: true) { playTrack(at: index) }
    }

    func previous() {
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
        do {
            try player.load(url)
        } catch {
            NSLog("MacAmp: cannot open \(url.path): \(error)")
            trackInfo = nil
            return
        }
        applyAutoPreset(for: url)
        player.play()
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let duration = player.duration
        trackInfo = TrackInfo(kbps: duration > 0 ? Int(Double(size) * 8 / duration / 1000) : 0,
                              kHz: Int(((player.file?.processingFormat.sampleRate ?? 0) / 1000).rounded()))
        if playlist.entries[index].duration == nil { playlist.entries[index].duration = duration }
        nowPlaying?.update()
    }

    func handle(_ command: NowPlaying.Command) {
        switch command {
        case .play: play()
        case .pause: if player.state == .playing { player.pause() }
        case .toggle: player.state == .stopped ? play() : player.pause()
        case .stop: player.stop()
        case .next: next()
        case .previous: previous()
        case .seek(let seconds): player.seek(to: seconds)
        }
        refreshViews()
    }

    private func expand(_ urls: [URL]) -> [PlaylistEntry] {
        urls.flatMap { url -> [PlaylistEntry] in
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
        let urls = entries.filter { $0.title == nil || $0.duration == nil }.map(\.url)
        guard !urls.isEmpty else { return }
        Task {
            for url in urls {
                let info = await Self.info(of: url)
                for index in playlist.entries.indices where playlist.entries[index].url == url {
                    if playlist.entries[index].title == nil { playlist.entries[index].title = info.title }
                    if playlist.entries[index].duration == nil { playlist.entries[index].duration = info.duration }
                }
            }
        }
    }

    /// "Artist - Title" and duration; runs off the main actor because AVFoundation metadata isn't Sendable.
    private nonisolated static func info(of url: URL) async -> (title: String?, duration: Double?) {
        let asset = AVURLAsset(url: url)
        guard let (metadata, duration) = try? await asset.load(.commonMetadata, .duration) else { return (nil, nil) }
        func tag(_ identifier: AVMetadataIdentifier) async -> String? {
            let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier).first
            return try? await item?.load(.stringValue)
        }
        let title = await tag(.commonIdentifierTitle)
        let artist = await tag(.commonIdentifierArtist)
        let seconds = duration.seconds.isFinite && duration.seconds > 0 ? duration.seconds : nil
        return (title.map { t in artist.map { "\($0) - \(t)" } ?? t }, seconds)
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
        case .pause: player.pause()
        case .stop: player.stop()
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
        case "c": player.pause()
        case "v": player.stop()
        case "b": next()
        case "l": openFiles()
        case "r": repeatAll.toggle()
        case "s": shuffle.toggle()
        default:
            switch Int(event.keyCode) {
            case 123: player.seek(to: player.currentTime - 5)
            case 124: player.seek(to: player.currentTime + 5)
            case 125: player.volume = max(0, player.volume - 0.05)
            case 126: player.volume = min(1, player.volume + 0.05)
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

    @objc func chooseSkin() {
        if let (skin, url) = pickSkin() { setSkin(skin, from: url) }
    }

    private func setSkin(_ skin: Skin, from url: URL) {
        self.skin = skin
        UserDefaults.standard.set(url.path, forKey: "skinPath")
        for window in skinWindows {
            window.contentView?.needsDisplay = true
            DispatchQueue.main.async { window.invalidateShadow() }
        }
    }

    private func loadInitialSkin() -> Skin? {
        let saved = UserDefaults.standard.string(forKey: "skinPath").map { URL(fileURLWithPath: $0) }
        for candidate in [pendingSkin, saved].compactMap({ $0 }) {
            if let skin = try? Skin(contentsOf: candidate) {
                if candidate == pendingSkin { UserDefaults.standard.set(candidate.path, forKey: "skinPath") }
                return skin
            }
        }
        return pickSkin()?.skin
    }

    /// Lets the user choose a .wsz file or an unpacked skin folder.
    private func pickSkin() -> (skin: Skin, url: URL)? {
        let panel = NSOpenPanel()
        panel.message = "Choose a classic skin (.wsz file or skin folder)"
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [UTType(filenameExtension: "wsz") ?? .zip, .zip, .folder]
        while panel.runModal() == .OK, let url = panel.url {
            do {
                let skin = try Skin(contentsOf: url)
                UserDefaults.standard.set(url.path, forKey: "skinPath")
                return (skin, url)
            } catch {
                let alert = NSAlert()
                alert.messageText = "This is not a classic skin."
                alert.informativeText = "\(url.lastPathComponent) contains no main.bmp."
                alert.runModal()
            }
        }
        return nil
    }

    // MARK: Menus

    private func makeMainMenu() -> NSMenu {
        let appMenu = NSMenu(title: "MacAmp")
        appMenu.addItem(withTitle: "About MacAmp", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit MacAmp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileMenu = NSMenu(title: "File")
        addItem(to: fileMenu, "Open File…", #selector(openFiles), key: "o")
        addItem(to: fileMenu, "Open Folder…", #selector(openFolder), key: "O")
        addItem(to: fileMenu, "Load Skin…", #selector(chooseSkin))

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
        addItem(to: menu, "Load Skin…", #selector(chooseSkin))
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
        case #selector(toggleMainShadeAction): mainShade
        case #selector(toggleDoubleSize): doubleSize
        default: nil
        }
        if let on { menuItem.state = on ? .on : .off }
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
            let views: [(String, NSView?)] = [("main", mainView), ("equalizer", equalizerView), ("playlist", playlistView)]
            for (name, view) in views {
                guard let view, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(base)-\(name).png"))
            }
            NSApp.terminate(nil)
        }
    }
}
