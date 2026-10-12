import AppKit
import MacAmpCore
import UniformTypeIdentifiers

/// The classic playlist editor (pledit.bmp): resizable in 25×29 px steps, with shade mode.
@MainActor
final class PlaylistView: SkinView {
    enum Control: Equatable {
        case close, shade
        case add, remove, select, misc, listMenu
        case previous, play, pause, stop, next, eject
        case resize, scrollbar, rows
    }

    static let minimumSize = CGSize(width: 275, height: 116)
    private static let rowHeight: CGFloat = 13

    private var pressed: Control?
    private var scrollRow = 0
    private var scrollRemainder: CGFloat = 0
    private var selectionAnchor: Int?
    /// Row under the mouse while selected entries are dragged to a new position.
    private var dragRow: Int?
    private var resizeStart: (mouse: CGPoint, size: CGSize)?

    override var logicalSize: CGSize {
        app.playlistShade ? CGSize(width: app.playlistSize.width, height: 14) : app.playlistSize
    }
    override var followsDoubleSize: Bool { false }

    private var listRect: CGRect {
        CGRect(x: 12, y: 20, width: logicalSize.width - 32, height: logicalSize.height - 58)
    }
    private var visibleRows: Int { max(1, Int(listRect.height / Self.rowHeight)) }
    private var maxScrollRow: Int { max(0, app.playlist.entries.count - visibleRows) }

    private var controls: [(Control, CGRect)] {
        let w = logicalSize.width, h = logicalSize.height
        let titleButtons: [(Control, CGRect)] = [
            (.close, CGRect(x: w - 11, y: 3, width: 9, height: 9)),
            (.shade, CGRect(x: w - 20, y: 3, width: 9, height: 9)),
        ]
        if app.playlistShade { return titleButtons }
        let corner = w - 150
        return titleButtons + [
            (.add, CGRect(x: 14, y: h - 30, width: 22, height: 18)),
            (.remove, CGRect(x: 43, y: h - 30, width: 22, height: 18)),
            (.select, CGRect(x: 72, y: h - 30, width: 22, height: 18)),
            (.misc, CGRect(x: 101, y: h - 30, width: 22, height: 18)),
            (.listMenu, CGRect(x: w - 46, y: h - 30, width: 22, height: 18)),
            (.previous, CGRect(x: corner + 6, y: h - 16, width: 7, height: 8)),
            (.play, CGRect(x: corner + 14, y: h - 16, width: 8, height: 8)),
            (.pause, CGRect(x: corner + 22, y: h - 16, width: 10, height: 8)),
            (.stop, CGRect(x: corner + 32, y: h - 16, width: 9, height: 8)),
            (.next, CGRect(x: corner + 41, y: h - 16, width: 7, height: 8)),
            (.eject, CGRect(x: corner + 49, y: h - 16, width: 9, height: 8)),
            (.resize, CGRect(x: w - 20, y: h - 20, width: 20, height: 20)),
            (.scrollbar, CGRect(x: w - 15, y: 20, width: 8, height: h - 58)),
            (.rows, listRect),
        ]
    }

    // MARK: Drawing

