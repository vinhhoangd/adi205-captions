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
    /// Minimum gap between prefix translations. Translation calls are serial and
    /// cost ~600 ms; words arrive faster than that during continuous speech, so
    /// without a floor the queue saturates and the translated line drifts past
    /// the budget even though each individual call is fast.
    public var minRetranslateGapMS: Double = 450
    /// Every language the captions are produced in. Each costs one translation
    /// call per update; they are issued concurrently rather than in sequence.
    public var targetLanguages: [String] = ["vi"]
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
    public enum Kind: String, Sendable { case english, translation, finalized, update }
    public var kind: Kind
    /// Identifies the caption line, so a later event can fill in translations
    /// for languages that were not being watched when the line settled.
    public var id: Int = 0
    public var english: String
    /// One entry per target language, keyed by language code.
    public var translations: [String: String]
    /// Convenience for callers that only care about the first configured language.
    public var translation: String { translations.values.first ?? "" }
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
    private let translators: [String: TranslationSession]
    private var corrector: (any TextCorrector)?
    private let glossary: [String]

    private var streamStart: Date = .now
    private var committed: [TimedWord] = []
    private var volatileWords: [TimedWord] = []

    private var lastTranslatedCount = 0
    private var lastPrefixTranslateAt = Date.distantPast
    private var lastResultAt = Date.distantPast
    public private(set) var translateCalls = 0
    public private(set) var translateTotalMS = 0.0
    public private(set) var lastTranslateMS = 0.0
    public private(set) var correctCalls = 0
    public private(set) var correctTotalMS = 0.0
    public private(set) var confidences: [Double] = []
    private var lastTranslations: [String: String] = [:]
    private var lineCounter = 0

    /// Languages a viewer is actually looking at. Translation calls do not
    /// overlap — measured at 680 ms for one language and 1976 ms for three, a
    /// near-exact 3x — so translating a language nobody is reading spends the
    /// latency budget on nothing. Empty means "just the first configured one".
    private var activeLanguages: Set<String> = []
    public func setActiveLanguages(_ langs: Set<String>) {
        activeLanguages = langs.filter { translators.keys.contains($0) }
    }

    private var emit: (CaptionEvent) -> Void = { _ in }

    public init(config: PipelineConfig,
                translators: [String: TranslationSession],
                glossary: [String] = []) {
        self.config = config
        self.translators = translators
        self.glossary = glossary
    }

    public func onEvent(_ cb: @escaping (CaptionEvent) -> Void) { self.emit = cb }

    /// Chooses which model performs layer-2 repair. Must be set before `warmUp`,
    /// which is where the first-inference cost is paid. Nil leaves layer 1
    /// (glossary repair) as the only correction, which is the shipped default.
    public func setCorrector(_ c: (any TextCorrector)?) { corrector = c }

    /// Names the active corrector for logs and the bench report.
    public var correctorName: String { corrector?.name ?? "none" }

    /// First inference on any of these models costs seconds. Paying that at
    /// launch instead of on the first spoken sentence is the single cheapest
    /// latency win available, and the one most likely to matter on demo day.
    /// Returns (correctorMS, translatorMS) so the report can show what cold
    /// start would otherwise have cost the first sentence of the lecture.
    @discardableResult
    public func warmUp() async -> (Double, Double) {
        var correctorMS = 0.0, translatorMS = 0.0
        if config.enableCorrection, let corrector {
            correctorMS = await corrector.warmUp()
        }
        let t2 = Date()
        for (_, session) in translators { _ = try? await session.translate("warm up") }
        translatorMS = Date().timeIntervalSince(t2) * 1000
        return (correctorMS, translatorMS)
    }

    public func setStreamStart(_ d: Date) { streamStart = d }

    /// Supplies the audio-clock-to-wall-clock mapping. Without it latency is
    /// measured against a fixed start time, which drifts by the total duration
    /// of every silence the speech gate removed — inflating a short utterance
    /// after a long pause by the whole pause.
    public var audioClock: (@Sendable (Double) -> Date?)?

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
        lastResultAt = Date()
        confidences.append(contentsOf: words.map(\.confidence))
        if confidences.count > 20_000 { confidences.removeFirst(confidences.count - 20_000) }
        if result.isFinal {
            committed.append(contentsOf: words)
            volatileWords = []
            let snapshot = committed
            let lineID = lineCounter
            // Advance immediately, not when the async finalise completes: the
            // next utterance starts emitting English straight away, and with a
            // stale counter its text landed in the line about to be finalised.
            lineCounter += 1
            lastTranslations = [:]
            committed = []
            lastTranslatedCount = 0
            // Any queued prefix translation is now superseded by the finished
            // sentence, so drop it rather than make the final line wait behind it.
            queued.removeAll()
            translationQueued = false
            schedule { await self.finalizeUtterance(snapshot, id: lineID) }
        } else {
            volatileWords = words
            emitEnglish(words)
            scheduleTranslation()
        }
    }

    // MARK: Single-flight scheduling

    private var work: Task<Void, Never>?
    private var queued: [() async -> Void] = []
    /// Backfill jobs live in their own queue. Superseded prefix translations are
    /// dropped when a line settles; completed-line backfills must not be, or the
    /// unwatched languages never arrive and switching tabs shows a blank history.
    private var backfill: [() async -> Void] = []

    /// Serialises translation/correction work off the result path, so a slow
    /// call delays only the translated line and never the English one.
    private func schedule(_ job: @escaping () async -> Void) {
        queued.append(job)
        pump()
    }

    private func scheduleBackfill(_ job: @escaping () async -> Void) {
        backfill.append(job)
        pump()
    }

    private func pump() {
        guard work == nil else { return }
        work = Task { @MainActor in
            while !queued.isEmpty || !backfill.isEmpty {
                // Live work first; backfills fill the gaps between utterances.
                let next = queued.isEmpty ? backfill.removeFirst() : queued.removeFirst()
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
        emit(CaptionEvent(kind: .english, id: lineCounter,
                          english: all.map(\.text).joined(separator: " "),
                          translations: lastTranslations,
                          audioTime: last.end,
                          latency: latency(to: last.end),
                          corrected: false,
                          confidence: all.map(\.confidence).min() ?? 1))
    }

    // MARK: Prefix translation

    private func maybeTranslatePrefix() async {
        let all = committed + volatileWords
        guard all.count - lastTranslatedCount >= config.retranslateEveryWords,
              !all.isEmpty else { return }
        // Do not out-run the translator. Issuing faster than it completes just
        // lengthens the queue, and the reader sees the delay, not the throughput.
        let sinceLast = Date().timeIntervalSince(lastPrefixTranslateAt) * 1000
        guard sinceLast >= config.minRetranslateGapMS else { return }

        // Hold back the newest k words: they are the least stable. But never
        // hold back everything — a fixed k of 3 meant a one- to three-word
        // utterance got no live translation at all and had to wait for the
        // recogniser to confirm the speaker had stopped, which is why "Hello?"
        // took seconds to appear. Always show at least one word.
        let k = min(config.maskK, max(0, all.count - 1))
        let shown = Array(all.dropLast(k))
        guard let anchor = shown.last else { return }
        let source = shown.map(\.text).joined(separator: " ")

        lastTranslatedCount = all.count
        lastPrefixTranslateAt = Date()
        let t0 = Date()
        let got = await translateAll(source)
        guard !got.isEmpty else { return }
        lastTranslateMS = Date().timeIntervalSince(t0) * 1000
        translateCalls += 1
        translateTotalMS += lastTranslateMS
        lastTranslations = lastTranslations.merging(got) { _, new in new }
        emit(CaptionEvent(kind: .translation, id: lineCounter,
                          english: all.map(\.text).joined(separator: " "),
                          translations: got,
                          audioTime: anchor.end,
                          latency: latency(to: anchor.end),
                          corrected: false,
                          confidence: shown.map(\.confidence).min() ?? 1))
    }

    // MARK: Finalization

    private func finalizeUtterance(_ words: [TimedWord], id lineID: Int) async {
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
            let fixedOpt = await corrector.correct(english)
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
        // Only what was translated for THIS line. Merging in lastTranslations
        // attached the previous sentence's text to this one for any language not
        // retranslated here.
        var finalTr = await translateAll(english)
        if finalTr.isEmpty { finalTr = lastTranslations }
        lastTranslateMS = Date().timeIntervalSince(tf) * 1000
        translateCalls += 1
        translateTotalMS += lastTranslateMS
        lastTranslations = finalTr

        // Languages nobody was watching when this line settled would otherwise
        // stay blank forever, so switching tabs showed an empty history. Fill
        // them in afterwards: the watched language is already on screen, so this
        // costs the reader nothing.
        let missing = Set(config.targetLanguages).subtracting(finalTr.keys)
        if !missing.isEmpty {
            let sentence = english
            scheduleBackfill { [weak self] in
                guard let self else { return }
                // Wait for a lull. A backfill blocking the worker delays the live
                // translated line of the sentence being spoken right now.
                while Date().timeIntervalSince(self.lastResultAt) < 0.6 {
                    try? await Task.sleep(for: .milliseconds(200))
                }
                let extra = await self.translate(sentence, into: missing)
                guard !extra.isEmpty else { return }
                self.emit(CaptionEvent(kind: .update, id: lineID,
                                       english: sentence,
                                       translations: extra,
                                       audioTime: .nan, latency: .nan,
                                       corrected: false, confidence: 1))
            }
        }

        emit(CaptionEvent(kind: .finalized, id: lineID,
                          english: english,
                          translations: finalTr,
                          audioTime: last.end,
                          latency: latency(to: last.end),
                          corrected: corrected,
                          confidence: minConf))

    }

    /// Translates one source string into the languages currently being watched.
    ///
    /// These calls were written to fan out concurrently. They do not: the tasks
    /// are MainActor-isolated and queue behind one another, measured at 680 ms
    /// for one language against 1976 ms for three. Since the cost is linear in
    /// the number of languages, the fix is to ask for fewer — only the ones a
    /// viewer has open.
    private func translate(_ source: String, into langs: Set<String>) async -> [String: String] {
        var started: [(String, Task<String?, Never>)] = []
        for (lang, session) in translators where langs.contains(lang) {
            started.append((lang, Task { @MainActor in
                try? await session.translate(source).targetText
            }))
        }
        var out: [String: String] = [:]
        for (lang, task) in started { if let t = await task.value { out[lang] = t } }
        return out
    }

    private func translateAll(_ source: String) async -> [String: String] {
        // Start every translation before awaiting any of them. A task group trips
        // the region-isolation checker here because TranslationSession is not
        // Sendable; these tasks inherit MainActor isolation instead, so nothing
        // crosses an isolation boundary.
        let wanted: Set<String> = activeLanguages.isEmpty
            ? Set(config.targetLanguages.prefix(1))
            : activeLanguages
        var started: [(String, Task<String?, Never>)] = []
        for (lang, session) in translators where wanted.contains(lang) {
            started.append((lang, Task { @MainActor in
                try? await session.translate(source).targetText
            }))
        }
        var out: [String: String] = [:]
        for (lang, task) in started {
            if let text = await task.value { out[lang] = text }
        }
        return out
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
        if let captured = audioClock?(audioTime) {
            return Date().timeIntervalSince(captured)
        }
        // Fallback for the file bench, which feeds contiguously with no gaps.
        return Date().timeIntervalSince(streamStart.addingTimeInterval(audioTime))
    }

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

/// Tracks which languages viewers have open, with an expiry so a viewer who
/// closes their tab stops costing translation time. Thread-safe: reports arrive
/// on the server's queue, reads happen on the main actor.
public final class ViewingTracker: @unchecked Sendable {
    private var seen: [String: Date] = [:]
    private let lock = NSLock()
    private let ttl: TimeInterval

    public init(ttl: TimeInterval = 90) { self.ttl = ttl }

    public func note(_ langs: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        for l in langs { seen[l] = now }
    }

    /// Languages reported recently; falls back to nothing, which the pipeline
    /// reads as "just the first configured language".
    public func active(all: Set<String>) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        let cutoff = Date().addingTimeInterval(-ttl)
        seen = seen.filter { $0.value > cutoff }
        return Set(seen.keys).intersection(all)
    }
}
