import Foundation
@preconcurrency import AVFoundation
import Speech
import CoreAudio

/// Live microphone capture, converted to whatever format SpeechAnalyzer asks for.
///
/// Two things here were settled by measurement rather than intent. Voice
/// processing (Apple's AEC + noise suppression) is available but off by default,
/// because enabling it renegotiates the input format and left the tap stalling
/// on this machine. And the tap buffer is requested small — capture granularity
/// is pure added latency — but Core Audio enforces its own floor of about 96 ms
/// here regardless of what we ask for.
public final class MicSource: @unchecked Sendable {

    public let format: AVAudioFormat
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let chunkFrames: AVAudioFrameCount
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?

    /// Wall-clock instant the first sample was captured; the zero point for latency.
    public private(set) var startDate: Date?

    /// Whether audio is actually being captured. False means the engine is not
    /// running at all — the macOS microphone indicator goes out — rather than
    /// captured-and-discarded, which is the only honest meaning of "paused" for
    /// a microphone pointed at a room full of people.
    public private(set) var capturing = false
    public var onLog: (@Sendable (String) -> Void)?
    /// Fired when capture restarts, so latency can be measured from a fresh zero.
    public var onRebaseline: (@Sendable () -> Void)?

    /// Capture statistics, sampled by a poller rather than pushed from the tap.
    /// The tap runs on a real-time audio thread: doing file I/O there stalls
    /// Core Audio outright, which showed up as the tap firing exactly once.
    private let statsLock = NSLock()
    private var _tapCalls = 0        // callbacks the audio thread made
    private var _converted = 0       // of those, ones that produced samples
    private var _lastLevel = 0.0
    private var _lastError: String?
    /// Total audio duration handed to the analyzer, and the wall clock at which
    /// the most recent buffer was handed over. Together these convert the
    /// analyzer's audio clock into real time: audio only advances while we feed
    /// it, wall clock advances always, so a fixed start time drifts by exactly
    /// the amount of audio the speech gate dropped.
    private var _fedSeconds = 0.0
    private var _lastFedWall = Date()
    public var stats: (taps: Int, converted: Int, level: Double, error: String?) {
        statsLock.lock(); defer { statsLock.unlock() }
        return (_tapCalls, _converted, _lastLevel, _lastError)
    }

    /// Wall-clock instant at which the audio now at `audioTime` on the analyzer's
    /// clock was captured. Feeding is real time, so a sample at audio time T was
    /// handed over (fed − T) seconds before the most recent buffer.
    public func wallClock(forAudioTime t: Double) -> Date? {
        guard t.isFinite else { return nil }
        statsLock.lock(); defer { statsLock.unlock() }
        guard _fedSeconds > 0 else { return nil }
        let behind = _fedSeconds - t
        // A negative "behind" means the analyzer's clock is ahead of the audio we
        // believe we fed, which cannot happen physically — it means the two
        // clocks have different origins. Refuse rather than report a time in the
        // future, which surfaced as impossible negative latency.
        guard behind >= 0 else {
            _clockSkew = behind
            return nil
        }
        _clockSkew = 0
        return _lastFedWall.addingTimeInterval(-behind)
    }

    private var _clockSkew = 0.0
    /// Non-zero when the analyzer's audio clock disagrees with the fed audio.
    public var clockSkew: Double { statsLock.lock(); defer { statsLock.unlock() }; return _clockSkew }
    public var fedSeconds: Double { statsLock.lock(); defer { statsLock.unlock() }; return _fedSeconds }

    private let voiceProcessing: Bool

    private let chunkMS: Double
    private let deviceID: AudioDeviceID?

    public init(format: AVAudioFormat, chunkMS: Double = 50, voiceProcessing: Bool = false,
                deviceID: AudioDeviceID? = nil) {
        self.deviceID = deviceID
        self.voiceProcessing = voiceProcessing
        self.format = format
        self.chunkMS = chunkMS
        // Placeholder; the real size is computed against the hardware rate once
        // the input node reports it. Sizing this in the analyzer's 16 kHz asks
        // for a third of the intended window.
        self.chunkFrames = AVAudioFrameCount(format.sampleRate * chunkMS / 1000.0)
    }

    public var inputDeviceName: String {
        #if os(macOS)
        return engine.inputNode.auAudioUnit.deviceID.description
        #else
        return "input"
        #endif
    }

