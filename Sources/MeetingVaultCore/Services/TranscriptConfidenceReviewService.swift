import CryptoKit
import Foundation

public struct TranscriptConfidenceReviewService: Sendable {
    public let transcriptConfidenceThreshold: Double
    public let speakerConfidenceThreshold: Double
    private let now: @Sendable () -> Date

    public init(
        transcriptConfidenceThreshold: Double = 0.70,
        speakerConfidenceThreshold: Double = 0.65,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        precondition(transcriptConfidenceThreshold.isFinite && (0...1).contains(transcriptConfidenceThreshold))
        precondition(speakerConfidenceThreshold.isFinite && (0...1).contains(speakerConfidenceThreshold))
        self.transcriptConfidenceThreshold = transcriptConfidenceThreshold
        self.speakerConfidenceThreshold = speakerConfidenceThreshold
        self.now = now
    }

    public func deriveQueue(
        transcript: MeetingTranscript,
        evidence: [TranscriptSegmentEvidence],
        transcriptVersion: Int,
        previous: TranscriptReviewQueue? = nil
    ) throws -> TranscriptReviewQueue {
        guard transcriptVersion >= 0 else { throw TranscriptReviewValidationError.invalidTranscriptVersion }
        if let previous, previous.meetingID != transcript.meetingID {
            throw TranscriptReviewRepositoryError.meetingMismatch
        }
        guard Set(transcript.segments.map(\.id)).count == transcript.segments.count,
              Set(evidence.map(\.segmentID)).count == evidence.count else {
            throw TranscriptReviewValidationError.duplicateSegmentID
        }
        for segment in transcript.segments {
            guard segment.startTime.isFinite, segment.endTime.isFinite,
                  segment.startTime >= 0, segment.endTime > segment.startTime,
                  segment.confidence.isFinite, (0...1).contains(segment.confidence) else {
                throw TranscriptReviewValidationError.evidenceSegmentMismatch
            }
        }
        let segments = Dictionary(uniqueKeysWithValues: transcript.segments.map { ($0.id, $0) })
        for item in evidence {
            guard let segment = segments[item.segmentID],
                  segment.trackKind == item.trackKind,
                  abs(segment.startTime - item.startTime) <= 0.001,
                  abs(segment.endTime - item.endTime) <= 0.001 else {
                throw TranscriptReviewValidationError.evidenceSegmentMismatch
            }
        }

        var generated: [TranscriptReviewItem] = []
        for item in evidence {
            var reasons: [(TranscriptReviewReason, Double?)] = []
            if let confidence = item.confidence, confidence < transcriptConfidenceThreshold {
                reasons.append((.lowConfidence, confidence))
            }
            if let confidence = item.speakerConfidence, confidence < speakerConfidenceThreshold {
                reasons.append((.uncertainSpeaker, confidence))
            }
            if item.speakerWasRevised { reasons.append((.revisedSpeaker, item.speakerConfidence)) }
            if item.overlapsSpeech { reasons.append((.overlap, item.confidence)) }
            if item.reconstructedFromPreviewGap { reasons.append((.reconstructedPreviewGap, item.confidence)) }
            for (reason, confidence) in reasons {
                generated.append(try makeItem(
                    meetingID: transcript.meetingID,
                    evidence: item,
                    reason: reason,
                    confidence: confidence,
                    transcriptVersion: transcriptVersion
                ))
            }
        }

        let reconciled = reconcile(generated: generated, previous: previous)
        return try TranscriptReviewQueue(
            meetingID: transcript.meetingID,
            transcriptDigest: LocalFinalTranscriptionService.transcriptDigest(transcript),
            transcriptVersion: transcriptVersion,
            evidenceComplete: !transcript.segments.isEmpty && evidence.count == transcript.segments.count,
            generatedAt: now(),
            items: reconciled
        )
    }

