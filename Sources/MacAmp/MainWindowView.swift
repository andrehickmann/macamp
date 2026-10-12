import AppKit
import MacAmpCore

/// The classic main window (275×116, or a 275×14 bar in shade mode), drawn from skin sprites.
@MainActor
final class MainWindowView: SkinView {
    enum Control {
        case options, minimize, shade, close
        case previous, play, pause, stop, next, eject
        case shuffle, repeatMode, equalizer, playlist
        case position, volume, balance

        var isSlider: Bool { self == .position || self == .volume || self == .balance }
    }

    private static let normalControls: [(Control, CGRect)] = [
        (.options, CGRect(x: 6, y: 3, width: 9, height: 9)),
        (.minimize, CGRect(x: 244, y: 3, width: 9, height: 9)),
        (.shade, CGRect(x: 254, y: 3, width: 9, height: 9)),
        (.close, CGRect(x: 264, y: 3, width: 9, height: 9)),
        (.previous, CGRect(x: 16, y: 88, width: 23, height: 18)),
        (.play, CGRect(x: 39, y: 88, width: 23, height: 18)),
        (.pause, CGRect(x: 62, y: 88, width: 23, height: 18)),
        (.stop, CGRect(x: 85, y: 88, width: 23, height: 18)),
        (.next, CGRect(x: 108, y: 88, width: 22, height: 18)),
        (.eject, CGRect(x: 136, y: 89, width: 22, height: 16)),
        (.shuffle, CGRect(x: 164, y: 89, width: 47, height: 15)),
        (.repeatMode, CGRect(x: 210, y: 89, width: 28, height: 15)),
        (.equalizer, CGRect(x: 219, y: 58, width: 23, height: 12)),
        (.playlist, CGRect(x: 242, y: 58, width: 23, height: 12)),
        (.position, CGRect(x: 16, y: 72, width: 248, height: 10)),
        (.volume, CGRect(x: 107, y: 57, width: 68, height: 13)),
        (.balance, CGRect(x: 177, y: 57, width: 38, height: 13)),
    ]

    /// In shade mode the transport buttons are painted into the bar itself.
    private static let shadeControls: [(Control, CGRect)] = [
        (.options, CGRect(x: 6, y: 3, width: 9, height: 9)),
        (.minimize, CGRect(x: 244, y: 3, width: 9, height: 9)),
        (.shade, CGRect(x: 254, y: 3, width: 9, height: 9)),
        (.close, CGRect(x: 264, y: 3, width: 9, height: 9)),
        (.previous, CGRect(x: 169, y: 2, width: 8, height: 11)),
        (.play, CGRect(x: 177, y: 2, width: 10, height: 11)),
        (.pause, CGRect(x: 187, y: 2, width: 10, height: 11)),
        (.stop, CGRect(x: 197, y: 2, width: 9, height: 11)),
        (.next, CGRect(x: 206, y: 2, width: 8, height: 11)),
        (.eject, CGRect(x: 215, y: 2, width: 9, height: 11)),
        (.position, CGRect(x: 226, y: 4, width: 17, height: 7)),
    ]

    private var pressed: Control?
    /// Seek target while the position thumb is dragged (0...1).
    private var dragProgress: Double?
    private var bars = [Float](repeating: 0, count: SpectrumAnalyzer.barCount)
    private var peaks = [Float](repeating: 0, count: SpectrumAnalyzer.barCount)
    private var tick = 0

    override var logicalSize: CGSize { CGSize(width: 275, height: app.mainShade ? 14 : 116) }
    override var regionName: String? { app.mainShade ? "windowshade" : "normal" }

    private var controls: [(Control, CGRect)] { app.mainShade ? Self.shadeControls : Self.normalControls }

    private func frame(_ control: Control) -> CGRect {
        controls.first { $0.0 == control }?.1 ?? .zero
    }

    /// Advances analyzer falloff and the marquee; driven by the app's 30 fps timer.
    func animate() {
        tick += 1
        let player = app.player
        let fresh = player.state == .playing ? player.analyzer.bars : Array(repeating: 0, count: bars.count)
        for i in bars.indices {
            bars[i] = max(fresh[i], bars[i] - 0.06)
            peaks[i] = bars[i] >= peaks[i] ? bars[i] : max(0, peaks[i] - 0.015)
        }
        needsDisplay = true
    }

    // MARK: Drawing

    override func drawSkin(_ context: CGContext) {
        if app.mainShade {
            drawShade(context)
            return
        }
        let player = app.transport
        blit(context, "main", CGRect(x: 0, y: 0, width: 275, height: 116), at: .zero)
        blit(context, "titlebar", CGRect(x: 27, y: isActive ? 0 : 15, width: 275, height: 14), at: .zero)
        drawTitleButtons(context, shadeButton: CGPoint(x: 0, y: 18), shadeButtonDown: CGPoint(x: 9, y: 18))
        drawTransport(context)
        drawToggles(context)
        drawStatus(context, player)
        drawSliders(context, player)
        drawVisualizer(context)
    }

