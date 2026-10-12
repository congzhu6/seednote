import AVFoundation
import Foundation
import Speech
import UIKit

private enum MediaError: LocalizedError {
    case microphoneDenied, recordingUnavailable, noRecording, invalidRecording
    case playbackUnavailable, speechDenied, speechUnavailable, onDeviceUnavailable
    case recognitionFailed, recognitionTimedOut

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: return L("Microphone access is disabled. Allow recording in Settings.", "麦克风权限未开启，请到系统设置中允许录音。")
        case .recordingUnavailable: return L("Recording could not start. Check that a microphone is available.", "无法开始录音，请检查麦克风是否可用。")
        case .noRecording: return L("There is no active recording.", "当前没有正在录制的音频。")
        case .invalidRecording: return L("The recording file is invalid. Please try again.", "录音文件无效，请重试。")
        case .playbackUnavailable: return L("This recording could not be played.", "无法播放这段录音。")
        case .speechDenied: return L("Speech recognition access is disabled. Allow it in Settings.", "语音识别权限未开启，请到系统设置中允许使用。")
        case .speechUnavailable: return L("Speech recognition is currently unavailable.", "当前无法使用语音识别。")
        case .onDeviceUnavailable: return L("On-device recognition is unavailable for this language on this device.", "此设备不支持所选语言的离线语音识别。")
        case .recognitionFailed: return L("Speech could not be recognized from this recording.", "未能识别这段录音中的文字。")
        case .recognitionTimedOut: return L("Speech recognition timed out. Please try again.", "语音识别超时，请重试。")
        }
    }
}

@MainActor
final class AudioRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var power: Float = 0
    @Published var errorMessage: String?
    @Published var stopNotice: String?

    var onFinished: ((URL, TimeInterval) -> Void)?
    var onFailed: ((URL, TimeInterval, String) -> Void)?

    private let maximumDuration: TimeInterval = 180
    private var startGeneration = UUID()
    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in guard let self, self.isRecording else { return }; self.stopNotice = L("Recording stopped when Seednote left the foreground. Your recorded audio was kept.", "Seednote 离开前台后已停止录音，已录下的音频会保留。"); self.finishAutomatically() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            Task { @MainActor [weak self] in guard let self, self.isRecording else { return }; self.stopNotice = L("Recording was interrupted. Your recorded audio was kept.", "录音被中断，已录下的音频会保留。"); self.finishAutomatically() }
        })
    }

    deinit {
        meterTimer?.invalidate()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func cancelPendingStart() { startGeneration = UUID() }

    func start(to url: URL) async throws {
        let generation = UUID()
        startGeneration = generation
        guard !isRecording, recorder == nil else { throw MediaError.recordingUnavailable }
        errorMessage = nil
        stopNotice = nil

        let allowed: Bool
        switch AVAudioApplication.shared.recordPermission {
        case .granted: allowed = true
        case .denied: allowed = false
        case .undetermined:
            allowed = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
            }
        @unknown default: allowed = false
        }
        guard allowed else {
            errorMessage = MediaError.microphoneDenied.localizedDescription
            throw MediaError.microphoneDenied
        }
        guard startGeneration == generation, !Task.isCancelled, UIApplication.shared.applicationState != .background else { throw CancellationError() }
        // Two start requests can overlap while the system permission sheet is open.
        guard !isRecording, recorder == nil else { throw MediaError.recordingUnavailable }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            let candidate = try AVAudioRecorder(url: url, settings: settings)
            candidate.delegate = self
            candidate.isMeteringEnabled = true
            guard candidate.record(forDuration: maximumDuration) else { throw MediaError.recordingUnavailable }
            recorder = candidate
            isRecording = true
            duration = 0
            power = 0
            meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateMeter() }
            }
        } catch {
            errorMessage = error.localizedDescription
            try? AVAudioSession.sharedInstance().setActive(false)
            throw error
        }
    }

    @discardableResult
    func stop() throws -> TimeInterval {
        guard let recorder else { throw MediaError.noRecording }
        // Explicit stop is attached by the caller; only automatic stops invoke onFinished.
        return finish(recorder, notify: false)
    }

    private func updateMeter() {
        guard let recorder, recorder.isRecording else { return }
        duration = min(max(0, recorder.currentTime), maximumDuration)
        recorder.updateMeters()
        let decibels = recorder.averagePower(forChannel: 0)
        power = max(0, min(1, (decibels + 60) / 60))
        if duration >= maximumDuration { stopNotice = L("The 3-minute recording limit was reached.", "已达到 3 分钟录音上限。"); finishAutomatically() }
        // A recorder that stopped by itself reports success or failure through its delegate.
        // Do not let a meter tick attach bytes before that result is known.
    }

    private func finishAutomatically(validatedDuration: TimeInterval? = nil) {
        guard let recorder else { return }
        _ = finish(recorder, notify: true, validatedDuration: validatedDuration)
    }

    @discardableResult
    private func finish(_ active: AVAudioRecorder, notify: Bool, validatedDuration: TimeInterval? = nil) -> TimeInterval {
        guard recorder === active else { return duration }
        var finalDuration = duration
        if active.isRecording {
            finalDuration = max(finalDuration, active.currentTime)
        }
        if let validatedDuration {
            finalDuration = max(finalDuration, validatedDuration)
        }
        finalDuration = min(max(0, finalDuration), maximumDuration)
        let url = active.url
        active.delegate = nil
        active.stop()
        meterTimer?.invalidate()
        meterTimer = nil
        recorder = nil
        isRecording = false
        duration = finalDuration
        power = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        if notify {
            // Keep the temporary file even if the owner cannot attach it yet.
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 {
                onFinished?(url, finalDuration)
            } else {
                stopNotice = nil
                errorMessage = MediaError.invalidRecording.localizedDescription
                onFailed?(url, finalDuration, MediaError.invalidRecording.localizedDescription)
            }
        }
        return finalDuration
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard self?.recorder === recorder else { return }
            if flag {
                let validatedDuration = self?.validatedFileDuration(at: recorder.url)
                if let self, let validatedDuration,
                   validatedDuration >= self.maximumDuration - 1 {
                    self.stopNotice = L("The 3-minute recording limit was reached.", "已达到 3 分钟录音上限。")
                }
                self?.finishAutomatically(validatedDuration: validatedDuration)
            }
            else { self?.finishFailed(recorder, error: MediaError.invalidRecording) }
        }
    }

    private func validatedFileDuration(at url: URL) -> TimeInterval? {
        guard let player = try? AVAudioPlayer(contentsOf: url),
              player.duration.isFinite, player.duration > 0 else { return nil }
        return min(player.duration, maximumDuration)
    }

    private func finishFailed(_ active: AVAudioRecorder, error: Error) {
        let url = active.url
        let elapsed = finish(active, notify: false)
        errorMessage = error.localizedDescription
        stopNotice = nil
        onFailed?(url, elapsed, error.localizedDescription)
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor [weak self] in
            guard self?.recorder === recorder else { return }
            self?.finishFailed(recorder, error: error ?? MediaError.invalidRecording)
        }
    }
}

