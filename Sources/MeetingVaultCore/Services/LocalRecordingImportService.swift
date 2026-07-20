import Foundation

public enum LocalRecordingImportError: Error, Equatable {
    case transcriptUnreadable
    case transcriptHasNoSegments
    case audioUnreadable
    case unsupportedTranscriptExtension(String)
    case unsupportedAudioExtension(String)
    case transcriptTooLarge(Int64)
    case audioTooLarge(Int64)
    case sourceMustBeRegularFile(String)
}

extension LocalRecordingImportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .transcriptUnreadable:
            "Transcript file could not be read. Use a UTF-8, UTF-16, or ISO Latin text transcript."
        case .transcriptHasNoSegments:
            "Transcript file has no importable timestamped segments."
        case .audioUnreadable:
            "Recording file could not be read."
        case let .unsupportedTranscriptExtension(value):
            "Unsupported transcript type .\(value.isEmpty ? "unknown" : value). Use TXT, SRT, or VTT."
        case let .unsupportedAudioExtension(value):
            "Unsupported recording type .\(value.isEmpty ? "unknown" : value). Use MP3, M4A, AAC, WAV, AIF, AIFF, AIFC, or CAF."
        case let .transcriptTooLarge(bytes):
            "Transcript file is too large to import safely (\(bytes) bytes; 32 MB maximum)."
        case let .audioTooLarge(bytes):
            "Recording file is too large to import safely (\(bytes) bytes; 192 MB maximum)."
        case let .sourceMustBeRegularFile(name):
            "\(name) must be a regular local file, not a folder or symbolic link."
        }
    }
}

