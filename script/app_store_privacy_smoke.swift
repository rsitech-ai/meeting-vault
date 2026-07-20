#!/usr/bin/env swift
import Foundation

struct AppStorePrivacySmokeReport: Codable {
    var timestamp: String
    var status: String
    var draftPath: String
    var posture: String
    var appStorePrivacyAnswerStatus: String
    var localInventoryReady: Bool
    var noCollectionClaimReady: Bool
    var permissionNotesReady: Bool
    var retentionNotesReady: Bool
    var privacyManifestReady: Bool
    var finalAppStoreConnectAnswersApproved: Bool
    var privacyOwnerApproved: Bool
    var legalApproved: Bool
    var appStoreConnectRecordCreated: Bool
    var externalUploadAttempted: Bool
    var rawTranscriptStored: Bool
    var rawAudioStored: Bool
    var rawUITextStored: Bool
    var handledLocalDataTypeCount: Int
    var collectedDataTypeCount: Int
    var issues: [String]
}

enum AppStorePrivacySmoke {
    static func main() {
        let rootURL = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let date = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        var draftURL = rootURL.appendingPathComponent("docs/app-store-privacy-draft.json")
        var outputURL = rootURL
            .appendingPathComponent("docs", isDirectory: true)
            .appendingPathComponent("evidence", isDirectory: true)
            .appendingPathComponent("app-store-privacy-smoke-\(date).json")

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
                usage: script/app_store_privacy_smoke.swift [--draft docs/app-store-privacy-draft.json] [--output PATH]

                Validates the repo-owned App Store privacy draft without creating
                an App Store Connect record, submitting privacy answers, uploading
                externally, or storing raw transcript/UI/audio content.
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
            fputs("failed to write app store privacy smoke: \(error.localizedDescription)\n", stderr)
            exit(1)
        }

