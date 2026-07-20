import Foundation

public struct PrivacyAuditLogWriter: @unchecked Sendable {
    private let logURL: URL
    private let now: @Sendable () -> Date
    private let encoder: JSONEncoder

    public init(logURL: URL, now: @escaping @Sendable () -> Date = Date.init) {
        self.logURL = logURL
        self.now = now
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
    }

    public func append(
        action: PrivacyAuditAction,
        meetingID: UUID?,
        metadata: [String: String] = [:]
    ) throws {
        let event = PrivacyAuditEvent(
            occurredAt: now(),
            action: action,
            meetingID: meetingID,
            metadata: sanitized(metadata)
        )
        try append(event)
    }

    public func append(_ event: PrivacyAuditEvent) throws {
        let fileLock = PrivacyAuditFileLockRegistry.lock(for: logURL)
        try fileLock.withLock {
            try FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoded = try encoder.encode(event)
            var line = encoded
            line.append(0x0A)

            if FileManager.default.fileExists(atPath: logURL.path) {
                let handle = try FileHandle(forWritingTo: logURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: logURL, options: [.atomic])
            }
        }
    }

    private func sanitized(_ metadata: [String: String]) -> [String: String] {
        metadata.reduce(into: [:]) { result, pair in
            result[pair.key] = LogRedactor.redact(pair.value)
        }
    }
}

private enum PrivacyAuditFileLockRegistry {
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var locks: [String: NSLock] = [:]

    static func lock(for url: URL) -> NSLock {
        registryLock.withLock {
            let key = url.standardizedFileURL.path
            if let existing = locks[key] { return existing }
            let lock = NSLock()
            locks[key] = lock
            return lock
        }
    }
}

public struct PrivacyAuditLogReader {
    private let logURL: URL
    private let decoder: JSONDecoder

    public init(logURL: URL) {
        self.logURL = logURL
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func readEvents() throws -> [PrivacyAuditEvent] {
        guard FileManager.default.fileExists(atPath: logURL.path) else {
            return []
        }
        let data = try Data(contentsOf: logURL)
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
        return try lines.map { line in
            try decoder.decode(PrivacyAuditEvent.self, from: Data(line.utf8))
        }
    }
}
