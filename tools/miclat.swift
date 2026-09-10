import Foundation
import CoreAudio

func addr(_ s: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: s, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}
func u32(_ dev: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> UInt32? {
    var a = addr(sel, scope); var v: UInt32 = 0; var sz = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(dev, &a, 0, nil, &sz, &v) == noErr ? v : nil
}
func f64(_ dev: AudioObjectID, _ sel: AudioObjectPropertySelector) -> Double? {
    var a = addr(sel); var v: Double = 0; var sz = UInt32(MemoryLayout<Double>.size)
    return AudioObjectGetPropertyData(dev, &a, 0, nil, &sz, &v) == noErr ? v : nil
}
func name(_ dev: AudioObjectID) -> String {
    var a = addr(kAudioObjectPropertyName); var s: CFString = "" as CFString
    var sz = UInt32(MemoryLayout<CFString?>.size)
    return AudioObjectGetPropertyData(dev, &a, 0, nil, &sz, &s) == noErr ? (s as String) : "?"
}
func inputChannels(_ dev: AudioObjectID) -> Int {
    var a = addr(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
    var sz: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &sz) == noErr, sz > 0 else { return 0 }
    let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(sz), alignment: 16)
    defer { buf.deallocate() }
    guard AudioObjectGetPropertyData(dev, &a, 0, nil, &sz, buf) == noErr else { return 0 }
    let abl = buf.assumingMemoryBound(to: AudioBufferList.self)
    return Int(UnsafeMutableAudioBufferListPointer(abl).reduce(0) { $0 + $1.mNumberChannels })
}
func streamLatency(_ dev: AudioObjectID) -> UInt32 {
    var a = addr(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
    var sz: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &sz) == noErr, sz > 0 else { return 0 }
    var ids = [AudioStreamID](repeating: 0, count: Int(sz) / MemoryLayout<AudioStreamID>.size)
    guard AudioObjectGetPropertyData(dev, &a, 0, nil, &sz, &ids) == noErr, let first = ids.first else { return 0 }
    var b = addr(kAudioStreamPropertyLatency); var v: UInt32 = 0; var s2 = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(first, &b, 0, nil, &s2, &v) == noErr ? v : 0
}

var a = addr(kAudioHardwarePropertyDevices)
var size: UInt32 = 0
AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
var devs = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &devs)

print("DEVICE                        rate     dev  safety  buffer   stream   TOTAL INPUT")
print(String(repeating: "-", count: 78))
for d in devs where inputChannels(d) > 0 {
    let sr = f64(d, kAudioDevicePropertyNominalSampleRate) ?? 48000
    let lat = u32(d, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeInput) ?? 0
    let safe = u32(d, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeInput) ?? 0
    let buf = u32(d, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal) ?? 0
    let strm = streamLatency(d)
    let totalFrames = Double(lat + safe + buf + strm)
    let ms = totalFrames / sr * 1000.0
    print(String(format: "%-28@ %7.0f %7u %7u %7u %9u  %6.1f ms", name(d) as NSString, sr, lat, safe, buf, strm, ms))
}
