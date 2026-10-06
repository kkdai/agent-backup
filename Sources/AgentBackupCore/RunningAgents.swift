import Darwin
import Foundation

/// Finds coding agents that are running right now. Restoring or rolling back while an agent
/// runs is unsafe: Claude Code, for one, rewrites `~/.claude.json` and would undo the restore.
public enum RunningAgents {
    struct Signature {
        /// Executable file names (native installs).
        let executables: Set<String>
        /// Substrings of the command line (npm installs run as `node …/cli.js`).
        let argumentMarkers: [String]
    }

    static let signatures: [String: Signature] = [
        // Markers end in "/" so sibling packages (e.g. @github/copilot-language-server) don't match.
        "claude-code": Signature(executables: ["claude"], argumentMarkers: ["@anthropic-ai/claude-code/"]),
        "codex": Signature(executables: ["codex"], argumentMarkers: ["@openai/codex/"]),
        "gemini-cli": Signature(executables: ["gemini"], argumentMarkers: ["@google/gemini-cli/"]),
        "copilot-cli": Signature(executables: ["copilot"], argumentMarkers: ["@github/copilot/"]),
        // The app's main process; its helpers are "Claude Helper (…)".
        "claude-desktop": Signature(executables: ["Claude"], argumentMarkers: []),
    ]

    public struct Process: Equatable {
        public let pid: pid_t
        public let executable: String
        public let arguments: [String]
    }

    /// agent ID → running processes, for agents with at least one.
    public static func find(in processes: [Process] = allProcesses()) -> [String: [pid_t]] {
        var out: [String: [pid_t]] = [:]
        for process in processes where process.pid != getpid() {
            // The native Claude Code binary lives at …/claude/versions/<version>, so argv[0] matters too.
            let names: Set<String> = [process.executable, process.arguments.first ?? ""].map { ($0 as NSString).lastPathComponent }
                .reduce(into: []) { $0.insert($1) }
            let commandLine = process.arguments.joined(separator: " ")
            for (agent, signature) in signatures
            where !signature.executables.isDisjoint(with: names) || signature.argumentMarkers.contains(where: commandLine.contains) {
                out[agent, default: []].append(process.pid)
            }
        }
        return out
    }

    public static func isRunning(_ agentID: String) -> Bool {
        find()[agentID] != nil
    }

    /// Every process this user can inspect.
    public static func allProcesses() -> [Process] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) * 2)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return pids.prefix(Int(max(0, filled))).compactMap { pid in
            guard pid > 0 else { return nil }
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
            return Process(pid: pid, executable: String(cString: path), arguments: arguments(of: pid))
        }
    }

    /// argv via `KERN_PROCARGS2`: [argc][exec path\0…padding\0][argv0\0argv1\0…].
    static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }

        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size && buffer[index] != 0 { index += 1 }   // exec path
        while index < size && buffer[index] == 0 { index += 1 }   // padding
        var args: [String] = []
        while args.count < argc && index < size {
            let start = index
            while index < size && buffer[index] != 0 { index += 1 }
            args.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return args
    }
}
