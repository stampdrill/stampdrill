import Foundation

/// Just enough git to share a workspace with a team: status, commit, pull,
/// push, clone and first-time setup. It drives the `git` the user already
/// has, so their SSH keys and credential helpers keep working.
public struct GitRepository: Sendable {
    public struct Status: Equatable, Sendable {
        public struct Change: Equatable, Sendable, Identifiable {
            public enum Kind: String, Sendable {
                case added = "A"
                case modified = "M"
                case deleted = "D"
                case renamed = "R"
                case untracked = "?"
                case conflicted = "U"
            }

            public var path: String
            public var kind: Kind
            public var id: String { path }
        }

        public var branch: String?
        public var upstream: String?
        public var ahead = 0
        public var behind = 0
        public var changes: [Change] = []

        public var hasConflicts: Bool { changes.contains { $0.kind == .conflicted } }
        public var isClean: Bool { changes.isEmpty }
    }

    public struct Failure: Error, LocalizedError, Sendable {
        public var command: String
        public var output: String

        public var errorDescription: String? {
            let detail = output
                .split(separator: "\n")
                .map { $0.replacingOccurrences(of: "fatal: ", with: "").replacingOccurrences(of: "error: ", with: "") }
                .first { !$0.hasPrefix("hint:") && !$0.isEmpty } ?? "failed"
            return "git \(command): \(detail)"
        }
    }

    public let root: URL
    public var executable: URL

    public init(root: URL, executable: URL = URL(fileURLWithPath: "/usr/bin/git")) {
        self.root = root
        self.executable = executable
    }

    public static var isAvailable: Bool {
        // /usr/bin/git is a shim that refuses to run inside the App Sandbox.
        guard ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil else { return false }
        return FileManager.default.isExecutableFile(atPath: "/usr/bin/git")
    }

    public var isRepository: Bool {
        get async { (try? await run(["rev-parse", "--is-inside-work-tree"]))?.trimmingCharacters(in: .whitespacesAndNewlines) == "true" }
    }

    // MARK: Reading

    public func status() async throws -> Status {
        let output = try await run(["status", "--porcelain=v2", "--branch", "--untracked-files=all"])
        return Self.parseStatus(output)
    }

    static func parseStatus(_ output: String) -> Status {
        var status = Status()
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: false)
            switch parts.first {
            case "#":
                guard parts.count >= 3 else { continue }
                switch parts[1] {
                case "branch.head": status.branch = parts[2] == "(detached)" ? nil : String(parts[2])
                case "branch.upstream": status.upstream = String(parts[2])
                case "branch.ab":
                    status.ahead = Int(parts[2].dropFirst()) ?? 0
                    status.behind = parts.count > 3 ? Int(parts[3].dropFirst()) ?? 0 : 0
                default: break
                }
            case "1":
                guard parts.count >= 9 else { continue }
                status.changes.append(.init(path: parts[8...].joined(separator: " "), kind: kind(parts[1])))
            case "2":
                guard parts.count >= 10 else { continue }
                let paths = parts[9...].joined(separator: " ").split(separator: "\t")
                status.changes.append(.init(path: String(paths.first ?? ""), kind: .renamed))
            case "u":
                guard parts.count >= 11 else { continue }
                status.changes.append(.init(path: parts[10...].joined(separator: " "), kind: .conflicted))
            case "?":
                status.changes.append(.init(path: String(line.dropFirst(2)), kind: .untracked))
            default:
                break
            }
        }
        return status
    }

    private static func kind(_ code: Substring) -> Status.Change.Kind {
        let letters = code.filter { $0 != "." }
        if letters.contains("D") { return .deleted }
        if letters.contains("A") { return .added }
        if letters.contains("R") { return .renamed }
        return .modified
    }

    public func recentCommits(limit: Int = 10) async throws -> [(hash: String, subject: String, author: String, date: Date)] {
        let output = try await run(["log", "-\(limit)", "--format=%h%x1f%s%x1f%an%x1f%at"])
        return output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard fields.count == 4, let seconds = Double(fields[3]) else { return nil }
            return (String(fields[0]), String(fields[1]), String(fields[2]), Date(timeIntervalSince1970: seconds))
        }
    }

    public func remoteURL() async -> String? {
        (try? await run(["remote", "get-url", "origin"]))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Changing

    /// Stages everything in the workspace and commits it.
    public func commitAll(message: String) async throws {
        try await run(["add", "--all"])
        try await run(["commit", "--message", message])
    }

    public func fetch() async throws {
        try await run(["fetch", "--prune"])
    }

    public func pull() async throws {
        try await run(["pull", "--rebase", "--autostash"])
    }

    public func push() async throws {
        let status = try await status()
        if status.upstream == nil, let branch = status.branch {
            try await run(["push", "--set-upstream", "origin", branch])
        } else {
            try await run(["push"])
        }
    }

    /// Pulls, then pushes whatever is ahead.
    public func sync() async throws {
        let status = try await status()
        if status.upstream != nil {
            try await pull()
        }
        if try await self.status().ahead > 0 || status.upstream == nil {
            try await push()
        }
    }

    /// Turns a plain workspace folder into a repository that pushes to `remote`.
    public func share(remote: String, message: String = "Share Stampdrill workspace") async throws {
        if !(await isRepository) {
            try await run(["init", "--initial-branch=main"])
        }
        try Self.ensureGitignore(in: root)
        if await remoteURL() == nil {
            try await run(["remote", "add", "origin", remote])
        } else {
            try await run(["remote", "set-url", "origin", remote])
        }
        try await run(["add", "--all"])
        if !(try await status().isClean) {
            try await run(["commit", "--message", message])
        }
        try await push()
    }

    public static func clone(_ remote: String, into destination: URL) async throws {
        let parent = GitRepository(root: destination.deletingLastPathComponent())
        try await parent.run(["clone", remote, destination.path], in: destination.deletingLastPathComponent())
    }

    /// Keeps personal files and generated output out of the repository.
    public static func ensureGitignore(in root: URL) throws {
        let url = root.appendingPathComponent(".gitignore")
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let wanted = [Workspace.localEnvironmentFileName, "reports/", "responses/", ".DS_Store"]
        let missing = wanted.filter { entry in !existing.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == entry } }
        guard !missing.isEmpty else { return }
        var text = existing
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        if existing.isEmpty { text += "# Stampdrill: personal variables and generated files stay local\n" }
        text += missing.joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    // MARK: Process

    @discardableResult
    func run(_ arguments: [String], in directory: URL? = nil) async throws -> String {
        let executable = executable
        let directory = directory ?? root
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                process.currentDirectoryURL = directory
                var environment = ProcessInfo.processInfo.environment
                // Never wait for a password prompt nobody can see.
                environment["GIT_TERMINAL_PROMPT"] = "0"
                environment["GIT_ASKPASS"] = "/usr/bin/false"
                environment["LC_ALL"] = "C"
                process.environment = environment

                let output = Pipe()
                process.standardOutput = output
                process.standardError = output
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: Failure(command: arguments.first ?? "", output: error.localizedDescription))
                    return
                }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let text = String(decoding: data, as: UTF8.self)
                if process.terminationStatus == 0 {
                    continuation.resume(returning: text)
                } else {
                    continuation.resume(throwing: Failure(command: arguments.first ?? "", output: text))
                }
            }
        }
    }
}
