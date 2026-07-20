import Foundation

public struct PrivacyAuditReviewService {
    public static let allowedMetadataKeys: Set<String> = [
        "ageDays",
        "calendarEventCount",
        "contactReviewCount",
        "destination",
        "editedSegmentCount",
        "externalWriteExecuted",
        "externalWritePrepared",
        "fileCount",
        "formats",
        "partialFailure",
        "proposalCount",
        "reason",
        "receiptCount",
        "reminderCount",
        "retentionDays",
        "version"
    ]

    private let reader: PrivacyAuditLogReader

    public init(reader: PrivacyAuditLogReader) {
        self.reader = reader
    }

    public func loadReview(limit: Int = 100) throws -> PrivacyAuditReview {
        let events = try reader.readEvents()
            .sorted {
                if $0.occurredAt == $1.occurredAt {
                    return $0.id.uuidString < $1.id.uuidString
                }
                return $0.occurredAt > $1.occurredAt
            }

        let rows = events.prefix(max(0, limit)).map { event in
            PrivacyAuditReviewRow(
                id: event.id,
                occurredAt: event.occurredAt,
                action: event.action,
                meetingID: event.meetingID,
                metadata: Self.filteredMetadata(event.metadata)
            )
        }
        let counts = Dictionary(grouping: events, by: \.action)
            .mapValues(\.count)

        return PrivacyAuditReview(
            rows: rows,
            counts: counts,
            latestOccurredAt: events.first?.occurredAt
        )
    }

    public static func filteredMetadata(_ metadata: [String: String]) -> [String: String] {
        metadata.filter { Self.allowedMetadataKeys.contains($0.key) }
    }
}

public struct PrivacyAuditReviewExport: Equatable, Sendable {
    public var directory: URL
    public var files: [URL]
    public var rowCount: Int
    public var actionFilter: PrivacyAuditAction?

    public init(directory: URL, files: [URL], rowCount: Int, actionFilter: PrivacyAuditAction?) {
        self.directory = directory
        self.files = files
        self.rowCount = rowCount
        self.actionFilter = actionFilter
    }
}

public struct PrivacyAuditReviewExportService {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func filteredRows(
        in review: PrivacyAuditReview,
        actionFilter: PrivacyAuditAction?
    ) -> [PrivacyAuditReviewRow] {
        review.rows
            .filter { row in
                guard let actionFilter else { return true }
                return row.action == actionFilter
            }
            .map(sanitizedRow)
    }

    public func exportReview(
        _ review: PrivacyAuditReview,
        to exportRoot: URL,
        actionFilter: PrivacyAuditAction?,
        now: Date = Date()
    ) throws -> PrivacyAuditReviewExport {
        let rows = filteredRows(in: review, actionFilter: actionFilter)
        let directory = exportRoot.appendingPathComponent(
            directoryName(now: now, actionFilter: actionFilter),
            isDirectory: true
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let jsonURL = directory.appendingPathComponent("privacy-audit-review.json")
        let csvURL = directory.appendingPathComponent("privacy-audit-review.csv")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(
            PrivacyAuditReviewExportPayload(
                generatedAt: now,
                actionFilter: actionFilter?.rawValue,
                rowCount: rows.count,
                rows: rows
            )
        )
        .write(to: jsonURL, options: [.atomic])

        try renderCSV(rows: rows).write(to: csvURL, atomically: true, encoding: .utf8)

        return PrivacyAuditReviewExport(
            directory: directory,
            files: [jsonURL, csvURL],
            rowCount: rows.count,
            actionFilter: actionFilter
        )
    }

    private func sanitizedRow(_ row: PrivacyAuditReviewRow) -> PrivacyAuditReviewRow {
        PrivacyAuditReviewRow(
            id: row.id,
            occurredAt: row.occurredAt,
            action: row.action,
            meetingID: row.meetingID,
            metadata: PrivacyAuditReviewService.filteredMetadata(row.metadata)
        )
    }

    private func directoryName(now: Date, actionFilter: PrivacyAuditAction?) -> String {
        let timestamp = Int(now.timeIntervalSince1970.rounded(.down))
        let suffix = actionFilter?.rawValue.replacingOccurrences(of: ".", with: "-") ?? "all"
        return "privacy-audit-review-\(timestamp)-\(suffix)"
    }

    private func renderCSV(rows: [PrivacyAuditReviewRow]) -> String {
        var lines = ["occurredAt,action,meetingID,metadata"]
        let formatter = ISO8601DateFormatter()
        lines.append(contentsOf: rows.map { row in
            [
                formatter.string(from: row.occurredAt),
                row.action.rawValue,
                row.meetingID?.uuidString ?? "",
                row.metadata
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }
                    .joined(separator: " ")
            ]
            .map(csvField)
            .joined(separator: ",")
        })
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func csvField(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        if escaped.contains(",") || escaped.contains("\"") || escaped.contains("\n") {
            return "\"\(escaped)\""
        }
        return escaped
    }
}

private struct PrivacyAuditReviewExportPayload: Codable {
    var generatedAt: Date
    var actionFilter: String?
    var rowCount: Int
    var rows: [PrivacyAuditReviewRow]
}
