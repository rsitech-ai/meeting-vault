import XCTest
@testable import MeetingVaultCore

final class DiagnosticsTests: XCTestCase {
    func testCaptureHealthReportSurfacesActionableWarnings() {
        let report = CaptureHealthReport(
            remoteDropouts: 2,
            microphoneDropouts: 0,
            remoteClippingPercent: 0.2,
            microphoneClippingPercent: 0,
            silentPeriods: [
                SilentPeriod(startTime: 552.2, endTime: 601.4, track: .remoteSystem)
            ],
            deviceChanges: [
                AudioDeviceChange(time: 1_204.1, from: "AirPods Pro", to: "MacBook Speakers")
            ],
            transcriptionEngine: "SpeechAnalyzer",
            intelligenceProvider: "FoundationModels.onDevice"
        )

        XCTAssertEqual(report.severity, .warning)
        XCTAssertEqual(report.warnings.map(\.code), [
            .remoteDropouts,
            .remoteClipping,
            .remoteSilence,
            .deviceChanged
        ])
        XCTAssertTrue(report.warnings.map(\.message).contains("Remote audio had 2 dropouts."))
        XCTAssertTrue(report.warnings.map(\.message).contains("Output device changed from AirPods Pro to MacBook Speakers."))
    }
}
