import Foundation
import StampdrillCore

/// `stampdrill import`: turns Postman, Insomnia, Bruno, HAR, curl and OpenAPI
/// files into request files, and their environments into `environment.stamp`.
struct ImportCommand {
    let arguments: Arguments
    let terminal: Terminal

    func execute() throws -> Int32 {
        let t = terminal
        guard !arguments.paths.isEmpty else {
            throw UsageError(description: "import expects \(Importer.supportedDescription)")
        }
        var temporary: [URL] = []
        let urls = try arguments.paths.map { path -> URL in
            guard path == "-" else { return URL(fileURLWithPath: path) }
            // curl commands piped in.
            let data = FileHandle.standardInput.readDataToEndOfFile()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("stampdrill-import-\(UUID().uuidString).txt")
            try data.write(to: url)
            temporary.append(url)
            return url
        }
        defer {
            for url in temporary { try? FileManager.default.removeItem(at: url) }
        }

        let manager = FileManager.default
        // The import must not take names the workspace it lands in already uses.
        let here = URL(fileURLWithPath: arguments.outputPath ?? ".", isDirectory: true)
        let existing = ImportedEnvironmentChanges.declaredNames(in: [Workspace.environmentFileName, Workspace.localEnvironmentFileName].map {
            (try? String(contentsOf: Workspace.root(containing: here).appendingPathComponent($0), encoding: .utf8)) ?? ""
        })
        let output = try Importer.convert(urls, existingNames: existing)
        let destination = URL(fileURLWithPath: arguments.outputPath ?? Importer.folderName(for: output.title), isDirectory: true)
        for (path, _) in output.files {
            let url = destination.appendingPathComponent(path)
            if manager.fileExists(atPath: url.path) {
                throw UsageError(description: "\(url.path) already exists; choose another folder with -o")
            }
        }
        for (path, text) in output.files {
            let url = destination.appendingPathComponent(path)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            t.out("  \(t.paint("created", .green)) \(url.path)")
        }

        // Environments go to the workspace the folder belongs to, or make the folder one.
        if !output.environment.isEmpty {
            try manager.createDirectory(at: destination, withIntermediateDirectories: true)
            let root = Workspace.root(containing: destination)
            var kept: [String] = []
            func read(_ name: String) -> String { (try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)) ?? "" }
            let before = (shared: read(Workspace.environmentFileName), local: read(Workspace.localEnvironmentFileName))
            for local in [false, true] {
                let url = root.appendingPathComponent(local ? Workspace.localEnvironmentFileName : Workspace.environmentFileName)
                let existing = local ? before.local : before.shared
                let (text, keptHere) = output.environment.apply(to: existing, other: local ? before.shared : before.local, local: local)
                kept += keptHere
                guard text != existing else { continue }
                try Data(text.utf8).write(to: url)
                t.out("  \(t.paint(existing.isEmpty ? "created" : "updated", .green)) \(url.path)")
            }
            // Any repository above the workspace counts: the secrets file must stay out of git.
            if !output.environment.local.isEmpty, isInGitRepository(root) {
                try? GitRepository.ensureGitignore(in: root)
            }
            if !kept.isEmpty {
                t.out("  \(t.paint("kept", .yellow)) existing values for \(Set(kept).sorted().joined(separator: ", "))")
            }
        }

        for warning in output.warnings {
            t.out("  \(t.paint("note", .yellow)) \(warning)")
        }
        let files = output.files.count
        t.out(t.paint("Imported \(output.title) (\(output.format)): \(plural(output.requestCount, "request")) in \(plural(files, "file"))", .bold))
        return 0
    }

    private func plural(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    private func isInGitRepository(_ root: URL) -> Bool {
        var folder = root.standardizedFileURL
        while true {
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path) { return true }
            let parent = folder.deletingLastPathComponent()
            if parent.path == folder.path { return false }
            folder = parent
        }
    }
}
