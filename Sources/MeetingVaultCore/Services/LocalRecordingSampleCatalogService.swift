import Foundation

public struct LocalRecordingSampleCatalogService {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func discoverSamples(
        transcriptDirectory: URL,
        audioDirectory: URL,
        limit: Int = 80
    ) throws -> [LocalRecordingSampleCandidate] {
        let transcriptFiles = try regularFiles(in: transcriptDirectory)
            .filter { LocalRecordingImportService.supportedTranscriptExtensions.contains($0.pathExtension.lowercased()) }
        let audioFiles = try regularFiles(in: audioDirectory)
            .filter { LocalRecordingImportService.supportedAudioExtensions.contains($0.pathExtension.lowercased()) }
        let audioByTimestamp = Dictionary(grouping: audioFiles) { Self.timestampKey(from: $0) }

        return transcriptFiles.compactMap { transcriptURL in
            guard let timestampKey = Self.timestampKey(from: transcriptURL),
                  let audioURL = preferredAudioURL(from: audioByTimestamp[timestampKey] ?? [])
            else {
                return nil
            }

            return LocalRecordingSampleCandidate(
                timestampKey: timestampKey,
                title: Self.title(from: transcriptURL),
                transcriptURL: transcriptURL,
                audioURL: audioURL,
                audioByteCount: audioByteCount(at: audioURL)
            )
        }
        .sorted {
            if $0.timestampKey != $1.timestampKey {
                return $0.timestampKey > $1.timestampKey
            }
            return $0.transcriptURL.lastPathComponent < $1.transcriptURL.lastPathComponent
        }
        .prefix(max(0, limit))
        .map { $0 }
    }

    private func regularFiles(in directory: URL) throws -> [URL] {
        guard fileManager.fileExists(atPath: directory.path) else {
            return []
        }

        return try fileManager
            .contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            .filter { url in
                (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
    }

    private func preferredAudioURL(from urls: [URL]) -> URL? {
        urls.sorted { lhs, rhs in
            let lhsScore = Self.audioPreferenceScore(lhs)
            let rhsScore = Self.audioPreferenceScore(rhs)
            if lhsScore != rhsScore {
                return lhsScore > rhsScore
            }
            return lhs.lastPathComponent < rhs.lastPathComponent
        }
        .first
    }

    private func audioByteCount(at url: URL) -> Int {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return attributes?[.size] as? Int ?? 0
    }

    private static func timestampKey(from url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent
        guard let match = name.range(
            of: #"\d{8} \d{4}"#,
            options: .regularExpression
        ) else {
            return nil
        }
        return String(name[match])
    }

    private static func title(from transcriptURL: URL) -> String {
        let name = transcriptURL.deletingPathExtension().lastPathComponent
        return name
            .replacingOccurrences(of: " Transcription 1", with: "")
            .replacingOccurrences(of: " Transcription", with: "")
    }

    private static func audioPreferenceScore(_ url: URL) -> Int {
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

}