    override func drawSkin(_ context: CGContext) {
        scrollRow = min(scrollRow, maxScrollRow)
        if app.playlistShade {
            drawShade(context)
            return
        }
        let w = logicalSize.width, h = logicalSize.height
        let top: CGFloat = isActive ? 0 : 21
        tile(context, "pledit", CGRect(x: 127, y: top, width: 25, height: 20), in: CGRect(x: 25, y: 0, width: w - 50, height: 20))
        blit(context, "pledit", CGRect(x: 0, y: top, width: 25, height: 20), at: .zero)
        blit(context, "pledit", CGRect(x: 26, y: top, width: 100, height: 20), at: CGPoint(x: ((w - 100) / 2).rounded(.down), y: 0))
        blit(context, "pledit", CGRect(x: 153, y: top, width: 25, height: 20), at: CGPoint(x: w - 25, y: 0))
        if pressed == .close { blit(context, "pledit", CGRect(x: 52, y: 42, width: 9, height: 9), at: CGPoint(x: w - 11, y: 3)) }
        if pressed == .shade { blit(context, "pledit", CGRect(x: 62, y: 42, width: 9, height: 9), at: CGPoint(x: w - 20, y: 3)) }

        tile(context, "pledit", CGRect(x: 0, y: 42, width: 12, height: 29), in: CGRect(x: 0, y: 20, width: 12, height: h - 58))
        tile(context, "pledit", CGRect(x: 31, y: 42, width: 20, height: 29), in: CGRect(x: w - 20, y: 20, width: 20, height: h - 58))

        tile(context, "pledit", CGRect(x: 179, y: 0, width: 25, height: 38), in: CGRect(x: 125, y: h - 38, width: w - 275, height: 38))
        blit(context, "pledit", CGRect(x: 0, y: 72, width: 125, height: 38), at: CGPoint(x: 0, y: h - 38))
        blit(context, "pledit", CGRect(x: 126, y: 72, width: 150, height: 38), at: CGPoint(x: w - 150, y: h - 38))

        drawRows(context)
        drawScrollbar(context)

        let playlist = app.playlist
        let running = "\(TimeDisplay.string(seconds: playlist.selectedDuration))/\(TimeDisplay.string(seconds: playlist.totalDuration))"
        drawText(context, running, at: CGPoint(x: w - 143, y: h - 28), width: 70)
        if app.transport.state != .stopped {
            drawText(context, TimeDisplay.string(seconds: app.transport.currentTime), at: CGPoint(x: w - 84, y: h - 15), width: 25)
        }
    }

    private func drawRows(_ context: CGContext) {
        let style = skin.playlistStyle
        let area = listRect
        context.setFillColor(style.normalBackground)
        context.fill(area)
        context.saveGState()
        context.clip(to: area)

        let font = NSFont(name: style.fontName, size: 9) ?? .systemFont(ofSize: 9)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        let playlist = app.playlist
        let lastRow = min(playlist.entries.count, scrollRow + visibleRows + 1)
        for row in scrollRow..<max(scrollRow, lastRow) {
            let y = area.minY + CGFloat(row - scrollRow) * Self.rowHeight
            if playlist.selection.contains(row) {
                context.setFillColor(style.selectedBackground)
                context.fill(CGRect(x: area.minX, y: y, width: area.width, height: Self.rowHeight))
            }
            let color = NSColor(cgColor: row == playlist.current ? style.current : style.normal) ?? .green
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
            let entry = playlist.entries[row]
            let duration = entry.duration.map { TimeDisplay.string(seconds: $0) } ?? ""
            let durationWidth = (duration as NSString).size(withAttributes: attributes).width
            (duration as NSString).draw(at: CGPoint(x: area.maxX - durationWidth - 2, y: y + 1), withAttributes: attributes)
            ("\(row + 1). \(entry.displayTitle)" as NSString).draw(
                in: CGRect(x: area.minX + 2, y: y + 1, width: area.width - durationWidth - 8, height: Self.rowHeight),
                withAttributes: attributes)
        }
        context.restoreGState()
    }

    private func drawScrollbar(_ context: CGContext) {
        let track = listRect
        let fraction = maxScrollRow > 0 ? CGFloat(scrollRow) / CGFloat(maxScrollRow) : 0
        blit(context, "pledit", CGRect(x: pressed == .scrollbar ? 61 : 52, y: 53, width: 8, height: 18),
             at: CGPoint(x: logicalSize.width - 15, y: (track.minY + fraction * (track.height - 18)).rounded()))
    }

    private func drawShade(_ context: CGContext) {
        let w = logicalSize.width
        tile(context, "pledit", CGRect(x: 72, y: 57, width: 25, height: 14), in: CGRect(x: 25, y: 0, width: w - 75, height: 14))
        blit(context, "pledit", CGRect(x: 72, y: 42, width: 25, height: 14), at: .zero)
        blit(context, "pledit", CGRect(x: 99, y: isActive ? 42 : 57, width: 50, height: 14), at: CGPoint(x: w - 50, y: 0))
        if pressed == .close { blit(context, "pledit", CGRect(x: 52, y: 42, width: 9, height: 9), at: CGPoint(x: w - 11, y: 3)) }
        if pressed == .shade { blit(context, "pledit", CGRect(x: 150, y: 42, width: 9, height: 9), at: CGPoint(x: w - 20, y: 3)) }

        let playlist = app.playlist
        guard let current = playlist.current, playlist.entries.indices.contains(current) else { return }
        let entry = playlist.entries[current]
        drawText(context, "\(current + 1). \(entry.displayTitle)", at: CGPoint(x: 5, y: 4), width: w - 90)
        drawText(context, TimeDisplay.string(seconds: entry.duration ?? app.transport.duration), at: CGPoint(x: w - 82, y: 4),
                 width: 25, alignRight: true)
    }

