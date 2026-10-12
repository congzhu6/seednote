import SwiftUI
import Combine
import AVFoundation

@MainActor final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var notes: [SeedNote] = []
    @Published var drafts: [NoteDraft] = []
    @Published var session: EditorSession?
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published private(set) var saveGeneration = 0
    private(set) var store: NoteStore?
    let captureTracker: CaptureSetupTracker

    init() {
        captureTracker = .shared
        do {
            let fm = FileManager.default
            let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            var root = base.appendingPathComponent("Seednote", isDirectory: true)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--uitesting") {
                root = base.appendingPathComponent("SeednoteUITest", isDirectory: true)
                if ProcessInfo.processInfo.arguments.contains("--reset-test-store"), fm.fileExists(atPath: root.path) { try fm.removeItem(at: root) }
            }
            #endif
            store = try NoteStore(root: root)
            try reload()
        } catch { errorMessage = error.localizedDescription }
    }

    init(store: NoteStore, captureTracker: CaptureSetupTracker = .shared) {
        self.store = store
        self.captureTracker = captureTracker
        do { try reload() } catch { errorMessage = error.localizedDescription }
    }

    func reload() throws {
        guard let store else { throw CaptureError.message(L("The local library is unavailable. Restart Seednote and try again.", "本地资料库无法访问，请重启 Seednote 后重试。")) }
        let updatedNotes = try store.list()
        let updatedDrafts = try store.pendingDrafts()
        notes = updatedNotes
        drafts = updatedDrafts
    }

    func create() {
        do { guard let store else { return }; open(try store.createDraft()) }
        catch { errorMessage = error.localizedDescription }
    }
    func edit(_ note: SeedNote) {
        do { guard let store else { return }; open(try store.editDraft(noteID: note.id)) }
        catch { errorMessage = error.localizedDescription }
    }
    func open(_ draft: NoteDraft) {
        do {
            guard let store else { return }
            guard session?.id != draft.id else { return }
            guard let currentDraft = try store.pendingDrafts().first(where: { $0.id == draft.id }) else { throw CaptureError.message(L("This draft is no longer available.", "这份草稿已不可用。")) }
            try session?.keepForLater()
            session?.invalidate()
            session = EditorSession(draft: currentDraft, store: store, model: self)
            try reload()
        } catch { errorMessage = error.localizedDescription }
    }
    func closeSaved() {
        session = nil
        do { try reload(); saveGeneration += 1; notice = L("Idea saved", "灵感已保存") } catch { errorMessage = error.localizedDescription }
    }
    func closeKeeping() {
        do { try session?.keepForLater(); session?.invalidate(); session = nil; try reload() }
        catch { session?.errorMessage = error.localizedDescription }
    }
    func discard() {
        do {
            guard let store, let session else { return }
            guard session.stopRecording() else { return }
            try store.cancel(session.draft)
            session.invalidate()
            self.session = nil
            try reload()
        } catch { session?.errorMessage = error.localizedDescription }
    }
    func delete(_ note: SeedNote) throws { try store?.delete(noteID: note.id); try reload() }
    func discardPending(_ draft: NoteDraft) {
        guard session?.id != draft.id else { return }
        do { try store?.cancel(draft); try reload() } catch { errorMessage = error.localizedDescription }
    }
    func receive(imageData: Data?, sourceURL: String?, sourceText: String?, origin: String) throws {
        guard let store else { throw CaptureError.message(L("Seednote cannot access its library.", "Seednote 无法访问资料库。")) }
        if let sourceURL, validWebURL(sourceURL) == nil { throw CaptureError.message(L("Use a complete http or https link.", "请使用完整的 http 或 https 链接。")) }
        if (sourceText?.count ?? 0) > 100_000 { throw CaptureError.message(L("This text exceeds 100,000 characters.", "文字超过 100,000 字符。")) }
        guard imageData != nil || sourceURL != nil || !(sourceText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CaptureError.message(L("No material was provided.", "没有收到素材。")) }
        let preparedImage = try imageData.map(ImageService.prepare)
        var draft = try store.createDraft()
        do {
            draft.note.origin = origin
            draft.note.sourceURL = sourceURL ?? ""
            draft.note.sourceText = sourceText ?? ""
            if let preparedImage { try store.attach(preparedImage, fileExtension: "jpg", to: &draft, kind: .image) }
            try store.saveDraft(draft)
        } catch { try? store.cancel(draft); throw error }
        try reload()
        if session == nil { open(draft) }
        else { notice = L("New material is waiting in your drafts.", "新素材已保存在草稿中。") }
    }
}

