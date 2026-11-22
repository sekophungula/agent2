import AppKit
import AVFoundation
import Speech

/// Push-to-talk: hold Control+Option anywhere on the Mac, speak, let go.
/// A quick tap (no speech) just opens Agent2 for typing.
@MainActor
final class HotkeyMonitor {
    var onPress: () -> Void = {}
    var onRelease: (_ heldFor: TimeInterval) -> Void = { _ in }
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var pressedAt: Date?

    func start() {
        stop()
        let handler: (NSEvent) -> Void = { [weak self] e in self?.handle(e.modifierFlags) }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handler)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { e in handler(e); return e }
    }

    func stop() {
        if let g = globalMonitor { NSEvent.removeMonitor(g) }
        if let l = localMonitor { NSEvent.removeMonitor(l) }
        globalMonitor = nil; localMonitor = nil
    }

    private func handle(_ flags: NSEvent.ModifierFlags) {
        let relevant = flags.intersection([.control, .option, .command, .shift])
        let isCombo = relevant == [.control, .option]
        if isCombo, pressedAt == nil {
            pressedAt = Date()
            onPress()
        } else if !isCombo, let start = pressedAt {
            pressedAt = nil
            onRelease(Date().timeIntervalSince(start))
        }
    }

    /// Global key monitors need Accessibility access.
    static func ensureAccessibility(prompt: Bool) -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }
}

/// On-device speech-to-text with Apple's Speech framework (no audio leaves the Mac
/// when on-device recognition is available).
@MainActor
final class VoiceInput: ObservableObject {
    @Published var transcript = ""
    @Published var isListening = false
    @Published var level: Float = 0
    @Published var problem: String?

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer()

    func requestPermissions() async -> Bool {
        let speechOK = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        let micOK = await AVCaptureDevice.requestAccess(for: .audio)
        if !speechOK { problem = "Allow Speech Recognition for Agent2 in System Settings → Privacy & Security." }
        else if !micOK { problem = "Allow Microphone access for Agent2 in System Settings → Privacy & Security." }
        else { problem = nil }
        return speechOK && micOK
    }

    func start() {
        guard !isListening else { return }
        guard let recognizer, recognizer.isAvailable else { problem = "Speech recognition isn't available right now."; return }
        transcript = ""
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            req.append(buffer)
            guard let ch = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            let rms = sqrt(sum / Float(max(n, 1)))
            Task { @MainActor in self?.level = min(1, rms * 12) }
        }
        task = recognizer.recognitionTask(with: req) { [weak self] result, _ in
            guard let result else { return }
            let text = result.bestTranscription.formattedString
            Task { @MainActor in self?.transcript = text }
        }
        engine.prepare()
        do {
            try engine.start()
            isListening = true
            problem = nil
        } catch {
            problem = "Couldn't start the microphone: \(error.localizedDescription)"
            cleanup()
        }
    }

    /// Stops listening and returns what was heard once recognition settles.
    func stop() async -> String {
        guard isListening else { return transcript }
        request?.endAudio()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        isListening = false
        level = 0
        try? await Task.sleep(nanoseconds: 450_000_000)
        let text = transcript
        cleanup()
        return text
    }

    private func cleanup() {
        task?.cancel()
        task = nil
        request = nil
    }
}

/// Agent2's voice. Replies to voice requests are read aloud, like a person
/// answering you, so you never need to look at a window.
@MainActor
final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = Speaker()
    @Published private(set) var isSpeaking = false
    private let synth = AVSpeechSynthesizer()

    override init() {
        super.init()
        synth.delegate = self
    }

    func speak(_ text: String) {
        let clean = Speaker.spoken(text)
        guard !clean.isEmpty else { return }
        synth.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: clean)
        u.voice = Speaker.bestVoice
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        u.postUtteranceDelay = 0.05
        isSpeaking = true
        synth.speak(u)
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in if !self.synth.isSpeaking { self.isSpeaking = false } }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }

    /// The best installed voice for the person's language: Premium, then Enhanced, then default.
    /// Better voices can be downloaded in System Settings → Accessibility → Spoken Content.
    static var bestVoice: AVSpeechSynthesisVoice? {
        let lang = Locale.preferredLanguages.first ?? "en-US"
        let base = String(lang.prefix(2))
        let voices = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.hasPrefix(base) && !$0.identifier.contains("speech.synthesis") // skip novelty voices
        }
        func rank(_ v: AVSpeechSynthesisVoice) -> Int {
            (v.quality == .premium ? 300 : v.quality == .enhanced ? 200 : 100) + (v.language == lang ? 10 : 0)
        }
        return voices.max { rank($0) < rank($1) } ?? AVSpeechSynthesisVoice(language: lang)
    }

    /// Turns Markdown into something that sounds natural read aloud.
    static func spoken(_ text: String) -> String {
        var s = text
        let rules: [(String, String)] = [
            (#"```[\s\S]*?```"#, " "),                    // code blocks
            (#"`([^`]*)`"#, "$1"),                         // inline code
            (#"!?\[([^\]]*)\]\([^)]*\)"#, "$1"),           // links and images
            (#"https?://\S+"#, "the link"),
            (#"(?m)^\s{0,3}#{1,6}\s*"#, ""),               // headings
            (#"(?m)^\s*[-*+]\s+"#, ""),                    // bullets
            (#"(?m)^\s*\d+\.\s+"#, ""),                    // numbered lists
            (#"(?m)^\s*\|.*\|\s*$"#, ""),                  // table rows
            (#"[*_~>#|]"#, ""),
            (#"\n{2,}"#, ". "),
            (#"\s+"#, " "),
        ]
        for (pattern, template) in rules {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        s = s.replacingOccurrences(of: "⚠️", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > 700, let cut = s.prefix(700).lastIndex(where: { ".!?".contains($0) }) {
            s = String(s[...cut]) + " The rest is in the Agent2 window."
        }
        return s
    }
}
