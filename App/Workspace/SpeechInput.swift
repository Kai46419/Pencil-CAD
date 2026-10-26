import AVFoundation
import Speech

/// Diktat für den KI-Assistenten: Mikrofon an, deutsche Spracherkennung (auf dem Gerät, wenn möglich),
/// der erkannte Text erscheint laufend im Eingabefeld.
@MainActor
final class SpeechInput: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var error: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "de-DE"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// Startet bzw. beendet das Diktat. text erhält den bisher erkannten Satz, finished den endgültigen.
    func toggle(text: @escaping (String) -> Void, finished: @escaping (String) -> Void) {
        if isRecording {
            stop()
        } else {
            Task { await start(text: text, finished: finished) }
        }
    }

    func stop() {
        guard isRecording else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func start(text: @escaping (String) -> Void, finished: @escaping (String) -> Void) async {
        error = nil
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized else {
            error = "Spracherkennung ist nicht erlaubt (Einstellungen › PencilCAD)."
            return
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            error = "Mikrofon ist nicht erlaubt (Einstellungen › PencilCAD)."
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            error = "Spracherkennung gerade nicht verfügbar."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
            // Fachwörter, die sonst falsch erkannt würden
            request.contextualStrings = ["Quader", "Zylinder", "Fase", "abrunden", "Bohrung", "extrudieren", "Millimeter"]
            self.request = request
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            engine.prepare()
            try engine.start()
            isRecording = true
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let result {
                        let spoken = result.bestTranscription.formattedString
                        text(spoken)
                        if result.isFinal {
                            self.stop()
                            finished(spoken)
                        }
                    }
                    if error != nil, self.isRecording {
                        self.stop()
                    }
                }
            }
        } catch {
            self.error = "Mikrofon konnte nicht starten."
            stop()
        }
    }
}
