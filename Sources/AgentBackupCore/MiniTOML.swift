import Foundation

/// Just enough TOML for Codex's `[mcp_servers.*]` tables: strings, string arrays (also
/// multi-line), inline tables of strings, and sub-tables. Other values are skipped.
enum MiniTOML {
    enum Value: Equatable {
        case string(String)
        case array([String])
        case table([String: String])
        case other
    }

    struct Entry {
        /// Dotted table path, e.g. ["mcp_servers", "github", "env"].
        var table: [String]
        var key: String
        var value: Value
    }

    // MARK: Reading

    static func entries(_ text: String) -> [Entry] {
        var out: [Entry] = []
        var table: [String] = []
        var scanner = Scanner(Array(text))
        while !scanner.atEnd {
            scanner.skipWhitespaceAndComments()
            guard let c = scanner.peek else { break }
            if c == "[" {
                scanner.advance()
                let isArrayTable = scanner.peek == "["
                if isArrayTable { scanner.advance() }
                table = scanner.readKeyPath(until: "]")
                scanner.skipLine()
                if isArrayTable { table = ["__array__"] + table }
            } else {
                let keyPath = scanner.readKeyPath(until: "=")
                guard scanner.peek == "=" else { scanner.skipLine(); continue }
                scanner.advance()
                scanner.skipSpaces()
                let value = scanner.readValue()
                scanner.skipLine()
                guard let key = keyPath.last else { continue }
                out.append(Entry(table: table + keyPath.dropLast(), key: key, value: value))
            }
        }
        return out
    }

    // MARK: Writing

    static func quoteKey(_ key: String) -> String {
        key.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil ? key : string(key)
    }

    static func string(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F: out += String(format: "\\u%04X", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    static func array(_ values: [String]) -> String {
        "[" + values.map(string).joined(separator: ", ") + "]"
    }

    static func inlineTable(_ values: [String: String]) -> String {
        "{ " + values.keys.sorted().map { "\(quoteKey($0)) = \(string(values[$0]!))" }.joined(separator: ", ") + " }"
    }

    /// Removes the `[prefix.name]` table and its sub-tables (`[prefix.name.*]`) for each name.
    static func removingTables(_ text: String, prefix: String, names: Set<String>) -> String {
        var out: [Substring] = []
        var skipping = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && !trimmed.hasPrefix("[[") {
                var scanner = Scanner(Array(trimmed.dropFirst()))
                let path = scanner.readKeyPath(until: "]")
                skipping = path.count >= 2 && path[0] == prefix && names.contains(path[1])
            } else if trimmed.hasPrefix("[[") {
                skipping = false
            }
            if !skipping { out.append(line) }
        }
        return out.joined(separator: "\n")
    }

    // MARK: Scanner

    struct Scanner {
        let chars: [Character]
        var index = 0

        init(_ chars: [Character]) { self.chars = chars }

        var atEnd: Bool { index >= chars.count }
        var peek: Character? { atEnd ? nil : chars[index] }
        mutating func advance() { index += 1 }

        mutating func skipSpaces() {
            while let c = peek, c == " " || c == "\t" { advance() }
        }

        mutating func skipLine() {
            while let c = peek, c != "\n" { advance() }
            advance()
        }

        mutating func skipWhitespaceAndComments() {
            while let c = peek {
                if c.isWhitespace { advance() }
                else if c == "#" { skipLine() }
                else { return }
            }
        }

        /// `a.b."c d"` up to (not including) `terminator`.
        mutating func readKeyPath(until terminator: Character) -> [String] {
            var parts: [String] = []
            var current = ""
            while let c = peek, c != terminator, c != "\n" {
                if c == "\"" || c == "'" {
                    current += readString()
                    continue
                }
                if c == "." {
                    parts.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                } else {
                    current.append(c)
                }
                advance()
            }
            if peek == terminator && terminator == "]" { advance() }
            let last = current.trimmingCharacters(in: .whitespaces)
            if !last.isEmpty || !parts.isEmpty { parts.append(last) }
            return parts
        }

        mutating func readString() -> String {
            guard let quote = peek else { return "" }
            advance()
            var out = ""
            while let c = peek, c != quote {
                if quote == "\"" && c == "\\" {
                    advance()
                    guard let escaped = peek else { break }
                    switch escaped {
                    case "n": out += "\n"
                    case "t": out += "\t"
                    case "r": out += "\r"
                    case "\"": out += "\""
                    case "\\": out += "\\"
                    case "u", "U":
                        let length = escaped == "u" ? 4 : 8
                        let hex = String(chars[(index + 1)..<min(chars.count, index + 1 + length)])
                        if let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) { out.unicodeScalars.append(scalar) }
                        index += length
                    default: out.append(escaped)
                    }
                } else {
                    out.append(c)
                }
                advance()
            }
            advance()
            return out
        }

        mutating func readValue() -> Value {
            switch peek {
            case "\"", "'":
                return .string(readString())
            case "[":
                advance()
                var items: [String] = []
                var other = false
                while let c = peek, c != "]" {
                    if c == "\"" || c == "'" { items.append(readString()) }
                    else if c == "#" { skipLine() }
                    else if c.isWhitespace || c == "," { advance() }
                    else { other = true; advance() }
                }
                advance()
                return other ? .other : .array(items)
            case "{":
                advance()
                var table: [String: String] = [:]
                while let c = peek, c != "}" {
                    if c.isWhitespace || c == "," { advance(); continue }
                    let key = readKeyPath(until: "=").joined(separator: ".")
                    guard peek == "=" else { break }
                    advance()
                    skipSpaces()
                    if case .string(let value) = readValue() { table[key] = value }
                }
                advance()
                return .table(table)
            default:
                while let c = peek, c != "\n", c != "#" { advance() }
                return .other
            }
        }
    }
}