    // MARK: Mouse

    private func control(at point: CGPoint) -> Control? {
        controls.first { $0.1.contains(point) }?.0
    }

    private func row(at point: CGPoint) -> Int {
        scrollRow + Int(((point.y - listRect.minY) / Self.rowHeight).rounded(.down))
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hit = control(at: point)
        if event.clickCount == 2, hit == nil, point.y < (app.playlistShade ? 14 : 20) {
            app.togglePlaylistShade()
            return
        }
        guard let hit else { return beginWindowDrag(event) }
        pressed = hit
        switch hit {
        case .resize: resizeStart = (NSEvent.mouseLocation, app.playlistSize)
        case .scrollbar: scroll(toThumbAt: point.y)
        case .rows: clickRows(at: point, event)
        default: break
        }
        needsDisplay = true
    }

    private func clickRows(at point: CGPoint, _ event: NSEvent) {
        let row = row(at: point)
        guard app.playlist.entries.indices.contains(row) else {
            app.playlist.selectNone()
            return
        }
        if event.clickCount == 2 {
            app.playTrack(at: row)
            return
        }
        if event.modifierFlags.contains(.command) {
            if app.playlist.selection.contains(row) { app.playlist.selection.remove(row) } else { app.playlist.selection.insert(row) }
        } else if event.modifierFlags.contains(.shift), let anchor = selectionAnchor {
            app.playlist.selection = IndexSet(integersIn: min(anchor, row)...max(anchor, row))
            return
        } else if !app.playlist.selection.contains(row) {
            app.playlist.selection = [row]
        }
        selectionAnchor = row
        dragRow = row
    }

