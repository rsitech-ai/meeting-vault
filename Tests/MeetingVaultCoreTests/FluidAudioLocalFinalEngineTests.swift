import Foundation
import XCTest
@testable import MeetingVaultCore

final class FluidAudioLocalFinalEngineTests: XCTestCase {
    func testBoundedPLDAParserAcceptsExactFiniteVector() throws {
        let floats = (0..<128).map { Float($0) / 128 }
        let encoded = floats.withUnsafeBytes { Data($0).base64EncodedString() }
        let data = try JSONSerialization.data(withJSONObject: [
            "tensors": ["psi": ["data_base64": encoded]]
        ])

        let values = try BoundedPLDAParameters.parse(data, expectedDimension: 128)

        XCTAssertEqual(values.count, 128)
        XCTAssertEqual(values[64], Double(floats[64]), accuracy: 0.000_001)
    }

    func testBoundedPLDAParserRejectsWrongDimensionNonFiniteAndOversize() throws {
        let one = [Float(1)].withUnsafeBytes { Data($0).base64EncodedString() }
        let wrongDimension = try JSONSerialization.data(withJSONObject: [
            "tensors": ["psi": ["data_base64": one]]
        ])
        XCTAssertThrowsError(try BoundedPLDAParameters.parse(wrongDimension, expectedDimension: 128))

        let nonFinite = [Float.nan].withUnsafeBytes { Data($0).base64EncodedString() }
        let nonFiniteData = try JSONSerialization.data(withJSONObject: [
            "tensors": ["psi": ["data_base64": nonFinite]]
        ])
        XCTAssertThrowsError(try BoundedPLDAParameters.parse(nonFiniteData, expectedDimension: 1))
        XCTAssertThrowsError(try BoundedPLDAParameters.parse(Data(repeating: 0, count: 8_388_609)))
    }

    func testProductionCompositionResolverInvokesInjectedEngineLoader() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVault-ProductionResolver-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EncryptedMeetingBundleStore(
            rootDirectory: root,
            vault: AESGCMDataVault(keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 0x31, count: 32)))
        )
        let writer = EncryptedAudioChunkWriter(bundleStore: store)
        let loader = ResolverEngineLoaderSpy()

        _ = LocalFinalTranscriptionCompositionResolver.production(
            runtime: ResolverMissingRuntime(),
            bundleStore: store,
            chunkWriter: writer,
            searchIndex: try SQLiteSearchIndex(inMemory: ()),
            engineLoader: loader
        )

        XCTAssertEqual(loader.observedModelLoadCount, 1)
    }

    func testProviderConfigurationIdentityBindsActualManifestRevisionsAndMeetingConfiguration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingVault-ProviderIdentity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EncryptedMeetingBundleStore(
            rootDirectory: root,
            vault: AESGCMDataVault(keyProvider: InMemorySymmetricKeyProvider(keyData: Data(repeating: 0x32, count: 32)))
        )
        let engine = FluidAudioLocalFinalTranscriptionEngine(
            runtime: ResolverMissingRuntime(),
            chunkWriter: EncryptedAudioChunkWriter(bundleStore: store)
        )

        let polish = try engine.providerConfigurationVersion(
            for: MeetingContext(localeIdentifier: "pl-PL", expectedParticipantCount: 5)
        )
        let english = try engine.providerConfigurationVersion(
            for: MeetingContext(localeIdentifier: "en-US", expectedParticipantCount: 2)
        )

        XCTAssertTrue(polish.contains("fluidaudio-0.15.5"))
        XCTAssertTrue(polish.contains("parakeet-tdt-0.6b-v3-coreml@aed02740059203c4a87495924f685de3722ae9ce"))
        XCTAssertTrue(polish.contains("speaker-diarization-coreml@1ed7a662fdc7109e36d822db793ee6eebdaf8594"))
        XCTAssertNotEqual(polish, english)
    }
}

private final class ResolverEngineLoaderSpy: LocalFinalProductionEngineLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0
    var observedModelLoadCount: Int { lock.withLock { storedValue } }
    func load(
        runtime: any LocalModelRuntimeSessionProviding,
        chunkWriter: EncryptedAudioChunkWriter
    ) -> any LocalFinalTranscriptionEngine {
        lock.withLock { storedValue += 1 }
        return ResolverFixtureEngine()
    }
}

private struct ResolverMissingRuntime: LocalModelRuntimeSessionProviding {
    func withRuntimeSession(
        _ ids: Set<String>,
        _ operation: @Sendable (LocalModelRuntimeAccess) async throws -> Void
    ) async throws {
        throw LocalModelInstallationError.unitNotReady
    }
}

private struct ResolverFixtureEngine: LocalFinalTranscriptionEngine {
    func transcribeChunk(_ request: LocalFinalChunkRequest) async throws -> [TranscriptSegment] { [] }
    func diarizeRemoteChunk(_ request: LocalFinalChunkRequest) async throws -> [DiarizationTurn] { [] }
}
