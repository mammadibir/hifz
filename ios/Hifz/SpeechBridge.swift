import AVFoundation
import Speech
import UIKit
import WebKit

struct BridgeError: Error {
    let code: String
    init(_ code: String) { self.code = code }
}

/// Speech recognition for the page, shown to it as `window.SpeechRecognition` (see BridgeScript).
/// Apple gives web apps on the Home Screen no speech recognition, so the app does it with SFSpeechRecognizer
/// and reports results the way the Web Speech API does: the parts already finished plus the part still being heard.
final class SpeechBridge: NSObject {
    weak var webView: WKWebView?

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?

    // The microphone tap runs on an audio thread, so the current request is guarded by a lock.
    private let lock = NSLock()
    private var currentRequest: SFSpeechAudioBufferRecognitionRequest?
    private var request: SFSpeechAudioBufferRecognitionRequest? {
        get { lock.lock(); defer { lock.unlock() }; return currentRequest }
        set { lock.lock(); currentRequest = newValue; lock.unlock() }
    }

    private var sessionId = 0
    private var active = false
    private var context: [String] = []
    private var finals: [String] = []
    private var partial = ""
    private var quickFailures = 0
    private var taskStarted = Date()
    private var tapInstalled = false
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let self = self, self.active,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            self.finish(error: "aborted")
        })
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.restartAudio()
        })
        observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.active else { return }
            self.finish(error: "audio-capture")
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Calls from the page

    func start(id: Int, lang: String, context: [String]) {
        if active { teardown() }
        sessionId = id
        self.context = context
        requestPermissions { [weak self] error in
            guard let self = self, self.sessionId == id else { return }
            if let error = error {
                self.sessionId = 0
                self.emit(id, "error", ["error": error])
                self.emit(id, "end", [:])
                return
            }
            do {
                try self.begin(lang: lang)
                self.emit(id, "start", [:])
            } catch let e as BridgeError {
                self.finish(error: e.code)
            } catch {
                self.finish(error: "audio-capture")
            }
        }
    }

    func stop(id: Int) {
        guard id == sessionId else { return }
        if active {
            // Deliver what was heard as final, then end, like the Web Speech API
            if !partial.isEmpty { finals.append(partial); partial = "" }
            emitResults()
        }
        finish(error: nil)
    }

    func abort(id: Int) {
        guard id == sessionId else { return }
        finish(error: nil)
    }

    // MARK: - Recognition

    private func requestPermissions(_ done: @escaping (String?) -> Void) {
        let askMicrophone: () -> Void = {
            let answer: (Bool) -> Void = { granted in
                DispatchQueue.main.async { done(granted ? nil : "not-allowed") }
            }
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission(completionHandler: answer)
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission(answer)
            }
        }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            askMicrophone()
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { status in
                DispatchQueue.main.async {
                    if status == .authorized { askMicrophone() } else { done("not-allowed") }
                }
            }
        default:
            done("not-allowed")
        }
    }

    private func begin(lang: String) throws {
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: lang)) else { throw BridgeError("language-not-supported") }
        guard rec.isAvailable else { throw BridgeError("network") }
        recognizer = rec
        try AudioSessionManager.shared.activateForRecording()
        finals = []
        partial = ""
        quickFailures = 0
        try startEngine()
        active = true
        startTask()
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw BridgeError("audio-capture") }
        if tapInstalled { input.removeTap(onBus: 0) }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
    }

    private func startTask() {
        guard active, let rec = recognizer else { return }
        task?.cancel()
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        if #available(iOS 16.0, *) { req.addsPunctuation = false }
        if !context.isEmpty { req.contextualStrings = Array(context.prefix(100)) }
        request = req
        taskStarted = Date()
        let id = sessionId
        task = rec.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                self?.handle(id: id, req: req, result: result, error: error)
            }
        }
    }

    private func handle(id: Int, req: SFSpeechAudioBufferRecognitionRequest, result: SFSpeechRecognitionResult?, error: Error?) {
        guard active, id == sessionId, req === request else { return }
        if let result = result {
            quickFailures = 0
            partial = result.bestTranscription.formattedString
            emitResults()
            if result.isFinal { rollOver(); return }
        }
        if error != nil {
            // A task that fails right after starting again and again means no network or no service
            if Date().timeIntervalSince(taskStarted) < 1.5 { quickFailures += 1 } else { quickFailures = 0 }
            if quickFailures >= 4 { finish(error: "network"); return }
            rollOver()
        }
    }

    /// A recognition task ends after a pause or after about a minute. Keep what it heard and go on with a new task
    /// while the microphone keeps running, so the page sees one continuous session.
    private func rollOver() {
        if !partial.isEmpty { finals.append(partial); partial = "" }
        request?.endAudio()
        startTask()
    }

    private func restartAudio() {
        guard active else { return }
        engine.stop()
        do { try startEngine() } catch { finish(error: "audio-capture") }
    }

    private func finish(error: String?) {
        let id = sessionId
        teardown()
        sessionId = 0
        guard id != 0 else { return }
        if let error = error { emit(id, "error", ["error": error]) }
        emit(id, "end", [:])
    }

    private func teardown() {
        let wasActive = active
        active = false
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        if engine.isRunning { engine.stop() }
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        recognizer = nil
        if wasActive { AudioSessionManager.shared.finishRecording() }
    }

    // MARK: - Page events

    private func emitResults() {
        var list: [[String: Any]] = finals.map { ["t": $0, "f": true] }
        if !partial.isEmpty { list.append(["t": partial, "f": false]) }
        emit(sessionId, "result", ["results": list])
    }

    private func emit(_ id: Int, _ kind: String, _ data: [String: Any]) {
        guard let webView = webView,
              let json = try? JSONSerialization.data(withJSONObject: data),
              let payload = String(data: json, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__hifzSR && window.__hifzSR(\(id), \"\(kind)\", \(payload))", completionHandler: nil)
    }
}