    override func mouseDragged(with event: NSEvent) {
        if continueWindowDrag() { return }
        let point = convert(event.locationInWindow, from: nil)
        switch pressed {
        case .resize:
            guard let start = resizeStart else { return }
            let mouse = NSEvent.mouseLocation
            let minimum = Self.minimumSize
            let columns = max(0, ((start.size.width + mouse.x - start.mouse.x - minimum.width) / 25).rounded())
            let rows = max(0, ((start.size.height + start.mouse.y - mouse.y - minimum.height) / 29).rounded())
            app.setPlaylistSize(CGSize(width: minimum.width + columns * 25, height: minimum.height + rows * 29))
        case .scrollbar:
            scroll(toThumbAt: point.y)
        case .rows:
            guard let dragRow else { return }
            let target = min(max(row(at: point), 0), max(0, app.playlist.entries.count - 1))
            self.dragRow = dragRow + app.playlist.moveSelection(by: target - dragRow)
        default:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        if endWindowDrag() { return }
        defer { pressed = nil; dragRow = nil; resizeStart = nil; needsDisplay = true }
        guard let pressed, control(at: convert(event.locationInWindow, from: nil)) == pressed else { return }
        switch pressed {
        case .close: app.togglePlaylist()
        case .shade: app.togglePlaylistShade()
        case .add: popUp(addMenu(), for: event)
        case .remove: popUp(removeMenu(), for: event)
        case .select: popUp(selectMenu(), for: event)
        case .misc: popUp(miscMenu(), for: event)
        case .listMenu: popUp(listMenu(), for: event)
        case .previous: app.previous()
        case .play: app.play()
        case .pause: app.transport.pause()
        case .stop: app.transport.stop()
        case .next: app.next()
        case .eject: app.openFiles()
        case .resize, .scrollbar, .rows: break
        }
    }

    private func scroll(toThumbAt y: CGFloat) {
        let track = listRect
        let fraction = min(1, max(0, (y - track.minY - 9) / max(1, track.height - 18)))
        scrollRow = Int((fraction * CGFloat(maxScrollRow)).rounded())
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        scrollRemainder += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / Self.rowHeight : event.scrollingDeltaY
        let rows = Int(scrollRemainder)
        guard rows != 0 else { return }
        scrollRemainder -= CGFloat(rows)
        scrollRow = min(max(0, scrollRow - rows), maxScrollRow)
        needsDisplay = true
    }

    // MARK: Keyboard and drops

    override func keyDown(with event: NSEvent) {
        let playlist = app.playlist
        switch Int(event.keyCode) {
        case 51, 117:  // delete, forward delete
            app.playlist.removeSelected()
        case 36, 76:  // return, enter
            if let row = playlist.selection.first { app.playTrack(at: row) }
        case 125, 126:  // down, up
            guard !playlist.entries.isEmpty else { return }
            let delta = event.keyCode == 125 ? 1 : -1
            let row = min(max(0, (delta > 0 ? playlist.selection.last : playlist.selection.first).map { $0 + delta } ?? 0), playlist.entries.count - 1)
            app.playlist.selection = [row]
            selectionAnchor = row
            if row < scrollRow { scrollRow = row } else if row >= scrollRow + visibleRows { scrollRow = row - visibleRows + 1 }
        default:
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "a" {
                app.playlist.selectAll()
            } else {
                return super.keyDown(with: event)
            }
        }
        needsDisplay = true
    }

    /// Dropping on the playlist appends instead of replacing.
    override func dropped(_ urls: [URL], at point: CGPoint) {
        app.open(urls, replacing: false)
    }

    // MARK: Button menus

    private func popUp(_ menu: NSMenu, for event: NSEvent) {
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func menu(_ items: [(String, Selector)]) -> NSMenu {
        let menu = NSMenu()
        for (title, action) in items { menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self }
        return menu
    }

    private func addMenu() -> NSMenu {
        menu([("Add URL…", #selector(addURL)), ("Add Folder…", #selector(addFolder)), ("Add File(s)…", #selector(addFiles))])
    }

    private func removeMenu() -> NSMenu {
        menu([("Remove Missing Files", #selector(removeMissing)), ("Remove All", #selector(removeAll)),
              ("Crop Selection", #selector(crop)), ("Remove Selected", #selector(removeSelected))])
    }

    private func selectMenu() -> NSMenu {
        menu([("Invert Selection", #selector(invertSelection)), ("Select None", #selector(selectNoEntries)),
              ("Select All", #selector(selectAllEntries))])
    }

    private func miscMenu() -> NSMenu {
        menu([("Sort by Title", #selector(sortByTitle)), ("Sort by File Name", #selector(sortByFileName)),
              ("Sort by Path", #selector(sortByPath)), ("Reverse List", #selector(reverseList)),
              ("Randomize List", #selector(randomizeList))])
    }

    private func listMenu() -> NSMenu {
        menu([("New List", #selector(removeAll)), ("Save List…", #selector(saveList)), ("Load List…", #selector(loadList)),
              ("Save to Library…", #selector(saveToLibrary))])
    }

    @objc private func addURL() { app.addURL() }
    @objc private func saveToLibrary() { app.savePlaylistToLibrary() }
    @objc private func addFolder() { app.addFolder() }
    @objc private func addFiles() { app.addFiles() }
    @objc private func removeSelected() { app.playlist.removeSelected() }
    @objc private func crop() { app.playlist.crop() }
    @objc private func removeAll() { app.playlist.removeAll() }
    @objc private func invertSelection() { app.playlist.invertSelection() }
    @objc private func selectNoEntries() { app.playlist.selectNone() }
    @objc private func selectAllEntries() { app.playlist.selectAll() }
    @objc private func sortByTitle() { app.playlist.sort { $0.displayTitle } }
    @objc private func sortByFileName() { app.playlist.sort { $0.url.lastPathComponent } }
    @objc private func sortByPath() { app.playlist.sort { $0.url.path } }
    @objc private func reverseList() { app.playlist.reverse() }
    @objc private func randomizeList() { app.playlist.randomize() }

    @objc private func removeMissing() {
        let missing = app.playlist.entries.indices.filter {
            let url = app.playlist.entries[$0].url
            return url.isFileURL && !FileManager.default.fileExists(atPath: url.path)
        }
        app.playlist.remove(IndexSet(missing))
    }

    @objc private func saveList() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "m3u") ?? .plainText]
        panel.nameFieldStringValue = "Playlist.m3u"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try PlaylistFile.m3u(app.playlist.entries).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc private func loadList() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["m3u", "m3u8", "pls"].compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        app.playlist.removeAll()
        app.open([url], replacing: false)
    }
}
