import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// The logo and name, drawn in block characters with a shadow.
///
/// It appears for `stampdrill`, `help` and `--version`, and before runs in an
/// interactive terminal. Piped output, CI logs, `--quiet` and
/// `STAMPDRILL_NO_BANNER=1` never get it.
enum Banner {
    private static let tagline = "Requests, tests, load and MCP as plain text files"

    private static let letters: [Character: [String]] = [
        "P": ["██████╗ ", "██╔══██╗", "██████╔╝", "██╔═══╝ ", "██║     ", "╚═╝     "],
        "O": [" ██████╗ ", "██╔═══██╗", "██║   ██║", "██║   ██║", "╚██████╔╝", " ╚═════╝ "],
        "S": ["███████╗", "██╔════╝", "███████╗", "╚════██║", "███████║", "╚══════╝"],
        "T": ["████████╗", "╚══██╔══╝", "   ██║   ", "   ██║   ", "   ██║   ", "   ╚═╝   "],
        "E": ["███████╗", "██╔════╝", "█████╗  ", "██╔══╝  ", "███████╗", "╚══════╝"],
        "C": [" ██████╗", "██╔════╝", "██║     ", "██║     ", "╚██████╗", " ╚═════╝"],
        "I": ["██╗", "██║", "██║", "██║", "██║", "╚═╝"],
        "A": [" █████╗ ", "██╔══██╗", "███████║", "██╔══██║", "██║  ██║", "╚═╝  ╚═╝"],
        "M": ["███╗   ███╗", "████╗ ████║", "██╔████╔██║", "██║╚██╔╝██║", "██║ ╚═╝ ██║", "╚═╝     ╚═╝"],
        "D": ["██████╗ ", "██╔══██╗", "██║  ██║", "██║  ██║", "██████╔╝", "╚═════╝ "],
        "R": ["██████╗ ", "██╔══██╗", "██████╔╝", "██╔══██╗", "██║  ██║", "╚═╝  ╚═╝"],
        "L": ["██╗     ", "██║     ", "██║     ", "██║     ", "███████╗", "╚══════╝"],
    ]

    /// An envelope with a `{ }` stamp, like the app icon. Six rows, 16 columns.
    private static let envelope = [
        "▗▄▄▄▄▄▄▄▄▄▄▄▄▄▄▖",
        "▐▚▖        ┏━━┓▌",
        "▐ ▝▚▖     ▗┃{}┃▌",
        "▐   ▝▚▄▄▄▞▘┗━━┛▌",
        "▐              ▌",
        "▝▀▀▀▀▀▀▀▀▀▀▀▀▀▀▘",
    ]

    static func render(version: String, colors: Bool) -> String {
        var rows = Array(repeating: "", count: 6)
        for letter in Array("STAMPDRILL") {
            for row in 0..<6 { rows[row] += letters[letter]![row] }
        }
        let width = rows[0].count
        let terminal = terminalWidth()
        // Ten block letters are wide; a narrow terminal gets one plain line.
        guard terminal >= width + 4 else {
            return "\n  " + dim("stampdrill v\(version), \(tagline)", colors) + "\n"
        }

        let showsLogo = terminal >= width + envelope[0].count + 6
        let indent = "  "
        let gap = "   "
        let blank = String(repeating: " ", count: envelope[0].count)

        let ramp = [214, 208, 208, 202, 202, 166]
        var lines: [String] = []
        for row in 0..<6 {
            let logo = showsLogo ? paintEnvelope(envelope[row], colors) + gap : ""
            lines.append(indent + logo + shade(rows[row], face: ramp[row], colors: colors))
        }

        let versionText = "v\(version)"
        let padding = String(repeating: " ", count: max(width - tagline.count - versionText.count, 2))
        lines.append(indent + (showsLogo ? blank + gap : "") + dim(tagline, colors) + padding + dim(versionText, colors))
        return "\n" + lines.joined(separator: "\n") + "\n"
    }

    /// Whether runs should start with the banner.
    static func showsBeforeRuns(quiet: Bool, environment: [String: String]) -> Bool {
        !quiet && isatty(STDOUT_FILENO) == 1 && environment["STAMPDRILL_NO_BANNER"] == nil && environment["CI"] == nil
    }

    // MARK: Drawing

    /// Block faces in the ramp colour, box-drawing strokes darker: the shadow that gives depth.
    private static func shade(_ text: String, face: Int, colors: Bool) -> String {
        guard colors else { return text }
        var result = ""
        var current: Int?
        for character in text {
            let color: Int? = character == "█" ? face : character == " " ? nil : 94
            if color != current, let color {
                result += "\u{1B}[38;5;\(color)m"
                current = color
            }
            result.append(character)
        }
        return result + "\u{1B}[0m"
    }

    private static func paintEnvelope(_ text: String, _ colors: Bool) -> String {
        guard colors else { return text }
        var result = ""
        for character in text {
            switch character {
            case "{", "}": result += "\u{1B}[1;38;5;231m\(character)"
            case "┏", "━", "┓", "┃", "┗", "┛": result += "\u{1B}[22;38;5;33m\(character)"
            default: result += "\u{1B}[22;38;5;209m\(character)"
            }
        }
        return result + "\u{1B}[0m"
    }

    private static func paint(_ text: String, _ color: Int, _ colors: Bool) -> String {
        colors ? "\u{1B}[38;5;\(color)m\(text)\u{1B}[0m" : text
    }

    private static func dim(_ text: String, _ colors: Bool) -> String {
        colors ? "\u{1B}[38;5;245m\(text)\u{1B}[0m" : text
    }

    private static func terminalWidth() -> Int {
        var size = winsize()
        if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &size) == 0, size.ws_col > 0 { return Int(size.ws_col) }
        if let columns = ProcessInfo.processInfo.environment["COLUMNS"].flatMap(Int.init) { return columns }
        return 100
    }
}
