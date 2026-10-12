import AVFoundation
import MacAmpCore

/// Plays a file or an internet radio stream through AVAudioEngine (player → equalizer → mixer)
/// and feeds the spectrum analyzer.
@MainActor
final class Player {
    enum State { case stopped, playing, paused }

    let analyzer = SpectrumAnalyzer()
    private(set) var file: AVAudioFile?
    /// URL of the radio stream being played, if any.
    private(set) var streamURL: URL?
    private(set) var channelCount = 0
    private(set) var state = State.stopped {
        didSet { onChange?() }
    }
    var onTrackEnd: (() -> Void)?
    /// Called after play state changes and seeks, e.g. to update Now Playing.
    var onChange: (() -> Void)?
    var onStreamTitle: ((String) -> Void)?
    var onStreamInfo: ((StreamDecoder.Info) -> Void)?
    var onStreamFailure: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let equalizer = AVAudioUnitEQ(numberOfBands: EqualizerSettings.frequencies.count)
    private var stream: StreamDecoder?
    private var sampleRate: Double = 44100
    /// Source frame at which the currently scheduled audio starts.
    private var segmentStart: AVAudioFramePosition = 0
    /// Bumped on every reschedule so callbacks from stale segments and streams are ignored.
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
        return Double(file.length) / sampleRate
    }

    var currentTime: Double {
        guard state != .stopped else { return 0 }
        guard let renderTime = node.lastRenderTime, let playerTime = node.playerTime(forNodeTime: renderTime) else {
            return Double(segmentStart) / sampleRate
        }
        let seconds = Double(segmentStart + playerTime.sampleTime) / sampleRate
        return file == nil ? seconds : min(duration, seconds)
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
        connect(format: file.processingFormat)
        self.file = file
        streamURL = nil
        channelCount = Int(file.processingFormat.channelCount)
    }

    /// Connects to a Shoutcast/Icecast stream and starts playing as soon as audio arrives.
    func playStream(_ url: URL) {
        stop()
        file = nil
        streamURL = url
        channelCount = 0
        connect(format: StreamDecoder.outputFormat)
        guard startEngine() else { return }

        let generation = generation
        // Buffers are scheduled straight from the download task; AVAudioPlayerNode is thread-safe for this.
        let decoder = StreamDecoder(
            url: url,
            output: { [node] buffer in node.scheduleBuffer(buffer) },
            onTitle: { [weak self] title in Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.onStreamTitle?(title)
            } },
            onInfo: { [weak self] info in Task { @MainActor in
                guard let self, self.generation == generation else { return }
                if let channels = info.channels { self.channelCount = channels }
                self.onStreamInfo?(info)
            } },
            onFailure: { [weak self] message in Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.stop()
                self.onStreamFailure?(message)
            } })
        stream = decoder
        decoder.start()
        node.play()
        state = .playing
    }

    func apply(_ settings: EqualizerSettings) {
        equalizer.bypass = !settings.enabled
        equalizer.globalGain = settings.preamp
        for (band, gain) in zip(equalizer.bands, settings.bands) { band.gain = gain }
    }

    /// Starts, resumes after pause, or restarts while already playing (as the original does).
    func play() {
        if state == .paused {
            node.play()
            state = .playing
        } else if let streamURL {
            playStream(streamURL)
        } else {
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
        stream?.cancel()
        stream = nil
        node.stop()
        segmentStart = 0
        state = .stopped
    }

    func seek(to seconds: Double) {
        guard let file, state != .stopped else { return }
        let wasPaused = state == .paused
        start(at: min(max(0, AVAudioFramePosition(seconds * sampleRate)), file.length))
        if wasPaused { pause() }
        onChange?()
    }

    private func connect(format: AVAudioFormat) {
        engine.disconnectNodeOutput(node)
        engine.disconnectNodeOutput(equalizer)
        engine.connect(node, to: equalizer, format: format)
        engine.connect(equalizer, to: engine.mainMixerNode, format: format)
        // Bands above Nyquist (e.g. 16 kHz in a 22 kHz file) can't be realized by the filter.
        let nyquist = Float(format.sampleRate / 2)
        for band in equalizer.bands { band.bypass = band.frequency >= nyquist * 0.9 }
        node.pan = balance
        sampleRate = format.sampleRate
    }

    private func startEngine() -> Bool {
        guard !engine.isRunning else { return true }
        do {
            try engine.start()
            return true
        } catch {
            NSLog("MacAmp: audio engine failed to start: \(error)")
            return false
        }
    }

    private func start(at frame: AVAudioFramePosition) {
        guard let file, startEngine() else { return }
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

    // Closures for the render and download threads are built in nonisolated helpers so
    // they don't inherit main-actor isolation (which would trap off the main thread).

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
