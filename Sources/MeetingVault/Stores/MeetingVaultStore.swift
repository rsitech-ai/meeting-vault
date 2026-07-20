import AppKit
import AVFoundation
import Foundation
import MeetingVaultCore
import OSLog

struct TranscriptionPrivacyPresentation: Equatable, Sendable {
    let label: String
    let systemImage: String
    let accessibilityValue: String

    init(mode: TranscriptionPrivacyMode, providerAvailable: Bool) {
        guard providerAvailable else {
            label = "Transcription unavailable"
            systemImage = "exclamationmark.triangle"
            accessibilityValue = "Transcription unavailable; recording remains available"
            return
        }
        switch mode {
        case .localOnly:
            label = "Local only"
            systemImage = "lock.shield"
            accessibilityValue = "Local transcription on this Mac"
        case .appleOnDeviceOnly:
            label = "Apple on-device"
            systemImage = "apple.logo"
            accessibilityValue = "Apple Speech on-device only"
        case .appleMayUseNetwork:
            label = "Apple compatibility"
            systemImage = "network"
            accessibilityValue = "Apple compatibility; network processing may occur"
        }
    }
}

struct TranscriptionSetupPresentation: Equatable, Sendable {
    static let requiredLocalUnitIDs: Set<String> = [
        "automatic-speech-recognition",
        "streaming-speaker-diarization",
        "offline-speaker-diarization",
    ]
    let provider: String
    let version: String
    let locale: String
    let privacy: String
    let readiness: String
    let recoveryTitle: String?

    init(
        mode: TranscriptionPrivacyMode,
        provider descriptor: ProviderDescriptor,
        localeIdentifier: String?,
        localModelStates: [LocalModelAssetState],
        applePermissionGranted: Bool
    ) {
        provider = descriptor.id == "apple-speech-frame-compatibility"
            ? "Apple Speech"
            : "Local transcription"
        version = descriptor.modelVersion
        locale = switch localeIdentifier {
        case nil: "Automatic"
        case "pl-PL": "Polish (Poland)"
        case "en-US": "English (United States)"
        case let value?: value
        }
        privacy = switch mode {
        case .localOnly: "Local only · no network fallback"
        case .appleOnDeviceOnly: "Apple on-device only · no server fallback"
        case .appleMayUseNetwork: "Apple compatibility · network may be used"
        }

        if let localeIdentifier,
           !descriptor.supportedLocaleIdentifiers.contains(localeIdentifier) {
            readiness = "Unsupported language"
            recoveryTitle = "Choose Automatic, Polish, or English"
        } else if mode == .localOnly {
            let states = Dictionary(uniqueKeysWithValues: localModelStates.map { ($0.id, $0.status) })
            let requiredStatuses = Self.requiredLocalUnitIDs.compactMap { states[$0] }
            if requiredStatuses.count != Self.requiredLocalUnitIDs.count
                || requiredStatuses.contains(.notInstalled)
                || requiredStatuses.contains(.unsupported) {
                readiness = "Models required · recording stays available"
                recoveryTitle = "Open Local Models & Privacy"
            } else if requiredStatuses.contains(.repairNeeded) {
                readiness = "Model repair required · recording stays available"
                recoveryTitle = "Open Local Models & Privacy"
            } else if requiredStatuses.contains(where: { $0 == .downloading || $0 == .verifying }) {
                readiness = "Models are being prepared · recording stays available"
                recoveryTitle = "Open Local Models & Privacy"
            } else {
                readiness = "Ready for both-side transcription"
                recoveryTitle = nil
            }
        } else if mode != .localOnly, !applePermissionGranted {
            readiness = "Speech permission required for transcription"
            recoveryTitle = "Open Speech Recognition Settings"
        } else {
            readiness = "Ready for both-side transcription"
            recoveryTitle = nil
        }
    }
}

struct TranscriptConversationTurn: Identifiable, Equatable {
    var id: UUID
    var createdAt: Date
    var question: String
    var answerDraft: String
    var evidence: [TranscriptQuestionEvidence]

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        question: String,
        answerDraft: String,
        evidence: [TranscriptQuestionEvidence]
    ) {
        self.id = id
        self.createdAt = createdAt
        self.question = question
        self.answerDraft = answerDraft
        self.evidence = evidence
    }
}

enum TranscriptPromptPreset: String, CaseIterable, Identifiable {
    case decisions
    case actions
    case followUps
    case executiveSummary
    case explain
    case risks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .decisions:
            "Decisions"
        case .actions:
            "Actions"
        case .followUps:
            "Follow-ups"
        case .executiveSummary:
            "Summarize"
        case .explain:
            "Explain"
        case .risks:
            "Risks"
        }
    }

    var systemImage: String {
        switch self {
        case .decisions:
            "checkmark.seal"
        case .actions:
            "checklist"
        case .followUps:
            "arrowshape.turn.up.right"
        case .executiveSummary:
            "doc.text.magnifyingglass"
        case .explain:
            "lightbulb.max"
        case .risks:
            "exclamationmark.triangle"
        }
    }

    var prompt: String {
        switch self {
        case .decisions:
            "What did we decide, and what needs follow-up?"
        case .actions:
            "List action items, owners, and deadlines from this transcript."
        case .followUps:
            "What should I follow up on next, and who needs to be involved?"
        case .executiveSummary:
            "Write a concise executive brief with outcome, decisions, blockers, and next actions."
        case .explain:
            "Explain the transcript in plain language, including context, why it matters, and the practical next step."
        case .risks:
            "What risks, blockers, or open questions did people mention?"
        }
    }
}

enum MeetingVaultCaptureRuntimeMode: Equatable {
    case mock
    case systemAndMicrophone
    case coreAudio
    case selectedMicrophone
    case screenCaptureKit

    static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> MeetingVaultCaptureRuntimeMode {
        switch environment["MEETINGVAULT_CAPTURE_RUNTIME"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "system-and-microphone", "system_and_microphone", "meeting-audio", "meeting_audio", "combined":
            .systemAndMicrophone
        case "core-audio", "core_audio", "coreaudio", "tap", "process-tap", "system-tap":
            .coreAudio
        case "selected-microphone", "selected_microphone", "microphone", "avfoundation":
            .selectedMicrophone
        case "screen-capture-kit", "screen_capture_kit", "screencapturekit", "screen-capture", "system-audio":
            .screenCaptureKit
        default:
            .mock
        }
    }
}

enum MeetingVaultLiveTranscriptionRuntimeMode: Equatable {
    case local
    case demo
    case appleSpeech

    static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> MeetingVaultLiveTranscriptionRuntimeMode {
        switch environment["MEETINGVAULT_LIVE_TRANSCRIPTION"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "apple-speech", "apple_speech", "speech", "sfspeech":
            .appleSpeech
        case "demo", "fixture":
            .demo
        default:
            .local
        }
    }
}

enum MeetingVaultFinalTranscriptionRuntimeMode: Equatable {
    case local
    case demo
    case appleSpeech
    case speechAnalyzer

    static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> MeetingVaultFinalTranscriptionRuntimeMode {
        switch environment["MEETINGVAULT_FINAL_TRANSCRIPTION"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "local", "local-only", "local_only", "fluidaudio":
            .local
        case "apple-speech", "apple_speech", "speech", "sfspeech":
            .appleSpeech
        case "speech-analyzer", "speech_analyzer", "speechanalyzer":
            .speechAnalyzer
        case "demo", "fixture":
            .demo
        default:
            .local
        }
    }
}

enum MeetingVaultIntelligenceRuntimeMode: Equatable {
    case demo
    case foundationModels

    static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> MeetingVaultIntelligenceRuntimeMode {
        switch environment["MEETINGVAULT_INTELLIGENCE_RUNTIME"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "foundation-models", "foundation_models", "apple-intelligence", "apple_intelligence", "foundationmodels":
            .foundationModels
        default:
            .demo
        }
    }
}

enum MeetingVaultTranscriptQuestionRuntimeMode: Equatable {
    case deterministic
    case foundationModels

    static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> MeetingVaultTranscriptQuestionRuntimeMode {
        switch environment["MEETINGVAULT_TRANSCRIPT_QA_RUNTIME"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "foundation-models", "foundation_models", "apple-intelligence", "apple_intelligence", "foundationmodels":
            .foundationModels
        default:
            .deterministic
        }
    }
}

enum RecordingBookmarkOutcome: Equatable, Sendable {
    case saved(MeetingBookmark)
    case failed
}

final class RecordingBookmarkOperation: @unchecked Sendable {
    let id: UUID
    let meetingID: UUID
    let sessionGeneration: UUID
    let sequence: UInt64
    fileprivate let task: Task<MeetingBookmark, Error>

    fileprivate init(
        id: UUID,
        meetingID: UUID,
        sessionGeneration: UUID,
        sequence: UInt64,
        task: Task<MeetingBookmark, Error>
    ) {
        self.id = id
        self.meetingID = meetingID
        self.sessionGeneration = sessionGeneration
        self.sequence = sequence
        self.task = task
    }

    func outcome() async -> RecordingBookmarkOutcome {
        do {
            return .saved(try await task.value)
        } catch {
            return .failed
        }
    }
}

@MainActor
final class MeetingVaultStore: ObservableObject {
    @Published var recordingState: RecordingState = .ready
    @Published var selectedSourceID: String = "zoom"
    @Published var requireConsentBeforeRecording = true
    @Published var selectedMeetingID: UUID? {
        didSet {
            guard selectedMeetingID != oldValue else { return }
            transcriptAskTask?.cancel()
            transcriptAskTask = nil
            if let oldValue {
                transcriptAgentRequestGenerations[oldValue] = UUID()
            }
            lastExportPackage = nil
            lastShareManifest = nil
            lastShareExecutionResult = nil
            cacheCurrentTranscriptEditSession(for: oldValue)
            transcriptSelectionGeneration = UUID()
            refreshSelectedTranscriptCorrectionActivity()
            transcriptReviewQueue = nil
            transcriptReviewStatus = selectedMeetingID == nil
                ? "Select a meeting to review transcript confidence"
                : "Loading confidence evidence"
            stopPlaybackIfSelectionDoesNotMatchTimeline()
            clearSelectedTranscriptWorkspace(
                meetingID: selectedMeetingID ?? UUID(),
                status: selectedMeetingID == nil
                    ? "Select a meeting to ask about its transcript"
                    : "Loading selected transcript"
            )
            loadTranscriptEditSessionForSelectedMeeting()
            refreshTranscriptReviewForSelectedMeeting()
        }
    }
    @Published var captureHealthReport: CaptureHealthReport
    @Published var latestPreflightResult: PermissionPreflightResult?
    @Published var permissionRecoveryStatus = "Permission recovery opens System Settings only when you choose it"
    @Published var storageRecoveryStatus = "Storage recovery opens Diagnostics only when you choose it"
    @Published var privacyAuditReview: PrivacyAuditReview
    @Published var privacyAuditActionFilter: PrivacyAuditAction?
    @Published var privacyAuditExportStatus = "Privacy audit export ready"
    @Published var lastPrivacyAuditExport: PrivacyAuditReviewExport?
    @Published var playbackTimeline: TranscriptPlaybackTimeline
    @Published var playbackSessionState: TranscriptPlaybackSessionState
    @Published var automationPlans: [MeetingAutomationPlan]
    @Published var systemIntegrationReview: MeetingSystemIntegrationReview?
    @Published var lastSystemIntegrationExecutionResult: MeetingSystemIntegrationExecutionResult?
    @Published var systemIntegrationStatus = "Calendar, Contacts, and Reminders review ready"
    @Published var transcriptEditDraft: TranscriptEditDraft
    @Published var transcriptEditHistory: TranscriptEditHistory
    @Published var transcriptEditStatus = "No unsaved edits"
    @Published var transcriptReviewQueue: TranscriptReviewQueue?
    @Published var transcriptReviewStatus = "Select a meeting to review transcript confidence"
    @Published private(set) var transcriptCorrectionInFlight = false
    @Published var transcriptRestoreNeedsConfirmation = false
    @Published var transcriptAskPrompt = "What did we decide, and what needs follow-up?"
    @Published var transcriptAskAnswerDraft = ""
    @Published var transcriptAskStatus = "Ask a question about the selected transcript"
    @Published var transcriptAskEvidence: [TranscriptQuestionEvidence] = []
    @Published var transcriptConversationTurns: [TranscriptConversationTurn] = []
    @Published var recordingProcessingProgress: RecordingProcessingProgress?
    @Published var recordingProcessingStatus = "No processing active"
    @Published var recordingProcessingFailureStage: RecordingProcessingStage?
    @Published var meetingContextDraft = MeetingContext()
    @Published private(set) var meetingContextReuseStatus = "Meeting context starts empty for every new recording"
    @Published private(set) var activeMeetingContext: MeetingContext?
    @Published private(set) var activeRecordingPresentation: ActiveRecordingPresentation?
    @Published private(set) var lastMarkedMoment: MeetingBookmark?
    @Published private(set) var recordingBookmarkStatus = "Mark Moment is available while recording"
    @Published private(set) var selectedBookmarkStatus = "No marked moments loaded"
    @Published private(set) var recordingStartInFlight = false
    @Published private(set) var runtimeInitializationError: String?
    @Published var recordingProcessingRecoveryStatus = "Capture recovery actions appear after a failed recording"
    @Published var recoveredRecordings: [RecoveredRecordingReport]
    @Published var recoveredRecordingImportStatus = "Recovered recording import ready"
    @Published var requestedSidebarItem: String?
    @Published var requestedWorkspaceFocus: String?
    @Published private(set) var healthRecoveryPresentationEvent: HealthRecoveryPresentationEvent?
    @Published var localRecordingImportStatus = "Local recording import ready"
    @Published var localRecordingSampleStatus = "Scan local recording folders to pick a matched transcript/audio pair"
    @Published var localRecordingSamples: [LocalRecordingSampleCandidate] = []
    @Published var selectedLocalRecordingSampleID: String?
    @Published var localRecordingTranscriptPath = ""
    @Published var localRecordingAudioPath = ""
    @Published var audioInputDevices: [AudioInputDevice] = []
    @Published var selectedAudioInputDeviceID: String?
    @Published var audioInputStatus = "Audio input detection ready"
    @Published var microphoneAuthorizationState: PermissionAuthorizationStatus = .unknown
    @Published var microphoneAuthorizationStatus = "Microphone permission has not been checked"
    @Published var appleSpeechAuthorizationState: SpeechRecognitionAuthorizationState = .unknown
    @Published var appleSpeechAuthorizationStatus = "Speech Recognition permission has not been checked"
    @Published var speechAnalyzerEvaluationReport = SpeechAnalyzerEvaluationReport.notEvaluated()
    @Published var speechAnalyzerEvaluationStatus = "SpeechAnalyzer evaluation ready"
    @Published var releaseBlockerSummary: ReleaseBlockerSummary
    @Published var releaseBlockerStatus = "Release blocker report ready"
    @Published var liveTranscriptPreviewSegments: [TranscriptSegment] = []
    @Published var liveTranscriptionStatus = "Live transcript preview starts when recording begins"
    @Published private(set) var transcriptionPrivacyPresentation = TranscriptionPrivacyPresentation(
        mode: .localOnly,
        providerAvailable: false
    )
    @Published private(set) var transcriptionSetupPresentation = TranscriptionSetupPresentation(
        mode: .localOnly,
        provider: UnavailableLocalTranscriptionProvider(reason: "Install models").descriptor,
        localeIdentifier: nil,
        localModelStates: [],
        applePermissionGranted: false
    )
    @Published var liveInputLevel: Double = 0
    @Published private(set) var liveSystemAudioLevel: Double = 0
    @Published private(set) var liveActiveSpeakers: [String] = []
    @Published var recordingLevelSnapshot = RecordingLevelSnapshot()
    private var recordingLevelGeneration = UUID()
    @Published private(set) var recordingPreviewDropCount = 0
    @Published private(set) var recordingPreviewDropStatus = "No live preview frames have been skipped"
    private var recordingPreviewDropGeneration = UUID()
    @Published var exportMarkdown = true
    @Published var exportWebVTT = true
    @Published var exportPDF = true
    @Published var exportDOCX = true
    @Published var exportJSON = true
    @Published var exportAudioPackage = false
    @Published var exportStatus = "Export package ready"
    @Published var lastExportPackage: MeetingExportPackage?
    @Published var libraryDeleteStatus = "Select a recording to delete it from the local library"
    @Published var shareDestination: MeetingShareDestination = .systemShareSheet
    @Published var shareStatus = "Prepare a local share from the latest export package"
    @Published var lastShareManifest: MeetingShareManifest?
    @Published var lastShareExecutionResult: MeetingShareExecutionResult?
    @Published var retentionDays = 30
    @Published var retentionCleanupPlan: RetentionCleanupPlan?
    @Published var retentionCleanupStatus = "Retention review ready"

    var transcriptAgentHasVisibleTranscript: Bool {
        transcriptEditDraft.segments.contains { !$0.trimmedEditedText.isEmpty }
    }

    var selectedTranscriptReviewQueue: TranscriptReviewQueue? {
        guard let selectedMeetingID,
              transcriptReviewQueue?.meetingID == selectedMeetingID,
              transcriptEditDraft.meetingID == selectedMeetingID,
              playbackTimeline.meetingID == selectedMeetingID else {
            return nil
        }
        return transcriptReviewQueue
    }

    var transcriptAgentCanAsk: Bool {
        transcriptAgentHasVisibleTranscript
            && !transcriptCorrectionInFlight
            && !transcriptAskPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var transcriptAgentReadinessStatus: String {
        if transcriptCorrectionInFlight {
            return "Agent is unavailable while transcript correction is being saved or recovered."
        }
        if !transcriptAgentHasVisibleTranscript {
            if recordingState == .recording, !liveTranscriptPreviewSegments.isEmpty {
                return "Live transcript is streaming. Stop recording to finalize it before asking Agent."
            }
            if recordingState == .processing {
                return "Final transcription is running. Agent unlocks when the saved transcript is ready."
            }
            return "Record or import a meeting to create a visible transcript before asking Agent."
        }
        if transcriptAskPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Choose a preset or write a prompt for the visible transcript."
        }
        return transcriptAskStatus
    }

    let logger = Logger(subsystem: "com.andrzej.MeetingVault", category: "app")
    private let permissionPreflightService: PermissionPreflightService
    private let permissionSettingsOpener: any PermissionSettingsOpening
    private let microphoneAuthorizationProvider: any MicrophoneAuthorizationProviding
    private let speechRecognitionAuthorizationProvider: any SpeechRecognitionAuthorizationProviding
    private let audioInputDeviceService: AudioInputDeviceService
    private let transcriptEditSessionService: TranscriptEditSessionService?
    private let transcriptQuestionAnsweringService = TranscriptQuestionAnsweringService()
    private let transcriptQuestionAnsweringProvider: (any TranscriptQuestionAnsweringProviding)?
    private let transcriptQuestionHistoryService: TranscriptQuestionHistoryService?
    private let recordingProcessingService: RecordingProcessingService?
    private let recordingSessionMetadataManager: (any RecordingSessionMetadataManaging)?
    private let meetingContextBundleStore: EncryptedMeetingBundleStore?
    private let meetingIntelligenceService: MeetingIntelligenceService?
    private let recordingRecoveryService: RecordingRecoveryService?
    private let recoveredRecordingImportService: RecoveredRecordingImportService?
    private let localRecordingImportService: LocalRecordingImportService?
    private let meetingDeleteService: MeetingDeleteService?
    private let meetingExportService: MeetingExportService?
    private let meetingSharePreparationService: MeetingSharePreparationService?
    private let retentionCleanupService: RetentionCleanupService?
    private let systemIntegrationPreparationService = MeetingSystemIntegrationPreparationService()
    private let systemIntegrationExecutionService: MeetingSystemIntegrationExecutionService
    private let meetingShareExecutor: any MeetingShareExecuting
    private let exportRoot: URL?
    private let recordingStorageRoot: URL
    private let localRecordingSampleCatalogService = LocalRecordingSampleCatalogService()
    private let speechAnalyzerEvaluationService: SpeechAnalyzerEvaluationService
    private let releaseBlockerSummaryService = ReleaseBlockerSummaryService()
    private let releaseBlockerReportURL: URL?
    private let transcriptPlaybackSessionService: TranscriptPlaybackSessionService?
    private let transcriptCorrectionCoordinator: TranscriptCorrectionCoordinator?
    private let transcriptCorrectionStoreReconciliationGate: @Sendable (UUID) async -> Void
    private let localTranscriptionProvider: any LocalTranscriptionProviding
    private let localModelReadinessProvider: (any LocalModelReadinessProviding)?
    private var localModelReadinessStates: [LocalModelAssetState] = []
    private let appleSpeechTranscriptionProvider: any LocalTranscriptionProviding
    private let transcriptionPrivacyBoundary: TranscriptionPrivacyBoundary
    private let transcriptionActivityGate: TranscriptionRuntimeActivityGate
    private let now: @Sendable () -> Date
    private var transcriptEditMeetingsByID: [UUID: SearchMeeting]
    private var transcriptEditSessionCache: [UUID: TranscriptEditSession]
    private var transcriptQuestionHistoryCache: [UUID: TranscriptQuestionHistory]
    private struct TranscriptAgentRequestAuthority {
        let meetingID: UUID
        let generation: UUID
        let transcriptVersion: Int
        let transcriptDigest: String
    }
    private var transcriptAgentRequestGenerations: [UUID: UUID] = [:]
    private var transcriptSelectionGeneration = UUID()
    private struct TranscriptCorrectionActivity {
        let token: UUID
        let draftAtStart: TranscriptEditDraft
        let historyAtStart: TranscriptEditHistory
    }
    private var transcriptCorrectionActivities: [UUID: TranscriptCorrectionActivity] = [:]
    private let recordingProcessingCancellation = RecordingProcessingCancellation()
    private var lastRecordingProcessingIntent: RecordingProcessingIntent?
    private var activeRecordingSession: ActiveRecordingProcessingSession?
    private var recordingActivityLease: TranscriptionRecordingActivityLease?
    private var activeRecordingCaptureMonitorTask: Task<Void, Never>?
    private var pendingBookmarkMutations: [UUID: RecordingBookmarkOperation] = [:]
    private var bookmarkMutationTail: Task<MeetingBookmark, Error>?
    private var bookmarkSessionGeneration = UUID()
    private var bookmarkRequestSequence: UInt64 = 0
    private var recordingCancellationInFlight = false
    private var activeLiveTranscriptionContext: LiveTranscriptionContext?
    private var activeTranscriptionCoordinator: TranscriptionSessionCoordinator?
    private var liveTranscriptPreviewTask: Task<Void, Never>?
    private var transcriptAskTask: Task<Void, Never>?
    private var liveTranscriptSegments: [TranscriptSegment] = []
    private var audioInputSelectionIsManual = false

    var canStartRecording: Bool {
        guard !recordingStartInFlight, activeRecordingSession == nil else { return false }
        switch recordingState {
        case .recording, .paused, .processing:
            return false
        case .idle, .ready, .permissionNeeded, .error, .recovered:
            return true
        }
    }

    var privacyTransitionIsBlocked: Bool {
        recordingStartInFlight || activeRecordingSession != nil || recordingState == .recording || recordingState == .processing
    }

    func restartLiveTranscriptionForPrivacyTransition() async {
        // Transitions are rejected while a capture exists. With no active capture,
        // there is no provider task to restart; cancelling any stale preview task
        // makes the replacement boundary the next provider-start contract.
        guard !privacyTransitionIsBlocked else { return }
        let mode = await transcriptionPrivacyBoundary.mode()
        transcriptionPrivacyPresentation = TranscriptionPrivacyPresentation(
            mode: mode,
            providerAvailable: providerIsAvailable(for: mode)
        )
        await refreshTranscriptionSetupPresentation()
        latestPreflightResult = nil
        stopLiveTranscriptPreviewLoop(finalStatus: "Live transcription will use the updated privacy boundary on the next recording")
    }

    private func providerIsAvailable(for mode: TranscriptionPrivacyMode) -> Bool {
        switch mode {
        case .localOnly:
            let statuses = Dictionary(uniqueKeysWithValues: localModelReadinessStates.map { ($0.id, $0.status) })
            return TranscriptionSetupPresentation.requiredLocalUnitIDs.allSatisfy { statuses[$0] == .ready }
        case .appleOnDeviceOnly, .appleMayUseNetwork:
            return true
        }
    }

    private func resolvedTranscriptionProviderForNextSession() async -> any LocalTranscriptionProviding {
        switch await transcriptionPrivacyBoundary.mode() {
        case .localOnly:
            return localTranscriptionProvider.descriptor.id == "apple-speech-frame-compatibility"
                ? UnavailableLocalTranscriptionProvider(reason: "Verified local models are unavailable")
                : localTranscriptionProvider
        case .appleOnDeviceOnly, .appleMayUseNetwork:
            return appleSpeechTranscriptionProvider
        }
    }

    func resolvedTranscriptionProviderIDForNextSession() async -> String {
        let provider = await resolvedTranscriptionProviderForNextSession()
        return provider.descriptor.id
    }

    var canStopRecording: Bool {
        activeRecordingSession != nil && recordingState == .recording
    }

    var recordingBookmarkPresentation: RecordingBookmarkPresentation {
        guard recordingState == .recording,
              activeRecordingSession != nil,
              activeRecordingPresentation != nil,
              recordingSessionMetadataManager != nil else {
            return RecordingBookmarkPresentation(
                isEnabled: false,
                detail: "Available only while an encrypted recording is active"
            )
        }
        return RecordingBookmarkPresentation(
            isEnabled: true,
            detail: pendingBookmarkMutations.isEmpty
                ? "Save this exact moment"
                : "Save another distinct moment while earlier marks finish encrypting"
        )
    }

    var recordingBookmarkNativeObservation: RecordingBookmarkNativeObservation {
        RecordingBookmarkNativeObservation(
            acceptedCount: bookmarkRequestSequence,
            lastStableIdentifier: lastMarkedMoment?.id
        )
    }

    var meetingContextForEditor: MeetingContext {
        activeMeetingContext ?? meetingContextDraft
    }

    func reusePreviousMeetingContext() {
        guard !recordingStartInFlight else {
            meetingContextReuseStatus = "Meeting context cannot change while recording is starting"
            return
        }
        guard recordingState != .recording, recordingState != .processing else {
            meetingContextReuseStatus = "Meeting context cannot change while recording is active"
            return
        }
        guard let selectedMeetingID, let meetingContextBundleStore else {
            meetingContextReuseStatus = "No reusable context is available for the selected meeting"
            return
        }
        do {
            let context = try meetingContextBundleStore
                .readManifest(meetingID: selectedMeetingID)
                .context
                .validated()
            guard context != MeetingContext() else {
                meetingContextReuseStatus = "No reusable context is available for the selected meeting"
                return
            }
            meetingContextDraft = context
            Task { @MainActor [weak self] in await self?.refreshTranscriptionSetupPresentation() }
            meetingContextReuseStatus = "Reused context from the selected meeting"
        } catch {
            meetingContextReuseStatus = "No reusable context is available for the selected meeting"
            logger.info("Meeting context reuse unavailable for selected meeting")
        }
    }

