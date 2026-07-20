import Foundation

public enum MeetingContextValidationError: Error, Equatable, Sendable {
    case unsupportedLocale
    case localeIdentifierTooLong
    case invalidParticipantCount
    case tooManyParticipantNames
    case tooManyVocabularyEntries
    case privateEntryTooLong
    case privateCollectionTooLarge
}

extension MeetingContextValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedLocale:
            "Choose Automatic, Polish, or English for the meeting language."
        case .localeIdentifierTooLong:
            "The meeting language identifier is too long."
        case .invalidParticipantCount:
            "Participant count must be between 1 and 10."
        case .tooManyParticipantNames:
            "Meeting context contains too many participant names."
        case .tooManyVocabularyEntries:
            "Meeting context contains too many vocabulary entries."
        case .privateEntryTooLong:
            "A meeting context entry is too long."
        case .privateCollectionTooLarge:
            "Meeting context contains too much private text."
        }
    }
}

public struct MeetingContext: Codable, Equatable, Sendable {
    public static let maxParticipantNames = 10
    public static let maxVocabularyEntries = 100
    public static let maxPrivateEntryUTF8Bytes = 256
    public static let maxPrivateCollectionUTF8Bytes = 16_384
    public static let maxLocaleIdentifierUTF8Bytes = 32

    public var localeIdentifier: String?
    public var expectedParticipantCount: Int?
    public var participantNames: [String]
    public var vocabulary: [String]

    public init(
        localeIdentifier: String? = nil,
        expectedParticipantCount: Int? = nil,
        participantNames: [String] = [],
        vocabulary: [String] = []
    ) {
        self.localeIdentifier = localeIdentifier
        self.expectedParticipantCount = expectedParticipantCount
        self.participantNames = participantNames
        self.vocabulary = vocabulary
    }

    public func validated() throws -> MeetingContext {
        guard participantNames.count <= Self.maxParticipantNames else {
            throw MeetingContextValidationError.tooManyParticipantNames
        }
        guard vocabulary.count <= Self.maxVocabularyEntries else {
            throw MeetingContextValidationError.tooManyVocabularyEntries
        }
        if let expectedParticipantCount,
           !(1...10).contains(expectedParticipantCount) {
            throw MeetingContextValidationError.invalidParticipantCount
        }

        try Self.validateRawLocaleBound(localeIdentifier)
        try Self.validatePrivateEntryBounds(participantNames + vocabulary)
        let normalizedLocaleIdentifier = try Self.normalizedLocale(localeIdentifier)
        let normalizedParticipantNames = try Self.normalizedPrivateEntries(participantNames)
        let normalizedVocabulary = try Self.normalizedPrivateEntries(vocabulary)
        try Self.validatePrivateEntryBounds(normalizedParticipantNames + normalizedVocabulary)

        return MeetingContext(
            localeIdentifier: normalizedLocaleIdentifier,
            expectedParticipantCount: expectedParticipantCount,
            participantNames: normalizedParticipantNames,
            vocabulary: normalizedVocabulary
        )
    }

    private static func normalizedLocale(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let compact = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        guard compact.utf8.count <= maxLocaleIdentifierUTF8Bytes else {
            throw MeetingContextValidationError.localeIdentifierTooLong
        }
        guard !compact.isEmpty else { return nil }
        switch compact {
        case "pl", "pl-pl":
            return "pl-PL"
        case "en", "en-us":
            return "en-US"
        default:
            throw MeetingContextValidationError.unsupportedLocale
        }
    }

    private static func validateRawLocaleBound(_ value: String?) throws {
        guard let value else { return }
        guard value.utf8.count <= maxLocaleIdentifierUTF8Bytes else {
            throw MeetingContextValidationError.localeIdentifierTooLong
        }
    }

    private static func normalizedPrivateEntries(_ values: [String]) throws -> [String] {
        var normalized: [String] = []
        var seen: Set<String> = []
        for value in values {
            let collapsed = value
                .split(whereSeparator: \Character.isWhitespace)
                .joined(separator: " ")
            guard !collapsed.isEmpty else { continue }
            guard collapsed.utf8.count <= maxPrivateEntryUTF8Bytes else {
                throw MeetingContextValidationError.privateEntryTooLong
            }
            let identity = collapsed.folding(
                options: [.caseInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            if seen.insert(identity).inserted {
                normalized.append(collapsed)
            }
        }
        return normalized
    }

    private static func validatePrivateEntryBounds(_ values: [String]) throws {
        var totalUTF8Bytes = 0
        for value in values {
            let byteCount = value.utf8.count
            guard byteCount <= maxPrivateEntryUTF8Bytes else {
                throw MeetingContextValidationError.privateEntryTooLong
            }
            guard byteCount <= maxPrivateCollectionUTF8Bytes - totalUTF8Bytes else {
                throw MeetingContextValidationError.privateCollectionTooLarge
            }
            totalUTF8Bytes += byteCount
        }
    }
}
