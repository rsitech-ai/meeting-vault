#!/usr/bin/env swift
import Foundation

let rootURL = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent()
    .deletingLastPathComponent()

let executable = "MeetingVaultAppShortcutsCatalogSmoke"
var arguments = Array(CommandLine.arguments.dropFirst())
let process = Process()
process.currentDirectoryURL = rootURL
process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
process.arguments = ["run", executable] + arguments
try process.run()
process.waitUntilExit()
exit(process.terminationStatus)
