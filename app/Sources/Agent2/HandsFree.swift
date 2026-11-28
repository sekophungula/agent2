import AppKit
import AVFoundation
import FluidAudio
import Speech

/// Hands-free conversation: once started, Agent2 keeps the microphone open,
/// notices when you start and stop talking (Silero voice activity detection via
/// FluidAudio, on this Mac), and sends each thing you say as soon as you pause.
///
/// You can talk over Agent2: it keeps listening while it speaks, learns how loud
/// its own voice is at the microphone, and when you speak clearly over that it
/// stops talking and listens. The request it was working on carries on, and what
/// you said is handled right after (see `Orchestrator.send`). Tapping ⌃⌥ also
/// cuts it off. The conversation ends
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
    private var transcriber: RollingTranscriber?

    private var vad: VadManager?
    private var vadState = VadStreamState()
    private var chunks: AsyncStream<[Float]>.Continuation?
    private var vadWorker: Task<Void, Never>?
    /// Only touched on the audio thread once the tap is installed.
    nonisolated(unsafe) private var tapConverter: AVAudioConverter?
    private let vadFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var pending: [Float] = []
    /// The last second of audio, so the start of what you say isn't clipped.
    private var preRoll: [AVAudioPCMBuffer] = []
    /// The same second at 16 kHz, and everything heard since the utterance began
    /// (what Parakeet transcribes).
    private var preRoll16k: [[Float]] = []
    private var utterance16k: [Float] = []
    private var lastActivity = Date()
    private var idleTimer: Timer?
    private var mutedUntil = Date.distantPast
    /// The detector currently hears speech (yours or Agent2's own, from the speakers).
    private var vadSpeaking = false
    /// How loud Agent2's own voice is at the microphone. Rises slowly, so you
    /// starting to talk stands out against it.
    private var echoLevel: Float = 0
    /// How long you've been clearly louder than Agent2's voice (seconds).
    private var overTalk: TimeInterval = 0
    /// When Agent2 started its current stretch of speech (nil when it's quiet).
    private var agentSpeechStarted: Date?
    /// The utterance being heard is really the person. False while a possible
    /// interruption is checked: Agent2 only stops talking once the words heard
    /// include some it didn't just say itself.
    private var confirmed = true
    /// The utterance began while Agent2 was talking (or just after), so it may
    /// contain Agent2's own voice.
    private var overlapped = false
    static let bargeInAfter: TimeInterval = 0.5
    /// What's been heard so far in this utterance.
    private var heardSoFar = ""
    /// Last time the microphone heard something louder than room noise.
    private var lastLoud = Date.distantPast
    /// When an utterance was ended early because it was a complete quick command.
    private var endedEarly = Date.distantPast
    /// A quick command ("open Safari") is acted on after this much quiet,
    /// instead of the longer pause allowed for thinking mid-sentence.
    static let commandPause: TimeInterval = 0.6
    /// Agent2's voice level at the mic is learned over this long before
    /// anything can count as talking over it.
    static let echoWarmup: TimeInterval = 1.0

    static let idleLimit: TimeInterval = 60
    /// How long you can pause mid-thought before Agent2 takes it as the end of
    /// what you're saying. Short pauses while thinking out loud shouldn't cut you off.
    static let segmentation = VadSegmentationConfig(minSpeechDuration: 0.25, minSilenceDuration: 1.6, speechPadding: 0.1)

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
        pending = []; preRoll = []; preRoll16k = []; utterance16k = []
        Parakeet.shared.prepareIfChosen()
        vadSpeaking = false; echoLevel = 0; overTalk = 0
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
        transcriber?.cancel(); transcriber = nil
        NSSound(named: "Pop")?.play()
    }

    // MARK: - Audio in

    /// Agent2 is talking (or just finished): don't treat the speakers as the person.
    private var agentTalking: Bool {
        Speaker.shared.isSpeaking || Date() < mutedUntil
    }

    private func receive(_ buffer: AVAudioPCMBuffer, mono16k: [Float], rms: Float) {
        guard isOn else { return }
        let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
        if Speaker.shared.isSpeaking {
            if agentSpeechStarted == nil { agentSpeechStarted = Date() }
            if hearing {
                // A reply started while you were still talking: you have the floor.
                if confirmed { Orchestrator.shared.interrupted() }
            } else {
                mutedUntil = Date().addingTimeInterval(0.8)
            }
        } else if !agentTalking {
            agentSpeechStarted = nil
        }
        preRoll.append(buffer)
        let keep = Int(1.0 * buffer.format.sampleRate / Double(max(buffer.frameLength, 1))) + 1
        if preRoll.count > keep { preRoll.removeFirst(preRoll.count - keep) }
        preRoll16k.append(mono16k)
        if preRoll16k.count > keep { preRoll16k.removeFirst(preRoll16k.count - keep) }
        transcriber?.append(buffer)
        if transcriber != nil { utterance16k += mono16k }

        if rms > 0.01 { lastLoud = Date() }
        if hearing, confirmed, AppSettings.shared.instantCommands,
           Date().timeIntervalSince(lastLoud) > Self.commandPause, QuickCommands.match(heardSoFar) != nil {
            Self.trace?("quick command: \(heardSoFar)")
            endedEarly = Date()
            speechEnded()
        } else if !hearing, vadSpeaking, !agentTalking, rms > 0.02, Date().timeIntervalSince(endedEarly) < 4 {
            // They kept talking after a quick command was taken: hear the rest too.
            beginUtterance()
        }
        if agentTalking && !hearing {
            level = 0
            // Agent2's voice at the mic: follow it up quickly, down slowly, so its
            // loud syllables set the bar.
            echoLevel += (rms - echoLevel) * (rms > echoLevel ? 0.3 : 0.01)
            let warmedUp = Date().timeIntervalSince(agentSpeechStarted ?? .distantPast) > Self.echoWarmup
            let loudEnough = warmedUp && rms > max(0.02, echoLevel * 2.5)
            if vadSpeaking && loudEnough { overTalk += seconds } else { overTalk = max(0, overTalk - seconds * 0.5) }
            if overTalk >= Self.bargeInAfter { bargeIn() }
        } else {
            level = min(1, rms * 12)
            overTalk = 0
            if !agentTalking { echoLevel *= 0.9 }
        }
        pending += mono16k
        while pending.count >= VadManager.chunkSize {
            chunks?.yield(Array(pending.prefix(VadManager.chunkSize)))
            pending.removeFirst(VadManager.chunkSize)
        }
    }

    /// Something loud over Agent2's voice: start listening (from just before it
    /// started). Agent2 only goes quiet once the words show it's really you, not
    /// its own voice coming back through the speakers.
    private func bargeIn() {
        Self.trace?("maybe barge in")
        overTalk = 0
        beginUtterance(confirmed: false)
        transcriber?.onUpdate = { [weak self] text in
            self?.heardSoFar = text
            guard let self, !self.confirmed, Speaker.shared.newWords(in: text).count >= 2 else { return }
            Self.trace?("barge in: \(text)")
            self.confirmed = true
            self.mutedUntil = .distantPast
            Orchestrator.shared.interrupted()
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
        vadSpeaking = true
        // While Agent2 is talking this is usually its own voice: `receive` decides
        // whether it's really you talking over it.
        guard isOn, !hearing, !agentTalking else { return }
        beginUtterance()
    }

    private func beginUtterance(confirmed: Bool = true) {
        guard isOn, !hearing, let recognizer, recognizer.isAvailable else { return }
        overlapped = !confirmed || agentTalking || Speaker.shared.isSpeaking
        hearing = true
        PointerTrail.shared.mark()
        self.confirmed = confirmed
        lastActivity = Date()
        heardSoFar = ""
        utterance16k = preRoll16k.flatMap { $0 }
        let t = RollingTranscriber(recognizer: recognizer)
        transcriber = t
        t.onUpdate = { [weak self] text in self?.heardSoFar = text }
        t.start(preRoll: preRoll)
    }

    private func speechEnded() {
        Self.trace?("speech ended")
        // Ended early for a quick command: the detector still hears speech.
        if Date().timeIntervalSince(endedEarly) > 0.1 { vadSpeaking = false }
        guard hearing else { return }
        hearing = false
        lastActivity = Date()
        guard let t = transcriber else { return }
        transcriber = nil
        let wasConfirmed = confirmed, overlapped = overlapped
        let audio = utterance16k
        utterance16k = []
        confirmed = true
        Task {
            let text: String
            if let heard = await Parakeet.shared.transcribe(audio) {
                // Parakeet heard it all: no need to wait for the live recognizer to settle.
                t.cancel()
                text = heard
            } else {
                text = await t.finish(timeout: 2.5).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            self.handle(text, overlapped: overlapped, interrupting: !wasConfirmed)
        }
    }

    /// Dev tools only: receives events and each utterance instead of sending it.
    static var trace: ((String) -> Void)?

    private func handle(_ heard: String, overlapped: Bool = false, interrupting: Bool = false) {
        let speaker = Speaker.shared
        let lower = heard.lowercased().trimmingCharacters(in: .punctuationCharacters)
        let command = ["stop", "cancel", "never mind", "nevermind", "goodbye", "bye", "bye bye"].contains(lower)
        // Agent2's own voice, heard back through the speakers: never send it.
        if overlapped, !command, speaker.isEcho(heard) {
            Self.trace?("echo dropped: \(heard)")
            return
        }
        let text = overlapped ? speaker.trimEcho(heard) : heard
        if let trace = Self.trace { trace("heard: \(text)"); return }
        let words = text.lowercased().trimmingCharacters(in: .punctuationCharacters)
        guard words.count >= 2 else { return }   // a cough or "um"
        let orchestrator = Orchestrator.shared
        // A real interruption that was confirmed only once it ended.
        if interrupting, speaker.isSpeaking { orchestrator.interrupted() }
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
