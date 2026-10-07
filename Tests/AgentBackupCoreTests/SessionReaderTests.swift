import Foundation
import Testing
@testable import AgentBackupCore

struct SessionReaderTests {
    func jsonl(_ lines: [String]) -> Data { Data(lines.joined(separator: "\n").utf8) }

    @Test func readsClaudeCode() throws {
        let data = jsonl([
            #"{"type":"user","message":{"role":"user","content":"<command-name>/model</command-name>"}}"#,
            #"{"type":"user","isMeta":true,"message":{"role":"user","content":"meta"}}"#,
            #"{"type":"user","message":{"role":"user","content":"Fix the login bug"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"Looking."},{"type":"tool_use","name":"Bash","input":{}}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"output"}]}}"#,
            #"{"type":"system","content":"x"}"#,
        ])
        let messages = try #require(SessionReader.transcript(agentID: "claude-code", path: "s.jsonl", data: data))
        #expect(messages == [.init(role: .user, text: "Fix the login bug"), .init(role: .assistant, text: "Looking."), .init(role: .tool, text: "Bash")])
        #expect(SessionReader.title(messages) == "Fix the login bug")
    }

    @Test func readsCodex() throws {
        let data = jsonl([
            #"{"type":"session_meta","payload":{"cwd":"/p"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>cwd</environment_context>"}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Add tests"}]}}"#,
            #"{"type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{}"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done."}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"rules"}]}}"#,
        ])
        #expect(SessionReader.transcript(agentID: "codex", path: "rollout.jsonl", data: data)
            == [.init(role: .user, text: "Add tests"), .init(role: .tool, text: "shell"), .init(role: .assistant, text: "Done.")])
    }

    @Test func readsGeminiBothFormats() {
        let jsonlData = jsonl([
            #"{"sessionId":"s","projectHash":"h"}"#,
            #"{"id":"1","type":"user","content":[{"text":"list files"}]}"#,
            #"{"id":"2","type":"gemini","content":"Here they are","toolCalls":[{"name":"list_directory"}]}"#,
        ])
        let expected: [TranscriptMessage] = [.init(role: .user, text: "list files"), .init(role: .assistant, text: "Here they are"),
                                             .init(role: .tool, text: "list_directory")]
        #expect(SessionReader.transcript(agentID: "gemini-cli", path: "session.jsonl", data: jsonlData) == expected)
        let json = Data(#"{"messages":[{"type":"user","content":"list files"},{"type":"gemini","content":"Here they are","toolCalls":[{"name":"list_directory"}]}]}"#.utf8)
        #expect(SessionReader.transcript(agentID: "gemini-cli", path: "session.json", data: json) == expected)
    }

    @Test func titlesSkipWrapperTagsAndToolRunsFold() {
        let messages: [TranscriptMessage] = [
            .init(role: .user, text: "<pasted_content id=\"1\">\nBuild a Mac app\n</pasted_content>"),
            .init(role: .tool, text: "Bash"), .init(role: .tool, text: "Bash"), .init(role: .tool, text: "Write"),
            .init(role: .assistant, text: "Done"), .init(role: .tool, text: "Read"),
        ]
        #expect(SessionReader.title(messages) == "Build a Mac app")
        #expect(SessionReader.foldingToolRuns(messages).map(\.text) == [messages[0].text, "Bash ×2、Write", "Done", "Read"])
    }

    @Test func unknownFormatsReturnNil() {
        #expect(SessionReader.transcript(agentID: "copilot-cli", path: "events.jsonl", data: Data()) == nil)
    }

    @Test func readsRealClaudeSessionsIfPresent() throws {
        // Smoke test against this Mac's own sessions; content is never printed.
        let projects = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: projects.path) else { return }
        for dir in dirs {
            let folder = projects.appendingPathComponent(dir)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(".jsonl") {
                let data = try Data(contentsOf: folder.appendingPathComponent(name))
                #expect(SessionReader.transcript(agentID: "claude-code", path: name, data: data) != nil)
            }
        }
    }
}
