import XCTest
import AVFoundation
import UIKit
@testable import Seednote

@MainActor final class EditorSessionTests: XCTestCase {
    private var root: URL!
    private var store: NoteStore!
    private var model: AppModel!
    private var defaults: UserDefaults!
    private var defaultsSuite: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("EditorSessionTests-\(UUID())")
        store = try NoteStore(root: root)
        defaultsSuite = "EditorSessionTests-\(UUID())"
        defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        model = AppModel(store: store, captureTracker: CaptureSetupTracker(defaults: defaults))
    }

    override func tearDownWithError() throws {
        model.session?.invalidate()
        model = nil
        defaults.removePersistentDomain(forName: defaultsSuite)
        defaults = nil
        store = nil
        try FileManager.default.removeItem(at: root)
    }

    func testRecoveredProcessingStatesBecomeDurableInterruptedStates() throws {
        var draft = try store.createDraft()
        draft.note.thought = "Keep these manual words"
        draft.note.transcript = "Manual transcript"
        draft.note.transcriptStatus = "processing"
        draft.note.ocrStatus = "processing"
        try store.saveDraft(draft)
        model.open(draft)
        let recovered = try XCTUnwrap(model.session)
        XCTAssertEqual(recovered.draft.note.transcriptStatus, "interrupted")
        XCTAssertEqual(recovered.draft.note.ocrStatus, "interrupted")
        XCTAssertEqual(recovered.draft.note.transcript, "Manual transcript")
        let reopened = try NoteStore(root: root).pendingDrafts().first
        XCTAssertEqual(reopened?.note.transcriptStatus, "interrupted")
        XCTAssertEqual(reopened?.note.ocrStatus, "interrupted")
    }

    func testKeepForLaterPersistsRecognitionCancellationWithoutLosingText() throws {
        model.create()
        let session = try XCTUnwrap(model.session)
        session.change(\.thought, to: "Keep the original thought")
        session.draft.note.transcript = "My correction"
        session.draft.note.transcriptStatus = "processing"
        session.draft.note.ocrStatus = "processing"
        session.isTranscribing = true
        session.isRecognizing = true
        model.closeKeeping()
        let kept = try XCTUnwrap(store.pendingDrafts().first)
        XCTAssertEqual(kept.note.transcriptStatus, "interrupted")
        XCTAssertEqual(kept.note.ocrStatus, "interrupted")
        XCTAssertEqual(kept.note.transcript, "My correction")
        XCTAssertFalse(session.isTranscribing)
        XCTAssertFalse(session.isRecognizing)
    }

    func testSavingDuringRecognitionNeverPersistsProcessing() throws {
        model.create()
        let session = try XCTUnwrap(model.session)
        session.change(\.thought, to: "Saved while recognition is pending")
        session.draft.note.transcriptStatus = "processing"
        session.draft.note.ocrStatus = "processing"
        session.isTranscribing = true
        session.isRecognizing = true
        session.save()
        let note = try XCTUnwrap(store.list().first)
        XCTAssertEqual(note.transcriptStatus, "interrupted")
        XCTAssertEqual(note.ocrStatus, "interrupted")
        XCTAssertNil(model.session)
    }

    func testCorruptReplacementAudioKeepsExistingAttachmentAndTranscript() throws {
        var draft = try store.createDraft()
        draft.note.thought = "A thought with useful audio"
        try store.attach(playableWAV(), fileExtension: "wav", to: &draft, kind: .audio)
        draft.note.transcript = "Keep my corrected transcript"
        try store.saveDraft(draft)
        let previousName = draft.note.audioName
        let oldURL = try store.draftAssetURL(draft, name: XCTUnwrap(previousName))
        XCTAssertGreaterThan(try AVAudioPlayer(contentsOf: oldURL).duration, 0)
        model.open(draft)
        let session = try XCTUnwrap(model.session)
        let broken = root.appendingPathComponent("broken.m4a")
        try Data("not an audio stream".utf8).write(to: broken)
        session.recorder.onFinished?(broken, 2)
        XCTAssertEqual(session.draft.note.audioName, previousName)
        XCTAssertEqual(session.draft.note.transcript, "Keep my corrected transcript")
        XCTAssertNotNil(session.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: broken.path))
        XCTAssertEqual(try store.pendingDrafts().first?.note.audioName, previousName)
        XCTAssertGreaterThan(try AVAudioPlayer(contentsOf: oldURL).duration, 0)
        session.discardPendingAudio()
        session.save()
        let saved = try XCTUnwrap(store.list().first)
        XCTAssertEqual(saved.audioName, previousName)
        XCTAssertEqual(saved.transcript, "Keep my corrected transcript")
    }
    func testConflictRecoveryCreatesIndependentRecordAndPreservesNewerOriginal() throws {
        var first = try store.createDraft()
        first.note.thought = "Original thought"
        let original = try store.commit(first)
        model.edit(original)
        let session = try XCTUnwrap(model.session)
        session.change(\.thought, to: "Rescued thought")
        var newer = try store.editDraft(noteID: original.id)
        newer.note.thought = "A newer original"
        _ = try store.commit(newer)
        session.save()
        XCTAssertNotNil(model.session)
        XCTAssertTrue(session.canSaveAsNew)
        session.saveAsNew()
        let notes = try store.list()
        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(notes.first(where: { $0.id == original.id })?.thought, "A newer original")
        XCTAssertTrue(notes.contains { $0.id != original.id && $0.thought == "Rescued thought" })
        XCTAssertNil(model.session)
    }

    func testDeletedSourceDraftCanBeRescuedAfterRelaunch() throws {
        var first = try store.createDraft()
        first.note.thought = "Original thought"
        let original = try store.commit(first)
        model.edit(original)
        model.session?.change(\.thought, to: "Recovered after deletion")
        model.closeKeeping()
        try store.delete(noteID: original.id)
        let persisted = try XCTUnwrap(store.pendingDrafts().first)
        model.open(persisted)
        let session = try XCTUnwrap(model.session)
        session.save()
        XCTAssertTrue(session.canSaveAsNew)
        session.saveAsNew()
        let rescued = try XCTUnwrap(store.list().first)
        XCTAssertNotEqual(rescued.id, original.id)
        XCTAssertEqual(rescued.thought, "Recovered after deletion")
        XCTAssertTrue(try store.pendingDrafts().isEmpty)
    }

    func testMissingAttachmentsCanBeExplicitlyRemovedWithoutLosingRecognizedText() throws {
        var draft = try store.createDraft()
        draft.note.thought = "Keep my thought"
        try store.attach(Data([1]), fileExtension: "jpg", to: &draft, kind: .image)
        try store.attach(Data([2]), fileExtension: "m4a", to: &draft, kind: .audio)
        draft.note.transcript = "Corrected transcription"
        draft.note.ocrText = "Useful source quotation"
        let original = try store.commit(draft)
        try FileManager.default.removeItem(at: store.assetURL(noteID: original.id, name: XCTUnwrap(original.imageName)))
        try FileManager.default.removeItem(at: store.assetURL(noteID: original.id, name: XCTUnwrap(original.audioName)))
        model.edit(original)
        let session = try XCTUnwrap(model.session)
        session.save()
        XCTAssertNotNil(model.session)
        session.removeImage()
        session.removeAudio()
        session.save()
        let saved = try XCTUnwrap(store.list().first)
        XCTAssertEqual(saved.id, original.id)
        XCTAssertEqual(saved.thought, "Keep my thought")
        XCTAssertEqual(saved.transcript, "Corrected transcription")
        XCTAssertEqual(saved.ocrText, "Useful source quotation")
        XCTAssertNil(saved.imageName)
        XCTAssertNil(saved.audioName)
    }
    func testRemovingAvailableImageAlsoRemovesItsRecognizedText() throws {
        var draft = try store.createDraft()
        draft.note.thought = "Keep my thought"
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }
        try store.attach(XCTUnwrap(image.pngData()), fileExtension: "png", to: &draft, kind: .image)
        draft.note.ocrText = "Text read from the removed image"
        draft.note.ocrState = .complete
        let original = try store.commit(draft)
        model.edit(original)
        let session = try XCTUnwrap(model.session)
        session.removeImage()
        session.save()
        let saved = try XCTUnwrap(store.list().first)
        XCTAssertNil(saved.imageName)
        XCTAssertEqual(saved.ocrText, "")
        XCTAssertEqual(saved.ocrState, .notStarted)
        XCTAssertEqual(saved.thought, "Keep my thought")
    }

    func testFailedRecorderCallbackDoesNotAutomaticallyReplacePlayableOriginal() throws {
        var draft = try store.createDraft()
        draft.note.thought = "Keep existing recording"
        try store.attach(playableWAV(), fileExtension: "wav", to: &draft, kind: .audio)
        try store.saveDraft(draft)
        model.open(draft)
        let session = try XCTUnwrap(model.session)
        let failed = root.appendingPathComponent("failed.wav")
        try playableWAV().write(to: failed)
        session.recorder.onFailed?(failed, 0.25, "Encoder reported failure")
        session.save()
        XCTAssertEqual(session.draft.note.audioName, draft.note.audioName)
        XCTAssertNotNil(model.session)
        XCTAssertTrue(FileManager.default.fileExists(atPath: failed.path))
        session.discardPendingAudio()
        session.save()
        XCTAssertEqual(try store.list().first?.audioName, draft.note.audioName)
    }

    func testCompletedAudioUsesDecodedDurationWhenStoppedRecorderReportsZero() throws {
        model.create()
        let session = try XCTUnwrap(model.session)
        let completed = root.appendingPathComponent("completed.wav")
        try playableWAV().write(to: completed)
        session.recorder.onFinished?(completed, 0)
        XCTAssertFalse(session.hasPendingAudio)
        XCTAssertNil(session.errorMessage)
        session.save()
        let saved = try XCTUnwrap(store.list().first)
        XCTAssertEqual(saved.audioDuration, 0.25, accuracy: 0.01)
        let audio = try store.assetURL(noteID: saved.id, name: XCTUnwrap(saved.audioName))
        XCTAssertGreaterThan(try AVAudioPlayer(contentsOf: audio).duration, 0)
    }

    func testDiscardingEditAfterNewRecordingKeepsSavedAudioAndTranscript() throws {
        var draft = try store.createDraft()
        draft.note.thought = "Keep the saved voice"
        try store.attach(playableWAV(), fileExtension: "wav", to: &draft, kind: .audio)
        draft.note.transcript = "Original spoken thought"
        let original = try store.commit(draft)
        let originalName = try XCTUnwrap(original.audioName)
        let originalBytes = try Data(contentsOf: store.assetURL(noteID: original.id, name: originalName))

        model.edit(original)
        let session = try XCTUnwrap(model.session)
        var replacementBytes = playableWAV()
        replacementBytes[replacementBytes.count - 1] = 1
        let replacement = root.appendingPathComponent("replacement.wav")
        try replacementBytes.write(to: replacement)
        session.recorder.onFinished?(replacement, 0.25)
        XCTAssertNotEqual(session.draft.note.audioName, originalName)
        XCTAssertEqual(session.draft.note.transcript, "")

        model.discard()
        XCTAssertNil(model.session)
        XCTAssertTrue(try store.pendingDrafts().isEmpty)
        let retained = try XCTUnwrap(store.list().first)
        XCTAssertEqual(retained.id, original.id)
        XCTAssertEqual(retained.audioName, originalName)
        XCTAssertEqual(retained.transcript, "Original spoken thought")
        XCTAssertEqual(try Data(contentsOf: store.assetURL(noteID: retained.id, name: originalName)), originalBytes)
    }

    func testSaveCancelsQueuedImageRecognitionBeforeItCanChangeSavedText() async throws {
        var draft = try store.createDraft()
        draft.note.thought = "Manual thought wins"
        draft.note.ocrText = "Existing extracted source"
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }
        try store.attach(XCTUnwrap(image.pngData()), fileExtension: "png", to: &draft, kind: .image)
        try store.saveDraft(draft)
        model.open(draft)
        let session = try XCTUnwrap(model.session)
        session.recognizeImage()
        XCTAssertTrue(session.isRecognizing)
        session.save()
        await Task.yield()
        let saved = try XCTUnwrap(store.list().first)
        XCTAssertEqual(saved.thought, "Manual thought wins")
        XCTAssertEqual(saved.ocrText, "Existing extracted source")
        XCTAssertEqual(saved.ocrStatus, "interrupted")
        XCTAssertFalse(session.isRecognizing)
    }

    func testCapturedScreenshotOpensEditorAndSecondCaptureWaitsWithVisibleNotice() async throws {
        let screenshot = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 300, height: 600)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 300, height: 600))
        }.pngData())
        try await model.receive(imageData: screenshot, sourceURL: nil, sourceText: nil, origin: "shortcutScreenshot",
                                trace: PerfTrace.begin("Capture", "test capture"))
        let first = try XCTUnwrap(model.session)
        XCTAssertEqual(first.draft.note.origin, "shortcutScreenshot")
        let imageName = try XCTUnwrap(first.draft.note.imageName)
        XCTAssertTrue(imageName.hasSuffix(".jpg"))
        XCTAssertNotNil(first.asset(imageName))
        XCTAssertNil(model.notice)
        model.editorDidAppear(first.id)

        try await model.receive(imageData: nil, sourceURL: "https://example.org/next", sourceText: nil, origin: "shortcutShare",
                                trace: PerfTrace.begin("Capture", "test capture"))
        XCTAssertEqual(model.session?.id, first.id, "A second capture must not replace the open draft")
        XCTAssertNotNil(model.notice)
        XCTAssertTrue(model.drafts.contains { $0.note.sourceURL == "https://example.org/next" })
    }

    func testCapturedDraftOpensDirectlyAndStaysInStepWithItsStoredCopy() async throws {
        try await model.receive(imageData: nil, sourceURL: "https://example.org/read", sourceText: "A passage", origin: "shortcutShare",
                                trace: PerfTrace.begin("Capture", "test capture"))
        let session = try XCTUnwrap(model.session)
        let pending = try store.pendingDrafts()
        XCTAssertEqual(pending.count, 1)
        let stored = try XCTUnwrap(pending.first)
        XCTAssertEqual(session.id, stored.id)
        XCTAssertEqual(session.draft.note.sourceURL, "https://example.org/read")
        XCTAssertEqual(session.draft.note.sourceText, "A passage")
        XCTAssertEqual(session.draft.baseRevision, stored.baseRevision)
        XCTAssertEqual(model.drafts.map(\.id), [stored.id])
        XCTAssertNil(model.errorMessage)
        // Opening without rereading must leave a draft the store still accepts.
        session.change(\.thought, to: "My take")
        XCTAssertNoThrow(try session.flush())
        session.save()
        XCTAssertEqual(try store.list().map(\.thought), ["My take"])
        XCTAssertNil(model.session)
    }

    func testTranscriptionTimeoutGrowsWithRecordingLength() {
        XCTAssertEqual(LocalTranscriber.timeout(forAudioDuration: 5), .seconds(60))
        XCTAssertEqual(LocalTranscriber.timeout(forAudioDuration: 30), .seconds(60))
        XCTAssertEqual(LocalTranscriber.timeout(forAudioDuration: 95), .seconds(190))
        XCTAssertEqual(LocalTranscriber.timeout(forAudioDuration: 180), .seconds(360))
        XCTAssertEqual(LocalTranscriber.timeout(forAudioDuration: 0), .seconds(60))
        XCTAssertEqual(LocalTranscriber.timeout(forAudioDuration: .nan), .seconds(60))
    }

    func testUnreadableRecordIsSurfacedWhileOtherIdeasStillLoad() throws {
        var draft = try store.createDraft()
        draft.note.thought = "Readable idea"
        let saved = try store.commit(draft)
        let broken = root.appendingPathComponent("notes/\(UUID().uuidString).json")
        try Data("{".utf8).write(to: broken)

        try model.reload()
        XCTAssertEqual(model.notes.map(\.id), [saved.id])
        XCTAssertEqual(model.unreadableFiles, [broken.lastPathComponent])
        XCTAssertNil(model.errorMessage)
    }

    // A real PCM WAV fixture; no microphone or permission prompt is involved.
    private func playableWAV() -> Data {
        var result = Data()
        func text(_ value: String) { result.append(contentsOf: value.utf8) }
        func word(_ value: UInt16) { var little = value.littleEndian; withUnsafeBytes(of: &little) { result.append(contentsOf: $0) } }
        func dword(_ value: UInt32) { var little = value.littleEndian; withUnsafeBytes(of: &little) { result.append(contentsOf: $0) } }
        let samples: UInt32 = 4_000
        text("RIFF"); dword(36 + samples * 2); text("WAVEfmt "); dword(16)
        word(1); word(1); dword(16_000); dword(32_000); word(2); word(16)
        text("data"); dword(samples * 2)
        result.append(Data(repeating: 0, count: Int(samples * 2)))
        return result
    }
}
