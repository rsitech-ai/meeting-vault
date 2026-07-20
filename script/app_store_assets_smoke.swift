#!/usr/bin/env swift
import Foundation

struct AppStoreAssetsSmokeReport: Codable {
    var timestamp: String
    var status: String
    var draftPath: String
    var metadataDraftReady: Bool
    var screenshotCandidatesReady: Bool
    var privacyDraftReady: Bool
    var reviewNotesDraftReady: Bool
    var finalAssetsReady: Bool
    var finalMetadataApproved: Bool
    var legalApproved: Bool
    var appStoreConnectRecordCreated: Bool
    var externalUploadAttempted: Bool
    var rawTranscriptStored: Bool
    var rawAudioStored: Bool
    var rawUITextStored: Bool
    var screenshotCount: Int
    var issues: [String]
}

enum AppStoreAssetsSmoke {
    static func main() {
        let rootURL = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let date = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        var draftURL = rootURL.appendingPathComponent("docs/app-store-submission-draft.json")
        var outputURL = rootURL
            .appendingPathComponent("docs", isDirectory: true)
            .appendingPathComponent("evidence", isDirectory: true)
            .appendingPathComponent("app-store-assets-smoke-\(date).json")

        var iterator = CommandLine.arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--draft":
                guard let value = iterator.next() else {
                    fputs("--draft requires a path\n", stderr)
                    exit(2)
                }
                draftURL = URL(fileURLWithPath: value)
            case "--output":
                guard let value = iterator.next() else {
                    fputs("--output requires a path\n", stderr)
                    exit(2)
                }
                outputURL = URL(fileURLWithPath: value)
            case "--help", "-h":
                print("""
                usage: script/app_store_assets_smoke.swift [--draft docs/app-store-submission-draft.json] [--output PATH]

                Validates the repo-owned App Store metadata/assets draft without
                creating an App Store Connect record, uploading assets, recording
                private audio, or storing raw transcript/UI/audio content.
                """)
                exit(0)
            default:
                fputs("unknown argument: \(argument)\n", stderr)
                exit(2)
            }
        }

        let report = buildReport(rootURL: rootURL, draftURL: draftURL)
        do {
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: outputURL, options: .atomic)
        } catch {
            fputs("failed to write app store assets smoke: \(error.localizedDescription)\n", stderr)
            exit(1)
        }

        print("Wrote \(outputURL.path)")
        print("status=\(report.status) metadataDraftReady=\(report.metadataDraftReady) screenshotCandidatesReady=\(report.screenshotCandidatesReady)")
        exit(report.status == "pass" ? 0 : 1)
    }

    private static func buildReport(rootURL: URL, draftURL: URL) -> AppStoreAssetsSmokeReport {
        var issues: [String] = []
        guard let draft = readJSONObject(at: draftURL) else {
            return AppStoreAssetsSmokeReport(
                timestamp: ISO8601DateFormatter().string(from: Date()),
                status: "fail",
                draftPath: relativePath(draftURL, rootURL: rootURL),
                metadataDraftReady: false,
                screenshotCandidatesReady: false,
                privacyDraftReady: false,
                reviewNotesDraftReady: false,
                finalAssetsReady: false,
                finalMetadataApproved: false,
                legalApproved: false,
                appStoreConnectRecordCreated: false,
                externalUploadAttempted: false,
                rawTranscriptStored: false,
                rawAudioStored: false,
                rawUITextStored: false,
                screenshotCount: 0,
                issues: ["Missing or unreadable App Store submission draft JSON."]
            )
        }

        let requiredStrings = [
            "appName",
            "bundleIdentifier",
            "version",
            "build",
            "primaryCategory",
            "subtitle",
            "promotionalText",
            "description"
        ]
        for key in requiredStrings where stringValue(draft[key]).isEmpty {
            issues.append("\(key) is required.")
        }

        let keywords = stringArray(draft["keywords"])
        if keywords.isEmpty {
            issues.append("keywords must contain at least one draft keyword.")
        }

        let metadataDraftReady = requiredStrings.allSatisfy { !stringValue(draft[$0]).isEmpty }
            && !keywords.isEmpty

        let screenshotCandidates = draft["screenshotCandidates"] as? [[String: Any]] ?? []
        if screenshotCandidates.isEmpty {
            issues.append("screenshotCandidates must contain at least one item.")
        }
        if screenshotCandidates.count > 10 {
            issues.append("screenshotCandidates must not exceed 10 items.")
        }

        for (index, candidate) in screenshotCandidates.enumerated() {
            let path = stringValue(candidate["path"])
            let purpose = stringValue(candidate["purpose"])
            if path.isEmpty {
                issues.append("screenshotCandidates[\(index)].path is required.")
                continue
            }
            if purpose.isEmpty {
                issues.append("screenshotCandidates[\(index)].purpose is required.")
            }
            let candidateURL = rootURL.appendingPathComponent(path)
            let ext = candidateURL.pathExtension.lowercased()
            if !["jpg", "jpeg", "png"].contains(ext) {
                issues.append("screenshotCandidates[\(index)] must use jpg, jpeg, or png.")
            }
            var isDirectory = ObjCBool(false)
            if !FileManager.default.fileExists(atPath: candidateURL.path, isDirectory: &isDirectory) || isDirectory.boolValue {
                issues.append("screenshotCandidates[\(index)] file is missing: \(path)")
            } else if fileSize(candidateURL) == 0 {
                issues.append("screenshotCandidates[\(index)] file is empty: \(path)")
            }
        }
        let screenshotCandidatesReady = !screenshotCandidates.isEmpty
            && screenshotCandidates.count <= 10
            && !issues.contains { $0.hasPrefix("screenshotCandidates") }

        let privacy = draft["privacySummary"] as? [String: Any] ?? [:]
        let privacyDraftReady = stringValue(privacy["posture"]) == "local-first"
            && bool(privacy["collectsData"]) == false
            && !stringArray(privacy["notes"]).isEmpty
        if !privacyDraftReady {
            issues.append("privacySummary must describe local-first posture, collectsData=false, and bounded notes.")
        }

        let permissionPurposeNotes = stringArray(draft["permissionPurposeNotes"])
        if permissionPurposeNotes.isEmpty {
            issues.append("permissionPurposeNotes must describe permission use.")
        }

        let reviewNotes = stringArray(draft["reviewNotes"])
        let reviewNotesDraftReady = !reviewNotes.isEmpty
            && reviewNotes.contains { $0.localizedCaseInsensitiveContains("local-first") }
            && reviewNotes.contains { $0.localizedCaseInsensitiveContains("permission") }
            && reviewNotes.contains { $0.localizedCaseInsensitiveContains("record") }
        if !reviewNotesDraftReady {
            issues.append("reviewNotes must mention local-first behavior, permissions, and recording.")
        }

        let finalAssetsReady = bool(draft["finalAssetsReady"])
        let finalMetadataApproved = bool(draft["finalMetadataApproved"])
        let legalApproved = bool(draft["legalApproved"])
        let appStoreConnectRecordCreated = bool(draft["appStoreConnectRecordCreated"])
        let externalUploadAttempted = bool(draft["externalUploadAttempted"])
        let rawTranscriptStored = bool(draft["rawTranscriptStored"])
        let rawAudioStored = bool(draft["rawAudioStored"])
        let rawUITextStored = bool(draft["rawUITextStored"])

        let mustRemainFalse: [(String, Bool)] = [
            ("finalAssetsReady", finalAssetsReady),
            ("finalMetadataApproved", finalMetadataApproved),
            ("legalApproved", legalApproved),
            ("appStoreConnectRecordCreated", appStoreConnectRecordCreated),
            ("externalUploadAttempted", externalUploadAttempted),
            ("rawTranscriptStored", rawTranscriptStored),
            ("rawAudioStored", rawAudioStored),
            ("rawUITextStored", rawUITextStored)
        ]
        for (key, value) in mustRemainFalse where value {
            issues.append("\(key) must remain false for this local draft smoke.")
        }

        let status = metadataDraftReady
            && screenshotCandidatesReady
            && privacyDraftReady
            && !permissionPurposeNotes.isEmpty
            && reviewNotesDraftReady
            && mustRemainFalse.allSatisfy { !$0.1 }
            ? "pass"
            : "fail"

        return AppStoreAssetsSmokeReport(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            status: status,
            draftPath: relativePath(draftURL, rootURL: rootURL),
            metadataDraftReady: metadataDraftReady,
            screenshotCandidatesReady: screenshotCandidatesReady,
            privacyDraftReady: privacyDraftReady,
            reviewNotesDraftReady: reviewNotesDraftReady,
            finalAssetsReady: finalAssetsReady,
            finalMetadataApproved: finalMetadataApproved,
            legalApproved: legalApproved,
            appStoreConnectRecordCreated: appStoreConnectRecordCreated,
            externalUploadAttempted: externalUploadAttempted,
            rawTranscriptStored: rawTranscriptStored,
            rawAudioStored: rawAudioStored,
            rawUITextStored: rawUITextStored,
            screenshotCount: screenshotCandidates.count,
            issues: issues
        )
    }

    private static func readJSONObject(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        return dictionary
    }

    private static func stringValue(_ value: Any?) -> String {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func stringArray(_ value: Any?) -> [String] {
        (value as? [String])?.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty } ?? []
    }

    private static func bool(_ value: Any?) -> Bool {
        value as? Bool ?? false
    }

    private static func fileSize(_ url: URL) -> UInt64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return UInt64(values?.fileSize ?? 0)
    }

    private static func relativePath(_ url: URL, rootURL: URL) -> String {
        let root = rootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else {
            return path
        }
        return String(path.dropFirst(root.count + 1))
    }
}

AppStoreAssetsSmoke.main()