    private func drawShade(_ context: CGContext) {
        let player = app.transport
        blit(context, "titlebar", CGRect(x: 27, y: isActive ? 29 : 42, width: 275, height: 14), at: .zero)
        drawTitleButtons(context, shadeButton: CGPoint(x: 0, y: 27), shadeButtonDown: CGPoint(x: 9, y: 27))

        if player.state != .stopped {
            let digits = TimeDisplay.digits(seconds: player.currentTime)
            drawText(context, "\(digits[0])\(digits[1]):\(digits[2])\(digits[3])", at: CGPoint(x: 127, y: 4), width: 25)
        }

        let bar = frame(.position)
        blit(context, "titlebar", CGRect(x: 0, y: 36, width: 17, height: 7), at: bar.origin)
        if player.state != .stopped, player.duration > 0 {
            let progress = dragProgress ?? player.currentTime / player.duration
            // The thumb sprite changes from left to middle to right part as playback advances.
            let sprite = CGRect(x: progress < 1.0 / 3 ? 20 : progress < 2.0 / 3 ? 23 : 26, y: 36, width: 3, height: 7)
            blit(context, "titlebar", sprite, at: CGPoint(x: bar.minX + CGFloat(progress) * (bar.width - 3), y: bar.minY))
        }

        // Mini spectrum: 19 bars of 1 px, 5 px high.
        let colors = skin.visColors
        for i in bars.indices {
            let height = Int((bars[i] * 5).rounded())
            for row in (5 - height)..<5 {
                context.setFillColor(colors[2 + row * 3])
                context.fill(CGRect(x: 79 + CGFloat(i * 2), y: 5 + CGFloat(row), width: 1, height: 1))
            }
        }
    }

