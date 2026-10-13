import Foundation

/// A per-record JSON commit is the durable point of truth. Assets are copied first;
/// orphaned copies from an interrupted commit are harmless and can be retried.
public final class NoteStore: @unchecked Sendable {
    // Covers separate instances of the same root in this process, including read-modify-write.
    private static let operationLock = NSRecursiveLock()
    private let root: URL
    private let files = FileManager.default

    public init(root: URL) throws {
        self.root = root.standardizedFileURL
        try Self.operationLock.withLock {
            for folder in [self.root, notesDirectory, draftsDirectory, assetsDirectory] {
                try files.createDirectory(at: folder, withIntermediateDirectories: true)
            }
        }
    }

    public func createDraft() throws -> NoteDraft {
        try Self.operationLock.withLock {
            let draft = NoteDraft()
            try write(draft, to: draftMetadata(draft.id))
            return draft
        }
    }

    public func editDraft(noteID: UUID) throws -> NoteDraft {
        try Self.operationLock.withLock {
            let note = try record(noteID).note
            let draft = NoteDraft(note: note, baseRevision: note.revision)
            // A recoverable edit must own copies of its inherited media. The user
            // may delete the formal record while keeping this draft for later.
            let staged = stagedDirectory(draft.id)
            do {
                try files.createDirectory(at: staged, withIntermediateDirectories: true)
                for name in [note.imageName, note.audioName].compactMap({ $0 }) {
                    try validateFileName(name)
                    let source = assetsDirectory.appendingPathComponent(noteID.uuidString).appendingPathComponent(name)
                    do {
                        try files.copyItem(at: source, to: staged.appendingPathComponent(name))
                    } catch where isMissingFileError(error) {
                        // Keep the reference in the draft so the editor can show the
                        // unavailable attachment and require explicit removal/replacement.
                    }
                }
                try write(draft, to: draftMetadata(draft.id))
                return draft
            } catch {
                try? files.removeItem(at: staged)
                throw error
            }
        }
    }

    public func saveDraft(_ draft: NoteDraft) throws {
        try Self.operationLock.withLock {
            let previous = try storedDraft(draft.id)
            guard previous.note.id == draft.note.id, previous.baseRevision == draft.baseRevision else {
                throw NoteStoreError.conflict
            }
            if files.fileExists(atPath: noteMetadata(draft.note.id).path) {
                let existing = try record(draft.note.id)
                if existing.committedDraftID == draft.id { throw NoteStoreError.conflict }
            }
            try validate(draft.note)
            var refreshed = draft
            refreshed.note.updatedAt = Date()
            try write(refreshed, to: draftMetadata(draft.id))
        }
    }

    public func rebaseDraftAsNew(_ draft: NoteDraft) throws -> NoteDraft {
        try Self.operationLock.withLock {
            let stored = try storedDraft(draft.id)
            guard stored.note.id == draft.note.id, stored.baseRevision == draft.baseRevision else {
                throw NoteStoreError.conflict
            }
            if files.fileExists(atPath: noteMetadata(draft.note.id).path),
               try record(draft.note.id).committedDraftID == draft.id {
                throw NoteStoreError.conflict
            }
            // A nil base already identifies a new-record draft. Returning the durable
            // value makes a retry idempotent instead of assigning another record ID.
            guard draft.baseRevision != nil else { return stored }
            try validate(draft.note)
            var rebased = draft
            rebased.note.id = UUID()
            rebased.baseRevision = nil
            // Atomic replacement is the transition boundary. Staged media stays under
            // the unchanged draft ID, so a failed write leaves the prior draft usable.
            try write(rebased, to: draftMetadata(draft.id))
            return rebased
        }
    }

    public func pendingDrafts() throws -> [NoteDraft] {
        try Self.operationLock.withLock { try readDrafts().drafts }
    }

    /// Loads saved ideas and drafts in one pass. A damaged file is skipped and named in
    /// `unreadableFiles` instead of failing the whole library; the file itself is kept.
    public func library() throws -> NoteLibrary {
        try Self.operationLock.withLock {
            let notes = try readNotes()
            let drafts = try readDrafts()
            return NoteLibrary(notes: notes.notes, drafts: drafts.drafts, unreadableFiles: notes.unreadable + drafts.unreadable)
        }
    }

    public func attach(_ data: Data, fileExtension: String, to draft: inout NoteDraft, kind: AttachmentKind) throws {
        try Self.operationLock.withLock {
            _ = try storedDraft(draft.id)
            let suffix = fileExtension.lowercased()
            guard (1...8).contains(suffix.count), suffix.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else {
                throw NoteStoreError.invalidInput("attachmentExtension")
            }
            let limit = kind == .image ? 20_000_000 : 100_000_000
            guard !data.isEmpty, data.count <= limit else { throw NoteStoreError.invalidInput("attachmentSize") }
            let name = UUID().uuidString + "." + suffix
            let directory = stagedDirectory(draft.id)
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
            // Assign the new name only after a complete write. The earlier attachment stays intact.
            switch kind {
            case .image: draft.note.imageName = name
            case .audio: draft.note.audioName = name
            }
        }
    }

