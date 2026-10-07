import Foundation
import StampdrillCore
import Stamp

/// `stampdrill list`: every request, grouped by file.
struct ListCommand {
    let arguments: Arguments
    let terminal: Terminal

    func execute() throws -> Int32 {
        let t = terminal
        let target = try WorkspaceTarget(arguments.paths)
        let width = target.files.flatMap(\.document.requests).map(\.name.count).max() ?? 0

        for file in target.files where !file.document.requests.isEmpty {
            t.out(t.paint(file.relativePath, .bold))
            for request in file.document.requests {
                let method = t.method(request.method.padding(toLength: 7, withPad: " ", startingAt: 0))
                let name = request.name.padding(toLength: width + 2, withPad: " ", startingAt: 0)
                let title = request.title.map { t.paint($0, .gray) } ?? ""
                t.out("  \(method)\(name)\(title)")
            }
        }
        return 0
    }
}

/// `stampdrill check`: parse everything and report problems without sending.
struct CheckCommand {
    let arguments: Arguments
    let terminal: Terminal

    func execute() throws -> Int32 {
        let t = terminal
        let target = try WorkspaceTarget(arguments.paths)
        var files = target.files
        if let environment = target.workspace.environmentFile, !files.contains(where: { $0.id == environment.id }) {
            files.insert(environment, at: 0)
        }

        var errors = 0
        var warnings = 0
        for file in files {
            printDiagnostics(file, terminal: t)
            errors += file.document.diagnostics.filter { $0.severity == .error }.count
            warnings += file.document.diagnostics.filter { $0.severity == .warning }.count
        }
        for problem in target.workspace.environment.problems {
            let location = "\(problem.entry.origin):\(problem.entry.set.lines.lowerBound)"
            FileHandle.standardError.write(Data("\(t.paint(location, .bold)): \(t.paint("warning", .yellow, .bold)): \(problem.message)\n".utf8))
            warnings += 1
        }
        for file in target.files {
            for request in file.document.requests {
                for name in request.dependencies where target.workspace.request(named: name, near: file) == nil {
                    let location = "\(file.relativePath):\(request.lines.lowerBound)"
                    FileHandle.standardError.write(Data("\(t.paint(location, .bold)): \(t.paint("error", .red, .bold)): '@needs \(name)': no request has that name\n".utf8))
                    errors += 1
                }
            }
        }

        let requests = target.files.map(\.document.requests.count).reduce(0, +)
        let summary = "\(files.count) file\(files.count == 1 ? "" : "s"), \(requests) request\(requests == 1 ? "" : "s")"
        if errors == 0 {
            t.out(t.paint("✓ ", .green, .bold) + summary + (warnings > 0 ? t.paint(", \(warnings) warning\(warnings == 1 ? "" : "s")", .yellow) : ""))
        } else {
            t.out(t.paint("✗ ", .red, .bold) + summary + t.paint(", \(errors) error\(errors == 1 ? "" : "s")", .red))
        }
        return errors == 0 ? 0 : 1
    }
}

/// `stampdrill env`: the dimensions and the variables they produce.
struct EnvCommand {
    let arguments: Arguments
    let terminal: Terminal

    func execute() throws -> Int32 {
        let t = terminal
        let target = try WorkspaceTarget(arguments.paths)
        let workspace = target.workspace
        let file = target.files.count == 1 ? target.files[0] : workspace.environmentFile
        let environment = file.map { workspace.environment(for: $0) } ?? workspace.environment

        var selection = environment.defaultSelection
        for (name, value) in arguments.dimensions {
            guard environment.dimension(named: name) != nil else {
                throw UsageError(description: "unknown dimension '\(name)'")
            }
            selection[name] = value == "*" ? nil : value
        }

        if !environment.dimensions.isEmpty {
            t.out(t.paint("Dimensions", .bold))
            let width = environment.dimensions.map(\.name.count).max()! + 2
            for dimension in environment.dimensions {
                let chosen = selection[dimension.name] ?? "*"
                let others = dimension.values.map { $0 == chosen ? t.paint($0, .cyan, .bold) : t.paint($0, .gray) }
                t.out("  \(dimension.name.padding(toLength: width, withPad: " ", startingAt: 0))\(others.joined(separator: t.paint(" | ", .gray)))")
            }
            t.out()
        }

        let overrides = Dictionary(arguments.variables.map { ($0.0, Value.string($0.1)) }) { _, last in last }
        let context: Scope
        if let file {
            context = RequestResolver.scope(
                for: nil, in: file, workspace: workspace,
                input: ResolutionInput(selection: selection, overrides: overrides)
            )
        } else {
            context = Scope(layers: environment.layers(for: selection), builtins: Builtins.standard)
        }

        let names = context.visibleNames.filter { context.source(of: $0) != "dimensions" }
        guard !names.isEmpty else {
            t.out(t.paint("No variables", .gray))
            return 0
        }

        t.out(t.paint("Variables", .bold))
        let width = names.map(\.count).max()! + 2
        var rows: [(String, String, String)] = []
        for name in names {
            let source = context.source(of: name) ?? ""
            do {
                rows.append((name, try context.value(of: name).interpolated, source))
            } catch {
                rows.append((name, t.paint("error: \(error.message)", .red), source))
            }
        }
        let shown = rows.map { name, value, _ in
            arguments.showSecrets || !(context.secrets.contains(value) || isSensitive(name)) ? value : "••••••"
        }
        let valueWidth = min(shown.map(\.count).max() ?? 0, 48) + 2
        for (row, value) in zip(rows, shown) {
            let padded = value.count < valueWidth ? value.padding(toLength: valueWidth, withPad: " ", startingAt: 0) : value + "  "
            t.out("  \(row.0.padding(toLength: width, withPad: " ", startingAt: 0))\(padded)\(t.paint(row.2, .gray))")
        }
        return 0
    }
}

func isSensitive(_ name: String) -> Bool {
    let lowered = name.lowercased()
    return ["secret", "token", "password", "passwd", "auth", "bearer", "apikey", "api_key", "credential"]
        .contains { lowered.contains($0) }
}
