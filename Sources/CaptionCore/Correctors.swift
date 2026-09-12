import Foundation
import FoundationModels

/// A second-pass repair of recognizer output.
///
/// Abstracted because the two candidates have opposite failure modes. The
/// on-device model cannot fail the network but costs ~6.5 s per call; a cloud
/// model answers in well under a second but can hang on classroom wifi. Both
/// must fail *open* — a correction that does not arrive in time is dropped and
/// the uncorrected line ships, because a late caption is worse than an
/// imperfect one.
public protocol TextCorrector: Sendable {
    /// Shown in logs and in the bench report, so a measurement says which model produced it.
    var name: String { get }
    /// Pays first-inference cost up front. Returns milliseconds spent.
    func warmUp() async -> Double
    /// Returns the repaired sentence, or nil if the pass failed, timed out, or
    /// had nothing to say. Never throws: the caller has a caption to ship.
    func correct(_ text: String) async -> String?
}

let correctionInstructions = """
You repair speech-recognition output from a university lecture.
Fix only words that were clearly misheard. Preserve the original wording, \
punctuation and capitalisation everywhere else. If nothing is wrong, return \
the input unchanged. Reply with the corrected sentence and nothing else.
"""

// MARK: - Apple on-device

/// Apple's ~3B on-device model via FoundationModels. Private and offline, and
/// measured here at ~6.5 s per call — identical at 30, 60 and 120 max tokens,
/// so the cost is fixed overhead rather than generation speed.
///
/// `@unchecked Sendable`: LanguageModelSession is not Sendable, and this type is
/// only ever touched from the MainActor-isolated pipeline.
public final class AppleCorrector: TextCorrector, @unchecked Sendable {
    public let name = "apple-on-device"
    private var session: LanguageModelSession?

    public init?() {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
    }

    public func warmUp() async -> Double {
        let t = Date()
        let s = LanguageModelSession(instructions: correctionInstructions)
        _ = try? await s.respond(to: "warm up", options: .init(maximumResponseTokens: 4))
        session = s
        return Date().timeIntervalSince(t) * 1000
    }

    public func correct(_ text: String) async -> String? {
        guard let session else { return nil }
        return try? await session.respond(
            to: "Transcript: \(text)",
            options: .init(temperature: 0.0, maximumResponseTokens: 120)
        ).content
    }
}

// MARK: - Gemini

/// Google Gemini over the REST API.
///
/// Three things here exist purely to protect the latency budget. Thinking is
/// disabled — a reasoning pass on a one-sentence repair is all cost and no
/// benefit. The request carries a hard timeout, so bad wifi drops the
/// correction instead of stalling the line behind it. And the key travels in a
/// header, never in the URL, so it stays out of logs and proxy history.
///
/// Note what this trades away: the transcript leaves the room. That is a real
/// change to the project's privacy story, not just a change of model.
public struct GeminiCorrector: TextCorrector {
    public let name: String
    private let apiKey: String
    private let model: String
    private let timeout: TimeInterval
    private let thinking: Bool
    private let session: URLSession

    /// - Parameter model: any Gemini model id, e.g. `gemini-3.5-flash-lite`.
    ///   Left configurable because Google renames and retires these often, and a
    ///   hardcoded id would strand the project on a model that no longer exists.
    public init(apiKey: String,
                model: String = "gemini-3.5-flash-lite",
                timeoutMS: Double = 900,
                thinking: Bool = false) {
        self.apiKey = apiKey
        self.model = model
        self.name = "gemini:\(model)"
        self.timeout = timeoutMS / 1000
        self.thinking = thinking
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = timeoutMS / 1000
        c.waitsForConnectivity = false
        self.session = URLSession(configuration: c)
    }

    /// Reads the key from the environment. Returns nil rather than shipping a
    /// corrector that 403s on every line.
    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment)
        -> GeminiCorrector? {
        guard let key = env["GEMINI_API_KEY"], !key.isEmpty else { return nil }
        return GeminiCorrector(
            apiKey: key,
            model: env["GEMINI_MODEL"] ?? "gemini-3.5-flash-lite",
            timeoutMS: Double(env["GEMINI_TIMEOUT_MS"] ?? "") ?? 900,
            thinking: (env["GEMINI_THINKING"] ?? "0") == "1")
    }

    public func warmUp() async -> Double {
        let t = Date()
        _ = await correct("warm up")
        return Date().timeIntervalSince(t) * 1000
    }

    public func correct(_ text: String) async -> String? {
        guard let url = URL(string:
            "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")
        else { return nil }

        var gen: [String: Any] = ["temperature": 0, "maxOutputTokens": 120]
        // Flash models from 2.5 onward reason before answering unless told not
        // to. For a one-sentence repair that is pure added latency.
        if !thinking { gen["thinkingConfig"] = ["thinkingBudget": 0] }

        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": correctionInstructions]]],
            "contents": [["role": "user", "parts": [["text": "Transcript: \(text)"]]]],
            "generationConfig": gen,
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Header, not a query parameter: a key in the URL ends up in logs.
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.httpBody = payload

        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cands = obj["candidates"] as? [[String: Any]],
              let content = cands.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]]
        else { return nil }

        let out = parts.compactMap { $0["text"] as? String }.joined()
        return out.isEmpty ? nil : out
    }
}

