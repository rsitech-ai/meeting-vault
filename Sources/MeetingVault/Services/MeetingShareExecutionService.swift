import AppKit
import Foundation
import MeetingVaultCore

struct MeetingShareExecutionResult: Equatable {
    var destination: MeetingShareDestination
    var fileCount: Int
}

enum MeetingVaultShareExecutionError: Error, Equatable, LocalizedError {
    case confirmationRequired
    case noPreparedShare
    case noFiles
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .confirmationRequired:
            "Confirm share before opening a destination"
        case .noPreparedShare:
            "Prepare a share before opening a destination"
        case .noFiles:
            "Share package has no files"
        case let .unavailable(message):
            message
        }
    }
}

@MainActor
protocol MeetingShareExecuting {
    func execute(_ manifest: MeetingShareManifest) throws -> MeetingShareExecutionResult
}

@MainActor
struct AppKitMeetingShareExecutor: MeetingShareExecuting {
    func execute(_ manifest: MeetingShareManifest) throws -> MeetingShareExecutionResult {
        let urls = manifest.files.map(\.url)
        guard !urls.isEmpty else {
            throw MeetingVaultShareExecutionError.noFiles
        }

        switch manifest.destination {
        case .finderReveal:
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        case .manualCopy:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            if !pasteboard.writeObjects(urls as [NSURL]) {
                pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
            }
        case .systemShareSheet:
            guard let view = NSApp.keyWindow?.contentView ?? NSApp.mainWindow?.contentView else {
                throw MeetingVaultShareExecutionError.unavailable("Open a MeetingVault window before using the system share sheet")
            }
            NSSharingServicePicker(items: urls).show(
                relativeTo: .zero,
                of: view,
                preferredEdge: .minY
            )
        }

        return MeetingShareExecutionResult(
            destination: manifest.destination,
            fileCount: urls.count
        )
    }
}
