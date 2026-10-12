import XCTest

final class InteractiveMediaTests: XCTestCase {
    func testTextOnlyArchiveReachesLocalFilesDestination() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reset-test-store", "--skip-welcome", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        app.buttons["newIdea"].tap()
        let thought = app.textViews["thoughtInput"]
        XCTAssertTrue(thought.waitForExistence(timeout: 5))
        thought.tap()
        thought.typeText("Seednote local Files export acceptance sample")
        app.buttons["saveIdea"].tap()
        XCTAssertTrue(app.buttons.matching(identifier: "noteRow").firstMatch.waitForExistence(timeout: 5))
        app.buttons["Settings"].tap()
        app.buttons["exportIdeas"].tap()
        let archive = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Seednote-export-'")).firstMatch
        XCTAssertTrue(archive.waitForExistence(timeout: 10))
        let archiveName = archive.label
        XCTAssertTrue(app.cells["Save to Files"].waitForExistence(timeout: 10))
        app.cells["Save to Files"].tap()
        XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 10))
        // The picker often defaults to iCloud Drive. Select the explicitly
        // local destination so this acceptance test does not upload its archive.
        let localRoot = app.otherElements.matching(NSPredicate(format: "identifier CONTAINS 'Title: On My iPhone'")).firstMatch
        if !localRoot.exists {
            let backToLocations = app.buttons.matching(identifier: "BackButton")
                .matching(NSPredicate(format: "label == 'iCloud Drive'")).firstMatch
            XCTAssertTrue(backToLocations.waitForExistence(timeout: 5))
            backToLocations.tap()
            let backToBrowse = app.buttons.matching(identifier: "BackButton")
                .matching(NSPredicate(format: "label == 'Browse'")).firstMatch
            XCTAssertTrue(backToBrowse.waitForExistence(timeout: 5))
            backToBrowse.tap()
            let local = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'On My iPhone'")).firstMatch
            XCTAssertTrue(local.waitForExistence(timeout: 5))
            local.tap()
        }
        XCTAssertTrue(localRoot.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 5))
        print("LOCAL_FILES_ARCHIVE=\(archiveName)")
        print("LOCAL_FILES_DESTINATION_SELECTED=On My iPhone")
        app.buttons["Save"].tap()
        let saveDismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["Save"])
        XCTAssertEqual(XCTWaiter.wait(for: [saveDismissed], timeout: 12), .completed)
        let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
        files.launch()
        XCTAssertTrue(files.wait(for: .runningForeground, timeout: 10))
        let previousPreviewClose = files.buttons["QLOverlayDoneButtonAccessibilityIdentifier"]
        if previousPreviewClose.exists { previousPreviewClose.tap() }
        let search = files.searchFields["Search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        if let current = search.value as? String, current != "Search", !current.isEmpty {
            search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        search.typeText("\(archiveName)\n")
        let savedArchive = files.cells.matching(NSPredicate(format: "label CONTAINS %@", archiveName)).firstMatch
        XCTAssertTrue(savedArchive.waitForExistence(timeout: 30))
        savedArchive.tap()
        XCTAssertTrue(files.otherElements["QLPreviewControllerView"].waitForExistence(timeout: 8))
        XCTAssertTrue(files.buttons["Preview Content"].exists)
        print("FILES_LOCAL_ARCHIVE_OPENED=\(archiveName)")
    }

    /// Run after the spoken-sample test, with the person ready to choose one photo.
    /// Reuses that isolated test note so export includes real microphone audio and a selected photo.
    func testUserSelectedPhotoPreservesSpokenAudioAndPreparesFilesExport() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--skip-welcome", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let row = app.buttons.matching(identifier: "noteRow").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Run the spoken microphone sample first.")
        row.tap()
        XCTAssertTrue(app.buttons["playRecording"].waitForExistence(timeout: 5))
        let originalTranscript = app.staticTexts["detailTranscript"].label
        app.buttons["editIdea"].tap()
        app.buttons["Image"].tap()
        print("SELECT_ONE_TEST_PHOTO_NOW: use a non-sensitive screenshot with readable text")
        XCTAssertTrue(app.staticTexts["Your selected image"].waitForExistence(timeout: 120), "The person must choose one image through PhotosPicker.")
        XCTAssertTrue(app.buttons["Open source image"].exists)
        let savedDraft = app.staticTexts["Draft kept on this iPhone"]
        XCTAssertTrue(savedDraft.waitForExistence(timeout: 15))
        app.buttons["Image options"].tap()
        app.buttons["Read text from image"].firstMatch.tap()
        let finishedOCR = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 0"), object: app.progressIndicators)
        XCTAssertEqual(XCTWaiter.wait(for: [finishedOCR], timeout: 30), .completed)
        app.buttons["saveIdea"].tap()
        XCTAssertTrue(app.buttons["editIdea"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.staticTexts["detailTranscript"].label, originalTranscript)
        XCTAssertTrue(app.buttons["playRecording"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[cd] 'recognized from source image'")).firstMatch.waitForExistence(timeout: 8), "The selected readable screenshot should produce source OCR without replacing the spoken transcript.")
        let captured = XCTAttachment(screenshot: app.screenshot())
        captured.name = "Real selected photo with original microphone recording"
        captured.lifetime = .keepAlways
        add(captured)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Settings"].tap()
        app.buttons["exportIdeas"].tap()
        let archive = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Seednote-export-'")).firstMatch
        XCTAssertTrue(archive.waitForExistence(timeout: 15))
        print("MEDIA_EXPORT_ARCHIVE=\(archive.label)")
        let save = app.cells["Save to Files"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()
        print("FILES_DESTINATION_INTERFACE=\(app.debugDescription)")
        let files = XCTAttachment(screenshot: app.screenshot())
        files.name = "Files destination for genuine image and microphone archive"
        files.lifetime = .keepAlways
        add(files)
        XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 8))
        // Destination is selected explicitly in the following physical acceptance step.
    }
}
