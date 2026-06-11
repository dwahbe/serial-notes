import Foundation
import Testing

@testable import SerialNotes

@Suite("Single Instance Guard")
struct SingleInstanceGuardTests {
    typealias Snapshot = SingleInstanceGuard.InstanceSnapshot
    typealias Decision = SingleInstanceGuard.Decision

    private let earlier = Date(timeIntervalSinceReferenceDate: 1_000)
    private let later = Date(timeIntervalSinceReferenceDate: 2_000)

    private func healthy(pid: pid_t, launch: Date?) -> Snapshot {
        Snapshot(pid: pid, launchDate: launch, executableStillExists: true, executableInTrash: false)
    }

    private func trashed(pid: pid_t, launch: Date? = nil) -> Snapshot {
        Snapshot(pid: pid, launchDate: launch, executableStillExists: true, executableInTrash: true)
    }

    private func deleted(pid: pid_t, launch: Date? = nil) -> Snapshot {
        Snapshot(pid: pid, launchDate: launch, executableStillExists: false, executableInTrash: false)
    }

    private func decide(
        _ others: [Snapshot],
        ownLaunch: Date? = nil,
        ownPID: pid_t = 500,
        readOnly: Bool = false
    ) -> Decision {
        SingleInstanceGuard.decide(
            others: others,
            ownLaunchDate: ownLaunch,
            ownPID: ownPID,
            launchedFromReadOnlyVolume: readOnly
        )
    }

    // MARK: - The common cases

    @Test("No other instances — proceed, even from a read-only volume")
    func noOthersProceeds() {
        #expect(decide([]) == .proceed)
        #expect(decide([], readOnly: true) == .proceed)
    }

    @Test("A healthy instance that launched earlier wins — defer to it")
    func healthyEarlierWins() {
        #expect(decide([healthy(pid: 100, launch: earlier)], ownLaunch: later) == .deferToOther)
    }

    @Test("A healthy instance that launched later loses — this one proceeds")
    func healthyLaterLoses() {
        #expect(decide([healthy(pid: 100, launch: later)], ownLaunch: earlier) == .proceed)
    }

    // MARK: - Install intent (DMG)

    @Test("Read-only source with anything running offers the replace flow")
    func readOnlyOffersReplace() {
        #expect(decide([healthy(pid: 100, launch: earlier)], ownLaunch: later, readOnly: true) == .offerReplace)
        #expect(decide([trashed(pid: 100)], readOnly: true) == .offerReplace)
        #expect(decide([trashed(pid: 100), healthy(pid: 200, launch: earlier)], readOnly: true) == .offerReplace)
    }

    // MARK: - Orphans

    @Test("Only orphans running — reclaim, whether trashed or deleted")
    func orphansOnlyReclaims() {
        #expect(decide([trashed(pid: 100)]) == .reclaimFromOrphans)
        #expect(decide([deleted(pid: 100)]) == .reclaimFromOrphans)
        #expect(decide([trashed(pid: 100), deleted(pid: 200)]) == .reclaimFromOrphans)
    }

    @Test("Orphan mixed with an earlier healthy instance — the healthy one wins")
    func mixedDefersToHealthy() {
        let others = [trashed(pid: 100), healthy(pid: 200, launch: earlier)]
        #expect(decide(others, ownLaunch: later) == .deferToOther)
    }

    @Test("Orphan mixed with a later healthy instance — this one proceeds")
    func mixedProceedsPastLaterHealthy() {
        let others = [trashed(pid: 100), healthy(pid: 200, launch: later)]
        #expect(decide(others, ownLaunch: earlier) == .proceed)
    }

    @Test("An orphan's launch date never outranks a fresh healthy launch")
    func orphanDateIgnored() {
        // The orphan launched first, but only healthy instances join the tie-break.
        let others = [trashed(pid: 100, launch: earlier)]
        #expect(decide(others, ownLaunch: later) == .reclaimFromOrphans)
    }

    // MARK: - Tie-breaks

    @Test("Equal launch dates fall back to the lower PID")
    func equalDatesUsePID() {
        #expect(decide([healthy(pid: 600, launch: earlier)], ownLaunch: earlier, ownPID: 500) == .proceed)
        #expect(decide([healthy(pid: 400, launch: earlier)], ownLaunch: earlier, ownPID: 500) == .deferToOther)
    }

    @Test("Unknown launch dates fall back to the lower PID")
    func nilDatesUsePID() {
        #expect(decide([healthy(pid: 600, launch: nil)], ownLaunch: nil, ownPID: 500) == .proceed)
        #expect(decide([healthy(pid: 400, launch: nil)], ownLaunch: nil, ownPID: 500) == .deferToOther)
        // Mixed nil/non-nil can't be ordered by date either.
        #expect(decide([healthy(pid: 600, launch: earlier)], ownLaunch: nil, ownPID: 500) == .proceed)
        #expect(decide([healthy(pid: 400, launch: nil)], ownLaunch: later, ownPID: 500) == .deferToOther)
    }

    @Test("Several healthy instances — survive only by beating every one")
    func mustBeatAllHealthy() {
        let others = [healthy(pid: 100, launch: later), healthy(pid: 200, launch: earlier)]
        #expect(decide(others, ownLaunch: Date(timeIntervalSinceReferenceDate: 1_500)) == .deferToOther)
        #expect(decide(others, ownLaunch: Date(timeIntervalSinceReferenceDate: 500)) == .proceed)
    }

    @Test("The tie-break is symmetric — exactly one of two racers wins")
    func tieBreakSymmetry() {
        let cases: [(Date?, pid_t, Date?, pid_t)] = [
            (earlier, 100, later, 200),
            (earlier, 200, earlier, 100),
            (nil, 100, nil, 200),
            (earlier, 100, nil, 200),
            (nil, 200, later, 100),
        ]
        for (dateA, pidA, dateB, pidB) in cases {
            let aWins = SingleInstanceGuard.winsTieBreak(
                ownLaunchDate: dateA, ownPID: pidA, otherLaunchDate: dateB, otherPID: pidB)
            let bWins = SingleInstanceGuard.winsTieBreak(
                ownLaunchDate: dateB, ownPID: pidB, otherLaunchDate: dateA, otherPID: pidA)
            #expect(aWins != bWins, "both or neither won: \(String(describing: dateA)),\(pidA) vs \(String(describing: dateB)),\(pidB)")
        }
    }

    // MARK: - Snapshot classification

    @Test("Orphan = executable in the Trash or gone; healthy otherwise")
    func orphanClassification() {
        #expect(trashed(pid: 1).isOrphan)
        #expect(deleted(pid: 1).isOrphan)
        #expect(!healthy(pid: 1, launch: nil).isOrphan)
    }
}
