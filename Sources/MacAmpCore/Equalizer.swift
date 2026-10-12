import Foundation

/// The 10-band graphic equalizer as shown in the equalizer window, values in dB.
public struct EqualizerSettings: Codable, Equatable, Sendable {
    public static let frequencies: [Float] = [60, 170, 310, 600, 1000, 3000, 6000, 12000, 14000, 16000]
    public static let range: ClosedRange<Float> = -12...12

    public var enabled = false
    /// Loads per-file curves when a track starts and remembers changes for it.
    public var auto = false
    public var preamp: Float = 0
    public var bands = [Float](repeating: 0, count: 10)

    public init() {}

    /// Curves for the presets menu.
    public static let presets: [(name: String, bands: [Float])] = [
        ("Flat", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        ("Rock", [5, 3, -3, -5, -2, 2, 5, 7, 7, 7]),
        ("Pop", [-1, 3, 5, 5, 3, 0, -1, -1, -1, -1]),
        ("Dance", [7, 5, 2, 0, 0, -3, -5, -5, 0, 0]),
        ("Classical", [0, 0, 0, 0, 0, 0, -4, -4, -4, -6]),
        ("Vocal", [-3, -2, 0, 3, 5, 4, 2, 0, -1, -2]),
        ("Full Bass", [8, 7, 5, 2, 0, -2, -4, -5, -5, -5]),
        ("Full Treble", [-6, -6, -6, -2, 2, 6, 9, 10, 10, 10]),
        ("Laptop Speakers", [4, 7, 3, -2, -1, 1, 4, 7, 9, 10]),
    ]

    /// Position of a value on a slider, 0 (bottom, -12 dB) ... 1 (top, +12 dB).
    public static func normalized(_ value: Float) -> Float {
        (value - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    /// The response curve in dB at `width` evenly spaced columns, smoothly interpolated between bands.
    public func curve(width: Int) -> [Float] {
        let last = Float(bands.count - 1)
        return (0..<width).map { column in
            let position = width > 1 ? Float(column) / Float(width - 1) * last : 0
            let i = min(Int(position), bands.count - 2)
            let t = position - Float(i)
            // Catmull-Rom through the neighbouring bands, clamped at the ends.
            let p0 = bands[max(i - 1, 0)], p1 = bands[i], p2 = bands[i + 1], p3 = bands[min(i + 2, bands.count - 1)]
            let value = 0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t
                + (-p0 + 3 * p1 - 3 * p2 + p3) * t * t * t)
            return min(Self.range.upperBound, max(Self.range.lowerBound, value))
        }
    }
}
