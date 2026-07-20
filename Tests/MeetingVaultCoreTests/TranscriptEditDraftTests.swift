import Foundation
import XCTest
@testable import MeetingVaultCore

final class TranscriptEditDraftTests: XCTestCase {
    func testTranscriptEditDraftBuildsValidatedServiceEditsOnlyForChangedRows() throws {
        let firstSegmentID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let secondSegmentID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let meetingID = UUID()
        let transcript = MeetingTranscript(
            meetingID: meetingID,
            localeIdentifier: "en-US",
            generatedAt: Date(timeIntervalSince1970: 1_780_010_000),
            segments: [
                TranscriptSegment(
                    id: firstSegmentID,
                    speakerName: "Unknown speaker",
                    trackKind: .remoteSystem,
                    startTime: 10,
                    endTime: 16,
                    text: "Original deployment date is Friday.",
                    confidence: 0.72,
                    isFinal: true
                ),
                TranscriptSegment(
                    id: secondSegmentID,
                    speakerName: "You",
                    trackKind: .microphone,
                    startTime: 19,
                    endTime: 25,
                    text: "I will update the release notes.",
                    confidence: 0.90,
                    isFinal: true
                )
            ]
        )
        let history = TranscriptEditHistory(
            meetingID: meetingID,
            entries: [
                TranscriptEditHistoryEntry(
                    version: 1,
                    editedAt: Date(timeIntervalSince1970: 1_780_010_500),
                    editedSegmentIDs: [secondSegmentID]
                )
            ]
        )

        var draft = TranscriptEditDraft(transcript: transcript, history: history)
        XCTAssertEqual(draft.meetingID, meetingID)
        XCTAssertEqual(draft.currentVersion, 1)
        XCTAssertFalse(draft.hasChanges)
        XCTAssertEqual(try draft.validatedEdits(), [])

        try draft.updateSegment(
            id: firstSegmentID,
            speakerName: " Anna ",
            text: " Deployment moves to Thursday after QA sign-off. "
        )

        XCTAssertTrue(draft.hasChanges)
        XCTAssertEqual(draft.changedSegmentCount, 1)

        let edits = try draft.validatedEdits()
        XCTAssertEqual(
            edits,
            [
                TranscriptSegmentEdit(
                    segmentID: firstSegmentID,
                    replacementText: "Deployment moves to Thursday after QA sign-off.",
                    replacementSpeakerName: "Anna"
                )
            ]
        )

        draft.markSaved(version: 2)
        XCTAssertEqual(draft.currentVersion, 2)
        XCTAssertFalse(draft.hasChanges)
        XCTAssertEqual(try draft.validatedEdits(), [])
        XCTAssertEqual(draft.segments.first?.originalSpeakerName, "Anna")
        XCTAssertEqual(draft.segments.first?.originalText, "Deployment moves to Thursday after QA sign-off.")
    }

    func testTranscriptEditDraftRejectsBlankTextAndUnknownSegments() throws {
        let segmentID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let transcript = MeetingTranscript(
            meetingID: UUID(),
            localeIdentifier: nil,
            segments: [
                TranscriptSegment(
                    id: segmentID,
                    speakerName: "Unknown speaker",
                    trackKind: .remoteSystem,
                    startTime: 0,
                    endTime: 4,
                    text: "Keep this segment.",
                    confidence: 0.8,
                    isFinal: true
                )
            ]
        )
        var draft = TranscriptEditDraft(transcript: transcript)

        let unknownSegmentID = UUID()
        XCTAssertThrowsError(
            try draft.updateSegment(id: unknownSegmentID, speakerName: nil as String?, text: "Unknown")
        ) { error in
            XCTAssertEqual(error as? TranscriptEditError, .segmentNotFound(unknownSegmentID))
        }

        try draft.updateSegment(id: segmentID, speakerName: nil as String?, text: "   ")
        XCTAssertThrowsError(try draft.validatedEdits()) { error in
            XCTAssertEqual(error as? TranscriptEditError, .blankReplacementText(segmentID))
        }
    }
}
