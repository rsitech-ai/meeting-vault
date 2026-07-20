import CSQLite
import Foundation

public enum SQLiteSearchIndexError: Error, Equatable {
    case openFailed(String)
    case prepareFailed(String)
    case executeFailed(String)
    case invalidUUID(String)
}

// SQLite is opened with FULLMUTEX and callers never receive the raw connection
// or statements. The recursive operation lock additionally keeps each public
// operation, including a multi-statement replacement transaction, opaque to
// other callers using this connection.
public final class SQLiteSearchIndex: @unchecked Sendable {
    private var db: OpaquePointer?
    private let isoFormatter = ISO8601DateFormatter()
    private let operationLock = NSRecursiveLock()
    private let replacementMutationHook: (@Sendable () -> Void)?

    public init(databaseURL: URL) throws {
        replacementMutationHook = nil
        try open(databasePath: databaseURL.path)
    }

    public init(inMemory: Void) throws {
        replacementMutationHook = nil
        try open(databasePath: ":memory:")
    }

    init(inMemory: Void, replacementMutationHook: @escaping @Sendable () -> Void) throws {
        self.replacementMutationHook = replacementMutationHook
        try open(databasePath: ":memory:")
    }

    private func open(databasePath: String) throws {
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(databasePath, &db, flags, nil) != SQLITE_OK {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw SQLiteSearchIndexError.openFailed(message)
        }
        try migrate()
    }

    deinit {
        sqlite3_close(db)
    }

    public func upsertMeeting(_ meeting: SearchMeeting) throws {
        try operationLock.withLock {
            try execute(
                """
                INSERT INTO meetings(id, title, started_at, source_app)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  title = excluded.title,
                  started_at = excluded.started_at,
                  source_app = excluded.source_app;
                """,
                bindings: [
                    .text(meeting.id.uuidString),
                    .text(meeting.title),
                    .text(isoFormatter.string(from: meeting.startedAt)),
                    .text(meeting.sourceApp)
                ]
            )
        }
    }

    public func upsertSegments(_ segments: [SearchTranscriptSegment]) throws {
        try operationLock.withLock {
            for segment in segments {
                try execute(
                    """
                    INSERT INTO transcript_segments(
                      id, meeting_id, speaker_name, start_time, end_time, text, confidence, is_final
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                      meeting_id = excluded.meeting_id,
                      speaker_name = excluded.speaker_name,
                      start_time = excluded.start_time,
                      end_time = excluded.end_time,
                      text = excluded.text,
                      confidence = excluded.confidence,
                      is_final = excluded.is_final;
                    """,
                    bindings: [
                        .text(segment.id.uuidString),
                        .text(segment.meetingID.uuidString),
                        .text(segment.speakerName),
                        .double(segment.startTime),
                        .double(segment.endTime),
                        .text(segment.text),
                        .double(segment.confidence),
                        .int(segment.isFinal ? 1 : 0)
                    ]
                )
            }
        }
    }

    /// Replaces one meeting's complete derived search projection atomically.
    /// Readers see either the prior projection or the complete replacement.
    public func replaceMeetingAndSegments(
        meeting: SearchMeeting,
        segments: [SearchTranscriptSegment]
    ) throws {
        try operationLock.withLock {
            try execute("BEGIN IMMEDIATE TRANSACTION;")
            do {
                try upsertMeeting(meeting)
                try deleteSegments(meetingID: meeting.id)
                replacementMutationHook?()
                try upsertSegments(segments)
                try execute("COMMIT;")
            } catch {
                try? execute("ROLLBACK;")
                throw error
            }
        }
    }

    public func deleteSegments(meetingID: UUID) throws {
        try operationLock.withLock {
            try execute(
                """
                DELETE FROM transcript_segments
                WHERE meeting_id = ?;
                """,
                bindings: [.text(meetingID.uuidString)]
            )
        }
    }

    public func deleteMeeting(id meetingID: UUID) throws {
        try operationLock.withLock {
            try deleteSegments(meetingID: meetingID)
            try execute(
                """
                DELETE FROM meetings
                WHERE id = ?;
                """,
                bindings: [.text(meetingID.uuidString)]
            )
        }
    }

