import Foundation
import CoreAudio
@preconcurrency import AVFoundation

/// Input-device enumeration and selection.
///
/// Decision 1 in the plan turns on comparing microphone positions — built-in
/// array mid-room against a laptop at the front. That comparison is only a
/// measurement if the app can be pointed at a chosen device on demand; otherwise
/// it is an assertion about physics.
public enum AudioDevices {

    public struct Device: Sendable, Identifiable {
        public let id: AudioDeviceID
        public let name: String
        public let sampleRate: Double
        public let isDefault: Bool
        /// Total input latency in milliseconds as CoreAudio reports it. Note this
        /// excludes any wireless transport delay, so Bluetooth flatters itself.
        public let latencyMS: Double
    }

    private static func addr(_ s: AudioObjectPropertySelector,
                             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: s, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func u32(_ dev: AudioObjectID, _ sel: AudioObjectPropertySelector,
                            _ scope: AudioObjectPropertyScope) -> UInt32 {
        var a = addr(sel, scope); var v: UInt32 = 0
        var sz = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(dev, &a, 0, nil, &sz, &v) == noErr ? v : 0
    }

    private static func inputChannels(_ dev: AudioObjectID) -> Int {
        var a = addr(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
        var sz: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &sz) == noErr, sz > 0 else { return 0 }
        let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(sz), alignment: 16)
        defer { buf.deallocate() }
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &sz, buf) == noErr else { return 0 }
        let abl = buf.assumingMemoryBound(to: AudioBufferList.self)
        return Int(UnsafeMutableAudioBufferListPointer(abl).reduce(0) { $0 + $1.mNumberChannels })
    }

    private static func name(_ dev: AudioObjectID) -> String {
        var a = addr(kAudioObjectPropertyName)
        var cf: CFString = "" as CFString
        var sz = UInt32(MemoryLayout<CFString?>.size)
        let ok = withUnsafeMutablePointer(to: &cf) {
            AudioObjectGetPropertyData(dev, &a, 0, nil, &sz, $0) == noErr
        }
        return ok ? (cf as String) : "device \(dev)"
    }

    public static var defaultInputID: AudioDeviceID {
        var a = addr(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(0)
        var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &id)
        return id
    }

    public static func inputs() -> [Device] {
        var a = addr(kAudioHardwarePropertyDevices)
        var sz: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz)
        var ids = [AudioObjectID](repeating: 0, count: Int(sz) / MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &ids)

        let def = defaultInputID
        return ids.filter { inputChannels($0) > 0 }.map { id in
            var sr = addr(kAudioDevicePropertyNominalSampleRate)
            var rate = 0.0; var rsz = UInt32(MemoryLayout<Double>.size)
            AudioObjectGetPropertyData(id, &sr, 0, nil, &rsz, &rate)
            let frames = u32(id, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeInput)
                       + u32(id, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeInput)
                       + u32(id, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal)
            return Device(id: id, name: name(id), sampleRate: rate, isDefault: id == def,
                          latencyMS: rate > 0 ? Double(frames) / rate * 1000 : 0)
        }
    }

    /// Case-insensitive substring match, so `CAPTION_DEVICE=macbook` is enough.
    public static func find(matching needle: String) -> Device? {
        let n = needle.lowercased()
        return inputs().first { $0.name.lowercased().contains(n) }
    }

    /// Points an engine's input node at a specific device. Must be called before
    /// the engine starts and before the tap is installed — the audio unit ignores
    /// the property once it has been initialised.
    ///
    /// Setting the raw `kAudioOutputUnitProperty_CurrentDevice` returns noErr and
    /// then does nothing if the unit is already live, so this goes through
    /// AUAudioUnit and reads the value back to confirm it actually took.
    @discardableResult
    public static func setInput(_ id: AudioDeviceID, on engine: AVAudioEngine) throws -> Bool {
        let au = engine.inputNode.auAudioUnit
        do { try au.setDeviceID(id) }
        catch { throw CaptionError.audio("could not select input device: \(error.localizedDescription)") }
        return au.deviceID == id
    }

    /// The device the engine is *actually* reading from, which is not necessarily
    /// the system default — the whole point of pinning one.
    public static func engineInput(_ engine: AVAudioEngine) -> String {
        let id = engine.inputNode.auAudioUnit.deviceID
        return inputs().first { $0.id == id }.map { "\($0.name) [\(id)]" } ?? "id \(id)"
    }
}
