import Foundation

@main
struct Stampdrill {
    /// Raised for every release of the command-line tool.
    static let version = "1.4.0"

    /// The name this was invoked by, so `stamp help` does not talk about `stampdrill`.
    static var name: String {
        let called = URL(fileURLWithPath: CommandLine.arguments.first ?? "stampdrill").lastPathComponent
        return ["stampdrill", "stamp"].contains(called) ? called : "stampdrill"
    }

    static var usage: String {
        """
    Send HTTP requests written in .stamp files.

    USAGE
      \(name) run [path] [request...] [dimension=value...] [options]
      \(name) test [path] [plan...] [--tags smoke] [--junit report.xml] [--html report.html]
      \(name) load [path] [test...] [--html report.html] [--json report.json]
      \(name) list [path]
      \(name) check [path]
      \(name) env [path] [dimension=value...]
      \(name) import file... [-o folder]
      \(name) mcp [path]
      \(name) --version

    COMMANDS
      run       Send the requests in a file, or in every file of a folder
      test      Run test plans across their matrix and data, and write reports
      load      Run load tests and check their thresholds
      list      Show the requests a file or folder contains
      check     Report problems in files without sending anything
      env       Show dimensions and the variables they resolve to
      import    Create request files from Postman, Insomnia, Bruno, HAR, curl or OpenAPI
      mcp       Serve the workspace to an AI agent over the Model Context Protocol, on stdio

    OPTIONS
      -d, --dimension name=value   Choose a dimension value (same as name=value)
      -v, --var name=value         Set a variable, overriding the files
      -o, --output path            Save the last response body to a file (or into a folder)
      --verbose                    Show headers and bodies
      -q, --quiet                  Only show failures
      --show-secrets               Don't mask values passed through secret()
      --no-save                    Don't write 'save' results to environment.local.stamp
      --tags a,b                   Only run plans with one of these tags
      --junit / --html / --json F  Write a test report to F
      --html-assets prefix         Where the HTML report loads its elements from
      --no-color                   Plain output
    """
    }

    static func main() async {
        let environment = ProcessInfo.processInfo.environment
        let rawArguments = Array(CommandLine.arguments.dropFirst())
        let terminal = Terminal(colors: isatty(STDERR_FILENO) == 1 && environment["NO_COLOR"] == nil)

        do {
            let arguments = try Arguments(rawArguments.isEmpty ? ["help"] : rawArguments, environment: environment)
            let terminal = Terminal(colors: arguments.colors)
            if ["run", "test", "load", "check"].contains(arguments.command),
               Banner.showsBeforeRuns(quiet: arguments.quiet, environment: environment)
            {
                print(Banner.render(version: version, colors: arguments.colors))
            }
            switch arguments.command {
            case "run":
                exit(try await RunCommand(arguments: arguments, terminal: terminal).execute())
            case "test":
                exit(try await TestCommand(arguments: arguments, terminal: terminal).execute())
            case "load":
                exit(try await LoadCommand(arguments: arguments, terminal: terminal).execute())
            case "list":
                exit(try ListCommand(arguments: arguments, terminal: terminal).execute())
            case "check":
                exit(try CheckCommand(arguments: arguments, terminal: terminal).execute())
            case "env":
                exit(try EnvCommand(arguments: arguments, terminal: terminal).execute())
            case "mcp":
                exit(try await MCPServerCommand(arguments: arguments, terminal: terminal).execute())
            case "import":
                exit(try ImportCommand(arguments: arguments, terminal: terminal).execute())
            case "banner":
                print(Banner.render(version: version, colors: arguments.colors))
            case "version", "--version":
                print(isatty(STDOUT_FILENO) == 1 ? Banner.render(version: version, colors: arguments.colors) : "\(name) \(version)")
            case "help", "-h", "--help":
                if isatty(STDOUT_FILENO) == 1 { print(Banner.render(version: version, colors: arguments.colors)) }
                print(usage)
            default:
                throw UsageError(description: "unknown command '\(arguments.command)'")
            }
        } catch let error as UsageError {
            terminal.error(error.description)
            FileHandle.standardError.write(Data("run '\(name) help' for usage\n".utf8))
            exit(2)
        } catch {
            terminal.error(error.localizedDescription)
            exit(1)
        }
    }
}
