import XCTest
import Foundation
@testable import KariNative

final class LifeWakeTests: XCTestCase {
    func testSceneWeightsCooldownAndEmptyCandidates() throws {
        let a = IdleScene(id: "a", title: "a", titleZH: "a", body: false, steps: [])
        let b = IdleScene(id: "b", title: "b", titleZH: "b", body: true, steps: [])
        var settings = IdleSceneSettings(); settings.repeatGap = 15
        var engine = LifeEngine(); engine.begin(now: 0, settings: settings)
        func select(_ time: Double, _ scenes: [IdleScene], body: Bool = false, speaking: Bool = false) -> IdleScene? {
            engine.select(now: time, catalog: scenes, settings: settings, profile: .init(), bodyAllowed: body, speaking: speaking, conversation: false, manual: true, sample: 0)
        }
        XCTAssertNil(select(2, [a,b], body: true))
        XCTAssertEqual(select(4, [a,b])?.id, "a")
        XCTAssertNil(select(5, [a,b]))
        XCTAssertNil(select(35, [b], body: true, speaking: true))
        XCTAssertEqual(select(35, [b], body: true)?.id, "b")
        settings.scenes["a"] = .init(enabled: false); XCTAssertNil(select(100, [a], body: true))
        settings.scenes["a"] = .init(weight: 0); XCTAssertNil(select(100, [a], body: true))
        settings.scenes["a"] = .init(availability: .sleeping); XCTAssertNil(select(100, [a], body: true))
        engine.tick(now: 100, profile: .init(), sleepAfter: 60)
        XCTAssertEqual(select(100, [a], body: true)?.id, "a")
    }
    func testLifeClockAndSuspension() {
        var life = LifeEngine(); life.begin(now: 0, settings: .init())
        let start = life.state.energy
        life.tick(now: 1, profile: .init(), sleepAfter: 60)
        XCTAssertEqual(life.state.energy, start - 0.001, accuracy: 0.000001)
        life.suspend(); let paused = life.state
        life.tick(now: 1000, profile: .init(), sleepAfter: 60)
        XCTAssertEqual(life.state, paused)
        life.tick(now: 1001, profile: .init(), sleepAfter: 60); XCTAssertFalse(life.state.sleeping, "Background time cannot count toward sleep")
        life.event("user_activity", now: 1001)
        XCTAssertEqual(life.state.boredom, 0); XCTAssertFalse(life.state.sleeping)
        XCTAssertEqual(life.state.userIdentity, "unknown"); XCTAssertEqual(life.state.obstacle, "unknown")
        life.tick(now: 1100, profile: .init(), sleepAfter: 60); XCTAssertTrue(life.state.sleeping)
        life.event("wake", now: 1100); XCTAssertFalse(life.state.sleeping)
        life.begin(now: 1200, settings: .init()); XCTAssertEqual(life.state, LifeState())
    }
    func testWakeBufferTransitionsAndStaleResponses() {
        var p = WakePolicy(); p.wait(now: 0)
        for _ in 0..<20 { XCTAssertNil(p.append(Data(repeating: 1, count: 3200), now: 0.5, voice: false)) }
        XCTAssertEqual(p.buffer.count, 32_000)
        let ticket = p.wake(now: 1)!; XCTAssertNil(p.wake(now: 1.1))
        _ = p.append(Data(repeating: 2, count: 3200), now: 1.2, voice: false)
        let data = p.connected(generation: ticket, now: 2)!
        XCTAssertEqual(data.count, 35_200); XCTAssertEqual(data.first, 1); XCTAssertEqual(data.last, 2)
        XCTAssertNil(p.connected(generation: ticket, now: 2.1)); XCTAssertTrue(p.buffer.isEmpty)
        XCTAssertEqual(p.append(Data([9,8]), now: 3, voice: true), Data([9,8]))
        XCTAssertFalse(p.timedOut(now: 100, timeout: 60, busy: true)); XCTAssertTrue(p.timedOut(now: 100, timeout: 60, busy: false))
        p.wait(now: 101); let old = p.wake(now: 102)!
        _ = p.append(Data(repeating: 3, count: 256_002), now: 103, voice: false)
        XCTAssertTrue(p.overflow); XCTAssertTrue(p.buffer.isEmpty)
        XCTAssertNil(p.append(Data([1,2]), now: 104, voice: false)); XCTAssertTrue(p.buffer.isEmpty)
        p.stop(suspended: true); XCTAssertNil(p.connected(generation: old, now: 105))
        XCTAssertTrue(p.buffer.isEmpty); XCTAssertFalse(p.overflow)
        p.wait(now: 200); _ = p.append(Data([1,2]), now: 200, voice: false); p.stop(); XCTAssertTrue(p.buffer.isEmpty)
    }
    func testWakePhraseVariants() {
        XCTAssertTrue(WakePreset.chinese.matches("你好，卡里！今天怎么样"))
        XCTAssertTrue(WakePreset.english.matches("Hey, Louie. What time is it?"))
        XCTAssertFalse(WakePreset.english.matches("They said hey Louie on TV"))
        XCTAssertFalse(WakePreset.chinese.matches("这不是一个唤醒词"))
    }
    @MainActor func testConfigurationPersistenceAndAtomicImport() throws {
        let name = "kari.life-config-test.\(UUID())", defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let f = KariCompanionFeatures(defaults: defaults)
        XCTAssertGreaterThan(f.catalog.count, 6); XCTAssertEqual(Set(f.catalog.map(\.id)).count, f.catalog.count)
        XCTAssertTrue(f.catalog.flatMap(\.steps).allSatisfy { ["move", "stop", "pause"].contains($0.kind) })
        f.wakeSettings.enabled = true; f.idleSettings.repeatGap = 90
        let data = try f.exportedConfiguration(), restored = KariCompanionFeatures(defaults: defaults)
        XCTAssertTrue(restored.wakeSettings.enabled); XCTAssertEqual(restored.idleSettings.repeatGap, 90)
        XCTAssertEqual(try restored.exportedConfiguration(), data)
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var wake = json["wake"] as! [String: Any]; wake["silenceTimeout"] = 1; json["wake"] = wake
        XCTAssertThrowsError(try f.importConfiguration(JSONSerialization.data(withJSONObject: json)))
        XCTAssertEqual(try f.exportedConfiguration(), data)
        json["schemaVersion"] = 999; XCTAssertThrowsError(try f.importConfiguration(JSONSerialization.data(withJSONObject: json)))
        try f.importProfile(f.profile.exported()); XCTAssertTrue(f.wakeSettings.enabled)
    }
    @MainActor func testAllDisabledScenesReturnNeutralWithoutMotion() async throws {
        let name = "kari.empty-idle-test.\(UUID())", defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let app = KariAppModel(defaults: defaults); app.cameraEnabled = false
        try app.settings.save(.fresh("rule"), key: "")
        app.companion.idleSettings.first = .init(minimum: 3, maximum: 3)
        for scene in app.companion.catalog { app.companion.setSceneOptions(.init(enabled: false), id: scene.id) }
        var sent = 0
        app.motion.sendRaw = { _, _ in sent += 1; return ["ok": true] }
        app.motion.stopRaw = { _ in true }
        app.start()
        for _ in 0..<60 {
            if app.companion.decisions.contains(where: { $0.kind == "idle_empty" }) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(app.phase, .active)
        XCTAssertTrue(app.companion.decisions.contains(where: { $0.kind == "idle_empty" }))
        XCTAssertEqual(sent, 0); XCTAssertNil(app.motion.source)
        await app.stop()
    }
    @MainActor func testWaitingGateBlocksTextAndCameraUploadWithoutCapture() async throws {
        let name = "kari.wake-gate-test.\(UUID())", defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let app = KariAppModel(defaults: defaults)
        app.companion.wakeSettings.enabled = true
        XCTAssertTrue(app.sendText("停止"), "Stop remains local even before wake")
        XCTAssertFalse(app.sendText("Do not send")); app.camera.onFrame?(Data([0,1,2]))
        XCTAssertEqual(app.live.sentVideoFrames, 0); XCTAssertFalse(app.live.connected)
        await app.stop(); XCTAssertEqual(app.wake.phase, .stopped)
    }
}
