import SwiftUI
import AppKit
import Speech
import Translation
import AVFoundation
import CaptionCore

func trace(_ m: String) {
    FileHandle.standardError.write("[trace \(String(format: "%.2f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000)))] \(m)\n".data(using: .utf8)!)
}

// The Translation framework only vends a TranslationSession through SwiftUI's
// .translationTask, so even the headless benchmark is hosted by a tiny app.
// It prints to stdout and exits.

/// Holds one TranslationSession per language, exactly as the app does, so a
/// benchmark result describes the shipping configuration rather than a simpler
/// one. Each closure parks to keep its session valid.
struct BenchView: View {
    @State private var cfgVI: TranslationSession.Configuration?
    @State private var cfgHans: TranslationSession.Configuration?
    @State private var cfgHant: TranslationSession.Configuration?
    @State private var sessions: [String: TranslationSession] = [:]
    @State private var started = false

    private var wanted: [String] {
        (ProcessInfo.processInfo.environment["BENCH_LANGS"] ?? "vi")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        Text("bench running…")
            .frame(width: 240, height: 60)
            .task {
                let src = Locale.Language(identifier: "en")
                if wanted.contains("vi") { cfgVI = .init(source: src, target: .init(identifier: "vi")) }
                if wanted.contains("zh-Hans") { cfgHans = .init(source: src, target: .init(identifier: "zh-Hans")) }
                if wanted.contains("zh-Hant") { cfgHant = .init(source: src, target: .init(identifier: "zh-Hant")) }
            }
            .translationTask(cfgVI)   { s in await hold("vi", s) }
            .translationTask(cfgHans) { s in await hold("zh-Hans", s) }
            .translationTask(cfgHant) { s in await hold("zh-Hant", s) }
    }

    @MainActor
    private func hold(_ lang: String, _ session: TranslationSession) async {
        sessions[lang] = session
        if !started, sessions.count == wanted.count {
            started = true
            let all = sessions
            Task { @MainActor in exit(await runBench(sessions: all)) }
        }
        while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
    }
}

// MARK: - Stats

func pct(_ xs: [Double], _ p: Double) -> Double {
    guard !xs.isEmpty else { return .nan }
    let s = xs.sorted()
    let i = Int((Double(s.count - 1) * p).rounded())
    return s[i]
}

