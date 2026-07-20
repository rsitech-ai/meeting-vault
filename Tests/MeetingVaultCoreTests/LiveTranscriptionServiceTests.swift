import Foundation
import XCTest
@testable import MeetingVaultCore

final class LiveTranscriptionServiceTests: XCTestCase {
    func testAppleSpeechLiveFailsBeforeStreamerWhenOnDeviceRecognitionUnsupported() async throws {
        let streamer = StubSpeechLiveEventStreamer(events: [])
        let provider = AppleSpeechLiveTranscriptionProvider(
            privacyBoundary: TranscriptionPrivacyBoundary(mode: .appleOnDeviceOnly),
            authorizationProvider: CapturingSpeechAuthorizationProvider(currentState: .authorized),
            onDeviceCapability: FixedAppleSpeechOnDeviceCapability(supported: false),
            eventStreamerFactory: { _ in streamer }
        )
        do {
            for try await _ in provider.events(for: LiveTranscriptionContext(meetingID: UUID(), sourceID: "m", sourceName: "m")) {}
            XCTFail("Expected on-device capability rejection")
        } catch {
            XCTAssertEqual(error as? TranscriptionPrivacyBoundaryError, .onDeviceRecognitionRequired)
        }
        XCTAssertEqual(streamer.startCount, 0)
    }
    func testAppleSpeechProviderFailsClosedBeforeCreatingStreamerInLocalOnlyMode() async throws {
        let authorization = CapturingSpeechAuthorizationProvider(currentState: .authorized)
        let streamer = StubSpeechLiveEventStreamer(events: [.status("must not start")])
        let boundary = TranscriptionPrivacyBoundary(mode: .localOnly)
        let provider = AppleSpeechLiveTranscriptionProvider(
            privacyBoundary: boundary,
            authorizationProvider: authorization,
            eventStreamerFactory: { _ in streamer }
        )

        do {
            for try await _ in provider.events(for: LiveTranscriptionContext(
                meetingID: UUID(), sourceID: "microphone", sourceName: "Microphone"
            )) {}
            XCTFail("Expected local-only rejection")
        } catch {
            XCTAssertEqual(error as? TranscriptionPrivacyBoundaryError, .localProviderUnavailable)
        }

        XCTAssertEqual(authorization.requestCount, 0)
        XCTAssertEqual(streamer.startCount, 0)
    }

    func testAppleSpeechProviderPassesOnDeviceRequirementBeforeStartingStreamer() async throws {
        let authorization = CapturingSpeechAuthorizationProvider(currentState: .authorized)
        let streamer = CapturingSpeechLiveEventStreamer()
        let provider = AppleSpeechLiveTranscriptionProvider(
            privacyBoundary: TranscriptionPrivacyBoundary(mode: .appleOnDeviceOnly),
            authorizationProvider: authorization,
            eventStreamerFactory: { _ in streamer }
        )

        for try await _ in provider.events(for: LiveTranscriptionContext(
            meetingID: UUID(), sourceID: "microphone", sourceName: "Microphone"
        )) {}

        XCTAssertEqual(streamer.contexts.count, 1)
        XCTAssertTrue(streamer.contexts[0].appleSpeechRequiresOnDeviceRecognition)
    }

    func testLiveTranscriptionServiceStreamsProviderEventsInOrder() async throws {
        let meetingID = UUID(uuidString: "41414141-4141-4141-4141-414141414141")!
        let partial = TranscriptSegment(
            speakerName: "You",
            trackKind: .microphone,
            startTime: 0,
            endTime: 3,
            text: "Draft transcript is visible",
            confidence: 0.55,
            isFinal: false
        )
        let final = TranscriptSegment(
            speakerName: "You",
            trackKind: .microphone,
            startTime: 0,
            endTime: 3,
            text: "Final live segment is reconciled",
            confidence: 0.90,
            isFinal: true
        )
        let provider = MockLiveTranscriptionProvider(
            actions: [
                .event(.status("Live transcription connected")),
                .event(.inputLevel(0.64)),
                .event(.partial(partial)),
                .event(.final(final))
            ]
        )
        let service = LiveTranscriptionService(provider: provider)
        let context = LiveTranscriptionContext(
            meetingID: meetingID,
            sourceID: "selected-microphone",
            sourceName: "Selected Microphone",
            microphoneDeviceID: "studio",
            microphoneDeviceName: "Studio Display Microphone",
            localeIdentifier: "en_US"
        )

        var events: [LiveTranscriptionEvent] = []
        for try await event in service.events(for: context) {
            events.append(event)
        }

        XCTAssertEqual(
            events,
            [
                .status("Live transcription connected"),
                .inputLevel(0.64),
                .partial(partial),
                .final(final)
            ]
        )
        XCTAssertEqual(provider.contexts, [context])
        XCTAssertEqual(service.providerID, "mock-live-transcription")
    }

