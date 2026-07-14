import Foundation
import os

/// A counting gate: `wait()` suspends until a permit is available; `permit()`
/// releases one banked or waiting caller. Lets tests hold an async callback
/// open at an exact lifecycle point and release it deterministically — the
/// alternative (sleep-based timing) flakes under a saturated CI executor.
final class AsyncPermitGate: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(
        initialState: (permits: 0, waiters: [CheckedContinuation<Void, Never>]())
    )

    func permit(_ count: Int = 1) {
        let toResume: [CheckedContinuation<Void, Never>] = lock.withLock { s in
            s.permits += count
            var resumable: [CheckedContinuation<Void, Never>] = []
            while s.permits > 0, !s.waiters.isEmpty {
                s.permits -= 1
                resumable.append(s.waiters.removeFirst())
            }
            return resumable
        }
        for continuation in toResume { continuation.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow: Bool = lock.withLock { s in
                if s.permits > 0 {
                    s.permits -= 1
                    return true
                }
                s.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}

/// Polls `condition` on the main actor until it holds or `timeout` elapses;
/// returns the final evaluation. Shared by suites that wait out asynchronous
/// state transitions — one implementation so CI-flake tuning (step, timeout)
/// can't drift between copies.
@MainActor
func waitUntil(
    timeout: Duration = .seconds(5),
    _ condition: @MainActor () -> Bool
) async -> Bool {
    var waited = Duration.zero
    while !condition(), waited < timeout {
        try? await Task.sleep(for: .milliseconds(10))
        waited += .milliseconds(10)
    }
    return condition()
}
