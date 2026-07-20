import Foundation

public enum SpeechAnalyzerEvaluationStatus: String, Codable, Equatable, Sendable {
    case notEvaluated
    case available
    case assetsNeeded
    case unsupported
    case failed

    public var displayTitle: String {
        switch self {
        case .notEvaluated:
            "Not Evaluated"
        case .available:
            "Available"
        case .assetsNeeded:
            "Assets Needed"
        case .unsupported:
            "Unsupported"
        case .failed:
            "Failed"
        }
    }
}

public struct SpeechAnalyzerEvaluationReport: Codable, Equatable, Sendable {
    public var generatedAt: Date
    public var requestedLocaleIdentifier: String
    public var resolvedLocaleIdentifier: String?
    public var sdkAvailable: Bool
    public var transcriberAvailable: Bool
    public var assetStatus: String?
    public var compatibleAudioFormatDescription: String?
    public var status: SpeechAnalyzerEvaluationStatus
    public var notes: [String]

    public init(
        generatedAt: Date,
        requestedLocaleIdentifier: String,
        resolvedLocaleIdentifier: String?,
        sdkAvailable: Bool,
        transcriberAvailable: Bool,
        assetStatus: String?,
        compatibleAudioFormatDescription: String?,
        status: SpeechAnalyzerEvaluationStatus,
        notes: [String]
    ) {
        self.generatedAt = generatedAt
        self.requestedLocaleIdentifier = requestedLocaleIdentifier
        self.resolvedLocaleIdentifier = resolvedLocaleIdentifier
        self.sdkAvailable = sdkAvailable
        self.transcriberAvailable = transcriberAvailable
        self.assetStatus = assetStatus
        self.compatibleAudioFormatDescription = compatibleAudioFormatDescription
        self.status = status
        self.notes = notes
    }

    public static func notEvaluated(
        requestedLocaleIdentifier: String = Locale.current.identifier
    ) -> SpeechAnalyzerEvaluationReport {
        SpeechAnalyzerEvaluationReport(
            generatedAt: Date(timeIntervalSince1970: 0),
            requestedLocaleIdentifier: requestedLocaleIdentifier,
            resolvedLocaleIdentifier: nil,
            sdkAvailable: false,
            transcriberAvailable: false,
            assetStatus: nil,
            compatibleAudioFormatDescription: nil,
            status: .notEvaluated,
            notes: ["SpeechAnalyzer capability has not been evaluated in this app session."]
        )
    }
}