    public func draftAssetURL(_ draft: NoteDraft, name: String) throws -> URL {
        try Self.operationLock.withLock {
            try validateFileName(name)
            guard draft.note.imageName == name || draft.note.audioName == name else { throw NoteStoreError.notFound }
            _ = try storedDraft(draft.id)
            let staged = stagedDirectory(draft.id).appendingPathComponent(name)
            if files.fileExists(atPath: staged.path) { return staged }
            if draft.baseRevision != nil { return try assetURL(noteID: draft.note.id, name: name) }
            throw NoteStoreError.missingMedia(name)
        }
    }

    /// Lock-free lookup for rendering an already loaded record. Attachment names are
    /// validated UUID file names and never rewritten, so no metadata read is needed.
    public func existingAssetURL(for note: SeedNote, name: String) -> URL? {
        guard note.imageName == name || note.audioName == name, (try? validateFileName(name)) != nil else { return nil }
        let url = assetsDirectory.appendingPathComponent(note.id.uuidString).appendingPathComponent(name)
        return files.fileExists(atPath: url.path) ? url : nil
    }

    public func assetURL(noteID: UUID, name: String) throws -> URL {
        try Self.operationLock.withLock {
            try validateFileName(name)
            let note = try record(noteID).note
            guard note.imageName == name || note.audioName == name else { throw NoteStoreError.notFound }
            let url = assetsDirectory.appendingPathComponent(noteID.uuidString).appendingPathComponent(name)
            guard files.fileExists(atPath: url.path) else { throw NoteStoreError.missingMedia(name) }
            return url
        }
    }