@MainActor
func runBench(sessions: [String: TranslationSession]) async -> Int32 {
    let env = ProcessInfo.processInfo.environment
    let args = CommandLine.arguments.filter { $0.hasSuffix(".wav") || $0.hasSuffix(".aiff") }
    guard let path = args.first ?? env["BENCH_WAV"] else {
        FileHandle.standardError.write("usage: bench <file.wav>  (or BENCH_WAV=…)\n".data(using: .utf8)!)
        return 2
    }

    var cfg = PipelineConfig()
    cfg.maskK = Int(env["BENCH_MASK_K"] ?? "") ?? 3
    cfg.enableCorrection = (env["BENCH_CORRECTION"] ?? "0") == "1"
    cfg.correctionConfidenceThreshold = Double(env["BENCH_CONF"] ?? "") ?? 0.75
    cfg.targetLanguages = Array(sessions.keys).sorted()
    let chunkMS = Double(env["BENCH_CHUNK_MS"] ?? "") ?? 50

    let glossary = (env["BENCH_GLOSSARY"] ?? "")
        .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }

    // Same builder the product uses, so a benchmark result describes the product.
    let setup: AnalyzerSetup
    do {
        // BENCH_BIAS controls what the *recognizer* is biased with; BENCH_GLOSSARY
        // controls what the *repair pass* matches against. Separating them is the
        // only way to tell which of the two actually fixed a word.
        let biasTerms = env["BENCH_BIAS"].map {
            $0.split(separator: ",").map { t in t.trimmingCharacters(in: .whitespaces) }
             .filter { t in !t.isEmpty }
        } ?? glossary
        setup = try await AnalyzerSetup.make(
            glossary: biasTerms,
            speechDetection: (env["BENCH_VAD"] ?? "1") == "1")
    } catch { print("setup: \(error)"); return 3 }
    let transcriber = setup.transcriber
    let format = setup.format

    let pipeline = CaptionPipeline(config: cfg, translators: sessions, glossary: glossary)

    let collector = EventCollector()
    pipeline.onEvent { ev in collector.add(ev) }

    trace("starting warm-up")
    let (warmCorrMS, warmTransMS) = await pipeline.warmUp()

    trace("warm-up done")
    let source: PacedFileSource
    do { source = try PacedFileSource(url: URL(fileURLWithPath: path), target: format, chunkMS: chunkMS) }
    catch { print("error: \(error)"); return 4 }


    // One agreed zero point for every latency figure below.
    let t0 = Date().addingTimeInterval(0.05)
    pipeline.setStreamStart(t0)
    let raw = source.stream(startingAt: t0)
    let stream = AsyncStream<AnalyzerInput>(bufferingPolicy: .unbounded) { cont in
        Task {
            var n = 0
            for await item in raw {
                n += 1
                if n <= 2 || n % 60 == 0 {
                    let b = item.buffer
                    var rms = 0.0
                    if let d = b.int16ChannelData {
                        for i in 0..<Int(b.frameLength) { let v = Double(d[0][i]) / 32768.0; rms += v * v }
                    } else if let d = b.floatChannelData {
                        for i in 0..<Int(b.frameLength) { rms += Double(d[0][i] * d[0][i]) }
                    }
                    rms = (rms / Double(max(1, b.frameLength))).squareRoot()
                    trace("yield #\(n) frames=\(b.frameLength) rms=\(String(format: "%.4f", rms))")
                }
                cont.yield(item)
            }
            trace("paced source produced \(n) buffers")
            cont.finish()
        }
    }

    let consumer = Task {
        var n = 0
        do {
            for try await result in transcriber.results {
                n += 1
                if n <= 3 || n % 20 == 0 {
                    trace("result #\(n) final=\(result.isFinal) \"\(String(result.text.characters).prefix(40))\"")
                }
                await pipeline.handle(result: result)
            }
            trace("results sequence ended after \(n)")
        } catch { trace("results error after \(n): \(error)") }
    }

    let analyzer = SpeechAnalyzer(inputSequence: stream,
                                  modules: setup.modules,
                                  analysisContext: setup.context)
    do {
        trace("analyzer running")
        // The initialiser owns the stream; the paced source feeds it in real
        // time. Finalising before that finishes would analyse silence.
        try await Task.sleep(for: .seconds(source.totalDuration + 0.4))
        trace("audio fed, finalising")
        try await analyzer.finalizeAndFinishThroughEndOfInput()
    } catch { print("analyzer error: \(error)"); return 5 }
    trace("stream finished, draining results")
    _ = await consumer.result
    await pipeline.drain()
    trace("consumer done")

    // ---- report ----
    let events = collector.all()
    let enL = events.filter { $0.kind == .english }.map(\.latency).filter { $0.isFinite }
    let viL = events.filter { $0.kind == .translation }.map(\.latency).filter { $0.isFinite }
    let finals = events.filter { $0.kind == .finalized }

    print("")
    print("file            \((path as NSString).lastPathComponent)")
    print(String(format: "audio           %.2f s", source.totalDuration))
    print("chunk           \(Int(chunkMS)) ms     mask-k \(cfg.maskK)     correction \(cfg.enableCorrection ? "on" : "off")")
    print("languages       \(cfg.targetLanguages.joined(separator: ", "))")
    print("biasing         \(setup.context.contextualStrings[.general]?.count ?? 0) terms      speech detector \(setup.detector != nil ? "on" : "off")")
    print(String(format: "warm-up         corrector %.0f ms · translator %.0f ms", warmCorrMS, warmTransMS))
    print("                (paid once at launch — this is what the first spoken")
    print("                 sentence would have cost without pre-warming)")
    print("")
    print("                      n    median      p90       max")
    func row(_ n: String, _ xs: [Double]) {
        guard !xs.isEmpty else { print(String(format: "  %-18@ %4d         —        —         —", n as NSString, 0)); return }
        print(String(format: "  %-18@ %4d  %7.0f ms %7.0f ms %7.0f ms",
                     n as NSString, xs.count, pct(xs, 0.5) * 1000, pct(xs, 0.9) * 1000, (xs.max() ?? 0) * 1000))
    }
    row("English line", enL)
    row("Translated line", viL)
    print("")
    let tc = pipeline.translateCalls, cc = pipeline.correctCalls
    print(String(format: "  translate calls   %4d  %7.0f ms avg", tc, tc > 0 ? pipeline.translateTotalMS / Double(tc) : 0))
    let cs = pipeline.confidences.sorted()
    if !cs.isEmpty {
        print(String(format: "  ASR confidence    min %.2f  p10 %.2f  median %.2f  (gate at %.2f)",
                     cs.first!, cs[max(0, cs.count / 10)], cs[cs.count / 2], cfg.correctionConfidenceThreshold))
    }
    print(String(format: "  correction calls  %4d  %7.0f ms avg  (gated: skipped when ASR was confident)",
                 cc, cc > 0 ? pipeline.correctTotalMS / Double(cc) : 0))
    print("")
    for f in finals {
        print("  EN  \(f.english)")
        for l in cfg.targetLanguages { print("  \(l)  \(f.translations[l] ?? "—")") }
        print(String(format: "      final latency %.0f ms · min confidence %.2f%@",
                     f.latency * 1000, f.confidence, f.corrected ? " · corrected" : ""))
        print("")
    }

    if let csv = env["BENCH_CSV"] {
        var out = "kind,audio_time_s,latency_ms,confidence,corrected,english,translation\n"
        for e in events {
            let esc = { (s: String) in "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            out += "\(e.kind.rawValue),\(String(format: "%.3f", e.audioTime)),"
            out += "\(String(format: "%.1f", e.latency * 1000)),\(String(format: "%.3f", e.confidence)),"
            out += "\(e.corrected),\(esc(e.english)),\(esc(e.translation))\n"
        }
        try? out.write(toFile: csv, atomically: true, encoding: .utf8)
        print("csv → \(csv)")
    }
    return 0
}

final class EventCollector: @unchecked Sendable {
    private var events: [CaptionEvent] = []
    private let lock = NSLock()
    func add(_ e: CaptionEvent) { lock.lock(); events.append(e); lock.unlock() }
    func all() -> [CaptionEvent] { lock.lock(); defer { lock.unlock() }; return events }
}
