import Foundation

public enum CaptureSetupOrigin: String, CaseIterable, Codable, Sendable {
    case screenshotShortcut = "shortcutScreenshot"
    case shareShortcut = "shortcutShare"
    case manual = "manual"

    fileprivate init?(noteOrigin: String) {
        switch noteOrigin.trimmingCharacters(in: .whitespacesAndNewlines) {
        case Self.screenshotShortcut.rawValue:
            self = .screenshotShortcut
        case Self.shareShortcut.rawValue:
            self = .shareShortcut
        case "", Self.manual.rawValue:
            self = .manual
        default:
            return nil
        }
    }
}

public enum CaptureSetupStatus: String, Codable, Sendable {
    case notStarted
    case savedAwaitingReopen
    case verified
}

public struct CaptureSetupProgress: Equatable, Sendable {
    public let origin: CaptureSetupOrigin
    public let status: CaptureSetupStatus
    public let pendingNoteID: UUID?
    public let verifiedNoteID: UUID?
    public let lastSavedAt: Date?
    public let verifiedAt: Date?
}

/// Stores only note identifiers, timestamps and capture origins on this device.
/// A path is verified only when the exact record saved for that path is opened.
public final class CaptureSetupTracker: @unchecked Sendable {
    public static let shared: CaptureSetupTracker = {
        let arguments = ProcessInfo.processInfo.arguments
        let isUITesting = arguments.contains("--uitesting")
        let defaults: UserDefaults
        if isUITesting {
            defaults = UserDefaults(suiteName: "com.seednote.capture-setup.uitesting") ?? .standard
        } else {
            defaults = .standard
        }
        let tracker = CaptureSetupTracker(defaults: defaults)
        if isUITesting, arguments.contains("--reset-test-store") {
            defaults.removeObject(forKey: tracker.storageKey)
        }
        return tracker
    }()

    private struct Entry: Codable {
        var pendingNoteIDs: [UUID] = []
        var verifiedNoteID: UUID? = nil
        var lastSavedAt: Date? = nil
        var verifiedAt: Date? = nil

        private enum CodingKeys: String, CodingKey {
            case pendingNoteIDs, pendingNoteID, verifiedNoteID, lastSavedAt, verifiedAt
        }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            pendingNoteIDs = try container.decodeIfPresent([UUID].self, forKey: .pendingNoteIDs)
                ?? container.decodeIfPresent(UUID.self, forKey: .pendingNoteID).map { [$0] }
                ?? []
            verifiedNoteID = try container.decodeIfPresent(UUID.self, forKey: .verifiedNoteID)
            lastSavedAt = try container.decodeIfPresent(Date.self, forKey: .lastSavedAt)
            verifiedAt = try container.decodeIfPresent(Date.self, forKey: .verifiedAt)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(pendingNoteIDs, forKey: .pendingNoteIDs)
            try container.encodeIfPresent(verifiedNoteID, forKey: .verifiedNoteID)
            try container.encodeIfPresent(lastSavedAt, forKey: .lastSavedAt)
            try container.encodeIfPresent(verifiedAt, forKey: .verifiedAt)
        }
    }

    private struct StoredState: Codable {
        var entries: [String: Entry] = [:]
    }

    private let defaults: UserDefaults
    private let storageKey: String
    private let lock = NSLock()

    public init(defaults: UserDefaults, storageKey: String = "CaptureSetupProgress.v1") {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    public func progress(for origin: CaptureSetupOrigin) -> CaptureSetupProgress {
        lock.lock()
        defer { lock.unlock() }
        let entry = load().entries[origin.rawValue]
        let status: CaptureSetupStatus
        if entry?.verifiedNoteID != nil {
            status = .verified
        } else if entry?.pendingNoteIDs.isEmpty == false {
            status = .savedAwaitingReopen
        } else {
            status = .notStarted
        }
        return CaptureSetupProgress(
            origin: origin,
            status: status,
            pendingNoteID: entry?.pendingNoteIDs.last,
            verifiedNoteID: entry?.verifiedNoteID,
            lastSavedAt: entry?.lastSavedAt,
            verifiedAt: entry?.verifiedAt
        )
    }

    public func recordSaved(_ note: SeedNote) {
        guard let origin = CaptureSetupOrigin(noteOrigin: note.origin) else { return }
        lock.lock()
        defer { lock.unlock() }
        var state = load()
        var entry = state.entries[origin.rawValue] ?? Entry()
        entry.lastSavedAt = Date()
        if entry.verifiedNoteID == nil, !entry.pendingNoteIDs.contains(note.id) {
            entry.pendingNoteIDs.append(note.id)
        }
        state.entries[origin.rawValue] = entry
        save(state)
    }

    public func recordOpened(_ note: SeedNote) {
        guard let origin = CaptureSetupOrigin(noteOrigin: note.origin) else { return }
        lock.lock()
        defer { lock.unlock() }
        var state = load()
        guard var entry = state.entries[origin.rawValue], entry.pendingNoteIDs.contains(note.id) else { return }
        entry.pendingNoteIDs = []
        entry.verifiedNoteID = note.id
        entry.verifiedAt = Date()
        state.entries[origin.rawValue] = entry
        save(state)
    }

    private func load() -> StoredState {
        guard let data = defaults.data(forKey: storageKey),
              let state = try? JSONDecoder().decode(StoredState.self, from: data) else {
            return StoredState()
        }
        return state
    }

    private func save(_ state: StoredState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
