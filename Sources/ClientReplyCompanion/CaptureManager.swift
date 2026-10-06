import AVFoundation
import ScreenCaptureKit
import Speech
import SwiftUI

private func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
    await withCheckedContinuation { continuation in
        SFSpeechRecognizer.requestAuthorization { status in
            continuation.resume(returning: status)
        }
    }
}

private final class AudioBufferSink: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var isPaused = false

    func setRequest(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        self.request = request
        isPaused = false
        lock.unlock()
    }

    func setPaused(_ paused: Bool) {
        lock.lock()
        isPaused = paused
        lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        if !isPaused { request?.append(buffer) }
        lock.unlock()
    }

    func append(_ buffer: CMSampleBuffer) {
        lock.lock()
        if !isPaused { request?.appendAudioSampleBuffer(buffer) }
        lock.unlock()
    }

    func finish() {
        lock.lock()
        request?.endAudio()
        request = nil
        isPaused = false
        lock.unlock()
    }
}

private func installMicrophoneTap(on input: AVAudioInputNode, sink: AudioBufferSink) {
    let format = input.outputFormat(forBus: 0)
    input.installTap(onBus: 0, bufferSize: 2_048, format: format) { buffer, _ in
        sink.append(buffer)
    }
}

private func makeRecognitionTask(
    recognizer: SFSpeechRecognizer,
    request: SFSpeechAudioBufferRecognitionRequest,
    handler: @escaping @MainActor @Sendable (String?, Bool, String?) -> Void
) -> SFSpeechRecognitionTask {
    recognizer.recognitionTask(with: request) { result, error in
        let transcript = result?.bestTranscription.formattedString
        let isFinal = result?.isFinal ?? false
        let errorMessage = error?.localizedDescription
        Task { @MainActor in
            handler(transcript, isFinal, errorMessage)
        }
    }
}

enum AudioSource: String, CaseIterable, Identifiable {
    case iphoneCall = "Дзвінок iPhone"
    case macMeeting = "Мітинг на Mac"

    var id: String { rawValue }

    var detail: String {
        switch self {
        case .iphoneCall: "Увімкни гучний зв’язок — Mac слухатиме через мікрофон"
        case .macMeeting: "Захоплення системного аудіо з мітингу на цьому Mac"
        }
    }

    var symbol: String {
        switch self {
        case .iphoneCall: "iphone.gen3"
        case .macMeeting: "macbook"
        }
    }
}

@MainActor
final class CaptureManager: NSObject, ObservableObject {
    @Published var source: AudioSource = .iphoneCall
    @Published var isCapturing = false
    @Published var transcript = ""
    @Published var draft = ""
    @Published var summary = ""
    @Published var replyRevision = UUID()
    @Published var status = "Готовий до розмови"
    @Published var errorMessage: String?
    @Published var isGenerating = false
    @Published var isSummarizing = false
    @Published var isRecognitionPaused = false
    @Published var isFinalizingTranscript = false

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    nonisolated private let audioSink = AudioBufferSink()
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?
    private var stream: SCStream?
    private let audioQueue = DispatchQueue(label: "client-reply.audio-capture")
    private var committedTranscript = ""
    private var currentUtterance = ""
    private var lastRepliedTranscript = ""
    private var lastTranscriptUpdate = Date.distantPast
    private var shouldSummarizeAfterStop = false

    private struct SavedConversation: Codable {
        var transcript: String
        var summary: String
        var lastRepliedTranscript: String?
    }

    var hasUnansweredText: Bool {
        !unansweredText(after: lastRepliedTranscript, in: transcript).isEmpty
    }