    func testLiveTranscriptionServiceSurfacesProviderFailure() async throws {
        let provider = MockLiveTranscriptionProvider(
            actions: [
                .event(.status("Starting live transcription")),
                .fail("Speech recognition unavailable")
            ]
        )
        let service = LiveTranscriptionService(provider: provider)
        let context = LiveTranscriptionContext(
            meetingID: UUID(uuidString: "42424242-4242-4242-4242-424242424242")!,
            sourceID: "teams",
            sourceName: "Microsoft Teams"
        )

        var events: [LiveTranscriptionEvent] = []
        do {
            for try await event in service.events(for: context) {
                events.append(event)
            }
            XCTFail("Expected provider failure")
        } catch {
            XCTAssertEqual(error as? LiveTranscriptionProviderError, LiveTranscriptionProviderError(message: "Speech recognition unavailable"))
        }

        XCTAssertEqual(events, [.status("Starting live transcription")])
        XCTAssertEqual(provider.contexts, [context])
    }

    func testAppleSpeechProviderDoesNotRequestPermissionAgainWhenAlreadyAuthorized() async throws {
        let finalSegment = TranscriptSegment(
            speakerName: "You",
            trackKind: .microphone,
            startTime: 0,
            endTime: 2,
            text: "Apple Speech is streaming",
            confidence: 0.91,
            isFinal: true
        )
        let authorization = CapturingSpeechAuthorizationProvider(currentState: .authorized)
        let streamer = StubSpeechLiveEventStreamer(
            events: [
                .status("Engine ready"),
                .final(finalSegment)
            ]
        )
        let provider = AppleSpeechLiveTranscriptionProvider(
            authorizationProvider: authorization,
            eventStreamerFactory: { locale in
                streamer.recordLocale(locale)
                return streamer
            }
        )

        let context = LiveTranscriptionContext(
            meetingID: UUID(uuidString: "43434343-4343-4343-4343-434343434343")!,
            sourceID: "selected-microphone",
            sourceName: "Selected Microphone",
            microphoneDeviceID: "airpods",
            microphoneDeviceName: "Sikor AirPods Pro",
            localeIdentifier: "en-US"
        )

        var events: [LiveTranscriptionEvent] = []
        for try await event in provider.events(for: context) {
            events.append(event)
        }

        XCTAssertEqual(authorization.requestCount, 0)
        XCTAssertEqual(streamer.locales.map(\.identifier), ["en-US"])
        XCTAssertEqual(
            events,
            [
                .status("Checking Speech Recognition permission"),
                .status("Starting Apple Speech live transcription"),
                .status("Engine ready"),
                .final(finalSegment)
            ]
        )
    }

    func testAppleSpeechProviderDoesNotRequestPermissionWhenNotDetermined() async throws {
        let authorization = CapturingSpeechAuthorizationProvider(
            currentState: .notDetermined,
            requestedState: .authorized
        )
        let streamer = StubSpeechLiveEventStreamer(events: [.status("Engine ready")])
        let provider = AppleSpeechLiveTranscriptionProvider(
            authorizationProvider: authorization,
            eventStreamerFactory: { _ in streamer }
        )

        var events: [LiveTranscriptionEvent] = []
        do {
            for try await event in provider.events(
                for: LiveTranscriptionContext(
                    meetingID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                    sourceID: "selected-microphone",
                    sourceName: "Selected Microphone"
                )
            ) {
                events.append(event)
            }
            XCTFail("Expected not determined permission to fail closed")
        } catch {
            XCTAssertEqual(
                error as? AppleSpeechLiveTranscriptionError,
                .authorizationDenied(.notDetermined)
            )
        }

        XCTAssertEqual(authorization.requestCount, 0)
        XCTAssertEqual(streamer.startCount, 0)
        XCTAssertEqual(
            events,
            [
                .status("Checking Speech Recognition permission")
            ]
        )
    }

