import AppKit
import AVFoundation
import Carbon
import Speech

enum VoiceInputShortcut {
    static func matches(_ key: Int, flags: InputHook.Flags, mouseMode: Bool) -> Bool {
        key == kVK_ANSI_V && (mouseMode || flags.fnc)
            && !flags.ctrl && !flags.shift && !flags.opt && !flags.cmd
    }
}

@available(macOS 26.0, *)
@MainActor
final class VoiceInput: NSObject, AVAudioRecorderDelegate {
    private struct Target {
        let pid: pid_t
        let window: AXUIElement?
        let element: AXUIElement?

        init?(pid: pid_t?) {
            guard let pid, pid != getpid(), !IsSecureEventInputEnabled() else { return nil }
            self.pid = pid
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.15)
            window = Self.focused(app, kAXFocusedWindowAttribute)
            element = Self.focused(app, kAXFocusedUIElementAttribute)
        }

        var isCurrent: Bool {
            guard let current = Target(pid: NSWorkspace.shared.frontmostApplication?.processIdentifier),
                current.pid == pid else { return false }
            if let window, current.window.map({ CFEqual(window, $0) }) != true { return false }
            if let element, current.element.map({ CFEqual(element, $0) }) != true { return false }
            return true
        }

        private static func focused(_ app: AXUIElement, _ attribute: String) -> AXUIElement? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, attribute as CFString, &value) == .success,
                let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
    }

    private enum Failure: Error {
        case microphone, model, noSpeech
    }

    enum Status {
        case idle, preparing, recording, recognizing, microphone, targetChanged, model, noSpeech, failed
    }

    private var recorder: AVAudioRecorder?
    private var audioFile: URL?
    private var target: Target?
    private var task: Task<Void, Never>?
    private var preparation: Task<DictationTranscriber, Error>?
    private var generation = 0
    private let update: (Status) -> Void
    private let insert: (String) -> Void

    init(update: @escaping (Status) -> Void, insert: @escaping (String) -> Void) {
        self.update = update
        self.insert = insert
    }

    var isActive: Bool { target != nil }

    func toggle(frontmostPID: pid_t?) {
        if let recorder {
            finish(recorder, succeeded: true)
            return
        }
        guard !isActive else { return }
        guard let target = Target(pid: frontmostPID)
            else { update(.targetChanged); return }
        self.target = target
        let run = generation
        update(.preparing)
        task = Task { [weak self] in
            let granted: Bool
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: granted = true
            case .notDetermined: granted = await AVCaptureDevice.requestAccess(for: .audio)
            default: granted = false
            }
            guard let self, self.generation == run else { return }
            self.task = nil
            guard granted else { self.cancel(status: .microphone); return }
            guard target.isCurrent else { self.cancel(status: .targetChanged); return }
            self.record()
        }
    }

    func cancel(status: Status = .idle) {
        generation += 1
        task?.cancel()
        task = nil
        preparation?.cancel()
        preparation = nil
        recorder?.delegate = nil
        recorder?.stop()
        recorder = nil
        if let audioFile { try? FileManager.default.removeItem(at: audioFile) }
        audioFile = nil
        target = nil
        update(status)
    }

    private func record() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        audioFile = file
        do {
            let recorder = try AVAudioRecorder(url: file, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48_000,
            ])
            recorder.delegate = self
            self.recorder = recorder
            guard recorder.record(forDuration: 60) else { throw Failure.microphone }
            update(.recording)
            // Talkerと同じ日本語モデルを録音中に確認・準備しておく。
            preparation = Task {
                guard let locale = await DictationTranscriber.supportedLocale(
                    equivalentTo: Locale(identifier: "ja-JP")) else { throw Failure.model }
                let transcriber = DictationTranscriber(locale: locale, preset: .longDictation)
                if await AssetInventory.status(forModules: [transcriber]) != .installed {
                    if let request = try await AssetInventory.assetInstallationRequest(
                        supporting: [transcriber]) {
                        try await request.downloadAndInstall()
                    }
                    guard await AssetInventory.status(forModules: [transcriber]) == .installed
                        else { throw Failure.model }
                }
                return transcriber
            }
        } catch {
            cancel(status: .microphone)
        }
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder,
        successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.finish(recorder, succeeded: flag) }
    }

    private func finish(_ recorder: AVAudioRecorder, succeeded: Bool) {
        guard self.recorder === recorder, let audioFile, let preparation, let target else { return }
        self.recorder = nil
        recorder.delegate = nil
        recorder.stop()
        guard succeeded else { cancel(status: .microphone); return }
        guard target.isCurrent else { cancel(status: .targetChanged); return }
        let run = generation
        update(.recognizing)
        task = Task { [weak self] in
            do {
                let transcriber = try await preparation.value
                try Task.checkCancellation()
                let text = try await Self.transcribe(audioFile, using: transcriber)
                guard let self, self.generation == run else { return }
                guard target.isCurrent else { self.cancel(status: .targetChanged); return }
                self.insert(text)
                self.cancel()
            } catch {
                guard let self, self.generation == run else { return }
                switch error {
                case Failure.model: self.cancel(status: .model)
                case Failure.noSpeech: self.cancel(status: .noSpeech)
                default: self.cancel(status: .failed)
                }
            }
        }
    }

    private static func transcribe(_ url: URL, using transcriber: DictationTranscriber)
        async throws -> String {
        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        guard duration.isFinite, duration > 0, duration <= 64 else { throw Failure.noSpeech }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        async let text: String = finalText(transcriber)
        do {
            guard let end = try await analyzer.analyzeSequence(from: file) else {
                throw Failure.noSpeech
            }
            try await analyzer.finalizeAndFinish(through: end)
            let result = try await text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !result.isEmpty else { throw Failure.noSpeech }
            return result
        } catch {
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    private static func finalText(_ transcriber: DictationTranscriber) async throws -> String {
        var result = ""
        for try await part in transcriber.results where part.isFinal {
            result.append(contentsOf: part.text.characters)
        }
        return result
    }
}
