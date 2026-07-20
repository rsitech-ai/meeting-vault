import Foundation
import XCTest
@testable import MeetingVaultCore

final class RetentionCleanupTests: XCTestCase {
    func testRetentionCleanupPlansAndDeletesOnlyExpiredMeetingBundles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultRetention-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let vault = AESGCMDataVault(
            keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 61, count: 32))
        )
        let bundleStore = EncryptedMeetingBundleStore(rootDirectory: root, vault: vault)
        let now = Date(timeIntervalSince1970: 1_780_003_000)

        let expiredID = UUID()
        var expired = MeetingBundleManifest.initialEncryptedBundle(
            meetingID: expiredID,
            title: "Expired customer call"
        )
        expired.createdAt = now.addingTimeInterval(-46 * 86_400)
        _ = try bundleStore.createBundle(expired)

        let recentID = UUID()
        var recent = MeetingBundleManifest.initialEncryptedBundle(
            meetingID: recentID,
            title: "Recent roadmap call"
        )
        recent.createdAt = now.addingTimeInterval(-2 * 86_400)
        _ = try bundleStore.createBundle(recent)

        let unrelatedDirectory = root.appendingPathComponent("manual-export", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelatedDirectory, withIntermediateDirectories: true)

        let service = RetentionCleanupService(bundleStore: bundleStore)
        let plan = try service.planCleanup(
            policy: RetentionPolicy(retentionDays: 30),
            now: now
        )

        XCTAssertEqual(plan.candidates.map(\.meetingID), [expiredID])
        XCTAssertEqual(plan.candidates.first?.title, "Expired customer call")
        XCTAssertEqual(plan.candidates.first?.ageDays, 46)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleStore.bundleURL(for: expiredID).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleStore.bundleURL(for: recentID).path))

        let result = try service.apply(plan)

        XCTAssertEqual(result.deletedMeetingIDs, [expiredID])
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundleStore.bundleURL(for: expiredID).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleStore.bundleURL(for: recentID).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedDirectory.path))
        XCTAssertEqual(try bundleStore.listMeetingBundleIDs(), [recentID])
    }
}
