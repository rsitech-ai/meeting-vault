import Foundation

public enum MeetingGeneratedTitleError: Error, Equatable, LocalizedError, Sendable {
    case emptyTitle

    public var errorDescription: String? {
        switch self {
        case .emptyTitle:
            "Meeting intelligence returned an empty generated title."
        }
    }
}

public enum MeetingGeneratedTitleService {
    public static func title(
        from summary: MeetingSummary,
        transcript: MeetingTranscript? = nil
    ) throws -> String {
        let title = summary.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw MeetingGeneratedTitleError.emptyTitle
        }
        if !isGeneric(title), !isMismatchedDemoTitle(title, transcript: transcript) {
            return title
        }
        if let contentTitle = transcript.flatMap(contentTitle(from:)) {
            return contentTitle
        }
        return title
    }

    public static func summaryWithGeneratedTitle(
        from summary: MeetingSummary,
        transcript: MeetingTranscript
    ) throws -> MeetingSummary {
        var promoted = summary
        promoted.title = try title(from: summary, transcript: transcript)
        return promoted
    }

    private static func isGeneric(_ title: String) -> Bool {
        let normalized = title
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return [
            "meeting",
            "meeting notes",
            "meeting summary",
            "recorded meeting",
            "recording summary",
            "short title",
            "summary",
            "transcript summary",
            "untitled meeting"
        ].contains(normalized)
    }

    // ponytail: guards against the bundled demo summary title leaking onto real
    // recordings whose transcript never mentions the demo topics. Upgrade path:
    // provider-side grounding of titles instead of this name-specific check.
    private static func isMismatchedDemoTitle(_ title: String, transcript: MeetingTranscript?) -> Bool {
        guard title.trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedCaseInsensitiveCompare("Release readiness sync") == .orderedSame,
              let transcript
        else {
            return false
        }
        let text = transcript.segments.map(\.text).joined(separator: " ").lowercased()
        return !text.contains("beta candidate")
            && !text.contains("privacy review")
            && !text.contains("release readiness")
    }

    private static func contentTitle(from transcript: MeetingTranscript) -> String? {
        let words = transcript.segments
            .map(\.text)
            .joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .map { token in
                String(token).trimmingCharacters(in: .punctuationCharacters)
            }
            .filter { !$0.isEmpty }

        let leadingFillers: Set<String> = [
            "a", "about", "actually", "and", "are", "discussed", "i", "just", "now", "ok",
            "okay", "so", "the", "today", "talk", "talked", "talking", "to", "um", "want",
            "we", "well", "you"
        ]
        let contentWords = words.drop { leadingFillers.contains($0.lowercased()) }
        let selected = Array(contentWords.prefix(7))
        guard !selected.isEmpty else { return nil }
        return selected.map(capitalizedTitleWord).joined(separator: " ")
    }

    private static func capitalizedTitleWord(_ word: String) -> String {
        guard let first = word.first else { return word }
        return String(first).uppercased() + String(word.dropFirst())
    }
}
