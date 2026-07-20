@preconcurrency import CoreML
import Foundation

public enum LocalModelSubprocessSelfCheckError: Error, Equatable, Sendable {
    case unsupportedUnit
    case missingAsset(String)
    case invalidMetadata(String)
}

/// Entry point for the separately signed, killable model prewarm helper.
/// The helper loads only model packages from the already verified unit root.
public enum LocalModelSubprocessSelfCheck {
    public static func run(assetID: String, root: URL) async throws {
        let packages: [String]
        let metadataFiles: [String]
        switch assetID {
        case "automatic-speech-recognition":
            packages = ["Preprocessor", "Encoder", "Decoder", "JointDecisionv3"].map {
                "parakeet-tdt-0.6b-v3/\($0).mlmodelc"
            }
            metadataFiles = ["parakeet-tdt-0.6b-v3/parakeet_vocab.json"]
        case "streaming-speaker-diarization":
            packages = ["ls-eend/dih3/optimized/dih3/100ms/ls_eend_dih3_100ms.mlmodelc"]
            metadataFiles = []
        case "offline-speaker-diarization":
            packages = ["Embedding", "FBank", "PldaRho", "Segmentation"].map {
                "speaker-diarization/\($0).mlmodelc"
            }
            metadataFiles = ["speaker-diarization/plda-parameters.json"]
        default:
            throw LocalModelSubprocessSelfCheckError.unsupportedUnit
        }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        for relativePath in packages {
            let url = root.appendingPathComponent(relativePath, isDirectory: true)
            guard !url.pathComponents.contains(".."),
                  FileManager.default.fileExists(atPath: url.path)
            else { throw LocalModelSubprocessSelfCheckError.missingAsset(relativePath) }
            _ = try MLModel(contentsOf: url, configuration: configuration)
        }
        for relativePath in metadataFiles {
            let url = root.appendingPathComponent(relativePath)
            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
                  !data.isEmpty, data.count <= 4 * 1_024 * 1_024,
                  (try? JSONSerialization.jsonObject(with: data)) != nil
            else { throw LocalModelSubprocessSelfCheckError.invalidMetadata(relativePath) }
        }
    }
}
