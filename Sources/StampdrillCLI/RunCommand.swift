import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import StampdrillCore
import Stamp

struct RunCommand {
    let arguments: Arguments
    let terminal: Terminal

    func execute() async throws -> Int32 {
        let target = try WorkspaceTarget(arguments.paths)
        let workspace = target.workspace

        for file in target.files where file.document.hasErrors {
            printDiagnostics(file, terminal: terminal)
        }
        guard !target.files.contains(where: { $0.document.hasErrors }) else { return 2 }

        let selection = try selection(in: workspace)
        let runner = Runner(
            workspace: workspace,
            selection: selection,
            overrides: Dictionary(arguments.variables.map { ($0.0, Value.string($0.1)) }) { _, last in last },
            transport: PlatformHTTPTransport(userAgent: "stampdrill")
        )

        let references = try references(in: target)
        guard !references.isEmpty else {
            terminal.error("no requests to run")
            return 2
        }

        let printer = ResultPrinter(terminal: terminal, verbose: arguments.verbose, quiet: arguments.quiet, showSecrets: arguments.showSecrets)
        var results: [RunResult] = []
        for reference in references {
            results += await runner.run(reference) { printer.print($0) }
        }
        printer.summary(results)

        if let path = arguments.outputPath, let response = results.last(where: { !$0.isDependency })?.response {
            let url = URL(fileURLWithPath: path)
            let destination = url.hasDirectoryPath ? url.appendingPathComponent(response.suggestedFileName) : url
            try response.body.write(to: destination, options: .atomic)
            terminal.out(terminal.paint("saved \(formatBytes(response.body.count)) to \(destination.path)", .gray))
        }

        let saved = results.flatMap(\.savedVariables)
        if arguments.savesVariables, !saved.isEmpty {
            let url = workspace.root.appendingPathComponent(Workspace.localEnvironmentFileName)
            let text = SavedVariables.apply(saved, selection: selection, environment: workspace.environment, to: workspace.localEnvironmentFile?.text ?? "")
            try Data(text.utf8).write(to: url, options: .atomic)
            terminal.out(terminal.paint("saved \(saved.map(\.name).joined(separator: ", ")) to \(Workspace.localEnvironmentFileName)", .gray))
        }
        return results.allSatisfy(\.passed) ? 0 : 1
    }

    private func selection(in workspace: Workspace) throws -> DimensionSelection {
        let environment = workspace.environment
        var selection = environment.defaultSelection
        for (name, value) in arguments.dimensions {
            guard let dimension = environment.dimension(named: name) else {
                let known = environment.dimensions.map(\.name)
                throw UsageError(description: known.isEmpty
                    ? "this workspace declares no dimensions; use --var \(name)=\(value) to set a variable"
                    : "unknown dimension '\(name)'. This workspace has \(known.joined(separator: ", ")). Use --var \(name)=\(value) to set a variable instead")
            }
            guard dimension.values.contains(value) || value == "*" else {
                throw UsageError(description: "'\(name)' has no value '\(value)' (choose from \(dimension.values.joined(separator: ", ")))")
            }
            selection[name] = value == "*" ? nil : value
        }
        return selection
    }

    private func references(in target: WorkspaceTarget) throws -> [RequestReference] {
        guard !arguments.names.isEmpty else {
            return target.files.flatMap { file in
                file.document.requests.map { RequestReference(path: file.relativePath, name: $0.name) }
            }
        }
        return try arguments.names.map { name in
            let matches = target.files.filter { $0.document.request(named: name) != nil }
            guard let file = matches.first else {
                throw UsageError(description: "no request named '\(name)'")
            }
            return RequestReference(path: file.relativePath, name: name)
        }
    }
}

/// A file or folder given on the command line, and the workspace it lives in.
struct WorkspaceTarget {
    let workspace: Workspace
    let files: [WorkspaceFile]

    /// Several files or folders; they must share a workspace.
    init(_ paths: [String]) throws {
        let targets = try (paths.isEmpty ? ["."] : paths).map { try WorkspaceTarget($0) }
        let root = targets[0].workspace.root
        workspace = targets[0].workspace
        guard targets.allSatisfy({ $0.workspace.root == root }) else {
            throw UsageError(description: "the files belong to different workspaces")
        }
        var seen = Set<String>()
        files = targets.flatMap(\.files).filter { seen.insert($0.relativePath).inserted }
    }

    init(_ path: String) throws {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw UsageError(description: "no such file or folder '\(path)'")
        }
        let folderURL = isDirectory.boolValue ? URL(fileURLWithPath: url.path, isDirectory: true) : url
        workspace = try Workspace.load(from: Workspace.root(containing: folderURL))

