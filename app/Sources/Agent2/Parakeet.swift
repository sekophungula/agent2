import AVFoundation
import FluidAudio
import Foundation

/// Speech-to-text with NVIDIA Parakeet (the Ultra post-training of TDT 0.6B v3),
/// running on this Mac's Neural Engine through FluidAudio. The same model the
/// best Mac dictation apps (OpenWhispr, Spokenly, VoiceInk) use: far more
/// accurate than Apple's recognizer with accents, names and long speech, and it
/// transcribes a minute of audio in about half a second.
///
/// Apple's recognizer still shows your words live while you talk (and is used
/// until Parakeet has downloaded). When you stop, Parakeet transcribes the
/// whole recording and its text is what gets sent.
///
/// Names Agent2 knows (people and projects from memory, your apps, Agent2's own
/// terms) are boosted with a small CTC keyword model, so they come out spelled
/// right.
@MainActor
final class Parakeet: ObservableObject {
    static let shared = Parakeet()

    enum State: Equatable { case notInstalled, downloading, ready, failed(String) }
    @Published private(set) var state: State = .notInstalled

    static let version: AsrModelVersion = .ultra
    /// One-time download, shown in Settings.
    static let downloadSize = "650 MB"

    private var asr: AsrManager?
    private var ctc: CtcModels?
    private var boost: VocabularyBoostingSession?
    private var loadTask: Task<Void, Never>?
    private var vocabularyTask: Task<Void, Never>?

    private var installed: Bool {
        get { UserDefaults.standard.bool(forKey: "parakeetInstalled") }
        set { UserDefaults.standard.set(newValue, forKey: "parakeetInstalled") }
    }

    var isReady: Bool { state == .ready }
    /// Names are being boosted (the keyword model has loaded).
    var boosting: Bool { boost != nil }
    /// Parakeet is chosen and ready to use.
    var active: Bool { AppSettings.shared.dictationEngine == .parakeet && isReady }

    /// At launch: load it if it was downloaded before.
    func loadIfInstalled() {
        if installed, AppSettings.shared.dictationEngine == .parakeet { prepare() }
    }

    /// Parakeet is chosen but not downloaded: fetch it in the background (Apple's
    /// recognizer is used until it's ready).
    func prepareIfChosen() {
        if AppSettings.shared.dictationEngine == .parakeet, state == .notInstalled { prepare() }
    }

    /// Download (first time) and load the models. Safe to call repeatedly.
    func prepare() {
        guard loadTask == nil, state != .ready else { return }
        state = .downloading
        loadTask = Task {
            do {
                let models = try await AsrModels.downloadAndLoad(version: Self.version)
                // One window at a time: running several copies of the encoder at once on the
                // Neural Engine fails on long recordings ("Failed to specialize the model").
                let manager = AsrManager(config: ASRConfig(parallelChunkConcurrency: 1))
                try await manager.loadModels(models)
                // The first run after loading is slower (Neural Engine warm-up): do it now.
                var st = TdtDecoderState.make()
                _ = try? await manager.transcribe([Float](repeating: 0, count: 16_000), decoderState: &st)
                asr = manager
                installed = true
                state = .ready
                refreshVocabulary()
            } catch {
                state = .failed(Orchestrator.shortError(error.localizedDescription))
            }
            loadTask = nil
        }
    }

    /// Deletes the downloaded models.
    func remove() {
        loadTask?.cancel(); loadTask = nil
        vocabularyTask?.cancel(); vocabularyTask = nil
        asr = nil; ctc = nil; boost = nil
        installed = false
        state = .notInstalled
        try? FileManager.default.removeItem(at: AsrModels.defaultCacheDirectory(for: Self.version))
        try? FileManager.default.removeItem(at: CtcModels.defaultCacheDirectory())
    }

    // MARK: - Transcribing

    /// Text for 16 kHz mono `samples`, or nil when Parakeet isn't in use or heard nothing.
    func transcribe(_ samples: [Float]) async -> String? {
        guard active, let asr, samples.count > 16_000 / 4 else { return nil }
        // Parakeet needs at least a second of audio: pad short commands with silence.
        let audio = samples.count < 16_000 ? samples + [Float](repeating: 0, count: 16_000 - samples.count) : samples
        let started = Date()
        do {
            var st = TdtDecoderState.make()
            let result = try await asr.transcribe(audio, decoderState: &st)
            var text = result.text
            if let boost, let timings = result.tokenTimings, !timings.isEmpty,
               let out = await boost.rescore(text: text, tokenTimings: timings, audioSamples: audio), out.wasModified {
                text = out.text
            }
            Self.trace?(String(format: "parakeet %.2fs audio in %.0f ms: %@", Double(samples.count) / 16_000,
                               Date().timeIntervalSince(started) * 1000, text))
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            Self.trace?("parakeet failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Text for a recorded audio file.
    func transcribe(file: URL) async -> String? {
        guard active, let samples = try? AudioConverter().resampleAudioFile(file) else { return nil }
        return await transcribe(samples)
    }

    /// Dev tools only.
    static var trace: ((String) -> Void)?

    // MARK: - Vocabulary

    /// Rebuilds the list of names to get right (after memory learns new ones).
    func refreshVocabulary() {
        guard isReady else { return }
        let terms = Self.vocabulary()
        vocabularyTask?.cancel()
        vocabularyTask = Task {
            do {
                if ctc == nil { ctc = try await CtcModels.downloadAndLoad() }
                guard let ctc, !Task.isCancelled else { return }
                let context = CustomVocabularyContext(terms: terms.map { CustomVocabularyTerm(text: $0) })
                boost = try await VocabularyBoostingSession(vocabulary: context, ctcModels: ctc)
                Self.trace?("vocabulary: \(terms.count) terms")
            } catch {
                // Boosting is extra: transcription works without it.
                Self.trace?("vocabulary unavailable: \(error.localizedDescription)")
            }
        }
    }

    /// Names worth spelling right: Agent2's own words, the people, projects, apps
    /// and places in memory, and the apps installed in /Applications.
    static func vocabulary() -> [String] {
        var terms = ["Agent2", "Shakatec", "Claude Code", "Codex", "Composio", "graphify", "Kokoro", "Parakeet",
                     "ChatGPT", "GitHub", "macOS", "Xcode", "TextEdit", "WhatsApp"]
        terms += HistoryMemory.shared.namedThings(kinds: ["person", "project", "app", "place"])
        if let apps = try? FileManager.default.contentsOfDirectory(atPath: "/Applications") {
            terms += apps.filter { $0.hasSuffix(".app") }.map { String($0.dropLast(4)) }
        }
        var seen = Set<String>()
        return terms
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { t in
                // Short, distinctive names only: not sentences, not everyday words.
                let words = t.split(separator: " ").count
                return t.count >= 3 && words <= 3 && !QuickCommandsCommonWords.contains(t.lowercased())
                    && seen.insert(t.lowercased()).inserted
            }
            .prefix(120).map { $0 }
    }
}

/// Everyday words that happen to be app names ("Notes", "Music"): boosting them
/// would only risk changing ordinary speech.
private let QuickCommandsCommonWords: Set<String> = [
    "notes", "music", "photos", "mail", "maps", "messages", "calendar", "reminders", "books", "news", "stocks",
    "home", "clock", "weather", "contacts", "preview", "podcasts", "tv", "freeform", "shortcuts", "passwords",
    "journal", "games", "utilities", "safari", "finder", "keynote", "pages", "numbers", "chess", "stickies",
]