    private func makeItem(
        meetingID: UUID,
        evidence: TranscriptSegmentEvidence,
        reason: TranscriptReviewReason,
        confidence: Double?,
        transcriptVersion: Int
    ) throws -> TranscriptReviewItem {
        let identity = [
            meetingID.uuidString.lowercased(),
            evidence.segmentID.uuidString.lowercased(),
            evidence.trackKind.rawValue,
            canonicalTime(evidence.startTime),
            canonicalTime(evidence.endTime),
            reason.rawValue,
            evidence.providerConfigurationVersion,
        ].joined(separator: "|")
        return try TranscriptReviewItem(
            id: Self.stableUUID(for: identity),
            segmentID: evidence.segmentID,
            trackKind: evidence.trackKind,
            startTime: evidence.startTime,
            endTime: evidence.endTime,
            reason: reason,
            confidence: confidence,
            status: .needsReview,
            transcriptVersion: transcriptVersion,
            providerConfigurationVersion: evidence.providerConfigurationVersion
        )
    }

    private func reconcile(
        generated: [TranscriptReviewItem],
        previous: TranscriptReviewQueue?
    ) -> [TranscriptReviewItem] {
        guard let previous else { return generated }
        var unusedOld = previous.items.filter { $0.status != .superseded }
        var output: [TranscriptReviewItem] = []
        for var item in generated {
            let exactIndex = unusedOld.firstIndex { old in
                old.id == item.id && old.reason == item.reason
            }
            let fallbackCandidates = unusedOld.indices.filter { index in
                let old = unusedOld[index]
                return old.reason == item.reason
                    && old.trackKind == item.trackKind
                    && old.providerConfigurationVersion == item.providerConfigurationVersion
                    && Self.rangesMatch(oldStart: old.startTime, oldEnd: old.endTime, newStart: item.startTime, newEnd: item.endTime)
            }
            let fallbackIndex = exactIndex ?? (fallbackCandidates.count == 1 ? fallbackCandidates[0] : nil)
            if let index = fallbackIndex {
                let old = unusedOld.remove(at: index)
                if old.status == .resolved || old.status == .deferred {
                    item.status = old.status
                }
                if old.id != item.id {
                    var superseded = old
                    superseded.status = .superseded
                    output.append(superseded)
                }
            }
            output.append(item)
        }
        output.append(contentsOf: unusedOld.map { old in
            var value = old
            value.status = .superseded
            return value
        })
        output.append(contentsOf: previous.items.filter { $0.status == .superseded })
        return output
    }

    private static func rangesMatch(
        oldStart: TimeInterval,
        oldEnd: TimeInterval,
        newStart: TimeInterval,
        newEnd: TimeInterval
    ) -> Bool {
        let overlap = min(oldEnd, newEnd) - max(oldStart, newStart)
        guard overlap > 0 else { return false }
        let shorter = min(oldEnd - oldStart, newEnd - newStart)
        return overlap / shorter >= 0.8
    }

    private func canonicalTime(_ value: TimeInterval) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func stableUUID(for value: String) -> UUID {
        let hex = SHA256.hash(data: Data(value.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        let formatted = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
        return UUID(uuidString: formatted)!
    }
}

public struct TranscriptReviewRepository: Sendable {
    private let bundleStore: EncryptedMeetingBundleStore

    public init(bundleStore: EncryptedMeetingBundleStore) {
        self.bundleStore = bundleStore
    }

    public func load(meetingID: UUID) throws -> TranscriptReviewQueue {
        guard try bundleStore.artifactExists(meetingID: meetingID, relativePath: TranscriptReviewQueue.relativePath) else {
            throw TranscriptReviewRepositoryError.queueNotFound
        }
        return try bundleStore.readJSONArtifact(
            TranscriptReviewQueue.self,
            meetingID: meetingID,
            relativePath: TranscriptReviewQueue.relativePath,
            purpose: TranscriptReviewQueue.purpose
        ).validated(expectedMeetingID: meetingID)
    }

    public func loadIfPresent(meetingID: UUID) throws -> TranscriptReviewQueue? {
        guard try bundleStore.artifactExists(meetingID: meetingID, relativePath: TranscriptReviewQueue.relativePath) else {
            return nil
        }
        return try load(meetingID: meetingID)
    }

    public func save(_ queue: TranscriptReviewQueue) throws {
        _ = try queue.validated(expectedMeetingID: queue.meetingID)
        try bundleStore.writeJSONArtifact(
            queue,
            meetingID: queue.meetingID,
            relativePath: TranscriptReviewQueue.relativePath,
            purpose: TranscriptReviewQueue.purpose
        )
    }
}