    public func commit(_ draft: NoteDraft) throws -> SeedNote {
        try Self.operationLock.withLock {
            // The marker and note are in the same atomic JSON replacement. A retry after
            // an interrupted draft cleanup can only return this exact committed version.
            if files.fileExists(atPath: noteMetadata(draft.note.id).path) {
                let previous = try record(draft.note.id)
                if previous.committedDraftID == draft.id {
                    try? cleanupDraft(draft.id)
                    return previous.note
                }
            }
            let stored = try storedDraft(draft.id)
            guard stored.note.id == draft.note.id, stored.baseRevision == draft.baseRevision else {
                throw NoteStoreError.conflict
            }
            try validate(draft.note)
            guard draft.note.hasContent else { throw NoteStoreError.invalidInput("emptyNote") }
            let old: StoredNote?
            if let baseRevision = draft.baseRevision {
                let current = try record(draft.note.id)
                guard current.note.revision == baseRevision else { throw NoteStoreError.conflict }
                old = current
            } else {
                guard !files.fileExists(atPath: noteMetadata(draft.note.id).path) else { throw NoteStoreError.conflict }
                old = nil
            }
            // Copy staged files to unique immutable names. Existing references for edits
            // remain valid until the new metadata is safely committed.
            for name in [draft.note.imageName, draft.note.audioName].compactMap({ $0 }) {
                let target = assetsDirectory.appendingPathComponent(draft.note.id.uuidString).appendingPathComponent(name)
                if files.fileExists(atPath: target.path) {
                    if old?.note.imageName == name || old?.note.audioName == name { continue }
                    // This is a copied but uncommitted attachment from an earlier
                    // attempt. Only reuse it when the staged source is identical.
                    let staged = stagedDirectory(draft.id).appendingPathComponent(name)
                    guard files.fileExists(atPath: staged.path),
                          files.contentsEqual(atPath: staged.path, andPath: target.path) else {
                        throw NoteStoreError.conflict
                    }
                    continue
                }
                let staged = stagedDirectory(draft.id).appendingPathComponent(name)
                guard files.fileExists(atPath: staged.path) else { throw NoteStoreError.missingMedia(name) }
                try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let temp = target.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".tmp")
                try files.copyItem(at: staged, to: temp)
                do { try files.moveItem(at: temp, to: target) }
                catch { try? files.removeItem(at: temp); throw error }
            }
            var note = draft.note
            note.revision = (old?.note.revision ?? 0) + 1
            note.createdAt = old?.note.createdAt ?? Date()
            note.updatedAt = Date()
            try write(StoredNote(note: note, committedDraftID: draft.id), to: noteMetadata(note.id))
            // Failure after this point is a successful commit. Leave draft cleanup best effort.
            try? cleanupDraft(draft.id)
            return note
        }
    }

    public func cancel(_ draft: NoteDraft) throws {
        try Self.operationLock.withLock {
            _ = try storedDraft(draft.id)
            // Once metadata is gone, the draft is discarded. Failure to remove
            // stray staged bytes must not strand the editor in an unretryable state.
            try files.removeItem(at: draftMetadata(draft.id))
            let staged = stagedDirectory(draft.id)
            if files.fileExists(atPath: staged.path) { try? files.removeItem(at: staged) }
        }
    }

    /// Readable saved ideas, newest first. Use `library()` to learn which files were skipped.
    public func list() throws -> [SeedNote] {
        try Self.operationLock.withLock { try readNotes().notes }
    }

    public func search(_ text: String) throws -> [SeedNote] {
        try list().filter { text.isEmpty || $0.searchableText.localizedCaseInsensitiveContains(text) }
    }

    public func delete(noteID: UUID) throws {
        try Self.operationLock.withLock {
            _ = try record(noteID)
            // Commit deletion by removing metadata first; any interrupted cleanup only
            // leaves orphan assets and never accidentally removes another record.
            try files.removeItem(at: noteMetadata(noteID))
            let media = assetsDirectory.appendingPathComponent(noteID.uuidString)
            // The record is already deleted. A media cleanup failure may leave
            // orphan bytes, but must not report an error the user cannot retry.
            if files.fileExists(atPath: media.path) { try? files.removeItem(at: media) }
        }
    }

    public func export(to directory: URL, languageCode: String = Bundle.main.preferredLocalizations.first ?? "en") throws -> URL {
        // Snapshot the records under the lock, then copy media outside it so a large export
        // never blocks drafting. Committed attachment files are immutable once named.
        let snapshot = try Self.operationLock.withLock { try readNotes() }
        let notes = snapshot.notes
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let package = directory.appendingPathComponent("Seednote-export-" + UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: package, withIntermediateDirectories: false)
        do {
            func label(_ english: String, _ chinese: String) -> String {
                CoreText.choose(english, chinese, languageCode: languageCode)
            }
            var index = label("Seednote export", "Seednote 导出资料") + "\n"
            index += label("\(notes.count) saved \(notes.count == 1 ? "idea" : "ideas")", "共 \(notes.count) 条记录") + "\n"
            if !snapshot.unreadable.isEmpty {
                index += label("Unreadable files not exported: ", "无法读取、未导出的文件：") + snapshot.unreadable.joined(separator: ", ") + "\n"
            }
            index += "\n"
            for note in notes {
                index += "—— \(note.id.uuidString) ——\n\(note.writingCard(languageCode: languageCode))\n"
                index += label("Origin: ", "来源：") + note.origin + "\n"
                index += label("Created: ", "创建时间：") + CoreText.date(note.createdAt, languageCode: languageCode) + "\n"
                for name in [note.imageName, note.audioName].compactMap({ $0 }) {
                    let relative = "media/\(note.id.uuidString)/\(name)"
                    let target = package.appendingPathComponent(relative)
                    // A missing attachment must not block exporting everything else.
                    if let source = existingAssetURL(for: note, name: name) {
                        do {
                            try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                            try files.copyItem(at: source, to: target)
                            index += label("Attachment: ", "附件：") + relative + "\n"
                            continue
                        } catch where isMissingFileError(error) {}
                    }
                    index += label("Attachment unavailable: ", "附件不可用：") + name + "\n"
                }
                index += "\n"
            }
            try index.write(to: package.appendingPathComponent("index.txt"), atomically: true, encoding: .utf8)
            return package
        } catch {
            try? files.removeItem(at: package)
            throw error
        }
    }

    private struct StoredNote: Codable {
        /// Bump when a change cannot be read by older builds; they then report the
        /// record as unreadable instead of misreading or overwriting it.
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let note: SeedNote
        let committedDraftID: UUID

        init(note: SeedNote, committedDraftID: UUID) {
            schemaVersion = Self.currentSchemaVersion
            self.note = note
            self.committedDraftID = committedDraftID
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Records written before versioning have no key and are version 1.
            schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            note = try container.decode(SeedNote.self, forKey: .note)
            committedDraftID = try container.decode(UUID.self, forKey: .committedDraftID)
        }
    }

    private var notesDirectory: URL { root.appendingPathComponent("notes", isDirectory: true) }
    private var draftsDirectory: URL { root.appendingPathComponent("drafts", isDirectory: true) }
    private var assetsDirectory: URL { root.appendingPathComponent("assets", isDirectory: true) }
    private func noteMetadata(_ id: UUID) -> URL { notesDirectory.appendingPathComponent(id.uuidString + ".json") }
    private func draftMetadata(_ id: UUID) -> URL { draftsDirectory.appendingPathComponent(id.uuidString + ".json") }
    private func stagedDirectory(_ id: UUID) -> URL { draftsDirectory.appendingPathComponent(id.uuidString, isDirectory: true) }

    private func cleanupDraft(_ id: UUID) throws {
        let metadata = draftMetadata(id)
        if files.fileExists(atPath: metadata.path) { try files.removeItem(at: metadata) }
        let media = stagedDirectory(id)
        if files.fileExists(atPath: media.path) { try files.removeItem(at: media) }
    }

    private func storedDraft(_ id: UUID) throws -> NoteDraft {
        let path = draftMetadata(id)
        guard files.fileExists(atPath: path.path) else { throw NoteStoreError.notFound }
        do { return try read(NoteDraft.self, from: path) }
        catch { throw NoteStoreError.corruptData(path.lastPathComponent) }
    }

    private func record(_ id: UUID) throws -> StoredNote {
        let path = noteMetadata(id)
        guard files.fileExists(atPath: path.path) else { throw NoteStoreError.notFound }
        return try record(at: path, expectedID: id)
    }

    private struct VersionProbe: Decodable { let schemaVersion: Int? }

    private func record(at path: URL, expectedID: UUID) throws -> StoredNote {
        let data: Data
        do { data = try Data(contentsOf: path) } catch { throw NoteStoreError.corruptData(path.lastPathComponent) }
        // Check the version before the full decode so a newer layout is never misreported as damage.
        if let probe = try? JSONDecoder().decode(VersionProbe.self, from: data),
           (probe.schemaVersion ?? 1) > StoredNote.currentSchemaVersion {
            throw NoteStoreError.newerFormat(path.lastPathComponent)
        }
        do {
            let stored = try JSONDecoder().decode(StoredNote.self, from: data)
            guard stored.note.id == expectedID else { throw NoteStoreError.corruptData(path.lastPathComponent) }
            return stored
        } catch { throw NoteStoreError.corruptData(path.lastPathComponent) }
    }

    private func readNotes() throws -> (notes: [SeedNote], unreadable: [String]) {
        var notes: [SeedNote] = []
        var unreadable: [String] = []
        for path in try jsonFiles(in: notesDirectory) {
            guard let id = UUID(uuidString: path.deletingPathExtension().lastPathComponent),
                  let stored = try? record(at: path, expectedID: id) else {
                unreadable.append(path.lastPathComponent)
                continue
            }
            notes.append(stored.note)
        }
        return (notes.sorted { $0.createdAt > $1.createdAt }, unreadable.sorted())
    }

    private func readDrafts() throws -> (drafts: [NoteDraft], unreadable: [String]) {
        var drafts: [NoteDraft] = []
        var unreadable: [String] = []
        for path in try jsonFiles(in: draftsDirectory) {
            guard let draft = try? read(NoteDraft.self, from: path) else {
                unreadable.append(path.lastPathComponent)
                continue
            }
            // A draft whose commit already landed is finished; a damaged record cannot
            // prove that, so the draft stays recoverable.
            if files.fileExists(atPath: noteMetadata(draft.note.id).path),
               (try? record(draft.note.id))?.committedDraftID == draft.id {
                try? cleanupDraft(draft.id)
                continue
            }
            drafts.append(draft)
        }
        return (drafts.sorted { $0.note.updatedAt > $1.note.updatedAt }, unreadable.sorted())
    }

    private func jsonFiles(in directory: URL) throws -> [URL] {
        try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
    }

    private func read<T: Decodable>(_ type: T.Type, from path: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: path))
    }

    private func isMissingFileError(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain
            && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError)
    }

    private func write<T: Encodable>(_ value: T, to path: URL) throws {
        try JSONEncoder().encode(value).write(to: path, options: .atomic)
    }

    private func validateFileName(_ name: String) throws {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, UUID(uuidString: String(parts[0])) != nil,
              (1...8).contains(parts[1].count), parts[1].unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else {
            throw NoteStoreError.invalidInput("mediaName")
        }
    }

    private func validate(_ note: SeedNote) throws {
        for text in [note.sourceText, note.thought, note.transcript, note.ocrText] {
            guard text.count <= 100_000 else { throw NoteStoreError.invalidInput("textLength") }
        }
        if !note.sourceURL.isEmpty, WebLink.url(from: note.sourceURL) == nil {
            throw NoteStoreError.invalidInput("webURL")
        }
        for name in [note.imageName, note.audioName].compactMap({ $0 }) { try validateFileName(name) }
        guard note.audioDuration.isFinite, (0...180).contains(note.audioDuration) else {
            throw NoteStoreError.invalidInput("mediaDuration")
        }
    }
}
