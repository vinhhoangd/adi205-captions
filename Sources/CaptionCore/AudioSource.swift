import Foundation
@preconcurrency import AVFoundation
import Speech

/// Feeds a WAV file into the analyzer *at real-time pace*, so that latency
/// measured against wall clock means the same thing it would from a microphone.
///
/// Replaying a file as fast as it decodes would produce meaningless latency
/// numbers: the analyzer would be handed the whole lecture in a second. Pacing
/// makes the file path and the live path measure the same quantity.
public struct PacedFileSource {

    public let sampleRate: Double
    public let totalDuration: TimeInterval
    private let buffers: [AVAudioPCMBuffer]
    private let chunkSeconds: Double

    /// - Parameter chunkMS: capture granularity. Smaller means lower latency at
    ///   the cost of more wakeups; 50 ms is a reasonable live default.
    public init(url: URL, target format: AVAudioFormat, chunkMS: Double = 50) throws {
        let file = try AVAudioFile(forReading: url)
        guard let converter = AVAudioConverter(from: file.processingFormat, to: format) else {
            throw CaptionError.audio("cannot convert \(file.processingFormat) to \(format)")
        }

        // Decode whole file, then re-chunk at the target rate.
        let inCapacity = AVAudioFrameCount(file.length)
        guard inCapacity > 0,
              let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: inCapacity) else {
            throw CaptionError.audio("empty or unreadable file: \(url.lastPathComponent)")
        }
        try file.read(into: inBuf)

        let ratio = format.sampleRate / file.processingFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 4096
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outCapacity) else {
            throw CaptionError.audio("cannot allocate output buffer")
        }
        let latch = ConverterLatch()
        var convErr: NSError?
        converter.convert(to: outBuf, error: &convErr) { _, status in
            guard latch.take() else { status.pointee = .endOfStream; return nil }
            status.pointee = .haveData; return inBuf
        }
        if let convErr { throw CaptionError.audio("conversion failed: \(convErr.localizedDescription)") }

        // Slice into fixed-size chunks. Copy raw bytes rather than reaching for
        // floatChannelData: SpeechAnalyzer asks for Int16 on this machine, and a
        // float-typed accessor returns nil for it, which silently yields nothing.
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        let chunkFrames = AVAudioFrameCount(format.sampleRate * chunkMS / 1000.0)
        var out: [AVAudioPCMBuffer] = []
        var offset: AVAudioFrameCount = 0
        while offset < outBuf.frameLength {
            let n = min(chunkFrames, outBuf.frameLength - offset)
            guard let slice = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n) else { break }
            let src = UnsafeMutableAudioBufferListPointer(outBuf.mutableAudioBufferList)
            let dst = UnsafeMutableAudioBufferListPointer(slice.mutableAudioBufferList)
            for i in 0..<min(src.count, dst.count) {
                guard let sp = src[i].mData, let dp = dst[i].mData else { continue }
                memcpy(dp, sp.advanced(by: Int(offset) * bytesPerFrame), Int(n) * bytesPerFrame)
            }
            slice.frameLength = n
            out.append(slice)
            offset += n
        }
        guard !out.isEmpty else {
            throw CaptionError.audio("decoded 0 frames from \(url.lastPathComponent)")
        }

        self.buffers = out
        self.sampleRate = format.sampleRate
        self.chunkSeconds = chunkMS / 1000.0
        self.totalDuration = Double(outBuf.frameLength) / format.sampleRate
    }

    /// Yields analyzer input in real time, treating `start` as the instant the
    /// first sample was captured. The caller hands the same `start` to the
    /// pipeline, so both sides measure latency against one agreed zero point.
    public func stream(startingAt start: Date) -> AsyncStream<AnalyzerInput> {
        // The buffers are filled once during init and only read from here on,
        // so handing them to the producer task is safe even though AVAudioPCMBuffer
        // carries no Sendable conformance of its own.
        let box = BufferBox(buffers: self.buffers)
        let chunkSeconds = self.chunkSeconds
        return AsyncStream(AnalyzerInput.self, bufferingPolicy: .unbounded) { cont in
            let task = Task {
                for (i, buf) in box.buffers.enumerated() {
                    // Wake when this chunk's audio would have finished arriving.
                    let due = start.addingTimeInterval(Double(i + 1) * chunkSeconds)
                    let wait = due.timeIntervalSinceNow
                    if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                    if Task.isCancelled { break }
                    cont.yield(AnalyzerInput(buffer: buf))
                }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}

public enum CaptionError: Error, CustomStringConvertible {
    case audio(String)
    case setup(String)
    public var description: String {
        switch self {
        case .audio(let m): return "audio: \(m)"
        case .setup(let m): return "setup: \(m)"
        }
    }
}

/// Immutable carrier so decoded audio can cross into the producer task.
struct BufferBox: @unchecked Sendable {
    let buffers: [AVAudioPCMBuffer]
}

/// One-shot latch for `AVAudioConverter`'s input block.
///
/// The block is invoked synchronously, on this thread, before `convert` returns
/// — but its type is @Sendable, so a captured `var` trips strict concurrency.
/// A reference holds the state legally and documents why it is safe.
final class ConverterLatch: @unchecked Sendable {
    private var served = false
    /// True the first time only; false on every later call.
    func take() -> Bool {
        if served { return false }
        served = true
        return true
    }
}
