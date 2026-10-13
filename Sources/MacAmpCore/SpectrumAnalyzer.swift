import Accelerate
import os

/// Turns blocks of mono samples into the 19 bar heights of the classic spectrum analyzer.
///
/// `process` runs on the audio render thread, `bars` is read from the UI.
/// `@unchecked Sendable`: the FFT setup and window are immutable after init,
/// and the only mutable state sits behind a lock.
public final class SpectrumAnalyzer: @unchecked Sendable {
    public static let barCount = 19
    private static let log2n: vDSP_Length = 10
    private static let size = 1 << log2n

    // Calibration: power in dB mapped onto the bar height (0...1).
    private static let floorDB: Float = 10
    private static let rangeDB: Float = 45

    private let setup: FFTSetup
    private let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized,
                                     count: SpectrumAnalyzer.size, isHalfWindow: false)
    private let latest = OSAllocatedUnfairLock(initialState: [Float](repeating: 0, count: SpectrumAnalyzer.barCount))
    /// The most recent `size` input samples, oldest first, for waveform visualizers.
    private let recent = OSAllocatedUnfairLock(initialState: [Float](repeating: 0, count: SpectrumAnalyzer.size))

    public init() {
        setup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))!
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Latest bar heights in 0...1, lowest frequency first.
    public var bars: [Float] { latest.withLock { $0 } }

    /// The last 1024 samples as bytes centered on 128, the format MilkDrop-style visualizers take.
    public var waveform: [UInt8] {
        recent.withLock { $0 }.map { UInt8(max(0, min(255, 128 + $0 * 127))) }
    }

    public func process(_ samples: UnsafePointer<Float>, count: Int) {
        let bars = Self.bars(fromPower: power(samples, count: count))
        latest.withLock { $0 = bars }
        let fresh = Array(UnsafeBufferPointer(start: samples, count: min(count, Self.size)))
        recent.withLock { $0 = Array($0.dropFirst(fresh.count)) + fresh }
    }

    /// Power spectrum (|X|², `size / 2` bins) of the first `size` samples, Hann windowed.
    func power(_ samples: UnsafePointer<Float>, count: Int) -> [Float] {
        let n = Self.size
        var input = [Float](repeating: 0, count: n)
        for i in 0..<min(count, n) { input[i] = samples[i] }
        vDSP.multiply(input, window, result: &input)

        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        var power = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { realBuffer in
            imag.withUnsafeMutableBufferPointer { imagBuffer in
                var split = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imagBuffer.baseAddress!)
                input.withUnsafeBytes {
                    vDSP_ctoz($0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(n / 2))
                }
                vDSP_fft_zrip(setup, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(n / 2))
            }
        }
        return power
    }

    /// Groups power bins into log-spaced bars (at least one bin each) and scales them to 0...1.
    static func bars(fromPower power: [Float]) -> [Float] {
        let bins = power.count
        var edges = [1]
        for i in 1...barCount {
            edges.append(max(edges[i - 1] + 1, Int(pow(Float(bins), Float(i) / Float(barCount)))))
        }
        return (0..<barCount).map { i in
            let lower = min(edges[i], bins - 1)
            let upper = min(max(edges[i + 1], lower + 1), bins)
            let peak = power[lower..<upper].max() ?? 0
            let db = 10 * log10(peak + 1e-12)
            return min(1, max(0, (db - floorDB) / rangeDB))
        }
    }
}
