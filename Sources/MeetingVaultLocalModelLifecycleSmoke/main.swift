import CryptoKit
import Foundation
import MeetingVaultCore

private struct SmokeReport: Codable {
    var status: String
    var installUnitCount: Int
    var installedUnitID: String
    var terminalProgressExact: Bool
    var activeUseRemovalRejected: Bool
    var postReleaseRemovalPassed: Bool
    var prewarmUnavailable: Bool
    var externalNetworkRequested: Bool
    var realModelDownloaded: Bool
    var rawPrivateDataStored: Bool
    var auditActions: [String]
    var issues: [String]
}

private actor SmokeAudit {
    private(set) var actions: [String] = []
    func record(_ action: PrivacyAuditAction) { actions.append(action.rawValue) }
}

private final class SmokeURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [URL: Data] = [:]
    nonisolated(unsafe) static var requestCount = 0
    private static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.lock.withLock { () -> Data? in
            Self.requestCount += 1
            return request.url.flatMap { Self.responses[$0] }
        }
        guard let url = request.url, let body else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": String(body.count), "ETag": "smoke-v1"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@main
private enum LocalModelLifecycleSmoke {
    static func main() async {
        do {
            let output = try outputURL()
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("MeetingVault-LocalModel-Smoke-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = makeManifest()
            SmokeURLProtocol.responses = fixture.responses
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [SmokeURLProtocol.self]
            let audit = SmokeAudit()
            let service = try LocalModelInstallationService(
                manifest: fixture.manifest,
                modelsRoot: root,
                sessionConfiguration: configuration,
                approvedHosts: ["huggingface.co"],
                availableCapacity: { _ in 10_000_000 },
                now: { Date(timeIntervalSince1970: 1_790_000_000) },
                selfCheck: { _, runtimeRoot in
                    guard FileManager.default.fileExists(atPath: runtimeRoot.path) else {
                        throw LocalModelInstallationError.unitNotReady
                    }
                },
                audit: { action, _ in await audit.record(action) }
            )

            let initial = await service.snapshot()
            var events: [ModelInstallEvent] = []
            for try await event in await service.install("automatic-speech-recognition") {
                events.append(event)
            }
            var prewarmUnavailable = false
            do {
                _ = try await service.prewarm("automatic-speech-recognition")
            } catch LocalModelInstallationError.selfCheckUnavailable {
                prewarmUnavailable = true
            }
            let lease = try await service.acquire(["automatic-speech-recognition"])
            var removalRejected = false
            do {
                try await service.remove("automatic-speech-recognition")
            } catch LocalModelInstallationError.unitInUse {
                removalRejected = true
            }
            lease.release()
            try await service.remove("automatic-speech-recognition")
            let final = await service.snapshot()
            let actions = await audit.actions
            let terminalProgressExact = events.contains(.progress(completedBytes: 8, totalBytes: 8))
            let postReleaseRemovalPassed = final.first?.status == .notInstalled
            let passed = initial.count == 3
                && terminalProgressExact
                && removalRejected
                && postReleaseRemovalPassed
                && prewarmUnavailable
                && SmokeURLProtocol.requestCount == 2
            let report = SmokeReport(
                status: passed ? "pass" : "fail",
                installUnitCount: initial.count,
                installedUnitID: "automatic-speech-recognition",
                terminalProgressExact: terminalProgressExact,
                activeUseRemovalRejected: removalRejected,
                postReleaseRemovalPassed: postReleaseRemovalPassed,
                prewarmUnavailable: prewarmUnavailable,
                externalNetworkRequested: false,
                realModelDownloaded: false,
                rawPrivateDataStored: false,
                auditActions: actions,
                issues: passed ? [] : ["lifecycle_contract_failed"]
            )
            try write(report, to: output)
            if !passed { exit(1) }
        } catch {
            fputs("local model lifecycle smoke failed with bounded code: lifecycle_smoke_error\n", stderr)
            exit(1)
        }
    }

    private static func outputURL() throws -> URL {
        var iterator = CommandLine.arguments.dropFirst().makeIterator()
        var output: URL?
        while let argument = iterator.next() {
            switch argument {
            case "--output":
                guard let value = iterator.next() else { throw LocalModelInstallationError.invalidResponse }
                output = URL(fileURLWithPath: value)
            default:
                throw LocalModelInstallationError.invalidResponse
            }
        }
        guard let output else { throw LocalModelInstallationError.invalidResponse }
        return output
    }

    private static func makeManifest() -> (manifest: LocalModelManifest, responses: [URL: Data]) {
        let revision = "aed02740059203c4a87495924f685de3722ae9ce"
        let entries: [(String, String, String, Data)] = [
            ("asr-a", "automatic-speech-recognition", "parakeet-tdt-0.6b-v3/a.bin", Data("asr".utf8)),
            ("asr-b", "automatic-speech-recognition", "parakeet-tdt-0.6b-v3/b.bin", Data("bytes".utf8)),
            ("offline", "offline-speaker-diarization", "speaker-diarization/model.bin", Data("offline".utf8)),
            ("stream", "streaming-speaker-diarization", "ls-eend/dih3/optimized/dih3/100ms/model.bin", Data("stream".utf8)),
        ]
        var responses: [URL: Data] = [:]
        let assets = entries.map { id, feature, path, body -> LocalModelAsset in
            let url = URL(string: "https://huggingface.co/FluidInference/fixture/resolve/\(revision)/\(path)")!
            responses[url] = body
            return LocalModelAsset(
                id: id,
                feature: feature,
                version: "1",
                sourceURL: url,
                sourceRevision: revision,
                licenseName: "MIT",
                licenseURL: URL(string: "https://opensource.org/license/mit")!,
                expectedBytes: Int64(body.count),
                sha256: SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined(),
                relativeInstallPath: path
            )
        }.sorted { [$0.id, $0.relativeInstallPath].lexicographicallyPrecedes([$1.id, $1.relativeInstallPath]) }
        return (LocalModelManifest(schemaVersion: 1, assets: assets), responses)
    }

    private static func write(_ report: SmokeReport, to output: URL) throws {
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        guard data.count <= 8 * 1_024 else { throw LocalModelInstallationError.invalidResponse }
        try data.write(to: output, options: [.atomic])
    }
}