    /// Explicitly ask for microphone access so the prompt appears at a moment
    /// the user can act on, rather than the engine silently capturing nothing.
    public static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    public static var accessStatus: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not determined"
        @unknown default: return "unknown"
        }
    }

    public func start() throws -> AsyncStream<AnalyzerInput> {
        let input = engine.inputNode
        // Device selection must happen before anything reads the input format.
        if let deviceID {
            let took = (try? AudioDevices.setInput(deviceID, on: engine)) ?? false
            onLog?(took ? "input pinned to id \(deviceID)"
                        : "WARNING: could not pin input device — following the system default")
        }
        // Voice processing gives AEC + noise suppression from Apple's DSP, but
        // it renegotiates the input node's format and on this machine that can
        // leave the tap firing once and stalling. Off by default; measure with
        // it on before trusting it.
        if voiceProcessing {
            do { try input.setVoiceProcessingEnabled(true) }
            catch { onLog?("voice processing unavailable: \(error.localizedDescription)") }
        }

        let hwFormat = input.outputFormat(forBus: 0)
        onLog?("input format \(Int(hwFormat.sampleRate)) Hz x\(hwFormat.channelCount), analyzer wants \(Int(format.sampleRate)) Hz")
        guard hwFormat.sampleRate > 0 else {
            throw CaptionError.audio("input device reports no sample rate — is a microphone selected?")
        }
        guard let conv = AVAudioConverter(from: hwFormat, to: format) else {
            throw CaptionError.audio("cannot convert \(hwFormat) to analyzer format")
        }
        converter = conv

        let stream = AsyncStream(AnalyzerInput.self, bufferingPolicy: .unbounded) { cont in
            self.continuation = cont
        }

        installTap(hwFormat: hwFormat)

        // A headset connecting or disconnecting reconfigures the input node.
        // The old tap and converter are then built for a format the hardware no
        // longer produces, and capture dies silently — which is exactly what a
        // Bluetooth headset waking up mid-lecture would do to a demo.
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.onLog?("audio configuration changed — rebuilding capture")
            self.rebuild()
        }

        engine.prepare()
        onLog?("capture ready (paused), device \(currentInputName())")
        return stream
    }

    /// Installs (or re-installs) the capture tap for a given hardware format.
    /// Core Audio treats `bufferSize` as a request, not a guarantee — it has its
    /// own floor of about 96 ms on this Mac. Ask in hardware frames so we at
    /// least get the smallest window the device is willing to give.
    private func installTap(hwFormat: AVAudioFormat) {
        let input = engine.inputNode
        let tapFrames = AVAudioFrameCount(hwFormat.sampleRate * chunkMS / 1000.0)
        input.installTap(onBus: 0, bufferSize: tapFrames, format: hwFormat) { [weak self] buf, _ in
            guard let self, let conv = self.converter else { return }
            // Paused: drop anything the engine delivers while it winds down, so
            // no audio from a paused session can reach the recogniser.
            guard self.capturing else { return }
            // The configuration-change notification can arrive before the hardware
            // has settled, so the converter may have been rebuilt against the old
            // device's format. Feeding 48 kHz frames through a 16 kHz converter
            // makes the analyzer's audio clock run three times too fast, which
            // shows up as impossible negative latency rather than as an error.
            if buf.format.sampleRate != hwFormat.sampleRate {
                self.statsLock.lock(); self._lastError =
                    "format changed \(Int(hwFormat.sampleRate)) → \(Int(buf.format.sampleRate)) Hz"
                self.statsLock.unlock()
                DispatchQueue.main.async { [weak self] in self?.rebuild() }
                return
            }
            if self.startDate == nil { self.startDate = Date() }
            let capacity = AVAudioFrameCount(
                Double(buf.frameLength) * self.format.sampleRate / hwFormat.sampleRate) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: self.format, frameCapacity: capacity) else { return }

            var err: NSError?
            var served = false
            conv.convert(to: out, error: &err) { _, status in
                if served { status.pointee = .noDataNow; return nil }
                served = true; status.pointee = .haveData; return buf
            }

            self.statsLock.lock(); self._tapCalls += 1; self.statsLock.unlock()
            if let err {
                self.statsLock.lock(); self._lastError = err.localizedDescription; self.statsLock.unlock()
                return
            }
            guard out.frameLength > 0 else { return }

            var sum = 0.0
            if let d = out.int16ChannelData {
                for i in 0..<Int(out.frameLength) { let v = Double(d[0][i]) / 32768.0; sum += v * v }
            } else if let d = out.floatChannelData {
                for i in 0..<Int(out.frameLength) { sum += Double(d[0][i] * d[0][i]) }
            }
            let rms = (sum / Double(max(1, out.frameLength))).squareRoot()
            self.statsLock.lock()
            self._converted += 1
            self._lastLevel = max(self._lastLevel * 0.9, rms)
            self._fedSeconds += Double(out.frameLength) / self.format.sampleRate
            self._lastFedWall = Date()
            self.statsLock.unlock()
            self.continuation?.yield(AnalyzerInput(buffer: out))
        }
    }

    /// Begins capturing. The latency clock is re-anchored because the analyzer's
    /// audio clock does not advance while paused but wall clock does.
    public func resume() throws {
        guard !capturing else { return }
        if !engine.isRunning { try engine.start() }
        capturing = true
        startDate = nil
        // Do NOT reset _fedSeconds. The analyzer's audio clock also only advances
        // while we feed it, so the two stay aligned across a pause. Zeroing this
        // put them a whole pause apart and produced latencies like -169 s.
        statsLock.lock(); _lastFedWall = Date(); statsLock.unlock()
        onRebaseline?()
        onLog?("capturing")
    }

    public func pause() {
        guard capturing else { return }
        capturing = false
        engine.pause()
        onLog?("paused")
    }

    /// Re-attaches the tap after the hardware changed. Keeps the same output
    /// stream, so the analyzer never sees an interruption.
    private func rebuild() {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let hw = input.outputFormat(forBus: 0)
        guard hw.sampleRate > 0, let conv = AVAudioConverter(from: hw, to: format) else {
            onLog?("rebuild failed: input format is \(hw)")
            return
        }
        converter = conv
        installTap(hwFormat: hw)
        if capturing, !engine.isRunning { try? engine.start() }
        // The analyzer's audio clock keeps counting across a rebuild while wall
        // clock does not, so the latency baseline has to be re-anchored.
        onRebaseline?()
        onLog?("capture rebuilt at \(Int(hw.sampleRate)) Hz, device \(currentInputName())")
    }

    private func currentInputName() -> String { AudioDevices.engineInput(engine) }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
    }
}
