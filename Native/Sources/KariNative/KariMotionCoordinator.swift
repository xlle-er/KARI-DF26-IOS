import Foundation
import Combine

@MainActor final class KariMotionCoordinator: ObservableObject {
    @Published private(set) var source: MotionSource?
    private var authority = MotionAuthority()
    private var barrier: Task<Bool, Never>?
    private var barrierID = UUID()
    var sendRaw: (([String: Any], TimeInterval) async throws -> [String: Any])?
    var stopRaw: ((TimeInterval) async -> Bool)?
    var preempt: (() -> Void)?
    func acquire(_ source: MotionSource) async throws -> MotionLease {
        let previous = authority.owner
        let lease = try authority.acquire(source)
        self.source = source
        if previous != nil { preempt?() }
        guard await stopBarrier(timeout: source == .manual ? 0.25 : 1), authority.permits(lease), !Task.isCancelled else {
            if authority.permits(lease) { authority.invalidate(); self.source = nil }
            throw PolicyError.unconfirmed
        }
        return lease
    }
    func valid(_ lease: MotionLease) -> Bool { authority.permits(lease) }
    func send(_ payload: [String: Any], lease: MotionLease, timeout: TimeInterval = 1) async throws -> [String: Any] {
        guard authority.permits(lease), !Task.isCancelled else { throw PolicyError.cancelled }
        if let barrier { guard await barrier.value else { throw PolicyError.unconfirmed } }
        guard authority.permits(lease), !Task.isCancelled else { throw PolicyError.cancelled }
        let value: [String: Any]
        if payload["type"] as? String == "stop" {
            guard await stopBarrier(timeout: timeout) else { throw PolicyError.unconfirmed }; value = ["ok": true]
        } else {
            guard let sendRaw else { throw PolicyError.unconfirmed }; value = try await sendRaw(payload, timeout)
        }
        guard authority.permits(lease), !Task.isCancelled else { throw PolicyError.cancelled }
        return value
    }
    func release(_ lease: MotionLease) { authority.release(lease); source = authority.owner }
    func invalidate() { authority.invalidate(); source = nil; preempt?() }
    // Revoke synchronously, before the caller's task can release its lease or a
    // different controller can take over. The queued barrier never revokes a newer owner.
    func stopCurrent(_ lease: MotionLease, timeout: TimeInterval = 0.25) {
        guard authority.permits(lease) else { return }
        invalidate()
        Task { _ = await stopBarrier(timeout: timeout) }
    }
    func stopCurrent(source: MotionSource) {
        guard authority.owner == source else { return }
        invalidate()
        Task { _ = await stopBarrier(timeout: 0.25) }
    }
    func stop(timeout: TimeInterval = 1) async -> Bool { invalidate(); return await stopBarrier(timeout: timeout) }
    // Manual zero/release barriers must not invalidate the remote's current lease.
    func manualStop() async -> Bool {
        if authority.owner != .manual { invalidate() }
        return await stopBarrier(timeout: 0.25)
    }
    private func stopBarrier(timeout: TimeInterval) async -> Bool {
        if let barrier { return await barrier.value }
        let id = UUID(); barrierID = id
        let work = Task { [weak self] in await self?.stopRaw?(timeout) ?? false }
        barrier = work
        let result = await work.value
        if barrierID == id { barrier = nil }
        return result
    }
}
