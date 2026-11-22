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
