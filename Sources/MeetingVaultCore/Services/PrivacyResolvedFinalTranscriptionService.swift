import Foundation

/// Resolves the authoritative final provider from the same persisted privacy
/// boundary as live transcription. Recording activity holds the boundary
/// stable from accepted Start through this final pass, so no session can switch
/// providers or network policy mid-recording.
public struct PrivacyResolvedFinalTranscriptionService: FinalTranscriptionServicing, Sendable {
    private let boundary: TranscriptionPrivacyBoundary
    private let local: any FinalTranscriptionServicing
    private let apple: any FinalTranscriptionServicing

    public init(
        boundary: TranscriptionPrivacyBoundary,
        local: any FinalTranscriptionServicing,
        apple: any FinalTranscriptionServicing
    ) {
        self.boundary = boundary
        self.local = local
        self.apple = apple
    }

    public func transcribe(
        meeting: SearchMeeting,
        records: [AudioChunkRecord],
        context: MeetingContext,
        speakerRenames: [String: String],
        indexSearch: Bool,
        previewEvidence: TranscriptPreviewEvidence
    ) async throws -> FinalTranscriptionResult {
        switch await boundary.mode() {
        case .localOnly:
            try await local.transcribe(
                meeting: meeting,
                records: records,
                context: context,
                speakerRenames: speakerRenames,
                indexSearch: indexSearch,
                previewEvidence: previewEvidence
            )
        case .appleOnDeviceOnly, .appleMayUseNetwork:
            try await apple.transcribe(
                meeting: meeting,
                records: records,
                context: context,
                speakerRenames: speakerRenames,
                indexSearch: indexSearch,
                previewEvidence: previewEvidence
            )
        }
    }
}

public struct UnavailableFinalTranscriptionService: FinalTranscriptionServicing, Sendable {
    public init() {}

    public func transcribe(
        meeting _: SearchMeeting,
        records _: [AudioChunkRecord],
        context _: MeetingContext,
        speakerRenames _: [String: String],
        indexSearch _: Bool,
        previewEvidence _: TranscriptPreviewEvidence
    ) async throws -> FinalTranscriptionResult {
        throw LocalModelInstallationError.unitNotReady
    }
}
