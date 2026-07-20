import Foundation

public enum DiagnosticSeverity: String, Codable, Comparable, Sendable {
    case healthy
    case warning
    case critical

    public static func < (lhs: DiagnosticSeverity, rhs: DiagnosticSeverity) -> Bool {
        lhs.rank < rhs.rank
    }

    private var rank: Int {
        switch self {
        case .healthy: 0
        case .warning: 1
        case .critical: 2
        }
    }
}

public enum DiagnosticWarningCode: String, Codable, Sendable {
    case remoteDropouts
    case microphoneDropouts
    case remoteClipping
    case microphoneClipping
    case remoteSilence
    case microphoneSilence
    case deviceChanged
}

public struct DiagnosticWarning: Codable, Equatable, Sendable {
    public var code: DiagnosticWarningCode
    public var severity: DiagnosticSeverity
    public var message: String

    public init(code: DiagnosticWarningCode, severity: DiagnosticSeverity, message: String) {
        self.code = code
        self.severity = severity
        self.message = message
    }
}

public struct SilentPeriod: Codable, Equatable, Sendable {
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var track: TrackKind

    public init(startTime: TimeInterval, endTime: TimeInterval, track: TrackKind) {
        self.startTime = startTime
        self.endTime = endTime
        self.track = track
    }
}

public struct AudioDeviceChange: Codable, Equatable, Sendable {
    public var time: TimeInterval
    public var from: String
    public var to: String

    public init(time: TimeInterval, from: String, to: String) {
        self.time = time
        self.from = from
        self.to = to
    }
}

public struct CaptureHealthReport: Codable, Equatable, Sendable {
    public var remoteDropouts: Int
    public var microphoneDropouts: Int
    public var remoteClippingPercent: Double
    public var microphoneClippingPercent: Double
    public var silentPeriods: [SilentPeriod]
    public var deviceChanges: [AudioDeviceChange]
    public var transcriptionEngine: String
    public var intelligenceProvider: String

    public init(
        remoteDropouts: Int,
        microphoneDropouts: Int,
        remoteClippingPercent: Double,
        microphoneClippingPercent: Double,
        silentPeriods: [SilentPeriod],
        deviceChanges: [AudioDeviceChange],
        transcriptionEngine: String,
        intelligenceProvider: String
    ) {
        self.remoteDropouts = remoteDropouts
        self.microphoneDropouts = microphoneDropouts
        self.remoteClippingPercent = remoteClippingPercent
        self.microphoneClippingPercent = microphoneClippingPercent
        self.silentPeriods = silentPeriods
        self.deviceChanges = deviceChanges
        self.transcriptionEngine = transcriptionEngine
        self.intelligenceProvider = intelligenceProvider
    }

    public var severity: DiagnosticSeverity {
        warnings.map(\.severity).max() ?? .healthy
    }

    public var warnings: [DiagnosticWarning] {
        var result: [DiagnosticWarning] = []

        if remoteDropouts > 0 {
            result.append(
                DiagnosticWarning(
                    code: .remoteDropouts,
                    severity: remoteDropouts >= 5 ? .critical : .warning,
                    message: "Remote audio had \(remoteDropouts) \(remoteDropouts == 1 ? "dropout" : "dropouts")."
                )
            )
        }

        if microphoneDropouts > 0 {
            result.append(
                DiagnosticWarning(
                    code: .microphoneDropouts,
                    severity: microphoneDropouts >= 5 ? .critical : .warning,
                    message: "Microphone audio had \(microphoneDropouts) \(microphoneDropouts == 1 ? "dropout" : "dropouts")."
                )
            )
        }

        if remoteClippingPercent > 0 {
            result.append(
                DiagnosticWarning(
                    code: .remoteClipping,
                    severity: remoteClippingPercent >= 1 ? .critical : .warning,
                    message: "Remote audio clipped for \(formatPercent(remoteClippingPercent)) of the recording."
                )
            )
        }

        if microphoneClippingPercent > 0 {
            result.append(
                DiagnosticWarning(
                    code: .microphoneClipping,
                    severity: microphoneClippingPercent >= 1 ? .critical : .warning,
                    message: "Microphone audio clipped for \(formatPercent(microphoneClippingPercent)) of the recording."
                )
            )
        }

        for silentPeriod in silentPeriods {
            let isRemote = silentPeriod.track == .remoteSystem
            result.append(
                DiagnosticWarning(
                    code: isRemote ? .remoteSilence : .microphoneSilence,
                    severity: .warning,
                    message: "\(isRemote ? "Remote audio" : "Microphone") was silent for \(formatDuration(silentPeriod.endTime - silentPeriod.startTime))."
                )
            )
        }

        for change in deviceChanges {
            result.append(
                DiagnosticWarning(
                    code: .deviceChanged,
                    severity: .warning,
                    message: "Output device changed from \(change.from) to \(change.to)."
                )
            )
        }

        return result
    }

    private func formatPercent(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }

    private func formatDuration(_ value: TimeInterval) -> String {
        if value < 60 {
            return "\(Int(value.rounded())) seconds"
        }
        return "\(Int((value / 60).rounded())) minutes"
    }
}
