import Foundation

public enum MeetingExportError: Error, Equatable {
    case noFormatsRequested
    case metadataMeetingMismatch
}

extension MeetingExportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noFormatsRequested:
            "Choose at least one export format."
        case .metadataMeetingMismatch:
            "Encrypted recording metadata belongs to a different meeting."
        }
    }
}

public struct MeetingExportService {
    private let bundleStore: EncryptedMeetingBundleStore
    private let chunkWriter: EncryptedAudioChunkWriter
    private let fileManager: FileManager
    private let auditWriter: PrivacyAuditLogWriter?

    public init(
        bundleStore: EncryptedMeetingBundleStore,
        fileManager: FileManager = .default,
        auditWriter: PrivacyAuditLogWriter? = nil
    ) {
        self.bundleStore = bundleStore
        self.chunkWriter = EncryptedAudioChunkWriter(bundleStore: bundleStore)
        self.fileManager = fileManager
        self.auditWriter = auditWriter
    }

    public func exportPackage(
        meeting: SearchMeeting,
        to exportRoot: URL,
        formats: [MeetingExportFormat]
    ) throws -> MeetingExportPackage {
        guard !formats.isEmpty else {
            throw MeetingExportError.noFormatsRequested
        }

        let transcript = try bundleStore.readJSONArtifact(
            MeetingTranscript.self,
            meetingID: meeting.id,
            relativePath: MeetingTranscript.finalTranscriptRelativePath,
            purpose: MeetingTranscript.finalTranscriptPurpose
        )
        let intelligence = try bundleStore.readJSONArtifact(
            MeetingIntelligenceArtifact.self,
            meetingID: meeting.id,
            relativePath: MeetingIntelligenceArtifact.summaryRelativePath,
            purpose: MeetingIntelligenceArtifact.summaryPurpose
        )
        let transcriptDigest = try LocalFinalTranscriptionService.transcriptDigest(transcript)
        if try bundleStore.artifactExists(
            meetingID: meeting.id,
            relativePath: TranscriptCorrectionRecoveryMarker.relativePath
        ) {
            throw TranscriptArtifactVersionError.correctionInProgress
        }
        guard transcript.transcriptVersion == intelligence.transcriptVersion,
              (intelligence.transcriptDigest == transcriptDigest
                || (intelligence.transcriptDigest == "legacy" && transcript.transcriptVersion == 0)) else {
            throw TranscriptArtifactVersionError.mixedVersions
        }
        if try bundleStore.artifactExists(
            meetingID: meeting.id,
            relativePath: TranscriptDerivedArtifactState.relativePath
        ) {
            _ = try TranscriptArtifactVersionGate(bundleStore: bundleStore).validateCurrent(meetingID: meeting.id)
        }
        let payload = MeetingExportPayload(
            meeting: meeting,
            transcript: transcript,
            intelligence: intelligence,
            bookmarks: try loadBookmarks(meetingID: meeting.id)
        )

        let directory = exportRoot.appendingPathComponent(packageDirectoryName(for: meeting), isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        var files: [MeetingExportFile] = []
        for format in orderedUniqueFormats(formats) {
            let url = exportURL(format: format, directory: directory, meeting: meeting)
            if format == .audioPackage {
                try exportAudioPackage(meetingID: meeting.id, to: url)
            } else {
                let data = try render(format: format, payload: payload)
                try data.write(to: url, options: [.atomic])
            }
            files.append(MeetingExportFile(format: format, url: url))
        }

        try auditWriter?.append(
            action: .exportPackage,
            meetingID: meeting.id,
            metadata: [
                "formats": files.map(\.format.rawValue).joined(separator: ","),
                "fileCount": "\(files.count)"
            ]
        )

        return MeetingExportPackage(
            meetingID: meeting.id,
            transcriptVersion: transcript.transcriptVersion,
            transcriptDigest: transcriptDigest,
            directory: directory,
            files: files
        )
    }

    private func render(format: MeetingExportFormat, payload: MeetingExportPayload) throws -> Data {
        switch format {
        case .markdown:
            return Data(renderMarkdown(payload).utf8)
        case .webVTT:
            return Data(renderWebVTT(payload).utf8)
        case .pdf:
            return renderPDF(payload)
        case .docx:
            return try renderDOCX(payload)
        case .json:
            return try JSONEncoder.meetingVaultExport.encode(payload)
        case .audioPackage:
            preconditionFailure("Audio package exports are written as a directory, not rendered as a single data blob.")
        }
    }

    private func renderMarkdown(_ payload: MeetingExportPayload) -> String {
        let summary = payload.intelligence.summary
        var lines: [String] = [
            "# \(escapeMarkdown(summary.title))",
            "",
            escapeMarkdown(summary.oneParagraph),
            "",
            "## Highlights"
        ]

        lines.append(contentsOf: summary.bullets.map { "- \(escapeMarkdown($0))" })
        lines.append(contentsOf: ["", "## Decisions"])
        if summary.decisions.isEmpty {
            lines.append("- None")
        } else {
            lines.append(contentsOf: summary.decisions.map {
                "- \(escapeMarkdown($0.title)): \(escapeMarkdown($0.details))"
            })
        }

        lines.append(contentsOf: ["", "## Action Items"])
        if summary.actionItems.isEmpty {
            lines.append("- None")
        } else {
            lines.append(contentsOf: summary.actionItems.map { action in
                let owner = action.ownerName.map { " (@\(escapeMarkdown($0)))" } ?? ""
                return "- [ ] \(escapeMarkdown(action.title))\(owner)"
            })
        }

        lines.append(contentsOf: ["", "## Open Questions"])
        if summary.openQuestions.isEmpty {
            lines.append("- None")
        } else {
            lines.append(contentsOf: summary.openQuestions.map { question in
                let context = question.context.trimmingCharacters(in: .whitespacesAndNewlines)
                return context.isEmpty
                    ? "- \(escapeMarkdown(question.question))"
                    : "- \(escapeMarkdown(question.question)): \(escapeMarkdown(context))"
            })
        }

        lines.append(contentsOf: ["", "## Risks"])
        if summary.risks.isEmpty {
            lines.append("- None")
        } else {
            lines.append(contentsOf: summary.risks.map { risk in
                "- [\(risk.severity.rawValue)] \(escapeMarkdown(risk.title)): \(escapeMarkdown(risk.details))"
            })
        }

        lines.append(contentsOf: ["", "## Transcript"])
        lines.append(contentsOf: payload.transcript.segments.map { segment in
            "[\(formatCompactTimestamp(segment.startTime))] \(segment.speakerName): \(segment.text)"
        })
        appendMarkdownBookmarks(payload.bookmarks, to: &lines)
        lines.append("")

        return lines.joined(separator: "\n")
    }

    private func renderWebVTT(_ payload: MeetingExportPayload) -> String {
        var lines = ["WEBVTT", ""]
        for bookmark in payload.bookmarks {
            var pieces = ["NOTE bookmark", formatWebVTTTimestamp(bookmark.timestamp)]
            if let category = bookmark.category { pieces.append(category.rawValue) }
            if let note = bookmark.note { pieces.append(sanitizeWebVTTNote(note)) }
            lines.append(pieces.joined(separator: " "))
            lines.append("")
        }
        for segment in payload.transcript.segments {
            lines.append("\(formatWebVTTTimestamp(segment.startTime)) --> \(formatWebVTTTimestamp(segment.endTime))")
            lines.append("<v \(segment.speakerName)>\(segment.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private func renderPDF(_ payload: MeetingExportPayload) -> Data {
        let lines = plainTextLines(payload).flatMap(wrappedPDFLines)
        let pages = stride(from: 0, to: max(lines.count, 1), by: 48).map { offset in
            Array(lines[offset..<min(offset + 48, lines.count)])
        }
        let pageObjectIDs = pages.indices.map { 4 + ($0 * 2) }

        var objects: [String] = [
            "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
            "2 0 obj\n<< /Type /Pages /Kids [\(pageObjectIDs.map { "\($0) 0 R" }.joined(separator: " "))] /Count \(pages.count) >>\nendobj\n",
            "3 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n"
        ]
        for (pageIndex, pageLines) in pages.enumerated() {
            let pageObjectID = pageObjectIDs[pageIndex]
            let contentObjectID = pageObjectID + 1
            let textStream = pageLines
                .map { "(\(escapePDFText($0))) Tj\nT*" }
                .joined(separator: "\n")
            let content = """
            BT
            /F1 12 Tf
            14 TL
            72 760 Td
            \(textStream)
            ET
            """
            objects.append("\(pageObjectID) 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents \(contentObjectID) 0 R >>\nendobj\n")
            objects.append("\(contentObjectID) 0 obj\n<< /Length \(Data(content.utf8).count) >>\nstream\n\(content)\nendstream\nendobj\n")
        }

        var data = Data("%PDF-1.4\n".utf8)
        var offsets: [Int] = [0]
        for object in objects {
            offsets.append(data.count)
            data.append(Data(object.utf8))
        }
        let xrefOffset = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n".utf8))
        data.append(Data("0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() {
            data.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        data.append(Data("""
        trailer
        << /Size \(objects.count + 1) /Root 1 0 R >>
        startxref
        \(xrefOffset)
        %%EOF
        """.utf8))
        return data
    }

    private func wrappedPDFLines(_ line: String) -> [String] {
        guard line.count > 88 else { return [line] }
        var result: [String] = []
        var remainder = line[...]
        while remainder.count > 88 {
            let limit = remainder.index(remainder.startIndex, offsetBy: 88)
            let breakIndex = remainder[..<limit].lastIndex(of: " ") ?? limit
            result.append(String(remainder[..<breakIndex]))
            remainder = remainder[breakIndex...].drop(while: { $0 == " " })
        }
        result.append(String(remainder))
        return result
    }

    private func renderDOCX(_ payload: MeetingExportPayload) throws -> Data {
        let paragraphs = plainTextLines(payload)
            .map { "<w:p><w:r><w:t>\(escapeXML(sanitizeXMLText($0)))</w:t></w:r></w:p>" }
            .joined()
        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>
            \(paragraphs)
            <w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/></w:sectPr>
          </w:body>
        </w:document>
        """
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        </Types>
        """
        let relationships = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """

        return ZIPStore.archive(entries: [
            ZIPStore.Entry(path: "[Content_Types].xml", data: Data(contentTypes.utf8)),
            ZIPStore.Entry(path: "_rels/.rels", data: Data(relationships.utf8)),
            ZIPStore.Entry(path: "word/document.xml", data: Data(document.utf8))
        ])
    }

    private func exportAudioPackage(meetingID: UUID, to directory: URL) throws {
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        var files: [MeetingAudioExportFile] = []
        for track in TrackKind.allCases {
            let checkpoint = try chunkWriter.readCheckpoint(meetingID: meetingID, track: track)
            guard !checkpoint.chunks.isEmpty else { continue }

            let trackDirectory = directory.appendingPathComponent(track.rawValue, isDirectory: true)
            try fileManager.createDirectory(at: trackDirectory, withIntermediateDirectories: true)
            for record in checkpoint.chunks.sorted(by: sortAudioChunkRecords) {
                let data = try chunkWriter.readChunk(record, meetingID: meetingID)
                let fileName = "chunk-\(String(format: "%06d", record.chunkIndex)).\(audioFileExtension(for: record.codec))"
                let relativePath = "\(track.rawValue)/\(fileName)"
                try data.write(to: directory.appendingPathComponent(relativePath), options: [.atomic])
                files.append(
                    MeetingAudioExportFile(
                        track: record.track,
                        chunkIndex: record.chunkIndex,
                        relativePath: relativePath,
                        startTime: record.startTime,
                        duration: record.duration,
                        byteCount: data.count,
                        codec: record.codec
                    )
                )
            }
        }

        let manifest = MeetingAudioExportManifest(
            meetingID: meetingID,
            exportedAt: Date(),
            files: files
        )
        let manifestData = try JSONEncoder.meetingVaultExport.encode(manifest)
        try manifestData.write(to: directory.appendingPathComponent("manifest.json"), options: [.atomic])
    }

    private func plainTextLines(_ payload: MeetingExportPayload) -> [String] {
        let summary = payload.intelligence.summary
        var lines: [String] = [
            summary.title,
            "",
            summary.oneParagraph,
            "",
            "Highlights"
        ]
        lines.append(contentsOf: summary.bullets.map { "- \($0)" })
        lines.append("")
        lines.append("Decisions")
        lines.append(contentsOf: summary.decisions.map { "- \($0.title): \($0.details)" })
        lines.append("")
        lines.append("Action Items")
        lines.append(contentsOf: summary.actionItems.map { action in
            let owner = action.ownerName.map { " (@\($0))" } ?? ""
            return "- \(action.title)\(owner)"
        })
        lines.append("")
        lines.append("Transcript")
        lines.append(contentsOf: payload.transcript.segments.map { segment in
            "[\(formatCompactTimestamp(segment.startTime))] \(segment.speakerName): \(segment.text)"
        })
        lines.append("")
        lines.append("Marked Moments")
        lines.append(contentsOf: payload.bookmarks.map(plainTextBookmark))
        return lines
    }

    private func loadBookmarks(meetingID: UUID) throws -> [MeetingBookmark] {
        let manifest = try bundleStore.readManifest(meetingID: meetingID)
        let bookmarks: [MeetingBookmark]
        if try bundleStore.artifactExists(
            meetingID: meetingID,
            relativePath: manifest.sessionMetadataPath
        ) {
            let metadata = try bundleStore.readJSONArtifact(
                RecordingSessionMetadata.self,
                meetingID: meetingID,
                relativePath: manifest.sessionMetadataPath,
                purpose: RecordingSessionMetadata.purpose
            )
            guard metadata.meetingID == meetingID else {
                throw MeetingExportError.metadataMeetingMismatch
            }
            bookmarks = try validatedBookmarkProjection(
                metadata.bookmarks,
                meetingID: meetingID,
                startedAt: metadata.startedAt,
                context: metadata.context,
                revision: metadata.revision,
                isFinalized: metadata.isFinalized
            )
        } else {
            bookmarks = try validatedBookmarkProjection(
                manifest.bookmarks,
                meetingID: meetingID,
                startedAt: manifest.createdAt,
                context: manifest.context,
                revision: 0,
                isFinalized: true
            )
        }
        return bookmarks
    }

    private func appendMarkdownBookmarks(_ bookmarks: [MeetingBookmark], to lines: inout [String]) {
        lines.append(contentsOf: ["", "## Marked Moments"])
        if bookmarks.isEmpty {
            lines.append("- None")
        } else {
            lines.append(contentsOf: bookmarks.map { bookmark in
                var value = "[\(formatCompactTimestamp(bookmark.timestamp))]"
                if let category = bookmark.category { value += " \(category.rawValue)" }
                if let note = bookmark.note { value += " — \(escapeMarkdown(note))" }
                return "- \(value)"
            })
        }
    }

    private func plainTextBookmark(_ bookmark: MeetingBookmark) -> String {
        var value = "[\(formatCompactTimestamp(bookmark.timestamp))]"
        if let category = bookmark.category { value += " \(category.rawValue)" }
        if let note = bookmark.note { value += " — \(sanitizeSingleLine(note))" }
        return value
    }

    private func bookmarkSort(_ lhs: MeetingBookmark, _ rhs: MeetingBookmark) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func sanitizeSingleLine(_ value: String) -> String {
        sanitizeXMLText(value).components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func escapeMarkdown(_ value: String) -> String {
        let specials = CharacterSet(charactersIn: "\\`*_{}[]()|~")
        let sanitized = sanitizeSingleLine(value)
        var escaped = sanitized.unicodeScalars.map { scalar in
            if scalar == "&" { return "&amp;" }
            if scalar == "<" { return "&lt;" }
            if scalar == ">" { return "&gt;" }
            if specials.contains(scalar) { return "\\\(Character(scalar))" }
            return String(Character(scalar))
        }.joined()
        if ["# ", "> ", "- ", "+ ", "---"].contains(where: escaped.hasPrefix),
           let first = escaped.first {
            escaped = "\\\(first)" + escaped.dropFirst()
        }
        return escaped
    }

    private func sanitizeWebVTTNote(_ value: String) -> String {
        sanitizeSingleLine(value).replacingOccurrences(of: "-->", with: "--\u{200B}>")
    }

    private func sanitizeXMLText(_ value: String) -> String {
        String(value.unicodeScalars.filter { scalar in
            scalar.value == 0x09
                || scalar.value == 0x0A
                || scalar.value == 0x0D
                || (scalar.value >= 0x20 && scalar.value <= 0xD7FF)
                || (scalar.value >= 0xE000 && scalar.value <= 0xFFFD)
                || (scalar.value >= 0x10000 && scalar.value <= 0x10FFFF)
        })
    }

    private func validatedBookmarkProjection(
        _ source: [MeetingBookmark],
        meetingID: UUID,
        startedAt: Date,
        context: MeetingContext,
        revision: Int,
        isFinalized: Bool
    ) throws -> [MeetingBookmark] {
        var seen = Set<UUID>()
        let projected = source.sorted(by: bookmarkSort).filter { seen.insert($0.id).inserted }
        do {
            return try RecordingSessionMetadata(
                meetingID: meetingID,
                startedAt: startedAt,
                context: context,
                bookmarks: projected,
                revision: revision,
                isFinalized: isFinalized
            ).validated(expectedMeetingID: meetingID).bookmarks
        } catch RecordingSessionMetadataValidationError.metadataMeetingMismatch {
            throw MeetingExportError.metadataMeetingMismatch
        }
    }

    private func orderedUniqueFormats(_ formats: [MeetingExportFormat]) -> [MeetingExportFormat] {
        var seen = Set<MeetingExportFormat>()
        var result: [MeetingExportFormat] = []
        for format in formats where !seen.contains(format) {
            seen.insert(format)
            result.append(format)
        }
        return result
    }

    private func exportURL(format: MeetingExportFormat, directory: URL, meeting: SearchMeeting) -> URL {
        directory.appendingPathComponent(
            "\(baseFileName(for: meeting)).\(format.fileExtension)",
            isDirectory: format == .audioPackage
        )
    }

    private func packageDirectoryName(for meeting: SearchMeeting) -> String {
        "\(safeSlug(meeting.title))-\(meeting.id.uuidString.prefix(8))"
    }

    private func baseFileName(for meeting: SearchMeeting) -> String {
        safeSlug(meeting.title)
    }

    private func safeSlug(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(scalars)
            .split(separator: "-")
            .joined(separator: "-")
        return collapsed.isEmpty ? "Meeting" : collapsed
    }

    private func formatCompactTimestamp(_ value: TimeInterval) -> String {
        let milliseconds = Int((value * 1000).rounded())
        let minutes = milliseconds / 60_000
        let seconds = (milliseconds % 60_000) / 1000
        let ms = milliseconds % 1000
        return String(format: "%02d:%02d.%03d", minutes, seconds, ms)
    }

    private func formatWebVTTTimestamp(_ value: TimeInterval) -> String {
        let milliseconds = Int((value * 1000).rounded())
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds % 3_600_000) / 60_000
        let seconds = (milliseconds % 60_000) / 1000
        let ms = milliseconds % 1000
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, seconds, ms)
    }

    private func sortAudioChunkRecords(_ lhs: AudioChunkRecord, _ rhs: AudioChunkRecord) -> Bool {
        if lhs.track.rawValue != rhs.track.rawValue {
            return lhs.track.rawValue < rhs.track.rawValue
        }
        return lhs.chunkIndex < rhs.chunkIndex
    }

    private func audioFileExtension(for codec: String) -> String {
        let normalized = codec.lowercased()
        if normalized.contains("mp3") || normalized.contains("mpeg") {
            return "mp3"
        }
        if normalized.contains("aiff") || normalized.contains("aifc") {
            return "aiff"
        }
        if normalized.contains("m4a") || normalized.contains("aac") {
            return "m4a"
        }
        if normalized.contains("wav") {
            return "wav"
        }
        if normalized.contains("caf") || normalized.contains("pcm") || normalized.contains("lpcm") {
            return "caf"
        }
        return "bin"
    }

    private func escapePDFText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
    }

    private func escapeXML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

private enum ZIPStore {
    struct Entry {
        var path: String
        var data: Data
    }

    static func archive(entries: [Entry]) -> Data {
        var data = Data()
        var centralDirectory = Data()
        for entry in entries {
            let localHeaderOffset = UInt32(data.count)
            let nameData = Data(entry.path.utf8)
            let checksum = crc32(entry.data)
            data.appendUInt32LE(0x0403_4b50)
            data.appendUInt16LE(20)
            data.appendUInt16LE(0)
            data.appendUInt16LE(0)
            data.appendUInt16LE(0)
            data.appendUInt16LE(0)
            data.appendUInt32LE(checksum)
            data.appendUInt32LE(UInt32(entry.data.count))
            data.appendUInt32LE(UInt32(entry.data.count))
            data.appendUInt16LE(UInt16(nameData.count))
            data.appendUInt16LE(0)
            data.append(nameData)
            data.append(entry.data)

            centralDirectory.appendUInt32LE(0x0201_4b50)
            centralDirectory.appendUInt16LE(20)
            centralDirectory.appendUInt16LE(20)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt32LE(checksum)
            centralDirectory.appendUInt32LE(UInt32(entry.data.count))
            centralDirectory.appendUInt32LE(UInt32(entry.data.count))
            centralDirectory.appendUInt16LE(UInt16(nameData.count))
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt32LE(0)
            centralDirectory.appendUInt32LE(localHeaderOffset)
            centralDirectory.append(nameData)
        }

        let centralDirectoryOffset = UInt32(data.count)
        data.append(centralDirectory)
        data.appendUInt32LE(0x0605_4b50)
        data.appendUInt16LE(0)
        data.appendUInt16LE(0)
        data.appendUInt16LE(UInt16(entries.count))
        data.appendUInt16LE(UInt16(entries.count))
        data.appendUInt32LE(UInt32(centralDirectory.count))
        data.appendUInt32LE(centralDirectoryOffset)
        data.appendUInt16LE(0)
        return data
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xff)
            crc = (crc >> 8) ^ crcTable[index]
        }
        return crc ^ 0xffff_ffff
    }

    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            if crc & 1 == 1 {
                crc = (crc >> 1) ^ 0xedb8_8320
            } else {
                crc >>= 1
            }
        }
        return crc
    }
}

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }
}
