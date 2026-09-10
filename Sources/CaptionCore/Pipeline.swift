import Foundation
@preconcurrency import AVFoundation
import Speech
import FoundationModels
@preconcurrency import Translation
import CoreMedia

// MARK: - Tuning

public struct PipelineConfig: Sendable {
    /// Words held back from the displayed translation. Simultaneous-translation
    /// work calls this mask-k: the newest target words are the ones most likely
    /// to be revised when more source arrives, so hiding them buys stability.
    /// k = 0 shows everything immediately and flickers most.
    public var maskK: Int = 3
    /// Below this ASR confidence we pay for an LLM correction pass; above it we
    /// skip it entirely. Measured confidences on this recognizer are bimodal —
    /// median 1.00, with genuine errors landing at 0.60-0.65 — so the gate sits
    /// above those but below the confident mass.
    public var correctionConfidenceThreshold: Double = 0.75
    /// Re-translate once the prefix has grown by this many words.
    public var retranslateEveryWords: Int = 1
    public var targetLanguage: String = "vi"
    /// OFF by default, on measurement rather than principle: one on-device
    /// FoundationModels call costs ~6.5 s on this M1 Pro — a fixed overhead,
    /// identical at 30, 60 and 120 max tokens — against a 3 s total budget.
    /// Glossary repair fixes the jargon errors it would have caught, for ~0 ms.
    /// Leave it off for live captioning; enable it only for offline passes or
    /// when a fast cloud model is wired in behind the same gate.
    public var enableCorrection: Bool = false

    public init() {}
}

// MARK: - Events

public struct CaptionEvent: Sendable {
    public enum Kind: String, Sendable { case english, translation, finalized }
    public var kind: Kind
    public var english: String
    public var translation: String
    /// Audio-clock time of the last word this event actually displays.
    public var audioTime: Double
    /// Wall-clock latency from that word being spoken to this event.
    public var latency: Double
    public var corrected: Bool
    public var confidence: Double
}

// MARK: - Word/time helpers

struct TimedWord: Sendable {
    var text: String
    var end: Double
    var confidence: Double
}

func timedWords(_ s: AttributedString) -> [TimedWord] {
    var out: [TimedWord] = []
    for run in s.runs {
        let piece = String(s[run.range].characters)
        let end = run.audioTimeRange.map { CMTimeGetSeconds($0.end) } ?? .nan
        let conf = run.transcriptionConfidence ?? 1.0
        // A run can span several words; split so masking is word-accurate.
        let parts = piece.split(separator: " ", omittingEmptySubsequences: true)
        for p in parts { out.append(TimedWord(text: String(p), end: end, confidence: conf)) }
    }
    return out
}

// MARK: - Pipeline

@MainActor
public final class CaptionPipeline {

    public private(set) var config: PipelineConfig
    private let translator: TranslationSession
    private var corrector: LanguageModelSession?
    private let glossary: [String]

    private var streamStart: Date = .now
    private var committed: [TimedWord] = []
    private var volatileWords: [TimedWord] = []

    private var lastTranslatedCount = 0
    public private(set) var translateCalls = 0
    public private(set) var translateTotalMS = 0.0
    public private(set) var lastTranslateMS = 0.0
    public private(set) var correctCalls = 0
    public private(set) var correctTotalMS = 0.0
    public private(set) var confidences: [Double] = []
    private var lastTranslation = ""

    private var emit: (CaptionEvent) -> Void = { _ in }

    public init(config: PipelineConfig,
                translator: TranslationSession,
                glossary: [String] = []) {
        self.config = config
        self.translator = translator
        self.glossary = glossary
    }

    public func onEvent(_ cb: @escaping (CaptionEvent) -> Void) { self.emit = cb }

    /// First inference on any of these models costs seconds. Paying that at
    /// launch instead of on the first spoken sentence is the single cheapest
    /// latency win available, and the one most likely to matter on demo day.
    /// Returns (correctorMS, translatorMS) so the report can show what cold
    /// start would otherwise have cost the first sentence of the lecture.
    @discardableResult
    public func warmUp() async -> (Double, Double) {
        var correctorMS = 0.0, translatorMS = 0.0
        if config.enableCorrection, case .available = SystemLanguageModel.default.availability {
            let t = Date()
            let s = LanguageModelSession(instructions: Self.correctionInstructions)
            _ = try? await s.respond(to: "warm up", options: .init(maximumResponseTokens: 4))
            corrector = s
            correctorMS = Date().timeIntervalSince(t) * 1000
        }
        let t2 = Date()
        _ = try? await translator.translate("warm up")
        translatorMS = Date().timeIntervalSince(t2) * 1000
        return (correctorMS, translatorMS)
    }

