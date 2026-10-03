import Foundation
import Stamp

/// curl commands, as browsers' "Copy as cURL" and API docs write them.
enum CurlImporter {
    static func collection(_ text: String, translator: inout ImportTranslator) throws -> ImportedCollection {
        let commands = commands(in: text)
        guard !commands.isEmpty else { throw Importer.Failure(message: "No curl command found") }
        var collection = ImportedCollection(name: "curl", format: Importer.Format.curl.rawValue)
        for words in commands {
            var request = try request(words, translator: &translator, warnings: &collection.warnings)
            if collection.root.requests.contains(where: { $0.title == request.title }) {
                request.title += " (\(collection.root.requests.count + 1))"
            }
            collection.root.requests.append(request)
        }
        if commands.count == 1, let host = URL(string: collection.root.requests[0].url)?.host {
            collection.name = host
        }
        return collection
    }

    /// Each command's words. Lines continued with `\`, `^` (cmd) or a backtick
    /// (PowerShell) are joined, and a line break inside quotes stays in the value.
    static func commands(in text: String) -> [[String]] {
        var text = text.replacingOccurrences(of: "\r\n", with: "\n")
        // Chrome's "Copy as cURL (cmd)" escapes with carets: ^" is a quote, ^^ a caret.
        if text.contains("^\"") { text = uncaret(text) }

        var logical: [String] = []
        var current = ""
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let last = trimmed.last, "\\^`".contains(last), !isQuoteOpen(current + String(trimmed.dropLast())) {
                line = String(trimmed.dropLast())
                current += line + " "
                continue
            }
            current += line
            // A quote that is still open means the value itself runs over the line break.
            if isQuoteOpen(current) {
                current += "\n"
                continue
            }
            logical.append(current)
            current = ""
        }
        if !current.isEmpty { logical.append(current) }