        print("Wrote \(outputURL.path)")
        print("status=\(report.status) localInventoryReady=\(report.localInventoryReady) noCollectionClaimReady=\(report.noCollectionClaimReady)")
        exit(report.status == "pass" ? 0 : 1)
    }

    private static func buildReport(rootURL: URL, draftURL: URL) -> AppStorePrivacySmokeReport {
        var issues: [String] = []
        guard let draft = readJSONObject(at: draftURL) else {
            return AppStorePrivacySmokeReport(
                timestamp: ISO8601DateFormatter().string(from: Date()),
                status: "fail",
                draftPath: relativePath(draftURL, rootURL: rootURL),
                posture: "",
                appStorePrivacyAnswerStatus: "",
                localInventoryReady: false,
                noCollectionClaimReady: false,
                permissionNotesReady: false,
                retentionNotesReady: false,
                privacyManifestReady: false,
                finalAppStoreConnectAnswersApproved: false,
                privacyOwnerApproved: false,
                legalApproved: false,
                appStoreConnectRecordCreated: false,
                externalUploadAttempted: false,
                rawTranscriptStored: false,
                rawAudioStored: false,
                rawUITextStored: false,
                handledLocalDataTypeCount: 0,
                collectedDataTypeCount: 0,
                issues: ["Missing or unreadable App Store privacy draft JSON."]
            )
        }

        let posture = stringValue(draft["posture"])
        let answerStatus = stringValue(draft["appStorePrivacyAnswerStatus"])
        if posture != "local-first" {
            issues.append("posture must be local-first.")
        }
        if answerStatus != "draft-local" {
            issues.append("appStorePrivacyAnswerStatus must remain draft-local until App Store Connect entry is approved.")
        }

        let handledLocalTypes = draft["dataTypesHandledLocally"] as? [[String: Any]] ?? []
        let collectedTypes = stringArray(draft["collectedDataTypes"])
        let requiredLocalTypeNames = ["Audio Data", "User Content", "Identifiers", "Diagnostics"]
        let handledNames = handledLocalTypes.map { stringValue($0["name"]) }
        for requiredName in requiredLocalTypeNames where !handledNames.contains(requiredName) {
            issues.append("dataTypesHandledLocally must include \(requiredName).")
        }
        for (index, localType) in handledLocalTypes.enumerated() {
            if stringValue(localType["name"]).isEmpty {
                issues.append("dataTypesHandledLocally[\(index)].name is required.")
            }
            if stringArray(localType["examples"]).isEmpty {
                issues.append("dataTypesHandledLocally[\(index)].examples must not be empty.")
            }
            if stringValue(localType["storage"]).isEmpty {
                issues.append("dataTypesHandledLocally[\(index)].storage is required.")
            }
            if localType["offDeviceByDefault"] as? Bool == nil {
                issues.append("dataTypesHandledLocally[\(index)].offDeviceByDefault must be an explicit boolean.")
            }
        }
        let localInventoryReady = !handledLocalTypes.isEmpty
            && requiredLocalTypeNames.allSatisfy { handledNames.contains($0) }
            && !issues.contains { $0.hasPrefix("dataTypesHandledLocally") }

        let noCollectionClaimReady = bool(draft["appCollectsData"]) == false
            && collectedTypes.isEmpty
            && bool(draft["tracking"]) == false
            && bool(draft["linkedToUser"]) == false
            && bool(draft["thirdPartyAdvertising"]) == false
            && bool(draft["analyticsSentOffDevice"]) == false
            && bool(draft["diagnosticsSentOffDevice"]) == false
        if !noCollectionClaimReady {
            issues.append("No-collection draft requires appCollectsData=false, no collectedDataTypes, no tracking, and no off-device analytics/diagnostics.")
        }

        let permissionNotesReady = stringArray(draft["permissionPurposeNotes"]).count >= 3
        if !permissionNotesReady {
            issues.append("permissionPurposeNotes must cover microphone, speech recognition, and file access.")
        }

        let externalProcessingNotes = stringArray(draft["externalProcessingNotes"])
        let hasOffDeviceProcessing = handledLocalTypes.contains { bool($0["offDeviceByDefault"]) }
        let offDeviceProcessingDisclosed = !hasOffDeviceProcessing
            || externalProcessingNotes.contains { note in
                note.localizedCaseInsensitiveContains("Apple Speech")
                    && note.localizedCaseInsensitiveContains("Apple")
            }
        let retentionNotesReady = !stringArray(draft["retentionAndDeletionNotes"]).isEmpty
            && !externalProcessingNotes.isEmpty
            && offDeviceProcessingDisclosed
        if !retentionNotesReady {
            issues.append("retention/deletion notes and truthful external processing disclosures must be drafted.")
        }

        let manifestPath = stringValue(draft["privacyManifestPath"])
        let manifestURL = rootURL.appendingPathComponent(manifestPath)
        let privacyManifestReady = !manifestPath.isEmpty
            && FileManager.default.fileExists(atPath: manifestURL.path)
            && bool(draft["privacyManifestStagedInApp"])
        if !privacyManifestReady {
            issues.append("privacyManifestPath must exist and privacyManifestStagedInApp must be true.")
        }

        let finalAnswersApproved = bool(draft["finalAppStoreConnectAnswersApproved"])
        let privacyOwnerApproved = bool(draft["privacyOwnerApproved"])
        let legalApproved = bool(draft["legalApproved"])
        let appStoreConnectRecordCreated = bool(draft["appStoreConnectRecordCreated"])
        let externalUploadAttempted = bool(draft["externalUploadAttempted"])
        let rawTranscriptStored = bool(draft["rawTranscriptStored"])
        let rawAudioStored = bool(draft["rawAudioStored"])
        let rawUITextStored = bool(draft["rawUITextStored"])

        let mustRemainFalse: [(String, Bool)] = [
            ("finalAppStoreConnectAnswersApproved", finalAnswersApproved),
            ("privacyOwnerApproved", privacyOwnerApproved),
            ("legalApproved", legalApproved),
            ("appStoreConnectRecordCreated", appStoreConnectRecordCreated),
            ("externalUploadAttempted", externalUploadAttempted),
            ("rawTranscriptStored", rawTranscriptStored),
            ("rawAudioStored", rawAudioStored),
            ("rawUITextStored", rawUITextStored)
        ]
        for (key, value) in mustRemainFalse where value {
            issues.append("\(key) must remain false for this local privacy draft smoke.")
        }

        let status = posture == "local-first"
            && answerStatus == "draft-local"
            && localInventoryReady
            && noCollectionClaimReady
            && permissionNotesReady
            && retentionNotesReady
            && privacyManifestReady
            && mustRemainFalse.allSatisfy { !$0.1 }
            ? "pass"
            : "fail"

        return AppStorePrivacySmokeReport(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            status: status,
            draftPath: relativePath(draftURL, rootURL: rootURL),
            posture: posture,
            appStorePrivacyAnswerStatus: answerStatus,
            localInventoryReady: localInventoryReady,
            noCollectionClaimReady: noCollectionClaimReady,
            permissionNotesReady: permissionNotesReady,
            retentionNotesReady: retentionNotesReady,
            privacyManifestReady: privacyManifestReady,
            finalAppStoreConnectAnswersApproved: finalAnswersApproved,
            privacyOwnerApproved: privacyOwnerApproved,
            legalApproved: legalApproved,
            appStoreConnectRecordCreated: appStoreConnectRecordCreated,
            externalUploadAttempted: externalUploadAttempted,
            rawTranscriptStored: rawTranscriptStored,
            rawAudioStored: rawAudioStored,
            rawUITextStored: rawUITextStored,
            handledLocalDataTypeCount: handledLocalTypes.count,
            collectedDataTypeCount: collectedTypes.count,
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

    private static func relativePath(_ url: URL, rootURL: URL) -> String {
        let root = rootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else {
            return path
        }
        return String(path.dropFirst(root.count + 1))
    }
}

AppStorePrivacySmoke.main()
