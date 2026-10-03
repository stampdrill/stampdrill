import Foundation

struct UsageError: Error, CustomStringConvertible {
    var description: String
}

struct Arguments {
    var command: String
    var paths: [String] = []
    var names: [String] = []
    /// `name=value` pairs; checked against the workspace's dimensions later.
    var dimensions: [(String, String)] = []
    var variables: [(String, String)] = []
    var verbose = false
    var quiet = false
    var showSecrets = false
    var savesVariables = true
    var tags: Set<String> = []
    var junitPath: String?
    var htmlPath: String?
    var jsonPath: String?
    var outputPath: String?
    var colors: Bool

    init(_ arguments: [String], environment: [String: String]) throws(UsageError) {
        colors = isatty(STDOUT_FILENO) == 1 && environment["NO_COLOR"] == nil

        var remaining = arguments[...]
        guard let command = remaining.popFirst() else { throw UsageError(description: "missing command") }
        self.command = command

        while let argument = remaining.popFirst() {
            switch argument {
            case "-d", "--dimension":
                dimensions.append(try pair(remaining.popFirst(), for: argument))
            case "-v", "--var":
                variables.append(try pair(remaining.popFirst(), for: argument))
            case "--verbose":
                verbose = true
            case "-q", "--quiet":
                quiet = true
            case "--show-secrets":
                showSecrets = true
            case "--no-save":
                savesVariables = false
            case "--tags":
                tags.formUnion((remaining.popFirst() ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            case "--junit":
                junitPath = try value(remaining.popFirst(), for: argument)
            case "--html":
                htmlPath = try value(remaining.popFirst(), for: argument)
            case "-o", "--output":
                outputPath = try value(remaining.popFirst(), for: argument)
            case "--json":
                jsonPath = try value(remaining.popFirst(), for: argument)
            case "-":
                paths.append("-")
            case "--no-color":
                colors = false
            case "--version":
                self.command = "version"
            case "-h", "--help":
                self.command = "help"
            default:
                if argument.hasPrefix("-") {
                    throw UsageError(description: "unknown option '\(argument)'")
                } else if argument.contains("=") {
                    dimensions.append(try pair(argument, for: "dimension"))
                } else if paths.isEmpty || FileManager.default.fileExists(atPath: argument) {
                    paths.append(argument)
                } else {
                    names.append(argument)
                }
            }
        }
    }

    private func value(_ text: String?, for option: String) throws(UsageError) -> String {
        guard let text, !text.hasPrefix("-") else { throw UsageError(description: "\(option) expects a file path") }
        return text
    }

    private func pair(_ text: String?, for option: String) throws(UsageError) -> (String, String) {
        guard let text, let equals = text.firstIndex(of: "="), equals != text.startIndex else {
            throw UsageError(description: "\(option) expects name=value")
        }
        return (String(text[..<equals]), String(text[text.index(after: equals)...]))
    }
}
