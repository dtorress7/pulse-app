import Foundation
import SwiftUI
import Speech
import AVFoundation

/// Dictado en español para el diario ("HABLAR", como WHOOP). Reconocimiento de Apple; pide permiso de micrófono y de voz.
final class SpeechInput: ObservableObject {
    @Published var text = ""
    @Published var listening = false
    @Published var error: String? = nil

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "es-ES"))

    func start() {
        error = nil
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                guard status == .authorized else {
                    self.error = "Para hablar, permite el reconocimiento de voz a PulseApp en Ajustes."
                    return
                }
                AVAudioSession.sharedInstance().requestRecordPermission { ok in
                    DispatchQueue.main.async {
                        if ok { self.begin() } else { self.error = "Para hablar, permite el micrófono a PulseApp en Ajustes." }
                    }
                }
            }
        }
    }

    private func begin() {
        guard let r = recognizer, r.isAvailable else {
            error = "El reconocimiento de voz no está disponible ahora mismo."
            return
        }
        stop()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            request = req
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in req.append(buffer) }
            engine.prepare()
            try engine.start()
            listening = true
            let base = text.isEmpty ? "" : text + " "
            task = r.recognitionTask(with: req) { [weak self] result, err in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if let result = result { self.text = base + result.bestTranscription.formattedString }
                    if err != nil || (result?.isFinal ?? false) { self.stop() }
                }
            }
        } catch {
            self.error = "No se pudo usar el micrófono."
            stop()
        }
    }

    func stop() {
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        request = nil
        task?.finish()
        task = nil
        if listening {
            listening = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    deinit { stop() }
}
