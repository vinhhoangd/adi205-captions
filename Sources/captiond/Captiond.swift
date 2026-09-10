import SwiftUI
import AppKit
import Speech
import Translation
import AVFoundation
import CaptionCore

/// Launched from Finder there is no console, so the log goes to a file the
/// group can tail during a demo: `tail -f /tmp/captiond.log`.
func note(_ m: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(m)\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
    let path = ProcessInfo.processInfo.environment["CAPTION_LOG"] ?? "/tmp/captiond.log"
    if let h = FileHandle(forWritingAtPath: path) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

/// Owns the TranslationSession (only SwiftUI vends one) and drives the live
/// pipeline. The window is incidental — the real interface is the caption page
/// every laptop and phone in the room opens.
struct CaptiondView: View {
    @State private var config: TranslationSession.Configuration?
    @State private var status = "starting…"
    @State private var viewers = 0
    @State private var urls: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ADI205 live captions").font(.headline)
            Text(status).font(.caption).foregroundStyle(.secondary)
            ForEach(urls, id: \.self) { u in
                Text(u).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            Text("\(viewers) viewer\(viewers == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
        .task {
            let target = ProcessInfo.processInfo.environment["CAPTION_LANG"] ?? "vi"
            config = TranslationSession.Configuration(
                source: Locale.Language(identifier: "en"),
                target: Locale.Language(identifier: target))
        }
        .translationTask(config) { session in
            await run(session: session,
                      status: { status = $0 },
                      viewers: { viewers = $0 },
                      urls: { urls = $0 })
        }
    }
}

@MainActor
func run(session: TranslationSession,
         status: @escaping (String) -> Void,
         viewers: @escaping (Int) -> Void,
         urls: @escaping ([String]) -> Void) async {

    let env = ProcessInfo.processInfo.environment
    let lang = env["CAPTION_LANG"] ?? "vi"
    let port = UInt16(env["CAPTION_PORT"] ?? "") ?? 8420
    var cfg = PipelineConfig()
    cfg.maskK = Int(env["CAPTION_MASK_K"] ?? "") ?? 3
    cfg.targetLanguage = lang
    cfg.enableCorrection = (env["CAPTION_CORRECTION"] ?? "0") == "1"
    let glossary = (env["CAPTION_GLOSSARY"] ?? "")
        .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

    // Server first, so viewers can connect while the models warm up.
    let server: CaptionServer
    do {
        server = try CaptionServer(port: port, page: CaptionPage.html(target: lang))
        server.start()
    } catch { status("server failed: \(error)"); note("server failed: \(error)"); return }

    let addrs = CaptionServer.lanAddresses().map { "http://\($0):\(port)" }
    urls(["http://localhost:\(port)"] + addrs)
    note("captions at: " + (["http://localhost:\(port)"] + addrs).joined(separator: "  "))

    // Log what inputs exist, so choosing one for the distance A/B is possible
    // without guessing at names.
    for d in AudioDevices.inputs() {
        note(String(format: "input: %@%@  %.0f Hz  %.1f ms",
                    d.name, d.isDefault ? " (default)" : "", d.sampleRate, d.latencyMS))
    }
    var chosenDevice: AudioDeviceID? = nil
    if let want = env["CAPTION_DEVICE"], !want.isEmpty {
        if let d = AudioDevices.find(matching: want) {
            chosenDevice = d.id; note("selected input: \(d.name)")
        } else {
            note("no input matching \"\(want)\" — falling back to the default device")
        }
    }

    let setup: AnalyzerSetup
    do {
        setup = try await AnalyzerSetup.make(
            glossary: glossary,
            speechDetection: (env["CAPTION_VAD"] ?? "1") == "1")
    } catch { status("setup: \(error)"); note("setup: \(error)"); return }
    let format = setup.format
    note("biasing terms: \(glossary.count) · speech detector: \(setup.detector != nil)")

    let pipeline = CaptionPipeline(config: cfg, translator: session, glossary: glossary)
    var finals = 0
    pipeline.onEvent { ev in
        server.broadcast(ev)
        viewers(server.viewerCount)
        if ev.kind == .finalized {
            finals += 1
            note(String(format: "#%d [%.0f ms] EN: %@", finals, ev.latency * 1000, ev.english))
            note("        \(lang.uppercased()): \(ev.translation)")
        }
    }

    note("server up, warming models")
    status("warming models…")
    let (c, t) = await pipeline.warmUp()
    note(String(format: "warm-up: corrector %.0f ms, translator %.0f ms", c, t))

    let granted = await MicSource.requestAccess()
    note("microphone access: \(MicSource.accessStatus)")
    guard granted else {
        status("microphone access denied — grant it in System Settings › Privacy › Microphone")
        note("DENIED: grant access in System Settings > Privacy & Security > Microphone, then relaunch")
        return
    }
    let mic = MicSource(format: format,
                        chunkMS: Double(env["CAPTION_CHUNK_MS"] ?? "") ?? 50,
                        voiceProcessing: (env["CAPTION_VOICEPROC"] ?? "0") == "1",
                        deviceID: chosenDevice)
    mic.onLog = { m in note("mic: \(m)") }
    mic.onRebaseline = { Task { @MainActor in pipeline.requestRebaseline() } }
    let stream: AsyncStream<AnalyzerInput>
    do { stream = try mic.start() }
    catch { status("microphone: \(error)"); note("microphone: \(error)"); return }

    // The tap fires on the first captured buffer; that instant is latency zero.
    Task {
        while mic.startDate == nil { try? await Task.sleep(for: .milliseconds(5)) }
        if let d = mic.startDate { pipeline.setStreamStart(d) }
    }

    // The analysis context carries the biasing terms, and it can only be passed
    // through this initialiser — not through SpeechAnalyzer(modules:).
    let analyzer = SpeechAnalyzer(inputSequence: stream,
                                  modules: setup.modules,
                                  analysisContext: setup.context)
    Task {
        do {
            for try await result in setup.transcriber.results { pipeline.handle(result: result) }
        } catch { note("results ended: \(error)") }
    }
    if let detector = setup.detector {
        Task {
            var speaking = false
            do {
                for try await r in detector.results where r.speechDetected != speaking {
                    speaking = r.speechDetected
                    note("speech \(speaking ? "started" : "ended")")
                }
            } catch { note("detector ended: \(error)") }
        }
    }

    // No start(inputSequence:) here: this initialiser already owns the stream,
    // and an AsyncStream has exactly one consumer — attaching twice would split
    // the audio between them.
    _ = analyzer

    note("microphone tap installed, analyzer running")
    // Poll capture stats off the audio thread.
    Task {
        var last = 0
        while true {
            try? await Task.sleep(for: .seconds(5))
            let st = mic.stats
            var flag = ""
            if st.taps == last { flag = "  <- TAP NOT FIRING" }
            else if st.converted == 0 { flag = "  <- CONVERSION FAILING" }
            else if st.level < 0.001 { flag = "  <- silent" }
            note(String(format: "capture: %d taps (+%d), %d converted, peak %.4f%@%@",
                        st.taps, st.taps - last, st.converted, st.level, flag,
                        st.error.map { " err: \($0)" } ?? ""))
            last = st.taps
        }
    }

    status("live · \(lang) · mask-k \(cfg.maskK)")
    note("listening.")
}
