import AppKit
import AVFoundation
import FluidAudio
import Speech

/// Hands-free conversation: once started, Agent2 keeps the microphone open,
/// notices when you start and stop talking (Silero voice activity detection via
/// FluidAudio, on this Mac), and sends each thing you say as soon as you pause.
///
/// Agent2 doesn't listen while it's speaking, so it never hears itself through
/// the speakers; tap ⌃⌥ or click the pill to cut it off. The conversation ends
/// when you tap ⌃⌥ again, say "goodbye", or stay quiet for a minute.
@MainActor
final class HandsFree: ObservableObject {
    static let shared = HandsFree()

    @Published private(set) var isOn = false
    /// You're talking right now.
    @Published private(set) var hearing = false
    @Published private(set) var level: Float = 0
    @Published private(set) var problem: String?

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var transcript = ""

    private var vad: VadManager?
    private var vadState = VadStreamState()
    private var chunks: AsyncStream<[Float]>.Continuation?
    private var vadWorker: Task<Void, Never>?
    /// Only touched on the audio thread once the tap is installed.
    nonisolated(unsafe) private var tapConverter: AVAudioConverter?
    private let vadFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var pending: [Float] = []
    /// The last ~0.6s of audio, so the start of what you say isn't clipped.
    private var preRoll: [AVAudioPCMBuffer] = []
    private var lastActivity = Date()
    private var idleTimer: Timer?
    private var mutedUntil = Date.distantPast

    static let idleLimit: TimeInterval = 60
    static let segmentation = VadSegmentationConfig(minSpeechDuration: 0.25, minSilenceDuration: 0.8, speechPadding: 0.1)

    // MARK: - On / off

    func toggle() {
        if isOn { end() } else { Task { await begin() } }
    }