        var commands: [[String]] = []
        for line in logical {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("$ ") { trimmed = String(trimmed.dropFirst(2)) }
            guard trimmed.contains("curl") else { continue }
            // `curl a; curl b` and `curl a && curl b` are separate commands.
            var segment: [String] = []
            for word in words(in: trimmed) + [separator] {
                guard word == separator else {
                    segment.append(word)
                    continue
                }
                if let first = segment.first, first == "curl" || first == "curl.exe", segment.count > 1 {
                    commands.append(Array(segment.dropFirst()))
                }
                segment = []
            }
        }
        return commands
    }

    /// Stands for `;`, `&&`, `||` and `|` between words.
    private static let separator = "\u{0};"

    /// Whether a quote is still open at the end of the text, so the command continues.
    private static func isQuoteOpen(_ text: String) -> Bool {
        var quote: Character?
        var characters = Array(text)[...]
        while let character = characters.popFirst() {
            if let open = quote {
                if character == "\\", open == "\"" { _ = characters.popFirst() } else if character == open { quote = nil }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character == "$", characters.first == "'" {
                characters.removeFirst()
                quote = "'"
            } else if character == "\\" {
                _ = characters.popFirst()
            }
        }
        return quote != nil
    }

    /// Chrome's cmd quoting: `^"` is a quote, `^^` a caret, `^x` a literal x.
    private static func uncaret(_ text: String) -> String {
        var result = ""
        var characters = Array(text)[...]
        while let character = characters.popFirst() {
            guard character == "^", let next = characters.popFirst() else {
                result.append(character)
                continue
            }
            // A caret before a line break is a continuation; keep it for the line pass.
            if next == "\n" {
                result.append("^")
                result.append(next)
            } else {
                result.append(next)
            }
        }
        return result
    }

    /// Shell words: quotes, `$'…'` with escapes, and backslashes.
    static func words(in text: String) -> [String] {
        var words: [String] = []
        var word = ""
        var inWord = false
        var characters = Array(text)[...]
        while let character = characters.popFirst() {
            // `;`, `|`, `||`, `&&` and a lone `&` all end a command: a backgrounded
            // curl is still a curl, and dropping it would lose a request.
            if character == ";" || character == "|" || character == "&" {
                if inWord { words.append(word) }
                word = ""
                inWord = false
                if character != ";", characters.first == character { characters.removeFirst() }
                words.append(separator)
                continue
            }
            switch character {
            case " ", "\t":
                if inWord { words.append(word) }
                word = ""
                inWord = false
            case "'":
                inWord = true
                while let next = characters.popFirst(), next != "'" { word.append(next) }
            case "$" where characters.first == "'":
                inWord = true
                characters.removeFirst()
                while let next = characters.popFirst(), next != "'" {
                    guard next == "\\", let escaped = characters.popFirst() else { word.append(next); continue }
                    func hexadecimal(_ limit: Int) -> Character? {
                        var digits = ""
                        while digits.count < limit, let digit = characters.first, digit.isHexDigit {
                            digits.append(digit)
                            characters.removeFirst()
                        }
                        return UInt32(digits, radix: 16).flatMap(Unicode.Scalar.init).map(Character.init)
                    }
                    switch escaped {
                    case "n": word.append("\n")
                    case "t": word.append("\t")
                    case "r": word.append("\r")
                    case "a": word.append("\u{7}")
                    case "b": word.append("\u{8}")
                    case "e", "E": word.append("\u{1B}")
                    case "f": word.append("\u{C}")
                    case "v": word.append("\u{B}")
                    // Firefox and Safari write non-ASCII characters and tabs as \xHH.
                    case "x": if let character = hexadecimal(2) { word.append(character) }
                    case "u": if let character = hexadecimal(4) { word.append(character) }
                    case "U": if let character = hexadecimal(8) { word.append(character) }
                    case "0", "1", "2", "3", "4", "5", "6", "7":
                        var digits = String(escaped)
                        while digits.count < 3, let digit = characters.first, digit.isNumber, digit < "8" {
                            digits.append(digit)
                            characters.removeFirst()
                        }
                        if let scalar = UInt32(digits, radix: 8).flatMap(Unicode.Scalar.init) { word.append(Character(scalar)) }
                    default: word.append(escaped)
                    }
                }
            case "\"":
                inWord = true
                while let next = characters.popFirst(), next != "\"" {
                    if next == "\\", let escaped = characters.first, "\"\\$`".contains(escaped) {
                        word.append(escaped)
                        characters.removeFirst()
                    } else {
                        word.append(next)
                    }
                }
            case "\\":
                inWord = true
                if let escaped = characters.popFirst() { word.append(escaped) }
            default:
                inWord = true
                word.append(character)
            }
        }
        if inWord { words.append(word) }
        return words
    }

    private static func request(_ words: [String], translator: inout ImportTranslator, warnings: inout [String]) throws -> ImportedRequest {
        var method: String?
        var url: String?
        var headers: [ImportedField] = []
        var defaultHeaders: [ImportedField] = []
        var data: [String] = []
        var encodedData: [ImportedField] = []
        var form: [ImportedField] = []
        var json = false
        var getWithData = false
        var auth: ImportedAuth?
        var notes: [String] = []

        let withValue: Set<String> = [
            "-X", "--request", "-H", "--header", "-d", "--data", "--data-raw", "--data-ascii", "--data-binary", "--data-urlencode",
            "--json", "-F", "--form", "--form-string", "-u", "--user", "-A", "--user-agent", "-e", "--referer", "-b", "--cookie",
            "--url", "-o", "--output", "-w", "--write-out", "-m", "--max-time", "--connect-timeout", "--oauth2-bearer", "-x", "--proxy",
            "--cacert", "--cert", "--key", "-c", "--cookie-jar", "--retry", "-T", "--upload-file", "--resolve", "--limit-rate",
            "-D", "--dump-header", "-r", "--range", "-K", "--config", "-E", "-U", "--proxy-user", "-y", "-Y", "-z", "--time-cond",
            "-C", "--continue-at", "--unix-socket", "--abstract-unix-socket", "--max-redirs", "--url-query", "--aws-sigv4",
            "--retry-delay", "--retry-max-time", "--proto", "--proto-redir", "--interface", "--noproxy", "--capath", "--ciphers",
            "--dns-servers", "--local-port", "--happy-eyeballs-timeout-ms", "--expect100-timeout", "--pinnedpubkey", "--tlsv1.2",
            "--tls-max", "--engine", "--egd-file", "--random-file", "--krb", "--login-options", "--sasl-authzid", "--service-name",
            "--output-dir", "--create-file-mode", "--hostpubmd5", "--hostpubsha256", "--pubkey", "--trace", "--trace-ascii", "--stderr",
        ]

        var queue = words[...]
        while let word = queue.popFirst() {
            var option = word
            var value: String?
            if word.hasPrefix("--"), let equals = word.firstIndex(of: "="), withValue.contains(String(word[..<equals])) {
                option = String(word[..<equals])
                value = String(word[word.index(after: equals)...])
            } else if word.hasPrefix("-"), !word.hasPrefix("--"), word.count > 2 {
                // Combined flags such as -sSL, and the last one may take a value: -sX POST.
                var letters = Array(word.dropFirst())[...]
                var handled = false
                while let flag = letters.popFirst() {
                    let short = "-" + String(flag)
                    if withValue.contains(short) {
                        option = short
                        value = letters.isEmpty ? queue.popFirst() : String(letters)
                        handled = true
                        break
                    }
                    if flag == "k" { notes.append("@insecure") }
                    if flag == "I" { method = "HEAD" }
                    if flag == "G" { getWithData = true }
                }
                if !handled { continue }
            }
            if withValue.contains(option), value == nil { value = queue.popFirst() }
            let argument = value ?? ""

            switch option {
            case "-X", "--request": method = argument.uppercased()
            case "--url": url = argument
            case "-H", "--header":
                if let colon = argument.firstIndex(of: ":") {
                    headers.append(ImportedField(name: String(argument[..<colon]).trimmingCharacters(in: .whitespaces),
                                                 value: String(argument[argument.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
                } else if argument.hasSuffix(";") {
                    headers.append(ImportedField(name: String(argument.dropLast()), value: ""))
                }
            // curl's own headers: an explicit -H of the same name replaces them.
            case "-A", "--user-agent": defaultHeaders.append(ImportedField(name: "User-Agent", value: argument))
            case "-e", "--referer": defaultHeaders.append(ImportedField(name: "Referer", value: argument))
            case "-b", "--cookie":
                if argument.contains("=") { defaultHeaders.append(ImportedField(name: "Cookie", value: argument)) }
            case "-d", "--data", "--data-ascii", "--data-binary":
                if argument.hasPrefix("@") {
                    data.append("< " + argument.dropFirst())
                } else {
                    data.append(argument)
                }
            case "--data-raw": data.append(argument)
            case "--data-urlencode":
                if let equals = argument.firstIndex(of: "=") {
                    encodedData.append(ImportedField(name: String(argument[..<equals]), value: String(argument[argument.index(after: equals)...])))
                } else {
                    data.append(argument.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? argument)
                }
            case "--json":
                json = true
                if argument.hasPrefix("@") { data.append("< " + argument.dropFirst()) } else { data.append(argument) }
            case "-F", "--form", "--form-string":
                guard let equals = argument.firstIndex(of: "=") else { continue }
                let name = String(argument[..<equals])
                var fieldValue = String(argument[argument.index(after: equals)...])
                let isFile = option != "--form-string" && fieldValue.hasPrefix("@")
                if isFile {
                    fieldValue = String(fieldValue.dropFirst().prefix { $0 != ";" })
                } else if fieldValue.hasPrefix("<") {
                    // curl reads the text from a file; a .stamp form can only do that for uploads.
                    warnings.append("the form field '\(name)' took its text from \(fieldValue.dropFirst()); it is now an upload of that file")
                    fieldValue = String(fieldValue.dropFirst().prefix { $0 != ";" })
                    form.append(ImportedField(name: name, value: fieldValue, isFile: true))
                    continue
                } else if let semicolon = fieldValue.firstIndex(of: ";"), fieldValue[semicolon...].hasPrefix(";type=") {
                    fieldValue = String(fieldValue[..<semicolon])
                }
                form.append(ImportedField(name: name, value: fieldValue, isFile: isFile))
            case "--digest", "--ntlm", "--negotiate", "--anyauth":
                warnings.append("\(option.dropFirst(2)) authentication isn't supported; the request uses Basic instead")
            case "-u", "--user":
                let parts = argument.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                auth = .basic(username: parts[0], password: parts.count > 1 ? parts[1] : "")
            case "--oauth2-bearer": auth = .bearer(argument)
            case "-m", "--max-time":
                if let seconds = Double(argument) { notes.append("@timeout \(seconds == seconds.rounded() ? String(Int(seconds)) : String(seconds))s") }
            case "-k", "--insecure": notes.append("@insecure")
            case "-I", "--head": method = "HEAD"
            case "-G", "--get": getWithData = true
            case "-T", "--upload-file":
                data.append("< " + argument)
                method = method ?? "PUT"
            default:
                if !word.hasPrefix("-"), url == nil { url = word }
            }
        }

        headers = defaultHeaders.filter { header in
            !headers.contains { $0.name.caseInsensitiveCompare(header.name) == .orderedSame }
        } + headers
        guard var target = url else { throw Importer.Failure(message: "A curl command has no URL") }
        if !target.contains("://") { target = "http://" + target }
        // Safari escapes curl's glob characters in the URL; they are ordinary characters here.
        for character in ["[", "]", "{", "}"] { target = target.replacingOccurrences(of: "\\" + character, with: character) }

        var request = ImportedRequest(title: "", method: "GET", url: "")
        let hasBody = !data.isEmpty || !encodedData.isEmpty || !form.isEmpty
        if getWithData, !data.isEmpty || !encodedData.isEmpty {
            let query = data + encodedData.map { "\($0.name)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value)" }
            target += (target.contains("?") ? "&" : "?") + query.joined(separator: "&")
            request.method = method ?? "GET"
        } else {
            request.method = method ?? (hasBody ? "POST" : "GET")
            let contentType = headers.first { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value.lowercased()
            if !form.isEmpty {
                request.body = .multipart(form)
                headers.removeAll { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }
            } else if let type = contentType, type.contains("multipart/form-data"),
                      let boundary = MultipartBody.boundary(in: headers.first { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value ?? ""),
                      let fields = MultipartBody.fields(in: data.joined(separator: "&"), boundary: boundary)
            {
                // Chrome copies a FormData post as the raw body; as fields it can be edited and re-sent.
                request.body = .multipart(fields)
                headers.removeAll { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }
            } else if data.count == 1, data[0].hasPrefix("< ") {
                request.body = .file(String(data[0].dropFirst(2)))
            } else if !data.isEmpty || !encodedData.isEmpty {
                let text = data.joined(separator: "&")
                let looksJSON = text.trimmingCharacters(in: .whitespaces).first.map { $0 == "{" || $0 == "[" } == true
                if json || contentType?.contains("json") == true || (contentType == nil && looksJSON && encodedData.isEmpty) {
                    request.body = .text(text)
                    if json {
                        if contentType == nil { headers.append(ImportedField(name: "Content-Type", value: "application/json")) }
                        if !headers.contains(where: { $0.name.caseInsensitiveCompare("Accept") == .orderedSame }) {
                            headers.append(ImportedField(name: "Accept", value: "application/json"))
                        }
                    }
                } else if contentType == nil || contentType!.contains("x-www-form-urlencoded"), let fields = formFields(text, encoded: encodedData) {
                    request.body = .urlEncoded(fields)
                    headers.removeAll { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }
                } else {
                    request.body = .text(text)
                }
            }
        }

        request.url = translator.escapingBraces(target)
        // Headers the HTTP stack manages itself; setting Accept-Encoding by hand can stop responses from being decompressed.
        headers.removeAll { ["accept-encoding", "connection", "content-length", "host"].contains($0.name.lowercased()) }
        request.headers = headers.map { ImportedField(name: $0.name, value: translator.escapingBraces($0.value)) }
        let escape = { (field: ImportedField) in
            ImportedField(name: translator.escapingBraces(field.name), value: translator.escapingBraces(field.value),
                          isEnabled: field.isEnabled, isFile: field.isFile)
        }
        switch request.body {
        case .text(let text)?: request.body = .text(translator.escapingBraces(text))
        case .urlEncoded(let fields)?: request.body = .urlEncoded(fields.map(escape))
        case .multipart(let fields)?: request.body = .multipart(fields.map(escape))
        default: break
        }
        switch auth {
        case .basic(let username, let password)?:
            auth = .basic(username: translator.escapingBraces(username), password: translator.escapingBraces(password))
        case .bearer(let token)?:
            auth = .bearer(translator.escapingBraces(token))
        default:
            break
        }
        request.auth = auth
        request.title = requestTitle(method: request.method, url: target)
        request.directives = notes
        return request
    }

    /// `a=1&b=two%20words` as form fields, when every part is `name=value`.
    private static func formFields(_ text: String, encoded: [ImportedField]) -> [ImportedField]? {
        var fields: [ImportedField] = []
        for part in text.split(separator: "&") where !part.isEmpty {
            guard let equals = part.firstIndex(of: "=") else { return nil }
            let name = String(part[..<equals]).removingPercentEncoding ?? String(part[..<equals])
            let value = String(part[part.index(after: equals)...]).replacingOccurrences(of: "+", with: " ")
            fields.append(ImportedField(name: name, value: value.removingPercentEncoding ?? value))
        }
        fields += encoded
        return fields.contains(where: { $0.name.contains(" ") || $0.value.contains(where: \.isNewline) }) ? nil : fields
    }
}

extension ImportTranslator {
    /// Text from a source without variables: any `{{` is literal.
    func escapingBraces(_ text: String) -> String {
        text.replacingOccurrences(of: "{{", with: "\\{{")
    }
}