// MARK: - OpenAI-compatible (Qwen, and anything else speaking that API)

/// Any endpoint speaking the OpenAI chat-completions API.
///
/// One implementation covers three cases that matter here: Qwen 2.5 running
/// locally under Ollama or llama.cpp, Qwen hosted by a provider, and any other
/// model behind the same shape. Only the base URL and model name change.
///
/// Run locally this is the interesting option for this project. It is a real
/// third-party model, so the comparison against Apple's is meaningful — but the
/// audio and transcript never leave the machine, so it keeps the offline and
/// private property the pipeline was designed around. A hosted endpoint gives
/// that up, exactly as the Gemini backend does.
public struct OpenAICompatibleCorrector: TextCorrector {
    public let name: String
    private let baseURL: String
    private let model: String
    private let apiKey: String?
    private let timeout: TimeInterval
    private let session: URLSession

    /// - Parameters:
    ///   - baseURL: root of the API, e.g. `http://localhost:11434/v1` for Ollama.
    ///   - apiKey: omitted for a local runtime, which authenticates nothing.
    public init(baseURL: String = "http://localhost:11434/v1",
                model: String = "qwen2.5:1.5b",
                apiKey: String? = nil,
                timeoutMS: Double = 1500,
                label: String? = nil) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.model = model
        self.apiKey = apiKey
        self.timeout = timeoutMS / 1000
        self.name = label ?? "openai-compatible:\(model)"
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = timeoutMS / 1000
        c.waitsForConnectivity = false
        self.session = URLSession(configuration: c)
    }

    public static func qwen(_ env: [String: String] = ProcessInfo.processInfo.environment)
        -> OpenAICompatibleCorrector {
        OpenAICompatibleCorrector(
            baseURL: env["QWEN_BASE_URL"] ?? "http://localhost:11434/v1",
            model: env["QWEN_MODEL"] ?? "qwen2.5:1.5b",
            apiKey: env["QWEN_API_KEY"].flatMap { $0.isEmpty ? nil : $0 },
            timeoutMS: Double(env["QWEN_TIMEOUT_MS"] ?? "") ?? 1500,
            label: "qwen:\(env["QWEN_MODEL"] ?? "qwen2.5:1.5b")")
    }

    /// A local runtime loads the weights on first use, which costs seconds.
    /// Ollama then holds the model in memory for five minutes by default, so a
    /// lecture with pauses in it stays warm.
    public func warmUp() async -> Double {
        let t = Date()
        _ = await correct("warm up")
        return Date().timeIntervalSince(t) * 1000
    }

    public func correct(_ text: String) async -> String? {
        guard let url = URL(string: "\(baseURL)/chat/completions") else { return nil }
        let body: [String: Any] = [
            "model": model,
            "temperature": 0,
            "max_tokens": 120,
            "stream": false,
            "messages": [
                ["role": "system", "content": correctionInstructions],
                ["role": "user", "content": "Transcript: \(text)"],
            ],
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        req.httpBody = payload

        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let out = msg["content"] as? String
        else { return nil }

        let clean = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
}

// MARK: - Selection

public enum CorrectorFactory {
    /// Builds whichever corrector the environment asks for. `CAPTION_CORRECTOR`
    /// (or `BENCH_CORRECTOR`) takes `apple`, `gemini` or `off`; unset means
    /// apple, so an existing setup keeps behaving exactly as it did.
    public static func make(_ env: [String: String] = ProcessInfo.processInfo.environment,
                            prefix: String = "CAPTION") -> (any TextCorrector)? {
        switch (env["\(prefix)_CORRECTOR"] ?? "apple").lowercased() {
        case "off", "none": return nil
        case "gemini": return GeminiCorrector.fromEnvironment(env)
        case "qwen", "ollama", "local": return OpenAICompatibleCorrector.qwen(env)
        default: return AppleCorrector()
        }
    }
}
