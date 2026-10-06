import Foundation

/// Rewrites absolute paths from the source machine to the target machine.
///
/// Sessions embed absolute paths everywhere (`cwd`, tool inputs, project keys),
/// so restoring onto a Mac with a different user name or project layout needs
/// every occurrence rewritten. Rules are applied longest-prefix first, in a
/// single pass, so one rule's output is never re-mapped by another.
public struct PathMapper {
    public struct Rule: Equatable {
        public let from: String
        public let to: String
        public init(from: String, to: String) {
            self.from = from
            self.to = to
        }
    }

    public let rules: [Rule]
    private let regex: NSRegularExpression?

    public init(rules: [Rule]) {
        var seen = Set<String>()
        let cleaned = rules
            .map { Rule(from: Self.trimTrailingSlash($0.from), to: Self.trimTrailingSlash($0.to)) }
            .filter { !$0.from.isEmpty && seen.insert($0.from).inserted }
            .sorted { $0.from.count > $1.from.count }
        self.rules = cleaned

        let active = cleaned.filter { $0.from != $0.to }
        if active.isEmpty {
            regex = nil
        } else {
            // A path segment boundary on both sides, so `/Users/al` never matches inside `/Users/alice`.
            // A JSON escape (`\n/Users/…` in tool output) also counts as a boundary on the left.
            let boundary = "A-Za-z0-9_.\\-"
            let alternation = active.map { NSRegularExpression.escapedPattern(for: $0.from) }.joined(separator: "|")
            regex = try? NSRegularExpression(
                pattern: "(?:(?<![\(boundary)])|(?<=\\\\[nrt]))(?:\(alternation))(?![\(boundary)])")
        }
    }

    public static let identity = PathMapper(rules: [])

    /// Maps a single absolute path by prefix.
    public func map(path: String) -> String {
        for rule in rules {
            if path == rule.from { return rule.to }
            if path.hasPrefix(rule.from + "/") { return rule.to + path.dropFirst(rule.from.count) }
        }
        return path
    }

    /// Rewrites every path occurrence inside free text (JSONL, JSON, Markdown).
    public func rewrite(_ text: String) -> String {
        guard let regex else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        var out = ""
        var cursor = 0
        for match in matches {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let matched = ns.substring(with: match.range)
            out += rules.first { $0.from == matched }?.to ?? matched
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    /// Rewrites UTF-8 data; non-text data is returned unchanged.
    public func rewrite(_ data: Data) -> Data {
        guard regex != nil, let text = String(data: data, encoding: .utf8) else { return data }
        return Data(rewrite(text).utf8)
    }

    /// Maps an encoded Claude project directory name when the original path is unknown.
    public func mapClaudeProjectDirName(_ dirName: String) -> String {
        for rule in rules {
            let from = Self.claudeProjectDirName(for: rule.from)
            if dirName == from || dirName.hasPrefix(from + "-") {
                return Self.claudeProjectDirName(for: rule.to) + dirName.dropFirst(from.count)
            }
        }
        return dirName
    }

    /// Claude Code names `~/.claude/projects/<dir>` by replacing every
    /// non-alphanumeric UTF-16 unit of the project path with `-`.
    public static func claudeProjectDirName(for path: String) -> String {
        String(path.utf16.map { unit -> Character in
            switch unit {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return Character(Unicode.Scalar(unit)!)
            default: return "-"
            }
        })
    }

    private static func trimTrailingSlash(_ path: String) -> String {
        var path = path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
