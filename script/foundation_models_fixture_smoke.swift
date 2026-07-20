#!/usr/bin/env swift
import Foundation

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0])
let rootURL = scriptURL
    .deletingLastPathComponent()
    .deletingLastPathComponent()

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
process.arguments = ["run", "MeetingVaultFoundationModelsSmoke"] + Array(CommandLine.arguments.dropFirst())
process.currentDirectoryURL = rootURL
process.standardInput = FileHandle.standardInput
process.standardOutput = FileHandle.standardOutput
process.standardError = FileHandle.standardError

do {
    try process.run()
    process.waitUntilExit()
    exit(process.terminationStatus)
} catch {
    fputs("failed to run MeetingVaultFoundationModelsSmoke: \(error.localizedDescription)\n", stderr)
    exit(1)
}