    @discardableResult
    func mutateMeetingContextDraft(_ mutation: (inout MeetingContext) -> Void) -> Bool {
        guard !recordingStartInFlight,
              recordingState != .recording,
              recordingState != .processing
        else {
            meetingContextReuseStatus = recordingStartInFlight
                ? "Meeting context cannot change while recording is starting"
                : "Meeting context cannot change while recording is active"
            return false
        }
        mutation(&meetingContextDraft)
        Task { @MainActor [weak self] in await self?.refreshTranscriptionSetupPresentation() }
        return true
    }

    var sources: [CaptureSource]
    @Published var meetings: [MeetingRecord]

    init(
        permissionProvider: PermissionProviding = SystemPermissionProvider(),
        libraryRoot: URL? = nil,
        keyProvider: (any SymmetricKeyProvider)? = nil,
        storageCapacityChecker: any RecordingStorageCapacityChecking = SystemRecordingStorageCapacityChecker(),
        playbackAudioEngine: (any TranscriptAudioEngine)? = nil,
        audioInputDeviceProvider: AudioInputDeviceProviding = SystemAudioInputDeviceProvider(),
        recordingSessionMetadataCreator: (any RecordingSessionMetadataCreating)? = nil,
        captureRuntimeMode: MeetingVaultCaptureRuntimeMode = .fromEnvironment(),
        liveTranscriptionRuntimeMode: MeetingVaultLiveTranscriptionRuntimeMode = .fromEnvironment(),
        finalTranscriptionRuntimeMode: MeetingVaultFinalTranscriptionRuntimeMode = .demo,
        intelligenceRuntimeMode: MeetingVaultIntelligenceRuntimeMode = .fromEnvironment(),
        transcriptQuestionRuntimeMode: MeetingVaultTranscriptQuestionRuntimeMode = .fromEnvironment(),
        coreAudioTapCapturer: (any CoreAudioTapCapturing)? = nil,
        selectedMicrophoneCapturer: (any SelectedMicrophoneAudioCapturing)? = nil,
        screenCaptureKitCapturer: (any ScreenCaptureKitSystemAudioCapturing)? = nil,
        liveTranscriptionProvider: (any LiveTranscriptionProviding)? = nil,
        localTranscriptionProvider: (any LocalTranscriptionProviding)? = nil,
        localModelRuntime: (any LocalModelRuntimeSessionProviding)? = nil,
        transcriptionPrivacyBoundary: TranscriptionPrivacyBoundary? = nil,
        transcriptionActivityGate: TranscriptionRuntimeActivityGate? = nil,
        transcriptQuestionAnsweringProvider: (any TranscriptQuestionAnsweringProviding)? = nil,
        microphoneAuthorizationProvider: any MicrophoneAuthorizationProviding = SystemMicrophoneAuthorizationProvider(),
        speechRecognitionAuthorizationProvider: any SpeechRecognitionAuthorizationProviding = SystemSpeechRecognitionAuthorizationProvider(),
        speechAnalyzerCapabilityProvider: any SpeechAnalyzerCapabilityProviding = SystemSpeechAnalyzerCapabilityProvider(),
        releaseBlockerReportURL: URL? = nil,
        permissionSettingsOpener: (any PermissionSettingsOpening)? = nil,
        meetingShareExecutor: (any MeetingShareExecuting)? = nil,
        systemIntegrationExecutor: (any MeetingSystemIntegrationExecuting)? = MeetingVaultSystemIntegrationExecutor(),
        includeSampleData: Bool = true,
        transcriptCorrectionRegenerationGate: @escaping @Sendable (UUID) async throws -> Void = { _ in },
        transcriptCorrectionStoreReconciliationGate: @escaping @Sendable (UUID) async -> Void = { _ in },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        let resolvedTranscriptionPrivacyBoundary = transcriptionPrivacyBoundary
            ?? TranscriptionPrivacyBoundary(modeStore: TranscriptionPrivacyModeStore())
        let resolvedTranscriptionActivityGate = transcriptionActivityGate
            ?? TranscriptionRuntimeActivityGate()
        let resolvedLibraryRoot = libraryRoot ?? (try? Self.defaultLibraryRoot())
        let preflightStorageRoot = resolvedLibraryRoot ?? Self.fallbackLibraryRoot()
        let resolvedKeyProvider = keyProvider ?? Self.defaultLocalKeyProvider(libraryRoot: libraryRoot)
        let resolvedLocalTranscriptionProvider = localTranscriptionProvider
            ?? liveTranscriptionProvider.map { LegacyLiveTranscriptionLocalAdapter(provider: $0) }
            ?? Self.makeLocalTranscriptionProvider(
                mode: liveTranscriptionRuntimeMode,
                privacyBoundary: resolvedTranscriptionPrivacyBoundary,
                localModelRuntime: localModelRuntime
            )
        let editRuntimeResult = Self.makeTranscriptEditRuntime(
            libraryRoot: resolvedLibraryRoot,
            keyProvider: resolvedKeyProvider,
            playbackAudioEngine: playbackAudioEngine,
            audioInputDeviceProvider: audioInputDeviceProvider,
            recordingSessionMetadataCreator: recordingSessionMetadataCreator,
            captureRuntimeMode: captureRuntimeMode,
            finalTranscriptionRuntimeMode: finalTranscriptionRuntimeMode,
            localTranscriptionProvider: resolvedLocalTranscriptionProvider,
            localModelRuntime: localModelRuntime,
            intelligenceRuntimeMode: intelligenceRuntimeMode,
            coreAudioTapCapturer: coreAudioTapCapturer,
            selectedMicrophoneCapturer: selectedMicrophoneCapturer,
            screenCaptureKitCapturer: screenCaptureKitCapturer,
            transcriptionPrivacyBoundary: resolvedTranscriptionPrivacyBoundary,
            transcriptCorrectionRegenerationGate: transcriptCorrectionRegenerationGate,
            includeSampleData: includeSampleData
        )
        let editRuntime: TranscriptEditRuntime?
        let runtimeInitializationError: String?
        switch editRuntimeResult {
        case let .success(runtime):
            editRuntime = runtime
            runtimeInitializationError = nil
        case let .failure(error):
            editRuntime = nil
            runtimeInitializationError = error.localizedDescription
        }
        let canUseSampleData = includeSampleData && runtimeInitializationError == nil
        let resolvedSources = editRuntime?.captureSources ?? SampleData.sources
        let resolvedSelectedSourceID = resolvedSources.contains { $0.id == "zoom" }
            ? "zoom"
            : (resolvedSources.first?.id ?? "zoom")
        let resolvedMeetings = editRuntime?.records ?? (canUseSampleData ? SampleData.meetings : [])
        let resolvedMeetingsByID = editRuntime?.meetingsByID
            ?? (canUseSampleData ? [SampleData.editorSearchMeeting.id: SampleData.editorSearchMeeting] : [:])
        let emptyDraftMeetingID = UUID()
        let emptyTranscript = MeetingTranscript(
            meetingID: emptyDraftMeetingID,
            localeIdentifier: Locale.current.identifier,
            segments: []
        )
        let emptyHistory = TranscriptEditHistory(meetingID: emptyDraftMeetingID)
        let initialMeetingID = resolvedMeetings.first?.id ?? (canUseSampleData ? SampleData.meetingID : nil)
        let initialSession = initialMeetingID.flatMap { editRuntime?.sessionsByMeetingID[$0] }

        self.sources = resolvedSources
        self.meetings = resolvedMeetings
        self.selectedSourceID = resolvedSelectedSourceID
        self.captureHealthReport = SampleData.captureHealthReport
        let initialPlaybackTimeline = canUseSampleData
            ? SampleData.playbackTimeline
            : TranscriptPlaybackTimelineService().buildTimeline(transcript: emptyTranscript, audioChunks: [])
        self.playbackTimeline = initialPlaybackTimeline
        self.playbackSessionState = editRuntime?.playbackSessionService.initialState(for: initialPlaybackTimeline)
            ?? TranscriptPlaybackSessionState.idle(for: initialPlaybackTimeline)
        self.automationPlans = SampleData.automationPlans
        self.transcriptEditMeetingsByID = resolvedMeetingsByID
        self.transcriptEditSessionCache = editRuntime?.sessionsByMeetingID ?? [:]
        self.transcriptQuestionHistoryCache = [:]
        self.runtimeInitializationError = runtimeInitializationError
        self.recoveredRecordings = editRuntime?.recoveredRecordings ?? []
        self.privacyAuditReview = editRuntime?.privacyAuditReview ?? SampleData.privacyAuditReview
        self.transcriptEditHistory = initialSession?.history ?? (canUseSampleData ? SampleData.transcriptEditHistory : emptyHistory)
        self.transcriptEditDraft = initialSession?.draft ?? TranscriptEditDraft(
            transcript: canUseSampleData ? SampleData.editorTranscript : emptyTranscript,
            history: canUseSampleData ? SampleData.transcriptEditHistory : emptyHistory
        )
        self.transcriptReviewQueue = initialMeetingID.flatMap { meetingID in
            guard let bundleStore = editRuntime?.bundleStore else { return nil }
            return try? TranscriptReviewRepository(bundleStore: bundleStore).load(meetingID: meetingID)
        }
        self.transcriptEditSessionService = editRuntime?.service
        self.transcriptQuestionHistoryService = editRuntime?.transcriptQuestionHistoryService
        self.recordingProcessingService = editRuntime?.recordingProcessingService
        self.recordingSessionMetadataManager = editRuntime?.recordingSessionMetadataManager
        self.meetingContextBundleStore = editRuntime?.bundleStore
        self.meetingIntelligenceService = editRuntime?.meetingIntelligenceService
        self.recordingRecoveryService = editRuntime?.recordingRecoveryService
        self.recoveredRecordingImportService = editRuntime?.recoveredRecordingImportService
        self.localRecordingImportService = editRuntime?.localRecordingImportService
        self.meetingDeleteService = editRuntime?.meetingDeleteService
        self.meetingExportService = editRuntime?.meetingExportService
        self.meetingSharePreparationService = editRuntime?.meetingSharePreparationService
        self.retentionCleanupService = editRuntime?.retentionCleanupService
        self.systemIntegrationExecutionService = MeetingSystemIntegrationExecutionService(executor: systemIntegrationExecutor)
        self.meetingShareExecutor = meetingShareExecutor ?? AppKitMeetingShareExecutor()
        self.exportRoot = editRuntime?.exportRoot
        self.recordingStorageRoot = preflightStorageRoot
        self.transcriptPlaybackSessionService = editRuntime?.playbackSessionService
        self.transcriptCorrectionCoordinator = editRuntime?.transcriptCorrectionCoordinator
        self.transcriptCorrectionStoreReconciliationGate = transcriptCorrectionStoreReconciliationGate
        self.speechAnalyzerEvaluationService = SpeechAnalyzerEvaluationService(provider: speechAnalyzerCapabilityProvider)
        let resolvedReleaseBlockerReportURL = releaseBlockerReportURL ?? Self.defaultReleaseBlockerReportURL()
        let initialReleaseBlockerSummary = releaseBlockerSummaryService.loadReport(at: resolvedReleaseBlockerReportURL)
        self.releaseBlockerReportURL = resolvedReleaseBlockerReportURL
        self.releaseBlockerSummary = initialReleaseBlockerSummary
        self.releaseBlockerStatus = Self.releaseBlockerStatusText(for: initialReleaseBlockerSummary)
        self.localTranscriptionProvider = resolvedLocalTranscriptionProvider
        self.localModelReadinessProvider = localModelRuntime as? any LocalModelReadinessProviding
        self.appleSpeechTranscriptionProvider = AppleSpeechFrameTranscriptionProvider(
            privacyBoundary: resolvedTranscriptionPrivacyBoundary
        )
        self.transcriptionPrivacyBoundary = resolvedTranscriptionPrivacyBoundary
        self.transcriptionActivityGate = resolvedTranscriptionActivityGate
        self.transcriptQuestionAnsweringProvider = transcriptQuestionAnsweringProvider
            ?? Self.makeTranscriptQuestionAnsweringProvider(mode: transcriptQuestionRuntimeMode)
        self.permissionPreflightService = PermissionPreflightService(
            permissionProvider: permissionProvider,
            storageCapacityChecker: storageCapacityChecker
        )
        self.permissionSettingsOpener = permissionSettingsOpener ?? SystemPermissionSettingsOpener()
        self.microphoneAuthorizationProvider = microphoneAuthorizationProvider
        self.speechRecognitionAuthorizationProvider = speechRecognitionAuthorizationProvider
        self.audioInputDeviceService = AudioInputDeviceService(provider: audioInputDeviceProvider)
        self.now = now
        self.selectedMeetingID = meetings.first?.id
        self.selectedSourceID = sources.first?.id ?? selectedSourceID
        refreshMicrophoneAuthorizationStatus()
        refreshAppleSpeechAuthorizationStatus()
        loadTranscriptQuestionHistoryForSelectedMeeting(defaultStatus: "Ask a question about the selected transcript")
        refreshTranscriptReviewForSelectedMeeting()
        if runtimeInitializationError != nil {
            recordingState = .error
            recordingProcessingStatus = "Encrypted library could not be opened. Review the local key and library integrity."
        }
        if editRuntime == nil {
            self.transcriptEditStatus = "Encrypted transcript library unavailable"
            self.recoveredRecordingImportStatus = "Recovered recording import unavailable"
            self.localRecordingImportStatus = "Local recording import unavailable"
            self.libraryDeleteStatus = "Library delete unavailable"
            self.exportStatus = "Export unavailable"
            self.shareStatus = "Share unavailable"
            self.retentionCleanupStatus = "Retention review unavailable"
            self.privacyAuditExportStatus = "Privacy audit export unavailable"
        }
        Task { @MainActor [weak self] in
            await self?.refreshTranscriptionPrivacyPresentation()
        }
    }

    private func refreshTranscriptionPrivacyPresentation() async {
        await refreshLocalModelReadiness()
        let mode = await transcriptionPrivacyBoundary.mode()
        transcriptionPrivacyPresentation = TranscriptionPrivacyPresentation(
            mode: mode,
            providerAvailable: providerIsAvailable(for: mode)
        )
        await refreshTranscriptionSetupPresentation()
    }

    private func refreshTranscriptionSetupPresentation() async {
        let mode = await transcriptionPrivacyBoundary.mode()
        let provider = await resolvedTranscriptionProviderForNextSession()
        let permissionGranted = !appleSpeechAuthorizationStatus.localizedCaseInsensitiveContains("denied")
            && !appleSpeechAuthorizationStatus.localizedCaseInsensitiveContains("not been checked")
            && !appleSpeechAuthorizationStatus.localizedCaseInsensitiveContains("request")
        transcriptionSetupPresentation = TranscriptionSetupPresentation(
            mode: mode,
            provider: provider.descriptor,
            localeIdentifier: meetingContextForEditor.localeIdentifier,
            localModelStates: localModelReadinessStates,
            applePermissionGranted: permissionGranted
        )
    }

    func refreshTranscriptionModelReadiness() async {
        await refreshLocalModelReadiness()
        await refreshTranscriptionPrivacyPresentationWithoutReadinessQuery()
    }

    private func refreshLocalModelReadiness() async {
        localModelReadinessStates = await localModelReadinessProvider?.snapshot() ?? []
    }

    private func refreshTranscriptionPrivacyPresentationWithoutReadinessQuery() async {
        let mode = await transcriptionPrivacyBoundary.mode()
        transcriptionPrivacyPresentation = TranscriptionPrivacyPresentation(
            mode: mode,
            providerAvailable: providerIsAvailable(for: mode)
        )
        await refreshTranscriptionSetupPresentation()
    }

    private static func defaultLocalKeyProvider(libraryRoot: URL?) -> any SymmetricKeyProvider {
        FileBackedSymmetricKeyProvider(keyFileURL: defaultLocalKeyURL(libraryRoot: libraryRoot))
    }

    private static func defaultReleaseBlockerReportURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectoryPath: String = FileManager.default.currentDirectoryPath
    ) -> URL? {
        if let configured = environment["MEETINGVAULT_RELEASE_BLOCKER_REPORT"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            return URL(fileURLWithPath: configured)
        }

        let sourceTreeCandidate = URL(fileURLWithPath: currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("docs", isDirectory: true)
            .appendingPathComponent("evidence", isDirectory: true)
            .appendingPathComponent("release-blocker-doctor-2026-07-01.json")
        if FileManager.default.fileExists(atPath: sourceTreeCandidate.path) {
            return sourceTreeCandidate
        }

        return nil
    }

    private static func releaseBlockerStatusText(for summary: ReleaseBlockerSummary) -> String {
        if summary.status == "unavailable" {
            return summary.issues.first ?? "Release blocker report unavailable"
        }
        if summary.releaseCandidateReady {
            return "Release candidate blockers cleared"
        }
        let operatorSuffix = summary.operatorBlockers.isEmpty
            ? ""
            : "; \(summary.operatorBlockers.count) operator blocker\(summary.operatorBlockers.count == 1 ? "" : "s")"
        let approvalSuffix = summary.approvalRequiredActionCount == 0
            ? ""
            : "; \(summary.approvalRequiredActionCount) approval-gated"
        let localCommandSuffix = summary.localRunnableActionCount == 0
            ? ""
            : "; \(summary.localRunnableActionCount) local command\(summary.localRunnableActionCount == 1 ? "" : "s") ready"
        let prerequisiteSuffix = summary.prerequisiteBlockedActionCount == 0
            ? ""
            : "; \(summary.prerequisiteBlockedActionCount) waiting on prerequisites"
        return "\(summary.blockedGateCount) release-candidate gates blocked; \(summary.totalActionCount) clearance actions queued\(approvalSuffix)\(localCommandSuffix)\(prerequisiteSuffix)\(operatorSuffix)"
    }

    private static func defaultLocalKeyURL(libraryRoot: URL?) -> URL {
        if let libraryRoot {
            return libraryRoot
                .appendingPathComponent(".meetingvault", isDirectory: true)
                .appendingPathComponent("local-master-key.bin")
        }

        let supportRoot = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)

        return supportRoot
            .appendingPathComponent("MeetingVault", isDirectory: true)
            .appendingPathComponent("Secrets", isDirectory: true)
            .appendingPathComponent("local-master-key.bin")
    }

    private static func fallbackLibraryRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("MeetingVault", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
    }

    private static func makeLocalTranscriptionProvider(
        mode: MeetingVaultLiveTranscriptionRuntimeMode,
        privacyBoundary: TranscriptionPrivacyBoundary,
        localModelRuntime: (any LocalModelRuntimeSessionProviding)?
    ) -> any LocalTranscriptionProviding {
        switch mode {
        case .local:
            if let localModelRuntime {
                FluidAudioLocalTranscriptionProvider(runtime: localModelRuntime)
            } else {
                UnavailableLocalTranscriptionProvider(
                    reason: "Install the verified local models in Settings"
                )
            }
        case .demo:
            LegacyLiveTranscriptionLocalAdapter(provider: DemoLiveTranscriptionProvider())
        case .appleSpeech:
            AppleSpeechFrameTranscriptionProvider(privacyBoundary: privacyBoundary)
        }
    }

    private static func makeFinalTranscriptionEngine(
        mode: MeetingVaultFinalTranscriptionRuntimeMode,
        privacyBoundary: TranscriptionPrivacyBoundary,
        localTranscriptionProvider: any LocalTranscriptionProviding
    ) -> any TranscriptionEngine {
        switch mode {
        case .local:
            FrameFedFinalTranscriptionEngine(provider: localTranscriptionProvider)
        case .demo:
            DemoTranscriptionEngine()
        case .appleSpeech:
            AppleSpeechFinalTranscriptionEngine(privacyBoundary: privacyBoundary)
        case .speechAnalyzer:
            SpeechAnalyzerFinalTranscriptionEngine()
        }
    }

    private static func makeMeetingIntelligenceProvider(
        mode: MeetingVaultIntelligenceRuntimeMode
    ) -> any MeetingIntelligenceProvider {
        switch mode {
        case .demo:
            DemoMeetingIntelligenceProvider()
        case .foundationModels:
            FoundationModelsMeetingIntelligenceProvider()
        }
    }

    private static func makeTranscriptQuestionAnsweringProvider(
        mode: MeetingVaultTranscriptQuestionRuntimeMode
    ) -> (any TranscriptQuestionAnsweringProviding)? {
        switch mode {
        case .deterministic:
            nil
        case .foundationModels:
            FoundationModelsTranscriptQuestionAnsweringProvider()
        }
    }

    var selectedMeeting: MeetingRecord? {
        meetings.first { $0.id == selectedMeetingID } ?? meetings.first
    }

    var selectedSource: CaptureSource? {
        sources.first { $0.id == selectedSourceID }
    }

    var transcriptEditMeetingTitle: String {
        transcriptEditMeetingsByID[transcriptEditDraft.meetingID]?.title
            ?? selectedMeeting?.title
            ?? "Selected meeting"
    }

    var preflightResult: RecordingPreflightResult {
        let latest = latestPreflightResult
        return RecordingPreflightResult(
            canRecord: latest?.canRecord ?? false,
            issues: latest?.issues ?? [.audioPermissionMissing, .microphonePermissionMissing, .speechPermissionMissing],
            storageEstimate: latest?.storageEstimate
        )
    }

    var permissionRecoveryActions: [PermissionRecoveryAction] {
        latestPreflightResult?.recoveryActions ?? []
    }

    var hasPermissionRecoveryActions: Bool {
        !permissionRecoveryActions.isEmpty
    }

    var hasStorageRecoveryAction: Bool {
        latestPreflightResult?.issues.contains(.diskSpaceLow) ?? false
    }

    var recordingReadinessTitle: String {
        guard recordingState == .permissionNeeded else {
            return recordingState.displayTitle
        }
        guard let result = latestPreflightResult else {
            return "Check Needed"
        }
        return Self.readinessTitle(for: result.issues)
    }

    var recordingReadinessDetail: String {
        guard let result = latestPreflightResult else {
            return "MeetingVault checks recording readiness automatically before Start."
        }
        guard !result.canRecord else {
            return "Ready to record with the selected input."
        }
        return Self.readinessDetail(for: result)
    }

    var selectedAudioInputDevice: AudioInputDevice? {
        audioInputDevices.first { $0.id == selectedAudioInputDeviceID }
            ?? audioInputDevices.first
    }

    func runPreflight() {
        Task {
            await refreshPermissions()
        }
    }

    @discardableResult
    func refreshPermissionsIfNeeded() async -> PermissionPreflightResult {
        if let latestPreflightResult {
            return latestPreflightResult
        }
        return await refreshPermissions()
    }

    func openPermissionRecoverySettings(kind: PermissionKind) {
        guard let action = permissionRecoveryActions.first(where: { $0.kind == kind }) else {
            permissionRecoveryStatus = "Refresh readiness to update available permission recovery actions"
            logger.warning("Permission recovery requested without available action kind=\(kind.rawValue, privacy: .public)")
            return
        }

        if permissionSettingsOpener.openSettings(for: action) {
            permissionRecoveryStatus = "Opened System Settings for \(action.title). Return here; MeetingVault refreshes readiness automatically."
            logger.info("Permission recovery settings opened kind=\(kind.rawValue, privacy: .public)")
        } else {
            permissionRecoveryStatus = "Could not open System Settings for \(action.title)"
            logger.error("Permission recovery settings failed kind=\(kind.rawValue, privacy: .public)")
        }
    }

    func refreshMicrophoneAuthorizationStatus() {
        let state = microphoneAuthorizationProvider.currentAuthorizationStatus()
        microphoneAuthorizationState = state
        microphoneAuthorizationStatus = Self.microphoneStatusText(for: state)
    }

    func requestMicrophoneAuthorizationOnce() async {
        microphoneAuthorizationStatus = "Requesting Microphone permission"
        let state = await microphoneAuthorizationProvider.requestAuthorizationStatus()
        microphoneAuthorizationState = state
        microphoneAuthorizationStatus = Self.microphoneStatusText(for: state)
        _ = await refreshPermissions()
        logger.info("Microphone authorization request finished state=\(state.rawValue, privacy: .public)")
    }

    func refreshAppleSpeechAuthorizationStatus() {
        let state = speechRecognitionAuthorizationProvider.currentAuthorizationState()
        appleSpeechAuthorizationState = state
        appleSpeechAuthorizationStatus = appleSpeechStatusText(for: state)
    }

    func requestAppleSpeechAuthorizationOnce() async {
        appleSpeechAuthorizationStatus = "Requesting Speech Recognition permission"
        let state = await speechRecognitionAuthorizationProvider.requestAuthorizationState()
        appleSpeechAuthorizationState = state
        appleSpeechAuthorizationStatus = appleSpeechStatusText(for: state)
        _ = await refreshPermissions()
        logger.info("Speech Recognition authorization request finished state=\(state.rawValue, privacy: .public)")
    }

    private static func microphoneStatusText(for state: PermissionAuthorizationStatus) -> String {
        switch state {
        case .authorized:
            "Microphone is authorized"
        case .denied:
            "Microphone was denied for MeetingVault"
        case .restricted:
            "Microphone is restricted by system policy"
        case .notDetermined:
            "Microphone has not been requested for MeetingVault"
        case .unknown:
            "Microphone permission status is unknown"
        }
    }

    func refreshReleaseBlockerSummary() {
        releaseBlockerSummary = releaseBlockerSummaryService.loadReport(at: releaseBlockerReportURL)
        releaseBlockerStatus = Self.releaseBlockerStatusText(for: releaseBlockerSummary)
        logger.info("Release blocker report refreshed status=\(self.releaseBlockerSummary.releaseBlockerStatus, privacy: .public)")
    }

    private func appleSpeechStatusText(for state: SpeechRecognitionAuthorizationState) -> String {
        switch state {
        case .authorized:
            "Speech Recognition is authorized"
        case .denied:
            "Speech Recognition was denied. Open System Settings to allow it."
        case .restricted:
            "Speech Recognition is restricted on this Mac"
        case .notDetermined:
            "Speech Recognition has not been requested for MeetingVault"
        case .unknown:
            "Speech Recognition authorization is unknown"
        }
    }

    func reviewStoragePressure() {
        guard hasStorageRecoveryAction else {
            storageRecoveryStatus = "Refresh readiness to update storage recovery actions"
            logger.warning("Storage recovery requested without low-storage preflight issue")
            return
        }

        do {
            try refreshRetentionCleanupPlan()
            let candidateCount = retentionCleanupPlan?.candidates.count ?? 0
            if candidateCount > 0 {
                storageRecoveryStatus = "Opened Diagnostics Retention Review with \(candidateCount) expired recording \(candidateCount == 1 ? "bundle" : "bundles") ready for review."
            } else {
                storageRecoveryStatus = "Opened Diagnostics Retention Review. No expired MeetingVault recordings are available; clear other local files, then retry Start."
            }
            logger.info("Storage recovery opened Diagnostics candidateCount=\(candidateCount, privacy: .public)")
        } catch {
            storageRecoveryStatus = "Opened Diagnostics, but retention review is unavailable"
            logger.error("Storage recovery retention review failed")
        }
        requestHealthRecoveryPresentation()
    }

    func startRecordingIntent() {
        guard canStartRecording else {
            recordingProcessingStatus = "A recording is already starting or active"
            logger.warning("Recording start ignored because another recording is starting or active")
            return
        }
        recordingStartInFlight = true
        let meetingContextSnapshot = meetingContextDraft
        Task {
            defer { recordingStartInFlight = false }
            let activityLease: TranscriptionRecordingActivityLease
            do {
                activityLease = try await transcriptionActivityGate.beginRecordingActivity()
            } catch {
                recordingProcessingStatus = "Recording start paused while transcription privacy changes"
                logger.info("Recording start rejected by transcription privacy activity gate")
                return
            }
            var activityLeaseTransferred = false
            defer {
                if !activityLeaseTransferred {
                    Task { await activityLease.release() }
                }
            }
            await refreshAudioInputDevices()
            let result = await preflightForRecordingStart()
            if result.canRecord {
                guard let recordingProcessingService else {
                    recordingState = .error
                    recordingProcessingStatus = "Recording processing unavailable"
                    logger.error("Recording start failed: processing service unavailable")
                    return
                }
                let source = selectedSource
                let inputDevice = selectedAudioInputDevice
                let request = RecordingProcessingRequest(
                    meetingID: UUID(),
                    title: "Recorded \(source?.displayName ?? "meeting")",
                    startedAt: now(),
                    sourceID: source?.id ?? selectedSourceID,
                    sourceName: source?.displayName ?? selectedSourceID,
                    includeMicrophone: true,
                    microphoneDeviceID: inputDevice?.id,
                    microphoneDeviceName: inputDevice?.displayName,
                    context: meetingContextSnapshot,
                    consentStatus: selectedMeeting?.consentStatus ?? .disclosed
                )
                do {
                    resetRecordingLevelSession()
                    recordingPreviewDropCount = 0
                    recordingPreviewDropStatus = "No live preview frames have been skipped"
                    recordingPreviewDropGeneration = UUID()
                    let levelMonitor = RecordingLevelMonitor(onSnapshot: recordingLevelHandler())
                    let transcriptionCoordinator = await prepareTranscriptionCoordinator(for: request)
                    var frameConsumers: [any CaptureFrameConsumer] = [levelMonitor]
                    if let transcriptionCoordinator {
                        frameConsumers.append(transcriptionCoordinator)
                    }
                    activeTranscriptionCoordinator = transcriptionCoordinator
                    let session = try await recordingProcessingService.beginRecording(
                        request,
                        frameConsumers: frameConsumers,
                        previewDropHandler: recordingPreviewDropHandler()
                    )
                    activeRecordingSession = session
                    recordingActivityLease = activityLease
                    activityLeaseTransferred = true
                    activeRecordingPresentation = ActiveRecordingPresentation(request: session.request)
                    bookmarkSessionGeneration = UUID()
                    bookmarkRequestSequence = 0
                    pendingBookmarkMutations.removeAll()
                    bookmarkMutationTail = nil
                    lastMarkedMoment = nil
                    recordingBookmarkStatus = "Mark Moment is available while recording"
                    activeMeetingContext = session.request.context
                    if meetingContextDraft == meetingContextSnapshot {
                        meetingContextDraft = MeetingContext()
                        meetingContextReuseStatus = "Context saved for this recording; the next recording starts empty"
                    } else {
                        meetingContextReuseStatus = "Context saved for this recording; newer draft changes were preserved"
                    }
                    activeLiveTranscriptionContext = liveTranscriptionContext(for: session.request)
                    recordingState = .recording
                    observeActiveCaptureFailure(for: session)
                } catch {
                    if let coordinator = activeTranscriptionCoordinator {
                        await persistPreviewEvidenceBestEffort(
                            meetingID: request.meetingID,
                            coordinator: coordinator
                        )
                        await coordinator.cancel()
                        activeTranscriptionCoordinator = nil
                    }
                    recordingState = .error
                    recordingProcessingStatus = "Recording start failed: \(Self.recordingErrorMessage(error))"
                    logger.error("Recording start failed")
                    return
                }
                recordingProcessingProgress = RecordingProcessingProgress(
                    stage: .recordingAudio,
                    fractionCompleted: 0.20,
                    message: inputDevice.map { "Writing encrypted audio chunks with \($0.displayName)" }
                        ?? "Writing encrypted audio chunks"
                )
                recordingProcessingStatus = recordingProcessingProgress?.message ?? "Writing encrypted audio chunks"
                if let selectedAudioInputDevice {
                    audioInputStatus = "Recording with \(selectedAudioInputDevice.displayName)"
                }
                startLiveTranscriptPreviewLoop()
                logger.info("Recording intent accepted source=\(self.selectedSource?.displayName ?? "unknown", privacy: .public)")
            } else {
                recordingState = .permissionNeeded
                permissionRecoveryStatus = Self.readinessDetail(for: result)
                let issues = result.issues.map(\.rawValue).joined(separator: ",")
                logger.warning("Recording blocked issues=\(issues, privacy: .public)")
            }
        }
    }

    func stopRecordingIntent() {
        guard let session = activeRecordingSession, canStopRecording else {
            recordingProcessingStatus = "No active recording to stop"
            logger.warning("Recording stop ignored because no active recording exists")
            return
        }
        // Stop capture at the interaction boundary. Durable bookmark writes may
        // still need to settle before metadata finalization, but must never keep
        // the microphone or system-audio producer running after Stop is pressed.
        session.requestStop()
        recordingState = .processing
        recordingProcessingCancellation.reset()
        liveTranscriptionStatus = "Finalizing local live transcript before the authoritative final pass"
        logger.info("Recording stop requested; processing started")
        let acceptedBookmarkOperations = pendingBookmarkMutations.values
            .filter {
                $0.sessionGeneration == bookmarkSessionGeneration
                    && $0.meetingID == session.request.meetingID
            }
            .sorted { $0.sequence < $1.sequence }
        Task {
            defer {
                if recordingCancellationInFlight {
                    recordingProcessingCancellation.reset()
                    recordingCancellationInFlight = false
                }
            }
            do {
                for operation in acceptedBookmarkOperations {
                    if case .failed = await operation.outcome() {
                        logger.error("Accepted recording bookmark failed before stop finalization")
                    }
                }
                _ = try await finishActiveRecordingSession(session)
            } catch RecordingProcessingError.cancelled {
                recordingState = .ready
                logger.info("Recording processing cancelled")
            } catch let error as RecordingProcessingError {
                switch error {
                case let .cancelled(stage):
                    recordingState = .ready
                    recordingProcessingProgress = RecordingProcessingProgress(
                        stage: stage,
                        fractionCompleted: recordingProcessingProgress?.fractionCompleted ?? 0,
                        message: "Processing cancelled"
                    )
                    recordingProcessingStatus = "Processing cancelled"
                    recordingProcessingFailureStage = nil
                case let .failed(stage, message):
                    applyRecordingProcessingFailure(stage: stage, message: message)
                }
                logger.error("Recording processing failed: \(Self.recordingErrorMessage(error), privacy: .public)")
            } catch {
                recordingState = .error
                recordingProcessingStatus = "Recording processing failed: \(Self.recordingErrorMessage(error))"
                logger.error("Recording processing failed: \(Self.recordingErrorMessage(error), privacy: .public)")
            }
        }
    }

    @discardableResult
    func markMoment(
        category: MeetingBookmarkCategory? = nil,
        note: String? = nil
    ) async -> Bool {
        guard let operation = acceptMarkMoment(category: category, note: note) else {
            return false
        }
        if case .saved = await operation.outcome() {
            return true
        }
        return false
    }

    @discardableResult
    func acceptMarkMoment(
        category: MeetingBookmarkCategory? = nil,
        note: String? = nil
    ) -> RecordingBookmarkOperation? {
        guard recordingState == .recording,
              let presentation = activeRecordingPresentation,
              let manager = recordingSessionMetadataManager else {
            recordingBookmarkStatus = "Mark Moment is available only while recording"
            return nil
        }
        let (sequence, overflow) = bookmarkRequestSequence.addingReportingOverflow(1)
        guard !overflow else {
            recordingBookmarkStatus = "Moment could not be marked"
            return nil
        }
        bookmarkRequestSequence = sequence
        let precedingMutation = bookmarkMutationTail
        let generation = bookmarkSessionGeneration
        let operationID = UUID()
        let timestamp = max(0, now().timeIntervalSince(presentation.startedAt))
        let task = Task {
            if let precedingMutation {
                _ = try? await precedingMutation.value
            }
            return try await manager.markMoment(
                meetingID: presentation.meetingID,
                timestamp: timestamp,
                category: category,
                note: note
            )
        }
        let operation = RecordingBookmarkOperation(
            id: operationID,
            meetingID: presentation.meetingID,
            sessionGeneration: generation,
            sequence: sequence,
            task: task
        )
        pendingBookmarkMutations[operationID] = operation
        bookmarkMutationTail = task
        recordingBookmarkStatus = "Saving marked moment"
        Task { @MainActor [weak self] in
            let outcome = await operation.outcome()
            guard let self,
                  self.bookmarkSessionGeneration == operation.sessionGeneration,
                  self.activeRecordingPresentation?.meetingID == operation.meetingID,
                  self.pendingBookmarkMutations.removeValue(forKey: operation.id) != nil
            else { return }
            switch outcome {
            case let .saved(bookmark):
                self.lastMarkedMoment = bookmark
                self.recordingBookmarkStatus = self.pendingBookmarkMutations.isEmpty
                    ? "Moment marked"
                    : "Moment marked; saving another marked moment"
                self.announceBookmarkConfirmation()
            case .failed:
                self.recordingBookmarkStatus = "Moment could not be marked"
                self.logger.error("Recording bookmark could not be saved")
            }
        }
        return operation
    }

    @discardableResult
    func markMomentIntent() -> RecordingBookmarkOperation? {
        acceptMarkMoment()
    }

    private func announceBookmarkConfirmation() {
        guard let application = NSApp else { return }
        NSAccessibility.post(
            element: application,
            notification: .announcementRequested,
            userInfo: [
                .announcement: "Moment marked",
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }

    func recordingPreviewDropHandler() -> @Sendable (Int) -> Void {
        let generation = recordingPreviewDropGeneration
        return { [weak self] count in
            Task { @MainActor [weak self] in
                guard let self,
                      generation == self.recordingPreviewDropGeneration,
                      count > self.recordingPreviewDropCount
                else { return }
                self.recordingPreviewDropCount = count
                self.recordingPreviewDropStatus = "Live preview skipped \(count) replaceable frames; encrypted recording continues."
                self.logger.info("Recording preview drops cumulativeCount=\(count, privacy: .public)")
            }
        }
    }

    func resetRecordingLevelSession() {
        recordingLevelGeneration = UUID()
        recordingLevelSnapshot = RecordingLevelSnapshot()
        liveInputLevel = 0
    }

    func recordingLevelHandler() -> @Sendable (RecordingLevelSnapshot) async -> Void {
        let generation = recordingLevelGeneration
        return { [weak self] snapshot in
            await self?.publishRecordingLevel(snapshot, generation: generation)
        }
    }

    private func publishRecordingLevel(
        _ snapshot: RecordingLevelSnapshot,
        generation: UUID
    ) {
        guard generation == recordingLevelGeneration,
              recordingState == .recording
        else { return }
        recordingLevelSnapshot = snapshot
        liveInputLevel = snapshot.microphone
    }

    var filteredPrivacyAuditRows: [PrivacyAuditReviewRow] {
        PrivacyAuditReviewExportService()
            .filteredRows(in: privacyAuditReview, actionFilter: privacyAuditActionFilter)
    }

    func cancelRecordingProcessing() async {
        if recordingCancellationInFlight {
            recordingProcessingStatus = "Cancellation requested"
            logger.info("Recording processing cancellation already requested")
            return
        }
        guard recordingState == .processing, activeRecordingSession != nil else {
            recordingProcessingStatus = "No recording processing to cancel"
            logger.warning("Recording processing cancellation ignored because processing is not active")
            return
        }
        recordingProcessingCancellation.request()
        recordingCancellationInFlight = true
        if let session = activeRecordingSession,
           let coordinator = activeTranscriptionCoordinator {
            await persistPreviewEvidenceBestEffort(
                meetingID: session.request.meetingID,
                coordinator: coordinator
            )
        }
        cleanupActiveRecordingSession(cancelCapture: true)
        stopLiveTranscriptPreviewLoop(finalStatus: "Processing cancellation requested")
        recordingProcessingStatus = "Cancellation requested"
        logger.info("Recording processing cancellation requested")
    }

    func refreshRecoveredRecordings() {
        guard let recordingRecoveryService else {
            recoveredRecordings = []
            return
        }

        do {
            recoveredRecordings = try recordingRecoveryService.scanRecoverableBundles()
        } catch {
            recoveredRecordings = []
            logger.error("Recording recovery scan failed")
        }
    }

    func refreshRetentionCleanupPlan(now: Date = Date()) throws {
        guard let retentionCleanupService else {
            retentionCleanupStatus = "Retention review unavailable"
            throw MeetingVaultRetentionRuntimeError.unavailable
        }

        do {
            let policy = RetentionPolicy(retentionDays: retentionDays)
            let plan = try retentionCleanupService.planCleanup(policy: policy, now: now)
            retentionCleanupPlan = plan
            retentionCleanupStatus = retentionPlanStatus(candidateCount: plan.candidates.count)
            logger.info("Retention cleanup plan refreshed candidateCount=\(plan.candidates.count, privacy: .public) retentionDays=\(policy.retentionDays, privacy: .public)")
        } catch RetentionCleanupError.invalidRetentionDays {
            retentionCleanupStatus = "Retention days must be greater than zero"
            throw MeetingVaultRetentionRuntimeError.invalidPolicy
        } catch {
            retentionCleanupStatus = "Retention review failed"
            logger.error("Retention cleanup plan failed")
            throw error
        }
    }

    @discardableResult
    func applyRetentionCleanup(userConfirmed: Bool) throws -> RetentionCleanupResult {
        guard userConfirmed else {
            retentionCleanupStatus = "Confirm retention cleanup before deleting expired recordings"
            throw MeetingVaultRetentionRuntimeError.confirmationRequired
        }
        guard let retentionCleanupService else {
            retentionCleanupStatus = "Retention review unavailable"
            throw MeetingVaultRetentionRuntimeError.unavailable
        }
        guard let plan = retentionCleanupPlan else {
            retentionCleanupStatus = "Review expired recordings before cleanup"
            throw MeetingVaultRetentionRuntimeError.noPlan
        }

        do {
            let result = try retentionCleanupService.apply(plan)
            let deleted = Set(result.deletedMeetingIDs)
            meetings.removeAll { deleted.contains($0.id) }
            for id in deleted {
                transcriptEditMeetingsByID.removeValue(forKey: id)
                transcriptEditSessionCache.removeValue(forKey: id)
                transcriptQuestionHistoryCache.removeValue(forKey: id)
            }
            if let selectedMeetingID, deleted.contains(selectedMeetingID) {
                self.selectedMeetingID = meetings.first?.id
            }
            retentionCleanupPlan = RetentionCleanupPlan(
                policy: plan.policy,
                generatedAt: Date(),
                candidates: []
            )
            for candidate in plan.candidates where deleted.contains(candidate.meetingID) {
                appendRetentionAuditRow(candidate: candidate, policy: plan.policy)
            }
            retentionCleanupStatus = "Deleted \(result.deletedMeetingIDs.count) expired recording \(result.deletedMeetingIDs.count == 1 ? "bundle" : "bundles")"
            logger.info("Retention cleanup applied deletedCount=\(result.deletedMeetingIDs.count, privacy: .public)")
            return result
        } catch {
            retentionCleanupStatus = "Retention cleanup failed"
            logger.error("Retention cleanup failed")
            throw error
        }
    }

    @discardableResult
    func deleteMeetingFromLibrary(meetingID: UUID) throws -> MeetingDeleteResult {
        guard let meetingDeleteService else {
            libraryDeleteStatus = "Library delete unavailable"
            throw MeetingVaultLibraryDeleteRuntimeError.unavailable
        }
        guard meetings.contains(where: { $0.id == meetingID }) || transcriptEditMeetingsByID[meetingID] != nil else {
            libraryDeleteStatus = "Recording is no longer in the library"
            throw MeetingVaultLibraryDeleteRuntimeError.noSelectedMeeting
        }

        do {
            let result = try meetingDeleteService.deleteMeeting(meetingID: meetingID, reason: .userRequested)
            removeMeetingFromWorkspace(meetingID: meetingID)
            appendManualDeleteAuditRow(meetingID: meetingID, reason: result.reason)
            libraryDeleteStatus = "Deleted recording from local library"
            logger.info("Meeting deleted from library meetingID=\(meetingID.uuidString, privacy: .public)")
            return result
        } catch MeetingBundleStoreError.bundleNotFound {
            removeMeetingFromWorkspace(meetingID: meetingID)
            libraryDeleteStatus = "Removed stale library row; encrypted bundle was already gone"
            throw MeetingVaultLibraryDeleteRuntimeError.bundleMissing
        } catch {
            libraryDeleteStatus = "Could not delete recording"
            logger.error("Meeting delete failed meetingID=\(meetingID.uuidString, privacy: .public)")
            throw error
        }
    }

    @discardableResult
    func deleteSelectedMeetingFromLibrary() throws -> MeetingDeleteResult {
        guard let meetingID = selectedMeeting?.id else {
            libraryDeleteStatus = "Select a recording before deleting"
            throw MeetingVaultLibraryDeleteRuntimeError.noSelectedMeeting
        }
        return try deleteMeetingFromLibrary(meetingID: meetingID)
    }

    @discardableResult
    func retryRecordingProcessing() async throws -> RecordingProcessingResult {
        guard let intent = lastRecordingProcessingIntent else {
            recordingState = .error
            recordingProcessingStatus = "No failed processing job to retry"
            throw RecordingProcessingRuntimeError.noRetryAvailable
        }
        return try await processStoppedRecordingForSelectedSource(
            meetingID: UUID(),
            title: intent.title,
            startedAt: intent.startedAt
        )
    }

    var hasRecordingCaptureRecoveryActions: Bool {
        recordingProcessingFailureStage == .recordingAudio
    }

    func refreshInputsForRecordingRecovery() async {
        await refreshAudioInputDevices()
        if audioInputDevices.isEmpty {
            recordingProcessingRecoveryStatus = "No inputs detected. Connect AirPods, a USB microphone, or another input, then detect inputs again."
        } else {
            recordingProcessingRecoveryStatus = "Detected \(audioInputDevices.count) input \(audioInputDevices.count == 1 ? "device" : "devices"). Choose the intended input, then retry recording."
        }
        logger.info("Recording capture recovery refreshed inputs count=\(self.audioInputDevices.count, privacy: .public)")
    }

    func openRecordingRecoveryReview() {
        refreshRecoveredRecordings()
        showWorkspace(.recover)
        let count = recoveredRecordings.count
        if count == 0 {
            recordingProcessingRecoveryStatus = "Opened Health & Recovery. No incomplete recording bundles are currently recoverable."
        } else {
            recordingProcessingRecoveryStatus = "Opened Health & Recovery with \(count) incomplete recording \(count == 1 ? "bundle" : "bundles") ready for review."
        }
        logger.info("Recording capture recovery opened review count=\(count, privacy: .public)")
    }

    func handleSystemSleepInterruption() async {
        guard recordingState == .recording else {
            return
        }

        activeRecordingSession?.requestStop()
        if let session = activeRecordingSession,
           let coordinator = activeTranscriptionCoordinator {
            await persistPreviewEvidenceBestEffort(
                meetingID: session.request.meetingID,
                coordinator: coordinator
            )
        }
        cleanupActiveRecordingSession(cancelCapture: true)
        stopLiveTranscriptPreviewLoop(finalStatus: "Live transcription stopped because macOS is sleeping")
        recordingState = .error
        recordingProcessingFailureStage = .recordingAudio
        recordingProcessingProgress = RecordingProcessingProgress(
            stage: .recordingAudio,
            fractionCompleted: recordingProcessingProgress?.fractionCompleted ?? 0.20,
            message: "Recording interrupted by system sleep"
        )
        recordingProcessingStatus = "Capture interrupted: macOS is going to sleep. Any checkpointed encrypted audio is preserved for recovery."
        recordingProcessingRecoveryStatus = "Recording stopped before sleep. On wake, detect inputs or choose another source, then open Health & Recovery to review any checkpointed audio."
        refreshRecoveredRecordings()
        showWorkspace(.recover)
        logger.warning("Active recording interrupted by system sleep")
    }

    func applyTranscriptPromptPreset(_ preset: TranscriptPromptPreset) {
        transcriptAskPrompt = preset.prompt
        transcriptAskStatus = "Prompt preset selected: \(preset.title)"
    }

    func askSelectedTranscriptFromLibrary() {
        let canRouteToAgent = transcriptAgentCanAsk
        askSelectedTranscript()
        if canRouteToAgent {
            showWorkspace(.understand)
        }
    }

    func refreshAudioInputDevices() async {
        let devices = await audioInputDeviceService.refresh()
        audioInputDevices = devices

        guard !devices.isEmpty else {
            selectedAudioInputDeviceID = nil
            audioInputSelectionIsManual = false
            audioInputStatus = "No audio input devices detected"
            return
        }

        if audioInputSelectionIsManual,
           let selectedAudioInputDeviceID,
           devices.contains(where: { $0.id == selectedAudioInputDeviceID }) {
            audioInputStatus = "Using manually selected \(selectedAudioInputDevice?.displayName ?? "input")"
            return
        }

        audioInputSelectionIsManual = false
        selectedAudioInputDeviceID = devices.first(where: \.isDefault)?.id ?? devices.first?.id
        audioInputStatus = "Auto-selected \(selectedAudioInputDevice?.displayName ?? "available input") from \(devices.count) detected input device(s)"
    }

    func monitorAudioInputDevices(refreshIntervalNanoseconds: UInt64 = 5_000_000_000) async {
        await refreshAudioInputDevices()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: refreshIntervalNanoseconds)
            guard !Task.isCancelled else { return }
            await refreshAudioInputDevices()
        }
    }

    func selectAudioInputDevice(id: String?) {
        guard let id, audioInputDevices.contains(where: { $0.id == id }) else {
            selectedAudioInputDeviceID = audioInputDevices.first(where: \.isDefault)?.id ?? audioInputDevices.first?.id
            audioInputSelectionIsManual = false
            audioInputStatus = selectedAudioInputDevice.map { "Auto-selected \($0.displayName)" } ?? "Audio input detection ready"
            return
        }
        selectedAudioInputDeviceID = id
        audioInputSelectionIsManual = true
        audioInputStatus = "Using manually selected \(selectedAudioInputDevice?.displayName ?? "selected input")"
    }

    func refreshSpeechAnalyzerEvaluation(localeIdentifier: String = Locale.current.identifier) async {
        do {
            let report = try await speechAnalyzerEvaluationService.evaluate(localeIdentifier: localeIdentifier)
            speechAnalyzerEvaluationReport = report
            speechAnalyzerEvaluationStatus = speechAnalyzerStatusText(report)
            logger.info("SpeechAnalyzer evaluation status=\(report.status.rawValue, privacy: .public) locale=\(report.resolvedLocaleIdentifier ?? report.requestedLocaleIdentifier, privacy: .public) assetStatus=\(report.assetStatus ?? "none", privacy: .public)")
        } catch {
            speechAnalyzerEvaluationReport = SpeechAnalyzerEvaluationReport(
                generatedAt: Date(),
                requestedLocaleIdentifier: localeIdentifier,
                resolvedLocaleIdentifier: nil,
                sdkAvailable: false,
                transcriberAvailable: false,
                assetStatus: nil,
                compatibleAudioFormatDescription: nil,
                status: .failed,
                notes: ["SpeechAnalyzer evaluation failed: \(error.localizedDescription)"]
            )
            speechAnalyzerEvaluationStatus = "SpeechAnalyzer evaluation failed"
            logger.error("SpeechAnalyzer evaluation failed")
        }
    }

    func prepareSpeechAnalyzerAssets(localeIdentifier: String = Locale.current.identifier) async {
        speechAnalyzerEvaluationStatus = "Preparing SpeechAnalyzer assets"
        do {
            let report = try await speechAnalyzerEvaluationService.prepareAssets(localeIdentifier: localeIdentifier)
            speechAnalyzerEvaluationReport = report
            speechAnalyzerEvaluationStatus = speechAnalyzerStatusText(report)
            logger.info("SpeechAnalyzer asset preparation status=\(report.status.rawValue, privacy: .public) locale=\(report.resolvedLocaleIdentifier ?? report.requestedLocaleIdentifier, privacy: .public) assetStatus=\(report.assetStatus ?? "none", privacy: .public)")
        } catch {
            speechAnalyzerEvaluationReport = SpeechAnalyzerEvaluationReport(
                generatedAt: Date(),
                requestedLocaleIdentifier: localeIdentifier,
                resolvedLocaleIdentifier: nil,
                sdkAvailable: false,
                transcriberAvailable: false,
                assetStatus: nil,
                compatibleAudioFormatDescription: nil,
                status: .failed,
                notes: ["SpeechAnalyzer asset preparation failed: \(error.localizedDescription)"]
            )
            speechAnalyzerEvaluationStatus = "SpeechAnalyzer asset preparation failed"
            logger.error("SpeechAnalyzer asset preparation failed")
        }
    }

    private func speechAnalyzerStatusText(_ report: SpeechAnalyzerEvaluationReport) -> String {
        let locale = report.resolvedLocaleIdentifier ?? report.requestedLocaleIdentifier
        switch report.status {
        case .available:
            return "SpeechAnalyzer available for \(locale); real non-private audio smoke still required"
        case .assetsNeeded:
            return "SpeechAnalyzer supported for \(locale), but speech assets are not proven installed"
        case .unsupported:
            return "SpeechAnalyzer unsupported for \(locale)"
        case .failed:
            return "SpeechAnalyzer evaluation failed"
        case .notEvaluated:
            return "SpeechAnalyzer evaluation ready"
        }
    }

    func transcriptDraftSegment(id: UUID) -> TranscriptEditDraftSegment? {
        transcriptEditDraft.segments.first { $0.id == id }
    }

    func updateTranscriptDraftText(id: UUID, text: String) {
        let speakerName = transcriptDraftSegment(id: id)?.editedSpeakerName
        updateTranscriptDraftSegment(id: id, speakerName: speakerName, text: text)
    }

    func updateTranscriptDraftSpeaker(id: UUID, speakerName: String) {
        let text = transcriptDraftSegment(id: id)?.editedText ?? ""
        updateTranscriptDraftSegment(id: id, speakerName: speakerName, text: text)
    }

    func revertTranscriptDraftSegment(id: UUID) {
        do {
            try transcriptEditDraft.revertSegment(id: id)
            transcriptRestoreNeedsConfirmation = false
            refreshTranscriptEditStatus(defaultStatus: "Segment reverted")
            cacheCurrentTranscriptEditSession(for: transcriptEditDraft.meetingID)
        } catch {
            transcriptEditStatus = "Segment unavailable"
            logger.error("Transcript draft segment revert failed")
        }
    }

    func revertTranscriptDraft() {
        transcriptEditDraft.revertAll()
        transcriptRestoreNeedsConfirmation = false
        cacheCurrentTranscriptEditSession(for: transcriptEditDraft.meetingID)
        transcriptEditStatus = "Draft reverted"
        logger.info("Transcript draft reverted")
    }

    @discardableResult
    func restoreTranscriptDraftFromSaved(userConfirmed: Bool) throws -> TranscriptEditSession {
        if transcriptEditDraft.hasChanges && !userConfirmed {
            transcriptRestoreNeedsConfirmation = true
            transcriptEditStatus = "Confirm restore before discarding unsaved transcript edits"
            throw MeetingVaultTranscriptRestoreRuntimeError.confirmationRequired
        }

        guard let transcriptEditSessionService else {
            transcriptEditStatus = "Editor persistence unavailable"
            throw MeetingVaultTranscriptRestoreRuntimeError.unavailable
        }
        guard let meeting = transcriptEditMeetingsByID[transcriptEditDraft.meetingID] else {
            transcriptEditStatus = "Transcript unavailable for selected meeting"
            throw MeetingVaultTranscriptRestoreRuntimeError.noSelectedMeeting
        }

        do {
            let session = try transcriptEditSessionService.loadSession(meeting: meeting)
            transcriptEditDraft = session.draft
            transcriptEditHistory = session.history
            transcriptEditSessionCache[meeting.id] = session
            transcriptRestoreNeedsConfirmation = false
            resetTranscriptAskResponse(status: "Visible transcript restored; ask again for an updated answer")
            transcriptEditStatus = session.history.latestVersion == 0
                ? "Restored original transcript"
                : "Restored latest saved transcript version \(session.history.latestVersion)"
            logger.info("Transcript draft restored meetingID=\(meeting.id.uuidString, privacy: .public) version=\(session.history.latestVersion, privacy: .public)")
            return session
        } catch {
            transcriptEditStatus = "Transcript restore failed"
            logger.error("Transcript draft restore failed")
            throw error
        }
    }

    @discardableResult
    func saveTranscriptDraft() -> Task<Void, Never>? {
        do {
            let edits = try transcriptEditDraft.validatedEdits()
            guard !edits.isEmpty else {
                transcriptEditStatus = "No transcript edits to save"
                return nil
            }

            guard let transcriptEditSessionService else {
                transcriptEditStatus = "Editor persistence unavailable"
                logger.error("Transcript draft save failed: session service unavailable")
                return nil
            }

            guard let meeting = transcriptEditMeetingsByID[transcriptEditDraft.meetingID] else {
                transcriptEditStatus = "Transcript unavailable for selected meeting"
                logger.error("Transcript draft save failed: selected meeting unavailable")
                return nil
            }

            if let coordinator = transcriptCorrectionCoordinator {
                guard transcriptCorrectionActivities[meeting.id] == nil else {
                    transcriptEditStatus = "A transcript correction is already being saved"
                    return nil
                }
                guard selectedMeetingID == meeting.id,
                      transcriptEditDraft.meetingID == meeting.id,
                      transcriptEditHistory.meetingID == meeting.id else {
                    transcriptEditStatus = "Transcript selection changed before the correction started"
                    return nil
                }
                let editedIDs = Set(edits.map(\.segmentID))
                let resolvedReviewIDs: [UUID] = transcriptReviewQueue?.activeItems.compactMap { item -> UUID? in
                    guard item.status != .superseded,
                          let segmentID = item.segmentID,
                          editedIDs.contains(segmentID) else { return nil }
                    return item.id
                } ?? []
                let selectionGeneration = transcriptSelectionGeneration
                guard let operationToken = beginTranscriptCorrectionActivity(meetingID: meeting.id) else {
                    transcriptEditStatus = "A transcript correction is already being saved"
                    return nil
                }
                transcriptEditStatus = "Saving edits and refreshing derived meeting artifacts"
                return Task { [weak self] in
                    guard let self else { return }
                    defer {
                        self.finishTranscriptCorrectionActivity(
                            meetingID: meeting.id,
                            operationToken: operationToken
                        )
                    }
                    do {
                        let result = try await coordinator.applyCorrection(
                            meeting: meeting,
                            edits: edits,
                            resolvedReviewItemIDs: resolvedReviewIDs
                        )
                        await self.transcriptCorrectionStoreReconciliationGate(meeting.id)
                        let didPresentResult = try self.applyTranscriptCorrectionResult(
                            result,
                            meeting: meeting,
                            operationToken: operationToken
                        )
                        self.appendTranscriptEditAuditRow(
                            meetingID: meeting.id,
                            version: result.editResult.version,
                            editedSegmentCount: edits.count
                        )
                        if didPresentResult {
                            self.transcriptEditStatus = "Saved transcript edits as version \(result.editResult.version)"
                        }
                    } catch TranscriptEditError.blankReplacementText {
                        if self.shouldPresentTranscriptCorrectionStatus(
                            meetingID: meeting.id,
                            generation: selectionGeneration,
                            operationToken: operationToken
                        ) {
                            self.transcriptEditStatus = "Transcript segment text cannot be blank"
                        }
                    } catch TranscriptEditError.segmentNotFound {
                        if self.shouldPresentTranscriptCorrectionStatus(
                            meetingID: meeting.id,
                            generation: selectionGeneration,
                            operationToken: operationToken
                        ) {
                            self.transcriptEditStatus = "Transcript segment unavailable"
                        }
                    } catch {
                        if self.shouldPresentTranscriptCorrectionStatus(
                            meetingID: meeting.id,
                            generation: selectionGeneration,
                            operationToken: operationToken
                        ) {
                            self.transcriptEditStatus = error.localizedDescription
                        }
                        self.logger.error("Coordinated transcript save failed")
                    }
                }
            }

            let session = TranscriptEditSession(
                meeting: meeting,
                draft: transcriptEditDraft,
                history: transcriptEditHistory
            )
            let saveResult = try transcriptEditSessionService.save(session: session)
            transcriptEditDraft = saveResult.session.draft
            transcriptEditHistory = saveResult.session.history
            transcriptEditSessionCache[saveResult.session.meeting.id] = saveResult.session
            transcriptRestoreNeedsConfirmation = false
            appendTranscriptEditAuditRow(
                meetingID: meeting.id,
                version: saveResult.result.version,
                editedSegmentCount: edits.count
            )
            transcriptEditStatus = "Saved transcript edits as version \(saveResult.result.version)"
            logger.info("Transcript draft saved version=\(saveResult.result.version, privacy: .public) editedSegmentCount=\(edits.count, privacy: .public)")
            return nil
        } catch TranscriptEditError.blankReplacementText {
            transcriptEditStatus = "Transcript segment text cannot be blank"
        } catch TranscriptEditError.segmentNotFound {
            transcriptEditStatus = "Transcript segment unavailable"
            logger.error("Transcript draft save failed: segment unavailable")
        } catch {
            transcriptEditStatus = "Transcript edits could not be saved"
            logger.error("Transcript draft save failed")
        }
        return nil
    }

    func askSelectedTranscript() {
        let trimmedPrompt = transcriptAskPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            transcriptAskStatus = "Prompt cannot be blank"
            transcriptAskEvidence = []
            return
        }

        guard !transcriptCorrectionInFlight else {
            transcriptAskStatus = transcriptAgentReadinessStatus
            transcriptAskEvidence = []
            return
        }

        guard transcriptAgentHasVisibleTranscript else {
            transcriptAskAnswerDraft = ""
            transcriptAskEvidence = []
            transcriptAskStatus = transcriptAgentReadinessStatus
            logger.info("Transcript question blocked: no visible transcript")
            return
        }

        if let transcriptQuestionAnsweringProvider {
            let question = trimmedPrompt
            let transcript = currentEditedTranscript()
            guard let requestAuthority = makeTranscriptAgentRequestAuthority(for: transcript) else {
                transcriptAskStatus = "Transcript answer authority could not be prepared"
                transcriptAskEvidence = []
                return
            }
            transcriptAskStatus = "Asking local Foundation Models"
            transcriptAskEvidence = []
            transcriptAskTask?.cancel()
            transcriptAskTask = Task { [weak self, transcriptQuestionAnsweringProvider] in
                do {
                    let answer = try await transcriptQuestionAnsweringProvider.answer(
                        question: question,
                        transcript: transcript
                    )
                    guard let self else { return }
                    self.applyTranscriptQuestionAnswer(
                        answer,
                        requestAuthority: requestAuthority
                    )
                } catch {
                    guard let self,
                          self.isCurrentTranscriptAgentRequest(requestAuthority) else { return }
                    self.applyTranscriptQuestionAnswerFailure(error)
                }
            }
            return
        }

        do {
            let transcript = currentEditedTranscript()
            guard let requestAuthority = makeTranscriptAgentRequestAuthority(for: transcript) else {
                transcriptAskStatus = "Transcript answer authority could not be prepared"
                transcriptAskEvidence = []
                return
            }
            let answer = try transcriptQuestionAnsweringService.answer(
                question: trimmedPrompt,
                transcript: transcript
            )
            applyTranscriptQuestionAnswer(answer, requestAuthority: requestAuthority)
        } catch TranscriptQuestionAnsweringError.blankQuestion {
            transcriptAskStatus = "Prompt cannot be blank"
            transcriptAskEvidence = []
        } catch {
            applyTranscriptQuestionAnswerFailure(error)
        }
    }

    private func applyTranscriptQuestionAnswer(
        _ answer: TranscriptQuestionAnswer,
        requestAuthority: TranscriptAgentRequestAuthority
    ) {
        guard isCurrentTranscriptAgentRequest(requestAuthority) else { return }
        guard answer.meetingID == requestAuthority.meetingID,
              answer.transcriptVersion == requestAuthority.transcriptVersion,
              (answer.transcriptDigest == requestAuthority.transcriptDigest
                || (answer.transcriptDigest == "legacy" && answer.transcriptVersion == 0)) else {
            transcriptAskStatus = "Transcript changed while Agent was answering; ask again"
            transcriptAskEvidence = []
            return
        }
        transcriptAskAnswerDraft = answer.editableText
        transcriptAskEvidence = answer.evidence
        transcriptConversationTurns.insert(
            TranscriptConversationTurn(
                question: answer.question,
                answerDraft: answer.editableText,
                evidence: answer.evidence
            ),
            at: 0
        )
        transcriptAskStatus = answer.evidence.isEmpty
            ? "No matching transcript evidence"
            : "Answer grounded in \(answer.evidence.count) transcript segment(s)"
        persistTranscriptQuestionHistory(meetingID: answer.meetingID)
        logger.info("Transcript question answered meetingID=\(answer.meetingID.uuidString, privacy: .public) evidenceCount=\(answer.evidence.count, privacy: .public)")
    }

    private func makeTranscriptAgentRequestAuthority(
        for transcript: MeetingTranscript
    ) -> TranscriptAgentRequestAuthority? {
        guard selectedMeetingID == transcript.meetingID,
              transcriptCorrectionActivities[transcript.meetingID] == nil,
              let digest = try? LocalFinalTranscriptionService.transcriptDigest(transcript) else {
            return nil
        }
        let generation = UUID()
        transcriptAgentRequestGenerations[transcript.meetingID] = generation
        return TranscriptAgentRequestAuthority(
            meetingID: transcript.meetingID,
            generation: generation,
            transcriptVersion: transcript.transcriptVersion,
            transcriptDigest: digest
        )
    }

    private func isCurrentTranscriptAgentRequest(
        _ authority: TranscriptAgentRequestAuthority
    ) -> Bool {
        guard selectedMeetingID == authority.meetingID,
              transcriptCorrectionActivities[authority.meetingID] == nil,
              transcriptAgentRequestGenerations[authority.meetingID] == authority.generation else {
            return false
        }
        let transcript = currentEditedTranscript()
        guard transcript.meetingID == authority.meetingID,
              transcript.transcriptVersion == authority.transcriptVersion,
              let digest = try? LocalFinalTranscriptionService.transcriptDigest(transcript) else {
            return false
        }
        return digest == authority.transcriptDigest
    }

    private func applyTranscriptQuestionAnswerFailure(_ error: Error) {
        transcriptAskEvidence = []
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            transcriptAskStatus = description
        } else {
            transcriptAskStatus = "Transcript question could not be answered"
        }
        logger.error("Transcript question answering failed")
    }

    func copyTranscriptAskAnswer() {
        let answer = transcriptAskAnswerDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else {
            transcriptAskStatus = "Answer is empty"
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcriptAskAnswerDraft, forType: .string)
        transcriptAskStatus = "Copied answer to clipboard"
        logger.info("Transcript answer copied characterCount=\(self.transcriptAskAnswerDraft.count, privacy: .public)")
    }

    func updateTranscriptAskAnswerDraft(_ text: String) {
        transcriptAskAnswerDraft = text
        guard !transcriptConversationTurns.isEmpty else { return }
        transcriptConversationTurns[0].answerDraft = text
        persistTranscriptQuestionHistory(meetingID: transcriptEditDraft.meetingID)
    }

    func copyVisibleTranscript() {
        let transcript = currentEditedTranscript()
        let text = transcript.segments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { segment in
                "[\(Self.timestamp(segment.startTime))-\(Self.timestamp(segment.endTime))] \(segment.speakerName): \(segment.text)"
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            transcriptAskStatus = transcriptAgentReadinessStatus
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        transcriptAskStatus = "Copied visible transcript to clipboard"
        logger.info("Visible transcript copied segmentCount=\(transcript.segments.count, privacy: .public)")
    }

    func clearRequestedSidebarItem() {
        requestedSidebarItem = nil
    }

    func showWorkspace(_ item: SidebarItem) {
        if item == .diagnostics {
            requestHealthRecoveryPresentation()
            return
        }
        requestedSidebarItem = SidebarItem.meetings.rawValue
        switch item {
        case .meetings:
            requestedWorkspaceFocus = MeetingsWorkspaceFocus.understand.rawValue
        case .library:
            requestedWorkspaceFocus = MeetingsWorkspaceFocus.find.rawValue
        case .recorder:
            requestedWorkspaceFocus = MeetingsWorkspaceFocus.record.rawValue
        case .intelligence:
            requestedWorkspaceFocus = MeetingsWorkspaceFocus.understand.rawValue
        case .diagnostics:
            break
        }
    }

    func showWorkspace(_ focus: MeetingsWorkspaceFocus) {
        if focus == .recover {
            requestHealthRecoveryPresentation()
            return
        }
        requestedSidebarItem = SidebarItem.meetings.rawValue
        requestedWorkspaceFocus = focus.rawValue
    }

    func requestHealthRecoveryPresentation() {
        healthRecoveryPresentationEvent = .next(after: healthRecoveryPresentationEvent)
    }

    func clearRequestedWorkspaceFocus() {
        requestedWorkspaceFocus = nil
    }

    func playTranscriptCue(_ cueID: UUID) {
        guard playbackMatchesSelectedMeeting else {
            logger.warning("Transcript playback ignored for non-selected meeting timeline")
            return
        }
        guard let transcriptPlaybackSessionService else {
            playbackSessionState = TranscriptPlaybackSessionState(
                meetingID: playbackTimeline.meetingID,
                selectedCueID: cueID,
                currentTime: playbackSessionState.currentTime,
                transportState: .failed,
                statusMessage: "Playback unavailable"
            )
            logger.error("Transcript playback failed: service unavailable")
            return
        }

        do {
            playbackSessionState = try transcriptPlaybackSessionService.playCue(cueID, in: playbackTimeline)
            logger.info("Transcript playback started cueID=\(cueID.uuidString, privacy: .public)")
        } catch {
            playbackSessionState = failedPlaybackState(cueID: cueID, message: playbackErrorMessage(error))
            logger.error("Transcript playback failed")
        }
    }

    func transcriptReviewSegment(for item: TranscriptReviewItem) -> TranscriptEditDraftSegment? {
        guard let selectedMeetingID,
              transcriptEditDraft.meetingID == selectedMeetingID,
              transcriptReviewQueue?.meetingID == selectedMeetingID,
              transcriptReviewQueue?.activeItems.contains(where: { $0.id == item.id }) == true else {
            return nil
        }
        if let segmentID = item.segmentID,
           let exact = transcriptEditDraft.segments.first(where: { $0.id == segmentID }) {
            return exact
        }
        let matches = transcriptEditDraft.segments.filter {
            $0.trackKind == item.trackKind
                && min($0.endTime, item.endTime) > max($0.startTime, item.startTime)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    func playTranscriptReviewItem(_ item: TranscriptReviewItem) {
        guard let selectedMeetingID,
              transcriptReviewQueue?.meetingID == selectedMeetingID,
              transcriptReviewQueue?.activeItems.contains(where: { $0.id == item.id }) == true,
              playbackMatchesSelectedMeeting,
              let transcriptPlaybackSessionService else {
            transcriptReviewStatus = "Exact review playback is unavailable"
            return
        }
        do {
            playbackSessionState = try transcriptPlaybackSessionService.playRange(
                startTime: item.startTime,
                endTime: item.endTime,
                track: item.trackKind,
                in: playbackTimeline
            )
            transcriptReviewStatus = "Playing exact review range"
        } catch {
            transcriptReviewStatus = playbackErrorMessage(error)
            logger.error("Transcript review playback failed")
        }
    }

    func setTranscriptReviewStatus(itemID: UUID, status: TranscriptReviewStatus) {
        guard var queue = transcriptReviewQueue,
              let selectedMeetingID,
              queue.meetingID == selectedMeetingID,
              transcriptEditDraft.meetingID == selectedMeetingID,
              playbackTimeline.meetingID == selectedMeetingID,
              let meetingContextBundleStore else {
            transcriptReviewStatus = "Review queue is unavailable"
            return
        }
        do {
            try queue.updateStatus(itemID: itemID, status: status)
            try TranscriptReviewRepository(bundleStore: meetingContextBundleStore).save(queue)
            transcriptReviewQueue = queue
            transcriptReviewStatus = status == .resolved ? "Review issue resolved" : "Review issue deferred"
        } catch {
            transcriptReviewStatus = "Review status could not be saved"
            logger.error("Transcript review status save failed")
        }
    }

    func correctTranscriptReviewItem(
        item: TranscriptReviewItem,
        replacementText: String,
        replacementSpeakerName: String
    ) {
        let trimmedText = replacementText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            transcriptReviewStatus = "Corrected transcript text cannot be blank"
            return
        }
        guard let coordinator = transcriptCorrectionCoordinator,
              let selectedMeetingID,
              transcriptCorrectionActivities[selectedMeetingID] == nil,
              transcriptReviewQueue?.meetingID == selectedMeetingID,
              transcriptReviewQueue?.activeItems.contains(where: { $0.id == item.id }) == true,
              transcriptEditDraft.meetingID == selectedMeetingID,
              transcriptEditHistory.meetingID == selectedMeetingID,
              playbackTimeline.meetingID == selectedMeetingID,
              let meeting = transcriptEditMeetingsByID[selectedMeetingID],
              let segment = transcriptReviewSegment(for: item) else {
            transcriptReviewStatus = transcriptCorrectionInFlight
                ? "A transcript correction is already being saved"
                : "This review segment can no longer be matched safely"
            return
        }
        let selectionGeneration = transcriptSelectionGeneration
        guard let operationToken = beginTranscriptCorrectionActivity(meetingID: selectedMeetingID) else {
            transcriptReviewStatus = "A transcript correction is already being saved"
            return
        }
        transcriptReviewStatus = "Saving correction and refreshing meeting intelligence"
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.finishTranscriptCorrectionActivity(
                    meetingID: meeting.id,
                    operationToken: operationToken
                )
            }
            do {
                let result = try await coordinator.applyCorrection(
                    meeting: meeting,
                    edits: [
                        TranscriptSegmentEdit(
                            segmentID: segment.id,
                            replacementText: trimmedText,
                            replacementSpeakerName: replacementSpeakerName
                        )
                    ],
                    resolvedReviewItemIDs: [item.id]
                )
                await self.transcriptCorrectionStoreReconciliationGate(meeting.id)
                let didPresentResult = try self.applyTranscriptCorrectionResult(
                    result,
                    meeting: meeting,
                    operationToken: operationToken
                )
                if didPresentResult {
                    self.transcriptReviewStatus = "Correction saved as transcript version \(result.editResult.version)"
                }
            } catch {
                if self.shouldPresentTranscriptCorrectionStatus(
                    meetingID: meeting.id,
                    generation: selectionGeneration,
                    operationToken: operationToken
                ) {
                    self.transcriptReviewStatus = error.localizedDescription
                }
                self.logger.error("Transcript review correction failed")
            }
        }
    }

    @discardableResult
    private func applyTranscriptCorrectionResult(
        _ result: TranscriptCorrectionResult,
        meeting: SearchMeeting,
        operationToken: UUID
    ) throws -> Bool {
        guard result.editResult.transcript.meetingID == meeting.id,
        result.reviewQueue.meetingID == meeting.id,
        result.playbackTimeline.meetingID == meeting.id,
        result.intelligence.meetingID == meeting.id,
        result.record.id == meeting.id,
        result.derivedState.meetingID == meeting.id else {
            throw TranscriptCorrectionError.meetingMismatch
        }
        let transcriptDigest = try LocalFinalTranscriptionService.transcriptDigest(
            result.editResult.transcript
        )
        guard result.editResult.transcript.transcriptVersion == result.editResult.version,
              result.reviewQueue.transcriptVersion == result.editResult.version,
              result.intelligence.transcriptVersion == result.editResult.version,
              result.intelligence.transcriptDigest == transcriptDigest,
              result.derivedState.isConsistent,
              result.derivedState.transcriptVersion == result.editResult.version,
              result.derivedState.transcriptDigest == transcriptDigest else {
            throw TranscriptArtifactVersionError.mixedVersions
        }
        let session = try transcriptEditSessionService?.loadSession(meeting: meeting)
        guard session?.draft.meetingID ?? meeting.id == meeting.id,
              session?.history.meetingID ?? meeting.id == meeting.id else {
            throw TranscriptCorrectionError.meetingMismatch
        }
        let matchingActivity = transcriptCorrectionActivities[meeting.id].flatMap { activity in
            activity.token == operationToken ? activity : nil
        }
        guard let matchingActivity else { return false }
        if let index = meetings.firstIndex(where: { $0.id == result.record.id }) {
            meetings[index] = result.record
        }
        if let session {
            let cachedSessionCanAdvance: Bool
            if let cachedSession = transcriptEditSessionCache[meeting.id] {
                cachedSessionCanAdvance = cachedSession.draft == matchingActivity.draftAtStart
                    && cachedSession.history == matchingActivity.historyAtStart
            } else {
                cachedSessionCanAdvance = true
            }
            if cachedSessionCanAdvance {
                transcriptEditSessionCache[meeting.id] = session
            }
        } else {
            transcriptEditSessionCache.removeValue(forKey: meeting.id)
        }
        transcriptQuestionHistoryCache.removeValue(forKey: meeting.id)

        if selectedMeetingID == meeting.id,
           matchingActivity.token == operationToken {
            transcriptAskTask?.cancel()
            transcriptAskTask = nil
            loadTranscriptQuestionHistoryForSelectedMeeting(
                defaultStatus: "Prior Agent answers were invalidated; ask again from transcript version \(result.editResult.version)",
                allowDuringCorrection: true
            )
        }

        guard selectedMeetingID == meeting.id else {
            return false
        }
        guard matchingActivity.token == operationToken,
              transcriptEditDraft == matchingActivity.draftAtStart,
              transcriptEditHistory == matchingActivity.historyAtStart else {
            return false
        }
        guard let session,
              session.draft.currentVersion == result.editResult.version,
              session.history.latestVersion == result.editResult.version,
              transcriptEditDraft.currentVersion <= result.editResult.version,
              transcriptEditHistory.latestVersion <= result.editResult.version,
              result.reviewQueue.transcriptVersion == result.editResult.version else {
            return false
        }

        transcriptReviewQueue = result.reviewQueue
        playbackTimeline = result.playbackTimeline
        playbackSessionState = transcriptPlaybackSessionService?.initialState(for: result.playbackTimeline)
            ?? .idle(for: result.playbackTimeline)
        transcriptEditDraft = session.draft
        transcriptEditHistory = session.history
        transcriptRestoreNeedsConfirmation = false
        lastExportPackage = nil
        lastShareManifest = nil
        lastShareExecutionResult = nil
        return true
    }

    private func beginTranscriptCorrectionActivity(meetingID: UUID) -> UUID? {
        guard transcriptCorrectionActivities[meetingID] == nil,
              transcriptEditDraft.meetingID == meetingID,
              transcriptEditHistory.meetingID == meetingID else {
            return nil
        }
        let operationToken = UUID()
        transcriptCorrectionActivities[meetingID] = TranscriptCorrectionActivity(
            token: operationToken,
            draftAtStart: transcriptEditDraft,
            historyAtStart: transcriptEditHistory
        )
        refreshSelectedTranscriptCorrectionActivity()
        invalidateTranscriptAgentWorkForCorrection(meetingID: meetingID)
        return operationToken
    }

    private func invalidateTranscriptAgentWorkForCorrection(meetingID: UUID) {
        transcriptAgentRequestGenerations[meetingID] = UUID()
        guard selectedMeetingID == meetingID else { return }
        transcriptAskTask?.cancel()
        transcriptAskTask = nil
        resetTranscriptAskResponse(
            status: "Agent is unavailable while transcript correction is being saved or recovered."
        )
    }

    private func finishTranscriptCorrectionActivity(meetingID: UUID, operationToken: UUID) {
        guard transcriptCorrectionActivities[meetingID]?.token == operationToken else { return }
        transcriptCorrectionActivities.removeValue(forKey: meetingID)
        refreshSelectedTranscriptCorrectionActivity()
    }

    private func refreshSelectedTranscriptCorrectionActivity() {
        transcriptCorrectionInFlight = selectedMeetingID.flatMap {
            transcriptCorrectionActivities[$0]
        } != nil
    }

    private func shouldPresentTranscriptCorrectionStatus(
        meetingID: UUID,
        generation: UUID,
        operationToken: UUID
    ) -> Bool {
        guard selectedMeetingID == meetingID else { return false }
        return transcriptSelectionGeneration == generation
            || transcriptCorrectionActivities[meetingID]?.token == operationToken
    }

    private func isCurrentTranscriptSelection(meetingID: UUID, generation: UUID) -> Bool {
        selectedMeetingID == meetingID && transcriptSelectionGeneration == generation
    }

    func pauseTranscriptPlayback() {
        guard playbackMatchesSelectedMeeting else {
            logger.warning("Transcript playback pause ignored for non-selected meeting timeline")
            return
        }
        guard let transcriptPlaybackSessionService else {
            playbackSessionState = failedPlaybackState(
                cueID: playbackSessionState.selectedCueID,
                message: "Playback unavailable"
            )
            return
        }

        do {
            playbackSessionState = try transcriptPlaybackSessionService.pause(playbackSessionState)
            logger.info("Transcript playback paused")
        } catch {
            playbackSessionState = failedPlaybackState(
                cueID: playbackSessionState.selectedCueID,
                message: playbackErrorMessage(error)
            )
            logger.error("Transcript playback pause failed")
        }
    }

    func stopTranscriptPlayback() {
        guard playbackMatchesSelectedMeeting else {
            logger.warning("Transcript playback stop ignored for non-selected meeting timeline")
            return
        }
        guard let transcriptPlaybackSessionService else {
            playbackSessionState = failedPlaybackState(
                cueID: playbackSessionState.selectedCueID,
                message: "Playback unavailable"
            )
            return
        }

        do {
            playbackSessionState = try transcriptPlaybackSessionService.stop(playbackSessionState)
            logger.info("Transcript playback stopped")
        } catch {
            playbackSessionState = failedPlaybackState(
                cueID: playbackSessionState.selectedCueID,
                message: playbackErrorMessage(error)
            )
            logger.error("Transcript playback stop failed")
        }
    }

    func seekTranscriptPlayback(to currentTime: TimeInterval) {
        guard playbackMatchesSelectedMeeting else {
            logger.warning("Transcript playback seek ignored for non-selected meeting timeline")
            return
        }
        guard let transcriptPlaybackSessionService else {
            playbackSessionState.currentTime = min(max(0, currentTime), playbackTimeline.duration)
            playbackSessionState.statusMessage = "Playback unavailable"
            return
        }

        playbackSessionState = transcriptPlaybackSessionService.seek(
            to: currentTime,
            in: playbackTimeline,
            state: playbackSessionState
        )
    }

    var playbackMatchesSelectedMeeting: Bool {
        guard let selectedMeetingID else { return false }
        return playbackTimeline.meetingID == selectedMeetingID
            && playbackSessionState.meetingID == selectedMeetingID
    }

    @discardableResult
    func importRecoveredRecording(meetingID: UUID) async throws -> RecoveredRecordingImportResult {
        guard let recoveredRecordingImportService else {
            recoveredRecordingImportStatus = "Recovered recording import unavailable"
            throw RecoveredRecordingImportRuntimeError.unavailable
        }

        do {
            let result = try await recoveredRecordingImportService.importRecoveredRecording(
                RecoveredRecordingImportRequest(
                    meetingID: meetingID,
                    sourceName: selectedSource?.displayName ?? "Recovered recording",
                    // Automatic language is the safe supported default; raw
                    // system locale identifiers (for example en-PL) are not
                    // silently coerced into Polish or English.
                    localeIdentifier: nil,
                    consentStatus: selectedMeeting?.consentStatus ?? .disclosed
                )
            )
            applyRecoveredRecordingImport(result)
            refreshRecoveredRecordings()
            recoveredRecordingImportStatus = "Recovered recording imported with \(result.transcription.transcript.segments.count) transcript segments"
            logger.info("Recovered recording imported meetingID=\(meetingID.uuidString, privacy: .public) segmentCount=\(result.transcription.transcript.segments.count, privacy: .public)")
            return result
        } catch let error as RecoveredRecordingImportError {
            recoveredRecordingImportStatus = "Recovery needs captured audio chunks"
            logger.error("Recovered recording import failed: no audio chunks")
            throw error
        } catch {
            recoveredRecordingImportStatus = "Recovered recording import failed"
            logger.error("Recovered recording import failed")
            throw error
        }
    }

    func importConfiguredLocalRecording() {
        guard !localRecordingTranscriptPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !localRecordingAudioPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            localRecordingImportStatus = "Choose transcript and recording paths first"
            return
        }

        let transcriptURL = URL(fileURLWithPath: localRecordingTranscriptPath.expandingTildePath)
        let audioURL = URL(fileURLWithPath: localRecordingAudioPath.expandingTildePath)
        let title = transcriptURL
            .deletingPathExtension()
            .lastPathComponent
            .replacingOccurrences(of: " Transcription", with: "")

        Task {
            try? await importLocalRecording(
                transcriptURL: transcriptURL,
                audioURL: audioURL,
                title: title,
                sourceName: "Local Recording"
            )
        }
    }

    func refreshLocalRecordingSamples(
        transcriptDirectory: URL = defaultLocalTranscriptSampleDirectory(),
        audioDirectory: URL = defaultLocalRecordingOutputDirectory()
    ) {
        do {
            let samples = try localRecordingSampleCatalogService.discoverSamples(
                transcriptDirectory: transcriptDirectory,
                audioDirectory: audioDirectory
            )
            localRecordingSamples = samples
            selectedLocalRecordingSampleID = samples.first?.id
            applySelectedLocalRecordingSamplePaths()
            localRecordingSampleStatus = samples.isEmpty
                ? "No matched transcript/audio pairs found"
                : "Found \(samples.count) matched local recording sample(s)"
            logger.info("Local recording samples refreshed count=\(samples.count, privacy: .public)")
        } catch {
            localRecordingSamples = []
            selectedLocalRecordingSampleID = nil
            localRecordingSampleStatus = "Local recording sample scan failed"
            logger.error("Local recording sample scan failed")
        }
    }

    func refreshLocalRecordingSamples(in directory: URL) {
        refreshLocalRecordingSamples(transcriptDirectory: directory, audioDirectory: directory)
    }

    @discardableResult
    func importLocalRecordingFolder(in directory: URL) async throws -> [LocalRecordingImportResult] {
        let samples: [LocalRecordingSampleCandidate]
        do {
            samples = try discoverLocalRecordingSamples(forSelectedFolder: directory)
        } catch {
            localRecordingSamples = []
            selectedLocalRecordingSampleID = nil
            localRecordingSampleStatus = "Local recording sample scan failed"
            localRecordingImportStatus = (error as? LocalizedError)?.errorDescription
                ?? "Local recording folder import failed"
            logger.error("Local recording folder import scan failed")
            throw error
        }
        localRecordingSamples = samples
        selectedLocalRecordingSampleID = samples.first?.id
        applySelectedLocalRecordingSamplePaths()
        localRecordingSampleStatus = samples.isEmpty
            ? "No matched transcript/audio pairs found"
            : "Found \(samples.count) matched local recording sample(s)"

        guard !samples.isEmpty else {
            localRecordingImportStatus = "No matched transcript/audio pairs found in selected folder"
            throw LocalRecordingImportRuntimeError.noSelectedSample
        }

        var results: [LocalRecordingImportResult] = []
        for sample in samples {
            let result = try await importLocalRecording(
                transcriptURL: sample.transcriptURL,
                audioURL: sample.audioURL,
                title: sample.title,
                sourceName: "Local Recording"
            )
            results.append(result)
        }

        localRecordingImportStatus = "Imported \(results.count) local recording\(results.count == 1 ? "" : "s") into library"
        return results
    }

    private func discoverLocalRecordingSamples(
        forSelectedFolder directory: URL
    ) throws -> [LocalRecordingSampleCandidate] {
        let transcriptDefault = defaultLocalTranscriptSampleDirectory()
        let audioDefault = defaultLocalRecordingOutputDirectory()
        let candidatePairs = [
            (transcriptDirectory: directory, audioDirectory: directory),
            (transcriptDirectory: directory, audioDirectory: audioDefault),
            (transcriptDirectory: transcriptDefault, audioDirectory: directory)
        ]

        var seenPairs = Set<String>()
        for pair in candidatePairs {
            let key = "\(pair.transcriptDirectory.standardizedFileURL.path)|\(pair.audioDirectory.standardizedFileURL.path)"
            guard seenPairs.insert(key).inserted else { continue }
            let samples = try localRecordingSampleCatalogService.discoverSamples(
                transcriptDirectory: pair.transcriptDirectory,
                audioDirectory: pair.audioDirectory,
                limit: 300
            )
            if !samples.isEmpty {
                return samples
            }
        }
        return []
    }

    func selectLocalRecordingSample(id: String?) {
        selectedLocalRecordingSampleID = id
        applySelectedLocalRecordingSamplePaths()
    }

    @discardableResult
    func importLocalRecordingSelection(urls: [URL]) async throws -> [LocalRecordingImportResult] {
        let pairs = localRecordingPairs(from: urls)
        guard !pairs.isEmpty else {
            localRecordingImportStatus = "Choose at least one supported transcript and matching recording file"
            throw LocalRecordingImportRuntimeError.noSelectedSample
        }

        localRecordingTranscriptPath = pairs[0].transcriptURL.path
        localRecordingAudioPath = pairs[0].audioURL.path

        var results: [LocalRecordingImportResult] = []
        for pair in pairs {
            let result = try await importLocalRecording(
                transcriptURL: pair.transcriptURL,
                audioURL: pair.audioURL,
                title: pair.title,
                sourceName: "Local Recording"
            )
            results.append(result)
        }

        localRecordingImportStatus = "Imported \(results.count) local recording\(results.count == 1 ? "" : "s") into library"
        return results
    }

    @discardableResult
    func importSelectedLocalRecordingSample() async throws -> LocalRecordingImportResult {
        guard let sample = selectedLocalRecordingSample else {
            localRecordingImportStatus = "Select a local recording sample first"
            throw LocalRecordingImportRuntimeError.noSelectedSample
        }

        return try await importLocalRecording(
            transcriptURL: sample.transcriptURL,
            audioURL: sample.audioURL,
            title: sample.title,
            sourceName: "Local Recording"
        )
    }

    @discardableResult
    func importLocalRecording(
        transcriptURL: URL,
        audioURL: URL,
        title: String? = nil,
        sourceName: String = "Local Recording"
    ) async throws -> LocalRecordingImportResult {
        guard let localRecordingImportService else {
            localRecordingImportStatus = "Local recording import unavailable"
            throw LocalRecordingImportRuntimeError.unavailable
        }

        do {
            let result = try await localRecordingImportService.importRecording(
                LocalRecordingImportRequest(
                    transcriptURL: transcriptURL,
                    audioURL: audioURL,
                    title: title,
                    sourceName: sourceName,
                    consentStatus: .internalOnly,
                    localeIdentifier: Locale.current.identifier
                ),
                intelligenceService: meetingIntelligenceService
            )
            applyImportedLocalRecording(result)
            switch result.intelligenceOutcome {
            case .generated:
                localRecordingImportStatus = "Imported \(result.transcript.segments.count) transcript segments and generated the meeting title"
            case let .unavailable(reason):
                localRecordingImportStatus = "Imported \(result.transcript.segments.count) transcript segments; title generation unavailable: \(reason)"
            case .notRequested:
                localRecordingImportStatus = "Imported local recording into library with \(result.transcript.segments.count) transcript segments"
            }
            logger.info("Local recording imported meetingID=\(result.record.id.uuidString, privacy: .public) segmentCount=\(result.transcript.segments.count, privacy: .public)")
            return result
        } catch {
            localRecordingImportStatus = (error as? LocalizedError)?.errorDescription ?? "Local recording import failed"
            logger.error("Local recording import failed")
            throw error
        }
    }

    @discardableResult
    func exportSelectedMeeting() throws -> MeetingExportPackage {
        guard let meetingExportService, let exportRoot else {
            exportStatus = "Export unavailable"
            throw MeetingVaultExportRuntimeError.unavailable
        }
        guard let meetingID = selectedMeetingID,
              let meeting = transcriptEditMeetingsByID[meetingID]
        else {
            exportStatus = "Select a meeting before exporting"
            throw MeetingVaultExportRuntimeError.noSelectedMeeting
        }

        let formats = selectedExportFormats()
        guard !formats.isEmpty else {
            exportStatus = "Select at least one export format"
            throw MeetingVaultExportRuntimeError.noFormatsSelected
        }

        do {
            let package = try meetingExportService.exportPackage(
                meeting: meeting,
                to: exportRoot,
                formats: formats
            )
            lastExportPackage = package
            exportStatus = "Exported \(package.files.count) file(s) for \(meeting.title)"
            appendExportAuditRow(meetingID: meeting.id, formats: package.files.map(\.format))
            logger.info("Meeting exported meetingID=\(meeting.id.uuidString, privacy: .public) fileCount=\(package.files.count, privacy: .public)")
            return package
        } catch {
            exportStatus = "Export failed"
            logger.error("Meeting export failed")
            throw error
        }
    }

    @discardableResult
    func prepareShareForLatestExportPackage() throws -> MeetingShareManifest {
        guard let meetingSharePreparationService else {
            shareStatus = "Share unavailable"
            throw MeetingVaultShareRuntimeError.unavailable
        }
        guard let meetingID = selectedMeetingID else {
            shareStatus = "Select a meeting before sharing"
            throw MeetingVaultShareRuntimeError.noSelectedMeeting
        }
        guard let package = lastExportPackage else {
            shareStatus = "Export a package before sharing"
            throw MeetingVaultShareRuntimeError.noExportPackage
        }
        guard package.meetingID == meetingID else {
            lastExportPackage = nil
            lastShareManifest = nil
            shareStatus = "Export the selected meeting before sharing"
            throw MeetingVaultShareRuntimeError.noExportPackage
        }

        do {
            let manifest = try meetingSharePreparationService.prepareShare(
                meetingID: meetingID,
                package: package,
                destination: shareDestination
            )
            lastShareManifest = manifest
            shareStatus = "Prepared \(shareDestination.displayTitle) share for \(manifest.files.count) file(s)"
            appendShareAuditRow(
                meetingID: meetingID,
                destination: shareDestination,
                formats: manifest.files.map(\.format)
            )
            logger.info("Meeting share prepared meetingID=\(meetingID.uuidString, privacy: .public) destination=\(self.shareDestination.rawValue, privacy: .public) fileCount=\(manifest.files.count, privacy: .public)")
            return manifest
        } catch {
            shareStatus = "Share preparation failed"
            logger.error("Meeting share preparation failed")
            throw error
        }
    }

    @discardableResult
    func executePreparedShare(userConfirmed: Bool) throws -> MeetingShareExecutionResult {
        guard userConfirmed else {
            shareStatus = MeetingVaultShareExecutionError.confirmationRequired.errorDescription ?? "Confirm share before opening a destination"
            throw MeetingVaultShareExecutionError.confirmationRequired
        }
        guard let manifest = lastShareManifest else {
            shareStatus = MeetingVaultShareExecutionError.noPreparedShare.errorDescription ?? "Prepare a share before opening a destination"
            throw MeetingVaultShareExecutionError.noPreparedShare
        }

        do {
            guard !transcriptCorrectionInFlight else {
                throw TranscriptArtifactVersionError.correctionInProgress
            }
            guard manifest.meetingID == selectedMeetingID else {
                throw TranscriptArtifactVersionError.meetingMismatch
            }
            guard let meetingSharePreparationService else {
                throw MeetingVaultShareRuntimeError.unavailable
            }
            try meetingSharePreparationService.validatePreparedShare(manifest)
            let result = try meetingShareExecutor.execute(manifest)
            lastShareExecutionResult = result
            shareStatus = "\(result.destination.executionTitle) share opened for \(result.fileCount) file(s)"
            logger.info("Meeting share destination opened meetingID=\(manifest.meetingID.uuidString, privacy: .public) destination=\(result.destination.rawValue, privacy: .public) fileCount=\(result.fileCount, privacy: .public)")
            return result
        } catch let error as MeetingVaultShareExecutionError {
            shareStatus = error.errorDescription ?? "Share destination failed"
            logger.error("Meeting share destination failed")
            throw error
        } catch {
            shareStatus = "Share destination failed"
            logger.error("Meeting share destination failed")
            throw error
        }
    }

    @discardableResult
    func exportFilteredPrivacyAuditReview() throws -> PrivacyAuditReviewExport {
        guard let exportRoot else {
            privacyAuditExportStatus = "Privacy audit export unavailable"
            throw MeetingVaultAuditExportRuntimeError.unavailable
        }

        do {
            let export = try PrivacyAuditReviewExportService().exportReview(
                privacyAuditReview,
                to: exportRoot.appendingPathComponent("PrivacyAudit", isDirectory: true),
                actionFilter: privacyAuditActionFilter
            )
            lastPrivacyAuditExport = export
            privacyAuditExportStatus = "Exported \(export.rowCount) redacted audit row(s)"
            logger.info("Privacy audit review exported rowCount=\(export.rowCount, privacy: .public) actionFilter=\(export.actionFilter?.rawValue ?? "all", privacy: .public)")
            return export
        } catch {
            privacyAuditExportStatus = "Privacy audit export failed"
            logger.error("Privacy audit review export failed")
            throw error
        }
    }

    @discardableResult
    func prepareSystemIntegrationReview() throws -> MeetingSystemIntegrationReview {
        guard let meetingID = selectedMeetingID,
              let meeting = transcriptEditMeetingsByID[meetingID]
        else {
            systemIntegrationStatus = "Select a meeting before preparing system integration review"
            throw MeetingVaultSystemIntegrationRuntimeError.noSelectedMeeting
        }
        guard let summary = selectedMeeting?.summary else {
            systemIntegrationStatus = "Selected meeting needs generated intelligence before system integration review"
            throw MeetingVaultSystemIntegrationRuntimeError.noMeetingSummary
        }

        do {
            let review = try systemIntegrationPreparationService.prepareReview(
                meeting: meeting,
                summary: summary
            )
            systemIntegrationReview = review
            systemIntegrationStatus = review.reviewSummary
            appendSystemIntegrationAuditRow(review)
            logger.info("System integration review prepared meetingID=\(meeting.id.uuidString, privacy: .public) proposalCount=\(review.proposals.count, privacy: .public)")
            return review
        } catch let error as MeetingSystemIntegrationPreparationError {
            systemIntegrationReview = nil
            systemIntegrationStatus = error.errorDescription ?? "System integration review unavailable"
            logger.error("System integration review failed")
            throw error
        } catch {
            systemIntegrationReview = nil
            systemIntegrationStatus = "System integration review failed"
            logger.error("System integration review failed")
            throw error
        }
    }

    @discardableResult
    func confirmSystemIntegrationWrites() throws -> MeetingSystemIntegrationExecutionResult {
        do {
            let result = try systemIntegrationExecutionService.executeConfirmedWrites(
                review: systemIntegrationReview,
                confirmed: true
            )
            lastSystemIntegrationExecutionResult = result
            systemIntegrationReview = nil
            systemIntegrationStatus = result.statusSummary
            appendSystemIntegrationConfirmAuditRow(result)
            logger.info("System integration confirmed meetingID=\(result.meetingID.uuidString, privacy: .public) receiptCount=\(result.receipts.count, privacy: .public)")
            return result
        } catch let error as MeetingSystemIntegrationPartialWriteError {
            let result = MeetingSystemIntegrationExecutionResult(
                meetingID: error.meetingID,
                executedAt: error.executedAt,
                receipts: error.receipts,
                externalWriteExecuted: !error.receipts.isEmpty,
                auditMetadata: [
                    "proposalCount": "\(systemIntegrationReview?.proposals.count ?? 0)",
                    "receiptCount": "\(error.receipts.count)",
                    "externalWriteExecuted": error.receipts.isEmpty ? "false" : "true",
                    "partialFailure": "true"
                ],
                statusSummary: error.errorDescription ?? "System handoff partially completed"
            )
            lastSystemIntegrationExecutionResult = result
            let completedIDs = Set(error.receipts.map(\.proposalID))
            systemIntegrationReview?.proposals.removeAll { completedIDs.contains($0.id) }
            systemIntegrationStatus = result.statusSummary
            appendSystemIntegrationConfirmAuditRow(result)
            logger.error("System integration partially completed receiptCount=\(error.receipts.count, privacy: .public)")
            throw error
        } catch let error as MeetingSystemIntegrationExecutionError {
            lastSystemIntegrationExecutionResult = nil
            systemIntegrationStatus = error.errorDescription ?? "System integration handoff unavailable"
            logger.error("System integration confirmation failed")
            throw error
        } catch {
            lastSystemIntegrationExecutionResult = nil
            systemIntegrationStatus = "System integration handoff failed"
            logger.error("System integration confirmation failed")
            throw error
        }
    }

    private func selectedExportFormats() -> [MeetingExportFormat] {
        var formats: [MeetingExportFormat] = []
        if exportMarkdown {
            formats.append(.markdown)
        }
        if exportWebVTT {
            formats.append(.webVTT)
        }
        if exportPDF {
            formats.append(.pdf)
        }
        if exportDOCX {
            formats.append(.docx)
        }
        if exportJSON {
            formats.append(.json)
        }
        if exportAudioPackage {
            formats.append(.audioPackage)
        }
        return formats
    }

    @discardableResult
    func processStoppedRecordingForSelectedSource(
        meetingID: UUID = UUID(),
        title: String? = nil,
        startedAt: Date = Date()
    ) async throws -> RecordingProcessingResult {
        guard let recordingProcessingService else {
            recordingState = .error
            logger.error("Recording processing unavailable")
            throw RecordingProcessingRuntimeError.unavailable
        }

        let source = selectedSource
        let inputDevice = selectedAudioInputDevice
        let resolvedTitle = title ?? "Recorded \(source?.displayName ?? "meeting")"
        lastRecordingProcessingIntent = RecordingProcessingIntent(
            title: resolvedTitle,
            startedAt: startedAt
        )
        recordingProcessingFailureStage = nil
        do {
            let result = try await recordingProcessingService.process(
                RecordingProcessingRequest(
                    meetingID: meetingID,
                    title: resolvedTitle,
                    startedAt: startedAt,
                    sourceID: source?.id ?? selectedSourceID,
                    sourceName: source?.displayName ?? selectedSourceID,
                    includeMicrophone: true,
                    microphoneDeviceID: inputDevice?.id,
                    microphoneDeviceName: inputDevice?.displayName,
                    context: MeetingContext(),
                    consentStatus: selectedMeeting?.consentStatus ?? .disclosed
                ),
                progress: { progress in
                    Task { @MainActor [weak self] in
                        self?.recordingProcessingProgress = progress
                        self?.recordingProcessingStatus = progress.message
                    }
                },
                shouldCancel: { [recordingProcessingCancellation] in
                    recordingProcessingCancellation.isRequested
                }
            )

            applyProcessedRecording(result)
            refreshRecoveredRecordings()
            recordingState = .ready
            recordingProcessingProgress = RecordingProcessingProgress(
                stage: .finished,
                fractionCompleted: 1,
                message: "Processing complete"
            )
            recordingProcessingStatus = "Processing complete"
            liveTranscriptionStatus = "Final transcript saved"
            liveTranscriptPreviewSegments = []
            liveInputLevel = 0
            recordingProcessingCancellation.reset()
            lastRecordingProcessingIntent = nil
            logger.info("Recording processing finished meetingID=\(meetingID.uuidString, privacy: .public) segmentCount=\(result.transcription.transcript.segments.count, privacy: .public)")
            return result
        } catch let error as RecordingProcessingError {
            switch error {
            case let .cancelled(stage):
                recordingState = .ready
                recordingProcessingStatus = "Processing cancelled"
                recordingProcessingProgress = RecordingProcessingProgress(
                    stage: stage,
                    fractionCompleted: recordingProcessingProgress?.fractionCompleted ?? 0,
                    message: "Processing cancelled"
                )
                recordingProcessingFailureStage = nil
            case let .failed(stage, message):
                applyRecordingProcessingFailure(stage: stage, message: message)
            }
            recordingProcessingCancellation.reset()
            logger.info("Recording processing did not complete meetingID=\(meetingID.uuidString, privacy: .public)")
            refreshRecoveredRecordings()
            throw error
        }
    }

    @discardableResult
    private func finishActiveRecordingSession(
        _ session: ActiveRecordingProcessingSession
    ) async throws -> RecordingProcessingResult {
        guard let recordingProcessingService else {
            if let coordinator = activeTranscriptionCoordinator {
                await persistPreviewEvidenceBestEffort(
                    meetingID: session.request.meetingID,
                    coordinator: coordinator
                )
            }
            cleanupActiveRecordingSession(cancelCapture: false)
            recordingState = .error
            logger.error("Active recording finish failed: processing service unavailable")
            throw RecordingProcessingRuntimeError.unavailable
        }
        defer { cleanupActiveRecordingSession(cancelCapture: false) }

        lastRecordingProcessingIntent = RecordingProcessingIntent(
            title: session.request.title,
            startedAt: session.request.startedAt
        )
        recordingProcessingFailureStage = nil
        do {
            // Establish an explicit live-to-final handoff. Capture fanout owns
            // coordinator.finish(), which drains queued frames and releases the
            // live model lease. The UI event consumer is then allowed to drain
            // the coordinator's terminal stream before final models can open.
            session.requestStop()
            _ = try? await session.waitForCaptureCompletion()
            if let coordinator = activeTranscriptionCoordinator {
                try? await coordinator.finish()
                if let recordingSessionMetadataManager {
                    _ = try await recordingSessionMetadataManager.recordPreviewEvidence(
                        meetingID: session.request.meetingID,
                        evidence: await coordinator.previewEvidenceSnapshot()
                    )
                }
            }
            await liveTranscriptPreviewTask?.value
            let result = try await recordingProcessingService.finishRecording(
                session,
                liveTranscriptSegments: liveTranscriptSegmentsForFinalization,
                progress: { progress in
                    Task { @MainActor [weak self] in
                        self?.recordingProcessingProgress = progress
                        self?.recordingProcessingStatus = progress.message
                    }
                },
                shouldCancel: { [recordingProcessingCancellation] in
                    recordingProcessingCancellation.isRequested
                }
            )

            guard activeRecordingSession === session else {
                throw RecordingProcessingError.cancelled(
                    stage: recordingProcessingProgress?.stage ?? .recordingAudio
                )
            }

            applyProcessedRecording(result)
            refreshRecoveredRecordings()
            recordingState = .ready
            recordingProcessingProgress = RecordingProcessingProgress(
                stage: .finished,
                fractionCompleted: 1,
                message: "Processing complete"
            )
            recordingProcessingStatus = "Processing complete"
            recordingProcessingCancellation.reset()
            liveTranscriptSegments = []
            liveTranscriptPreviewSegments = []
            liveInputLevel = 0
            liveTranscriptionStatus = "Final transcript saved"
            lastRecordingProcessingIntent = nil
            logger.info("Active recording processing finished meetingID=\(session.request.meetingID.uuidString, privacy: .public) segmentCount=\(result.transcription.transcript.segments.count, privacy: .public)")
            return result
        } catch let error as RecordingProcessingError {
            let resolvedError: RecordingProcessingError
            if recordingCancellationInFlight, activeRecordingSession !== session {
                let stage: RecordingProcessingStage = switch error {
                case let .cancelled(stage), let .failed(stage, _): stage
                }
                resolvedError = .cancelled(stage: stage)
            } else {
                resolvedError = error
            }
            switch resolvedError {
            case let .cancelled(stage):
                recordingState = .ready
                recordingProcessingStatus = "Processing cancelled"
                recordingProcessingProgress = RecordingProcessingProgress(
                    stage: stage,
                    fractionCompleted: recordingProcessingProgress?.fractionCompleted ?? 0,
                    message: "Processing cancelled"
                )
                recordingProcessingFailureStage = nil
            case let .failed(stage, message):
                applyRecordingProcessingFailure(stage: stage, message: message)
            }
            recordingProcessingCancellation.reset()
            liveTranscriptionStatus = switch resolvedError {
            case .cancelled: "Final transcription cancelled"
            case .failed: "Final transcription failed"
            }
            logger.info("Active recording processing did not complete meetingID=\(session.request.meetingID.uuidString, privacy: .public)")
            refreshRecoveredRecordings()
            throw resolvedError
        } catch {
            if recordingCancellationInFlight, activeRecordingSession !== session {
                let stage = recordingProcessingProgress?.stage ?? .recordingAudio
                recordingState = .ready
                recordingProcessingStatus = "Processing cancelled"
                recordingProcessingProgress = RecordingProcessingProgress(
                    stage: stage,
                    fractionCompleted: recordingProcessingProgress?.fractionCompleted ?? 0,
                    message: "Processing cancelled"
                )
                recordingProcessingFailureStage = nil
                recordingProcessingCancellation.reset()
                throw RecordingProcessingError.cancelled(stage: stage)
            }
            throw error
        }
    }

    private func observeActiveCaptureFailure(for session: ActiveRecordingProcessingSession) {
        activeRecordingCaptureMonitorTask?.cancel()
        activeRecordingCaptureMonitorTask = Task { @MainActor [weak self] in
            do {
                try await session.waitForCaptureCompletion()
            } catch {
                guard !Task.isCancelled,
                      let self,
                      self.recordingState == .recording,
                      self.activeRecordingSession === session
                else { return }

                if let coordinator = self.activeTranscriptionCoordinator {
                    await self.persistPreviewEvidenceBestEffort(
                        meetingID: session.request.meetingID,
                        coordinator: coordinator
                    )
                }
                self.cleanupActiveRecordingSession(cancelCapture: false)
                self.stopLiveTranscriptPreviewLoop(finalStatus: "Live transcription stopped because capture failed")
                let message = Self.recordingErrorMessage(error)
                self.applyRecordingProcessingFailure(stage: .recordingAudio, message: message)
                self.recordingProcessingProgress = RecordingProcessingProgress(
                    stage: .recordingAudio,
                    fractionCompleted: self.recordingProcessingProgress?.fractionCompleted ?? 0.20,
                    message: "Capture interrupted"
                )
                self.refreshRecoveredRecordings()
                self.logger.error("Active recording capture failed: \(message, privacy: .public)")
            }
        }
    }

    private func cleanupActiveRecordingSession(cancelCapture: Bool) {
        activeRecordingCaptureMonitorTask?.cancel()
        activeRecordingCaptureMonitorTask = nil
        if cancelCapture {
            activeRecordingSession?.cancel()
        }
        activeRecordingSession = nil
        let transcriptionCoordinator = activeTranscriptionCoordinator
        activeTranscriptionCoordinator = nil
        if let transcriptionCoordinator {
            Task { await transcriptionCoordinator.cancel() }
        }
        let activityLease = recordingActivityLease
        recordingActivityLease = nil
        if let activityLease { Task { await activityLease.release() } }
        activeRecordingPresentation = nil
        bookmarkSessionGeneration = UUID()
        pendingBookmarkMutations.removeAll()
        bookmarkMutationTail = nil
        lastMarkedMoment = nil
        recordingBookmarkStatus = "Mark Moment is available only while recording"
        activeMeetingContext = nil
        activeLiveTranscriptionContext = nil
        resetRecordingLevelSession()
    }

    private func persistPreviewEvidenceBestEffort(
        meetingID: UUID,
        coordinator: TranscriptionSessionCoordinator
    ) async {
        guard let recordingSessionMetadataManager else { return }
        do {
            _ = try await recordingSessionMetadataManager.recordPreviewEvidence(
                meetingID: meetingID,
                evidence: await coordinator.previewEvidenceSnapshot()
            )
        } catch {
            logger.error("Live preview evidence could not be persisted before recording teardown")
        }
    }

    @discardableResult
    func refreshPermissions() async -> PermissionPreflightResult {
        let privacyMode = await transcriptionPrivacyBoundary.mode()
        let result = await permissionPreflightService.evaluate(
            consentStatus: selectedMeeting?.consentStatus ?? .disclosed,
            storageDirectoryURL: recordingStorageRoot,
            requireConsentBeforeRecording: requireConsentBeforeRecording,
            requireSystemAudioPermission: selectedSourceRequiresSystemAudioPermission,
            requireSpeechRecognitionPermission: privacyMode != .localOnly
        )
        latestPreflightResult = result
        if canApplyPermissionRefreshState {
            recordingState = result.canRecord ? .ready : .permissionNeeded
        }
        let issues = result.issues.map(\.rawValue).joined(separator: ",")
        logger.info("Preflight finished canRecord=\(result.canRecord, privacy: .public) issues=\(issues, privacy: .public)")
        await refreshTranscriptionSetupPresentation()
        return result
    }

    private func preflightForRecordingStart() async -> PermissionPreflightResult {
        if let latestPreflightResult, latestPreflightResult.canRecord {
            return latestPreflightResult
        }
        return await refreshPermissions()
    }

    private static func readinessTitle(for issues: [PreflightIssue]) -> String {
        if issues.contains(.doNotRecord) {
            return "Do Not Record"
        }
        if issues.contains(.consentRequired) {
            return "Consent Needed"
        }
        if issues.contains(.diskSpaceLow) {
            return "Storage Needed"
        }
        if issues.contains(where: \.isPermissionIssue) {
            return "Permission Needed"
        }
        return "Setup Needed"
    }

    private static func readinessDetail(for result: PermissionPreflightResult) -> String {
        let issues = result.issues
        if issues.contains(.doNotRecord) {
            return "This meeting is marked do not record."
        }
        if issues.contains(.consentRequired) {
            return "Set consent or disclosure before recording."
        }
        if issues.contains(.diskSpaceLow) {
            if let estimate = result.storageEstimate {
                return "Free storage is \(Self.byteCount(estimate.availableBytes)); \(Self.byteCount(estimate.requiredFreeDiskBytes)) required."
            }
            return "Free storage is below the recording safety reserve."
        }
        let missingPermissions = issues.filter(\.isPermissionIssue).map(\.readinessLabel)
        if !missingPermissions.isEmpty {
            return "Allow \(missingPermissions.joined(separator: ", "))."
        }
        return "Refresh readiness and retry recording."
    }

    private static func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var selectedSourceRequiresSystemAudioPermission: Bool {
        switch selectedSource?.mode {
        case .microphone:
            false
        case .selectedApplication, .processGroup, .systemAudio, .outputDevice, .screenCaptureFallback, nil:
            true
        }
    }

    private var canApplyPermissionRefreshState: Bool {
        switch recordingState {
        case .idle, .ready, .permissionNeeded, .error, .recovered:
            true
        case .recording, .paused, .processing:
            false
        }
    }

    private func prepareTranscriptionCoordinator(
        for request: RecordingProcessingRequest
    ) async -> TranscriptionSessionCoordinator? {
        let expectedRemoteSpeakers = request.context.expectedParticipantCount.map { max(1, $0 - 1) }
        // Resolve once at the accepted Start boundary. Privacy transitions are
        // blocked for the lifetime of this recording, so live routing cannot
        // change mid-session and the next recording sees the next saved mode.
        let provider = await resolvedTranscriptionProviderForNextSession()
        let coordinator = TranscriptionSessionCoordinator(
            provider: provider,
            configuration: TranscriptionSessionConfiguration(
                meetingID: request.meetingID,
                context: request.context,
                expectedRemoteSpeakerCount: expectedRemoteSpeakers,
                sourceID: request.sourceID,
                microphoneDeviceID: request.microphoneDeviceID,
                microphoneDeviceName: request.microphoneDeviceName
            )
        )
        do {
            try await coordinator.start()
            return coordinator
        } catch {
            liveTranscriptionStatus = "Live transcription unavailable: \(Self.liveTranscriptionErrorMessage(error)). Recording remains encrypted and uninterrupted."
            return nil
        }
    }

    private func startLiveTranscriptPreviewLoop() {
        stopLiveTranscriptPreviewLoop(finalStatus: nil)
        liveTranscriptSegments = []
        liveTranscriptPreviewSegments = []
        liveInputLevel = 0
        liveSystemAudioLevel = 0
        liveActiveSpeakers = []
        guard let coordinator = activeTranscriptionCoordinator else { return }
        liveTranscriptionStatus = "Connecting verified frame-fed transcription"
        liveTranscriptPreviewTask = Task { [weak self] in
            guard let self else { return }
            for await event in coordinator.events {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.recordingState == .recording || self.recordingState == .processing else { return }
                    self.applyLocalTranscriptionEvent(event)
                }
            }
        }
    }

    private func applyLocalTranscriptionEvent(_ event: LocalTranscriptionEvent) {
        switch event {
        case let .status(message):
            liveTranscriptionStatus = message
        case let .level(track, level):
            switch track {
            case .microphone: liveInputLevel = level
            case .remoteSystem: liveSystemAudioLevel = level
            case .mixedPlayback: break
            }
        case let .partial(segment):
            upsertLiveTranscriptPreviewSegment(segment)
            liveTranscriptionStatus = "Streaming partial transcript preview · final transcription runs after Stop"
        case let .final(segment):
            upsertLiveTranscriptPreviewSegment(segment)
            liveTranscriptionStatus = "Live transcript segment finalized · final pass still runs after Stop"
        case let .activeSpeakers(speakers):
            liveActiveSpeakers = speakers
        case let .degraded(message):
            liveTranscriptionStatus = message
        }
    }

    private func upsertLiveTranscriptPreviewSegment(_ segment: TranscriptSegment) {
        if let index = liveTranscriptSegments.firstIndex(where: { $0.id == segment.id }) {
            liveTranscriptSegments[index] = segment
        } else {
            liveTranscriptSegments.append(segment)
        }
        if let index = liveTranscriptPreviewSegments.firstIndex(where: { $0.id == segment.id }) {
            liveTranscriptPreviewSegments[index] = segment
        } else {
            liveTranscriptPreviewSegments.append(segment)
        }
        if liveTranscriptPreviewSegments.count > 6 {
            liveTranscriptPreviewSegments.removeFirst(liveTranscriptPreviewSegments.count - 6)
        }
    }

    private var liveTranscriptSegmentsForFinalization: [TranscriptSegment] {
        guard localTranscriptionProvider.descriptor.id != "legacy-live-fixture-adapter" else {
            return []
        }
        return liveTranscriptSegments
    }

    private func stopLiveTranscriptPreviewLoop(finalStatus: String?) {
        liveTranscriptPreviewTask?.cancel()
        liveTranscriptPreviewTask = nil
        liveInputLevel = 0
        liveSystemAudioLevel = 0
        liveActiveSpeakers = []
        if let finalStatus {
            liveTranscriptionStatus = finalStatus
        }
    }

    private static func liveTranscriptionErrorMessage(_ error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription,
           !localized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return localized
        }
        return "Provider failed"
    }

    private func liveTranscriptionContext(for request: RecordingProcessingRequest) -> LiveTranscriptionContext {
        LiveTranscriptionContext(
            meetingID: request.meetingID,
            sourceID: request.sourceID,
            sourceName: request.sourceName,
            microphoneDeviceID: request.microphoneDeviceID,
            microphoneDeviceName: request.microphoneDeviceName,
            localeIdentifier: request.localeIdentifier
        )
    }

    private static func recordingErrorMessage(_ error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription,
           !localized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return localized
        }
        return String(describing: error)
    }

    private func applyRecordingProcessingFailure(stage: RecordingProcessingStage, message: String) {
        recordingState = .error
        recordingProcessingFailureStage = stage
        recordingProcessingStatus = "\(stage.failureTitle) failed: \(message)"
        if stage == .recordingAudio {
            recordingProcessingRecoveryStatus = "Capture stopped before completion. Detect inputs or choose another source, then retry. Any checkpointed audio is listed in Health & Recovery."
        } else {
            recordingProcessingRecoveryStatus = "Fix the \(stage.failureTitle.lowercased()) issue, then retry the last recording job."
        }
    }

    private func updateTranscriptDraftSegment(id: UUID, speakerName: String?, text: String) {
        do {
            try transcriptEditDraft.updateSegment(id: id, speakerName: speakerName, text: text)
            transcriptRestoreNeedsConfirmation = false
            refreshTranscriptEditStatus(defaultStatus: "Draft updated")
            cacheCurrentTranscriptEditSession(for: transcriptEditDraft.meetingID)
        } catch {
            transcriptEditStatus = "Transcript segment unavailable"
            logger.error("Transcript draft update failed")
        }
    }

    private func cacheCurrentTranscriptEditSession(for meetingID: UUID?) {
        guard let meetingID, let meeting = transcriptEditMeetingsByID[meetingID] else {
            return
        }
        transcriptEditSessionCache[meetingID] = TranscriptEditSession(
            meeting: meeting,
            draft: transcriptEditDraft,
            history: transcriptEditHistory
        )
    }

    private func loadTranscriptEditSessionForSelectedMeeting() {
        guard let selectedMeetingID else {
            clearSelectedTranscriptWorkspace(
                status: "Select a meeting to ask about its transcript",
                bookmarkStatus: "No marked moments loaded: no meeting selected"
            )
            return
        }

        guard let meeting = transcriptEditMeetingsByID[selectedMeetingID] else {
            clearSelectedTranscriptWorkspace(
                meetingID: selectedMeetingID,
                status: "Transcript unavailable for selected meeting",
                bookmarkStatus: "Marked moments unavailable: selected transcript is unavailable"
            )
            transcriptEditStatus = "Transcript unavailable for selected meeting"
            logger.warning("Transcript editor selection has no seeded transcript session")
            return
        }

        if let cachedSession = transcriptEditSessionCache[selectedMeetingID] {
            var session = cachedSession
            if isUnchangedTranscriptSessionFromActiveCorrection(
                cachedSession,
                meetingID: selectedMeetingID
            ), let persistedSession = try? transcriptEditSessionService?.loadSession(meeting: meeting),
               persistedSession.draft.currentVersion > cachedSession.draft.currentVersion {
                session = persistedSession
                transcriptEditSessionCache[selectedMeetingID] = persistedSession
            }
            transcriptEditDraft = session.draft
            transcriptEditHistory = session.history
            transcriptRestoreNeedsConfirmation = false
            refreshTranscriptEditStatus(defaultStatus: "Loaded \(meeting.title)")
            loadTranscriptQuestionHistoryForSelectedMeeting(defaultStatus: "Ask a question about \(meeting.title)")
            refreshSelectedPlaybackBookmarks(meetingID: selectedMeetingID)
            return
        }

        guard let transcriptEditSessionService else {
            transcriptEditStatus = "Editor persistence unavailable"
            resetTranscriptAskResponse(status: "Editor persistence unavailable")
            logger.error("Transcript draft load failed: session service unavailable")
            return
        }

        do {
            let session = try transcriptEditSessionService.loadSession(meeting: meeting)
            transcriptEditSessionCache[selectedMeetingID] = session
            transcriptEditDraft = session.draft
            transcriptEditHistory = session.history
            transcriptRestoreNeedsConfirmation = false
            refreshTranscriptEditStatus(defaultStatus: "Loaded \(meeting.title)")
            loadTranscriptQuestionHistoryForSelectedMeeting(defaultStatus: "Ask a question about \(meeting.title)")
            refreshSelectedPlaybackBookmarks(meetingID: selectedMeetingID)
        } catch {
            transcriptEditStatus = "Transcript unavailable for selected meeting"
            resetTranscriptAskResponse(status: "Transcript unavailable for selected meeting")
            logger.error("Transcript draft load failed")
        }
    }

    private func isUnchangedTranscriptSessionFromActiveCorrection(
        _ session: TranscriptEditSession,
        meetingID: UUID
    ) -> Bool {
        guard let activity = transcriptCorrectionActivities[meetingID] else {
            return false
        }
        guard session.draft == activity.draftAtStart,
              session.history == activity.historyAtStart,
              let meetingContextBundleStore else {
            return false
        }
        return (try? !meetingContextBundleStore.artifactExists(
            meetingID: meetingID,
            relativePath: TranscriptCorrectionRecoveryMarker.relativePath
        )) == true
    }

    private func refreshTranscriptReviewForSelectedMeeting() {
        guard let selectedMeetingID,
              let meetingContextBundleStore else {
            transcriptReviewQueue = nil
            transcriptReviewStatus = "Select a meeting to review transcript confidence"
            return
        }
        let selectionGeneration = transcriptSelectionGeneration
        do {
            if try meetingContextBundleStore.artifactExists(
                meetingID: selectedMeetingID,
                relativePath: TranscriptCorrectionRecoveryMarker.relativePath
            ), let coordinator = transcriptCorrectionCoordinator,
               let meeting = transcriptEditMeetingsByID[selectedMeetingID] {
                transcriptReviewStatus = "Recovering an interrupted transcript correction"
                guard transcriptCorrectionActivities[selectedMeetingID] == nil else {
                    refreshSelectedTranscriptCorrectionActivity()
                    return
                }
                guard let operationToken = beginTranscriptCorrectionActivity(
                    meetingID: selectedMeetingID
                ) else {
                    transcriptReviewStatus = "Correction recovery needs attention"
                    return
                }
                Task { [weak self] in
                    guard let self else { return }
                    var shouldRefreshReviewQueue = false
                    defer {
                        self.finishTranscriptCorrectionActivity(
                            meetingID: meeting.id,
                            operationToken: operationToken
                        )
                        if shouldRefreshReviewQueue,
                           self.selectedMeetingID == meeting.id {
                            self.refreshTranscriptReviewForSelectedMeeting()
                        }
                    }
                    do {
                        let recovery = try await coordinator.recoverIfNeeded(meeting: meeting)
                        if case let .regenerated(result) = recovery {
                            await self.transcriptCorrectionStoreReconciliationGate(meeting.id)
                            let didPresentResult = try self.applyTranscriptCorrectionResult(
                                result,
                                meeting: meeting,
                                operationToken: operationToken
                            )
                            if didPresentResult {
                                self.transcriptReviewStatus = "Interrupted correction recovered"
                            } else if self.selectedMeetingID == meeting.id {
                                self.transcriptReviewStatus = "Correction recovered; newer visible transcript state was preserved"
                            }
                        } else {
                            shouldRefreshReviewQueue = true
                        }
                    } catch {
                        if self.shouldPresentTranscriptCorrectionStatus(
                            meetingID: selectedMeetingID,
                            generation: selectionGeneration,
                            operationToken: operationToken
                        ) {
                            self.transcriptReviewStatus = "Correction recovery needs attention"
                        }
                        self.logger.error("Transcript correction recovery failed")
                    }
                }
                return
            }
            let queue = try TranscriptReviewRepository(
                bundleStore: meetingContextBundleStore
            ).loadIfPresent(meetingID: selectedMeetingID)
            guard isCurrentTranscriptSelection(
                meetingID: selectedMeetingID,
                generation: selectionGeneration
            ) else { return }
            transcriptReviewQueue = queue
            guard let queue else {
                transcriptReviewStatus = "Provider evidence is not available for this transcript"
                return
            }
            if !queue.evidenceComplete {
                transcriptReviewStatus = "Review evidence is incomplete; no clean result is claimed"
            } else if queue.pendingItems.isEmpty {
                transcriptReviewStatus = "No review issues found"
            } else {
                transcriptReviewStatus = "\(queue.pendingItems.count) transcript issue(s) need attention"
            }
        } catch {
            transcriptReviewQueue = nil
            transcriptReviewStatus = "Transcript review queue could not be opened"
            logger.error("Transcript review queue load failed")
        }
    }

    private func applyProcessedRecording(_ result: RecordingProcessingResult) {
        meetings.removeAll { $0.id == result.record.id }
        meetings.insert(result.record, at: 0)
        transcriptEditMeetingsByID[result.record.id] = result.searchMeeting

        let history = TranscriptEditHistory(meetingID: result.record.id)
        transcriptEditSessionCache[result.record.id] = TranscriptEditSession(
            meeting: result.searchMeeting,
            draft: TranscriptEditDraft(transcript: result.transcription.transcript, history: history),
            history: history
        )
        captureHealthReport = result.capture.healthReport
        playbackTimeline = TranscriptPlaybackTimelineService().buildTimeline(
            transcript: result.transcription.transcript,
            audioChunks: result.capture.records,
            bookmarks: result.bookmarks
        )
        playbackSessionState = transcriptPlaybackSessionService?.initialState(for: playbackTimeline)
            ?? TranscriptPlaybackSessionState.idle(for: playbackTimeline)
        selectedMeetingID = result.record.id
        transcriptAskStatus = "Transcript ready from latest recording. Ask a question or copy the visible transcript."
        showWorkspace(.understand)
    }

    private func applyImportedLocalRecording(_ result: LocalRecordingImportResult) {
        meetings.removeAll { $0.id == result.record.id }
        meetings.insert(result.record, at: 0)
        transcriptEditMeetingsByID[result.record.id] = result.searchMeeting

        let history = TranscriptEditHistory(meetingID: result.record.id)
        transcriptEditSessionCache[result.record.id] = TranscriptEditSession(
            meeting: result.searchMeeting,
            draft: TranscriptEditDraft(transcript: result.transcript, history: history),
            history: history
        )
        playbackTimeline = TranscriptPlaybackTimelineService().buildTimeline(
            transcript: result.transcript,
            audioChunks: result.audioChunks
        )
        playbackSessionState = transcriptPlaybackSessionService?.initialState(for: playbackTimeline)
            ?? TranscriptPlaybackSessionState.idle(for: playbackTimeline)
        selectedMeetingID = result.record.id
        transcriptAskStatus = "Imported recording transcript. Ask a question or copy the visible transcript."
        showWorkspace(.understand)
    }

    private var selectedLocalRecordingSample: LocalRecordingSampleCandidate? {
        guard let selectedLocalRecordingSampleID else { return nil }
        return localRecordingSamples.first { $0.id == selectedLocalRecordingSampleID }
    }

    private struct LocalRecordingFilePair {
        var transcriptURL: URL
        var audioURL: URL
        var title: String
    }

    private func localRecordingPairs(from urls: [URL]) -> [LocalRecordingFilePair] {
        let fileURLs = urls.filter { url in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue
            else {
                return false
            }
            return true
        }
        let transcriptURLs = fileURLs
            .filter { LocalRecordingImportService.supportedTranscriptExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let audioURLs = fileURLs
            .filter { LocalRecordingImportService.supportedAudioExtensions.contains($0.pathExtension.lowercased()) }
            .sorted(by: preferredLocalRecordingAudioSort)

        if transcriptURLs.count == 1, audioURLs.count == 1 {
            return [
                LocalRecordingFilePair(
                    transcriptURL: transcriptURLs[0],
                    audioURL: audioURLs[0],
                    title: Self.localRecordingTitle(from: transcriptURLs[0])
                )
            ]
        }

        let audioByTimestamp = Dictionary(grouping: audioURLs) { Self.localRecordingTimestampKey(from: $0) }
        return transcriptURLs.compactMap { transcriptURL in
            guard let key = Self.localRecordingTimestampKey(from: transcriptURL),
                  let audioURL = audioByTimestamp[key]?.sorted(by: preferredLocalRecordingAudioSort).first
            else {
                return nil
            }
            return LocalRecordingFilePair(
                transcriptURL: transcriptURL,
                audioURL: audioURL,
                title: Self.localRecordingTitle(from: transcriptURL)
            )
        }
    }

    private func preferredLocalRecordingAudioSort(_ lhs: URL, _ rhs: URL) -> Bool {
        let lhsScore = Self.localRecordingAudioPreferenceScore(lhs)
        let rhsScore = Self.localRecordingAudioPreferenceScore(rhs)
        if lhsScore != rhsScore {
            return lhsScore > rhsScore
        }
        return lhs.lastPathComponent < rhs.lastPathComponent
    }

    private static func localRecordingTimestampKey(from url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent
        guard let match = name.range(
            of: #"\d{8} \d{4}"#,
            options: .regularExpression
        ) else {
            return nil
        }
        return String(name[match])
    }

    private static func localRecordingTitle(from transcriptURL: URL) -> String {
        transcriptURL
            .deletingPathExtension()
            .lastPathComponent
            .replacingOccurrences(of: " Transcription 1", with: "")
            .replacingOccurrences(of: " Transcription", with: "")
    }

    private static func localRecordingAudioPreferenceScore(_ url: URL) -> Int {
        let name = url.lastPathComponent.lowercased()
        var score = 0
        if name.contains("voice chat") {
            score += 100
        }
        if url.pathExtension.lowercased() == "mp3" {
            score += 10
        }
        return score
    }

    private func applySelectedLocalRecordingSamplePaths() {
        guard let sample = selectedLocalRecordingSample else { return }
        localRecordingTranscriptPath = sample.transcriptURL.path
        localRecordingAudioPath = sample.audioURL.path
    }

    private func applyRecoveredRecordingImport(_ result: RecoveredRecordingImportResult) {
        meetings.removeAll { $0.id == result.record.id }
        meetings.insert(result.record, at: 0)
        transcriptEditMeetingsByID[result.record.id] = result.searchMeeting

        let history = TranscriptEditHistory(meetingID: result.record.id)
        transcriptEditSessionCache[result.record.id] = TranscriptEditSession(
            meeting: result.searchMeeting,
            draft: TranscriptEditDraft(transcript: result.transcription.transcript, history: history),
            history: history
        )
        playbackTimeline = TranscriptPlaybackTimelineService().buildTimeline(
            transcript: result.transcription.transcript,
            audioChunks: result.audioChunks,
            bookmarks: result.bookmarks
        )
        playbackSessionState = transcriptPlaybackSessionService?.initialState(for: playbackTimeline)
            ?? TranscriptPlaybackSessionState.idle(for: playbackTimeline)
        selectedMeetingID = result.record.id
        transcriptAskStatus = "Recovered recording transcript. Ask a question or copy the visible transcript."
        showWorkspace(.understand)
    }

    private func refreshSelectedPlaybackBookmarks(meetingID: UUID) {
        guard let meetingContextBundleStore else {
            clearSelectedPlaybackBookmarks(
                meetingID: meetingID,
                status: "Marked moments unavailable: encrypted library is unavailable"
            )
            return
        }
        let transcript = currentEditedTranscript()
        guard transcript.meetingID == meetingID else {
            clearSelectedPlaybackBookmarks(
                meetingID: meetingID,
                status: "Marked moments unavailable: selected transcript belongs to another meeting"
            )
            return
        }
        let chunkWriter = EncryptedAudioChunkWriter(bundleStore: meetingContextBundleStore)
        let chunks = TrackKind.allCases.flatMap { track in
            (try? chunkWriter.readCheckpoint(meetingID: meetingID, track: track).chunks) ?? []
        }
        do {
            let manifest = try meetingContextBundleStore.readManifest(meetingID: meetingID)
            guard try meetingContextBundleStore.artifactExists(
                meetingID: meetingID,
                relativePath: manifest.sessionMetadataPath
            ) else {
                clearSelectedPlaybackBookmarks(
                    meetingID: meetingID,
                    transcript: transcript,
                    chunks: chunks,
                    status: "Marked moments unavailable: encrypted metadata is missing"
                )
                return
            }
            let metadata = try meetingContextBundleStore.readJSONArtifact(
                RecordingSessionMetadata.self,
                meetingID: meetingID,
                relativePath: manifest.sessionMetadataPath,
                purpose: RecordingSessionMetadata.purpose
            ).validated(expectedMeetingID: meetingID)
            playbackTimeline = TranscriptPlaybackTimelineService().buildTimeline(
                transcript: transcript,
                audioChunks: chunks,
                bookmarks: metadata.bookmarks
            )
            playbackSessionState = transcriptPlaybackSessionService?.initialState(for: playbackTimeline)
                ?? TranscriptPlaybackSessionState.idle(for: playbackTimeline)
            selectedBookmarkStatus = metadata.bookmarks.isEmpty
                ? "No marked moments in the selected meeting"
                : "Loaded \(metadata.bookmarks.count) marked moment\(metadata.bookmarks.count == 1 ? "" : "s")"
        } catch RecordingSessionMetadataValidationError.metadataMeetingMismatch {
            clearSelectedPlaybackBookmarks(
                meetingID: meetingID,
                transcript: transcript,
                chunks: chunks,
                status: "Marked moments unavailable: metadata belongs to another meeting"
            )
        } catch {
            clearSelectedPlaybackBookmarks(
                meetingID: meetingID,
                transcript: transcript,
                chunks: chunks,
                status: "Marked moments unavailable: encrypted metadata is corrupt"
            )
            logger.info("Selected meeting bookmarks are unavailable")
        }
    }

    private func clearSelectedPlaybackBookmarks(
        meetingID: UUID,
        transcript: MeetingTranscript? = nil,
        chunks: [AudioChunkRecord] = [],
        status: String
    ) {
        let safeTranscript: MeetingTranscript
        if let transcript, transcript.meetingID == meetingID {
            safeTranscript = transcript
        } else {
            safeTranscript = MeetingTranscript(
                meetingID: meetingID,
                localeIdentifier: Locale.current.identifier,
                segments: []
            )
        }
        playbackTimeline = TranscriptPlaybackTimelineService().buildTimeline(
            transcript: safeTranscript,
            audioChunks: chunks,
            bookmarks: []
        )
        playbackSessionState = transcriptPlaybackSessionService?.initialState(for: playbackTimeline)
            ?? TranscriptPlaybackSessionState.idle(for: playbackTimeline)
        selectedBookmarkStatus = status
    }

    private func removeMeetingFromWorkspace(meetingID: UUID) {
        let currentSelection = selectedMeetingID
        meetings.removeAll { $0.id == meetingID }
        transcriptEditMeetingsByID.removeValue(forKey: meetingID)
        transcriptEditSessionCache.removeValue(forKey: meetingID)
        transcriptQuestionHistoryCache.removeValue(forKey: meetingID)
        transcriptConversationTurns.removeAll()

        if currentSelection == meetingID || selectedMeetingID == nil {
            selectedMeetingID = meetings.first?.id
            if selectedMeetingID == nil {
                clearSelectedTranscriptWorkspace(status: "Select or import a recording before asking Agent")
            }
        } else {
            objectWillChange.send()
        }
    }

    private func clearSelectedTranscriptWorkspace(
        meetingID: UUID = UUID(),
        status: String,
        bookmarkStatus: String = "No marked moments loaded"
    ) {
        let transcript = MeetingTranscript(
            meetingID: meetingID,
            localeIdentifier: Locale.current.identifier,
            segments: []
        )
        let history = TranscriptEditHistory(meetingID: meetingID)
        transcriptEditDraft = TranscriptEditDraft(transcript: transcript, history: history)
        transcriptEditHistory = history
        playbackTimeline = TranscriptPlaybackTimelineService().buildTimeline(transcript: transcript, audioChunks: [])
        playbackSessionState = TranscriptPlaybackSessionState(
            meetingID: meetingID,
            transportState: .idle,
            statusMessage: status
        )
        transcriptEditStatus = "No meeting selected"
        selectedBookmarkStatus = bookmarkStatus
        transcriptRestoreNeedsConfirmation = false
        resetTranscriptAskResponse(status: status)
    }

    private func currentEditedTranscript() -> MeetingTranscript {
        MeetingTranscript(
            meetingID: transcriptEditDraft.meetingID,
            transcriptVersion: transcriptEditDraft.currentVersion,
            providerConfigurationVersion: transcriptEditDraft.providerConfigurationVersion,
            localeIdentifier: transcriptEditDraft.localeIdentifier,
            generatedAt: transcriptEditDraft.generatedAt,
            editedAt: transcriptEditDraft.editedAt,
            segments: transcriptEditDraft.segments.map { segment in
                TranscriptSegment(
                    id: segment.id,
                    speakerName: segment.effectiveEditedSpeakerName,
                    trackKind: segment.trackKind,
                    startTime: segment.startTime,
                    endTime: segment.endTime,
                    text: segment.trimmedEditedText,
                    confidence: segment.confidence,
                    isFinal: true,
                    reviewEvidence: segment.reviewEvidence
                )
            }
        )
    }

    private func resetTranscriptAskResponse(status: String) {
        transcriptAskAnswerDraft = ""
        transcriptAskEvidence = []
        transcriptConversationTurns = []
        transcriptAskStatus = status
    }

    private func loadTranscriptQuestionHistoryForSelectedMeeting(
        defaultStatus: String,
        allowDuringCorrection: Bool = false
    ) {
        guard let meetingID = selectedMeetingID else {
            resetTranscriptAskResponse(status: defaultStatus)
            return
        }
        guard allowDuringCorrection || transcriptCorrectionActivities[meetingID] == nil else {
            resetTranscriptAskResponse(
                status: "Agent is unavailable while transcript correction is being saved or recovered."
            )
            return
        }

        let history: TranscriptQuestionHistory
        if let cached = transcriptQuestionHistoryCache[meetingID] {
            history = cached
        } else if let transcriptQuestionHistoryService {
            do {
                history = try transcriptQuestionHistoryService.load(meetingID: meetingID)
                transcriptQuestionHistoryCache[meetingID] = history
            } catch {
                resetTranscriptAskResponse(status: "Transcript answer history unavailable")
                logger.error("Transcript question history load failed")
                return
            }
        } else {
            history = TranscriptQuestionHistory(meetingID: meetingID)
        }

        transcriptConversationTurns = history.turns.map(Self.conversationTurn)
        transcriptAskAnswerDraft = transcriptConversationTurns.first?.answerDraft ?? ""
        transcriptAskEvidence = transcriptConversationTurns.first?.evidence ?? []
        transcriptAskStatus = transcriptConversationTurns.isEmpty
            ? defaultStatus
            : "Loaded \(transcriptConversationTurns.count) saved transcript answer(s)"
    }

    private func persistTranscriptQuestionHistory(meetingID: UUID) {
        guard !transcriptConversationTurns.isEmpty else { return }
        let transcript = currentEditedTranscript()
        let history = TranscriptQuestionHistory(
            meetingID: meetingID,
            transcriptVersion: transcript.transcriptVersion,
            transcriptDigest: (try? LocalFinalTranscriptionService.transcriptDigest(transcript)) ?? "unavailable",
            turns: transcriptConversationTurns.map(Self.questionTurn)
        )
        transcriptQuestionHistoryCache[meetingID] = history
        guard let transcriptQuestionHistoryService else { return }

        do {
            transcriptQuestionHistoryCache[meetingID] = try transcriptQuestionHistoryService.save(history)
        } catch {
            transcriptAskStatus = "Transcript answer history could not be saved"
            logger.error("Transcript question history save failed")
        }
    }

    private static func conversationTurn(from turn: TranscriptQuestionTurn) -> TranscriptConversationTurn {
        TranscriptConversationTurn(
            id: turn.id,
            createdAt: turn.createdAt,
            question: turn.question,
            answerDraft: turn.answerDraft,
            evidence: turn.evidence
        )
    }

    private static func questionTurn(from turn: TranscriptConversationTurn) -> TranscriptQuestionTurn {
        TranscriptQuestionTurn(
            id: turn.id,
            createdAt: turn.createdAt,
            question: turn.question,
            answerDraft: turn.answerDraft,
            evidence: turn.evidence
        )
    }

    private func stopPlaybackIfSelectionDoesNotMatchTimeline() {
        guard !playbackMatchesSelectedMeeting else { return }
        guard playbackSessionState.transportState == .playing
                || playbackSessionState.transportState == .paused else {
            return
        }

        if let transcriptPlaybackSessionService,
           let stoppedState = try? transcriptPlaybackSessionService.stop(playbackSessionState) {
            playbackSessionState = stoppedState
        } else {
            playbackSessionState = TranscriptPlaybackSessionState(
                meetingID: playbackTimeline.meetingID,
                selectedCueID: nil,
                currentTime: 0,
                transportState: .stopped,
                statusMessage: "Playback stopped after meeting selection changed"
            )
        }
    }

    private func failedPlaybackState(cueID: UUID?, message: String) -> TranscriptPlaybackSessionState {
        TranscriptPlaybackSessionState(
            meetingID: playbackTimeline.meetingID,
            selectedCueID: cueID,
            currentTime: playbackSessionState.currentTime,
            transportState: .failed,
            statusMessage: message
        )
    }

    private func playbackErrorMessage(_ error: Error) -> String {
        guard let playbackError = error as? TranscriptPlaybackSessionError else {
            return "Playback failed"
        }

        switch playbackError {
        case .timelineNotPlayable:
            return "No playable audio cues"
        case .cueNotFound:
            return "Playback cue unavailable"
        case .cueMissingAudio:
            return "Cue audio needs repair"
        case .audioDataUnavailable:
            return "Audio chunk unavailable"
        case .audioEngineFailed:
            return "Audio playback failed"
        case .invalidRange:
            return "Playback range is invalid"
        case .rangeHasNoTranscriptCue:
            return "Transcript range unavailable"
        case .rangeHasAudioGap:
            return "Audio range needs repair"
        }
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded(.down)))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func refreshTranscriptEditStatus(defaultStatus: String) {
        if transcriptEditDraft.hasChanges {
            transcriptEditStatus = "\(transcriptEditDraft.changedSegmentCount) unsaved transcript edit(s)"
        } else {
            transcriptEditStatus = defaultStatus
        }
    }

    private func appendTranscriptEditAuditRow(
        meetingID: UUID,
        version: Int,
        editedSegmentCount: Int
    ) {
        let row = PrivacyAuditReviewRow(
            id: UUID(),
            occurredAt: Date(),
            action: .transcriptEdit,
            meetingID: meetingID,
            metadata: [
                "editedSegmentCount": "\(editedSegmentCount)",
                "version": "\(version)"
            ]
        )
        privacyAuditReview.rows.insert(row, at: 0)
        privacyAuditReview.counts[.transcriptEdit, default: 0] += 1
        privacyAuditReview.latestOccurredAt = row.occurredAt
    }

    private func appendExportAuditRow(meetingID: UUID, formats: [MeetingExportFormat]) {
        let row = PrivacyAuditReviewRow(
            id: UUID(),
            occurredAt: Date(),
            action: .exportPackage,
            meetingID: meetingID,
            metadata: [
                "formats": formats.map(\.rawValue).joined(separator: ","),
                "fileCount": "\(formats.count)"
            ]
        )
        privacyAuditReview.rows.insert(row, at: 0)
        privacyAuditReview.counts[.exportPackage, default: 0] += 1
        privacyAuditReview.latestOccurredAt = row.occurredAt
    }

    private func appendShareAuditRow(
        meetingID: UUID,
        destination: MeetingShareDestination,
        formats: [MeetingExportFormat]
    ) {
        let row = PrivacyAuditReviewRow(
            id: UUID(),
            occurredAt: Date(),
            action: .sharePrepare,
            meetingID: meetingID,
            metadata: [
                "destination": destination.rawValue,
                "formats": formats.map(\.rawValue).joined(separator: ","),
                "fileCount": "\(formats.count)"
            ]
        )
        privacyAuditReview.rows.insert(row, at: 0)
        privacyAuditReview.counts[.sharePrepare, default: 0] += 1
        privacyAuditReview.latestOccurredAt = row.occurredAt
    }

    private func appendSystemIntegrationAuditRow(_ review: MeetingSystemIntegrationReview) {
        let row = PrivacyAuditReviewRow(
            id: UUID(),
            occurredAt: Date(),
            action: .systemIntegrationPrepare,
            meetingID: review.meetingID,
            metadata: PrivacyAuditReviewService.filteredMetadata(review.auditMetadata)
        )
        privacyAuditReview.rows.insert(row, at: 0)
        privacyAuditReview.counts[.systemIntegrationPrepare, default: 0] += 1
        privacyAuditReview.latestOccurredAt = row.occurredAt
    }

    private func appendSystemIntegrationConfirmAuditRow(_ result: MeetingSystemIntegrationExecutionResult) {
        let row = PrivacyAuditReviewRow(
            id: UUID(),
            occurredAt: Date(),
            action: .systemIntegrationConfirm,
            meetingID: result.meetingID,
            metadata: PrivacyAuditReviewService.filteredMetadata(result.auditMetadata)
        )
        privacyAuditReview.rows.insert(row, at: 0)
        privacyAuditReview.counts[.systemIntegrationConfirm, default: 0] += 1
        privacyAuditReview.latestOccurredAt = row.occurredAt
    }

    private func appendRetentionAuditRow(candidate: RetentionCleanupCandidate, policy: RetentionPolicy) {
        let row = PrivacyAuditReviewRow(
            id: UUID(),
            occurredAt: Date(),
            action: .retentionDelete,
            meetingID: candidate.meetingID,
            metadata: [
                "ageDays": "\(candidate.ageDays)",
                "retentionDays": "\(policy.retentionDays)"
            ]
        )
        privacyAuditReview.rows.insert(row, at: 0)
        privacyAuditReview.counts[.retentionDelete, default: 0] += 1
        privacyAuditReview.latestOccurredAt = row.occurredAt
    }

    private func appendManualDeleteAuditRow(meetingID: UUID, reason: MeetingDeleteReason) {
        let row = PrivacyAuditReviewRow(
            id: UUID(),
            occurredAt: Date(),
            action: .meetingDelete,
            meetingID: meetingID,
            metadata: ["reason": reason.rawValue]
        )
        privacyAuditReview.rows.insert(row, at: 0)
        privacyAuditReview.counts[.meetingDelete, default: 0] += 1
        privacyAuditReview.latestOccurredAt = row.occurredAt
    }

    private func retentionPlanStatus(candidateCount: Int) -> String {
        if candidateCount == 0 {
            return "No expired recording bundles found"
        }
        return "\(candidateCount) expired recording \(candidateCount == 1 ? "bundle" : "bundles") ready for review"
    }

    private static func makeTranscriptEditRuntime(
        libraryRoot: URL?,
        keyProvider: any SymmetricKeyProvider,
        playbackAudioEngine: (any TranscriptAudioEngine)?,
        audioInputDeviceProvider: any AudioInputDeviceProviding,
        recordingSessionMetadataCreator: (any RecordingSessionMetadataCreating)?,
        captureRuntimeMode: MeetingVaultCaptureRuntimeMode,
        finalTranscriptionRuntimeMode: MeetingVaultFinalTranscriptionRuntimeMode,
        localTranscriptionProvider: any LocalTranscriptionProviding,
        localModelRuntime: (any LocalModelRuntimeSessionProviding)?,
        intelligenceRuntimeMode: MeetingVaultIntelligenceRuntimeMode,
        coreAudioTapCapturer: (any CoreAudioTapCapturing)?,
        selectedMicrophoneCapturer: (any SelectedMicrophoneAudioCapturing)?,
        screenCaptureKitCapturer: (any ScreenCaptureKitSystemAudioCapturing)?,
        transcriptionPrivacyBoundary: TranscriptionPrivacyBoundary,
        transcriptCorrectionRegenerationGate: @escaping @Sendable (UUID) async throws -> Void,
        includeSampleData: Bool
    ) -> Result<TranscriptEditRuntime, Error> {
        do {
            let root = try libraryRoot ?? defaultLibraryRoot()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

            let vault = AESGCMDataVault(keyProvider: keyProvider)
            let bundleStore = EncryptedMeetingBundleStore(rootDirectory: root, vault: vault)
            let chunkWriter = EncryptedAudioChunkWriter(bundleStore: bundleStore)
            try removeLegacyPlaintextSearchIndex(from: root)
            let searchIndex = try SQLiteSearchIndex(inMemory: ())
            let repository = MeetingLibraryRepository(bundleStore: bundleStore, searchIndex: searchIndex)
            let auditWriter = PrivacyAuditLogWriter(logURL: root.appendingPathComponent("privacy-audit.jsonl"))
            let exportRoot = root.appendingPathComponent("Exports", isDirectory: true)
            if includeSampleData, try repository.loadSnapshot().records.isEmpty {
                for entry in SampleData.libraryEntries {
                    try repository.save(entry)
                    if let summary = entry.record.summary {
                        try bundleStore.writeJSONArtifact(
                            MeetingIntelligenceArtifact(
                                meetingID: entry.record.id,
                                providerID: "sample-data",
                                generatedAt: entry.record.startedAt,
                                summary: summary
                            ),
                            meetingID: entry.record.id,
                            relativePath: MeetingIntelligenceArtifact.summaryRelativePath,
                            purpose: MeetingIntelligenceArtifact.summaryPurpose
                        )
                    }
                }
            }
            let snapshot = try repository.loadSnapshot()

            let service = TranscriptEditSessionService(
                bundleStore: bundleStore,
                searchIndex: searchIndex,
                auditWriter: auditWriter
            )
            let meetingExportService = MeetingExportService(
                bundleStore: bundleStore,
                auditWriter: auditWriter
            )
            let meetingSharePreparationService = MeetingSharePreparationService(
                auditWriter: auditWriter,
                versionGate: TranscriptArtifactVersionGate(bundleStore: bundleStore)
            )
            let meetingDeleteService = MeetingDeleteService(
                bundleStore: bundleStore,
                auditWriter: auditWriter,
                searchIndex: searchIndex
            )
            let retentionCleanupService = RetentionCleanupService(
                bundleStore: bundleStore,
                auditWriter: auditWriter,
                searchIndex: searchIndex
            )
            let captureEngine: any CaptureRecordingEngine
            let captureSources: [CaptureSource]
            switch captureRuntimeMode {
            case .mock:
                captureSources = SampleData.sources
                captureEngine = MockCaptureRecordingEngine(
                    sources: captureSources,
                    chunks: SampleData.demoCapturedChunks,
                    healthReport: SampleData.captureHealthReport,
                    emitsSyntheticFramesDuringActiveRecording:
                        ProcessInfo.processInfo.environment["MEETINGVAULT_MOCK_ACTIVE_FRAMES"] == "1"
                )
            case .systemAndMicrophone:
                let source = Self.systemAndMicrophoneCaptureSource
                captureSources = [source]
                captureEngine = SystemAndMicrophoneCaptureEngine(
                    source: source,
                    systemSourceID: Self.coreAudioTapCaptureSource.id,
                    microphoneSourceID: Self.selectedMicrophoneCaptureSource.id,
                    systemEngine: CoreAudioTapCaptureEngine(
                        source: Self.coreAudioTapCaptureSource,
                        capturer: coreAudioTapCapturer ?? CoreAudioProcessTapCapturer()
                    ),
                    microphoneEngine: AVFoundationSelectedMicrophoneCaptureEngine(
                        source: Self.selectedMicrophoneCaptureSource,
                        capturer: selectedMicrophoneCapturer ?? AVFoundationSelectedMicrophoneAudioCapturer()
                    )
                )
            case .coreAudio:
                let source = Self.coreAudioTapCaptureSource
                captureSources = [source]
                captureEngine = CoreAudioTapCaptureEngine(
                    source: source,
                    capturer: coreAudioTapCapturer ?? CoreAudioProcessTapCapturer()
                )
            case .selectedMicrophone:
                let source = Self.selectedMicrophoneCaptureSource
                captureSources = [source]
                captureEngine = AVFoundationSelectedMicrophoneCaptureEngine(
                    source: source,
                    capturer: selectedMicrophoneCapturer ?? AVFoundationSelectedMicrophoneAudioCapturer()
                )
            case .screenCaptureKit:
                let source = Self.screenCaptureKitCaptureSource
                captureSources = [source]
                captureEngine = ScreenCaptureKitSystemAudioCaptureEngine(
                    source: source,
                    capturer: screenCaptureKitCapturer ?? ScreenCaptureKitSystemAudioCapturer()
                )
            }
            let captureService = CaptureRecordingService(
                engine: captureEngine,
                chunkWriter: chunkWriter,
                audioInputDeviceProvider: audioInputDeviceProvider
            )
            let compatibilityTranscriptionService = FinalTranscriptionService(
                engine: makeFinalTranscriptionEngine(
                    mode: finalTranscriptionRuntimeMode,
                    privacyBoundary: transcriptionPrivacyBoundary,
                    localTranscriptionProvider: localTranscriptionProvider
                ),
                bundleStore: bundleStore,
                chunkWriter: chunkWriter,
                searchIndex: searchIndex
            )
            let transcriptionService: any FinalTranscriptionServicing
            if finalTranscriptionRuntimeMode == .local {
                let localService: any FinalTranscriptionServicing
                if let localModelRuntime {
                    localService = LocalFinalTranscriptionCompositionResolver.production(
                        runtime: localModelRuntime,
                        bundleStore: bundleStore,
                        chunkWriter: chunkWriter,
                        searchIndex: searchIndex,
                    )
                } else {
                    // Test/demo compositions may inject a frame provider without
                    // a model lifecycle. Preserve that explicit composition;
                    // production supplies the shared lifecycle runtime.
                    localService = compatibilityTranscriptionService
                }
                let appleService = FinalTranscriptionService(
                    engine: AppleSpeechFinalTranscriptionEngine(
                        privacyBoundary: transcriptionPrivacyBoundary
                    ),
                    bundleStore: bundleStore,
                    chunkWriter: chunkWriter,
                    searchIndex: searchIndex
                )
                transcriptionService = PrivacyResolvedFinalTranscriptionService(
                    boundary: transcriptionPrivacyBoundary,
                    local: localService,
                    apple: appleService
                )
            } else {
                transcriptionService = compatibilityTranscriptionService
            }
            let intelligenceService = MeetingIntelligenceService(
                provider: makeMeetingIntelligenceProvider(mode: intelligenceRuntimeMode),
                bundleStore: bundleStore
            )
            let defaultMetadataService = RecordingSessionMetadataService(bundleStore: bundleStore)
            let metadataCreator = recordingSessionMetadataCreator ?? defaultMetadataService
            let processingService = RecordingProcessingService(
                captureService: captureService,
                transcriptionService: transcriptionService,
                intelligenceService: intelligenceService,
                repository: repository,
                bundleStore: bundleStore,
                chunkWriter: chunkWriter,
                sessionMetadataService: metadataCreator
            )
            let recoveryService = RecordingRecoveryService(
                bundleStore: bundleStore,
                chunkWriter: chunkWriter
            )
            let playbackSessionService = TranscriptPlaybackSessionService(
                chunkWriter: chunkWriter,
                audioEngine: playbackAudioEngine ?? AVFoundationTranscriptAudioEngine()
            )
            let transcriptCorrectionCoordinator = TranscriptCorrectionCoordinator(
                bundleStore: bundleStore,
                searchIndex: searchIndex,
                intelligenceService: intelligenceService,
                chunkWriter: chunkWriter,
                auditWriter: auditWriter,
                beforeDerivedArtifactRegeneration: transcriptCorrectionRegenerationGate
            )
            let recoveredRecordingImportService = RecoveredRecordingImportService(
                recoveryService: recoveryService,
                transcriptionService: transcriptionService,
                intelligenceService: intelligenceService,
                repository: repository,
                chunkWriter: chunkWriter
            )
            let localRecordingImportService = LocalRecordingImportService(
                repository: repository,
                chunkWriter: chunkWriter
            )
            let transcriptQuestionHistoryService = TranscriptQuestionHistoryService(bundleStore: bundleStore)
            return .success(TranscriptEditRuntime(
                bundleStore: bundleStore,
                service: service,
                transcriptQuestionHistoryService: transcriptQuestionHistoryService,
                recordingProcessingService: processingService,
                recordingSessionMetadataManager: metadataCreator as? any RecordingSessionMetadataManaging,
                meetingIntelligenceService: intelligenceService,
                recordingRecoveryService: recoveryService,
                recoveredRecordingImportService: recoveredRecordingImportService,
                localRecordingImportService: localRecordingImportService,
                meetingDeleteService: meetingDeleteService,
                meetingExportService: meetingExportService,
                meetingSharePreparationService: meetingSharePreparationService,
                retentionCleanupService: retentionCleanupService,
                exportRoot: exportRoot,
                playbackSessionService: playbackSessionService,
                transcriptCorrectionCoordinator: transcriptCorrectionCoordinator,
                records: snapshot.records,
                sessionsByMeetingID: snapshot.editSessionsByMeetingID,
                meetingsByID: snapshot.searchMeetingsByID,
                captureSources: captureSources,
                recoveredRecordings: try recoveryService.scanRecoverableBundles(),
                privacyAuditReview: SampleData.privacyAuditReview
            ))
        } catch {
            return .failure(error)
        }
    }

    private static func removeLegacyPlaintextSearchIndex(from root: URL) throws {
        for name in ["library.sqlite", "library.sqlite-wal", "library.sqlite-shm"] {
            let url = root.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func defaultLibraryRoot() throws -> URL {
        try FileManager.default
            .url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            .appendingPathComponent("MeetingVault", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
    }

    private static let selectedMicrophoneCaptureSource = CaptureSource(
        id: "selected-microphone",
        displayName: "Selected Microphone",
        mode: .microphone,
        isRecommended: true,
        level: 0
    )

    private static let coreAudioTapCaptureSource = CaptureSource(
        id: "coreaudio-system-audio",
        displayName: "Core Audio System Audio",
        mode: .systemAudio,
        isRecommended: true,
        level: 0
    )

    private static let systemAndMicrophoneCaptureSource = CaptureSource(
        id: "system-and-microphone",
        displayName: "Meeting Audio + Selected Microphone",
        mode: .systemAudio,
        isRecommended: true,
        level: 0
    )

    private static let screenCaptureKitCaptureSource = CaptureSource(
        id: "screencapturekit-system-audio",
        displayName: "System Audio",
        mode: .screenCaptureFallback,
        isRecommended: true,
        level: 0
    )
}

private struct TranscriptEditRuntime {
    var bundleStore: EncryptedMeetingBundleStore
    var service: TranscriptEditSessionService
    var transcriptQuestionHistoryService: TranscriptQuestionHistoryService
    var recordingProcessingService: RecordingProcessingService
    var recordingSessionMetadataManager: (any RecordingSessionMetadataManaging)?
    var meetingIntelligenceService: MeetingIntelligenceService
    var recordingRecoveryService: RecordingRecoveryService
    var recoveredRecordingImportService: RecoveredRecordingImportService
    var localRecordingImportService: LocalRecordingImportService
    var meetingDeleteService: MeetingDeleteService
    var meetingExportService: MeetingExportService
    var meetingSharePreparationService: MeetingSharePreparationService
    var retentionCleanupService: RetentionCleanupService
    var exportRoot: URL
    var playbackSessionService: TranscriptPlaybackSessionService
    var transcriptCorrectionCoordinator: TranscriptCorrectionCoordinator
    var records: [MeetingRecord]
    var sessionsByMeetingID: [UUID: TranscriptEditSession]
    var meetingsByID: [UUID: SearchMeeting]
    var captureSources: [CaptureSource]
    var recoveredRecordings: [RecoveredRecordingReport]
    var privacyAuditReview: PrivacyAuditReview
}

private enum RecordingProcessingRuntimeError: Error {
    case unavailable
    case noRetryAvailable
}

private enum LocalRecordingImportRuntimeError: Error {
    case unavailable
    case noSelectedSample
}

enum MeetingVaultLibraryDeleteRuntimeError: Error, Equatable {
    case unavailable
    case noSelectedMeeting
    case bundleMissing
}

private enum RecoveredRecordingImportRuntimeError: Error {
    case unavailable
}

enum MeetingVaultRetentionRuntimeError: Error, Equatable {
    case unavailable
    case invalidPolicy
    case noPlan
    case confirmationRequired
}

private enum MeetingVaultExportRuntimeError: Error {
    case unavailable
    case noSelectedMeeting
    case noFormatsSelected
}

private enum MeetingVaultShareRuntimeError: Error {
    case unavailable
    case noSelectedMeeting
    case noExportPackage
}

private enum MeetingVaultAuditExportRuntimeError: Error {
    case unavailable
}

enum MeetingVaultSystemIntegrationRuntimeError: Error, Equatable {
    case unavailable
    case noSelectedMeeting
    case noMeetingSummary
}

enum MeetingVaultTranscriptRestoreRuntimeError: Error, Equatable {
    case unavailable
    case noSelectedMeeting
    case confirmationRequired
}

private struct RecordingProcessingIntent {
    var title: String
    var startedAt: Date
}

private final class AVFoundationTranscriptAudioEngine: NSObject, TranscriptAudioEngine, AVAudioPlayerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var players: [AVAudioPlayer] = []
    private var playbackDurations: [TimeInterval] = []
    private var currentPlayerIndex = 0
    private var scheduledAdvance: DispatchWorkItem?
    private var playbackGeneration = UUID()

    func play(audioFragments: [TranscriptPlaybackAudioDataFragment], cue _: TranscriptPlaybackCue) throws {
        try playFragments(audioFragments)
    }

    func playRange(audioFragments: [TranscriptPlaybackAudioDataFragment], range _: TranscriptPlaybackRange) throws {
        try playFragments(audioFragments)
    }

    private func playFragments(_ audioFragments: [TranscriptPlaybackAudioDataFragment]) throws {
        let preparedPlayers = try audioFragments.map { fragment in
            let player = try AVAudioPlayer(data: fragment.audioData)
            player.currentTime = min(max(0, fragment.playbackStartOffset), player.duration)
            player.prepareToPlay()
            return player
        }
        let generation = UUID()
        lock.withLock {
            scheduledAdvance?.cancel()
            players.forEach { $0.stop() }
            players = preparedPlayers
            playbackDurations = audioFragments.map(\.playbackDuration)
            currentPlayerIndex = 0
            playbackGeneration = generation
        }
        playCurrentFragment(generation: generation)
    }

    func pause() throws {
        lock.withLock {
            scheduledAdvance?.cancel()
            scheduledAdvance = nil
            guard players.indices.contains(currentPlayerIndex) else { return }
            players[currentPlayerIndex].pause()
        }
    }

    func stop() throws {
        lock.withLock {
            scheduledAdvance?.cancel()
            scheduledAdvance = nil
            players.forEach { $0.stop() }
            players = []
            playbackDurations = []
            currentPlayerIndex = 0
            playbackGeneration = UUID()
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully _: Bool) {
        advance(from: player, generation: lock.withLock { playbackGeneration })
    }

    private func playCurrentFragment(generation: UUID) {
        let prepared: (AVAudioPlayer, TimeInterval, DispatchWorkItem)? = lock.withLock {
            guard playbackGeneration == generation,
                  players.indices.contains(currentPlayerIndex),
                  playbackDurations.indices.contains(currentPlayerIndex)
            else { return nil }
            let player = players[currentPlayerIndex]
            player.delegate = self
            let remainingDuration = max(0, player.duration - player.currentTime)
            let playbackDuration = min(playbackDurations[currentPlayerIndex], remainingDuration)
            guard playbackDuration > 0 else { return nil }
            let workItem = DispatchWorkItem { [weak self, weak player] in
                guard let self, let player else { return }
                self.advance(from: player, generation: generation)
            }
            scheduledAdvance?.cancel()
            scheduledAdvance = workItem
            return (player, playbackDuration, workItem)
        }
        guard let (player, playbackDuration, workItem) = prepared else {
            finishPlayback(generation: generation)
            return
        }
        player.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + playbackDuration, execute: workItem)
    }

    private func advance(from player: AVAudioPlayer, generation: UUID) {
        let action: PlaybackAdvanceAction = lock.withLock {
            guard playbackGeneration == generation,
                  players.indices.contains(currentPlayerIndex),
                  players[currentPlayerIndex] === player
            else { return .ignore }
            scheduledAdvance?.cancel()
            scheduledAdvance = nil
            player.stop()
            currentPlayerIndex += 1
            return players.indices.contains(currentPlayerIndex) ? .playNext : .finish
        }
        switch action {
        case .ignore:
            return
        case .playNext:
            playCurrentFragment(generation: generation)
        case .finish:
            finishPlayback(generation: generation)
        }
    }

    private func finishPlayback(generation: UUID) {
        lock.withLock {
            guard playbackGeneration == generation else { return }
            scheduledAdvance?.cancel()
            scheduledAdvance = nil
            players = []
            playbackDurations = []
            currentPlayerIndex = 0
        }
    }
}

private enum PlaybackAdvanceAction {
    case ignore
    case playNext
    case finish
}

private final class RecordingProcessingCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false

    var isRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }

    func request() {
        lock.lock()
        defer { lock.unlock() }
        requested = true
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        requested = false
    }
}

