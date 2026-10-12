import Foundation
import XCTest
@testable import SeednoteCore
#if os(macOS)
import Darwin
#endif

final class NoteStoreTests: XCTestCase {
    private func fixture() throws -> (URL, NoteStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, try NoteStore(root: root))
    }

    func testDraftIsRecoverableButNotFormalUntilCommitAndRetryIsIdempotent() throws {
        let (root, store) = try fixture()
        var draft = try store.createDraft()
        draft.note.thought = "First thought"
        try store.saveDraft(draft)
        XCTAssertTrue(try store.list().isEmpty)
        XCTAssertEqual(try NoteStore(root: root).pendingDrafts().single?.note.thought, "First thought")
        let committed = try store.commit(draft)
        XCTAssertEqual(committed.revision, 1)
        XCTAssertEqual(try NoteStore(root: root).commit(draft), committed)
        XCTAssertEqual(try store.list().count, 1)
        XCTAssertTrue(try store.pendingDrafts().isEmpty)
    }

    func testCommitInterruptedBeforeDraftCleanupDoesNotReappearOrDuplicate() throws {
        let (root, store) = try fixture()
        var draft = try store.createDraft()
        draft.note.thought = "Once"
        try store.saveDraft(draft)
        let draftPath = root.appendingPathComponent("drafts/\(draft.id.uuidString).json")
        let snapshot = try Data(contentsOf: draftPath)
        let first = try store.commit(draft)
        // Recreate the exact durable state at the crash boundary: the record was
        // written but an interrupted cleanup left the old draft metadata behind.
        try snapshot.write(to: draftPath)
        let reopened = try NoteStore(root: root)
        XCTAssertTrue(try reopened.pendingDrafts().isEmpty)
        XCTAssertEqual(try reopened.commit(draft), first)
        XCTAssertEqual(try reopened.list().single?.revision, 1)
    }

    func testSeparateStoreInstancesRejectStaleDraftAfterOtherStoreCommits() throws {
        let (root, first) = try fixture()
        let second = try NoteStore(root: root)
        var draft = try first.createDraft()
        draft.note.thought = "First"
        let saved = try first.commit(draft)
        var edit = try second.editDraft(noteID: saved.id)
        var concurrent = try first.editDraft(noteID: saved.id)
        concurrent.note.thought = "New version"
        _ = try first.commit(concurrent)
        edit.note.thought = "Stale version"
        XCTAssertThrowsError(try second.commit(edit)) { XCTAssertEqual($0 as? NoteStoreError, .conflict) }
    }

    func testRetryAfterMetadataWriteFailsFollowingMediaCopy() throws {
        let (root, store) = try fixture()
        var draft = try store.createDraft()
        draft.note.thought = "Keep this"
        try store.attach(Data("image bytes".utf8), fileExtension: "jpg", to: &draft, kind: .image)
        try store.saveDraft(draft)
        let notes = root.appendingPathComponent("notes")
        let hidden = root.appendingPathComponent("notes-hidden")
        try FileManager.default.moveItem(at: notes, to: hidden)
        try Data("blocking metadata directory".utf8).write(to: notes)
        XCTAssertThrowsError(try store.commit(draft))
        let name = try XCTUnwrap(draft.note.imageName)
        let copied = root.appendingPathComponent("assets/\(draft.note.id.uuidString)/\(name)")
        XCTAssertEqual(try Data(contentsOf: copied), Data("image bytes".utf8))
        try FileManager.default.removeItem(at: notes)
        try FileManager.default.moveItem(at: hidden, to: notes)
        let note = try store.commit(draft)
        XCTAssertEqual(note.revision, 1)
        XCTAssertEqual(try store.list().count, 1)
        XCTAssertEqual(try Data(contentsOf: store.assetURL(noteID: note.id, name: name)), Data("image bytes".utf8))
    }

    func testEditingDraftKeepsSourceMediaAfterOriginalRecordDeletion() throws {
        let (root, store) = try fixture()
        var draft = try store.createDraft()
        draft.note.thought = "Original"
        try store.attach(Data("only copy".utf8), fileExtension: "jpg", to: &draft, kind: .image)
        let original = try store.commit(draft)
        let edit = try store.editDraft(noteID: original.id)
        let name = try XCTUnwrap(edit.note.imageName)
        try store.delete(noteID: original.id)
        let reopened = try NoteStore(root: root)
        let recovered = try XCTUnwrap(reopened.pendingDrafts().single)
        XCTAssertEqual(try Data(contentsOf: reopened.draftAssetURL(recovered, name: name)), Data("only copy".utf8))
        XCTAssertThrowsError(try reopened.commit(recovered))
    }

    func testEditingNoteWithMissingMediaKeepsTextAndReferencesUntilExplicitRemoval() throws {
        let (root, store) = try fixture()
        var draft = try store.createDraft()
        draft.note.thought = "Text survives missing attachments"
        try store.attach(Data("image".utf8), fileExtension: "jpg", to: &draft, kind: .image)
        try store.attach(Data("audio".utf8), fileExtension: "m4a", to: &draft, kind: .audio)
        let original = try store.commit(draft)
        let imageName = try XCTUnwrap(original.imageName)
        let audioName = try XCTUnwrap(original.audioName)
        try FileManager.default.removeItem(at: root.appendingPathComponent("assets/\(original.id.uuidString)/\(imageName)"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("assets/\(original.id.uuidString)/\(audioName)"))

        var edit = try store.editDraft(noteID: original.id)

        XCTAssertEqual(edit.note.thought, "Text survives missing attachments")
        XCTAssertEqual(edit.note.imageName, imageName)
        XCTAssertEqual(edit.note.audioName, audioName)
        XCTAssertEqual(try NoteStore(root: root).pendingDrafts().single?.note, edit.note)
        XCTAssertThrowsError(try store.draftAssetURL(edit, name: imageName)) {
            XCTAssertEqual($0 as? NoteStoreError, .missingMedia(imageName))
        }
        XCTAssertThrowsError(try store.draftAssetURL(edit, name: audioName)) {
            XCTAssertEqual($0 as? NoteStoreError, .missingMedia(audioName))
        }
        XCTAssertThrowsError(try store.commit(edit)) {
            XCTAssertEqual($0 as? NoteStoreError, .missingMedia(imageName))
        }

        edit.note.imageName = nil
        edit.note.audioName = nil
        try store.saveDraft(edit)
        let saved = try store.commit(edit)
        XCTAssertEqual(saved.thought, "Text survives missing attachments")
        XCTAssertNil(saved.imageName)
        XCTAssertNil(saved.audioName)
    }

    func testEditDraftRejectsMalformedMediaNamePersistedInFormalRecord() throws {
        let (root, store) = try fixture()
        var draft = try store.createDraft()
        draft.note.thought = "Valid record before corruption"
        try store.attach(Data("image".utf8), fileExtension: "jpg", to: &draft, kind: .image)
        let saved = try store.commit(draft)
        let recordPath = root.appendingPathComponent("notes/\(saved.id.uuidString).json")
        var record = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: recordPath)) as? [String: Any])
        var note = try XCTUnwrap(record["note"] as? [String: Any])
        note["imageName"] = "../escape.jpg"
        record["note"] = note
        try JSONSerialization.data(withJSONObject: record).write(to: recordPath, options: .atomic)

        XCTAssertThrowsError(try store.editDraft(noteID: saved.id)) {
            XCTAssertEqual($0 as? NoteStoreError, .invalidInput("mediaName"))
        }
        XCTAssertTrue(try store.pendingDrafts().isEmpty)
    }

    func testRebaseDraftAsNewPreservesStagedMediaAndNeverOverwritesNewerOriginal() throws {
        let (root, store) = try fixture()
        var initial = try store.createDraft()
        initial.note.thought = "Original"
        try store.attach(Data("image bytes".utf8), fileExtension: "jpg", to: &initial, kind: .image)
        try store.attach(Data("audio bytes".utf8), fileExtension: "m4a", to: &initial, kind: .audio)
        let original = try store.commit(initial)
        var rescue = try store.editDraft(noteID: original.id)
        var competing = try store.editDraft(noteID: original.id)
        competing.note.thought = "Newer original"
        let newerOriginal = try store.commit(competing)
        rescue.note.thought = "Rescued copy"
        try store.saveDraft(rescue)

        let rebased = try store.rebaseDraftAsNew(rescue)

        XCTAssertEqual(rebased.id, rescue.id)
        XCTAssertNotEqual(rebased.note.id, original.id)
        XCTAssertNil(rebased.baseRevision)
        XCTAssertEqual(rebased.note.imageName, original.imageName)
        XCTAssertEqual(rebased.note.audioName, original.audioName)
        XCTAssertEqual(try Data(contentsOf: store.draftAssetURL(rebased, name: try XCTUnwrap(rebased.note.imageName))), Data("image bytes".utf8))
        XCTAssertEqual(try Data(contentsOf: store.draftAssetURL(rebased, name: try XCTUnwrap(rebased.note.audioName))), Data("audio bytes".utf8))
        XCTAssertEqual(try store.list().single?.thought, newerOriginal.thought)
        XCTAssertEqual(try store.list().single?.revision, 2)

        let reopened = try NoteStore(root: root)
        let persisted = try XCTUnwrap(reopened.pendingDrafts().single)
        XCTAssertEqual(persisted.id, rebased.id)
        XCTAssertEqual(persisted.note.id, rebased.note.id)
        XCTAssertNil(persisted.baseRevision)
        let repeated = try reopened.rebaseDraftAsNew(persisted)
        XCTAssertEqual(repeated.note.id, rebased.note.id)

        let rescued = try reopened.commit(repeated)
        XCTAssertEqual(try reopened.commit(repeated), rescued)
        let records = try reopened.list()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.first(where: { $0.id == original.id })?.thought, "Newer original")
        XCTAssertEqual(records.first(where: { $0.id == rescued.id })?.thought, "Rescued copy")
        XCTAssertEqual(try Data(contentsOf: reopened.assetURL(noteID: rescued.id, name: try XCTUnwrap(rescued.imageName))), Data("image bytes".utf8))
        XCTAssertEqual(try Data(contentsOf: reopened.assetURL(noteID: rescued.id, name: try XCTUnwrap(rescued.audioName))), Data("audio bytes".utf8))
    }

    func testRebaseDraftAsNewRescuesEditAfterOriginalWasDeleted() throws {
        let (_, store) = try fixture()
        var initial = try store.createDraft()
        initial.note.thought = "Original"
        try store.attach(Data("only staged copy".utf8), fileExtension: "jpg", to: &initial, kind: .image)
        let original = try store.commit(initial)
        var rescue = try store.editDraft(noteID: original.id)
        rescue.note.thought = "Recovered after deletion"
        try store.saveDraft(rescue)
        try store.delete(noteID: original.id)

        let rebased = try store.rebaseDraftAsNew(rescue)
        let saved = try store.commit(rebased)

        XCTAssertNotEqual(saved.id, original.id)
        XCTAssertEqual(saved.thought, "Recovered after deletion")
        XCTAssertEqual(try store.list().map(\.id), [saved.id])
        XCTAssertEqual(try Data(contentsOf: store.assetURL(noteID: saved.id, name: try XCTUnwrap(saved.imageName))), Data("only staged copy".utf8))
    }

    func testRebaseDraftAsNewRejectsUnrelatedAndStaleDraftIdentities() throws {
        let (_, store) = try fixture()
        var initial = try store.createDraft()
        initial.note.thought = "Original"
        let original = try store.commit(initial)
        let edit = try store.editDraft(noteID: original.id)

        var unrelatedNote = edit
        unrelatedNote.note.id = UUID()
        XCTAssertThrowsError(try store.rebaseDraftAsNew(unrelatedNote)) {
            XCTAssertEqual($0 as? NoteStoreError, .conflict)
        }
        var unrelatedRevision = edit
        unrelatedRevision.baseRevision = (edit.baseRevision ?? 0) + 1
        XCTAssertThrowsError(try store.rebaseDraftAsNew(unrelatedRevision)) {
            XCTAssertEqual($0 as? NoteStoreError, .conflict)
        }
        var unknownDraft = edit
        unknownDraft.id = UUID()
        XCTAssertThrowsError(try store.rebaseDraftAsNew(unknownDraft)) {
            XCTAssertEqual($0 as? NoteStoreError, .notFound)
        }

        let rebased = try store.rebaseDraftAsNew(edit)
        XCTAssertThrowsError(try store.rebaseDraftAsNew(edit)) {
            XCTAssertEqual($0 as? NoteStoreError, .conflict)
        }
        XCTAssertEqual(try store.rebaseDraftAsNew(rebased).note.id, rebased.note.id)
    }

    func testRebaseDraftAsNewRejectsEditingDraftLeftBehindAfterSuccessfulCommit() throws {
        let (root, store) = try fixture()
        var initial = try store.createDraft()
        initial.note.thought = "Original"
        let original = try store.commit(initial)
        var edit = try store.editDraft(noteID: original.id)
        edit.note.thought = "Committed update"
        try store.saveDraft(edit)
        let draftPath = root.appendingPathComponent("drafts/\(edit.id.uuidString).json")
        let snapshotBeforeCommit = try Data(contentsOf: draftPath)
        let committed = try store.commit(edit)
        // Recreate the crash boundary where formal metadata committed but best-effort
        // draft cleanup did not finish.
        try snapshotBeforeCommit.write(to: draftPath, options: .atomic)

        XCTAssertThrowsError(try store.rebaseDraftAsNew(edit)) {
            XCTAssertEqual($0 as? NoteStoreError, .conflict)
        }
        XCTAssertEqual(try store.list(), [committed])
    }

    #if os(macOS)
    func testRebaseDraftAsNewWriteFailureLeavesOriginalDraftAndStagedMediaRecoverable() throws {
        let (root, store) = try fixture()
        var initial = try store.createDraft()
        initial.note.thought = "Original"
        try store.attach(Data("staged image".utf8), fileExtension: "jpg", to: &initial, kind: .image)
        let original = try store.commit(initial)
        var rescue = try store.editDraft(noteID: original.id)
        rescue.note.thought = "Keep after failed rebase"
        try store.saveDraft(rescue)
        let draftsDirectory = root.appendingPathComponent("drafts")
        guard chflags(draftsDirectory.path, UInt32(UF_IMMUTABLE)) == 0 else {
            throw XCTSkip("File flags unavailable in this test environment")
        }
        defer { _ = chflags(draftsDirectory.path, 0) }

        XCTAssertThrowsError(try store.rebaseDraftAsNew(rescue))

        guard chflags(draftsDirectory.path, 0) == 0 else {
            return XCTFail("Could not restore drafts directory flags")
        }
        let recovered = try XCTUnwrap(try NoteStore(root: root).pendingDrafts().single)
        XCTAssertEqual(recovered.id, rescue.id)
        XCTAssertEqual(recovered.note.id, original.id)
        XCTAssertEqual(recovered.baseRevision, original.revision)
        XCTAssertEqual(recovered.note.thought, "Keep after failed rebase")
        XCTAssertEqual(try Data(contentsOf: store.draftAssetURL(recovered, name: try XCTUnwrap(recovered.note.imageName))), Data("staged image".utf8))
        XCTAssertNotEqual(try store.rebaseDraftAsNew(recovered).note.id, original.id)
    }
    #endif

    func testSavingDraftRefreshesItsRecoverySortDate() throws {
        let (_, store) = try fixture()
        var draft = try store.createDraft()
        draft.note.updatedAt = Date(timeIntervalSince1970: 0)
        draft.note.thought = "Recently edited"
        try store.saveDraft(draft)
        XCTAssertGreaterThan(try XCTUnwrap(store.pendingDrafts().single).note.updatedAt, Date(timeIntervalSince1970: 1_000_000))
    }

    #if os(macOS)
    func testCancelAndDeleteReportSuccessAfterMetadataRemovalWhenAssetCleanupFails() throws {
        let (_, store) = try fixture()
        var draft = try store.createDraft()
        draft.note.thought = "Discard me"
        try store.attach(Data("temporary".utf8), fileExtension: "jpg", to: &draft, kind: .image)
        let staged = try store.draftAssetURL(draft, name: try XCTUnwrap(draft.note.imageName))
        guard chflags(staged.path, UInt32(UF_IMMUTABLE)) == 0 else { throw XCTSkip("File flags unavailable in this test environment") }
        defer { _ = chflags(staged.path, 0) }
        XCTAssertNoThrow(try store.cancel(draft))
        XCTAssertTrue(try store.pendingDrafts().isEmpty)

        var savedDraft = try store.createDraft()
        savedDraft.note.thought = "Delete me"
        try store.attach(Data("saved".utf8), fileExtension: "jpg", to: &savedDraft, kind: .image)
        let note = try store.commit(savedDraft)
        let asset = try store.assetURL(noteID: note.id, name: try XCTUnwrap(note.imageName))
        guard chflags(asset.path, UInt32(UF_IMMUTABLE)) == 0 else { throw XCTSkip("File flags unavailable in this test environment") }
        defer { _ = chflags(asset.path, 0) }
        XCTAssertNoThrow(try store.delete(noteID: note.id))
        XCTAssertTrue(try store.list().isEmpty)
    }
    #endif

    func testWritingCardAndExportUseRequestedLanguage() throws {
        let (root, store) = try fixture()
        var draft = try store.createDraft()
        draft.note.thought = "A thought"
        draft.note.transcript = "Spoken words"
        draft.note.sourceURL = "https://example.org/story"
        draft.note.ocrText = "Printed words"
        let note = try store.commit(draft)
        let englishCard = note.writingCard(languageCode: "en-US")
        XCTAssertTrue(englishCard.contains("My thought: A thought"))
        XCTAssertTrue(englishCard.contains("Transcript: Spoken words"))
        XCTAssertTrue(englishCard.contains("Image text (source): Printed words"))
        XCTAssertFalse(englishCard.contains("我的想法"))
        let chineseCard = note.writingCard(languageCode: "zh-CN")
        XCTAssertTrue(chineseCard.contains("我的想法：A thought"))
        XCTAssertTrue(chineseCard.contains("图片识别的来源文字：Printed words"))
        let exported = try store.export(to: root.appendingPathComponent("exports"), languageCode: "en-US")
        let index = try String(contentsOf: exported.appendingPathComponent("index.txt"), encoding: .utf8)
        XCTAssertTrue(index.contains("Seednote export"))
        XCTAssertTrue(index.contains("1 saved idea"))
        XCTAssertTrue(index.contains("Created:"))
        XCTAssertFalse(index.contains("导出资料"))
    }

    func testValidationErrorsAndEmptyTitleHaveEnglishAndChineseMessages() {
        let empty = SeedNote()
        XCTAssertEqual(empty.displayTitle(languageCode: "en-US"), "Add your thought")
        XCTAssertEqual(empty.displayTitle(languageCode: "zh-CN"), "待补充想法")
        XCTAssertEqual(NoteStoreError.notFound.message(languageCode: "en-US"), "The idea or draft could not be found.")
        XCTAssertEqual(NoteStoreError.notFound.message(languageCode: "zh-CN"), "找不到资料或草稿。")
        XCTAssertTrue(NoteStoreError.invalidInput("webURL").message(languageCode: "en-US").contains("HTTP(S)"))
    }

    func testEditConflictAndCancelPreserveCommittedVersion() throws {
        let (_, store) = try fixture()
        var draft = try store.createDraft()
        draft.note.thought = "Original"
        let original = try store.commit(draft)
        var abandoned = try store.editDraft(noteID: original.id)
        abandoned.note.thought = "Abandoned"
        try store.saveDraft(abandoned)
        try store.cancel(abandoned)
        XCTAssertEqual(try store.list().single?.thought, "Original")
        var edit = try store.editDraft(noteID: original.id)
        var competing = try store.editDraft(noteID: original.id)
        edit.note.thought = "Winner"
        XCTAssertEqual(try store.commit(edit).revision, 2)
        competing.note.thought = "Loser"
        XCTAssertThrowsError(try store.commit(competing)) { XCTAssertEqual($0 as? NoteStoreError, .conflict) }
        XCTAssertEqual(try store.list().single?.thought, "Winner")
    }

    func testMediaStagingIsImmutableAndMissingFileAbortsWithoutLosingDraft() throws {
        let (_, store) = try fixture()
        var draft = try store.createDraft()
        draft.note.thought = "Keep me"
        try store.attach(Data("image A".utf8), fileExtension: "jpg", to: &draft, kind: .image)
        let staged = try store.draftAssetURL(draft, name: try XCTUnwrap(draft.note.imageName))
        let saved = try store.commit(draft)
        XCTAssertEqual(try Data(contentsOf: store.assetURL(noteID: saved.id, name: try XCTUnwrap(saved.imageName))), Data("image A".utf8))
        var edit = try store.editDraft(noteID: saved.id)
        try store.attach(Data("image B".utf8), fileExtension: "jpg", to: &edit, kind: .image)
        try store.cancel(edit)
        XCTAssertEqual(try Data(contentsOf: store.assetURL(noteID: saved.id, name: try XCTUnwrap(saved.imageName))), Data("image A".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        var damaged = try store.createDraft()
        damaged.note.thought = "Still recoverable"
        try store.attach(Data("temporary".utf8), fileExtension: "jpg", to: &damaged, kind: .image)
        try store.saveDraft(damaged)
        let missing = try store.draftAssetURL(damaged, name: try XCTUnwrap(damaged.note.imageName))
        try FileManager.default.removeItem(at: missing)
        XCTAssertThrowsError(try store.commit(damaged))
        XCTAssertEqual(try store.pendingDrafts().single?.note.thought, "Still recoverable")
    }

    func testAttachmentWriteFailureLeavesEditingDraftAndOriginalMediaIntact() throws {
        let (root, store) = try fixture()
        var draft = try store.createDraft()
        draft.note.thought = "Original"
        try store.attach(Data("old image".utf8), fileExtension: "jpg", to: &draft, kind: .image)
        let original = try store.commit(draft)
        var edit = try store.editDraft(noteID: original.id)
        let stagingPath = root.appendingPathComponent("drafts/\(edit.id.uuidString)")
        if FileManager.default.fileExists(atPath: stagingPath.path) { try FileManager.default.removeItem(at: stagingPath) }
        try Data("blocks directory".utf8).write(to: stagingPath)
        XCTAssertThrowsError(try store.attach(Data("replacement".utf8), fileExtension: "jpg", to: &edit, kind: .image))
        XCTAssertEqual(edit.note.imageName, original.imageName)
        XCTAssertEqual(try Data(contentsOf: store.assetURL(noteID: original.id, name: try XCTUnwrap(original.imageName))), Data("old image".utf8))
        XCTAssertEqual(try store.list().single?.revision, 1)
    }

    func testInvalidTextURLAndFileNameAreRejected() throws {
        let (_, store) = try fixture()
        var draft = try store.createDraft()
        draft.note.sourceText = String(repeating: "a", count: 100_001)
        XCTAssertThrowsError(try store.saveDraft(draft))
        draft.note.sourceText = ""
        draft.note.sourceURL = "javascript:alert(1)"
        XCTAssertThrowsError(try store.commit(draft))
        draft.note.sourceURL = "https://example.org/article"
        draft.note.imageName = "../escape.jpg"
        XCTAssertThrowsError(try store.commit(draft))
    }

    func testCorruptMetadataIsAnErrorInsteadOfAnEmptyLibrary() throws {
        let (root, store) = try fixture()
        let notes = root.appendingPathComponent("notes", isDirectory: true)
        try Data("not json".utf8).write(to: notes.appendingPathComponent(UUID().uuidString + ".json"))
        XCTAssertThrowsError(try store.list())
    }

    func testCommitReportsCorruptExistingRecordWithoutOverwritingIt() throws {
        let (root, store) = try fixture()
        var draft = try store.createDraft()
        draft.note.thought = "Should remain a draft"
        let recordPath = root.appendingPathComponent("notes/\(draft.note.id.uuidString).json")
        try Data("broken".utf8).write(to: recordPath)
        XCTAssertThrowsError(try store.commit(draft)) { error in
            guard case .corruptData = error as? NoteStoreError else { return XCTFail("Expected corruption, got \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: recordPath), Data("broken".utf8))
    }

    func testSourceOnlySearchExportAndDeletion() throws {
        let (root, store) = try fixture()
        var draft = try store.createDraft()
        draft.note.sourceURL = "https://example.org/path"
        XCTAssertTrue(draft.note.hasContent)
        try store.attach(Data("voice".utf8), fileExtension: "m4a", to: &draft, kind: .audio)
        let note = try store.commit(draft)
        XCTAssertEqual(try store.search("example").map(\.id), [note.id])
        let destination = root.appendingPathComponent("exports")
        let package = try store.export(to: destination)
        XCTAssertTrue(try String(contentsOf: package.appendingPathComponent("index.txt"), encoding: .utf8).contains("https://example.org/path"))
        XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent("media/")
            .appendingPathComponent(note.id.uuidString).appendingPathComponent(try XCTUnwrap(note.audioName))), Data("voice".utf8))
        try store.delete(noteID: note.id)
        XCTAssertTrue(try store.list().isEmpty)
        XCTAssertThrowsError(try store.assetURL(noteID: note.id, name: try XCTUnwrap(note.audioName)))
    }
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}
