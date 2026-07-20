#!/usr/bin/env swift
import Foundation

let rootURL = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent()
    .deletingLastPathComponent()

let process = Process()
process.currentDirectoryURL = rootURL
let builtExecutableURL = rootURL
    .appendingPathComponent(".build", isDirectory: true)
    .appendingPathComponent("debug", isDirectory: true)
    .appendingPathComponent("MeetingVaultReleaseBlockerDoctor")
if FileManager.default.isExecutableFile(atPath: builtExecutableURL.path) {
    process.executableURL = builtExecutableURL
    process.arguments = Array(CommandLine.arguments.dropFirst())
} else {
    process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
    process.arguments = ["run", "MeetingVaultReleaseBlockerDoctor"] + Array(CommandLine.arguments.dropFirst())
}
try process.run()
process.waitUntilExit()
exit(process.terminationStatus)