private extension String {
    var expandingTildePath: String {
        (self as NSString).expandingTildeInPath
    }
}

private extension MeetingShareDestination {
    var displayTitle: String {
        switch self {
        case .systemShareSheet:
            "system share sheet"
        case .finderReveal:
            "Finder reveal"
        case .manualCopy:
            "manual copy"
        }
    }

    var executionTitle: String {
        switch self {
        case .systemShareSheet:
            "System share sheet"
        case .finderReveal:
            "Finder reveal"
        case .manualCopy:
            "Manual copy"
        }
    }
}

private func defaultLocalTranscriptSampleDirectory() -> URL {
    if let path = ProcessInfo.processInfo.environment["MEETINGVAULT_LOCAL_TRANSCRIPT_SAMPLE_DIR"],
       !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return URL(fileURLWithPath: path.expandingTildePath)
    }
    // ponytail: convenience default for Audio Hijack export folders on this machine;
    // env override above is the supported configuration path. Upgrade path: a real
    // user-facing default-folder setting.
    let localTranscriptDirectory = URL(fileURLWithPath: "~/Downloads/hijack".expandingTildePath)
    if FileManager.default.fileExists(atPath: localTranscriptDirectory.path) {
        return localTranscriptDirectory
    }
    return URL(fileURLWithPath: "~/Documents/MeetingVault/Local Transcripts".expandingTildePath)
}