@MainActor final class EditorSession: ObservableObject, Identifiable {
    let id: UUID
    @Published var draft: NoteDraft
    @Published var errorMessage: String?
    @Published var isSaving = false
    @Published var isStartingRecording = false
    @Published private(set) var hasPendingAudio = false
    @Published var isImporting = false
    @Published var isTranscribing = false
    @Published var isRecognizing = false
    @Published var draftKept = false
    @Published private(set) var canSaveAsNew = false
    @Published var speechLocale = Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh-CN" : "en-US"
    let recorder = AudioRecorder()
    let player = AudioPlayer()
    private let transcriber = LocalTranscriber()
    let store: NoteStore
    private weak var model: AppModel?
    private var persistenceTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var recognitionTask: Task<Void, Never>?
    private var transcriptVersion = 0
    private var imageVersion = 0
    private var transcriptionGeneration = UUID()
    private var recognitionGeneration = UUID()
    private var invalidated = false
    private var recordingURL: URL?
    private var pendingAudio: (URL, TimeInterval)?
    private var pendingAudioRequiresReview = false
    private var disposables = Set<AnyCancellable>()

    init(draft: NoteDraft, store: NoteStore, model: AppModel) {
        id = draft.id; self.draft = draft; self.store = store; self.model = model
        recorder.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &disposables)
        player.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &disposables)
        recorder.onFinished = { [weak self] url, duration in self?.finishAudio(url, duration: duration) }
        recorder.onFailed = { [weak self] url, duration, message in
            guard let self, !self.invalidated else { return }
            self.recordingURL = nil
            self.pendingAudio = (url, duration); self.hasPendingAudio = true
            self.pendingAudioRequiresReview = true
            self.errorMessage = message
        }
        if draft.note.transcriptStatus == "processing" || draft.note.ocrStatus == "processing" {
            interruptRecognition()
            do { try flush() } catch { errorMessage = error.localizedDescription }
        }
    }

    func change(_ keyPath: WritableKeyPath<SeedNote, String>, to value: String) {
        guard value.count <= 100_000 else { errorMessage = L("Keep each text field under 100,000 characters.", "每个文字区域最多支持 100,000 字符。"); return }
        if keyPath == \SeedNote.transcript {
            transcriptVersion += 1
            cancelTranscription()
        }
        draft.note[keyPath: keyPath] = value
        schedulePersistence()
    }
    private func schedulePersistence() {
        draftKept = false
        persistenceTask?.cancel()
        persistenceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, !self.invalidated else { return }
            do { try self.flush() } catch { self.errorMessage = error.localizedDescription }
        }
    }
    func flush() throws {
        persistenceTask?.cancel(); persistenceTask = nil
        try store.saveDraft(draft); draftKept = true
    }
    func asset(_ name: String?) -> URL? {
        guard let name else { return nil }
        return try? store.draftAssetURL(draft, name: name)
    }
    func importImage(_ data: Data) async {
        guard !invalidated else { return }
        isImporting = true
        defer { isImporting = false }
        do {
            let prepared = try await Task.detached(priority: .userInitiated) { try ImageService.prepare(data) }.value
            guard !invalidated else { return }
            try store.attach(prepared, fileExtension: "jpg", to: &draft, kind: .image)
            imageVersion += 1; cancelImageRecognition()
            draft.note.ocrText = ""; draft.note.ocrStatus = ""
            try flush()
        } catch { errorMessage = error.localizedDescription }
    }
    func removeImage() {
        imageVersion += 1; cancelImageRecognition()
        draft.note.imageName = nil; draft.note.ocrStatus = ""
        schedulePersistence()
    }
    func removeAudio() {
        player.stop(); transcriptVersion += 1; cancelTranscription()
        draft.note.audioName = nil; draft.note.audioDuration = 0; draft.note.transcriptStatus = ""
        schedulePersistence()
    }
    func setSource(_ value: String, asLink: Bool) throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= 100_000 else { throw CaptureError.message(L("This text exceeds 100,000 characters.", "文字超过 100,000 字符。")) }
        if asLink, !value.isEmpty, validWebURL(value) == nil { throw CaptureError.message(L("Use a complete http or https link.", "请使用完整的 http 或 https 链接。")) }
        draft.note[keyPath: asLink ? \SeedNote.sourceURL : \SeedNote.sourceText] = value
        try flush()
    }
    func startRecording() async {
        guard !recorder.isRecording, !isStartingRecording, !invalidated, !isSaving, !hasPendingAudio else { return }
        isStartingRecording = true
        defer { isStartingRecording = false }
        player.stop()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SeednoteAudio", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(UUID().uuidString + ".m4a")
            try await recorder.start(to: url)
            if invalidated { _ = try? recorder.stop(); try? FileManager.default.removeItem(at: url); return }
            recordingURL = url
        } catch { recordingURL = nil; errorMessage = error.localizedDescription }
    }
    @discardableResult func stopRecording() -> Bool {
        guard recorder.isRecording else { return true }
        do {
            let duration = try recorder.stop()
            guard let url = recordingURL else { throw CaptureError.message(L("The recording path is unavailable. Your draft is still open.", "无法找到录音文件，草稿仍保持打开。")) }
            finishAudio(url, duration: duration)
            return !hasPendingAudio
        } catch { errorMessage = error.localizedDescription; return false }
    }
    private func finishAudio(_ url: URL, duration: TimeInterval) {
        recordingURL = nil
        guard !invalidated else { return }
        pendingAudio = (url, duration); hasPendingAudio = true
        pendingAudioRequiresReview = false
        do {
            try attachPendingAudio()
        } catch { errorMessage = L("Your audio is still available for retry. ", "录音仍保留，可重试保存。") + error.localizedDescription }
    }
    private func attachPendingAudio() throws {
        guard let (url, _) = pendingAudio else { return }
        guard !pendingAudioRequiresReview else {
            throw CaptureError.message(L("The recorder reported a failure. Retry the attachment explicitly, or discard this new recording to keep the earlier audio.", "录音器报告了失败。请明确重试添加，或丢弃这次新录音以保留原录音。"))
        }
        let candidate = try AVAudioPlayer(contentsOf: url)
        guard candidate.duration.isFinite, candidate.duration > 0, candidate.prepareToPlay() else {
            throw CaptureError.message(L("No playable audio was recorded. Keep the earlier audio or record again.", "未录到可播放的音频，可保留原录音后重新录制。"))
        }
        let data = try Data(contentsOf: url)
        var replacement = draft
        try store.attach(data, fileExtension: "m4a", to: &replacement, kind: .audio)
        replacement.note.audioDuration = min(candidate.duration, 180)
        replacement.note.transcript = ""; replacement.note.transcriptStatus = ""
        // Persist before replacing the in-memory attachment. Failed persistence keeps the earlier audio usable.
        try store.saveDraft(replacement)
        transcriptVersion += 1; cancelTranscription()
        draft = replacement; draftKept = true
        pendingAudio = nil; hasPendingAudio = false; pendingAudioRequiresReview = false
        try? FileManager.default.removeItem(at: url)
    }
    func retryPendingAudio() {
        pendingAudioRequiresReview = false
        do { try attachPendingAudio() } catch { errorMessage = error.localizedDescription }
    }
    func discardPendingAudio() {
        if let (url, _) = pendingAudio { try? FileManager.default.removeItem(at: url) }
        pendingAudio = nil; hasPendingAudio = false; pendingAudioRequiresReview = false
    }
    private func cancelTranscription() {
        transcriptionGeneration = UUID()
        transcriber.cancel(); transcriptionTask?.cancel(); transcriptionTask = nil
        if isTranscribing || draft.note.transcriptStatus == "processing" { draft.note.transcriptStatus = "interrupted" }
        isTranscribing = false
    }
    private func cancelImageRecognition() {
        recognitionGeneration = UUID()
        recognitionTask?.cancel(); recognitionTask = nil
        if isRecognizing || draft.note.ocrStatus == "processing" { draft.note.ocrStatus = "interrupted" }
        isRecognizing = false
    }
    private func interruptRecognition() {
        cancelTranscription(); cancelImageRecognition()
    }
    func playAudio() {
        if player.isPlaying { player.stop(); return }
        guard let url = asset(draft.note.audioName) else { errorMessage = L("The audio file is unavailable.", "音频文件无法访问。"); return }
        do { try player.play(url) } catch { errorMessage = error.localizedDescription }
    }
    func transcribe() {
        guard let url = asset(draft.note.audioName), !isTranscribing else { return }
        player.stop(); isTranscribing = true
        let version = transcriptVersion
        let original = draft.note.transcript
        draft.note.transcriptStatus = "processing"
        let generation = UUID(); transcriptionGeneration = generation
        do { try flush() } catch { cancelTranscription(); errorMessage = error.localizedDescription; return }
        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.transcriptionGeneration == generation { self.isTranscribing = false } }
            do {
                let text = try await self.transcriber.transcribe(url: url, localeIdentifier: self.speechLocale)
                guard !self.invalidated, !Task.isCancelled, self.transcriptionGeneration == generation, self.transcriptVersion == version, self.draft.note.transcript == original else { return }
                self.draft.note.transcript = text; self.draft.note.transcriptStatus = "complete"
                try self.flush()
            } catch {
                guard !self.invalidated, !Task.isCancelled, self.transcriptionGeneration == generation else { return }
                self.draft.note.transcriptStatus = "unavailable"
                self.errorMessage = error.localizedDescription
                try? self.flush()
            }
        }
    }
    func recognizeImage() {
        guard let url = asset(draft.note.imageName), !isRecognizing else { return }
        isRecognizing = true
        draft.note.ocrStatus = "processing"
        let generation = UUID(); recognitionGeneration = generation
        do { try flush() } catch { cancelImageRecognition(); errorMessage = error.localizedDescription; return }
        let version = imageVersion
        recognitionTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.recognitionGeneration == generation { self.isRecognizing = false } }
            do {
                let data = try Data(contentsOf: url)
                let text = try await ImageService.recognize(data)
                guard !self.invalidated, !Task.isCancelled, self.recognitionGeneration == generation, self.imageVersion == version else { return }
                self.draft.note.ocrText = text; self.draft.note.ocrStatus = "complete"
                try self.flush()
            } catch {
                guard !self.invalidated, !Task.isCancelled, self.recognitionGeneration == generation else { return }
                self.errorMessage = error.localizedDescription
                self.draft.note.ocrStatus = "unavailable"; try? self.flush()
            }
        }
    }
    func save() {
        guard !isSaving, !isImporting, !isStartingRecording else { return }
        isSaving = true
        defer { isSaving = false }
        guard stopRecording() else { return }
        do {
            try attachPendingAudio()
            interruptRecognition()
            try flush()
            let saved = try store.commit(draft)
            model?.captureTracker.recordSaved(saved)
            invalidate()
            model?.closeSaved()
        } catch {
            if let storeError = error as? NoteStoreError, draft.baseRevision != nil,
               storeError == .conflict || storeError == .notFound { canSaveAsNew = true }
            errorMessage = error.localizedDescription
        }
    }
    func saveAsNew() {
        guard canSaveAsNew, !isSaving, !isImporting, !isStartingRecording else { return }
        guard stopRecording() else { return }
        do {
            try attachPendingAudio(); interruptRecognition(); try flush()
            draft = try store.rebaseDraftAsNew(draft)
            canSaveAsNew = false
            save()
        } catch { errorMessage = error.localizedDescription }
    }
    func keepForLater() throws {
        guard !isImporting else { throw CaptureError.message(L("Wait for the image to finish importing before switching ideas.", "请等待图片导入完成后再切换灵感。")) }
        guard !isStartingRecording else { throw CaptureError.message(L("Finish the microphone permission prompt first.", "请先完成麦克风权限提示。")) }
        guard stopRecording() else { throw CaptureError.message(errorMessage ?? L("Could not stop recording.", "未能停止录音。")) }
        try attachPendingAudio(); interruptRecognition(); try flush()
    }
    func invalidate() {
        invalidated = true
        recorder.cancelPendingStart()
        if recorder.isRecording { _ = try? recorder.stop() }
        player.stop(); interruptRecognition()
        persistenceTask?.cancel(); transcriptionTask?.cancel(); recognitionTask?.cancel()
    }
}
