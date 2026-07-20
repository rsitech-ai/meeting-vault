#!/usr/bin/env swift
import Foundation

let repositoryRoot = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let process = Process()
process.currentDirectoryURL = repositoryRoot
process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
process.arguments = [
    "swift",
    "run",
    "--quiet",
    "MeetingVaultLocalModelLifecycleSmoke",
] + Array(CommandLine.arguments.dropFirst())
try process.run()
process.waitUntilExit()
exit(process.terminationStatus)