private func defaultLocalRecordingOutputDirectory() -> URL {
    if let path = ProcessInfo.processInfo.environment["MEETINGVAULT_LOCAL_RECORDING_DIR"],
       !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return URL(fileURLWithPath: path.expandingTildePath)
    }
    let localRecordingDirectory = URL(fileURLWithPath: "~/Music/Audio Hijack".expandingTildePath)
    if FileManager.default.fileExists(atPath: localRecordingDirectory.path) {
        return localRecordingDirectory
    }
    return URL(fileURLWithPath: "~/Music/MeetingVault Local Recordings".expandingTildePath)
}

private extension RecordingProcessingStage {
    var failureTitle: String {
        switch self {
        case .preparingBundle:
            "Preparation"
        case .recordingAudio:
            "Capture"
        case .transcribingAudio:
            "Transcription"
        case .generatingIntelligence:
            "Intelligence"
        case .savingLibrary:
            "Library save"
        case .finished:
            "Processing"
        }
    }
}

private struct DemoLiveTranscriptionProvider: LiveTranscriptionProviding {
    let id = "demo-live-transcription"

    func events(for context: LiveTranscriptionContext) -> AsyncThrowingStream<LiveTranscriptionEvent, Error> {
        AsyncThrowingStream { continuation in
            let inputName = context.microphoneDeviceName ?? "microphone"
            continuation.yield(.status("Live transcript preview active on \(inputName)"))
            continuation.yield(
                .partial(
                    TranscriptSegment(
                        speakerName: "You",
                        trackKind: .microphone,
                        startTime: 0,
                        endTime: 4,
                        text: "Listening on \(inputName)...",
                        confidence: 0.52,
                        isFinal: false
                    )
                )
            )
            continuation.yield(
                .partial(
                    TranscriptSegment(
                        speakerName: context.sourceName,
                        trackKind: .remoteSystem,
                        startTime: 4,
                        endTime: 9,
                        text: "Live transcript preview will firm up during the final pass.",
                        confidence: 0.48,
                        isFinal: false
                    )
                )
            )
            continuation.yield(
                .partial(
                    TranscriptSegment(
                        speakerName: "You",
                        trackKind: .microphone,
                        startTime: 9,
                        endTime: 13,
                        text: "Capturing local audio and preparing near-live transcript context...",
                        confidence: 0.46,
                        isFinal: false
                    )
                )
            )
            continuation.finish()
        }
    }
}

