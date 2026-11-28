import AVFoundation
import Speech

/// Speech-to-text that keeps up with long speech (minutes, not seconds).
///
/// One `SFSpeechRecognitionTask` can't do this on its own:
/// - After each pause it starts its transcript over with only the new sentence,
///   so reading `formattedString` at the end gives you only the last thing said.
/// - Server-based recognition (used when the language has no on-device model)
///   stops after about a minute, and any task can end by itself after a long
///   pause. Audio sent after that is ignored.
///
/// This class keeps every sentence by where it falls in time (each result's word
/// timestamps), and runs a chain of recognition tasks over the same audio. It
/// starts a new task when one ends, and hands over to a fresh task every
/// `rotateAfter` seconds, but only during a pause so no sentence is split.
@MainActor
final class RollingTranscriber {
    /// Everything heard so far, across all recognition tasks.
    private(set) var text = ""
    var onUpdate: ((String) -> Void)?

    static let rotateAfter: TimeInterval = 40
    /// Hand over even mid-speech by now (server recognition stops at about 60s).
    static let rotateBy: TimeInterval = 55

    private let recognizer: SFSpeechRecognizer
    private var segments: [Segment] = []
    private var tasks: [SFSpeechRecognitionTask] = []
    private var current: SFSpeechAudioBufferRecognitionRequest?
    private var currentStarted = Date()
    private var running = false
    /// Tasks in a row that ended at once with nothing heard (stops a restart loop).
    private var quickFailures = 0
    private var rotationTimer: Timer?

    /// Shared with the audio thread, guarded by `lock`.
    nonisolated(unsafe) private var live: SFSpeechAudioBufferRecognitionRequest?
    nonisolated(unsafe) private var quietSince: Date?
    private let lock = NSLock()

    /// What one recognition task heard: sentences keyed by when they start (seconds
    /// into that task's audio), plus the newest words before they have timings.
    private struct Segment {
        /// In the order they were said. `kept` ones were heard without timings.
        var sentences: [(start: Double, end: Double, text: String, kept: Bool)] = []
        var untimed = ""
        var finished = false
        var full: String {
            (sentences.map(\.text) + [untimed]).filter { !$0.isEmpty }.joined(separator: " ")
        }

        static func words(_ s: String) -> [Substring] {
            s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
        }

        /// The untimed words are an earlier draft of `said` (most of them are in it).
        static func isDraft(_ untimed: String, of said: String) -> Bool {
            let draft = words(untimed), final = Set(words(said))
            guard !draft.isEmpty else { return true }
            return Double(draft.filter { final.contains($0) }.count) / Double(draft.count) >= 0.6
        }

        mutating func add(_ t: SFTranscription) {
            let words = t.segments
            let said = t.formattedString
            guard !said.isEmpty else { return }
            guard let first = words.first, let last = words.last, last.timestamp + last.duration > 0 else {
                untimed = said   // a new sentence's first words, timings still to come
                return
            }
            let start = first.timestamp, end = last.timestamp + last.duration
            // A newer version of a sentence we have (it overlaps in time): replace it in place.
            let overlapping = sentences.indices.filter {
                !sentences[$0].kept && sentences[$0].start < end && sentences[$0].end > start - 0.5
            }
            if let i = overlapping.first {
                sentences[i] = (start, end, said, false)
                for j in overlapping.dropFirst().reversed() { sentences.remove(at: j) }
                return
            }
            // A new sentence. Untimed words before it were either its start or a
            // sentence of their own that never got timings: keep the latter.
            if !untimed.isEmpty {
                if !Self.isDraft(untimed, of: said) { sentences.append((start, start, untimed, true)) }
                untimed = ""
            }
            let at = sentences.firstIndex { !$0.kept && $0.start > start } ?? sentences.endIndex
            sentences.insert((start, end, said, false), at: at)
        }
    }

    init(recognizer: SFSpeechRecognizer) {
        self.recognizer = recognizer
    }

    /// Starts listening. `preRoll` is audio from just before, so the first word isn't clipped.
    func start(preRoll: [AVAudioPCMBuffer] = []) {
        segments = []; tasks = []; text = ""
        quickFailures = 0
        running = true
        beginTask()
        for b in preRoll { current?.append(b) }
        rotationTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.rotateIfDue() }
        }
    }

    /// Feeds microphone audio. Safe to call from the audio thread.
    nonisolated func append(_ buffer: AVAudioPCMBuffer) {
        let quiet = Self.rms(buffer) < 0.008
        lock.lock()
        let req = live
        if !quiet { quietSince = nil } else if quietSince == nil { quietSince = Date() }
        lock.unlock()
        req?.append(buffer)
    }

    /// No more audio: waits (up to `timeout`) for every task to finish, then returns the text.
    func finish(timeout: TimeInterval) async -> String {
        guard running else { return text }
        running = false
        rotationTimer?.invalidate(); rotationTimer = nil
        setLive(nil)
        current?.endAudio()
        current = nil
        let deadline = Date().addingTimeInterval(timeout)
        while !segments.allSatisfy(\.finished), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        cancel()
        return text
    }

    /// Stops at once and drops what's still being recognised.
    func cancel() {
        running = false
        rotationTimer?.invalidate(); rotationTimer = nil
        setLive(nil)
        current = nil
        for t in tasks { t.cancel() }
        tasks = []
    }

    // MARK: - Tasks

    private func beginTask() {
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        req.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        let index = segments.count
        segments.append(Segment())
        current = req
        currentStarted = Date()
        setLive(req)
        let trace = ProcessInfo.processInfo.environment["AGENT2_TRACE_STT"] != nil
        let task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            let transcription = result?.bestTranscription
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            if trace, let t = transcription {
                print(String(format: "[task %d] final=%d t=%.1f: …%@", index, isFinal ? 1 : 0,
                             t.segments.first?.timestamp ?? -1, String(t.formattedString.suffix(50))))
            }
            Task { @MainActor in self?.update(index, transcription, isFinal: isFinal, failed: failed) }
        }
        tasks.append(task)
    }

    private func update(_ index: Int, _ t: SFTranscription?, isFinal: Bool, failed: Bool) {
        guard index < segments.count else { return }
        if let t { segments[index].add(t) }
        if isFinal || failed { segments[index].finished = true }
        text = segments.map(\.full).filter { !$0.isEmpty }.joined(separator: " ")
        onUpdate?(text)

        // The current task ended by itself (a long pause, a time limit or an error)
        // while we're still listening: carry on in a new one.
        if running, index == segments.count - 1, segments[index].finished {
            let empty = segments[index].full.isEmpty && Date().timeIntervalSince(currentStarted) < 1
            quickFailures = empty ? quickFailures + 1 : 0
            if quickFailures <= 3 { beginTask() }
        }
    }

    /// Hands over to a fresh task once this one is old, at a pause if possible.
    private func rotateIfDue() {
        guard running, let old = current else { return }
        let age = Date().timeIntervalSince(currentStarted)
        lock.lock(); let quiet = quietSince.map { Date().timeIntervalSince($0) } ?? 0; lock.unlock()
        guard age > Self.rotateBy || (age > Self.rotateAfter && quiet > 0.4) else { return }
        beginTask()
        old.endAudio()
    }

    private func setLive(_ req: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock(); live = req; lock.unlock()
    }

    nonisolated static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let ch = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += ch[i] * ch[i] }
        return sqrt(sum / Float(max(n, 1)))
    }
}