    public func search(_ query: String, limit: Int = 20) throws -> [TranscriptSearchResult] {
        try operationLock.withLock {
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return []
            }

            return try select(
                """
                SELECT
                  transcript_segments.id,
                  transcript_segments.meeting_id,
                  meetings.title,
                  transcript_segments.speaker_name,
                  transcript_segments.start_time,
                  transcript_segments.end_time,
                  transcript_segments.text
                FROM transcript_segments_fts
                JOIN transcript_segments ON transcript_segments_fts.rowid = transcript_segments.rowid
                JOIN meetings ON meetings.id = transcript_segments.meeting_id
                WHERE transcript_segments_fts MATCH ?
                ORDER BY bm25(transcript_segments_fts), transcript_segments.start_time
                LIMIT ?;
                """,
                bindings: [.text(escapeFTSQuery(query)), .int(Int32(limit))]
            ) { statement in
                let segmentIDText = columnText(statement, 0)
                let meetingIDText = columnText(statement, 1)
                guard let segmentID = UUID(uuidString: segmentIDText) else {
                    throw SQLiteSearchIndexError.invalidUUID(segmentIDText)
                }
                guard let meetingID = UUID(uuidString: meetingIDText) else {
                    throw SQLiteSearchIndexError.invalidUUID(meetingIDText)
                }
                return TranscriptSearchResult(
                    segmentID: segmentID,
                    meetingID: meetingID,
                    meetingTitle: columnText(statement, 2),
                    speakerName: columnText(statement, 3),
                    startTime: sqlite3_column_double(statement, 4),
                    endTime: sqlite3_column_double(statement, 5),
                    text: columnText(statement, 6)
                )
            }
        }
    }

    private func migrate() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS meetings(
              id TEXT PRIMARY KEY,
              title TEXT NOT NULL,
              started_at TEXT NOT NULL,
              source_app TEXT NOT NULL
            );
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS transcript_segments(
              id TEXT PRIMARY KEY,
              meeting_id TEXT NOT NULL,
              speaker_name TEXT NOT NULL,
              start_time REAL NOT NULL,
              end_time REAL NOT NULL,
              text TEXT NOT NULL,
              confidence REAL NOT NULL,
              is_final INTEGER NOT NULL,
              FOREIGN KEY(meeting_id) REFERENCES meetings(id)
            );
            """
        )
        try execute(
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS transcript_segments_fts
            USING fts5(text, speaker_name, meeting_title, content='transcript_segments', content_rowid='rowid');
            """
        )
        try execute(
            """
            CREATE TRIGGER IF NOT EXISTS transcript_segments_ai AFTER INSERT ON transcript_segments BEGIN
              INSERT INTO transcript_segments_fts(rowid, text, speaker_name, meeting_title)
              VALUES (
                new.rowid,
                new.text,
                new.speaker_name,
                COALESCE((SELECT title FROM meetings WHERE id = new.meeting_id), '')
              );
            END;
            """
        )
        try execute(
            """
            CREATE TRIGGER IF NOT EXISTS transcript_segments_ad AFTER DELETE ON transcript_segments BEGIN
              INSERT INTO transcript_segments_fts(transcript_segments_fts, rowid, text, speaker_name, meeting_title)
              VALUES('delete', old.rowid, old.text, old.speaker_name, COALESCE((SELECT title FROM meetings WHERE id = old.meeting_id), ''));
            END;
            """
        )
        try execute(
            """
            CREATE TRIGGER IF NOT EXISTS transcript_segments_au AFTER UPDATE ON transcript_segments BEGIN
              INSERT INTO transcript_segments_fts(transcript_segments_fts, rowid, text, speaker_name, meeting_title)
              VALUES('delete', old.rowid, old.text, old.speaker_name, COALESCE((SELECT title FROM meetings WHERE id = old.meeting_id), ''));
              INSERT INTO transcript_segments_fts(rowid, text, speaker_name, meeting_title)
              VALUES (
                new.rowid,
                new.text,
                new.speaker_name,
                COALESCE((SELECT title FROM meetings WHERE id = new.meeting_id), '')
              );
            END;
            """
        )
    }

    private enum SQLiteBinding {
        case text(String)
        case double(Double)
        case int(Int32)
    }

    private func execute(_ sql: String, bindings: [SQLiteBinding] = []) throws {
        try withStatement(sql, bindings: bindings) { statement in
            let status = sqlite3_step(statement)
            guard status == SQLITE_DONE else {
                throw SQLiteSearchIndexError.executeFailed(lastErrorMessage)
            }
        }
    }

    private func select<Value>(
        _ sql: String,
        bindings: [SQLiteBinding],
        row: (OpaquePointer) throws -> Value
    ) throws -> [Value] {
        try withStatement(sql, bindings: bindings) { statement in
            var values: [Value] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_ROW {
                    values.append(try row(statement))
                } else if status == SQLITE_DONE {
                    return values
                } else {
                    throw SQLiteSearchIndexError.executeFailed(lastErrorMessage)
                }
            }
        }
    }

    private func withStatement<Value>(
        _ sql: String,
        bindings: [SQLiteBinding],
        body: (OpaquePointer) throws -> Value
    ) throws -> Value {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteSearchIndexError.prepareFailed(lastErrorMessage)
        }
        defer { sqlite3_finalize(statement) }

        for (index, binding) in bindings.enumerated() {
            let parameterIndex = Int32(index + 1)
            switch binding {
            case .text(let value):
                sqlite3_bind_text(statement, parameterIndex, value, -1, SQLITE_TRANSIENT)
            case .double(let value):
                sqlite3_bind_double(statement, parameterIndex, value)
            case .int(let value):
                sqlite3_bind_int(statement, parameterIndex, value)
            }
        }

        return try body(statement)
    }

    private var lastErrorMessage: String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
    }

    private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let text = sqlite3_column_text(statement, index) else {
            return ""
        }
        return String(cString: text)
    }

    private func escapeFTSQuery(_ query: String) -> String {
        let terms = query
            .split(whereSeparator: { $0.isWhitespace })
            .map { term in
                "\"\(term.replacingOccurrences(of: "\"", with: "\"\""))\""
            }
        return terms.joined(separator: " ")
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
