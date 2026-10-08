import Foundation
import Testing

/// The exit codes the documentation promises: 0 passed, 1 a check failed,
/// 2 a file could not be read or parsed.
@Suite("Exit codes")
struct ExitCodeTests {
    private static let binary: URL = {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root = root.deletingLastPathComponent() }
        let candidates = ["\u{2E}build/debug/stampdrill", ".build/out/Products/Debug/stampdrill",
                          ".build/release/stampdrill", ".build/out/Products/Release/stampdrill"]
        guard let found = candidates.map({ root.appendingPathComponent($0) })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
        else { fatalError("build the command first: swift build --package-path StampdrillKit") }
        return found
    }()

    private func status(_ arguments: [String], in folder: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = Self.binary
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        var environment = ProcessInfo.processInfo.environment
        environment["STAMPDRILL_NO_BANNER"] = "1"
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func folder(_ files: [String: String]) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("exit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (name, text) in files {
            try text.write(to: url.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return url
    }

    @Test func aCleanWorkspaceIsZero() throws {
        let url = try folder(["api.stamp": "### Hello\nGET https://example.invalid/hello\n"])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try status(["check", "."], in: url) == 0)
    }

    @Test func aFileThatCannotBeParsedIsTwo() throws {
        let url = try folder(["broken.stamp": "### Broken\nGET {{unclosed\n"])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try status(["check", "."], in: url) == 2, "a parse error is 2, which is what the docs promise")
    }

    @Test func aMissingPathIsTwo() throws {
        let url = try folder([:])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try status(["run", "nothing-here.stamp"], in: url) == 2)
        #expect(try status(["frobnicate"], in: url) == 2, "an unknown command is a usage error")
    }
}
