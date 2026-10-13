import AudioToolbox
import CoreAudio
import Foundation
import MacAmpCore

/// Feeds the spectrum analyzer from what other processes play, through a Core Audio process tap (macOS 14.2+):
/// Spotify's DRM-protected audio (web player or Spotify app) never passes MacAmp's own audio engine.
/// The tap covers all audio except MacAmp's engine and only listens; macOS asks once for audio-capture permission.
// ponytail: global tap, so other apps' sound shows too while Spotify plays; tap only WebKit/Spotify processes if that bothers.
@available(macOS 14.2, *)
final class SystemAudioTap {
    let analyzer = SpectrumAnalyzer()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "io.github.andrehickmann.macamp.visualizer")

    var isRunning: Bool { procID != nil }

    func start() throws {
        guard !isRunning else { return }
        do {
            let own = try Self.processObject(of: getpid())
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: own == kAudioObjectUnknown ? [] : [own])
            description.uuid = UUID()
            description.isPrivate = true
            description.muteBehavior = .unmuted
            try check(AudioHardwareCreateProcessTap(description, &tapID), "create tap")

            let output = try Self.defaultOutputUID()
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "MacAmp Visualizer",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: output,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                                   kAudioSubTapUIDKey: description.uuid.uuidString]],
            ]
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &deviceID), "create device")

            var format = AudioStreamBasicDescription()
            try Self.read(tapID, kAudioTapPropertyFormat, into: &format)
            let channels = max(1, Int(format.mChannelsPerFrame))
            let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            let analyzer = analyzer
            try check(AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, queue) { _, input, _, _, _ in
                let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                guard let first = buffers.first, let data = first.mData?.assumingMemoryBound(to: Float.self) else { return }
                // Non-interleaved: the first buffer is the left channel. Interleaved: mix down to mono.
                guard interleaved, channels > 1 else {
                    return analyzer.process(data, count: Int(first.mDataByteSize) / MemoryLayout<Float>.size)
                }
                let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
                let mono = (0..<frames).map { frame in
                    (0..<channels).reduce(Float(0)) { $0 + data[frame * channels + $1] } / Float(channels)
                }
                mono.withUnsafeBufferPointer { analyzer.process($0.baseAddress!, count: frames) }
            }, "create IO proc")
            try check(AudioDeviceStart(deviceID, procID), "start")
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let procID {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
        }
        procID = nil
        if deviceID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(deviceID) }
        deviceID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: Core Audio helpers

    struct Failure: LocalizedError {
        let step: String
        let status: OSStatus
        var errorDescription: String? { "\(step) failed (\(status))" }
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        if status != noErr { throw Failure(step: step, status: status) }
    }

    /// The Core Audio object of a process; unknown while it has never used audio.
    private static func processObject(of pid: pid_t) throws -> AudioObjectID {
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        if status != noErr { throw Failure(step: "find own process", status: status) }
        return object
    }

    private static func defaultOutputUID() throws -> String {
        var device = AudioObjectID(kAudioObjectUnknown)
        try read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice, into: &device)
        var uid: Unmanaged<CFString>?
        try read(device, kAudioDevicePropertyDeviceUID, into: &uid)
        guard let uid else { throw Failure(step: "read output device", status: kAudioHardwareUnknownPropertyError) }
        return uid.takeRetainedValue() as String
    }

    private static func read<Value>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, into value: inout Value) throws {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<Value>.size)
        let status = withUnsafeMutableBytes(of: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0.baseAddress!) }
        if status != noErr { throw Failure(step: "read property \(selector)", status: status) }
    }
}
