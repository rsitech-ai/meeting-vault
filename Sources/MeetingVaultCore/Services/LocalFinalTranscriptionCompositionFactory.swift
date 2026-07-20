import Foundation

/// Shared production/fixture composition seam. Deterministic proof can replace
/// only the native model engine while retaining the same encrypted persistence,
/// marker, search-index, and service orchestration used by production.
public protocol LocalFinalProductionEngineLoading: Sendable {
    func load(
        runtime: any LocalModelRuntimeSessionProviding,
        chunkWriter: EncryptedAudioChunkWriter
    ) -> any LocalFinalTranscriptionEngine
}

public struct FluidAudioLocalFinalProductionEngineLoader: LocalFinalProductionEngineLoading {
    public init() {}

    public func load(
        runtime: any LocalModelRuntimeSessionProviding,
        chunkWriter: EncryptedAudioChunkWriter
    ) -> any LocalFinalTranscriptionEngine {
        FluidAudioLocalFinalTranscriptionEngine(runtime: runtime, chunkWriter: chunkWriter)
    }
}

public enum LocalFinalTranscriptionCompositionResolver {
    public static func production(
        runtime: any LocalModelRuntimeSessionProviding,
        bundleStore: EncryptedMeetingBundleStore,
        chunkWriter: EncryptedAudioChunkWriter,
        searchIndex: SQLiteSearchIndex,
        engineLoader: any LocalFinalProductionEngineLoading = FluidAudioLocalFinalProductionEngineLoader()
    ) -> any FinalTranscriptionServicing {
        make(
            engine: engineLoader.load(runtime: runtime, chunkWriter: chunkWriter),
            bundleStore: bundleStore,
            chunkWriter: chunkWriter,
            searchIndex: searchIndex
        )
    }

    private static func make(
        engine: any LocalFinalTranscriptionEngine,
        bundleStore: EncryptedMeetingBundleStore,
        chunkWriter: EncryptedAudioChunkWriter,
        searchIndex: SQLiteSearchIndex
    ) -> any FinalTranscriptionServicing {
        LocalFinalTranscriptionService(
            engine: engine,
            bundleStore: bundleStore,
            searchIndex: searchIndex,
            decryptedChunkReaderFactory: { meetingID in
                EncryptedAudioChunkReader(writer: chunkWriter, meetingID: meetingID)
            }
        )
    }
}
