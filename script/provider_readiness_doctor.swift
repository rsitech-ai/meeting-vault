#!/usr/bin/env swift
import Foundation

let rootURL = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent()
    .deletingLastPathComponent()

let process = Process()
process.currentDirectoryURL = rootURL
process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
process.arguments = ["run", "MeetingVaultProviderReadinessDoctor"] + Array(CommandLine.arguments.dropFirst())
try process.run()
process.waitUntilExit()
exit(process.terminationStatus)
