import Foundation
@preconcurrency import AVFoundation
import Speech

/// Everything the analyzer needs, assembled once so the live app and the
/// benchmark cannot drift apart. If they configured the transcriber differently
/// the measurements would stop describing the product.
public struct AnalyzerSetup {
    public let transcriber: SpeechTranscriber
    public let detector: SpeechDetector?
    public let context: AnalysisContext
    public let format: AVAudioFormat

    public var modules: [any SpeechModule] {
        detector.map { [$0, transcriber] as [any SpeechModule] } ?? [transcriber]
    }

    /// - Parameters:
    ///   - glossary: course terms handed to the recognizer as contextual strings.
    ///     This is *prevention* — it biases decoding so jargon comes out right the
    ///     first time. The fuzzy repair in the pipeline is the *cure* for whatever
    ///     still slips through; the two are not redundant.
    ///   - speechDetection: adds Apple's own voice-activity module ahead of
    ///     transcription, so silence and room tone never reach the recogniser.
    public static func make(glossary: [String] = [],
                            speechDetection: Bool = true,
                            sensitivity: SpeechDetector.SensitivityLevel = .medium) async throws -> AnalyzerSetup {

        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
            ?? Locale(identifier: "en-US")

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            // fastResults trades a little stability for earlier output; volatile
            // results are what the English line is painted from.
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence])

        let detector: SpeechDetector? = speechDetection
            ? SpeechDetector(detectionOptions: .init(sensitivityLevel: sensitivity),
                             reportResults: true)
            : nil

        let context = AnalysisContext()
        if !glossary.isEmpty {
            context.contextualStrings = [.general: glossary]
        }

        var mods: [any SpeechModule] = [transcriber]
        if let detector { mods.insert(detector, at: 0) }

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: mods) else {
            throw CaptionError.setup("no audio format compatible with the selected modules")
        }

        return AnalyzerSetup(transcriber: transcriber, detector: detector,
                             context: context, format: format)
    }
}
