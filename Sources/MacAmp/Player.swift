import AVFoundation
import MacAmpCore

/// Plays one audio file through AVAudioEngine (player → equalizer → mixer) and feeds the spectrum analyzer.
@MainActor
final class Player {
    enum State { case stopped, playing, paused }

    let analyzer = SpectrumAnalyzer()
    private(set) var file: AVAudioFile?
    private(set) var state = State.stopped {
        didSet { onChange?() }
    }
    var onTrackEnd: (() -> Void)?
    /// Called after play state changes and seeks, e.g. to update Now Playing.
    var onChange: (() -> Void)?

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let equalizer = AVAudioUnitEQ(numberOfBands: EqualizerSettings.frequencies.count)
    /// File frame at which the currently scheduled segment starts.
    private var segmentStart: AVAudioFramePosition = 0
    /// Bumped on every reschedule so completions of stale segments are ignored.
    private var generation = 0

    init() {
        for (band, frequency) in zip(equalizer.bands, EqualizerSettings.frequencies) {
            band.filterType = .parametric
            band.frequency = frequency
            band.bandwidth = 1
            band.bypass = false
        }
        engine.attach(node)
        engine.attach(equalizer)
        engine.connect(node, to: equalizer, format: nil)
        engine.connect(equalizer, to: engine.mainMixerNode, format: nil)
        Self.installSpectrumTap(on: engine.mainMixerNode, analyzer: analyzer)
    }

    var duration: Double {
        guard let file else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    var currentTime: Double {
        guard let file, state != .stopped else { return 0 }
        let rate = file.processingFormat.sampleRate
        guard let renderTime = node.lastRenderTime, let playerTime = node.playerTime(forNodeTime: renderTime) else {
            return Double(segmentStart) / rate
        }
        return min(duration, Double(segmentStart + playerTime.sampleTime) / rate)
    }

    var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = newValue }
    }

    /// -1 (left) ... 1 (right).
    var balance: Float = 0 {
        didSet { node.pan = balance }
    }

    func load(_ url: URL) throws {
        stop()
        let file = try AVAudioFile(forReading: url)
        engine.disconnectNodeOutput(node)
        engine.disconnectNodeOutput(equalizer)
        engine.connect(node, to: equalizer, format: file.processingFormat)
        engine.connect(equalizer, to: engine.mainMixerNode, format: file.processingFormat)
        // Bands above Nyquist (e.g. 16 kHz in a 22 kHz file) can't be realized by the filter.
        let nyquist = Float(file.processingFormat.sampleRate / 2)
        for band in equalizer.bands { band.bypass = band.frequency >= nyquist * 0.9 }
        node.pan = balance
        self.file = file
    }

    func apply(_ settings: EqualizerSettings) {
        equalizer.bypass = !settings.enabled
        equalizer.globalGain = settings.preamp
        for (band, gain) in zip(equalizer.bands, settings.bands) { band.gain = gain }
    }

    /// Starts, resumes after pause, or restarts while already playing (as the original does).
    func play() {
        switch state {
        case .paused:
            node.play()
            state = .playing
        case .playing, .stopped:
            start(at: 0)
        }
    }

    /// Toggles between playing and paused.
    func pause() {
        switch state {
        case .playing:
            node.pause()
            state = .paused
        case .paused:
            node.play()
            state = .playing
        case .stopped:
            break
        }
    }

    func stop() {
        generation += 1
        node.stop()
        segmentStart = 0
        state = .stopped
    }

    func seek(to seconds: Double) {
        guard let file, state != .stopped else { return }
        let wasPaused = state == .paused
        let frame = AVAudioFramePosition(seconds * file.processingFormat.sampleRate)
        start(at: min(max(0, frame), file.length))
        if wasPaused { pause() }
        onChange?()
    }

    private func start(at frame: AVAudioFramePosition) {
        guard let file else { return }
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                NSLog("MacAmp: audio engine failed to start: \(error)")
                return
            }
        }
        generation += 1
        let generation = generation
        node.stop()
        segmentStart = frame
        Self.schedule(file, on: node, from: frame) { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.stop()
                self.onTrackEnd?()
            }
        }
        node.play()
        state = .playing
    }

    // Closures for the render thread are built in nonisolated helpers so they
    // don't inherit main-actor isolation (which would trap on the audio thread).

    private nonisolated static func schedule(_ file: AVAudioFile, on node: AVAudioPlayerNode,
                                             from frame: AVAudioFramePosition,
                                             onEnd: @escaping @Sendable () -> Void) {
        let count = AVAudioFrameCount(max(0, file.length - frame))
        guard count > 0 else { return onEnd() }
        node.scheduleSegment(file, startingFrame: frame, frameCount: count, at: nil,
                             completionCallbackType: .dataPlayedBack) { _ in onEnd() }
    }

    private nonisolated static func installSpectrumTap(on mixer: AVAudioMixerNode, analyzer: SpectrumAnalyzer) {
        mixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            guard let channels = buffer.floatChannelData else { return }
            analyzer.process(channels[0], count: Int(buffer.frameLength))
        }
    }
}
