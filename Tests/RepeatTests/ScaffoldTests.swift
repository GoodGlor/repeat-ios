import XCTest
import Scheduling
@testable import Repeat

/// Card #1 acceptance, expressed as tests. These stay green for the life of the
/// project — they assert the scaffold's contract, not any feature behaviour.
final class ScaffoldTests: XCTestCase {

    func testFSRSPackageLinksAndExposesVersionSix() {
        XCTAssertEqual(SchedulerConfig().weights.count, 21, "spec §5.1 requires FSRS-6, which has a 21-element w")
        XCTAssertEqual(Scheduler().algorithmVersion, .v6)
    }

    func testLearningStepsMatchSpec() {
        // Spec §5.1: learning steps 1m, 10m; relearning step 10m.
        XCTAssertEqual(SchedulerConfig().learningSteps, ["1m", "10m"])
        XCTAssertEqual(SchedulerConfig().relearningSteps, ["10m"])
    }

    func testAppGroupIdentifierMatchesEntitlements() {
        XCTAssertEqual(AppGroup.identifier, "group.com.goodglor.repeat")
    }

    /// Proves the entitlement is applied and the container is usable in-process.
    /// Cross-process sharing (extension writes, app reads) is verified on device
    /// with the Share Extension in #28 — the simulator cannot stand in for that.
    func testAppGroupContainerIsReachableAndWritable() throws {
        let container = try XCTUnwrap(
            AppGroup.containerURL,
            "App Group entitlement missing — check DEVELOPMENT_TEAM and that the group is provisioned"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: container.path))

        XCTAssertTrue(AppGroup.prepare())
        let inbox = try XCTUnwrap(AppGroup.inboxURL)
        let probe = inbox.appendingPathComponent("probe-\(UUID().uuidString).json")
        try Data("{}".utf8).write(to: probe)
        addTeardownBlock { try? FileManager.default.removeItem(at: probe) }
        XCTAssertEqual(try Data(contentsOf: probe), Data("{}".utf8))
    }
}
