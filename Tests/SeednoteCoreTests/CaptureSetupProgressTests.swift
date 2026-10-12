import XCTest
@testable import SeednoteCore

final class CaptureSetupProgressTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "CaptureSetupProgressTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testSavingARecognizedOriginWaitsForTheSameNoteToBeOpened() {
        let tracker = CaptureSetupTracker(defaults: defaults)
        let saved = SeedNote(origin: "shortcutScreenshot")

        tracker.recordSaved(saved)

        let progress = tracker.progress(for: .screenshotShortcut)
        XCTAssertEqual(progress.status, .savedAwaitingReopen)
        XCTAssertEqual(progress.pendingNoteID, saved.id)
        XCTAssertNil(progress.verifiedAt)
    }

    func testOpeningTheSavedNoteVerifiesThatOrigin() {
        let tracker = CaptureSetupTracker(defaults: defaults)
        let saved = SeedNote(origin: "shortcutShare")
        tracker.recordSaved(saved)

        tracker.recordOpened(saved)

        let progress = tracker.progress(for: .shareShortcut)
        XCTAssertEqual(progress.status, .verified)
        XCTAssertEqual(progress.verifiedNoteID, saved.id)
        XCTAssertNil(progress.pendingNoteID)
    }

    func testOpeningAnotherNoteOrAnotherOriginDoesNotVerifyPendingCapture() {
        let tracker = CaptureSetupTracker(defaults: defaults)
        let pending = SeedNote(origin: "shortcutScreenshot")
        tracker.recordSaved(pending)

        tracker.recordOpened(SeedNote(origin: "shortcutScreenshot"))
        tracker.recordOpened(SeedNote(id: pending.id, origin: "shortcutShare"))

        XCTAssertEqual(tracker.progress(for: .screenshotShortcut).status, .savedAwaitingReopen)
        XCTAssertEqual(tracker.progress(for: .shareShortcut).status, .notStarted)
    }

    func testProgressPersistsAcrossTrackerInstances() {
        let saved = SeedNote(origin: "shortcutShare")
        let first = CaptureSetupTracker(defaults: defaults)
        first.recordSaved(saved)
        first.recordOpened(saved)

        let reopened = CaptureSetupTracker(defaults: defaults)

        XCTAssertEqual(reopened.progress(for: .shareShortcut).status, .verified)
        XCTAssertEqual(reopened.progress(for: .shareShortcut).verifiedNoteID, saved.id)
    }

    func testOpeningAnyPreviouslySavedNoteCanVerifyItsOrigin() {
        let tracker = CaptureSetupTracker(defaults: defaults)
        let first = SeedNote(origin: "shortcutShare")
        let second = SeedNote(origin: "shortcutShare")
        tracker.recordSaved(first)
        tracker.recordSaved(second)

        tracker.recordOpened(first)

        XCTAssertEqual(tracker.progress(for: .shareShortcut).status, .verified)
        XCTAssertEqual(tracker.progress(for: .shareShortcut).verifiedNoteID, first.id)
    }

    func testTheThreePathsKeepIndependentProgress() {
        let tracker = CaptureSetupTracker(defaults: defaults)
        let screenshot = SeedNote(origin: "shortcutScreenshot")
        let share = SeedNote(origin: "shortcutShare")
        let manual = SeedNote(origin: "")
        tracker.recordSaved(screenshot)
        tracker.recordSaved(share)
        tracker.recordSaved(manual)
        tracker.recordOpened(screenshot)

        XCTAssertEqual(tracker.progress(for: .screenshotShortcut).status, .verified)
        XCTAssertEqual(tracker.progress(for: .shareShortcut).status, .savedAwaitingReopen)
        XCTAssertEqual(tracker.progress(for: .manual).status, .savedAwaitingReopen)
    }

    func testUnknownIntentOriginCannotMarkAnyPath() {
        let tracker = CaptureSetupTracker(defaults: defaults)
        let genericIntentNote = SeedNote(origin: "intent")

        tracker.recordSaved(genericIntentNote)
        tracker.recordOpened(genericIntentNote)

        for origin in CaptureSetupOrigin.allCases {
            XCTAssertEqual(tracker.progress(for: origin).status, .notStarted)
        }
    }
}