    func begin() async {
        guard !isOn else { return }
        guard await permissionsOK() else { return }
        do {
            if vad == nil { vad = try await VadManager(config: VadConfig(defaultThreshold: 0.7)) }
        } catch {
            problem = "Couldn't load speech detection: \(error.localizedDescription)"
            Speaker.shared.speak("I couldn't start hands-free listening. Try again in a moment.")
            return
        }
        if let vad { vadState = await vad.makeStreamState() }
        pending = []; preRoll = []
        startVADWorker()

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        tapConverter = AVAudioConverter(from: format, to: vadFormat)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            let rms = Self.rms(buffer)
            let mono16k = self?.resample(buffer) ?? []
            Task { @MainActor in self?.receive(buffer, mono16k: mono16k, rms: rms) }
        }
        engine.prepare()
        do { try engine.start() } catch {
            problem = "Couldn't start the microphone: \(error.localizedDescription)"
            input.removeTap(onBus: 0)
            return
        }
        isOn = true
        problem = nil
        lastActivity = Date()
        NSSound(named: "Tink")?.play()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in
                let c = HandsFree.shared
                if c.isOn, !c.hearing, !Speaker.shared.isSpeaking, !Orchestrator.shared.isWorking,
                   Date().timeIntervalSince(c.lastActivity) > Self.idleLimit { c.end() }
            }
        }
    }

    func end() {
        guard isOn else { return }
        isOn = false
        hearing = false
        level = 0
        idleTimer?.invalidate(); idleTimer = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        chunks?.finish(); chunks = nil
        vadWorker?.cancel(); vadWorker = nil
        task?.cancel(); task = nil; request = nil
        NSSound(named: "Pop")?.play()
    }

    // MARK: - Audio in

    /// Agent2 is talking (or just finished): don't treat the speakers as the person.
    private var agentTalking: Bool {
        Speaker.shared.isSpeaking || Date() < mutedUntil
    }

    private func receive(_ buffer: AVAudioPCMBuffer, mono16k: [Float], rms: Float) {
        guard isOn else { return }
        if Speaker.shared.isSpeaking { mutedUntil = Date().addingTimeInterval(0.6) }
        level = agentTalking ? 0 : min(1, rms * 12)
        preRoll.append(buffer)
        let keep = Int(0.6 * buffer.format.sampleRate / Double(max(buffer.frameLength, 1))) + 1
        if preRoll.count > keep { preRoll.removeFirst(preRoll.count - keep) }
        request?.append(buffer)
        guard !agentTalking else {
            // Keep the detector's state fresh but ignore what it hears.
            pending = []
            if hearing { cancelUtterance() }
            return
        }
        pending += mono16k
        while pending.count >= VadManager.chunkSize {
            chunks?.yield(Array(pending.prefix(VadManager.chunkSize)))
            pending.removeFirst(VadManager.chunkSize)
        }
    }

    private func startVADWorker() {
        let (stream, cont) = AsyncStream<[Float]>.makeStream()
        chunks = cont
        vadWorker = Task { [weak self] in
            for await chunk in stream {
                guard let self, let vad = self.vad else { return }
                guard let result = try? await vad.processStreamingChunk(chunk, state: self.vadState, config: Self.segmentation)
                else { continue }
                self.vadState = result.state
                if let event = result.event {
                    event.isStart ? self.speechStarted() : self.speechEnded()
                }
            }
        }
    }

    // MARK: - Turns

    private func speechStarted() {
        Self.trace?("speech started")
        guard isOn, !hearing, !agentTalking, let recognizer, recognizer.isAvailable else { return }
        hearing = true
        lastActivity = Date()
        transcript = ""
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        for b in preRoll { req.append(b) }
        request = req
        task = recognizer.recognitionTask(with: req) { [weak self] result, _ in
            guard let text = result?.bestTranscription.formattedString else { return }
            Task { @MainActor in self?.transcript = text }
        }
    }

    private func speechEnded() {
        Self.trace?("speech ended")
        guard hearing else { return }
        hearing = false
        lastActivity = Date()
        request?.endAudio()
        let req = request
        Task {
            try? await Task.sleep(for: .milliseconds(450))   // let recognition settle
            guard req === self.request else { return }
            let text = self.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            self.task?.cancel(); self.task = nil; self.request = nil
            self.handle(text)
        }
    }

    private func cancelUtterance() {
        hearing = false
        task?.cancel(); task = nil; request = nil
    }

    /// Dev tools only: receives events and each utterance instead of sending it.
    static var trace: ((String) -> Void)?

    private func handle(_ text: String) {
        if let trace = Self.trace { trace("heard: \(text)"); return }
        let words = text.lowercased().trimmingCharacters(in: .punctuationCharacters)
        guard words.count >= 2 else { return }   // a cough or "um"
        let orchestrator = Orchestrator.shared
        if ["goodbye", "bye", "bye bye", "that's all", "end conversation", "stop listening"].contains(words) {
            Speaker.shared.speak("Okay, talk soon.")
            end()
            return
        }
        if ["stop", "cancel", "never mind", "nevermind"].contains(words) {
            if orchestrator.isWorking { orchestrator.stop(); Speaker.shared.speak("Stopped.") }
            return
        }
        NSSound(named: "Pop")?.play()
        orchestrator.send(text, spoken: true)
    }

    // MARK: - Helpers

    private func permissionsOK() async -> Bool {
        let speechOK = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        let micOK = await AVCaptureDevice.requestAccess(for: .audio)
        if !speechOK || !micOK {
            problem = "Allow Microphone and Speech Recognition for Agent2 in System Settings → Privacy & Security."
            return false
        }
        return true
    }

    nonisolated private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let ch = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += ch[i] * ch[i] }
        return sqrt(sum / Float(max(n, 1)))
    }

    /// Mic audio → 16 kHz mono for the detector. Runs on the audio thread.
    nonisolated private func resample(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let conv = tapConverter else { return [] }
        let target = conv.outputFormat
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / buffer.format.sampleRate) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard err == nil, let ch = out.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
    }
}
