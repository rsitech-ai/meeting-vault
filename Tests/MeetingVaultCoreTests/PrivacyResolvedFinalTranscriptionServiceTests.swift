import Foundation
import XCTest
@testable import MeetingVaultCore

final class PrivacyResolvedFinalTranscriptionServiceTests: XCTestCase {
    func testPrivacyModeRoutesNextFinalPassWithoutFallback() async throws {
        let boundary = TranscriptionPrivacyBoundary(mode: .localOnly)
        let local = FinalServiceProbe(label: "local")
        let apple = FinalServiceProbe(label: "apple")
        let service = PrivacyResolvedFinalTranscriptionService(
            boundary: boundary,
            local: local,
            apple: apple
        )
        let meeting = SearchMeeting(id: UUID(), title: "Fixture", startedAt: Date(), sourceApp: "Fixture")

        _ = try await service.transcribe(
            meeting: meeting,
            records: [],
            context: MeetingContext(localeIdentifier: "pl-PL"),
            speakerRenames: [:],
            indexSearch: false
        )
        await boundary.replaceMode(.appleOnDeviceOnly)
        _ = try await service.transcribe(
            meeting: meeting,
            records: [],
            context: MeetingContext(localeIdentifier: "en-US"),
            speakerRenames: [:],
            indexSearch: false
        )

        XCTAssertEqual(local.calls, ["local:pl-PL"])
        XCTAssertEqual(apple.calls, ["apple:en-US"])
    }
}

private final class FinalServiceProbe: FinalTranscriptionServicing, @unchecked Sendable {
    private let lock = NSLock()
    private let label: String
    private var storage: [String] = []
    var calls: [String] { lock.withLock { storage } }

    init(label: String) { self.label = label }

    func transcribe(
        meeting: SearchMeeting,
        records: [AudioChunkRecord],
        context: MeetingContext,
        speakerRenames: [String: String],
        indexSearch: Bool,
        previewEvidence _: TranscriptPreviewEvidence
    ) async throws -> FinalTranscriptionResult {
        lock.withLock { storage.append("\(label):\(context.localeIdentifier ?? "automatic")") }
        return FinalTranscriptionResult(
            transcript: MeetingTranscript(
                meetingID: meeting.id,
                localeIdentifier: context.localeIdentifier,
                segments: []
            ),
            indexedSegmentCount: 0
        )
    }
}
