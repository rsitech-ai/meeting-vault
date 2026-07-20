import Foundation
import XCTest
@testable import MeetingVaultCore

final class SpeechAnalyzerEvaluationTests: XCTestCase {
    func testSpeechAnalyzerEvaluationServiceReturnsProviderReport() async throws {
        let report = SpeechAnalyzerEvaluationReport(
            generatedAt: Date(timeIntervalSince1970: 1_804_000_000),
            requestedLocaleIdentifier: "en_US",
            resolvedLocaleIdentifier: "en-US",
            sdkAvailable: true,
            transcriberAvailable: true,
            assetStatus: "installed",
            compatibleAudioFormatDescription: "48000 Hz, 1 channel(s), pcmFormatFloat32",
            status: .available,
            notes: [
                "SpeechAnalyzer and SpeechTranscriber symbols are available in the installed macOS SDK.",
                "A real non-private audio smoke is still required before this becomes a production transcription runtime."
            ]
        )
        let service = SpeechAnalyzerEvaluationService(
            provider: MockSpeechAnalyzerCapabilityProvider(report: report)
        )

        let evaluated = try await service.evaluate(localeIdentifier: "en_US")

        XCTAssertEqual(evaluated, report)
        XCTAssertEqual(evaluated.status.displayTitle, "Available")
    }

    func testSpeechAnalyzerEvaluationServiceSurfacesProviderFailure() async {
        let service = SpeechAnalyzerEvaluationService(
            provider: MockSpeechAnalyzerCapabilityProvider(error: SpeechAnalyzerEvaluationTestError.failed)
        )

        do {
            _ = try await service.evaluate(localeIdentifier: "en_US")
            XCTFail("Expected SpeechAnalyzer evaluation failure")
        } catch {
            XCTAssertEqual(error as? SpeechAnalyzerEvaluationTestError, .failed)
        }
    }

    func testSpeechAnalyzerEvaluationServicePreparesAssetsThroughProvider() async throws {
        let evaluationReport = SpeechAnalyzerEvaluationReport.notEvaluated(requestedLocaleIdentifier: "en_US")
        let preparedReport = SpeechAnalyzerEvaluationReport(
            generatedAt: Date(timeIntervalSince1970: 1_804_000_200),
            requestedLocaleIdentifier: "en_US",
            resolvedLocaleIdentifier: "en-US",
            sdkAvailable: true,
            transcriberAvailable: true,
            assetStatus: "installed",
            compatibleAudioFormatDescription: "16000 Hz, 1 channel(s), 16-bit integer PCM",
            status: .available,
            notes: [
                "SpeechAnalyzer asset preparation was explicitly requested by the user.",
                "Asset preparation did not open the microphone or read private recordings."
            ]
        )
        let service = SpeechAnalyzerEvaluationService(
            provider: MockSpeechAnalyzerCapabilityProvider(
                report: evaluationReport,
                prepareReport: preparedReport
            )
        )

        let report = try await service.prepareAssets(localeIdentifier: "en_US")

        XCTAssertEqual(report, preparedReport)
    }

    func testNotEvaluatedReportIsExplicitlyNotReady() {
        let report = SpeechAnalyzerEvaluationReport.notEvaluated(requestedLocaleIdentifier: "en_GB")

        XCTAssertEqual(report.status, .notEvaluated)
        XCTAssertFalse(report.sdkAvailable)
        XCTAssertEqual(report.requestedLocaleIdentifier, "en_GB")
        XCTAssertTrue(report.notes.first?.contains("not been evaluated") == true)
    }
}

private enum SpeechAnalyzerEvaluationTestError: Error, Equatable {
    case failed
}