    private func drawTitleButtons(_ context: CGContext, shadeButton: CGPoint, shadeButtonDown: CGPoint) {
        let sprites: [(Control, CGPoint, CGPoint)] = [
            (.options, CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 9)),
            (.minimize, CGPoint(x: 9, y: 0), CGPoint(x: 9, y: 9)),
            (.shade, shadeButton, shadeButtonDown),
            (.close, CGPoint(x: 18, y: 0), CGPoint(x: 18, y: 9)),
        ]
        for (control, normal, down) in sprites {
            let target = frame(control)
            blit(context, "titlebar", CGRect(origin: pressed == control ? down : normal, size: target.size), at: target.origin)
        }
    }

    private func drawTransport(_ context: CGContext) {
        let columns: [(Control, CGFloat)] = [(.previous, 0), (.play, 23), (.pause, 46), (.stop, 69), (.next, 92), (.eject, 114)]
        for (control, x) in columns {
            let target = frame(control)
            let y = pressed == control ? target.height : 0
            blit(context, "cbuttons", CGRect(x: x, y: y, width: target.width, height: target.height), at: target.origin)
        }
    }

    private func drawToggles(_ context: CGContext) {
        func shufrep(_ control: Control, x: CGFloat, on: Bool) {
            let target = frame(control)
            let y: CGFloat = (on ? 30 : 0) + (pressed == control ? 15 : 0)
            blit(context, "shufrep", CGRect(x: x, y: y, width: target.width, height: 15), at: target.origin)
        }
        shufrep(.shuffle, x: 28, on: app.shuffle)
        shufrep(.repeatMode, x: 0, on: app.repeatAll)

        func windowToggle(_ control: Control, x: CGFloat, on: Bool) {
            let sx = x + (pressed == control ? 46 : 0)
            blit(context, "shufrep", CGRect(x: sx, y: on ? 73 : 61, width: 23, height: 12), at: frame(control).origin)
        }
        windowToggle(.equalizer, x: 0, on: app.equalizerVisible)
        windowToggle(.playlist, x: 23, on: app.playlistVisible)
    }

    private func drawStatus(_ context: CGContext, _ player: any Transport) {
        let stateX: CGFloat = switch player.state {
        case .playing: 0
        case .paused: 9
        case .stopped: 18
        }
        blit(context, "playpaus", CGRect(x: stateX, y: 0, width: 9, height: 9), at: CGPoint(x: 26, y: 28))
        if player.state == .playing {
            blit(context, "playpaus", CGRect(x: 36, y: 0, width: 3, height: 9), at: CGPoint(x: 24, y: 28))
        }

        let channels = player.channelCount
        blit(context, "monoster", CGRect(x: 29, y: channels == 1 ? 0 : 12, width: 27, height: 12), at: CGPoint(x: 212, y: 41))
        blit(context, "monoster", CGRect(x: 0, y: channels >= 2 ? 0 : 12, width: 29, height: 12), at: CGPoint(x: 239, y: 41))

        // The time blinks while paused, like the original.
        let blinkHidden = player.state == .paused && (tick / 15) % 2 == 1
        if player.state != .stopped && !blinkHidden {
            let digits = TimeDisplay.digits(seconds: player.currentTime)
            for (digit, x) in zip(digits, [48, 60, 78, 90] as [CGFloat]) {
                blit(context, "numbers", CGRect(x: CGFloat(digit) * 9, y: 0, width: 9, height: 13), at: CGPoint(x: x, y: 26))
            }
        }

        if let info = app.trackInfo {
            drawText(context, String(min(info.kbps, 999)), at: CGPoint(x: 111, y: 43), width: 15, alignRight: true)
            drawText(context, String(min(info.kHz, 99)), at: CGPoint(x: 156, y: 43), width: 10, alignRight: true)
        }
        drawMarquee(context, app.marqueeText, in: CGRect(x: 111, y: 27, width: 155, height: 6), tick: tick)
    }

    private func drawSliders(_ context: CGContext, _ player: any Transport) {
        let position = frame(.position)
        blit(context, "posbar", CGRect(x: 0, y: 0, width: 248, height: 10), at: position.origin)
        if player.state != .stopped, player.duration > 0 {
            let progress = dragProgress ?? player.currentTime / player.duration
            let x = position.minX + CGFloat(progress) * (position.width - 29)
            blit(context, "posbar", CGRect(x: pressed == .position ? 278 : 248, y: 0, width: 29, height: 10),
                 at: CGPoint(x: x, y: position.minY))
        }

        let thumb = { (control: Control) in CGRect(x: self.pressed == control ? 0 : 15, y: 422, width: 14, height: 11) }

        let volume = frame(.volume)
        let level = CGFloat(player.volume)
        blit(context, "volume", CGRect(x: 0, y: (level * 27).rounded() * 15, width: 68, height: 13), at: volume.origin)
        blit(context, "volume", thumb(.volume), at: CGPoint(x: volume.minX + level * (volume.width - 14), y: volume.minY + 1))

        let balance = frame(.balance)
        let pan = CGFloat(app.player.balance)
        blit(context, "balance", CGRect(x: 9, y: (abs(pan) * 27).rounded() * 15, width: 38, height: 13), at: balance.origin)
        blit(context, "balance", thumb(.balance), at: CGPoint(x: balance.minX + (pan + 1) / 2 * (balance.width - 14), y: balance.minY + 1))
    }

    /// Spectrum analyzer: 19 bars of 3 px with 1 px gaps, colored per row from viscolor.txt.
    private func drawVisualizer(_ context: CGContext) {
        let area = CGRect(x: 24, y: 43, width: 76, height: 16)
        let colors = skin.visColors
        context.setFillColor(colors[0])
        context.fill(area)
        context.setFillColor(colors[1])
        for y in stride(from: area.minY + 1, to: area.maxY, by: 2) {
            for x in stride(from: area.minX, to: area.maxX, by: 2) {
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        for i in bars.indices {
            let x = area.minX + CGFloat(i * 4)
            let height = Int((bars[i] * 16).rounded())
            for row in (16 - height)..<16 {
                context.setFillColor(colors[2 + row])
                context.fill(CGRect(x: x, y: area.minY + CGFloat(row), width: 3, height: 1))
            }
            let peakRow = 16 - Int((peaks[i] * 16).rounded())
            if peakRow < 16 {
                context.setFillColor(colors[23])
                context.fill(CGRect(x: x, y: area.minY + CGFloat(max(0, peakRow - 1)), width: 3, height: 1))
            }
        }
    }

    // MARK: Mouse

    private func control(at point: CGPoint) -> Control? {
        controls.first { $0.1.contains(point) }?.0
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2, point.y < 14, control(at: point) == nil {
            app.toggleMainShade()
            return
        }
        guard let control = control(at: point) else { return beginWindowDrag(event) }
        pressed = control
        if control.isSlider { slide(control, to: point) }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if continueWindowDrag() { return }
        guard let pressed, pressed.isSlider else { return }
        slide(pressed, to: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        if endWindowDrag() { return }
        defer { pressed = nil; needsDisplay = true }
        guard let pressed else { return }
        if pressed == .position, let progress = dragProgress {
            dragProgress = nil
            app.transport.seek(to: progress * app.transport.duration)
        } else if !pressed.isSlider, control(at: convert(event.locationInWindow, from: nil)) == pressed {
            app.perform(pressed, event: event, in: self)
        }
    }

    private func slide(_ control: Control, to point: CGPoint) {
        let target = frame(control)
        switch control {
        case .position:
            guard app.transport.state != .stopped else { return }
            let thumb: CGFloat = app.mainShade ? 3 : 29
            dragProgress = Double(min(1, max(0, (point.x - target.minX - thumb / 2) / (target.width - thumb))))
        case .volume:
            app.transport.volume = Float(min(1, max(0, (point.x - target.minX - 7) / (target.width - 14))))
        case .balance:
            let value = Float(min(1, max(-1, (point.x - target.minX - 7) / (target.width - 14) * 2 - 1)))
            app.player.balance = abs(value) < 0.1 ? 0 : value  // snap to center
        default:
            break
        }
        needsDisplay = true
    }
}
