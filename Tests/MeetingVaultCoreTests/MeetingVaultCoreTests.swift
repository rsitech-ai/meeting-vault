import XCTest
@testable import MeetingVaultCore

final class MeetingVaultCoreTests: XCTestCase {
    func testPreflightBlocksUnknownConsentWhenPolicyRequiresIt() {
        let result = CompliancePolicy.evaluatePreflight(
            RecordingPreflightInput(
                consentStatus: .unknown,
                hasAudioPermission: true,
                hasMicrophonePermission: true,
                hasSpeechPermission: true,
                freeDiskBytes: CompliancePolicy.minimumFreeDiskBytes + 1,
                requireConsentBeforeRecording: true
            )
        )

        XCTAssertFalse(result.canRecord)
        XCTAssertEqual(result.issues, [.consentRequired])
    }

    func testPreflightFailsClosedForDoNotRecordEvenWithPermissions() {
        let result = CompliancePolicy.evaluatePreflight(
            RecordingPreflightInput(
                consentStatus: .doNotRecord,
                hasAudioPermission: true,
                hasMicrophonePermission: true,
                hasSpeechPermission: true,
                freeDiskBytes: CompliancePolicy.minimumFreeDiskBytes + 1,
                requireConsentBeforeRecording: false
            )
        )

        XCTAssertFalse(result.canRecord)
        XCTAssertEqual(result.issues, [.doNotRecord])
    }

    func testMeetingBundleManifestUsesEncryptedSeparateTracks() {
        let manifest = MeetingBundleManifest.initialEncryptedBundle(
            meetingID: UUID(),
            title: "Architecture review"
        )

        XCTAssertEqual(Set(manifest.tracks.map(\.kind)), [.remoteSystem, .microphone, .mixedPlayback])
        XCTAssertTrue(manifest.tracks.allSatisfy(\.encrypted))
        XCTAssertTrue(manifest.tracks.contains { $0.relativePath == "audio/remote_original.caf.enc" })
    }

    func testIntelligenceValidatorRejectsUnsupportedActionItems() {
        let summary = MeetingSummary(
            title: "Ungrounded",
            oneParagraph: "A generated summary.",
            bullets: [],
            decisions: [],
            actionItems: [
                ActionItem(title: "Ship tomorrow", evidence: [], confidence: 0.8)
            ]
        )

        XCTAssertThrowsError(try IntelligenceValidator.validate(summary)) { error in
            XCTAssertEqual(error as? IntelligenceValidationError, .actionItemMissingEvidence("Ship tomorrow"))
        }
    }

    func testIntelligenceValidatorAcceptsEvidenceLinkedArtifacts() throws {
        let meetingID = UUID()
        let evidence = EvidenceRef(
            meetingID: meetingID,
            segmentID: UUID(),
            startTime: 10,
            endTime: 14,
            quote: "We need QA sign-off first."
        )
        let summary = MeetingSummary(
            title: "Grounded",
            oneParagraph: "The release depends on QA.",
            bullets: ["QA is the release gate."],
            decisions: [
                Decision(title: "Wait for QA", details: "Do not ship before QA sign-off.", evidence: [evidence], confidence: 0.9)
            ],
            actionItems: [
                ActionItem(title: "Get QA sign-off", ownerName: "You", evidence: [evidence], confidence: 0.85)
            ]
        )

        XCTAssertNoThrow(try IntelligenceValidator.validate(summary))
    }

    func testLogRedactorRemovesSensitiveMeetingContent() {
        let secretRedacted = LogRedactor.redact("token: abc123 owner=alex@example.com")
        let pathRedacted = LogRedactor.redact("path=/Users/example/Music/Recorder/private.mp3")
        let transcriptRedacted = LogRedactor.redact("transcript: private roadmap details")

        XCTAssertFalse(secretRedacted.contains("abc123"))
        XCTAssertFalse(secretRedacted.contains("alex@example.com"))
        XCTAssertTrue(secretRedacted.contains("[redacted]"))
        XCTAssertTrue(secretRedacted.contains("[redacted-email]"))

        XCTAssertFalse(pathRedacted.contains("/Users/example"))
        XCTAssertFalse(pathRedacted.contains("Recorder"))
        XCTAssertTrue(pathRedacted.contains("[redacted-path]"))

        XCTAssertFalse(transcriptRedacted.contains("private roadmap"))
        XCTAssertTrue(transcriptRedacted.contains("[redacted-content]"))
    }
}