private final class DemoTranscriptionEngine: TranscriptionEngine, @unchecked Sendable {
    let id = "demo-transcription"
    let supportsRealtime = false

    func transcribe(_ request: TranscriptionRequest) async throws -> [TranscriptSegment] {
        if request.audioChunkPath.contains(TrackKind.microphone.rawValue) {
            let id = UUID()
            let evidence = try TranscriptSegmentEvidence(
                segmentID: id,
                trackKind: .microphone,
                startTime: 13,
                endTime: 20,
                confidence: 0.62,
                speakerConfidence: 0.88,
                overlapsSpeech: false,
                reconstructedFromPreviewGap: false,
                providerConfigurationVersion: "legacy"
            )
            return [
                TranscriptSegment(
                    id: id,
                    speakerName: "You",
                    trackKind: .microphone,
                    startTime: 13,
                    endTime: 20,
                    text: "I will prepare the notarized build checklist and send it for review.",
                    confidence: 0.62,
                    isFinal: true,
                    reviewEvidence: evidence
                )
            ]
        }

        let id = UUID()
        let evidence = try TranscriptSegmentEvidence(
            segmentID: id,
            trackKind: .remoteSystem,
            startTime: 4,
            endTime: 12,
            confidence: 0.94,
            speakerConfidence: 0.92,
            overlapsSpeech: false,
            reconstructedFromPreviewGap: false,
            providerConfigurationVersion: "legacy"
        )
        return [
            TranscriptSegment(
                id: id,
                speakerName: "Anna",
                trackKind: .remoteSystem,
                startTime: 4,
                endTime: 12,
                text: "The beta candidate can ship after privacy review.",
                confidence: 0.94,
                isFinal: true,
                reviewEvidence: evidence
            )
        ]
    }
}

