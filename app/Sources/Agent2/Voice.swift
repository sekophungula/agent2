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
/// when on-device recognition is available). Copes with long dictation: see
/// `RollingTranscriber`. The audio is also saved while you talk, so if live
/// recognition hears nothing, Agent2 transcribes the recording instead.
@MainActor
final class VoiceInput: ObservableObject {
    @Published var transcript = ""
    @Published var isListening = false
    @Published var level: Float = 0
    @Published var problem: String?

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer()
    private var transcriber: RollingTranscriber?
    private var startedAt = Date()
    private var configObserver: NSObjectProtocol?
    /// The recording made while listening. Written on the audio thread.
    nonisolated(unsafe) private var recording: AVAudioFile?
    private var recordingURL: URL?

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
        Parakeet.shared.prepareIfChosen()
        transcript = ""
        let t = RollingTranscriber(recognizer: recognizer)
        t.onUpdate = { [weak self] text in self?.transcript = text }
        transcriber = t
        t.start()

        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            problem = "No microphone found. Check System Settings → Sound → Input."
            cleanup(); return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agent2-dictation-\(UUID().uuidString).caf")
        recording = try? AVAudioFile(forWriting: url, settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        recordingURL = recording == nil ? nil : url
        installTap(format: format)
        // Headphones plugged in or the input changed: the engine stops, so restart it.
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.restartAfterDeviceChange() }
        }
        engine.prepare()
        do {
            try engine.start()
            isListening = true
            startedAt = Date()
            problem = nil
        } catch {
            problem = "Couldn't start the microphone: \(error.localizedDescription)"
            engine.inputNode.removeTap(onBus: 0)
            cleanup()
        }
    }

    private func installTap(format: AVAudioFormat) {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let t = transcriber
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            t?.append(buffer)
            if let file = self?.recording, file.processingFormat == buffer.format { try? file.write(from: buffer) }
            guard let ch = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            let rms = sqrt(sum / Float(max(n, 1)))
            Task { @MainActor in self?.level = min(1, rms * 12) }
        }
    }

    private func restartAfterDeviceChange() {
        guard isListening else { return }
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }
        installTap(format: format)
        engine.prepare()
        try? engine.start()
    }

    /// Stops listening and returns what was heard once recognition settles.
    func stop() async -> String {
        guard isListening else { return transcript }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        isListening = false
        level = 0
        let talked = Date().timeIntervalSince(startedAt)
        recording = nil   // closes the file
        // Parakeet transcribes the whole recording in a fraction of a second, more
        // accurately than the live recognizer, which is then not waited for.
        if let url = recordingURL, let text = await Parakeet.shared.transcribe(file: url) {
            transcript = text
            cleanup()
            return text
        }
        // Longer dictation takes longer to settle: wait for the final words.
        var text = await transcriber?.finish(timeout: min(6, 1.5 + talked * 0.03)) ?? transcript
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, talked > 0.8, let url = recordingURL {
            text = await Self.transcribe(file: url, recognizer: recognizer)
        }
        transcript = text
        cleanup()
        return text
    }

    private func cleanup() {
        transcriber?.cancel()
        transcriber = nil
        recording = nil
        if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
        recordingURL = nil
    }

    /// Transcribes a saved recording (the fallback when live recognition heard nothing).
    static func transcribe(file url: URL, recognizer: SFSpeechRecognizer?) async -> String {
        guard let recognizer, recognizer.isAvailable else { return "" }
        let req = SFSpeechURLRecognitionRequest(url: url)
        req.shouldReportPartialResults = false
        req.taskHint = .dictation
        req.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        return await withCheckedContinuation { c in
            var done = false
            var task: SFSpeechRecognitionTask?
            let finish: (String) -> Void = { text in
                guard !done else { return }
                done = true
                c.resume(returning: text)
            }
            task = recognizer.recognitionTask(with: req) { result, error in
                if let result, result.isFinal { DispatchQueue.main.async { finish(result.bestTranscription.formattedString) } }
                else if error != nil { DispatchQueue.main.async { finish("") } }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { task?.cancel(); finish("") }
        }
    }
}