        if isDirectory.boolValue {
            let prefix = url.path == workspace.root.path ? "" : url.path + "/"
            files = workspace.requestFiles.filter { prefix.isEmpty || $0.url.path.hasPrefix(prefix) }
        } else if let file = workspace.file(for: url) {
            files = [file]
        } else {
            throw UsageError(description: "'\(path)' is not a .stamp file")
        }
    }
}

struct ResultPrinter: Sendable {
    let terminal: Terminal
    let verbose: Bool
    let quiet: Bool
    let showSecrets: Bool

    func print(_ result: RunResult) {
        let t = terminal
        let mask = { (text: String) in showSecrets ? text : (result.request?.masked(text) ?? text) }
        let where_ = t.paint("\(result.reference.path) › \(result.reference.name)", .gray)

        if let request = result.request {
            t.out("\(t.paint("→", .gray)) \(t.method(request.method)) \(mask(request.target))  \(where_)")
        } else {
            t.out("\(t.paint("→", .gray)) \(result.reference.name)  \(where_)")
        }

        if verbose, let request = result.request {
            for header in request.headers {
                t.out("  " + t.paint("\(header.name): \(mask(header.value))", .gray))
            }
            if let body = request.bodyText, !body.isEmpty {
                t.out(t.paint(indent(mask(body), by: "  "), .gray))
            }
        }

        if let response = result.response {
            t.out("  \(t.status(response.statusCode, response.reason))  \(t.paint(formatDuration(response.duration), .dim))  \(t.paint(formatBytes(response.body.count), .dim))")
            if verbose {
                for header in response.headers {
                    t.out("  " + t.paint("\(header.name): \(header.value)", .gray))
                }
                if !response.body.isEmpty {
                    t.out(indent(prettyBody(response), by: "  "))
                }
            }
        }

        if let error = result.error {
            t.out("  " + t.paint("✗ \(mask(error))", .red))
        }
        for assertion in result.assertions {
            if assertion.passed {
                if !quiet { t.out("  " + t.paint("✓", .green) + " " + assertion.source.dropFirst("assert ".count)) }
            } else {
                let detail = assertion.message.map { t.paint(": " + mask($0), .dim) } ?? ""
                t.out("  " + t.paint("✗ " + assertion.source.dropFirst("assert ".count), .red) + detail)
            }
        }
        for log in result.logs {
            t.out("  " + t.paint("│", .gray) + " " + mask(log))
        }
        t.out()
    }

    func summary(_ results: [RunResult]) {
        let t = terminal
        let failed = results.filter { !$0.passed }.count
        let assertions = results.flatMap(\.assertions)
        let failedAssertions = assertions.filter { !$0.passed }.count

        var parts = ["\(results.count) request\(results.count == 1 ? "" : "s")"]
        if !assertions.isEmpty {
            parts.append("\(assertions.count) assertion\(assertions.count == 1 ? "" : "s")")
        }
        let line = parts.joined(separator: ", ")
        if failed == 0 {
            t.out(t.paint("✓ ", .green, .bold) + line)
        } else {
            let failures = "\(failed) failed" + (failedAssertions > 0 ? " (\(failedAssertions) assertion\(failedAssertions == 1 ? "" : "s"))" : "")
            t.out(t.paint("✗ ", .red, .bold) + line + ", " + t.paint(failures, .red))
        }
    }

    private func prettyBody(_ response: HTTPResponse) -> String {
        if response.isJSON, let value = try? Value(json: response.body) {
            return value.jsonString(pretty: true)
        }
        let text = response.bodyText
        return text.count > 4000 ? String(text.prefix(4000)) + "\n…" : text
    }
}

func printDiagnostics(_ file: WorkspaceFile, terminal t: Terminal) {
    for diagnostic in file.document.diagnostics {
        let label = diagnostic.severity == .error ? t.paint("error", .red, .bold) : t.paint("warning", .yellow, .bold)
        let location = "\(file.relativePath):\(diagnostic.range.start.line):\(diagnostic.range.start.column + 1)"
        FileHandle.standardError.write(Data("\(t.paint(location, .bold)): \(label): \(diagnostic.message)\n".utf8))
        let line = file.document.source.line(diagnostic.range.start.line)
        if !line.isEmpty {
            let underline = String(repeating: " ", count: diagnostic.range.start.column)
                + String(repeating: "^", count: max(diagnostic.range.end.column - diagnostic.range.start.column, 1))
            FileHandle.standardError.write(Data("  \(line)\n  \(t.paint(underline, .red))\n".utf8))
        }
    }
}
