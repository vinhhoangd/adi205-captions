import Foundation
import CoreAudio

// Sets the system default input device by name substring.
//
// AVAudioEngine reads through a CADefaultDeviceAggregate that follows the system
// default, and setting deviceID on the input node's audio unit does not stick.
// So choosing a microphone — for the demo, or for the mic-distance comparison —
// has to be done at the system level. This is that switch.

func addr(_ s: AudioObjectPropertySelector,
          _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
    -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: s, mScope: scope,
                               mElement: kAudioObjectPropertyElementMain)
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

func deviceName(_ dev: AudioObjectID) -> String {
    var a = addr(kAudioObjectPropertyName)
    var cf: CFString = "" as CFString
    var sz = UInt32(MemoryLayout<CFString?>.size)
    let ok = withUnsafeMutablePointer(to: &cf) {
        AudioObjectGetPropertyData(dev, &a, 0, nil, &sz, $0) == noErr
    }
    return ok ? (cf as String) : "device \(dev)"
}

var listAddr = addr(kAudioHardwarePropertyDevices)
var size: UInt32 = 0
AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &listAddr, 0, nil, &size)
var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &listAddr, 0, nil, &size, &ids)

var defAddr = addr(kAudioHardwarePropertyDefaultInputDevice)
var current = AudioDeviceID(0)
var csz = UInt32(MemoryLayout<AudioDeviceID>.size)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defAddr, 0, nil, &csz, &current)

let inputs = ids.filter { inputChannels($0) > 0 }
let needle = CommandLine.arguments.dropFirst().joined(separator: " ")

guard !needle.isEmpty else {
    print("Input devices (• = current):")
    for d in inputs { print("  \(d == current ? "•" : " ") \(deviceName(d))") }
    print("\nUsage: setinput <part of a device name>")
    exit(0)
}

guard let match = inputs.first(where: { deviceName($0).lowercased().contains(needle.lowercased()) }) else {
    print("No input device matching \"\(needle)\". Available:")
    for d in inputs { print("    \(deviceName(d))") }
    exit(1)
}

var target = match
let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defAddr, 0, nil,
                                        UInt32(MemoryLayout<AudioDeviceID>.size), &target)
if status == noErr {
    print("Default input is now: \(deviceName(match))")
} else {
    print("Failed to set input device (OSStatus \(status))")
    exit(2)
}
