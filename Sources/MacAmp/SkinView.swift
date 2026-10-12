import AppKit
import MacAmpCore

/// Borderless windows can't become key by default, which would swallow keyboard input.
final class SkinWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Base for the skinned windows: flipped skin-pixel coordinates, sprite and bitmap-font drawing,
/// region.txt clipping, window dragging with magnetism, shared shortcuts and file drops.
@MainActor
class SkinView: NSView {
    unowned let app: AppController
    private var isDraggingWindow = false

    init(app: AppController) {
        self.app = app
        super.init(frame: .zero)
        // Files and folders, plus spotify: URLs dragged from the media library.
        registerForDraggedTypes([.fileURL, .URL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var skin: Skin { app.skin }

    /// Window size in skin pixels for the current mode.
    var logicalSize: CGSize { CGSize(width: 275, height: 116) }

    /// Whether ⌃D doubles this window.
    var followsDoubleSize: Bool { true }

    /// region.txt section shaping this window in its current mode.
    var regionName: String? { nil }

    var isActive: Bool { window?.isKeyWindow ?? true }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.needsDisplay = true }
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = .none
        if let name = regionName, let polygons = skin.regions[name], !polygons.isEmpty {
            let path = CGMutablePath()
            for polygon in polygons {
                path.addLines(between: polygon)
                path.closeSubpath()
            }
            context.addPath(path)
            context.clip()
        }
        drawSkin(context)
    }

    func drawSkin(_ context: CGContext) {}

    // MARK: Sprites and text

    /// Draws a sprite with top-left origin in this flipped view.
    func blit(_ context: CGContext, _ sheet: String, _ source: CGRect, at origin: CGPoint) {
        guard let image = skin.sprite(sheet, source) else { return }
        let target = CGRect(origin: origin, size: source.size)
        context.saveGState()
        context.translateBy(x: target.minX, y: target.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: target.size))
        context.restoreGState()
    }

    /// Repeats a sprite to fill `area`, clipping the last tile.
    func tile(_ context: CGContext, _ sheet: String, _ source: CGRect, in area: CGRect) {
        context.saveGState()
        context.clip(to: area)
        for y in stride(from: area.minY, to: area.maxY, by: source.height) {
            for x in stride(from: area.minX, to: area.maxX, by: source.width) {
                blit(context, sheet, source, at: CGPoint(x: x, y: y))
            }
        }
        context.restoreGState()
    }

    /// Draws `text` in the 5×6 skin font, clipped to `width`.
    func drawText(_ context: CGContext, _ text: String, at origin: CGPoint, width: CGFloat, alignRight: Bool = false) {
        let size = SkinText.glyphSize
        let start = alignRight ? origin.x + width - CGFloat(text.count) * size.width : origin.x
        for (i, character) in text.enumerated() {
            let x = start + CGFloat(i) * size.width
            if x + size.width > origin.x + width { break }
            blit(context, "text", CGRect(origin: SkinText.glyphOrigin(character), size: size), at: CGPoint(x: x, y: origin.y))
        }
    }

    /// Text that scrolls one glyph every 200 ms when it doesn't fit, like the original marquee.
    func drawMarquee(_ context: CGContext, _ text: String, in area: CGRect, tick: Int) {
        var text = text
        if CGFloat(text.count) * SkinText.glyphSize.width > area.width {
            text += "  ***  "
            let step = (tick / 6) % text.count
            text = String(text.dropFirst(step) + text.prefix(step))
        }
        context.saveGState()
        context.clip(to: area)
        drawText(context, text, at: area.origin, width: area.width + SkinText.glyphSize.width)
        context.restoreGState()
    }

    // MARK: Window dragging

    /// Call from `mouseDown` when no control was hit.
    func beginWindowDrag(_ event: NSEvent) {
        guard let window else { return }
        isDraggingWindow = true
        app.beginWindowDrag(window)
    }

    /// Returns true when the event belonged to a window drag.
    func continueWindowDrag() -> Bool {
        if isDraggingWindow { app.continueWindowDrag() }
        return isDraggingWindow
    }

    func endWindowDrag() -> Bool {
        defer { isDraggingWindow = false }
        return isDraggingWindow
    }

    // MARK: Keyboard, menus and drops

    override func keyDown(with event: NSEvent) {
        if !app.handleKey(event) { super.keyDown(with: event) }
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        NSMenu.popUpContextMenu(app.makeContextMenu(), with: event, for: self)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        dropped(urls, at: convert(sender.draggingLocation, from: nil))
        return true
    }

    /// Dropping on the main or equalizer window replaces the playlist and plays it.
    func dropped(_ urls: [URL], at point: CGPoint) {
        app.open(urls, replacing: true)
    }
}
