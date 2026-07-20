import Foundation
import XCTest
@testable import MeetingVaultCore

final class TranscriptQuestionHistoryTests: XCTestCase {
    func testTranscriptQuestionHistoryPersistsEncryptedEditableTurns() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVaultTranscriptQuestionHistory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let meetingID = UUID()
        let segmentID = UUID()
        let keyProvider = InMemorySymmetricKeyProvider(keyData: Data(repeating: 117, count: 32))
        let vault = AESGCMDataVault(keyProvider: keyProvider)
        let bundleStore = EncryptedMeetingBundleStore(rootDirectory: root, vault: vault)
        _ = try bundleStore.createBundle(
            MeetingBundleManifest.initialEncryptedBundle(
                meetingID: meetingID,
                title: "Agent persistence smoke"
            )
        )
        let service = TranscriptQuestionHistoryService(bundleStore: bundleStore)
        let answer = TranscriptQuestionAnswer(
            meetingID: meetingID,
            question: "What launch risk did Marta mention?",
            answerText: "Marta mentioned that legal review is still open.",
            editableText: "Edited answer: legal review is still open.",
            evidence: [
                TranscriptQuestionEvidence(
                    segmentID: segmentID,
                    speakerName: "Marta",
                    startTime: 44,
                    endTime: 52,
                    quote: "Legal review is still open before launch."
                )
            ]
        )

        let saved = try service.record(answer: answer, createdAt: Date(timeIntervalSince1970: 1_780_030_000))
        let loaded = try service.load(meetingID: meetingID)

        XCTAssertEqual(saved, loaded)
        XCTAssertEqual(loaded.meetingID, meetingID)
        XCTAssertEqual(loaded.turns.map(\.question), ["What launch risk did Marta mention?"])
        XCTAssertEqual(loaded.turns.first?.answerDraft, "Edited answer: legal review is still open.")
        XCTAssertEqual(loaded.turns.first?.evidence.first?.segmentID, segmentID)

        let rawHistory = try String(
            data: Data(
                contentsOf: bundleStore.bundleURL(for: meetingID)
                    .appendingPathComponent(TranscriptQuestionHistory.relativePath)
            ),
            encoding: .utf8
        ) ?? ""
        XCTAssertFalse(rawHistory.contains("What launch risk"))
        XCTAssertFalse(rawHistory.contains("Edited answer"))
        XCTAssertFalse(rawHistory.contains("Legal review"))
    }
}