    public func setStreamStart(_ d: Date) { streamStart = d }

    /// Re-anchor the latency clock on the next result. Used after capture is
    /// rebuilt: the analyzer's audio clock survives the restart, wall clock does
    /// not, and without this the two disagree by however long the gap was.
    public func requestRebaseline() { needsRebaseline = true }
    private var needsRebaseline = false

    // MARK: Result intake

    /// Deliberately *not* async. Painting English must never queue behind a
    /// translation round trip: when it did, English inherited the translator's
    /// latency and the paced audio feed was starved along with it.
    public func handle(result: SpeechTranscriber.Result) {
        let words = timedWords(result.text)
        guard !words.isEmpty else { return }

        if needsRebaseline, let end = words.last?.end, end.isFinite {
            streamStart = Date().addingTimeInterval(-end)
            needsRebaseline = false
        }
        confidences.append(contentsOf: words.map(\.confidence))
        if result.isFinal {
            committed.append(contentsOf: words)
            volatileWords = []
            let snapshot = committed
            committed = []
            lastTranslatedCount = 0
            // Any queued prefix translation is now superseded by the finished
            // sentence, so drop it rather than make the final line wait behind it.
            queued.removeAll()
            translationQueued = false
            schedule { await self.finalizeUtterance(snapshot) }
        } else {
            volatileWords = words
            emitEnglish(words)
            scheduleTranslation()
        }
    }

    // MARK: Single-flight scheduling

    private var work: Task<Void, Never>?
    private var queued: [() async -> Void] = []

    /// Serialises translation/correction work off the result path, so a slow
    /// call delays only the translated line and never the English one.
    private func schedule(_ job: @escaping () async -> Void) {
        queued.append(job)
        guard work == nil else { return }
        work = Task { @MainActor in
            while !queued.isEmpty {
                let next = queued.removeFirst()
                await next()
            }
            work = nil
        }
    }

    /// Prefix translations are coalescing: if one is already pending there is no
    /// point queuing another, because the newer prefix supersedes it.
    private func scheduleTranslation() {
        guard !translationQueued else { return }
        translationQueued = true
        schedule { [weak self] in
            guard let self else { return }
            self.translationQueued = false
            await self.maybeTranslatePrefix()
        }
    }
    private var translationQueued = false

    public func drain() async { await work?.value }

    /// English is painted from the volatile hypothesis with no processing in
    /// between — it is the fastest thing the system can show.
    private func emitEnglish(_ words: [TimedWord]) {
        let all = committed + words
        guard let last = all.last else { return }
        emit(CaptionEvent(kind: .english,
                          english: all.map(\.text).joined(separator: " "),
                          translation: lastTranslation,
                          audioTime: last.end,
                          latency: latency(to: last.end),
                          corrected: false,
                          confidence: all.map(\.confidence).min() ?? 1))
    }

    // MARK: Prefix translation

    private func maybeTranslatePrefix() async {
        let all = committed + volatileWords
        guard all.count - lastTranslatedCount >= config.retranslateEveryWords,
              all.count > config.maskK else { return }

        // Hold back the newest k words: they are the least stable.
        let shown = Array(all.dropLast(config.maskK))
        guard let anchor = shown.last else { return }
        let source = shown.map(\.text).joined(separator: " ")

        lastTranslatedCount = all.count
        let t0 = Date()
        guard let vi = try? await translator.translate(source).targetText else { return }
        lastTranslateMS = Date().timeIntervalSince(t0) * 1000
        translateCalls += 1
        translateTotalMS += lastTranslateMS
        lastTranslation = vi
        emit(CaptionEvent(kind: .translation,
                          english: all.map(\.text).joined(separator: " "),
                          translation: vi,
                          audioTime: anchor.end,
                          latency: latency(to: anchor.end),
                          corrected: false,
                          confidence: shown.map(\.confidence).min() ?? 1))
    }

    // MARK: Finalization

