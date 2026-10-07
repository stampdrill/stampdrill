import Foundation

struct Terminal: Sendable {
    enum Style: String {
        case bold = "1"
        case dim = "2"
        case red = "31"
        case green = "32"
        case yellow = "33"
        case blue = "34"
        case magenta = "35"
        case cyan = "36"
        case gray = "90"
    }

    var colors: Bool

    func paint(_ text: String, _ styles: Style...) -> String {
        guard colors, !styles.isEmpty else { return text }
        return "\u{1B}[\(styles.map(\.rawValue).joined(separator: ";"))m\(text)\u{1B}[0m"
    }

    func out(_ text: String = "") {
        print(text)
    }

    func error(_ text: String) {
        FileHandle.standardError.write(Data((paint("error:", .red, .bold) + " " + text + "\n").utf8))
    }

    func method(_ method: String) -> String {
        switch method {
        case "GET": paint(method, .green, .bold)
        case "POST": paint(method, .blue, .bold)
        case "PUT", "PATCH": paint(method, .cyan, .bold)
        case "DELETE": paint(method, .red, .bold)
        default: paint(method, .magenta, .bold)
        }
    }

    func status(_ code: Int, _ reason: String) -> String {
        let text = "\(code) \(reason)"
        switch code {
        case 200..<300: return paint(text, .green, .bold)
        case 300..<400: return paint(text, .yellow, .bold)
        default: return paint(text, .red, .bold)
        }
    }
}

func formatBytes(_ count: Int) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowsNonnumericFormatting = false
    return formatter.string(fromByteCount: Int64(count))
}

func formatDuration(_ seconds: TimeInterval) -> String {
    seconds < 1 ? "\(Int((seconds * 1000).rounded())) ms" : String(format: "%.2f s", seconds)
}

func indent(_ text: String, by prefix: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false).map { prefix + $0 }.joined(separator: "\n")
}
