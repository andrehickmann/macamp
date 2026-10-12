import AppKit
import MacAmpCore

/// The classic equalizer window (eqmain.bmp; shade mode from eq_ex.bmp).
@MainActor
final class EqualizerView: SkinView {
    enum Control: Equatable {
        case on, auto, presets, shade, close
        case preamp
        case band(Int)
        // Shade mode
        case volume, balance
    }

    private static let sliderSize = CGSize(width: 14, height: 63)

    private var pressed: Control?

    override var logicalSize: CGSize { CGSize(width: 275, height: app.equalizerShade ? 14 : 116) }
    override var regionName: String? { app.equalizerShade ? "equalizerws" : "equalizer" }

    private var controls: [(Control, CGRect)] {
        if app.equalizerShade {
            return [
                (.shade, CGRect(x: 254, y: 3, width: 9, height: 9)),
                (.close, CGRect(x: 264, y: 3, width: 9, height: 9)),
                (.volume, CGRect(x: 61, y: 4, width: 97, height: 7)),
                (.balance, CGRect(x: 164, y: 4, width: 43, height: 7)),
            ]
        }
        var controls: [(Control, CGRect)] = [
            (.on, CGRect(x: 14, y: 18, width: 26, height: 12)),
            (.auto, CGRect(x: 40, y: 18, width: 32, height: 12)),
            (.presets, CGRect(x: 217, y: 18, width: 44, height: 12)),
            (.shade, CGRect(x: 254, y: 3, width: 9, height: 9)),
            (.close, CGRect(x: 264, y: 3, width: 9, height: 9)),
            (.preamp, CGRect(origin: CGPoint(x: 21, y: 38), size: Self.sliderSize)),
        ]
        for band in 0..<10 {
            controls.append((.band(band), CGRect(origin: CGPoint(x: 78 + CGFloat(band) * 18, y: 38), size: Self.sliderSize)))
        }
        return controls
    }

    private func frame(_ control: Control) -> CGRect {
        controls.first { $0.0 == control }?.1 ?? .zero
    }

    // MARK: Drawing

    override func drawSkin(_ context: CGContext) {
        if app.equalizerShade {
            drawShade(context)
            return
        }
        let eq = app.equalizer
        blit(context, "eqmain", CGRect(x: 0, y: 0, width: 275, height: 116), at: .zero)
        blit(context, "eqmain", CGRect(x: 0, y: isActive ? 134 : 149, width: 275, height: 14), at: .zero)

        func toggle(_ control: Control, x: CGFloat, width: CGFloat, on: Bool) {
            let sx = x + (on ? 59 : 0) + (pressed == control ? 118 : 0)
            blit(context, "eqmain", CGRect(x: sx, y: 119, width: width, height: 12), at: frame(control).origin)
        }
        toggle(.on, x: 10, width: 26, on: eq.enabled)
        toggle(.auto, x: 36, width: 32, on: eq.auto)
        blit(context, "eqmain", CGRect(x: 224, y: pressed == .presets ? 176 : 164, width: 44, height: 12), at: frame(.presets).origin)
        // Normal close and shade buttons are part of the background; only their pressed states are sprites.
        if pressed == .close { blit(context, "eqmain", CGRect(x: 0, y: 125, width: 9, height: 9), at: frame(.close).origin) }
        if pressed == .shade { blit(context, "eq_ex", CGRect(x: 1, y: 38, width: 9, height: 9), at: frame(.shade).origin) }

        drawSlider(context, .preamp, value: eq.preamp)
        for (band, value) in eq.bands.enumerated() { drawSlider(context, .band(band), value: value) }
        drawGraph(context, eq)
    }

    private func drawSlider(_ context: CGContext, _ control: Control, value: Float) {
        let target = frame(control)
        let level = CGFloat(EqualizerSettings.normalized(value))
        // 28 background frames in two rows of 14 show the fill level.
        let index = Int((level * 27).rounded())
        let background = CGRect(x: 13 + CGFloat(index % 14) * 15, y: 164 + CGFloat(index / 14) * 65,
                                width: Self.sliderSize.width, height: Self.sliderSize.height)
        blit(context, "eqmain", background, at: target.origin)
        let thumbY = target.minY + (1 - level) * (target.height - 11)
        blit(context, "eqmain", CGRect(x: 0, y: pressed == control ? 176 : 164, width: 11, height: 11),
             at: CGPoint(x: target.minX + 1, y: thumbY))
    }

