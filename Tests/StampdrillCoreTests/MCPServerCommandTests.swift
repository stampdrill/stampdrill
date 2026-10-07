import Foundation
import Testing

/// Drives the built `stampdrill mcp` server the way an agent would: one JSON-RPC
/// message per line on stdin, one reply per line on stdout.
@Suite("Serving a workspace over MCP")
struct MCPServerCommandTests {
    /// The built command, found from this file rather than from the test bundle,
    /// which moves between build systems.
    private static let binary: URL = {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root = root.deletingLastPathComponent() }  // .../StampdrillKit
        let candidates = [
            root.appendingPathComponent(".build/debug/stampdrill"),
            root.appendingPathComponent(".build/out/Products/Debug/stampdrill"),
            root.appendingPathComponent(".build/release/stampdrill"),
            root.appendingPathComponent(".build/out/Products/Release/stampdrill"),
        ]
        guard let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            fatalError("build the command first: swift build --package-path StampdrillKit")
        }
        return found
    }()

    private func converse(_ requests: [String], workspace: URL) throws -> [[String: Any]] {
        let process = Process()
        process.executableURL = Self.binary
        process.arguments = ["mcp", workspace.path]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        input.fileHandleForWriting.write(Data((requests.joined(separator: "\n") + "\n").utf8))
        input.fileHandleForWriting.closeFile()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let replies = String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        #expect(process.terminationStatus == 0, "the server exited with \(process.terminationStatus): \(String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))")
        return replies
    }

    private func reply(_ replies: [[String: Any]], id: Int) -> [String: Any]? {
        replies.first { ($0["id"] as? Int) == id }
    }

    private func result(_ replies: [[String: Any]], id: Int) -> [String: Any]? {
        reply(replies, id: id)?["result"] as? [String: Any]
    }

    private func text(_ replies: [[String: Any]], id: Int) -> String {
        let content = result(replies, id: id)?["content"] as? [[String: Any]] ?? []
        return content.compactMap { $0["text"] as? String }.joined()
    }

    private func workspace() throws -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mcp-server-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        @baseUrl = https://example.invalid

        ### Hello
        @name hello
        GET {{baseUrl}}/hello

        > assert status == 200
        """.write(to: folder.appendingPathComponent("api.stamp"), atomically: true, encoding: .utf8)
        return folder
    }

    @Test func itAnswersTheHandshakeAndListsItsTools() throws {
        let folder = try workspace()
        defer { try? FileManager.default.removeItem(at: folder) }

        let replies = try converse([
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
        ], workspace: folder)

        #expect(replies.count == 2, "a notification must not get a reply, got \(replies.count) replies")
        let handshake = result(replies, id: 1)
        #expect((handshake?["serverInfo"] as? [String: Any])?["name"] as? String == "stampdrill")
        #expect(handshake?["protocolVersion"] as? String == "2025-11-25")

        let tools = result(replies, id: 2)?["tools"] as? [[String: Any]] ?? []
        let names = Set(tools.compactMap { $0["name"] as? String })
        #expect(names == ["list_requests", "check", "run_request", "run_plan", "run_load", "show_environment"])
        #expect(tools.allSatisfy { $0["inputSchema"] != nil && $0["description"] != nil })
    }

    @Test func itListsRequestsAndChecksTheWorkspace() throws {
        let folder = try workspace()
        defer { try? FileManager.default.removeItem(at: folder) }

        let replies = try converse([
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{}}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_requests","arguments":{}}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"check","arguments":{}}}"#,
        ], workspace: folder)

        #expect(text(replies, id: 2).contains("hello"))
        #expect(text(replies, id: 3).contains("No problems"))
        #expect(result(replies, id: 3)?["isError"] as? Bool == false)
    }

    @Test func itReportsAMistakeInsteadOfCrashing() throws {
        let folder = try workspace()
        defer { try? FileManager.default.removeItem(at: folder) }
        try "### Broken\nGET {{unclosed\n".write(to: folder.appendingPathComponent("broken.stamp"), atomically: true, encoding: .utf8)

        let replies = try converse([
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{}}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"check","arguments":{}}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"run_request","arguments":{"request":"nothing"}}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"nonsense/method"}"#,
        ], workspace: folder)

        #expect(result(replies, id: 2)?["isError"] as? Bool == true, "a file with an error has to come back as an error")
        #expect(result(replies, id: 3)?["isError"] as? Bool == true)

        let unknown = reply(replies, id: 4)?["error"] as? [String: Any]
        #expect(unknown?["code"] as? Int == -32601, "an unknown method is a JSON-RPC error, not a tool error")
    }
}
