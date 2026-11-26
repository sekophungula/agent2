import AVFoundation
import FluidAudio
import Foundation

/// Kokoro-82M running on this Mac through FluidAudio (Apache 2.0).
/// The model (about 180 MB) downloads once to
/// ~/Library/Application Support/Agent2/Voice and is reused after that.
@MainActor
final class Kokoro: ObservableObject {
    static let shared = Kokoro()

    enum State: Equatable {
        case notInstalled, downloading, ready, failed(String)
    }

    /// Voices offered in Settings (Kokoro v1.0 names). The first is the default.
    static let voices: [(id: String, name: String)] = [
        ("af_heart", "Heart · US, warm"),
        ("af_bella", "Bella · US, bright"),
        ("am_michael", "Michael · US, calm"),
        ("am_adam", "Adam · US, deep"),
        ("bf_emma", "Emma · British"),
        ("bm_george", "George · British"),
    ]

    @Published private(set) var state: State = .notInstalled
    private var manager: KokoroAneManager?
    private var loadTask: Task<Void, Never>?

    /// Set once a download has finished, so later launches load from disk without asking.
    private var installed: Bool {
        get { UserDefaults.standard.bool(forKey: "kokoroInstalled") }
        set { UserDefaults.standard.set(newValue, forKey: "kokoroInstalled") }
    }

    var isReady: Bool { state == .ready }

    /// Load the model at launch if it was downloaded before.
    func loadIfInstalled() {
        if installed { prepare() }
    }

    /// Download (first time) and load the model. Safe to call repeatedly.
    func prepare() {
        guard loadTask == nil, state != .ready else { return }
        state = .downloading
        let voice = AppSettings.shared.kokoroVoice
        loadTask = Task {
            do {
                let m: KokoroAneManager
                if #available(macOS 15, *) {
                    m = KokoroAneManager(defaultVoice: voice, directory: Self.folder, version: .v3)
                } else {
                    m = KokoroAneManager(defaultVoice: voice, directory: Self.folder)
                }
                try await m.initialize(preloadVoices: [voice])
                // The first generation after loading is several times slower; do it now, silently.
                _ = try? await m.synthesizeDetailed(text: "Ready.", voice: voice)
                manager = m
                installed = true
                state = .ready
            } catch {
                state = .failed(Orchestrator.shortError(error.localizedDescription))
            }
            loadTask = nil
        }
    }

    /// 24 kHz mono samples for one piece of text.
    func synthesize(_ text: String, voice: String) async throws -> [Float] {
        guard let manager else { throw CancellationError() }
        return try await manager.synthesizeDetailed(text: text, voice: voice).samples
    }

    /// Delete the downloaded model.
    func remove() {
        loadTask?.cancel(); loadTask = nil
        manager = nil
        installed = false
        state = .notInstalled
        try? FileManager.default.removeItem(at: Self.folder)
    }

    static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Agent2/Voice", isDirectory: true)

    /// Size of the downloaded models on disk, for Settings.
    static func diskSize() -> Int64 {
        guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }
}

/// Plays Kokoro speech from a queue of sentences. Text can be added while
/// earlier sentences are playing: each is generated while the one before it plays,
/// so speech starts as soon as the first sentence of a reply exists.
@MainActor
final class KokoroPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    private var queue: [(text: String, voice: String)] = []
    private var worker: Task<Void, Never>?
    private var pending = 0
    private var generation = 0
    /// All queued speech has been played.
    var onFinish: () -> Void = {}
    /// Kokoro couldn't voice this text; the caller can use another voice for it.
    var onFailure: (String) -> Void = { _ in }

    var isBusy: Bool { worker != nil || pending > 0 }

    init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    func enqueue(_ text: String, voice: String) {
        queue += Self.sentences(text).map { ($0, voice) }
        guard worker == nil, !queue.isEmpty else { return }
        let gen = generation
        worker = Task { [weak self] in
            while let self, gen == self.generation, !self.queue.isEmpty {
                let next = self.queue.removeFirst()
                do {
                    let samples = try await Kokoro.shared.synthesize(next.text, voice: next.voice)
                    guard gen == self.generation, !Task.isCancelled else { return }
                    self.schedule(samples, gen: gen)
                } catch {
                    guard gen == self.generation, !Task.isCancelled else { return }
                    self.onFailure(next.text)
                }
            }
            guard let self, gen == self.generation else { return }
            self.worker = nil
            if self.pending == 0 { self.onFinish() }
        }
    }

    func stop() {
        generation += 1
        queue.removeAll()
        worker?.cancel(); worker = nil
        node.stop()
        pending = 0
    }

    private func schedule(_ samples: [Float], gen: Int) {
        guard !samples.isEmpty,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        if !engine.isRunning { try? engine.start() }
        pending += 1
        node.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                self.pending -= 1
                if self.pending == 0 && self.worker == nil { self.onFinish() }
            }
        }
        if !node.isPlaying { node.play() }
    }

    /// Splits text into sentences, merging very short ones so the voice keeps its flow.
    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { s, _, _, _ in
            guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return }
            if let last = out.last, last.count < 40 { out[out.count - 1] = last + " " + s } else { out.append(s) }
        }
        return out.isEmpty && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [text] : out
    }
}