    func testAppleSpeechProviderFailsClosedWhenSpeechPermissionIsDenied() async throws {
        let authorization = CapturingSpeechAuthorizationProvider(currentState: .denied)
        let streamer = StubSpeechLiveEventStreamer(events: [.status("Should not start")])
        let provider = AppleSpeechLiveTranscriptionProvider(
            authorizationProvider: authorization,
            eventStreamerFactory: { _ in streamer }
        )

        var events: [LiveTranscriptionEvent] = []
        do {
            for try await event in provider.events(
                for: LiveTranscriptionContext(
                    meetingID: UUID(uuidString: "45454545-4545-4545-4545-454545454545")!,
                    sourceID: "teams",
                    sourceName: "Microsoft Teams"
                )
            ) {
                events.append(event)
            }
            XCTFail("Expected denied permission to fail closed")
        } catch {
            XCTAssertEqual(
                error as? AppleSpeechLiveTranscriptionError,
                .authorizationDenied(.denied)
            )
        }

        XCTAssertEqual(events, [.status("Checking Speech Recognition permission")])
        XCTAssertEqual(authorization.requestCount, 0)
        XCTAssertEqual(streamer.startCount, 0)
    }
}

private final class CapturingSpeechAuthorizationProvider: SpeechRecognitionAuthorizationProviding, @unchecked Sendable {
    private let currentState: SpeechRecognitionAuthorizationState
    private let requestedState: SpeechRecognitionAuthorizationState
    private let lock = NSLock()
    private var _requestCount = 0

    var requestCount: Int {
        lock.withLock { _requestCount }
    }

    init(
        currentState: SpeechRecognitionAuthorizationState,
        requestedState: SpeechRecognitionAuthorizationState = .authorized
    ) {
        self.currentState = currentState
        self.requestedState = requestedState
    }

    func currentAuthorizationState() -> SpeechRecognitionAuthorizationState {
        currentState
    }

    func requestAuthorizationState() async -> SpeechRecognitionAuthorizationState {
        lock.withLock {
            _requestCount += 1
        }
        return requestedState
    }
}

private final class StubSpeechLiveEventStreamer: SpeechLiveEventStreaming, @unchecked Sendable {
    private let eventsToEmit: [LiveTranscriptionEvent]
    private let lock = NSLock()
    private var _startCount = 0
    private var _locales: [Locale] = []

    var startCount: Int {
        lock.withLock { _startCount }
    }

    var locales: [Locale] {
        lock.withLock { _locales }
    }

    init(events: [LiveTranscriptionEvent]) {
        self.eventsToEmit = events
    }

    func recordLocale(_ locale: Locale) {
        lock.withLock {
            _locales.append(locale)
        }
    }

    func events(for context: LiveTranscriptionContext) -> AsyncThrowingStream<LiveTranscriptionEvent, Error> {
        lock.withLock {
            _startCount += 1
        }
        return AsyncThrowingStream { continuation in
            for event in eventsToEmit {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}

private final class CapturingSpeechLiveEventStreamer: SpeechLiveEventStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [LiveTranscriptionContext] = []

    var contexts: [LiveTranscriptionContext] { lock.withLock { storage } }

    func events(for context: LiveTranscriptionContext) -> AsyncThrowingStream<LiveTranscriptionEvent, Error> {
        lock.withLock { storage.append(context) }
        return AsyncThrowingStream { $0.finish() }
    }
}

private struct FixedAppleSpeechOnDeviceCapability: AppleSpeechOnDeviceCapabilityProviding {
    let supported: Bool
    func supportsOnDeviceRecognition(for locale: Locale) -> Bool { supported }
}