private final class DemoMeetingIntelligenceProvider: MeetingIntelligenceProvider, @unchecked Sendable {
    let id = "demo-intelligence"

    func summarize(segments: [TranscriptSegment], meetingID: UUID) async throws -> MeetingSummary {
        let decisionSegment = segments.first { $0.text.localizedCaseInsensitiveContains("beta candidate") }
            ?? segments.first
        let actionSegment = segments.first { $0.text.localizedCaseInsensitiveContains("notarized") }
            ?? decisionSegment

        let decisionEvidence = decisionSegment.map {
            EvidenceRef(
                meetingID: meetingID,
                segmentID: $0.id,
                startTime: $0.startTime,
                endTime: $0.endTime,
                quote: $0.text
            )
        }.map { [$0] } ?? []
        let actionEvidence = actionSegment.map {
            EvidenceRef(
                meetingID: meetingID,
                segmentID: $0.id,
                startTime: $0.startTime,
                endTime: $0.endTime,
                quote: $0.text
            )
        }.map { [$0] } ?? []

        return MeetingSummary(
            title: "Release readiness sync",
            oneParagraph: "The team aligned on shipping the beta candidate after privacy review and preparing the notarized build checklist.",
            bullets: [
                "Beta shipment depends on privacy review.",
                "The notarized build checklist needs owner review."
            ],
            decisions: [
                Decision(
                    title: "Ship after privacy review",
                    details: "The beta candidate can ship after privacy review.",
                    evidence: decisionEvidence,
                    confidence: 0.90
                )
            ],
            actionItems: [
                ActionItem(
                    title: "Prepare notarized build checklist",
                    ownerName: "You",
                    evidence: actionEvidence,
                    confidence: 0.84
                )
            ],
            openQuestions: [
                OpenQuestion(
                    question: "Who owns final privacy approval?",
                    context: "The beta cannot close until privacy ownership is explicit.",
                    evidence: decisionEvidence,
                    confidence: 0.78
                )
            ],
            risks: [
                MeetingRisk(
                    title: "Notarization can block the beta",
                    details: "Release readiness depends on the notarized build checklist being reviewed.",
                    severity: .high,
                    evidence: actionEvidence,
                    confidence: 0.80
                )
            ]
        )
    }

