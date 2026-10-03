/// Re-indents JSON text without decoding it.
///
/// Going through a parser would round numbers like `12345678901234567890`
/// and rewrite escapes; this works on the characters, so the output shows
/// exactly what the server sent, only laid out.
public enum JSONFormatter {
    /// Returns nil when `text` isn't a JSON object or array.
    public static func prettyPrinted(_ text: String, indent: String = "  ") -> String? {
        format(text, indent: indent, pretty: true)
    }

    public static func minified(_ text: String) -> String? {
        format(text, indent: "", pretty: false)
    }

    private static func format(_ text: String, indent: String, pretty: Bool) -> String? {
        let scalars = Array(text.unicodeScalars)
        guard let first = scalars.firstIndex(where: { !isWhitespace($0) }), scalars[first] == "{" || scalars[first] == "[" else {
            return nil
        }

        var output = String.UnicodeScalarView()
        output.reserveCapacity(scalars.count + scalars.count / 4)
        var stack: [Unicode.Scalar] = []
        var index = first
        var afterOpen = false

        func newline() {
            guard pretty else { return }
            output.append("\n")
            for _ in 0..<stack.count { output.append(contentsOf: indent.unicodeScalars) }
        }

        while index < scalars.count {
            let scalar = scalars[index]
            switch scalar {
            case "\"":
                if afterOpen { newline(); afterOpen = false }
                output.append(scalar)
                index += 1
                var closed = false
                while index < scalars.count {
                    let inner = scalars[index]
                    output.append(inner)
                    index += 1
                    if inner == "\\", index < scalars.count {
                        output.append(scalars[index])
                        index += 1
                    } else if inner == "\"" {
                        closed = true
                        break
                    }
                }
                guard closed else { return nil }
                continue
            case "{", "[":
                if afterOpen { newline() }
                output.append(scalar)
                stack.append(scalar)
                afterOpen = true
            case "}", "]":
                guard let open = stack.popLast(), (open == "{") == (scalar == "}") else { return nil }
                if !afterOpen { newline() }
                afterOpen = false
                output.append(scalar)
            case ",":
                guard !stack.isEmpty else { return nil }
                output.append(scalar)
                newline()
            case ":":
                output.append(scalar)
                if pretty { output.append(" ") }
            default:
                if isWhitespace(scalar) { break }
                if afterOpen { newline(); afterOpen = false }
                output.append(scalar)
            }
            index += 1
            if stack.isEmpty {
                // Only whitespace may follow the top-level value.
                guard scalars[index...].allSatisfy(isWhitespace) else { return nil }
                break
            }
        }
        return stack.isEmpty ? String(output) : nil
    }

    private static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || scalar == "\n" || scalar == "\r" || scalar == "\t"
    }
}
