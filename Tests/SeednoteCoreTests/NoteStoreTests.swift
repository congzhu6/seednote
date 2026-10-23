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

    func testCommittedEditRemovesReplacedAndRemovedAttachments() throws {
        let (root, store) = try fixture()
        var draft = try store.createDraft()
        draft.note.thought = "Replace the media"
        try store.attach(Data("first image".utf8), fileExtension: "jpg", to: &draft, kind: .image)
        try store.attach(Data("first audio".utf8), fileExtension: "m4a", to: &draft, kind: .audio)
        let original = try store.commit(draft)
        let folder = root.appendingPathComponent("assets/\(original.id.uuidString)")

        var edit = try store.editDraft(noteID: original.id)
        try store.attach(Data("second audio".utf8), fileExtension: "m4a", to: &edit, kind: .audio)
        edit.note.imageName = nil
        try store.saveDraft(edit)
        let saved = try store.commit(edit)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(remaining, [try XCTUnwrap(saved.audioName)])
        XCTAssertEqual(try Data(contentsOf: store.assetURL(noteID: saved.id, name: XCTUnwrap(saved.audioName))), Data("second audio".utf8))
    }

    func testCommitKeepsAttachmentAnotherDraftOfTheSameIdeaStillReferences() throws {
        let (root, store) = try fixture()
        var draft = try store.createDraft()
        draft.note.thought = "Two edits at once"
        try store.attach(Data("shared image".utf8), fileExtension: "jpg", to: &draft, kind: .image)
        let original = try store.commit(draft)
        let imageName = try XCTUnwrap(original.imageName)
        // A draft recorded before edits owned their own copies refers to the record's file.
        let older = NoteDraft(note: original, baseRevision: original.revision)
        let olderData = try JSONEncoder().encode(older)
        try olderData.write(to: root.appendingPathComponent("drafts/\(older.id.uuidString).json"))

        var edit = try store.editDraft(noteID: original.id)
        edit.note.imageName = nil
        try store.saveDraft(edit)
        _ = try store.commit(edit)

        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("assets/\(original.id.uuidString)/\(imageName)").path))
    }

    func testRemoveOrphanedAssetsKeepsReferencedAndUnreadableMedia() throws {
        let (root, store) = try fixture()
        let assets = root.appendingPathComponent("assets")
        var draft = try store.createDraft()
        draft.note.thought = "Keep referenced media"
        try store.attach(Data("kept".utf8), fileExtension: "jpg", to: &draft, kind: .image)
        let saved = try store.commit(draft)
        let savedFolder = assets.appendingPathComponent(saved.id.uuidString)
        // Leftovers from an interrupted copy and a record that no longer exists.
        try Data("partial".utf8).write(to: savedFolder.appendingPathComponent(UUID().uuidString + ".tmp"))
        let orphan = assets.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data("orphan".utf8).write(to: orphan.appendingPathComponent(UUID().uuidString + ".jpg"))
        // A record that cannot be read may still own its folder.
        let damagedID = UUID()
        try Data("{".utf8).write(to: root.appendingPathComponent("notes/\(damagedID.uuidString).json"))
        let damagedFolder = assets.appendingPathComponent(damagedID.uuidString)
        try FileManager.default.createDirectory(at: damagedFolder, withIntermediateDirectories: true)
        try Data("unknown".utf8).write(to: damagedFolder.appendingPathComponent(UUID().uuidString + ".jpg"))

        try store.removeOrphanedAssets()

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: savedFolder.path), [try XCTUnwrap(saved.imageName)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: damagedFolder.path).count, 1)
    }

    func testRemoveOrphanedAssetsDoesNothingWhileADraftIsUnreadable() throws {
        let (root, store) = try fixture()
        let orphan = root.appendingPathComponent("assets/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data("maybe needed".utf8).write(to: orphan.appendingPathComponent(UUID().uuidString + ".jpg"))
        try Data("{".utf8).write(to: root.appendingPathComponent("drafts/\(UUID().uuidString).json"))

        try store.removeOrphanedAssets()

        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))
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

    func testCorruptMetadataIsReportedWithoutHidingReadableRecords() throws {
        let (root, store) = try fixture()
        var draft = try store.createDraft()
        draft.note.thought = "Still readable"
        let saved = try store.commit(draft)
        var pending = try store.createDraft()
        pending.note.thought = "Pending draft"
        try store.saveDraft(pending)

        let brokenNote = root.appendingPathComponent("notes/\(UUID().uuidString).json")
        let brokenDraft = root.appendingPathComponent("drafts/\(UUID().uuidString).json")
        try Data("not json".utf8).write(to: brokenNote)
        try Data("not json".utf8).write(to: brokenDraft)

        XCTAssertEqual(try store.list().map(\.id), [saved.id])
        XCTAssertEqual(try store.pendingDrafts().map(\.id), [pending.id])
        let library = try store.library()
        XCTAssertEqual(library.notes.map(\.id), [saved.id])
        XCTAssertEqual(library.drafts.map(\.id), [pending.id])
        XCTAssertEqual(Set(library.unreadableFiles), [brokenNote.lastPathComponent, brokenDraft.lastPathComponent])
        // Damaged files are reported, never deleted or rewritten.
        XCTAssertEqual(try Data(contentsOf: brokenNote), Data("not json".utf8))
        XCTAssertEqual(try Data(contentsOf: brokenDraft), Data("not json".utf8))
    }

    func testWebLinkIsTheSingleRuleForSavedLinks() throws {
        XCTAssertNotNil(WebLink.url(from: "https://example.org/a?b=1"))
        XCTAssertNotNil(WebLink.url(from: "HTTP://example.org"))
        for rejected in ["javascript:alert(1)", "ftp://example.org", "https://", "example.org",
                         "https://user:secret@example.org", " https://example.org"] {
            XCTAssertNil(WebLink.url(from: rejected), rejected)
        }
        let (_, store) = try fixture()
        var draft = try store.createDraft()
        draft.note.thought = "Link with credentials"
        draft.note.sourceURL = "https://user:secret@example.org"
        XCTAssertThrowsError(try store.saveDraft(draft)) { error in
            XCTAssertEqual(error as? NoteStoreError, .invalidInput("webURL"))
        }
    }

    func testRecognitionStatusKeepsTheStoredStrings() {
        var note = SeedNote()
        XCTAssertEqual(note.transcriptState, .notStarted)
        note.transcriptState = .interrupted
        note.ocrState = .complete
        XCTAssertEqual(note.transcriptStatus, "interrupted")
        XCTAssertEqual(note.ocrStatus, "complete")
        XCTAssertTrue(note.transcriptState.didNotFinish)
        XCTAssertFalse(note.ocrState.didNotFinish)
        note.ocrStatus = "unavailable"
        XCTAssertEqual(note.ocrState, .unavailable)
    }

    func testRecordsWrittenBeforeNewerFieldsStillLoad() throws {
        let (root, store) = try fixture()
        var draft = try store.createDraft()
        draft.note.thought = "Written by an early build"
        let saved = try store.commit(draft)
        let path = root.appendingPathComponent("notes/\(saved.id.uuidString).json")
        var stored = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        var note = try XCTUnwrap(stored["note"] as? [String: Any])
        for key in ["origin", "transcriptStatus", "ocrStatus", "ocrText", "audioDuration"] { note.removeValue(forKey: key) }
        stored["note"] = note
        stored.removeValue(forKey: "schemaVersion")
        try JSONSerialization.data(withJSONObject: stored).write(to: path)

        let loaded = try XCTUnwrap(store.list().single)
        XCTAssertEqual(loaded.id, saved.id)
        XCTAssertEqual(loaded.thought, "Written by an early build")
        XCTAssertEqual(loaded.ocrStatus, "")
        XCTAssertEqual(loaded.audioDuration, 0)
        XCTAssertTrue(try store.library().unreadableFiles.isEmpty)
        // Editing and saving again upgrades the record in place.
        var edit = try store.editDraft(noteID: saved.id)
        edit.note.thought = "Edited later"
        XCTAssertEqual(try store.commit(edit).revision, 2)
    }

    func testRecordFromNewerSchemaIsReportedAndNeverOverwritten() throws {
        let (root, store) = try fixture()
        var draft = try store.createDraft()
        draft.note.thought = "From the future"
        let saved = try store.commit(draft)
        let path = root.appendingPathComponent("notes/\(saved.id.uuidString).json")
        var stored = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        stored["schemaVersion"] = 99
        let newer = try JSONSerialization.data(withJSONObject: stored)
        try newer.write(to: path)

        XCTAssertTrue(try store.list().isEmpty)
        XCTAssertEqual(try store.library().unreadableFiles, [path.lastPathComponent])
        XCTAssertThrowsError(try store.editDraft(noteID: saved.id)) { error in
            XCTAssertEqual(error as? NoteStoreError, .newerFormat(path.lastPathComponent))
        }
        XCTAssertEqual(try Data(contentsOf: path), newer)
    }

    func testExportSkipsMissingAttachmentAndNamesUnreadableFiles() throws {
        let (root, store) = try fixture()
        var lost = try store.createDraft()
        lost.note.thought = "Image went missing"
        try store.attach(Data("image".utf8), fileExtension: "jpg", to: &lost, kind: .image)
        let lostNote = try store.commit(lost)
        var kept = try store.createDraft()
        kept.note.thought = "Audio is fine"
        try store.attach(Data("voice".utf8), fileExtension: "m4a", to: &kept, kind: .audio)
        let keptNote = try store.commit(kept)
        let imageName = try XCTUnwrap(lostNote.imageName)
        try FileManager.default.removeItem(at: store.assetURL(noteID: lostNote.id, name: imageName))
        let broken = UUID().uuidString + ".json"
        try Data("not json".utf8).write(to: root.appendingPathComponent("notes/\(broken)"))

        let package = try store.export(to: root.appendingPathComponent("exports"), languageCode: "en-US")
        let index = try String(contentsOf: package.appendingPathComponent("index.txt"), encoding: .utf8)
        XCTAssertTrue(index.contains("2 saved ideas"))
        XCTAssertTrue(index.contains("Image went missing"))
        XCTAssertTrue(index.contains("Attachment unavailable: \(imageName)"))
        XCTAssertTrue(index.contains("Unreadable files not exported: \(broken)"))
        let audio = package.appendingPathComponent("media/\(keptNote.id.uuidString)/\(try XCTUnwrap(keptNote.audioName))")
        XCTAssertEqual(try Data(contentsOf: audio), Data("voice".utf8))
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