    func summarize(
        segments: [TranscriptSegment],
        bookmarkEvidence: [MeetingIntelligenceBookmarkEvidence],
        meetingID: UUID
    ) async throws -> MeetingSummary {
        var summary = try await summarize(segments: segments, meetingID: meetingID)
        let markedMomentBullets = bookmarkEvidence
            .filter { $0.bookmark.meetingID == meetingID && $0.provenance == .userAuthored }
            .sorted { $0.bookmark.timestamp < $1.bookmark.timestamp }
            .map { evidence in
                let seconds = String(format: "%.1f", evidence.bookmark.timestamp)
                return "Marked moment at \(seconds)s for emphasis."
            }
        summary.bullets.append(contentsOf: markedMomentBullets)
        return summary
    }
}

private extension PreflightIssue {
    var isPermissionIssue: Bool {
        switch self {
        case .audioPermissionMissing, .microphonePermissionMissing, .speechPermissionMissing:
            true
        case .diskSpaceLow, .consentRequired, .doNotRecord:
            false
        }
    }

    var readinessLabel: String {
        switch self {
        case .audioPermissionMissing:
            "Screen & System Audio"
        case .microphonePermissionMissing:
            "Microphone"
        case .speechPermissionMissing:
            "Speech Recognition"
        case .diskSpaceLow:
            "Storage"
        case .consentRequired:
            "Consent"
        case .doNotRecord:
            "Do Not Record"
        }
    }
}

private struct TranscriptEditSeed {
    var meeting: SearchMeeting
    var transcript: MeetingTranscript
    var history: TranscriptEditHistory
}

private enum SampleData {
    static let sources = [
        CaptureSource(
            id: "zoom",
            displayName: "Zoom.us",
            bundleIdentifier: "us.zoom.xos",
            mode: .selectedApplication,
            isRecommended: true,
            level: 0.72
        ),
        CaptureSource(
            id: "teams",
            displayName: "Microsoft Teams",
            bundleIdentifier: "com.microsoft.teams2",
            mode: .processGroup,
            isRecommended: true,
            level: 0.54
        ),
        CaptureSource(
            id: "system",
            displayName: "Entire system audio",
            mode: .systemAudio,
            level: 0.34
        ),
        CaptureSource(
            id: "fallback",
            displayName: "ScreenCaptureKit fallback",
            mode: .screenCaptureFallback,
            level: 0.15
        )
    ]

    static let demoCapturedChunks = [
        CapturedAudioChunk(
            track: .remoteSystem,
            data: wavPCMData(durationSeconds: 60),
            startTime: 0,
            duration: 60,
            codec: "WAV/PCM"
        ),
        CapturedAudioChunk(
            track: .microphone,
            data: wavPCMData(durationSeconds: 60),
            startTime: 0,
            duration: 60,
            codec: "WAV/PCM"
        )
    ]

    private static func wavPCMData(durationSeconds: Double, sampleRate: UInt32 = 8_000) -> Data {
        let channelCount: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let bytesPerSample = UInt32(bitsPerSample / 8)
        let sampleCount = max(1, UInt32(durationSeconds * Double(sampleRate)))
        let audioDataByteCount = sampleCount * UInt32(channelCount) * bytesPerSample
        let byteRate = sampleRate * UInt32(channelCount) * bytesPerSample
        let blockAlign = channelCount * UInt16(bytesPerSample)

        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        appendLittleEndian(UInt32(36) + audioDataByteCount, to: &data)
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        appendLittleEndian(UInt32(16), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(channelCount, to: &data)
        appendLittleEndian(sampleRate, to: &data)
        appendLittleEndian(byteRate, to: &data)
        appendLittleEndian(blockAlign, to: &data)
        appendLittleEndian(bitsPerSample, to: &data)
        data.append(contentsOf: "data".utf8)
        appendLittleEndian(audioDataByteCount, to: &data)
        data.append(Data(repeating: 0, count: Int(audioDataByteCount)))
        return data
    }

    private static func appendLittleEndian<Value: FixedWidthInteger>(_ value: Value, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    static let meetingID = UUID()
    static let segmentID = UUID()
    static let designReviewMeetingID = UUID()
    static let designReviewSegmentID = UUID()

    static let evidence = EvidenceRef(
        meetingID: meetingID,
        segmentID: segmentID,
        startTime: 31 * 60 + 44,
        endTime: 31 * 60 + 51,
        quote: "Let's move deployment to Thursday after QA signs off."
    )

    static let editorSearchMeeting = SearchMeeting(
        id: meetingID,
        title: "Project weekly sync",
        startedAt: Date(timeIntervalSinceNow: -3_600),
        sourceApp: "Microsoft Teams"
    )

    static let designReviewSearchMeeting = SearchMeeting(
        id: designReviewMeetingID,
        title: "Design review",
        startedAt: Date(timeIntervalSinceNow: -86_400),
        sourceApp: "Zoom.us"
    )

    static let editorTranscript = MeetingTranscript(
        meetingID: meetingID,
        localeIdentifier: "en-US",
        generatedAt: Date(timeIntervalSinceNow: -1_200),
        segments: [
            TranscriptSegment(
                id: segmentID,
                speakerName: "Anna",
                trackKind: .remoteSystem,
                startTime: 31 * 60 + 44,
                endTime: 31 * 60 + 51,
                text: "Let's move deployment to Thursday after QA signs off.",
                confidence: 0.94,
                isFinal: true
            ),
            TranscriptSegment(
                id: UUID(),
                speakerName: "You",
                trackKind: .microphone,
                startTime: 31 * 60 + 58,
                endTime: 32 * 60 + 5,
                text: "I will update release notes and attach the decision.",
                confidence: 0.89,
                isFinal: true
            ),
            TranscriptSegment(
                id: UUID(),
                speakerName: "Anna",
                trackKind: .remoteSystem,
                startTime: 41 * 60 + 10,
                endTime: 41 * 60 + 18,
                text: "This recovered transcript segment is waiting for audio repair.",
                confidence: 0.81,
                isFinal: true
            )
        ]
    )

    static let transcriptEditHistory = TranscriptEditHistory(
        meetingID: meetingID,
        entries: [
            TranscriptEditHistoryEntry(
                version: 1,
                editedAt: Date(timeIntervalSinceNow: -600),
                editedSegmentIDs: [segmentID]
            )
        ]
    )

    static let designReviewTranscript = MeetingTranscript(
        meetingID: designReviewMeetingID,
        localeIdentifier: "en-US",
        generatedAt: Date(timeIntervalSinceNow: -82_000),
        segments: [
            TranscriptSegment(
                id: designReviewSegmentID,
                speakerName: "Maya",
                trackKind: .remoteSystem,
                startTime: 9 * 60 + 12,
                endTime: 9 * 60 + 20,
                text: "The inspector needs clearer hierarchy before the final handoff.",
                confidence: 0.92,
                isFinal: true
            ),
            TranscriptSegment(
                id: UUID(),
                speakerName: "You",
                trackKind: .microphone,
                startTime: 9 * 60 + 25,
                endTime: 9 * 60 + 32,
                text: "I will tighten the empty states and send a revised build.",
                confidence: 0.90,
                isFinal: true
            )
        ]
    )

    static let designReviewEditHistory = TranscriptEditHistory(meetingID: designReviewMeetingID)

    static let editorSessionSeeds = [
        TranscriptEditSeed(
            meeting: editorSearchMeeting,
            transcript: editorTranscript,
            history: transcriptEditHistory
        ),
        TranscriptEditSeed(
            meeting: designReviewSearchMeeting,
            transcript: designReviewTranscript,
            history: designReviewEditHistory
        )
    ]

    static let libraryEntries: [MeetingLibraryEntry] = editorSessionSeeds.compactMap { seed in
        guard let record = meetings.first(where: { $0.id == seed.meeting.id }) else {
            return nil
        }
        return MeetingLibraryEntry(
            record: record,
            searchMeeting: seed.meeting,
            transcript: seed.transcript,
            editHistory: seed.history
        )
    }

    static let meetings = [
        MeetingRecord(
            id: meetingID,
            title: "Project weekly sync",
            startedAt: Date(timeIntervalSinceNow: -3_600),
            durationSeconds: 2_536,
            sourceName: "Microsoft Teams",
            state: .processing,
            consentStatus: .disclosed,
            summary: MeetingSummary(
                title: "Project weekly sync",
                oneParagraph: "The team aligned on moving deployment after QA sign-off and captured follow-up work for release readiness.",
                bullets: [
                    "Deployment timing depends on QA sign-off.",
                    "Release notes and follow-up tasks need owner review.",
                    "Risk tracking should stay attached to transcript evidence."
                ],
                decisions: [
                    Decision(
                        title: "Move deployment to Thursday",
                        details: "Deployment should move after QA signs off.",
                        evidence: [evidence],
                        confidence: 0.91
                    )
                ],
                actionItems: [
                    ActionItem(
                        title: "Confirm QA sign-off before release",
                        ownerName: "You",
                        dueDate: Date(timeIntervalSinceNow: 86_400),
                        evidence: [evidence],
                        confidence: 0.86
                    )
                ],
                openQuestions: [
                    OpenQuestion(
                        question: "Who gives final QA approval?",
                        context: "Deployment stays gated until ownership and approval are explicit.",
                        evidence: [evidence],
                        confidence: 0.83
                    )
                ],
                risks: [
                    MeetingRisk(
                        title: "Deployment may slip",
                        details: "Thursday deployment depends on QA sign-off happening first.",
                        severity: .medium,
                        evidence: [evidence],
                        confidence: 0.79
                    )
                ]
            )
        ),
        MeetingRecord(
            id: designReviewMeetingID,
            title: "Design review",
            startedAt: Date(timeIntervalSinceNow: -86_400),
            durationSeconds: 4_018,
            sourceName: "Zoom.us",
            state: .recovered,
            consentStatus: .consented,
            summary: nil
        )
    ]

    static let captureHealthReport = CaptureHealthReport(
        remoteDropouts: 0,
        microphoneDropouts: 0,
        remoteClippingPercent: 0,
        microphoneClippingPercent: 0,
        silentPeriods: [
            SilentPeriod(startTime: 552.2, endTime: 601.4, track: .remoteSystem)
        ],
        deviceChanges: [
            AudioDeviceChange(time: 1_204.1, from: "AirPods Pro", to: "MacBook Speakers")
        ],
        transcriptionEngine: "SpeechAnalyzer boundary",
        intelligenceProvider: "Foundation Models boundary"
    )

    static let privacyAuditReview = PrivacyAuditReview(
        rows: [
            PrivacyAuditReviewRow(
                id: UUID(),
                occurredAt: Date(timeIntervalSinceNow: -600),
                action: .transcriptEdit,
                meetingID: meetingID,
                metadata: ["editedSegmentCount": "1", "version": "1"]
            ),
            PrivacyAuditReviewRow(
                id: UUID(),
                occurredAt: Date(timeIntervalSinceNow: -900),
                action: .sharePrepare,
                meetingID: meetingID,
                metadata: ["destination": "systemShareSheet", "fileCount": "2", "formats": "markdown,json"]
            ),
            PrivacyAuditReviewRow(
                id: UUID(),
                occurredAt: Date(timeIntervalSinceNow: -1_200),
                action: .exportPackage,
                meetingID: meetingID,
                metadata: ["fileCount": "3", "formats": "markdown,json,webVTT"]
            ),
            PrivacyAuditReviewRow(
                id: UUID(),
                occurredAt: Date(timeIntervalSinceNow: -3_600),
                action: .meetingDelete,
                meetingID: UUID(),
                metadata: ["reason": "userRequested"]
            ),
            PrivacyAuditReviewRow(
                id: UUID(),
                occurredAt: Date(timeIntervalSinceNow: -7_200),
                action: .retentionDelete,
                meetingID: UUID(),
                metadata: ["ageDays": "90", "retentionDays": "30"]
            )
        ],
        counts: [
            .exportPackage: 1,
            .meetingDelete: 1,
            .retentionDelete: 1,
            .sharePrepare: 1,
            .transcriptEdit: 1
        ],
        latestOccurredAt: Date(timeIntervalSinceNow: -600)
    )

    static let playbackTimeline = TranscriptPlaybackTimelineService().buildTimeline(
        transcript: editorTranscript,
        audioChunks: [
            AudioChunkRecord(
                track: .remoteSystem,
                chunkIndex: 0,
                relativePath: "audio/remoteSystem/chunk-0000.caf.enc",
                startTime: 31 * 60,
                duration: 120,
                byteCount: 8_192,
                codec: "CAF/LPCM",
                encrypted: true
            ),
            AudioChunkRecord(
                track: .microphone,
                chunkIndex: 0,
                relativePath: "audio/microphone/chunk-0000.caf.enc",
                startTime: 31 * 60,
                duration: 120,
                byteCount: 4_096,
                codec: "CAF/LPCM",
                encrypted: true
            )
        ]
    )

    static let automationPlans: [MeetingAutomationPlan] = {
        let planner = MeetingAutomationPlanner()
        return [
            planner.plan(
                MeetingAutomationRequest(
                    action: .startRecording,
                    surface: .shortcuts,
                    meetingID: meetingID,
                    sourceID: "zoom",
                    localOnlyMode: true,
                    approval: .notApproved
                )
            ),
            planner.plan(
                MeetingAutomationRequest(
                    action: .prepareShare,
                    surface: .appIntent,
                    meetingID: meetingID,
                    localOnlyMode: true,
                    approval: .userConfirmed
                )
            ),
            planner.plan(
                MeetingAutomationRequest(
                    action: .sendWebhook,
                    surface: .appIntent,
                    meetingID: meetingID,
                    localOnlyMode: true,
                    approval: .notApproved,
                    payloadPreview: "Private launch transcript detail"
                )
            )
        ]
    }()
}
