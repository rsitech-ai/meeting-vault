import Foundation

/// Exact local roots consumed by the pinned FluidAudio 0.15.5 adapters.
///
/// Task 9 receives only these verified roots and never invokes a download API.
public struct LocalModelRuntimeLayout: Equatable, Sendable {
    public let parakeetASR: URL
    public let lsEENDCache: URL
    public let lsEENDModel: URL
    public let offlineDiarization: URL

    public init(root: URL) {
        let root = root.standardizedFileURL
        parakeetASR = root.appendingPathComponent("parakeet-tdt-0.6b-v3", isDirectory: true)
        lsEENDCache = root
        lsEENDModel = root.appendingPathComponent(
            "ls-eend/dih3/optimized/dih3/100ms",
            isDirectory: true
        )
        offlineDiarization = root
    }
}
