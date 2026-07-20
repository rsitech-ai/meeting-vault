@preconcurrency import AVFAudio
import Foundation
@preconcurrency import Speech

public protocol SpeechAnalyzerCapabilityProviding: Sendable {
    func evaluateSpeechAnalyzer(localeIdentifier: String) async throws -> SpeechAnalyzerEvaluationReport
    func prepareSpeechAnalyzerAssets(localeIdentifier: String) async throws -> SpeechAnalyzerEvaluationReport
}

public struct SpeechAnalyzerEvaluationService: Sendable {
    private let provider: any SpeechAnalyzerCapabilityProviding

    public init(provider: any SpeechAnalyzerCapabilityProviding) {
        self.provider = provider
    }

    public func evaluate(localeIdentifier: String = Locale.current.identifier) async throws -> SpeechAnalyzerEvaluationReport {
        try await provider.evaluateSpeechAnalyzer(localeIdentifier: localeIdentifier)
    }

    public func prepareAssets(localeIdentifier: String = Locale.current.identifier) async throws -> SpeechAnalyzerEvaluationReport {
        try await provider.prepareSpeechAnalyzerAssets(localeIdentifier: localeIdentifier)
    }
}

public struct MockSpeechAnalyzerCapabilityProvider: SpeechAnalyzerCapabilityProviding {
    private let result: Result<SpeechAnalyzerEvaluationReport, Error>
    private let prepareResult: Result<SpeechAnalyzerEvaluationReport, Error>

    public init(report: SpeechAnalyzerEvaluationReport) {
        self.result = .success(report)
        self.prepareResult = .success(report)
    }

    public init(report: SpeechAnalyzerEvaluationReport, prepareReport: SpeechAnalyzerEvaluationReport) {
        self.result = .success(report)
        self.prepareResult = .success(prepareReport)
    }

    public init(error: Error) {
        self.result = .failure(error)
        self.prepareResult = .failure(error)
    }

    public init(report: SpeechAnalyzerEvaluationReport, prepareError: Error) {
        self.result = .success(report)
        self.prepareResult = .failure(prepareError)
    }

    public func evaluateSpeechAnalyzer(localeIdentifier: String) async throws -> SpeechAnalyzerEvaluationReport {
        try result.get()
    }

    public func prepareSpeechAnalyzerAssets(localeIdentifier: String) async throws -> SpeechAnalyzerEvaluationReport {
        try prepareResult.get()
    }
}

public struct SystemSpeechAnalyzerCapabilityProvider: SpeechAnalyzerCapabilityProviding {
    public init() {}

    public func evaluateSpeechAnalyzer(localeIdentifier: String) async throws -> SpeechAnalyzerEvaluationReport {
        guard #available(macOS 26.0, *) else {
            return SpeechAnalyzerEvaluationReport(
                generatedAt: Date(),
                requestedLocaleIdentifier: localeIdentifier,
                resolvedLocaleIdentifier: nil,
                sdkAvailable: false,
                transcriberAvailable: false,
                assetStatus: nil,
                compatibleAudioFormatDescription: nil,
                status: .unsupported,
                notes: ["SpeechAnalyzer requires macOS 26 or newer."]
            )
        }

        let requestedLocale = Locale(identifier: localeIdentifier)
        guard SpeechTranscriber.isAvailable else {
            return SpeechAnalyzerEvaluationReport(
                generatedAt: Date(),
                requestedLocaleIdentifier: localeIdentifier,
                resolvedLocaleIdentifier: nil,
                sdkAvailable: true,
                transcriberAvailable: false,
                assetStatus: nil,
                compatibleAudioFormatDescription: nil,
                status: .unsupported,
                notes: ["SpeechTranscriber is not available on this runtime."]
            )
        }

        guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            return SpeechAnalyzerEvaluationReport(
                generatedAt: Date(),
                requestedLocaleIdentifier: localeIdentifier,
                resolvedLocaleIdentifier: nil,
                sdkAvailable: true,
                transcriberAvailable: true,
                assetStatus: nil,
                compatibleAudioFormatDescription: nil,
                status: .unsupported,
                notes: ["No SpeechTranscriber locale equivalent was found for \(localeIdentifier)."]
            )
        }

        let transcriber = SpeechTranscriber(
            locale: supportedLocale,
            preset: .timeIndexedProgressiveTranscription
        )
        let modules: [any SpeechModule] = [transcriber]
        let assetStatus = await AssetInventory.status(forModules: modules)
        let compatibleFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules)
        let status = evaluationStatus(assetStatusDescription: String(describing: assetStatus))
        let notes = notes(
            status: status,
            assetStatusDescription: String(describing: assetStatus),
            compatibleFormat: compatibleFormat
        )

        return SpeechAnalyzerEvaluationReport(
            generatedAt: Date(),
            requestedLocaleIdentifier: localeIdentifier,
            resolvedLocaleIdentifier: supportedLocale.identifier,
            sdkAvailable: true,
            transcriberAvailable: true,
            assetStatus: String(describing: assetStatus),
            compatibleAudioFormatDescription: compatibleFormat.map(Self.describe(format:)),
            status: status,
            notes: notes
        )
    }

    public func prepareSpeechAnalyzerAssets(localeIdentifier: String) async throws -> SpeechAnalyzerEvaluationReport {
        guard #available(macOS 26.0, *) else {
            return try await evaluateSpeechAnalyzer(localeIdentifier: localeIdentifier)
        }

        let requestedLocale = Locale(identifier: localeIdentifier)
        guard SpeechTranscriber.isAvailable,
              let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            return try await evaluateSpeechAnalyzer(localeIdentifier: localeIdentifier)
        }

        let transcriber = SpeechTranscriber(
            locale: supportedLocale,
            preset: .timeIndexedProgressiveTranscription
        )
        let modules: [any SpeechModule] = [transcriber]
        let startingStatus = await AssetInventory.status(forModules: modules)
        guard startingStatus != .installed else {
            var report = try await evaluateSpeechAnalyzer(localeIdentifier: localeIdentifier)
            report.notes.append("SpeechAnalyzer assets were already installed; no download was requested.")
            return report
        }

        guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules) else {
            var report = try await evaluateSpeechAnalyzer(localeIdentifier: localeIdentifier)
            report.notes.append("No SpeechAnalyzer asset installation request was available for \(supportedLocale.identifier).")
            return report
        }

        try await request.downloadAndInstall()
        var report = try await evaluateSpeechAnalyzer(localeIdentifier: localeIdentifier)
        report.notes.append("SpeechAnalyzer asset preparation was explicitly requested by the user.")
        report.notes.append("Asset preparation did not open the microphone or read private recordings.")
        return report
    }

    private func evaluationStatus(assetStatusDescription: String) -> SpeechAnalyzerEvaluationStatus {
        switch assetStatusDescription {
        case "installed":
            .available
        case "supported", "downloading":
            .assetsNeeded
        case "unsupported":
            .unsupported
        default:
            .failed
        }
    }

    private func notes(
        status: SpeechAnalyzerEvaluationStatus,
        assetStatusDescription: String,
        compatibleFormat: AVAudioFormat?
    ) -> [String] {
        var result = [
            "SpeechAnalyzer and SpeechTranscriber symbols are available in the installed macOS SDK.",
            "Evaluation did not open a microphone, read a private recording, request permission, or start transcription."
        ]
        result.append("AssetInventory status is \(assetStatusDescription).")
        if compatibleFormat == nil {
            result.append("No compatible audio format was reported by SpeechAnalyzer for the selected module.")
        }
        switch status {
        case .available:
            result.append("A real non-private audio smoke is still required before this becomes a production transcription runtime.")
        case .assetsNeeded:
            result.append("Speech assets are supported but not proven installed; do not trigger downloads without explicit user approval.")
        case .unsupported:
            result.append("This runtime cannot use SpeechAnalyzer for the requested locale.")
        case .failed:
            result.append("The runtime returned an unrecognized SpeechAnalyzer asset status.")
        case .notEvaluated:
            break
        }
        return result
    }

    private static func describe(format: AVAudioFormat) -> String {
        let sampleRate = Int(format.sampleRate.rounded())
        return "\(sampleRate) Hz, \(format.channelCount) channel(s), \(describe(commonFormat: format.commonFormat))"
    }

    private static func describe(commonFormat: AVAudioCommonFormat) -> String {
        switch commonFormat {
        case .pcmFormatFloat32:
            "32-bit float PCM"
        case .pcmFormatFloat64:
            "64-bit float PCM"
        case .pcmFormatInt16:
            "16-bit integer PCM"
        case .pcmFormatInt32:
            "32-bit integer PCM"
        case .otherFormat:
            "other audio format"
        @unknown default:
            "unknown audio format"
        }
    }
}
