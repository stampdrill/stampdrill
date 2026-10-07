import Foundation
import Testing
@testable import StampdrillCore

@Suite(.enabled(if: GitRepository.isAvailable))
struct GitRepositoryTests {
    private func temporaryFolder(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stampdrill-git-\(UUID().uuidString)").appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func configure(_ repository: GitRepository) async throws {
        try await repository.run(["config", "user.name", "Stampdrill Tests"])
        try await repository.run(["config", "user.email", "tests@example.com"])
        try await repository.run(["config", "commit.gpgsign", "false"])
    }

    @Test func parsesPorcelainStatus() {
        let status = GitRepository.parseStatus("""
        # branch.oid 1234
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +2 -1
        1 .M N... 100644 100644 100644 abc abc environment.stamp
        1 A. N... 000000 100644 100644 000 abc Blog/New post.stamp
        u UU N... 100644 100644 100644 100644 a b c conflict.stamp
        ? notes.txt
        """)
        #expect(status.branch == "main")
        #expect(status.upstream == "origin/main")
        #expect(status.ahead == 2)
        #expect(status.behind == 1)
        #expect(status.changes.map(\.path) == ["environment.stamp", "Blog/New post.stamp", "conflict.stamp", "notes.txt"])
        #expect(status.changes.map(\.kind) == [.modified, .added, .conflicted, .untracked])
        #expect(status.hasConflicts)
    }

    @Test func sharesAndSyncsBetweenTwoClones() async throws {
        let remote = try temporaryFolder("team.git")
        _ = try await GitRepository(root: remote).run(["init", "--bare", "--initial-branch=main"])

        // Alice shares her workspace.
        let alice = try temporaryFolder("alice")
        try "GET https://example.com\n".write(to: alice.appendingPathComponent("ping.stamp"), atomically: true, encoding: .utf8)
        try "token = \"alice-secret\"\n".write(to: alice.appendingPathComponent("environment.local.stamp"), atomically: true, encoding: .utf8)
        let aliceRepo = GitRepository(root: alice)
        try await aliceRepo.run(["init", "--initial-branch=main"])
        try await configure(aliceRepo)
        try await aliceRepo.share(remote: remote.path)
        #expect(try await aliceRepo.status().isClean)
        let ignored = try String(contentsOf: alice.appendingPathComponent(".gitignore"), encoding: .utf8)
        #expect(ignored.contains("environment.local.stamp"))

        // Bob clones it and changes a request.
        let bob = try temporaryFolder("bob")
        try await GitRepository.clone(remote.path, into: bob)
        let bobRepo = GitRepository(root: bob)
        try await configure(bobRepo)
        #expect(FileManager.default.fileExists(atPath: bob.appendingPathComponent("ping.stamp").path))
        #expect(!FileManager.default.fileExists(atPath: bob.appendingPathComponent("environment.local.stamp").path))
        try "GET https://example.com/v2\n".write(to: bob.appendingPathComponent("ping.stamp"), atomically: true, encoding: .utf8)
        #expect(try await bobRepo.status().changes.map(\.kind) == [.modified])
        try await bobRepo.commitAll(message: "Use v2")
        try await bobRepo.sync()

        // Alice picks it up.
        try await aliceRepo.fetch()
        #expect(try await aliceRepo.status().behind == 1)
        try await aliceRepo.sync()
        let text = try String(contentsOf: alice.appendingPathComponent("ping.stamp"), encoding: .utf8)
        #expect(text == "GET https://example.com/v2\n")
        #expect(try await aliceRepo.recentCommits(limit: 1).first?.subject == "Use v2")
    }

    @Test func reportsReadableFailures() async throws {
        let folder = try temporaryFolder("plain")
        let failure = await #expect(throws: GitRepository.Failure.self) {
            try await GitRepository(root: folder).status()
        }
        #expect(failure?.errorDescription?.hasPrefix("git status: not a git repository") == true)
    }
}
