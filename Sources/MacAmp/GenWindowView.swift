import AppKit
import MacAmpCore

/// Base for windows in the skin's generic gen.bmp frame (media library, rooms): title bar, borders,
/// close button and resizing in 25×29 steps. Subclasses put native views into `contentRect`.
@MainActor
class GenWindowView: SkinView {
    private enum Control { case close, resize }

    private var pressed: Control?
    private var resizeStart: (mouse: CGPoint, size: CGSize)?

    /// Upper-case title drawn in the gen.bmp font.
    var title: String { "" }
    func resize(to size: CGSize) {}
    func close() {}

    override var followsDoubleSize: Bool { false }

    var contentRect: CGRect {
        CGRect(x: 11, y: 20, width: logicalSize.width - 19, height: logicalSize.height - 34)
    }

    // MARK: Frame

    override func drawSkin(_ context: CGContext) {
        let w = logicalSize.width, h = logicalSize.height
        // The windows are transparent for region.txt, so the content area needs its own background.
        context.setFillColor(skin.playlistStyle.normalBackground)
        context.fill(contentRect)
        let top: CGFloat = isActive ? 0 : 21
        let titleWidth = textWidth(title)
        let titleBlock = max(25, (titleWidth / 25).rounded(.up) * 25)
        let titleStart = (((w - titleBlock) / 2) / 25).rounded(.down) * 25

        func piece(_ x: CGFloat) -> CGRect { CGRect(x: x, y: top, width: 25, height: 20) }
        tile(context, "gen", piece(104), in: CGRect(x: 25, y: 0, width: titleStart - 50, height: 20))
        tile(context, "gen", piece(104), in: CGRect(x: titleStart + titleBlock + 25, y: 0, width: w - titleStart - titleBlock - 50, height: 20))
        tile(context, "gen", piece(52), in: CGRect(x: titleStart, y: 0, width: titleBlock, height: 20))
        blit(context, "gen", piece(0), at: .zero)
        blit(context, "gen", piece(26), at: CGPoint(x: titleStart - 25, y: 0))
        blit(context, "gen", piece(78), at: CGPoint(x: titleStart + titleBlock, y: 0))
        blit(context, "gen", piece(130), at: CGPoint(x: w - 25, y: 0))
        drawTitle(context, at: CGPoint(x: titleStart + ((titleBlock - titleWidth) / 2).rounded(.down), y: 4))
        if pressed == .close { blit(context, "gen", CGRect(x: 148, y: 42, width: 9, height: 9), at: CGPoint(x: w - 11, y: 3)) }

        tile(context, "gen", CGRect(x: 127, y: 42, width: 11, height: 29), in: CGRect(x: 0, y: 20, width: 11, height: h - 58))
        blit(context, "gen", CGRect(x: 158, y: 42, width: 11, height: 24), at: CGPoint(x: 0, y: h - 38))
        tile(context, "gen", CGRect(x: 139, y: 42, width: 8, height: 29), in: CGRect(x: w - 8, y: 20, width: 8, height: h - 58))
        blit(context, "gen", CGRect(x: 170, y: 42, width: 8, height: 24), at: CGPoint(x: w - 8, y: h - 38))

        tile(context, "gen", CGRect(x: 127, y: 72, width: 25, height: 14), in: CGRect(x: 125, y: h - 14, width: w - 250, height: 14))
        blit(context, "gen", CGRect(x: 0, y: 42, width: 125, height: 14), at: CGPoint(x: 0, y: h - 14))
        blit(context, "gen", CGRect(x: 0, y: 57, width: 125, height: 14), at: CGPoint(x: w - 125, y: h - 14))
    }

    private func textWidth(_ text: String) -> CGFloat {
        text.reduce(0) { $0 + (skin.genFont[$1]?.width ?? 4) }
    }

    private func drawTitle(_ context: CGContext, at origin: CGPoint) {
        var x = origin.x
        for character in title {
            guard var glyph = skin.genFont[character] else {
                x += 4
                continue
            }
            if !isActive { glyph.origin.y += 8 }
            blit(context, "gen", glyph, at: CGPoint(x: x, y: origin.y))
            x += glyph.width
        }
    }

    // MARK: Mouse

    private func control(at point: CGPoint) -> Control? {
        let w = logicalSize.width, h = logicalSize.height
        if CGRect(x: w - 11, y: 3, width: 9, height: 9).contains(point) { return .close }
        if CGRect(x: w - 20, y: h - 14, width: 20, height: 14).contains(point) { return .resize }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = control(at: point) else { return beginWindowDrag(event) }
        pressed = hit
        if hit == .resize { resizeStart = (NSEvent.mouseLocation, logicalSize) }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if continueWindowDrag() { return }
        guard pressed == .resize, let start = resizeStart else { return }
        let mouse = NSEvent.mouseLocation
        let columns = max(0, ((start.size.width + mouse.x - start.mouse.x - 275) / 25).rounded())
        let rows = max(0, ((start.size.height + start.mouse.y - mouse.y - 116) / 29).rounded())
        resize(to: CGSize(width: 275 + columns * 25, height: 116 + rows * 29))
    }

    override func mouseUp(with event: NSEvent) {
        if endWindowDrag() { return }
        defer { pressed = nil; resizeStart = nil; needsDisplay = true }
        if pressed == .close, control(at: convert(event.locationInWindow, from: nil)) == .close { close() }
    }
}

/// A view that positions its subviews with a closure whenever its size changes.
final class ManualLayoutView: NSView {
    var layoutSubviews: ((CGSize) -> Void)?

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        layoutSubviews?(bounds.size)
    }
}

/// Draws the selection in the skin's playlist selection color.
final class SkinRowView: NSTableRowView {
    private let selection: NSColor

    init(selection: NSColor) {
        self.selection = selection
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func drawSelection(in dirtyRect: NSRect) {
        selection.setFill()
        bounds.fill()
    }
}
