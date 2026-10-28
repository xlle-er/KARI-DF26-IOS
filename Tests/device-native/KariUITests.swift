import XCTest
final class KariUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    func testLiveFailureShowsReasonAndKeepsCompanionship() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--ui-testing-live-failure"]; app.launch()
        XCTAssertTrue(app.buttons["startExperience"].waitForExistence(timeout: 20))
        app.buttons["startExperience"].tap()
        XCTAssertTrue(app.staticTexts["liveFailureTitle"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["runtimeNotice"].label.contains("Google"))
        XCTAssertFalse(app.staticTexts["runtimeNotice"].label.contains("CancellationError"))
        XCTAssertFalse(app.buttons["tab_0"].exists)
        let retry = app.buttons["retryLiveConnection"]
        XCTAssertTrue(retry.exists); retry.tap()
        XCTAssertTrue(app.staticTexts["liveFailureTitle"].exists)
        XCTAssertTrue(app.buttons["startExperience"].isHittable)
        let evidence = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); evidence.name = "Companion retained with explicit Live failure"; evidence.lifetime = .keepAlways; add(evidence)
        app.buttons["startExperience"].tap()
        XCTAssertTrue(app.buttons["tab_0"].waitForExistence(timeout: 10))
    }
    func testFourNativePagesAndSingleCompanionAction() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        XCTAssertTrue(app.buttons["tab_0"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["connectFromRobot"].exists)
        XCTAssertTrue(app.buttons["robotRemote"].exists)
        let robot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); robot.name = "Floating glass robot page on iPhone"; robot.lifetime = .keepAlways; add(robot)
        app.buttons["tab_1"].tap()
        XCTAssertTrue(app.textFields["personalityName"].waitForExistence(timeout: 5))
        app.buttons["tab_2"].tap()
        XCTAssertTrue(app.switches["enableDetection"].waitForExistence(timeout: 5))
        app.buttons["tab_3"].tap()
        XCTAssertEqual(app.buttons.matching(identifier: "startExperience").count, 1)
        app.buttons["startExperience"].tap()
        let stop = app.buttons["startExperience"]
        XCTAssertTrue(stop.waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["tab_1"].exists, "No page switching during companionship")
        XCTAssertFalse(app.buttons["tab_2"].exists)
        XCTAssertGreaterThan(app.frame.width, app.frame.height, "Companion must occupy a landscape window")
        XCTAssertTrue(stop.isHittable, "The central stop button must remain reachable")
        print("Companion window: \(app.frame); stop: \(stop.frame)")
        let active = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); active.name = "Personal companion on iPhone"; active.lifetime = .keepAlways; add(active)
        stop.tap()
        XCTAssertTrue(app.buttons["tab_3"].waitForExistence(timeout: 15))
        let idle = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); idle.name = "Native settings on iPhone"; idle.lifetime = .keepAlways; add(idle)
    }
    func testLifeAndSceneSettingsNavigation() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        XCTAssertTrue(app.buttons["tab_1"].waitForExistence(timeout: 20)); app.buttons["tab_1"].tap()
        let link = app.buttons["idleScenesLink"]
        for _ in 0..<4 where !link.isHittable { app.swipeUp() }
        XCTAssertTrue(link.exists); link.tap()
        let scene = app.buttons["scene_pose_neutral"]
        for _ in 0..<5 where !scene.isHittable { app.swipeUp() }
        XCTAssertTrue(scene.exists); scene.tap()
        XCTAssertTrue(app.buttons["previewIdleScene"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let life = app.buttons["lifeStateLink"]
        for _ in 0..<4 where !life.isHittable { app.swipeUp() }
        life.tap(); XCTAssertTrue(app.otherElements["lifeStatePage"].waitForExistence(timeout: 5) || app.collectionViews["lifeStatePage"].exists)
        app.buttons["tab_3"].tap(); app.buttons["wakeSettingsLink"].tap()
        XCTAssertTrue(app.switches["enableWakeWord"].waitForExistence(timeout: 5))
    }
    func testStopFollowsControlsVisibility() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--ui-testing-live-ready"]; app.launch()
        XCTAssertTrue(app.buttons["startExperience"].waitForExistence(timeout: 20)); app.buttons["startExperience"].tap()
        let stop = app.buttons["startExperience"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(stop.frame.midX, app.frame.width * 0.7)
        XCTAssertLessThan(stop.frame.midY, app.frame.height * 0.25)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: stop)
        waitForExpectations(timeout: 5)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        XCTAssertTrue(stop.waitForExistence(timeout: 5)); stop.tap()
        XCTAssertTrue(app.buttons["tab_0"].waitForExistence(timeout: 10))
    }
    func testOnDeviceWakeListeningDoesNotConnectLive() {
        addUIInterruptionMonitor(withDescription: "Speech permission") { alert in
            let button = alert.buttons.matching(NSPredicate(format: "label IN %@", ["允许", "好", "Allow", "OK"])).firstMatch
            if button.exists { button.tap(); return true }; return false
        }
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--ui-testing-wake-listening"]; app.launch()
        XCTAssertTrue(app.buttons["startExperience"].waitForExistence(timeout: 20)); app.buttons["startExperience"].tap()
        // Interact to let XCTest handle the system permission sheet if present.
        app.tap()
        let counters = app.staticTexts["wakePrivacyCounters"]
        XCTAssertTrue(counters.waitForExistence(timeout: 25))
        expectation(for: NSPredicate(format: "label CONTAINS 'microphone=true'"), evaluatedWith: counters)
        waitForExpectations(timeout: 15)
        XCTAssertTrue(counters.label.contains("connected=false video=0"))
        let status = app.staticTexts["wakeStatus"]
        print("WAKE_LOCAL_STATUS \(status.label); \(counters.label)")
        let evidence = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); evidence.name = "Local wake listening on iPhone"; evidence.lifetime = .keepAlways; add(evidence)
        app.buttons["startExperience"].tap()
        XCTAssertTrue(app.buttons["tab_0"].waitForExistence(timeout: 10))
    }
    func testAllNativePagesReserveBottomTabBarSpace() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        let bar = app.tabBars["nativeTabBar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 20), "Use the real system tab bar")
        let pages = [("tab_0", "robotManagementSettings", true), ("tab_1", "exportPersonality", true), ("tab_2", "visionFooter", false), ("tab_3", "runtimeNotice", false)]
        for (tab, footer, button) in pages {
            app.buttons[tab].tap()
            let element = button ? app.buttons[footer] : app.staticTexts[footer]
            for _ in 0..<10 {
                if element.exists && element.frame.maxY < bar.frame.minY - 2 && element.isHittable { break }
                app.swipeUp()
            }
            XCTAssertTrue(element.exists, footer)
            XCTAssertTrue(element.isHittable, "Bottom content must be reachable: \(footer)")
            XCTAssertLessThanOrEqual(element.frame.maxY, bar.frame.minY - 2, "Bottom content must clear the native tab bar: \(footer)")
            let evidence = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); evidence.name = "Native tab safe area \(tab)"; evidence.lifetime = .keepAlways; add(evidence)
        }
        // A secondary navigation screen must inherit the same tab safe area.
        app.buttons["wakeSettingsLink"].tap()
        XCTAssertTrue(app.switches["enableWakeWord"].waitForExistence(timeout: 5))
        XCTAssertTrue(bar.exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["startExperience"].tap()
        XCTAssertFalse(bar.exists, "No tabs while accompanying")
        app.buttons["startExperience"].tap()
        XCTAssertTrue(bar.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["runtimeNotice"].exists, "Action item returns to the original settings page")
    }
}