/// Agent2's voice. Replies to voice requests are read aloud, like a person
/// answering you, so you never need to look at a window.
@MainActor
final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = Speaker()
    @Published private(set) var isSpeaking = false
    /// What Agent2 said lately, so the microphone hearing it back through the
    /// speakers isn't mistaken for the person.
    private var said: [(Date, String)] = []
    static let echoMemory: TimeInterval = 60
    private let synth = AVSpeechSynthesizer()
    private let kokoro = KokoroPlayer()

    override init() {
        super.init()
        synth.delegate = self
        kokoro.onFinish = { [weak self] in
            guard let self else { return }
            if !self.synth.isSpeaking { self.isSpeaking = false }
        }
        kokoro.onFailure = { [weak self] text in self?.speakSystem(text) }
    }

    /// Reads a whole reply aloud, replacing anything already being said.
    func speak(_ text: String) {
        let clean = Speaker.spoken(text)
        guard !clean.isEmpty else { return }
        stop()
        enqueue(clean)
    }

    /// Adds text to what's being said, without interrupting it. Used to speak a
    /// reply sentence by sentence while the agent is still writing it.
    /// Dev tools only: told about every piece of text queued for speech.
    static var trace: ((String) -> Void)?

    func enqueue(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        Speaker.trace?(clean)
        remember(clean)
        isSpeaking = true
        let settings = AppSettings.shared
        // First spoken reply with Kokoro chosen: fetch it in the background and use
        // the macOS voice until it's ready.
        if settings.voiceEngine == .kokoro, Kokoro.shared.state == .notInstalled { Kokoro.shared.prepare() }
        // Don't switch voices halfway through a reply.
        if settings.voiceEngine == .kokoro, Kokoro.shared.isReady, !synth.isSpeaking {
            kokoro.enqueue(clean, voice: settings.kokoroVoice)
        } else if kokoro.isBusy {
            kokoro.enqueue(clean, voice: settings.kokoroVoice)
        } else {
            speakSystem(clean)
        }
    }

    private func speakSystem(_ clean: String) {
        let u = AVSpeechUtterance(string: clean)
        u.voice = Speaker.bestVoice
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        u.postUtteranceDelay = 0.05
        isSpeaking = true
        synth.speak(u)
    }

    func remember(_ text: String) {
        said.append((Date(), text))
        said.removeAll { Date().timeIntervalSince($0.0) > Self.echoMemory }
    }

    static func words(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
    }

    private var saidWords: Set<String> {
        Set(said.filter { Date().timeIntervalSince($0.0) < Self.echoMemory }.flatMap { Self.words($0.1) })
    }

    /// Words in `heard` that Agent2 didn't just say itself.
    func newWords(in heard: String) -> [String] {
        let mine = saidWords
        return Self.words(heard).filter { !mine.contains($0) }
    }

    /// `heard` is mostly Agent2's own recent speech picked up by the microphone.
    func isEcho(_ heard: String) -> Bool {
        let w = Self.words(heard)
        guard !w.isEmpty, !said.isEmpty else { return false }
        let fresh = newWords(in: heard).count
        return fresh < 2 || Double(fresh) / Double(w.count) < 0.4
    }

    /// Drops the start of `heard` while it repeats Agent2's own words (what the
    /// microphone caught of its voice just before the person cut in).
    func trimEcho(_ heard: String) -> String {
        let mine = saidWords
        let parts = heard.split(separator: " ", omittingEmptySubsequences: true)
        var i = 0
        while i < parts.count, let w = Self.words(String(parts[i])).first, mine.contains(w) { i += 1 }
        return i >= 2 && i < parts.count ? parts[i...].joined(separator: " ") : heard
    }

    func stop() {
        kokoro.stop()
        synth.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in if !self.synth.isSpeaking && !self.kokoro.isBusy { self.isSpeaking = false } }
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
    static func spoken(_ text: String, limit: Int? = 700) -> String {
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
        if let limit, s.count > limit, let cut = s.prefix(limit).lastIndex(where: { ".!?".contains($0) }) {
            s = String(s[...cut]) + " The rest is in the Agent2 window."
        }
        return s
    }
}