    private func finalizeUtterance(_ words: [TimedWord]) async {
        guard let last = words.last else { return }
        var english = words.map(\.text).joined(separator: " ")
        let minConf = words.map(\.confidence).min() ?? 1
        var corrected = false

        // Layer 1: glossary repair. Sub-millisecond, deterministic, and — unlike
        // recognizer-side biasing — it works on any backend's output.
        let repaired = repairAgainstGlossary(english)
        if repaired != english { english = repaired; corrected = true }

        // Layer 2: the LLM, only when the recognizer was unsure. Most segments
        // never reach here, which is where the average saving comes from.
        if config.enableCorrection, minConf < config.correctionConfidenceThreshold,
           let corrector {
            let tc = Date()
            let fixedOpt = try? await corrector.respond(
                to: "Transcript: \(english)",
                options: .init(temperature: 0.0, maximumResponseTokens: 120)
            ).content
            correctCalls += 1
            correctTotalMS += Date().timeIntervalSince(tc) * 1000
            if let fixed = fixedOpt {
                let clean = fixed.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty, clean.count < english.count * 2 {
                    if clean != english { corrected = true }
                    english = clean
                }
            }
        }

        let tf = Date()
        let vi = (try? await translator.translate(english).targetText) ?? lastTranslation
        translateCalls += 1
        translateTotalMS += Date().timeIntervalSince(tf) * 1000
        lastTranslation = vi
        emit(CaptionEvent(kind: .finalized,
                          english: english,
                          translation: vi,
                          audioTime: last.end,
                          latency: latency(to: last.end),
                          corrected: corrected,
                          confidence: minConf))

    }

    // MARK: Glossary

    /// Repairs course jargon against the term list. Works on the recognizer's
    /// *text*, so it behaves identically whichever ASR backend produced it —
    /// unlike recognizer-side vocabulary biasing, which not every backend offers.
    private func repairAgainstGlossary(_ s: String) -> String {
        guard !glossary.isEmpty else { return s }
        var words = s.split(separator: " ").map(String.init)
        var out: [String] = []
        var i = 0
        while i < words.count {
            let w = words[i]
            let bare = w.trimmingCharacters(in: .punctuationCharacters)

            // A term the recognizer split across two words ("eigon vector" for
            // "eigenvector") can only be recovered by testing the pair together.
            if i + 1 < words.count {
                let nextBare = words[i + 1].trimmingCharacters(in: .punctuationCharacters)
                let joined = bare + nextBare
                if let term = closestTerm(to: joined), term.count >= 6 {
                    let trailing = String(words[i + 1].reversed().prefix(while: { $0.isPunctuation }).reversed())
                    out.append(term + trailing)
                    i += 2
                    continue
                }
            }

            if bare.count >= 4, let term = closestTerm(to: bare) {
                out.append(w.replacingOccurrences(of: bare, with: term))
            } else {
                out.append(w)
            }
            i += 1
        }
        words = out
        return words.joined(separator: " ")
    }

    /// Nearest glossary term, or nil when nothing is close enough. The distance
    /// budget scales with term length so short ordinary words are never rewritten.
    private func closestTerm(to candidate: String) -> String? {
        let c = candidate.lowercased()
        guard c.count >= 4 else { return nil }
        if glossary.contains(where: { $0.lowercased() == c }) { return nil }
        var best: (String, Int)? = nil
        for term in glossary where abs(term.count - c.count) <= 3 {
            let d = editDistance(c, term.lowercased())
            if d <= max(1, term.count / 4), best == nil || d < best!.1 { best = (term, d) }
        }
        return best?.0
    }

    private func latency(to audioTime: Double) -> Double {
        guard audioTime.isFinite else { return .nan }
        return Date().timeIntervalSince(streamStart.addingTimeInterval(audioTime))
    }

    static let correctionInstructions = """
    You repair speech-recognition output from a university lecture.
    Fix only words that were clearly misheard. Preserve the original wording, \
    punctuation and capitalisation everywhere else. If nothing is wrong, return \
    the input unchanged. Reply with the corrected sentence and nothing else.
    """
}

func editDistance(_ a: String, _ b: String) -> Int {
    let a = Array(a), b = Array(b)
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }
    var prev = Array(0...b.count)
    var cur = [Int](repeating: 0, count: b.count + 1)
    for i in 1...a.count {
        cur[0] = i
        for j in 1...b.count {
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i-1] == b[j-1] ? 0 : 1))
        }
        swap(&prev, &cur)
    }
    return prev[b.count]
}
