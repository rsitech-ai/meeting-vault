import Foundation
import MeetingVaultCore

@main
struct MeetingVaultLocalModelSelfCheck {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else { exit(64) }
        try await LocalModelSubprocessSelfCheck.run(
            assetID: CommandLine.arguments[1],
            root: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        )
    }
}
