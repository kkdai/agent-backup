import Testing
@testable import AgentBackupCore

struct PathMapperTests {
    let mapper = PathMapper(rules: [
        .init(from: "/Users/alice", to: "/Users/al"),
        .init(from: "/Users/alice/Documents/app", to: "/Users/al/Code/app"),
    ])

    @Test func encodesClaudeProjectDirNames() {
        #expect(PathMapper.claudeProjectDirName(for: "/Users/alice/Documents/kkdai.github.io")
            == "-Users-alice-Documents-kkdai-github-io")
    }

    @Test func mapsLongestPrefixFirst() {
        #expect(mapper.map(path: "/Users/alice/Documents/app/src") == "/Users/al/Code/app/src")
        #expect(mapper.map(path: "/Users/alice/Documents/other") == "/Users/al/Documents/other")
        #expect(mapper.map(path: "/Users/alicex") == "/Users/alicex")
    }

    @Test func rewritesTextOnSegmentBoundariesOnly() {
        let text = #"{"cwd":"/Users/alice/Documents/app","x":"/Users/alicex/a /Users/alice"}"#
        #expect(mapper.rewrite(text) == #"{"cwd":"/Users/al/Code/app","x":"/Users/alicex/a /Users/al"}"#)
    }

    @Test func rewritesPathsAfterJSONEscapes() {
        #expect(mapper.rewrite(#"{"content":"Exit 1\n/Users/alice/go\t/Users/alice/x"}"#)
            == #"{"content":"Exit 1\n/Users/al/go\t/Users/al/x"}"#)
        #expect(mapper.rewrite("plain/Users/alice") == "plain/Users/alice")
    }

    @Test func doesNotRemapAlreadyMappedOutput() {
        // `/Users/al` is the output of one rule and must not be fed to another.
        let swap = PathMapper(rules: [.init(from: "/a", to: "/b"), .init(from: "/b", to: "/a")])
        #expect(swap.rewrite("/a/x /b/y") == "/b/x /a/y")
    }

    @Test func mapsEncodedDirNamesWhenPathUnknown() {
        #expect(mapper.mapClaudeProjectDirName("-Users-alice-Documents-foo") == "-Users-al-Documents-foo")
    }
}