public struct LocalRecordingImportService: @unchecked Sendable {
    public static let supportedTranscriptExtensions: Set<String> = ["txt", "srt", "vtt"]
    public static let supportedAudioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "aifc", "caf"]
    public static let maximumTranscriptBytes: Int64 = 32 * 1_024 * 1_024
    public static let maximumAudioBytes: Int64 = 192 * 1_024 * 1_024

    private let repository: MeetingLibraryRepository
    private let chunkWriter: EncryptedAudioChunkWriter
    private let fileManager: FileManager

    public init(
        repository: MeetingLibraryRepository,
        chunkWriter: EncryptedAudioChunkWriter,
        fileManager: FileManager = .default
    ) {
        self.repository = repository
        self.chunkWriter = chunkWriter
        self.fileManager = fileManager
    }

    public func importRecording(_ request: LocalRecordingImportRequest) throws -> LocalRecordingImportResult {
        let transcriptExtension = request.transcriptURL.pathExtension.lowercased()
        guard Self.supportedTranscriptExtensions.contains(transcriptExtension) else {
            throw LocalRecordingImportError.unsupportedTranscriptExtension(transcriptExtension)
        }

        let audioExtension = request.audioURL.pathExtension.lowercased()
        guard Self.supportedAudioExtensions.contains(audioExtension) else {
            throw LocalRecordingImportError.unsupportedAudioExtension(audioExtension)
        }

        let transcriptByteCount = try validatedFileByteCount(
            at: request.transcriptURL,
            maximumBytes: Self.maximumTranscriptBytes,
            tooLargeError: LocalRecordingImportError.transcriptTooLarge
        )
        let audioByteCount = try validatedFileByteCount(
            at: request.audioURL,
            maximumBytes: Self.maximumAudioBytes,
            tooLargeError: LocalRecordingImportError.audioTooLarge
        )
        guard transcriptByteCount > 0,
              let transcriptText = readTranscriptText(at: request.transcriptURL)
        else { throw LocalRecordingImportError.transcriptUnreadable }
        guard audioByteCount > 0 else { throw LocalRecordingImportError.audioUnreadable }

        let parsedSegments = parseTranscript(transcriptText)
        guard !parsedSegments.isEmpty else {
            throw LocalRecordingImportError.transcriptHasNoSegments
        }

        let meetingID = UUID()
        let startedAt = startDate(from: request.transcriptURL) ?? request.importedAt
        let title = normalizedTitle(
            request.title,
            transcriptURL: request.transcriptURL,
            startedAt: startedAt
        )
        let segments = makeSegments(parsedSegments: parsedSegments)
        let duration = segments.map(\.endTime).max() ?? 0
        let sourceName = "Imported recording / \(request.sourceName.trimmingCharacters(in: .whitespacesAndNewlines))"
        let searchMeeting = SearchMeeting(
            id: meetingID,
            title: title,
            startedAt: startedAt,
            sourceApp: sourceName
        )
        let record = MeetingRecord(
            id: meetingID,
            title: title,
            startedAt: startedAt,
            durationSeconds: duration,
            sourceName: sourceName,
            state: .ready,
            consentStatus: request.consentStatus
        )
        let transcript = MeetingTranscript(
            meetingID: meetingID,
            localeIdentifier: request.localeIdentifier,
            generatedAt: request.importedAt,
            segments: segments
        )
        let metadata = LocalRecordingImportMetadata(
            importedAt: request.importedAt,
            transcriptFileName: request.transcriptURL.lastPathComponent,
            audioFileName: request.audioURL.lastPathComponent,
            audioByteCount: Int(audioByteCount),
            transcriptLineCount: parsedSegments.count
        )

        do {
            try repository.save(
                MeetingLibraryEntry(
                    record: record,
                    searchMeeting: searchMeeting,
                    transcript: transcript,
                    editHistory: TranscriptEditHistory(meetingID: meetingID)
                )
            )
            let importedAudioChunks = try writeImportedAudioChunks(
                audioURL: request.audioURL,
                audioByteCount: audioByteCount,
                meetingID: meetingID,
                duration: duration
            )
            try repository.saveLocalRecordingImportMetadata(metadata, meetingID: meetingID)

            return LocalRecordingImportResult(
                record: record,
                searchMeeting: searchMeeting,
                transcript: transcript,
                metadata: metadata,
                audioChunks: importedAudioChunks
            )
        } catch {
            do {
                try repository.discard(meetingID: meetingID)
            } catch let rollbackError {
                throw LocalRecordingImportRollbackError(importError: error, rollbackError: rollbackError)
            }
            throw error
        }
    }

    public func importRecording(
        _ request: LocalRecordingImportRequest,
        intelligenceService: MeetingIntelligenceService?
    ) async throws -> LocalRecordingImportResult {
        let imported = try importRecording(request)
        guard let intelligenceService else {
            return imported
        }

        let intelligence: MeetingIntelligenceArtifact
        do {
            intelligence = try await intelligenceService.generateSummary(meetingID: imported.record.id)
        } catch let error as FoundationModelsMeetingIntelligenceError {
            return LocalRecordingImportResult(
                record: imported.record,
                searchMeeting: imported.searchMeeting,
                transcript: imported.transcript,
                metadata: imported.metadata,
                audioChunks: imported.audioChunks,
                intelligenceOutcome: .unavailable(error.errorDescription ?? "Foundation Models intelligence unavailable")
            )
        } catch let error as IntelligenceValidationError {
            return LocalRecordingImportResult(
                record: imported.record,
                searchMeeting: imported.searchMeeting,
                transcript: imported.transcript,
                metadata: imported.metadata,
                audioChunks: imported.audioChunks,
                intelligenceOutcome: .unavailable("Generated meeting intelligence failed transcript evidence validation: \(error)")
            )
        }
        let generatedTitle = try MeetingGeneratedTitleService.title(
            from: intelligence.summary,
            transcript: imported.transcript
        )
        let record = MeetingRecord(
            id: imported.record.id,
            title: generatedTitle,
            startedAt: imported.record.startedAt,
            durationSeconds: imported.record.durationSeconds,
            sourceName: imported.record.sourceName,
            state: imported.record.state,
            consentStatus: imported.record.consentStatus,
            summary: intelligence.summary
        )
        let searchMeeting = SearchMeeting(
            id: imported.searchMeeting.id,
            title: generatedTitle,
            startedAt: imported.searchMeeting.startedAt,
            sourceApp: imported.searchMeeting.sourceApp
        )
        try repository.save(
            MeetingLibraryEntry(
                record: record,
                searchMeeting: searchMeeting,
                transcript: imported.transcript,
                editHistory: TranscriptEditHistory(meetingID: imported.record.id)
            )
        )

        return LocalRecordingImportResult(
            record: record,
            searchMeeting: searchMeeting,
            transcript: imported.transcript,
            metadata: imported.metadata,
            audioChunks: imported.audioChunks,
            intelligenceOutcome: .generated
        )
    }

    private func parseTranscript(_ text: String) -> [ParsedLocalRecordingSegment] {
        let timestampedSegments = parseBracketedTimestampTranscript(text)
        if !timestampedSegments.isEmpty {
            return timestampedSegments
        }
        let timedCueSegments = parseTimedCueTranscript(text)
        if !timedCueSegments.isEmpty {
            return timedCueSegments
        }
        return parsePlainTextTranscript(text)
    }

    private func parseBracketedTimestampTranscript(_ text: String) -> [ParsedLocalRecordingSegment] {
        var segments: [ParsedLocalRecordingSegment] = []
        var current: ParsedLocalRecordingSegment?

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if let parsed = parseTimestampedLine(line) {
                if let current, !current.text.isEmpty {
                    segments.append(current)
                }
                current = parsed
            } else if current != nil {
                current?.text += " \(line)"
            }
        }

        if let current, !current.text.isEmpty {
            segments.append(current)
        }

        return segments
    }

    private func parseTimedCueTranscript(_ text: String) -> [ParsedLocalRecordingSegment] {
        let normalizedText = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let blocks = normalizedText.components(separatedBy: "\n\n")

        return blocks.compactMap { block in
            let lines = block
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !$0.localizedCaseInsensitiveContains("WEBVTT") }
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else {
                return nil
            }
            let timingParts = lines[timingIndex].components(separatedBy: "-->")
            guard timingParts.count == 2,
                  let startTime = seconds(fromCueTimestamp: timingParts[0]),
                  let endTime = seconds(fromCueTimestamp: timingParts[1])
            else {
                return nil
            }

            let body = lines.dropFirst(timingIndex + 1)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else {
                return nil
            }
            let speakerAndText = speakerAndText(fromTimedCueBody: body)
            guard !speakerAndText.text.isEmpty else {
                return nil
            }
            return ParsedLocalRecordingSegment(
                speakerName: speakerAndText.speaker,
                startTime: startTime,
                endTime: max(startTime + 0.5, endTime),
                text: speakerAndText.text
            )
        }
    }

    private func parsePlainTextTranscript(_ text: String) -> [ParsedLocalRecordingSegment] {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return [] }

        var startTime: TimeInterval = 0
        var segments: [ParsedLocalRecordingSegment] = []
        for line in lines {
            let speakerAndText = speakerAndText(fromTimedCueBody: line)
            let words = speakerAndText.text.split(whereSeparator: \.isWhitespace)
            for wordOffset in stride(from: 0, to: words.count, by: 80) {
                let endOffset = min(wordOffset + 80, words.count)
                let chunk = words[wordOffset..<endOffset].joined(separator: " ")
                let duration = max(2.0, Double(endOffset - wordOffset) / 2.6)
                segments.append(
                    ParsedLocalRecordingSegment(
                        speakerName: speakerAndText.speaker,
                        startTime: startTime,
                        endTime: startTime + duration,
                        text: chunk
                    )
                )
                startTime += duration
            }
        }
        return segments
    }

    private func parseTimestampedLine(_ line: String) -> ParsedLocalRecordingSegment? {
        guard line.hasPrefix("["),
              let closeBracket = line.firstIndex(of: "]")
        else {
            return nil
        }

        let timestampText = String(line[line.index(after: line.startIndex)..<closeBracket])
        guard let startTime = seconds(from: timestampText) else {
            return nil
        }

        let remainder = line[line.index(after: closeBracket)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = remainder.firstIndex(of: ":") else {
            return nil
        }

        let speaker = String(remainder[..<colon])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let text = String(remainder[remainder.index(after: colon)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !speaker.isEmpty, !text.isEmpty else {
            return nil
        }

        return ParsedLocalRecordingSegment(
            speakerName: speaker,
            startTime: startTime,
            endTime: nil,
            text: text
        )
    }

    private func makeSegments(parsedSegments: [ParsedLocalRecordingSegment]) -> [TranscriptSegment] {
        parsedSegments.enumerated().map { index, parsed in
            let nextStart = parsedSegments.indices.contains(index + 1)
                ? parsedSegments[index + 1].startTime
                : parsed.startTime + 5
            return TranscriptSegment(
                speakerName: parsed.speakerName,
                trackKind: .mixedPlayback,
                startTime: parsed.startTime,
                endTime: max(parsed.startTime + 0.5, parsed.endTime ?? nextStart),
                text: parsed.text,
                confidence: 0.86,
                isFinal: true
            )
        }
    }

    private func writeImportedAudioChunks(
        audioURL: URL,
        audioByteCount: Int64,
        meetingID: UUID,
        duration: TimeInterval
    ) throws -> [AudioChunkRecord] {
        let data = try Data(contentsOf: audioURL, options: [.mappedIfSafe])
        guard Int64(data.count) == audioByteCount, !data.isEmpty else {
            throw LocalRecordingImportError.audioUnreadable
        }
        let codec = audioURL.pathExtension.lowercased().isEmpty ? "binary" : audioURL.pathExtension.lowercased()
        return [
            try chunkWriter.writeChunk(
                data,
                meetingID: meetingID,
                track: .mixedPlayback,
                chunkIndex: 0,
                startTime: 0,
                duration: max(duration, 0.5),
                codec: codec
            )
        ]
    }

    private func seconds(from timestamp: String) -> TimeInterval? {
        let parts = timestamp.split(separator: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2])
        else {
            return nil
        }
        return (hours * 3_600) + (minutes * 60) + seconds
    }

    private func seconds(fromCueTimestamp timestamp: String) -> TimeInterval? {
        let cleaned = timestamp
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .first?
            .replacingOccurrences(of: ",", with: ".") ?? ""
        let parts = cleaned.split(separator: ":")
        if parts.count == 3,
           let hours = Double(parts[0]),
           let minutes = Double(parts[1]),
           let seconds = Double(parts[2]) {
            return (hours * 3_600) + (minutes * 60) + seconds
        }
        if parts.count == 2,
           let minutes = Double(parts[0]),
           let seconds = Double(parts[1]) {
            return (minutes * 60) + seconds
        }
        return nil
    }

    private func speakerAndText(fromTimedCueBody body: String) -> (speaker: String, text: String) {
        if body.hasPrefix("<v "),
           let close = body.firstIndex(of: ">") {
            let speakerStart = body.index(body.startIndex, offsetBy: 3)
            let speaker = String(body[speakerStart..<close])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let text = stripCueMarkup(String(body[body.index(after: close)...]))
            return (
                speaker.isEmpty ? "Imported Transcript" : speaker,
                text
            )
        }

        let strippedBody = stripCueMarkup(body)
        if let colon = strippedBody.firstIndex(of: ":") {
            let speaker = String(strippedBody[..<colon])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let text = String(strippedBody[strippedBody.index(after: colon)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !speaker.isEmpty, speaker.count <= 40, !text.isEmpty {
                return (speaker, text)
            }
        }

        return ("Imported Transcript", strippedBody)
    }

    private func stripCueMarkup(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"<[^>]+>"#,
            with: "",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func readTranscriptText(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        if let utf16 = String(data: data, encoding: .utf16) {
            return utf16
        }
        return String(data: data, encoding: .isoLatin1)
    }

    private func startDate(from transcriptURL: URL) -> Date? {
        let name = transcriptURL.deletingPathExtension().lastPathComponent
        let prefix = String(name.prefix(13))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd HHmm"
        return formatter.date(from: prefix)
    }

    private func normalizedTitle(
        _ title: String?,
        transcriptURL: URL,
        startedAt: Date
    ) -> String {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedTitle.isEmpty {
            return trimmedTitle
        }

        let name = transcriptURL.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: " Transcription", with: "")
        return name.isEmpty ? "Imported Local Recording" : name
    }

    private func validatedFileByteCount(
        at url: URL,
        maximumBytes: Int64,
        tooLargeError: (Int64) -> LocalRecordingImportError
    ) throws -> Int64 {
        guard fileManager.fileExists(atPath: url.path) else {
            throw url.pathExtension.lowercased().mapToTranscriptOrAudioError(
                transcriptExtensions: Self.supportedTranscriptExtensions
            )
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw LocalRecordingImportError.sourceMustBeRegularFile(url.lastPathComponent)
        }
        let bytes = Int64(values.fileSize ?? 0)
        guard bytes <= maximumBytes else { throw tooLargeError(bytes) }
        return bytes
    }
}

public struct LocalRecordingImportRollbackError: Error, LocalizedError {
    public let importError: Error
    public let rollbackError: Error

    public var errorDescription: String? {
        "Import failed and its partial local bundle could not be removed: \(rollbackError.localizedDescription)"
    }
}

private extension String {
    func mapToTranscriptOrAudioError(transcriptExtensions: Set<String>) -> LocalRecordingImportError {
        transcriptExtensions.contains(self) ? .transcriptUnreadable : .audioUnreadable
    }
}

private struct ParsedLocalRecordingSegment {
    var speakerName: String
    var startTime: TimeInterval
    var endTime: TimeInterval?
    var text: String
}
