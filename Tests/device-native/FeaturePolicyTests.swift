import Foundation
import XCTest
@testable import KariNative

final class FeaturePolicyTests: XCTestCase {
    @MainActor func testPolicyAndMotionInvariants() async throws {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ reason: String) { precondition(value(), reason); count += 1 }
        let profile = PersonalityProfile()
        let roundtrip = try PersonalityProfile.imported(profile.exported())
        check(profile == roundtrip, "Web-shaped JSON roundtrip")
        for json in ["[]", "{}", "{\"name\":42}", "{\"coreTraits\":{\"curiosity\":true}}", "{\"coreTraits\":{\"curiosity\":2}}", "{\"speechStyle\":{\"shortReplies\":1}}", "{\"identity\":\"\"}"] {
            do { _ = try PersonalityProfile.imported(Data(json.utf8)); preconditionFailure("Invalid import accepted: \(json)") } catch { count += 1 }
        }
        let unsafe = try PersonalityProfile.imported(Data("{\"name\":\"小乐\",\"boundaries\":{\"doNotMoveWhenUnarmed\":false}}".utf8))
        check(unsafe.boundaries.values.allSatisfy { $0 }, "Imported boundaries cannot disable safety")
        var scheduler = BehaviorCoordinator(); var settings = BehaviorSettings()
        scheduler.begin(now: 0)
        check(!scheduler.idle(now: 2, settings: settings, profile: profile, blocked: false), "No immediate idle action")
        check(!scheduler.idle(now: 30, settings: settings, profile: profile, blocked: true), "Speech/control blocks idle")
        check(scheduler.idle(now: 30, settings: settings, profile: profile, blocked: false), "Idle admitted")
        check(!scheduler.idle(now: 31, settings: settings, profile: profile, blocked: false), "No idle burst")
        scheduler.interact(now: 35)
        check(!scheduler.idle(now: 36, settings: settings, profile: profile, blocked: false), "Interaction resets attention")
        _ = scheduler.idle(now: 100, settings: settings, profile: profile, blocked: false)
        check(scheduler.sleeping, "Silence enters sleep")
        scheduler.interact(now: 101); check(!scheduler.sleeping, "Interaction wakes")
        check(scheduler.admitThought(now: 101, limit: 2), "First thought")
        check(!scheduler.admitThought(now: 102, limit: 2), "Burst rejected")
        check(scheduler.admitThought(now: 107, limit: 2), "Second thought")
        check(!scheduler.admitThought(now: 130, limit: 2), "Minute cap")
        check(scheduler.admitThought(now: 162, limit: 2), "Rolling window expires")
        check(scheduler.admitExpression(now: 0, interval: 60), "First expression")
        check(!scheduler.admitExpression(now: 59, interval: 60), "Expression throttle")
        check(scheduler.admitExpression(now: 60, interval: 60), "Expression exact boundary")
        settings.thoughtsPerMinute = 99; settings.expressionInterval = 1; settings.sleepAfter = .nan; settings.normalize()
        check(settings.thoughtsPerMinute == 12 && settings.expressionInterval == 60 && settings.sleepAfter == 60, "Behavior bounds")
        var authority = MotionAuthority(); let low = try authority.acquire(.idle)
        let high = try authority.acquire(.manual)
        check(!authority.permits(low) && authority.permits(high), "Preemption invalidates old lease")
        do { _ = try authority.acquire(.follow); preconditionFailure("Follow preempted manual") } catch { count += 1 }
        authority.release(low); check(authority.permits(high), "Stale release cannot revoke new owner")
        authority.invalidate(); check(!authority.permits(high), "Stop invalidates owner")
        let original = NormalizedBox(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let rotated = original.rotated(clockwise: 1)
        check(abs(rotated.x - 0.4) < 0.0001 && rotated.y == 0.1 && rotated.width == 0.4, "Quarter turn box mapping")
        check(abs(rotated.rotated(clockwise: -1).x - original.x) < 0.0001, "Rotation roundtrip")
        check(abs(rotated.area - original.area) < 0.0001, "Reference area survives rotation")
        var follow = FollowPolicy()
        let box = NormalizedBox(x: 0.4, y: 0.3, width: 0.2, height: 0.3)
        check(box.display(mirrored: true).display(mirrored: true) == box || abs(box.display(mirrored: true).display(mirrored: true).x - box.x) < 0.0001, "Mirror roundtrip")
        check(abs(box.iou(box) - 1) < 0.0001, "IoU identity")
        follow.select(.init(id: 1, label: "person", score: 0.9, box: box, time: 0))
        check(!follow.calibrate(now: 0.31), "Cannot calibrate stale frame")
        check(follow.calibrate(now: 0.1) && follow.start(now: 0.1), "Fresh selected target can follow")
        check(follow.intent(now: 0.1).linear == 0, "At reference size stays still")
        let small = NormalizedBox(x: 0.45, y: 0.35, width: 0.1, height: 0.2)
        check(follow.update([.init(id: 2, label: "person", score: 0.9, box: small, time: 0.2)], now: 0.2), "Same target tracked")
        check(follow.intent(now: 0.2).linear > 0, "Smaller target advances")
        check(follow.target?.id == 1, "Stable target identity")
        check(follow.intent(now: 0.6).linear == 0 && !follow.enabled, "Stale target stops")
        follow.select(.init(id: 1, label: "person", score: 0.9, box: box, time: 1)); _ = follow.calibrate(now: 1); _ = follow.start(now: 1)
        check(!follow.update([.init(id: 2, label: "person", score: 0.9, box: box, time: 1.1), .init(id: 3, label: "person", score: 0.9, box: box, time: 1.1)], now: 1.1), "Ambiguous targets invalidate")
        check(follow.target == nil && follow.reference == nil && !follow.enabled, "No automatic retarget")
        var journal = CompanionJournal()
        for i in 0..<600 { journal.record("frame", "\(i)", now: Double(i)); journal.record("decision", now: Double(i), decision: true) }
        check(journal.events.count == 500 && journal.decisions.count == 100, "Bounded diagnostic history")
        journal.clear(); check(journal.events.isEmpty && journal.decisions.isEmpty, "Clear history")
        let coordinator = KariMotionCoordinator()
        var sent = 0, stops = 0
        coordinator.stopRaw = { _ in stops += 1; return true }
        coordinator.sendRaw = { _, _ in sent += 1; return ["ok": true] }
        let idle = try await coordinator.acquire(.idle)
        let manual = try await coordinator.acquire(.manual)
        do { _ = try await coordinator.send(["type":"motion"], lease: idle); preconditionFailure("Old command sent") } catch { count += 1 }
        _ = try await coordinator.send(["type":"motion"], lease: manual)
        check(sent == 1 && stops == 2, "Only current owner sends after stop barriers")
        let stopped = await coordinator.manualStop(); check(stopped, "Manual release stop")
        check(coordinator.valid(manual), "Zero input stop retains manual lease")
        _ = await coordinator.stop()
        do { _ = try await coordinator.send(["type":"motion"], lease: manual); preconditionFailure("Stopped motion replayed") } catch { count += 1 }
        coordinator.stopRaw = { _ in false }
        do { _ = try await coordinator.acquire(.follow); preconditionFailure("Unconfirmed stop admitted follow") } catch { count += 1 }
        check(coordinator.source == nil, "Failed preparation releases owner")
        let delayed = KariMotionCoordinator()
        delayed.stopRaw = { _ in true }
        var ack: CheckedContinuation<[String: Any], Error>?
        delayed.sendRaw = { _, _ in try await withCheckedThrowingContinuation { ack = $0 } }
        let old = try await delayed.acquire(.follow)
        let pending = Task { try await delayed.send(["type":"motion"], lease: old) }
        while ack == nil { await Task.yield() }
        _ = await delayed.stop()
        let new = try await delayed.acquire(.manual)
        ack?.resume(returning: ["ok":true])
        do { _ = try await pending.value; preconditionFailure("Late ACK restored old motion") } catch { count += 1 }
        delayed.release(old)
        check(delayed.valid(new), "Late response and stale cleanup cannot revoke manual takeover")
        print("Feature checks passed: \(count)")
    }
    static func check(awaitValue: Bool, _ reason: String) { precondition(awaitValue, reason) }
}
