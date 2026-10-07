import Foundation

public struct TranscriptMessage: Equatable {
    public enum Role: String {
        case user, assistant
        /// A tool call, shown as a one-line marker.
        case tool
    }

    public var role: Role
    public var text: String
}

/// Turns each agent's session file into a readable transcript: user and assistant text, tool calls
/// as short markers. Thinking, tool output and injected context are left out.
public enum SessionReader {
    /// nil when the file isn't a session format this app can read.
    public static func transcript(agentID: String, path: String, data: Data) -> [TranscriptMessage]? {
        switch agentID {
        case "claude-code" where path.hasSuffix(".jsonl"): claude(data)
        case "codex" where path.hasSuffix(".jsonl"): codex(data)
        case "gemini-cli": gemini(data, isJSONL: path.hasSuffix(".jsonl"))
        default: nil
        }
    }

    /// The first line of the first user message that isn't just a wrapper tag (e.g. `<pasted_content …>`).
    public static func title(_ messages: [TranscriptMessage]) -> String? {
        for message in messages where message.role == .user {
            let line = message.text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty && !($0.hasPrefix("<") && $0.hasSuffix(">")) }
            if let line { return String(line.prefix(120)) }
        }
        return nil
    }

    /// Consecutive tool calls folded into one line ("Bash ×6、Write"), for display.
    public static func foldingToolRuns(_ messages: [TranscriptMessage]) -> [TranscriptMessage] {
        var out: [TranscriptMessage] = []
        var run: [String] = []
        func flush() {
            guard !run.isEmpty else { return }
            var counts: [(String, Int)] = []
            for name in run {
                if let i = counts.firstIndex(where: { $0.0 == name }) { counts[i].1 += 1 } else { counts.append((name, 1)) }
            }
            out.append(.init(role: .tool, text: counts.map { $0.1 > 1 ? "\($0.0) ×\($0.1)" : $0.0 }.joined(separator: "、")))
            run = []
        }
        for message in messages {
            if message.role == .tool { run.append(message.text) } else { flush(); out.append(message) }
        }
        flush()
        return out
    }

    static func lines(_ data: Data) -> [[String: Any]] {
        String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    /// Wrappers agents inject into the user turn (slash-command echoes, reminders, environment).
    static func isInjected(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || ["<command-", "<local-command", "<system-reminder", "<environment_context", "<user_instructions",
                                   "Caveat:"].contains { trimmed.hasPrefix($0) }
    }

    static func claude(_ data: Data) -> [TranscriptMessage] {
        var out: [TranscriptMessage] = []
        for line in lines(data) {
            guard let type = line["type"] as? String, type == "user" || type == "assistant",
                  line["isMeta"] as? Bool != true, let message = line["message"] as? [String: Any] else { continue }
            let role: TranscriptMessage.Role = type == "user" ? .user : .assistant
            if let text = message["content"] as? String {
                if !isInjected(text) { out.append(.init(role: role, text: text)) }
                continue
            }
            for part in message["content"] as? [[String: Any]] ?? [] {
                switch part["type"] as? String {
                case "text":
                    if let text = part["text"] as? String, !isInjected(text) { out.append(.init(role: role, text: text)) }
                case "tool_use":
                    out.append(.init(role: .tool, text: part["name"] as? String ?? "tool"))
                default:
                    break   // thinking, tool_result, images
                }
            }
        }
        return out
    }

    static func codex(_ data: Data) -> [TranscriptMessage] {
        var out: [TranscriptMessage] = []
        for line in lines(data) where line["type"] as? String == "response_item" {
            guard let payload = line["payload"] as? [String: Any] else { continue }
            switch payload["type"] as? String {
            case "message":
                let role = payload["role"] as? String
                guard role == "user" || role == "assistant" else { continue }
                let text = (payload["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
                if !isInjected(text) { out.append(.init(role: role == "user" ? .user : .assistant, text: text)) }
            case "function_call", "local_shell_call", "custom_tool_call":
                out.append(.init(role: .tool, text: payload["name"] as? String ?? "shell"))
            default:
                break
            }
        }
        return out
    }

    static func gemini(_ data: Data, isJSONL: Bool) -> [TranscriptMessage] {
        let records: [[String: Any]] = isJSONL
            ? lines(data)
            : ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["messages"] as? [[String: Any]] ?? [])
        var out: [TranscriptMessage] = []
        for record in records {
            guard let type = record["type"] as? String, type == "user" || type == "gemini" else { continue }
            let text: String
            if let string = record["content"] as? String {
                text = string
            } else {
                text = (record["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
            }
            if !isInjected(text) { out.append(.init(role: type == "user" ? .user : .assistant, text: text)) }
            for call in record["toolCalls"] as? [[String: Any]] ?? [] {
                out.append(.init(role: .tool, text: call["name"] as? String ?? "tool"))
            }
        }
        return out
    }
}
