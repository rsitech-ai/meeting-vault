import Foundation

public struct MeetingSharePreparationService {
    private let auditWriter: PrivacyAuditLogWriter?
    private let versionGate: TranscriptArtifactVersionGate?

    public init(
        auditWriter: PrivacyAuditLogWriter? = nil,
        versionGate: TranscriptArtifactVersionGate? = nil
    ) {
        self.auditWriter = auditWriter
        self.versionGate = versionGate
    }

    public func prepareShare(
        meetingID: UUID,
        package: MeetingExportPackage,
        destination: MeetingShareDestination
    ) throws -> MeetingShareManifest {
        guard package.meetingID == meetingID else {
            throw TranscriptArtifactVersionError.meetingMismatch
        }
        try versionGate?.validate(package: package)
        let files = package.files.map { file in
            MeetingShareFile(format: file.format, url: file.url)
        }

        try auditWriter?.append(
            action: .sharePrepare,
            meetingID: meetingID,
            metadata: [
                "destination": destination.rawValue,
                "fileCount": "\(files.count)",
                "formats": files.map(\.format.rawValue).joined(separator: ",")
            ]
        )

        return MeetingShareManifest(
            meetingID: meetingID,
            transcriptVersion: package.transcriptVersion,
            transcriptDigest: package.transcriptDigest,
            destination: destination,
            files: files,
            requiresUserConfirmation: true
        )
    }

    /// Rechecks the authoritative encrypted artifact generation immediately
    /// before an external share destination is opened.
    public func validatePreparedShare(_ manifest: MeetingShareManifest) throws {
        try versionGate?.validate(manifest: manifest)
    }
}
