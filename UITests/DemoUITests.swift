import XCTest

/// Runs the end-to-end demo like a user: launches with -demo, taps Allow on the system permission prompts,
/// waits until the notes are written, then scrolls through the result (the CI records the screen meanwhile).
final class DemoUITests: XCTestCase {
    func testDemoProducesTranscriptSlidesAndNotes() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo"]
        app.launch()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let done = app.descendants(matching: .any)["demo-done"]
        let deadline = Date().addingTimeInterval(400)
        while Date() < deadline && !done.exists {
            for label in ["Allow", "OK", "Allow While Using App"] {
                let b = springboard.buttons[label]
                if b.exists { b.tap() }
            }
            sleep(2)
        }
        XCTAssertTrue(done.exists, "Demo did not finish")
        sleep(3)
        for _ in 0..<6 { app.swipeUp(velocity: .slow); sleep(2) }
        XCTAssertTrue(app.staticTexts["Notes"].exists || app.staticTexts["Raw transcript"].exists)
    }
}
