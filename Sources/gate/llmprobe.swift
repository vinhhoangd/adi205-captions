import Foundation
import FoundationModels

/// Measures what one on-device correction actually costs on this machine.
/// The pipeline's whole correction design depends on this number.
func probeLLM() async {
    guard case .available = SystemLanguageModel.default.availability else {
        print("  SystemLanguageModel unavailable"); return
    }
    let instructions = """
    You repair speech-recognition output from a university lecture.
    Fix only words that were clearly misheard. Reply with the corrected \
    sentence and nothing else.
    """
    let sentence = "Theorem lets us update a prior into posterior."
    for cap in [30, 60, 120] {
        let s = LanguageModelSession(instructions: instructions)
        let t0 = Date()
        _ = try? await s.respond(to: "warm", options: .init(maximumResponseTokens: 4))
        let warm = Date().timeIntervalSince(t0) * 1000
        var runs: [Double] = []
        for _ in 0..<3 {
            let t = Date()
            let r = try? await s.respond(to: "Transcript: \(sentence)",
                                         options: .init(temperature: 0.0, maximumResponseTokens: cap))
            runs.append(Date().timeIntervalSince(t) * 1000)
            if cap == 30, let r { print("      → \"\(r.content.prefix(70))\"") }
        }
        print(String(format: "  maxTokens %3d   warm %6.0f ms   calls: %.0f / %.0f / %.0f ms",
                     cap, warm, runs[0], runs[1], runs[2]))
    }
}