/// Turns a reply that arrives in pieces into speech, one finished sentence at a
/// time. Skips code blocks and `<delegate>` instructions meant for other agents,
/// and stops after about a minute of talking (the rest is in the window).
@MainActor
final class SpeechStream {
    private var buffer = ""
    private var spokenChars = 0
    private var capped = false
    private(set) var spokeAnything = false
    static let maxChars = 900

    func feed(_ piece: String) {
        buffer += piece
        drain(final: false)
    }

    /// The reply is complete: speak whatever is left.
    func finish() { drain(final: true) }

    private func drain(final: Bool) {
        guard !capped else { buffer = ""; return }
        // Drop finished code blocks and delegation blocks.
        for pattern in [#"```[\s\S]*?```"#, #"<delegate\b[\s\S]*?</delegate>"#, ScreenLook.markPattern] {
            buffer = buffer.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        // Text from an unfinished code block or <delegate> tag onward isn't speech
        // (at the end of the reply it's dropped). A trailing "<del…" may be a tag starting.
        var safeEnd = buffer.endIndex
        if let r = buffer.range(of: "```") { safeEnd = r.lowerBound }
        if let r = buffer.range(of: "<delegate"), r.lowerBound < safeEnd { safeEnd = r.lowerBound }
        // A [POINT:…] mark for the cursor, not for reading out (a trailing "[PO…" may be one starting).
        if let r = buffer.range(of: "[POINT"), r.lowerBound < safeEnd { safeEnd = r.lowerBound }
        if !final, let r = buffer.range(of: "[", options: .backwards), r.lowerBound < safeEnd,
           "[POINT".hasPrefix(String(buffer[r.lowerBound...])) {
            safeEnd = r.lowerBound
        }
        if !final, let r = buffer.range(of: "<", options: .backwards), r.lowerBound < safeEnd,
           "<delegate".hasPrefix(String(buffer[r.lowerBound...])) {
            safeEnd = r.lowerBound
        }
        let safe = buffer[..<safeEnd]
        // Speak up to the last sentence end (or line break) in the safe part.
        var cut = safe.startIndex
        if final {
            cut = safe.endIndex
        } else {
            var i = safe.startIndex
            while i < safe.endIndex {
                let c = safe[i]
                let next = safe.index(after: i)
                if c == "\n" || (".!?".contains(c) && (next == safe.endIndex ? false : safe[next].isWhitespace)) {
                    cut = next
                }
                i = next
            }
            // Nothing said yet and a long first sentence: start at a comma rather than wait.
            if cut == safe.startIndex, !spokeAnything, safe.count > 80,
               let r = safe.range(of: ", ", options: .backwards), safe.distance(from: safe.startIndex, to: r.lowerBound) > 30 {
                cut = r.upperBound
            }
        }
        guard cut > safe.startIndex else { if final { buffer = "" }; return }
        let chunk = String(safe[..<cut])
        buffer.removeSubrange(buffer.startIndex..<cut)
        if final { buffer = "" }
        let text = Speaker.spoken(chunk, limit: nil)
        guard !text.isEmpty, text.contains(where: { $0.isLetter || $0.isNumber }) else { return }
        spokenChars += text.count
        spokeAnything = true
        Speaker.shared.enqueue(text)
        if spokenChars > Self.maxChars {
            capped = true
            Speaker.shared.enqueue("The rest is in the Agent2 window.")
        }
    }
}
