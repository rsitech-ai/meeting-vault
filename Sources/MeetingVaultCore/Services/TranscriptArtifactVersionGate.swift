import Foundation

public struct TranscriptArtifactVersionGate: Sendable {
    private let bundleStore: EncryptedMeetingBundleStore

    public init(bundleStore: EncryptedMeetingBundleStore) {
        self.bundleStore = bundleStore
    }

    public func validateCurrent(meetingID: UUID) throws -> TranscriptDerivedArtifactState {
        if try bundleStore.artifactExists(meetingID: meetingID, relativePath: TranscriptCorrectionRecoveryMarker.relativePath) {
            throw TranscriptArtifactVersionError.correctionInProgress
        }
        guard try bundleStore.artifactExists(meetingID: meetingID, relativePath: TranscriptDerivedArtifactState.relativePath) else {
            throw TranscriptArtifactVersionError.missingDerivedState
        }
        let transcript = try bundleStore.readJSONArtifact(
            MeetingTranscript.self,
            meetingID: meetingID,
            relativePath: MeetingTranscript.finalTranscriptRelativePath,
            purpose: MeetingTranscript.finalTranscriptPurpose
        )
        let intelligence = try bundleStore.readJSONArtifact(
            MeetingIntelligenceArtifact.self,
            meetingID: meetingID,
            relativePath: MeetingIntelligenceArtifact.summaryRelativePath,
            purpose: MeetingIntelligenceArtifact.summaryPurpose
        )
        let state = try bundleStore.readJSONArtifact(
            TranscriptDerivedArtifactState.self,
            meetingID: meetingID,
            relativePath: TranscriptDerivedArtifactState.relativePath,
            purpose: TranscriptDerivedArtifactState.purpose
        )
        let digest = try LocalFinalTranscriptionService.transcriptDigest(transcript)
        guard state.meetingID == meetingID, intelligence.meetingID == meetingID else {
            throw TranscriptArtifactVersionError.meetingMismatch
        }
        guard state.isConsistent,
              transcript.transcriptVersion == state.transcriptVersion,
              intelligence.transcriptVersion == state.transcriptVersion,
              digest == state.transcriptDigest,
              intelligence.transcriptDigest == digest else {
            throw TranscriptArtifactVersionError.mixedVersions
        }
        return state
    }

    public func validate(package: MeetingExportPackage) throws {
        if try bundleStore.artifactExists(meetingID: package.meetingID, relativePath: TranscriptCorrectionRecoveryMarker.relativePath) {
            throw TranscriptArtifactVersionError.correctionInProgress
        }
        if try bundleStore.artifactExists(meetingID: package.meetingID, relativePath: TranscriptDerivedArtifactState.relativePath) {
            let state = try validateCurrent(meetingID: package.meetingID)
            guard package.transcriptVersion == state.transcriptVersion,
                  package.transcriptDigest == state.transcriptDigest else {
                throw TranscriptArtifactVersionError.staleExportOrShare
            }
            return
        }
        let transcript = try bundleStore.readJSONArtifact(
            MeetingTranscript.self,
            meetingID: package.meetingID,
            relativePath: MeetingTranscript.finalTranscriptRelativePath,
            purpose: MeetingTranscript.finalTranscriptPurpose
        )
        let intelligence = try bundleStore.readJSONArtifact(
            MeetingIntelligenceArtifact.self,
            meetingID: package.meetingID,
            relativePath: MeetingIntelligenceArtifact.summaryRelativePath,
            purpose: MeetingIntelligenceArtifact.summaryPurpose
        )
        let digest = try LocalFinalTranscriptionService.transcriptDigest(transcript)
        guard transcript.transcriptVersion == intelligence.transcriptVersion,
              (intelligence.transcriptDigest == digest || (intelligence.transcriptDigest == "legacy" && transcript.transcriptVersion == 0)) else {
            throw TranscriptArtifactVersionError.mixedVersions
        }
        guard package.transcriptVersion == transcript.transcriptVersion,
              package.transcriptDigest == digest else {
            throw TranscriptArtifactVersionError.staleExportOrShare
        }
    }

    public func validate(manifest: MeetingShareManifest) throws {
        if try bundleStore.artifactExists(
            meetingID: manifest.meetingID,
            relativePath: TranscriptCorrectionRecoveryMarker.relativePath
        ) {
            throw TranscriptArtifactVersionError.correctionInProgress
        }
        if try bundleStore.artifactExists(
            meetingID: manifest.meetingID,
            relativePath: TranscriptDerivedArtifactState.relativePath
        ) {
            let state = try validateCurrent(meetingID: manifest.meetingID)
            guard manifest.transcriptVersion == state.transcriptVersion,
                  manifest.transcriptDigest == state.transcriptDigest else {
                throw TranscriptArtifactVersionError.staleExportOrShare
            }
            return
        }
        let transcript = try bundleStore.readJSONArtifact(
            MeetingTranscript.self,
            meetingID: manifest.meetingID,
            relativePath: MeetingTranscript.finalTranscriptRelativePath,
            purpose: MeetingTranscript.finalTranscriptPurpose
        )
        let intelligence = try bundleStore.readJSONArtifact(
            MeetingIntelligenceArtifact.self,
            meetingID: manifest.meetingID,
            relativePath: MeetingIntelligenceArtifact.summaryRelativePath,
            purpose: MeetingIntelligenceArtifact.summaryPurpose
        )
        let digest = try LocalFinalTranscriptionService.transcriptDigest(transcript)
        guard transcript.meetingID == manifest.meetingID,
              intelligence.meetingID == manifest.meetingID else {
            throw TranscriptArtifactVersionError.meetingMismatch
        }
        guard transcript.transcriptVersion == intelligence.transcriptVersion,
              (intelligence.transcriptDigest == digest
                || (intelligence.transcriptDigest == "legacy" && transcript.transcriptVersion == 0)) else {
            throw TranscriptArtifactVersionError.mixedVersions
        }
        guard manifest.transcriptVersion == transcript.transcriptVersion,
              manifest.transcriptDigest == digest else {
            throw TranscriptArtifactVersionError.staleExportOrShare
        }
    }
}