@MainActor
final class AudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    @Published var errorMessage: String?
    private var player: AVAudioPlayer?
    private var interruptionObserver: NSObjectProtocol?

    override init() {
        super.init()
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            Task { @MainActor [weak self] in self?.stop() }
        }
    }

    deinit {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
    }

    func play(_ url: URL) throws {
        stop()
        errorMessage = nil
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback)
            try session.setActive(true)
            let candidate = try AVAudioPlayer(contentsOf: url)
            candidate.delegate = self
            guard candidate.play() else { throw MediaError.playbackUnavailable }
            player = candidate
            isPlaying = true
        } catch {
            errorMessage = error.localizedDescription
            try? AVAudioSession.sharedInstance().setActive(false)
            throw error
        }
    }

    func stop() {
        player?.delegate = nil
        player?.stop()
        player = nil
        isPlaying = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard self?.player === player else { return }
            if !flag { self?.errorMessage = MediaError.playbackUnavailable.localizedDescription }
            self?.stop()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            guard self?.player === player else { return }
            self?.errorMessage = error?.localizedDescription ?? MediaError.playbackUnavailable.localizedDescription
            self?.stop()
        }
    }
}

@MainActor
final class LocalTranscriber {
    private var recognitionTask: SFSpeechRecognitionTask?
    private var timeoutTask: Task<Void, Never>?
    private var pending: CheckedContinuation<String, Error>?
    private var requestID: UUID?
    private var generation = UUID()

    func transcribe(url: URL, localeIdentifier: String) async throws -> String {
        cancel()
        let generation = UUID()
        self.generation = generation
        try Task.checkCancellation()
        let authorized: Bool
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: authorized = true
        case .notDetermined:
            authorized = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        default: authorized = false
        }
        try Task.checkCancellation()
        guard self.generation == generation else { throw CancellationError() }
        guard authorized else { throw MediaError.speechDenied }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) else {
            throw MediaError.speechUnavailable
        }
        guard recognizer.supportsOnDeviceRecognition else { throw MediaError.onDeviceUnavailable }
        guard recognizer.isAvailable else { throw MediaError.speechUnavailable }
        guard self.generation == generation else { throw CancellationError() }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                requestID = id
                pending = continuation
                if Task.isCancelled {
                    finish(id: id, result: .failure(CancellationError()))
                    return
                }
                recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if let result, result.isFinal {
                            self.finish(id: id, result: .success(result.bestTranscription.formattedString))
                        } else if let error {
                            self.finish(id: id, result: .failure(error))
                        }
                    }
                }
                timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(60))
                    guard !Task.isCancelled else { return }
                    self?.finish(id: id, result: .failure(MediaError.recognitionTimedOut))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id: id, result: .failure(CancellationError())) }
        }
    }

    func cancel() {
        generation = UUID()
        guard let id = requestID else { return }
        finish(id: id, result: .failure(CancellationError()))
    }

    private func finish(id: UUID, result: Result<String, Error>) {
        guard requestID == id, let continuation = pending else { return }
        pending = nil
        requestID = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        continuation.resume(with: result)
    }
}
