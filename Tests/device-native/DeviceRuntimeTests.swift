import XCTest
import UIKit
import CoreVideo
@testable import KariNative

final class DeviceRuntimeTests: XCTestCase {
    @MainActor func testLiveFailureKeepsCompanionUntilExplicitStop() async throws {
        let domain = "kari.failure-test.\(UUID().uuidString)", reason = "Google region denied: User location is not supported for the API use."
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let app = KariAppModel(defaults: defaults, liveStarter: { _ in throw KariError.message(reason) })
        app.cameraEnabled = false
        app.start()
        for _ in 0..<100 where app.phase == .starting { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(app.phase, .active)
        XCTAssertEqual(app.liveFailure, reason)
        XCTAssertFalse(app.liveFailure.contains("CancellationError"))
        app.recoverCapture()
        for _ in 0..<100 where app.recovering { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(app.phase, .active, "Retry failure must not exit companionship")
        XCTAssertEqual(app.liveFailure, reason)
        await app.stop(); XCTAssertEqual(app.phase, .idle)
    }
    @MainActor func testWakeSharedCaptureLiveHandoff() async throws {
        let config = KariSettings().configuration
        guard config.isLive else { throw XCTSkip("Saved configuration is not Live") }
        let live = KariLiveService(); defer { live.stop() }
        try await live.startSharedCapture(onFrame: { data, level in live.sendPCM(data, level: level) }, onState: { _, _ in })
        try await Task.sleep(nanoseconds: 300_000_000)
        let before = live.audioDiagnostics["capturedPCMFrames"] as? Int ?? 0
        XCTAssertGreaterThan(before, 0)
        XCTAssertEqual(live.audioDiagnostics["microphoneTapStarts"] as? Int, 1)
        XCTAssertFalse(live.connected)
        try await live.start(config, captureMicrophone: false)
        XCTAssertTrue(live.microphone)
        XCTAssertEqual(live.audioDiagnostics["microphoneTapStarts"] as? Int, 1, "No second tap when handing capture to Live")
        live.sendText("请只说这一句话：唤醒对话测试开始，这句话需要完整播放，唤醒对话测试结束。")
        let deadline = Date().addingTimeInterval(75)
        while Date() < deadline, live.error.isEmpty {
            if live.receivedAudioChunks > 0 && live.turnComplete && !live.speaking { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(live.error.isEmpty, live.error)
        XCTAssertTrue(live.turnComplete); XCTAssertGreaterThan(live.receivedAudioChunks, 0)
        XCTAssertEqual(live.receivedPCMFrames, live.playedPCMFrames, "Every received sample must finish playing")
        XCTAssertEqual(live.serverInterruptions, 0); XCTAssertEqual(live.playbackFailures, 0)
        let metrics = live.audioDiagnostics.filter { $0.key != "route" }
        print("WAKE_HANDOFF_DIAG \(String(data: try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys]), encoding: .utf8)!)")
        live.stop(preserveCapture: true)
        XCTAssertFalse(live.connected); XCTAssertTrue(live.microphone)
        let count = live.audioDiagnostics["capturedPCMFrames"] as? Int ?? 0
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertGreaterThan(live.audioDiagnostics["capturedPCMFrames"] as? Int ?? 0, count)
        XCTAssertEqual(live.audioDiagnostics["microphoneTapStarts"] as? Int, 1, "Returning to local waiting must retain the original capture tap")
    }
    @MainActor private func completeSpeech(microphone: Bool) async throws {
        let config = KariSettings().configuration
        guard config.isLive else { throw XCTSkip("Saved configuration is not Live") }
        let live = KariLiveService(); defer { live.stop() }
        try await live.start(config, captureMicrophone: microphone)
        live.sendText("请只说这一句话，不要解释：语音测试开始，这句话必须播放完整，语音测试结束。")
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline, live.error.isEmpty {
            if live.receivedAudioChunks > 0 && live.turnComplete && !live.speaking { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let metrics = String(data: try JSONSerialization.data(withJSONObject: live.audioDiagnostics.filter { $0.key != "route" }, options: [.sortedKeys]), encoding: .utf8)!
        print("SPEECH_DIAG microphone=\(microphone) tailPresent=\(live.reply.contains("测试结束")) turnComplete=\(live.turnComplete) metrics=\(metrics)")
        XCTAssertTrue(live.error.isEmpty, live.error)
        XCTAssertTrue(live.turnComplete)
        XCTAssertEqual(live.serverInterruptions, 0, "Unprompted interruption during fixed test")
        XCTAssertEqual(live.playbackFailures, 0)
        XCTAssertEqual(live.playedPCMFrames, live.receivedPCMFrames, "All received PCM must play before test stops")
        XCTAssertGreaterThan(live.receivedPCMFrames, 48_000)
        XCTAssertTrue(live.reply.contains("测试结束"), "Fixed utterance must include the final sentence")
    }
    @MainActor func testConfiguredLiveCompleteSpeechOnPhone() async throws { try await completeSpeech(microphone: false) }
    @MainActor func testConfiguredLiveDuplexSpeechOnPhone() async throws { try await completeSpeech(microphone: true) }
    @MainActor func testConfiguredLiveSpokenTurnOnPhone() async throws {
        let config = KariSettings().configuration
        guard config.isLive else { throw XCTSkip("Saved configuration is not Live") }
        let live = KariLiveService()
        UIApplication.shared.isIdleTimerDisabled = true
        defer { live.stop(); UIApplication.shared.isIdleTimerDisabled = false }
        try await live.start(config)
        print("SPOKEN_TURN_READY: microphone active; waiting for one user question")
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline, live.error.isEmpty {
            if live.heard.count >= 8 && live.receivedPCMFrames >= 48_000 && live.generationCompletions > 0 && live.turnComplete && !live.speaking { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let metrics = String(data: try JSONSerialization.data(withJSONObject: live.audioDiagnostics.filter { $0.key != "route" }, options: [.sortedKeys]), encoding: .utf8)!
        print("SPOKEN_TURN_DIAG heardCharacters=\(live.heard.count) turnComplete=\(live.turnComplete) metrics=\(metrics)")
        XCTAssertTrue(live.error.isEmpty, live.error)
        XCTAssertGreaterThanOrEqual(live.heard.count, 8, "Must exercise spoken rather than typed input")
        XCTAssertTrue(live.turnComplete)
        XCTAssertEqual(live.playbackFailures, 0)
        XCTAssertEqual(live.playedPCMFrames, live.receivedPCMFrames, "Received speech must drain fully")
    }
    @MainActor func testConfiguredLiveConnectionOnPhone() async throws {
        let config = KariSettings().configuration
        print("LIVE_DIAG provider=\(config.provider) auth=\(config.auth) model=\(config.liveModel)")
        guard config.isLive else { throw XCTSkip("Current saved configuration is not Live") }
        let live = KariLiveService(); defer { live.stop() }
        do {
            try await live.start(config, testOnly: true)
            print("LIVE_DIAG setupComplete=true")
            live.sendText("Please say only: connection test successful.")
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline, live.error.isEmpty, live.receivedAudioChunks == 0 { try await Task.sleep(nanoseconds: 100_000_000) }
            print("LIVE_DIAG audioChunks=\(live.receivedAudioChunks) transport=\(live.transportDiagnostic)")
            XCTAssertTrue(live.error.isEmpty, live.error)
            XCTAssertGreaterThan(live.receivedAudioChunks, 0)
        } catch {
            print("LIVE_DIAG failure=\(KariAIRequest.redact(error.localizedDescription)) transport=\(live.transportDiagnostic)")
            throw error
        }
    }
    @MainActor func testPhysicalCameraSharedFramesAndStop() async throws {
        let camera = KariCamera(), vision = KariVisionService()
        let jpeg = expectation(description: "Camera JPEG upload frame")
        let inference = expectation(description: "Shared camera detector frame")
        var frames = 0, images = 0, detections = 0
        vision.setEnabled(true)
        vision.onDetections = { _ in detections += 1; if detections == 1 { inference.fulfill() } }
        camera.onPixelBuffer = { buffer, time in frames += 1; vision.submit(buffer, time: time) }
        camera.onFrame = { _ in images += 1; if images == 1 { jpeg.fulfill() } }
        try await camera.start(front: true)
        defer { vision.setEnabled(false); camera.stop() }
        await fulfillment(of: [jpeg, inference], timeout: 15)
        XCTAssertTrue(camera.running); XCTAssertGreaterThan(frames, 0)
        XCTAssertNotNil(camera.snapshot())
        camera.stop(); vision.setEnabled(false)
        XCTAssertFalse(camera.running); XCTAssertNil(camera.snapshot()); XCTAssertTrue(vision.detections.isEmpty)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertNil(camera.snapshot(), "Late camera callbacks cannot repopulate a stopped snapshot")
    }
    @MainActor func testPersonalityPersistenceAndRejectedImport() throws {
        let name = "kari.tests.\(UUID().uuidString)"; let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = KariCompanionFeatures(defaults: defaults)
        store.behavior.proactiveAI = true
        store.behavior.thoughtsPerMinute = 99
        XCTAssertEqual(store.behavior.thoughtsPerMinute, 12)
        XCTAssertTrue(KariCompanionFeatures(defaults: defaults).behavior.proactiveAI)
        var profile = store.profile; profile.name = "测试人格"; profile.coreTraits["curiosity"] = 0.9
        try store.saveProfile(profile)
        XCTAssertEqual(KariCompanionFeatures(defaults: defaults).profile, profile)
        XCTAssertThrowsError(try store.importProfile(Data("{\"name\": false}".utf8)))
        XCTAssertEqual(store.profile, profile)
        XCTAssertTrue(store.profile.instruction.contains("personality_profile"))
    }
    @MainActor func testActualEfficientDetModelOnFixture() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "burger", withExtension: "jpg"))
        let image = try XCTUnwrap(UIImage(contentsOfFile: url.path))
        let labels = try KariVisionService.fixtureDetections(image)
        XCTAssertFalse(labels.isEmpty, "The real bundled model must detect an object in Google's burger fixture")
        XCTAssertTrue(labels.contains("sandwich"), "Expected COCO sandwich category; got \(labels)")
    }
    @MainActor func testLiveFrameAdmissionAndStaleCallback() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "burger", withExtension: "jpg"))
        let image = try XCTUnwrap(UIImage(contentsOfFile: url.path))
        let buffer = try makeBuffer(image)
        let vision = KariVisionService(); let completed = expectation(description: "real video inference")
        var callbacks = 0
        vision.setEnabled(true)
        // Frame admission is independent of whether this transformed buffer contains a detection.
        // The image-mode fixture above separately verifies model classification.
        vision.onDetections = { _ in callbacks += 1; if callbacks == 1 { completed.fulfill() } }
        let now = ProcessInfo.processInfo.systemUptime
        for i in 0..<50 { vision.submit(buffer, time: now + Double(i) / 10) }
        await fulfillment(of: [completed], timeout: 20)
        XCTAssertEqual(callbacks, 1, "Busy frames must be dropped instead of queued")
        vision.submit(buffer, time: now + 10); vision.setEnabled(false)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(vision.detections.isEmpty)
        XCTAssertFalse(vision.enabled)
    }
    @MainActor func testDiagnosticExportExcludesPrivateInputs() throws {
        let app = KariAppModel()
        app.textReply = "PRIVATE_CHAT_MUST_NOT_EXPORT"
        app.body.management.password = "PRIVATE_PASSWORD_MUST_NOT_EXPORT"
        let text = String(data: try app.companion.diagnosticData(), encoding: .utf8)!
        XCTAssertFalse(text.contains("PRIVATE_")); XCTAssertFalse(text.contains("admin_password"))
    }
    private func makeBuffer(_ image: UIImage) throws -> CVPixelBuffer {
        let size = CGSize(width: 640, height: 480)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 640, 480, kCVPixelFormatType_32BGRA, [kCVPixelBufferCGImageCompatibilityKey:true,kCVPixelBufferCGBitmapContextCompatibilityKey:true] as CFDictionary, &buffer), kCVReturnSuccess)
        let result = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(result, []); defer { CVPixelBufferUnlockBaseAddress(result, []) }
        let context = try XCTUnwrap(CGContext(data: CVPixelBufferGetBaseAddress(result), width: 640, height: 480, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(result), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        UIGraphicsPushContext(context); image.draw(in: CGRect(origin: .zero, size: size)); UIGraphicsPopContext()
        return result
    }
}
