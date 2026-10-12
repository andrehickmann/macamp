import AudioToolbox
import AVFoundation
import MacAmpCore

/// Downloads a Shoutcast/Icecast stream, decodes MP3/AAC with AudioFileStream + AVAudioConverter
/// and hands PCM buffers in `outputFormat` to `output`.
///
/// `@unchecked Sendable`: all mutable state is touched only by the download task (the
/// AudioFileStream callbacks run synchronously inside `AudioFileStreamParseBytes` on that task).
final class StreamDecoder: @unchecked Sendable {
    struct Info: Sendable {
        var name: String?
        var bitrate: Int?
        var sampleRate: Double?
        var channels: Int?
    }

    static let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!

    private let url: URL
    private let output: @Sendable (AVAudioPCMBuffer) -> Void
    private let onTitle: @Sendable (String) -> Void
    private let onInfo: @Sendable (Info) -> Void
    private let onFailure: @Sendable (String) -> Void
    private var task: Task<Void, Never>?
    private var streamID: AudioFileStreamID?
    private var inputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var loggedConversionError = false

    init(url: URL,
         output: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
         onTitle: @escaping @Sendable (String) -> Void,
         onInfo: @escaping @Sendable (Info) -> Void,
         onFailure: @escaping @Sendable (String) -> Void) {
        self.url = url
        self.output = output
        self.onTitle = onTitle
        self.onInfo = onInfo
        self.onFailure = onFailure
    }

    deinit {
        if let streamID { AudioFileStreamClose(streamID) }
    }

    func start() {
        task = Task.detached { [self] in await run() }
    }

    func cancel() {
        task?.cancel()
    }

    private func run() async {
        var request = URLRequest(url: url)
        request.setValue("1", forHTTPHeaderField: "Icy-MetaData")
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return onFailure("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            guard contentType.contains("mpeg") || contentType.contains("aac") || contentType.contains("mp3") else {
                return onFailure("unsupported stream type \(contentType)")
            }
            onInfo(Info(name: http.value(forHTTPHeaderField: "icy-name"),
                        bitrate: http.value(forHTTPHeaderField: "icy-br").flatMap { Int($0.split(separator: ",")[0]) }))
            guard openParser(typeHint: contentType.contains("aac") ? kAudioFileAAC_ADTSType : kAudioFileMP3Type) else {
                return onFailure("cannot open stream parser")
            }

            var demuxer = IcyDemuxer(metaInterval: Int(http.value(forHTTPHeaderField: "icy-metaint") ?? "") ?? 0)
            var chunk: [UInt8] = []
            chunk.reserveCapacity(4096)
            for try await byte in bytes {
                chunk.append(byte)
                guard chunk.count == 4096 else { continue }
                let (audio, titles) = demuxer.consume(chunk)
                chunk.removeAll(keepingCapacity: true)
                titles.forEach(onTitle)
                parse(audio)
            }
            onFailure("stream ended")
        } catch {
            if !Task.isCancelled { onFailure(error.localizedDescription) }
        }
    }

    // MARK: AudioFileStream

    private func openParser(typeHint: AudioFileTypeID) -> Bool {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = AudioFileStreamOpen(context, { context, stream, property, _ in
            Unmanaged<StreamDecoder>.fromOpaque(context).takeUnretainedValue().propertyChanged(stream, property)
        }, { context, byteCount, packetCount, data, descriptions in
            Unmanaged<StreamDecoder>.fromOpaque(context).takeUnretainedValue()
                .received(data, byteCount: byteCount, packetCount: packetCount, descriptions: descriptions)
        }, typeHint, &streamID)
        return status == noErr
    }

    private func parse(_ audio: [UInt8]) {
        guard let streamID, !audio.isEmpty else { return }
        audio.withUnsafeBytes { _ = AudioFileStreamParseBytes(streamID, UInt32($0.count), $0.baseAddress, []) }
    }

    private func propertyChanged(_ stream: AudioFileStreamID, _ property: AudioFileStreamPropertyID) {
        guard property == kAudioFileStreamProperty_ReadyToProducePackets else { return }
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_DataFormat, &size, &description) == noErr,
              let input = AVAudioFormat(streamDescription: &description),
              let converter = AVAudioConverter(from: input, to: Self.outputFormat) else {
            return onFailure("unsupported audio format")
        }
        var cookieSize: UInt32 = 0
        if AudioFileStreamGetPropertyInfo(stream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, nil) == noErr, cookieSize > 0 {
            var cookie = Data(count: Int(cookieSize))
            cookie.withUnsafeMutableBytes {
                _ = AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, $0.baseAddress!)
            }
            converter.magicCookie = cookie
        }
        inputFormat = input
        self.converter = converter
        onInfo(Info(sampleRate: description.mSampleRate, channels: Int(description.mChannelsPerFrame)))
    }

    private func received(_ data: UnsafeRawPointer, byteCount: UInt32, packetCount: UInt32,
                          descriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?) {
        guard let inputFormat, let converter, packetCount > 0 else { return }
        let packets = Int(packetCount)
        // The capacity must hold all bytes: ADTS headers lie between packets but aren't part of their sizes.
        let evenShare = (Int(byteCount) + packets - 1) / packets
        let largestPacket = max(evenShare, descriptions.map { list in (0..<packets).map { Int(list[$0].mDataByteSize) }.max() ?? 0 } ?? 0)
        let buffer = AVAudioCompressedBuffer(format: inputFormat, packetCapacity: packetCount,
                                             maximumPacketSize: max(1, largestPacket))
        buffer.data.copyMemory(from: data, byteCount: Int(byteCount))
        buffer.byteLength = byteCount
        buffer.packetCount = packetCount
        if let target = buffer.packetDescriptions {
            if let descriptions {
                target.update(from: descriptions, count: packets)
            } else {
                // Constant packet size: describe consecutive slices of the data.
                for i in 0..<packets {
                    let offset = i * evenShare
                    target[i] = AudioStreamPacketDescription(mStartOffset: Int64(offset), mVariableFramesInPacket: 0,
                                                             mDataByteSize: UInt32(max(0, min(evenShare, Int(byteCount) - offset))))
                }
            }
        }

        var provided = false
        while true {
            guard let pcm = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: 8192) else { return }
            var error: NSError?
            let status = converter.convert(to: pcm, error: &error) { _, inputStatus in
                if provided {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                provided = true
                inputStatus.pointee = .haveData
                return buffer
            }
            if pcm.frameLength > 0 { output(pcm) }
            if status == .error, !loggedConversionError {
                loggedConversionError = true
                NSLog("MacAmp: stream conversion failed: \(error?.localizedDescription ?? "unknown"), input \(inputFormat)")
            }
            if status != .haveData { break }
        }
    }
}
