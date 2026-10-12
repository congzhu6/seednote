import XCTest

/// Run explicitly on an unlocked phone with a person ready to speak.
/// These tests use SeednoteUITest, never the user's normal library.
final class DeviceAcceptanceTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical microphone acceptance is run on the test iPhone.")
        #endif
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reset-test-store", "--skip-welcome", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func allowMicrophoneIfRequested() {
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = system.alerts.firstMatch
        if alert.waitForExistence(timeout: 3) {
            for label in ["Allow", "OK", "允许", "好"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return }
            }
        }
    }

    private func recordForSpeech() {
        app.buttons["newIdea"].tap()
        let record = app.buttons["recordThought"]
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        record.tap()
        allowMicrophoneIfRequested()
        let stop = app.buttons["Stop recording"]
        XCTAssertTrue(stop.waitForExistence(timeout: 8))
        print("MICROPHONE_RECORDING_NOW: speak the supplied test sentence")
        capture("Real microphone recording")
        // Intentional recording window: enough time for a person to read the sentence.
        let spokenWindow = expectation(description: "Fifteen seconds of actual microphone capture")
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { spokenWindow.fulfill() }
        wait(for: [spokenWindow], timeout: 17)
        stop.tap()
        XCTAssertTrue(app.buttons["Play recording"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Stop recording"].exists)
    }

    func testRealMicrophoneSaveReopenAndPlayback() {
        recordForSpeech()
        app.buttons["Play recording"].tap()
        XCTAssertTrue(app.buttons["Pause recording"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Play recording"].waitForExistence(timeout: 25), "Let the complete microphone sample play for the person to assess audibility.")
        app.buttons["saveIdea"].tap()
        XCTAssertTrue(app.buttons.matching(identifier: "noteRow").firstMatch.waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments.removeAll { $0 == "--reset-test-store" }
        app.launch()
        let row = app.buttons.matching(identifier: "noteRow").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        let playback = app.buttons["playRecording"]
        XCTAssertTrue(playback.waitForExistence(timeout: 5))
        playback.tap()
        XCTAssertTrue(app.staticTexts["Playing"].waitForExistence(timeout: 5))
        capture("Actual recording reopened and playing")
        playback.tap()
    }

    /// Records a new spoken sample, then checks local recognition and durable text.
    func testOnDeviceTranscriptionOfSpokenSample() throws {
        recordForSpeech()
        app.buttons["Play recording"].tap()
        XCTAssertTrue(app.buttons["Pause recording"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Play recording"].waitForExistence(timeout: 25), "Let the spoken sample play completely before transcription.")
        app.buttons["Transcribe on device"].tap()
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = system.alerts.firstMatch
        if alert.waitForExistence(timeout: 3) {
            for label in ["Allow", "OK", "允许", "好"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                break
            }
        }
        let transcript = app.textViews["Transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 70), "A supported on-device recognizer should return the spoken sentence; otherwise inspect the retained audio and error.")
        let actual = (transcript.value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(actual.isEmpty)
        print("ACTUAL_DEVICE_TRANSCRIPT=\(actual)")
        capture("Real spoken audio transcribed on device")
        app.buttons["saveIdea"].tap()
        XCTAssertTrue(app.buttons.matching(identifier: "noteRow").firstMatch.waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments.removeAll { $0 == "--reset-test-store" }
        app.launch()
        let row = app.buttons.matching(identifier: "noteRow").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.staticTexts["detailTranscript"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["detailTranscript"].label, actual)
        XCTAssertTrue(app.buttons["playRecording"].exists)
        app.buttons["playRecording"].tap()
        XCTAssertTrue(app.staticTexts["Playing"].waitForExistence(timeout: 5))
        app.buttons["playRecording"].tap()
    }

    func testRecordingStopsWhenAppLeavesForeground() {
        app.buttons["newIdea"].tap()
        app.buttons["recordThought"].tap()
        allowMicrophoneIfRequested()
        XCTAssertTrue(app.buttons["Stop recording"].waitForExistence(timeout: 8))
        let captured = expectation(description: "Capture a recoverable microphone segment")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { captured.fulfill() }
        wait(for: [captured], timeout: 5)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["Play recording"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["Stop recording"].exists)
        XCTAssertTrue(app.staticTexts["Recording stopped when Seednote left the foreground. Your recorded audio was kept."].exists)
        capture("Background interruption retained recording")
        app.buttons["saveIdea"].tap()
        XCTAssertTrue(app.buttons.matching(identifier: "noteRow").firstMatch.waitForExistence(timeout: 5))
        app.buttons.matching(identifier: "noteRow").firstMatch.tap()
        app.buttons["playRecording"].tap()
        XCTAssertTrue(app.staticTexts["Playing"].waitForExistence(timeout: 5))
        app.buttons["playRecording"].tap()
    }

    func testRecordingStopsAtThreeMinuteLimitAndCanBeSaved() {
        app.buttons["newIdea"].tap()
        app.buttons["recordThought"].tap()
        allowMicrophoneIfRequested()
        let stop = app.buttons["Stop recording"]
        XCTAssertTrue(stop.waitForExistence(timeout: 8))
        let stopped = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: stop)
        XCTAssertEqual(XCTWaiter.wait(for: [stopped], timeout: 190), .completed)
        XCTAssertTrue(app.buttons["Play recording"].waitForExistence(timeout: 5))
        // AAC duration can end just below 180 s; the app displays elapsed whole seconds.
        // Keep the actual audio for independent decoded-duration verification after this test.
        XCTAssertTrue(app.staticTexts["02:59"].exists || app.staticTexts["03:00"].exists)
        XCTAssertTrue(app.staticTexts["The 3-minute recording limit was reached."].exists)
        capture("Three-minute automatic stop retained audio")
        app.buttons["saveIdea"].tap()
        let row = app.buttons.matching(identifier: "noteRow").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        app.buttons["playRecording"].tap()
        XCTAssertTrue(app.staticTexts["Playing"].waitForExistence(timeout: 5))
        app.buttons["playRecording"].tap()
    }
}
