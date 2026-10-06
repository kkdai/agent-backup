import Foundation
import Testing
@testable import AgentBackupCore

struct RunningAgentsTests {
    typealias P = RunningAgents.Process

    @Test func matchesNativeAndNpmInstalls() {
        let found = RunningAgents.find(in: [
            P(pid: 10, executable: "/Users/a/.local/bin/claude", arguments: ["claude"]),
            P(pid: 11, executable: "/opt/homebrew/bin/node", arguments: ["node", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"]),
            P(pid: 12, executable: "/opt/homebrew/bin/node", arguments: ["node", "/x/node_modules/@openai/codex/bin/codex.js"]),
            P(pid: 13, executable: "/Applications/Claude.app/Contents/MacOS/Claude", arguments: ["Claude"]),
            P(pid: 14, executable: "/usr/bin/vim", arguments: ["vim", "claude-notes.md"]),
            P(pid: 15, executable: "/Users/a/.local/share/claude/versions/2.1.289", arguments: ["claude", "--resume"]),
        ])
        #expect(found["claude-code"] == [10, 11, 15])
        #expect(found["codex"] == [12])
        #expect(found["gemini-cli"] == nil)
    }

    @Test func readsRealProcessTable() {
        let processes = RunningAgents.allProcesses()
        let me = processes.first { $0.pid == getpid() }
        #expect(me != nil)
        #expect(me?.arguments.isEmpty == false)
    }
}
