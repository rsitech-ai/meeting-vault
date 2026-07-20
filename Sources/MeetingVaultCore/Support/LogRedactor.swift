import Foundation

public enum LogRedactor {
    private static let sensitivePatterns: [(String, String)] = [
        (#"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, "[redacted-email]"),
        (#"(?i)\b(api[_-]?key|token|secret)\s*[:=]\s*\S+"#, "$1=[redacted]"),
        (#"(?i)(~|/Users/|/private/var/|/var/)[^\n,;]+"#, "[redacted-path]"),
        (#"(?i)\b(transcript|quote|private note)\s*[:=]\s*.+$"#, "$1=[redacted-content]")
    ]

    public static func redact(_ message: String) -> String {
        sensitivePatterns.reduce(message) { current, pattern in
            current.replacingOccurrences(
                of: pattern.0,
                with: pattern.1,
                options: [.regularExpression]
            )
        }
    }
}
