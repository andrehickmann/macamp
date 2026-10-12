import Foundation

/// Splits a Shoutcast/Icecast byte stream into audio bytes and the in-band metadata blocks
/// that appear every `icy-metaint` bytes (a length byte ×16, then `StreamTitle='…';`).
public struct IcyDemuxer: Sendable {
    private let interval: Int
    private var audioRemaining: Int
    /// Metadata bytes still expected; nil while waiting for the length byte.
    private var metadataRemaining: Int?
    private var metadata: [UInt8] = []

    /// `metaInterval` 0 means the server sends no metadata.
    public init(metaInterval: Int) {
        interval = metaInterval
        audioRemaining = metaInterval > 0 ? metaInterval : .max
    }

    /// Returns the audio payload of `chunk` and the stream titles completed within it.
    public mutating func consume(_ chunk: some Collection<UInt8>) -> (audio: [UInt8], titles: [String]) {
        var audio: [UInt8] = []
        audio.reserveCapacity(chunk.count)
        var titles: [String] = []
        for byte in chunk {
            if audioRemaining > 0 {
                audio.append(byte)
                audioRemaining -= 1
            } else if let remaining = metadataRemaining {
                metadata.append(byte)
                if remaining == 1 {
                    if let title = Self.streamTitle(metadata) { titles.append(title) }
                    finishMetadata()
                } else {
                    metadataRemaining = remaining - 1
                }
            } else if byte == 0 {
                finishMetadata()
            } else {
                metadataRemaining = Int(byte) * 16
                metadata.removeAll(keepingCapacity: true)
            }
        }
        return (audio, titles)
    }

    private mutating func finishMetadata() {
        metadataRemaining = nil
        audioRemaining = interval
    }

    static func streamTitle(_ block: [UInt8]) -> String? {
        let bytes = Array(block.prefix { $0 != 0 })
        guard let text = String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1),
              let start = text.range(of: "StreamTitle='") else { return nil }
        let rest = text[start.upperBound...]
        let title = rest[..<(rest.range(of: "';")?.lowerBound ?? rest.endIndex)].trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }
}