    /// The response preview above the sliders: background, preamp line and the interpolated curve.
    private func drawGraph(_ context: CGContext, _ eq: EqualizerSettings) {
        let origin = CGPoint(x: 86, y: 17)
        blit(context, "eqmain", CGRect(x: 0, y: 294, width: 113, height: 19), at: origin)
        func row(_ value: Float) -> CGFloat { (1 - CGFloat(EqualizerSettings.normalized(value))) * 18 }
        blit(context, "eqmain", CGRect(x: 0, y: 314, width: 113, height: 1), at: CGPoint(x: origin.x, y: origin.y + row(eq.preamp).rounded()))
        var previous: CGFloat?
        for (x, value) in eq.curve(width: 113).enumerated() {
            let y = row(value).rounded()
            // Fill vertical gaps so steep curves stay connected; the color comes from the line-color strip.
            for fillY in stride(from: min(y, previous ?? y), through: max(y, previous ?? y), by: 1) {
                blit(context, "eqmain", CGRect(x: 115, y: 294 + fillY, width: 1, height: 1),
                     at: CGPoint(x: origin.x + CGFloat(x), y: origin.y + fillY))
            }
            previous = y
        }
    }

    private func drawShade(_ context: CGContext) {
        let player = app.player
        blit(context, "eq_ex", CGRect(x: 0, y: isActive ? 0 : 15, width: 275, height: 14), at: .zero)
        if pressed == .shade { blit(context, "eq_ex", CGRect(x: 1, y: 47, width: 9, height: 9), at: frame(.shade).origin) }
        blit(context, "eq_ex", CGRect(x: 11, y: pressed == .close ? 47 : 38, width: 9, height: 9), at: frame(.close).origin)

        func thumb(_ control: Control, value: CGFloat, spriteX: CGFloat) {
            let target = frame(control)
            let part: CGFloat = value < 1.0 / 3 ? 0 : value < 2.0 / 3 ? 3 : 6
            blit(context, "eq_ex", CGRect(x: spriteX + part, y: 30, width: 3, height: 7),
                 at: CGPoint(x: target.minX + value * (target.width - 3), y: target.minY))
        }
        thumb(.volume, value: CGFloat(app.transport.volume), spriteX: 1)
        thumb(.balance, value: (CGFloat(player.balance) + 1) / 2, spriteX: 11)
    }

    // MARK: Mouse

    private func control(at point: CGPoint) -> Control? {
        controls.first { $0.1.contains(point) }?.0
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2, point.y < 14, control(at: point) == nil {
            app.toggleEqualizerShade()
            return
        }
        guard let control = control(at: point) else { return beginWindowDrag(event) }
        pressed = control
        slide(control, to: point)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if continueWindowDrag() { return }
        if let pressed { slide(pressed, to: convert(event.locationInWindow, from: nil)) }
    }

    override func mouseUp(with event: NSEvent) {
        if endWindowDrag() { return }
        defer { pressed = nil; needsDisplay = true }
        guard let pressed, control(at: convert(event.locationInWindow, from: nil)) == pressed else { return }
        switch pressed {
        case .on: app.equalizer.enabled.toggle()
        case .auto: app.equalizer.auto.toggle()
        case .presets: NSMenu.popUpContextMenu(app.makePresetsMenu(), with: event, for: self)
        case .shade: app.toggleEqualizerShade()
        case .close: app.toggleEqualizer()
        case .preamp, .band, .volume, .balance: break
        }
    }

    private func slide(_ control: Control, to point: CGPoint) {
        let target = frame(control)
        let range = EqualizerSettings.range
        func sliderValue() -> Float {
            let level = 1 - min(1, max(0, (point.y - target.minY - 5.5) / (target.height - 11)))
            let value = range.lowerBound + Float(level) * (range.upperBound - range.lowerBound)
            return abs(value) < 0.75 ? 0 : value  // snap to 0 dB
        }
        switch control {
        case .preamp: app.equalizer.preamp = sliderValue()
        case .band(let band): app.equalizer.bands[band] = sliderValue()
        case .volume:
            app.transport.volume = Float(min(1, max(0, (point.x - target.minX - 1.5) / (target.width - 3))))
        case .balance:
            let value = Float(min(1, max(-1, (point.x - target.minX - 1.5) / (target.width - 3) * 2 - 1)))
            app.player.balance = abs(value) < 0.1 ? 0 : value
        default:
            return
        }
        needsDisplay = true
    }
}
