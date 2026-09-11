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
/// Owns one TranslationSession per target language and drives the live pipeline.
///
/// The Translation framework only vends a session inside `.translationTask`, and
/// that session is valid only for the lifetime of the closure. To hold three at
/// once, each closure registers its session and then parks — the suspension is
/// what keeps the session alive.
struct CaptiondView: View {
    @State private var cfgVI: TranslationSession.Configuration?
    @State private var cfgHans: TranslationSession.Configuration?
    @State private var cfgHant: TranslationSession.Configuration?

    @State private var sessions: [String: TranslationSession] = [:]
    @State private var started = false

    @State private var status = "starting…"
    @State private var viewers = 0
    @State private var urls: [String] = []

    private var wanted: [String] {
        (ProcessInfo.processInfo.environment["CAPTION_LANGS"] ?? "vi,zh-Hans,zh-Hant")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ADI205 live captions").font(.headline)
            Text(status).font(.caption).foregroundStyle(.secondary)
            ForEach(urls, id: \.self) { u in
                Text(u).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            Text("\(viewers) viewer\(viewers == 1 ? "" : "s") · \(sessions.count)/\(wanted.count) languages")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
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

    /// Registers a session, starts the pipeline once every language has one, then
    /// suspends indefinitely so the framework keeps the session valid.
    @MainActor
    private func hold(_ lang: String, _ session: TranslationSession) async {
        sessions[lang] = session
        note("translation session ready: \(lang) (\(sessions.count)/\(wanted.count))")

        if !started, sessions.count == wanted.count {
            started = true
            let all = sessions
            Task { @MainActor in
                await run(sessions: all,
                          status: { status = $0 },
                          viewers: { viewers = $0 },
                          urls: { urls = $0 })
            }
        }
        // Park. Returning here would invalidate the session.
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
    }
}

@MainActor
func run(sessions: [String: TranslationSession],
         status: @escaping (String) -> Void,
         viewers: @escaping (Int) -> Void,
         urls: @escaping ([String]) -> Void) async {

    let env = ProcessInfo.processInfo.environment
    let langs = Array(sessions.keys).sorted()
    let lang = langs.first ?? "vi"
    let port = UInt16(env["CAPTION_PORT"] ?? "") ?? 8420
    var cfg = PipelineConfig()
    cfg.maskK = Int(env["CAPTION_MASK_K"] ?? "") ?? 3
    cfg.targetLanguages = langs
    cfg.enableCorrection = (env["CAPTION_CORRECTION"] ?? "0") == "1"
    let glossary = (env["CAPTION_GLOSSARY"] ?? "")
        .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

    // Server first, so viewers can connect while the models warm up.
    let server: CaptionServer
    do {
        let token = env["CAPTION_TOKEN"].flatMap { $0.isEmpty ? nil : $0 }
        server = try CaptionServer(port: port,
                                   page: CaptionPage.html(languages: langs),
                                   accessToken: token)
        server.start()
    } catch { status("server failed: \(error)"); note("server failed: \(error)"); return }

    let suffix = (env["CAPTION_TOKEN"].flatMap { $0.isEmpty ? nil : "?k=\($0)" }) ?? ""
    let addrs = CaptionServer.lanAddresses().map { "http://\($0):\(port)\(suffix)" }
    let all = ["http://localhost:\(port)\(suffix)"] + addrs
    urls(all)
    note("captions at: " + all.joined(separator: "  "))
    if suffix.isEmpty {
        note("NOTE: no access token set. Fine on a trusted network; set CAPTION_TOKEN "
           + "before exposing this beyond the LAN — /control/start is otherwise open "
           + "to anyone who can reach the port.")
    }

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

    let pipeline = CaptionPipeline(config: cfg, translators: sessions, glossary: glossary)
    var finals = 0
    pipeline.onEvent { ev in
        server.broadcast(ev)
        viewers(server.viewerCount)
        if ev.kind == .finalized {
            finals += 1
            note(String(format: "#%d [%.0f ms] EN: %@", finals, ev.latency * 1000, ev.english))
            for l in langs { note("        \(l): \(ev.translations[l] ?? "—")") }
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

    server.onControl = { action in
        Task { @MainActor in
            switch action {
            case "start":
                do { try mic.resume(); status("recording · \(langs.joined(separator: ", "))") }
                catch { note("could not start capture: \(error)") }
            case "pause":
                mic.pause(); status("paused")
            default: note("unknown control: \(action)")
            }
        }
    }
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

    if (env["CAPTION_AUTOSTART"] ?? "0") == "1" {
        try? mic.resume()
        note("autostart: recording")
    } else {
        note("ready — paused until a viewer presses Start")
    }
    // Push a health snapshot to every viewer once a second, so silence is
    // visibly different from a dead microphone.
    Task {
        while true {
            try? await Task.sleep(for: .milliseconds(1000))
            let st = mic.stats
            let dev = AudioDevices.inputs().first { $0.isDefault }?.name ?? "unknown"
            var warn: String? = nil
            if mic.capturing {
                if st.taps == 0 { warn = "No audio reaching the app" }
                else if st.level < 0.001 { warn = "Microphone is silent — check the input device" }
            }
            server.broadcastStatus(level: mic.capturing ? st.level : 0, device: dev,
                                   language: lang, listening: mic.capturing, warning: warn)
        }
    }

    // Poll capture stats off the audio thread.
    Task {
        var last = 0
        while true {
            try? await Task.sleep(for: .seconds(5))
            let st = mic.stats
            var flag = ""
            if !mic.capturing { flag = "  (paused)" }
            else if st.taps == last { flag = "  <- TAP NOT FIRING" }
            else if st.converted == 0 { flag = "  <- CONVERSION FAILING" }
            else if st.level < 0.001 { flag = "  <- silent" }
            note(String(format: "capture: %d taps (+%d), %d converted, peak %.4f%@%@",
                        st.taps, st.taps - last, st.converted, st.level, flag,
                        st.error.map { " err: \($0)" } ?? ""))
            last = st.taps
        }
    }

    status(mic.capturing ? "recording · \(langs.joined(separator: ", "))" : "paused — press Start")
    note("listening.")
}