    private var archiveURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Replyline", isDirectory: true)
            .appendingPathComponent("conversation.json")
    }

    override init() {
        super.init()
        restoreConversation()
    }

    func toggleCapture() {
        guard !isFinalizingTranscript else { return }
        if isCapturing {
            stopCapture()
        } else {
            Task { await startCapture() }
        }
    }

    func clear() {
        committedTranscript = ""
        currentUtterance = ""
        lastRepliedTranscript = ""
        lastTranscriptUpdate = .distantPast
        transcript = ""
        draft = ""
        summary = ""
        replyRevision = UUID()
        isFinalizingTranscript = false
        shouldSummarizeAfterStop = false
        status = "Готовий до розмови"
        try? FileManager.default.removeItem(at: archiveURL)
    }

    func prepareReply(instructions: String) {
        guard !isFinalizingTranscript,
              !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let conversationSnapshot = transcript
        let previousSnapshot = lastRepliedTranscript
        let message = unansweredText(after: previousSnapshot, in: conversationSnapshot)
        guard !message.isEmpty else {
            status = "Немає нових слів для відповіді"
            return
        }
        pauseRecognitionForReply()
        isGenerating = true
        draft = ""
        replyRevision = UUID()
        status = isCapturing ? "Слухання на паузі — готую відповідь…" : "Готую коротку відповідь на Mac…"
        let context = String(previousSnapshot.suffix(1_200))
        Task { [weak self] in
            guard let self else { return }
            do {
                self.draft = try await ReplyGenerator().streamReply(
                    for: message,
                    context: context,
                    instructions: instructions,
                    provider: AIProviderStore.shared.selected
                ) { partialText in
                    self.draft = partialText
                }
                self.lastRepliedTranscript = self.transcript
                self.persistCurrentConversation()
                self.status = self.isRecognitionPaused
                    ? "Пауза: прочитай відповідь, потім натисни «Продовжити слухати»"
                    : "Чернетка готова — відредагуй її перед використанням"
            } catch {
                self.errorMessage = error.localizedDescription
                self.status = "Не вдалося згенерувати відповідь"
            }
            self.isGenerating = false
        }
    }

    func summarizeConversation() {
        guard !isCapturing, !isFinalizingTranscript, !isSummarizing,
              !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isSummarizing = true
        summary = ""
        status = "Готую конспект розмови на Mac…"
        let conversation = transcript
        Task { [weak self] in
            guard let self else { return }
            do {
                self.summary = try await ReplyGenerator().streamSummary(
                    for: conversation,
                    provider: AIProviderStore.shared.selected
                ) { partialText in
                    self.summary = partialText
                }
                self.persistCurrentConversation()
                self.status = "Конспект готовий"
            } catch {
                self.errorMessage = error.localizedDescription
                self.status = "Не вдалося створити конспект"
            }
            self.isSummarizing = false
        }
    }

    func toggleRecognitionPause() {
        guard isCapturing else { return }
        isRecognitionPaused.toggle()
        audioSink.setPaused(isRecognitionPaused)
        status = isRecognitionPaused
            ? "Пауза — мікрофон і розпізнавання не передають нові фрази"
            : (source == .iphoneCall ? "Слухаю через мікрофон Mac" : "Слухаю системне аудіо Mac")
    }

    private func pauseRecognitionForReply() {
        guard isCapturing, !isRecognitionPaused else { return }
        isRecognitionPaused = true
        audioSink.setPaused(true)
    }

    private func startCapture() async {
        errorMessage = nil
        do {
            try await authorizeSpeech()
            try await beginRecognition()
            switch source {
            case .iphoneCall:
                try await startMicrophone()
            case .macMeeting:
                try await startSystemAudio()
            }
            if !transcript.isEmpty || !summary.isEmpty { clear() }
            isCapturing = true
            isRecognitionPaused = false
            summary = ""
            status = source == .iphoneCall ? "Слухаю через мікрофон Mac" : "Слухаю системне аудіо Mac"
            persistCurrentConversation()
        } catch {
            stopCapture(finalizeConversation: false)
            errorMessage = error.localizedDescription
            status = "Не вдалося почати захоплення аудіо"
        }
    }

    private func authorizeSpeech() async throws {
        let result = await requestSpeechAuthorization()
        guard result == .authorized else {
            throw CaptureError.permission("Дозволь розпізнавання мовлення в налаштуваннях macOS.")
        }
        guard let recognizer, recognizer.isAvailable else {
            throw CaptureError.permission("Розпізнавання англійської зараз недоступне на цьому Mac.")
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw CaptureError.permission("На цьому Mac недоступне локальне розпізнавання англійської.")
        }
    }

    private func beginRecognition() async throws {
        recognitionTask?.cancel()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        audioSink.setRequest(request)
        if let recognizer {
            recognitionTask = makeRecognitionTask(recognizer: recognizer, request: request) { [weak self] text, isFinal, error in
                if let text { self?.updateTranscript(with: text, isFinal: isFinal) }
                if isFinal {
                    guard let self else { return }
                    if self.isCapturing {
                        self.status = "Фразу розпізнано"
                        Task { try? await self.beginRecognition() }
                    } else if self.isFinalizingTranscript {
                        self.finishStoppedConversation()
                    }
                }
                if let error, let self {
                    if self.isCapturing {
                        self.errorMessage = error
                    } else if self.isFinalizingTranscript {
                        self.finishStoppedConversation()
                    }
                }
            }
        }
    }

    private func updateTranscript(with text: String, isFinal: Bool) {
        let incoming = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !incoming.isEmpty else { return }

        if currentUtterance.isEmpty {
            currentUtterance = incoming
        } else {
            let old = currentUtterance.lowercased()
            let new = incoming.lowercased()
            let pauseElapsed = Date().timeIntervalSince(lastTranscriptUpdate) >= 1.2

            if new.hasPrefix(old) {
                // Speech may revise or extend the current phrase; keep its newest hypothesis.
                currentUtterance = incoming
            } else if old.hasPrefix(new), !pauseElapsed {
                // A shorter partial is a recognition revision, not a reason to erase text.
            } else if commonWordPrefixCount(old, new) >= 2, !pauseElapsed {
                currentUtterance = incoming
            } else {
                // Apple Speech can restart its partial transcript after a pause. Commit the
                // previous phrase first so the new partial cannot replace what was heard.
                commitCurrentUtterance()
                currentUtterance = incoming
            }
        }

        lastTranscriptUpdate = Date()
        if isFinal { commitCurrentUtterance() }
        transcript = [committedTranscript, currentUtterance]
            .filter { !$0.isEmpty }
            .joined(separator: committedTranscript.isEmpty ? "" : " ")
        persistCurrentConversation()
    }

    private func restoreConversation() {
        guard let data = try? Data(contentsOf: archiveURL),
              let saved = try? JSONDecoder().decode(SavedConversation.self, from: data) else { return }
        transcript = saved.transcript
        summary = saved.summary
        // Archives written by older builds have no reply boundary; treat their existing text as handled.
        lastRepliedTranscript = saved.lastRepliedTranscript ?? saved.transcript
        committedTranscript = saved.transcript
        status = saved.transcript.isEmpty ? "Готовий до розмови" : "Попередній діалог збережено"
    }

    func persistCurrentConversation() {
        let saved = SavedConversation(
            transcript: transcript,
            summary: summary,
            lastRepliedTranscript: lastRepliedTranscript
        )
        guard let data = try? JSONEncoder().encode(saved) else { return }
        do {
            try FileManager.default.createDirectory(
                at: archiveURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: archiveURL, options: .atomic)
        } catch {
            // Keep the live conversation available even if the local archive cannot be written.
        }
    }

    private func commitCurrentUtterance() {
        guard !currentUtterance.isEmpty else { return }
        if !committedTranscript.isEmpty { committedTranscript += " " }
        committedTranscript += currentUtterance
        currentUtterance = ""
    }

    private func commonWordPrefixCount(_ lhs: String, _ rhs: String) -> Int {
        let leftWords = lhs.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let rightWords = rhs.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return zip(leftWords, rightWords).prefix { $0 == $1 }.count
    }

    private func unansweredText(after handledTranscript: String, in fullTranscript: String) -> String {
        let full = fullTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !full.isEmpty else { return "" }
        guard !handledTranscript.isEmpty else { return full }

        func wordMatches(_ text: String) -> [(value: String, range: NSRange)] {
            guard let regex = try? NSRegularExpression(pattern: "[\\p{L}\\p{N}]+") else { return [] }
            return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
                let value = (text as NSString).substring(with: match.range).lowercased()
                return (value, match.range)
            }
        }

        let handledWords = wordMatches(handledTranscript).map(\.value)
        let fullWords = wordMatches(full)
        guard !handledWords.isEmpty,
              fullWords.count > handledWords.count,
              Array(fullWords.prefix(handledWords.count).map(\.value)) == handledWords,
              let lastHandledWord = fullWords.dropFirst(handledWords.count - 1).first else {
            return ""
        }

        let nsFull = full as NSString
        let suffixRange = NSRange(location: NSMaxRange(lastHandledWord.range), length: nsFull.length - NSMaxRange(lastHandledWord.range))
        return nsFull.substring(with: suffixRange)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    private func startMicrophone() async throws {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else { throw CaptureError.permission("Дозволь доступ до мікрофона в налаштуваннях macOS.") }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        installMicrophoneTap(on: input, sink: audioSink)
        engine.prepare()
        try engine.start()
        audioEngine = engine
    }

    private func startSystemAudio() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CaptureError.permission("Не знайдено дисплей для захоплення аудіо.") }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 16_000
        configuration.channelCount = 1
        configuration.width = 2
        configuration.height = 2

        let audioStream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try audioStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try await audioStream.startCapture()
        stream = audioStream
    }

    func stopCapture(finalizeConversation: Bool = true) {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        if let stream {
            Task { try? await stream.stopCapture() }
        }
        stream = nil
        shouldSummarizeAfterStop = finalizeConversation
        isFinalizingTranscript = finalizeConversation && recognitionTask != nil
        isCapturing = false
        isRecognitionPaused = false
        audioSink.finish()
        if isFinalizingTranscript {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                guard self.isFinalizingTranscript, !self.isCapturing else { return }
                self.recognitionTask?.cancel()
                self.finishStoppedConversation()
            }
        } else if finalizeConversation {
            finishStoppedConversation()
        } else {
            recognitionTask?.cancel()
            recognitionTask = nil
        }
        if isFinalizingTranscript {
            status = "Фіксую останні слова…"
        } else if !finalizeConversation, errorMessage == nil {
            status = "Захоплення зупинено"
        }
    }

    private func finishStoppedConversation() {
        isFinalizingTranscript = false
        recognitionTask = nil
        status = "Діалог збережено"
        guard shouldSummarizeAfterStop else { return }
        shouldSummarizeAfterStop = false
        summarizeConversation()
    }

    private enum CaptureError: LocalizedError {
        case permission(String)
        var errorDescription: String? {
            if case let .permission(message) = self { return message }
            return nil
        }
    }

    nonisolated private func appendAudioBuffer(_ buffer: CMSampleBuffer) {
        audioSink.append(buffer)
    }
}

extension CaptureManager: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        appendAudioBuffer(sampleBuffer)
    }
}
