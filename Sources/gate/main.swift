import Foundation
import Speech
import FoundationModels
import Translation
import AVFoundation

func line(_ label: String, _ ok: Bool?, _ detail: String) {
    let mark = ok == nil ? "?" : (ok! ? "PASS" : "FAIL")
    print(String(format: "  %-6@ %-30@ %@", mark as NSString, label as NSString, detail))
}

print("\n=== ADI205 caption node — platform gate ===\n")

// 1. SpeechTranscriber
print("[1] Speech")
line("SpeechTranscriber.isAvailable", SpeechTranscriber.isAvailable, "")
let supported = await SpeechTranscriber.supportedLocales
let installed = await SpeechTranscriber.installedLocales
let en = supported.first { $0.identifier(.bcp47).hasPrefix("en-US") }
line("en-US supported", en != nil, "\(supported.count) locales supported")
let enInstalled = installed.contains { $0.identifier(.bcp47).hasPrefix("en-US") }
line("en-US installed", enInstalled, enInstalled ? "asset present" : "needs AssetInventory download")

// 2. Which reporting options we can ask for
print("\n[2] Latency-relevant transcriber options")
for o in SpeechTranscriber.ReportingOption.allCases { line("reporting", true, "\(o)") }
for o in SpeechTranscriber.ResultAttributeOption.allCases { line("attribute", true, "\(o)") }

// 3. FoundationModels
print("\n[3] FoundationModels")
let model = SystemLanguageModel.default
switch model.availability {
case .available: line("SystemLanguageModel", true, "available")
case .unavailable(let reason): line("SystemLanguageModel", false, "unavailable: \(reason)")
@unknown default: line("SystemLanguageModel", nil, "unknown")
}

// 4. Translation
print("\n[4] Translation")
let avail = LanguageAvailability()
let src = Locale.Language(identifier: "en")
for (name, id) in [("Vietnamese", "vi"), ("Chinese (Simplified)", "zh-Hans")] {
    let status = await avail.status(from: src, to: Locale.Language(identifier: id))
    switch status {
    case .installed:   line(name, true,  "installed")
    case .supported:   line(name, true,  "supported — pack needs download")
    case .unsupported: line(name, false, "unsupported")
    @unknown default:  line(name, nil,   "unknown")
    }
}

// 5. Audio format the analyzer wants
print("\n[5] Audio")
let t = SpeechTranscriber(locale: en ?? Locale(identifier: "en-US"),
                          transcriptionOptions: [],
                          reportingOptions: [.volatileResults, .fastResults],
                          attributeOptions: [.audioTimeRange, .transcriptionConfidence])
if let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t]) {
    line("analyzer format", true, "\(Int(fmt.sampleRate)) Hz, \(fmt.channelCount) ch, \(fmt.commonFormat.rawValue)")
} else {
    line("analyzer format", false, "none")
}
print("")

print("\n[6] On-device LLM correction cost")
await probeLLM()
print("")
