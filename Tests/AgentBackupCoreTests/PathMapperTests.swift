import Testing
@testable import AgentBackupCore

struct PathMapperTests {
    let mapper = PathMapper(rules: [
        .init(from: "/Users/evanlin", to: "/Users/evan"),
        .init(from: "/Users/evanlin/Documents/app", to: "/Users/evan/Code/app"),
    ])

    @Test func encodesClaudeProjectDirNames() {
        #expect(PathMapper.claudeProjectDirName(for: "/Users/evanlin/Documents/kkdai.github.io")
            == "-Users-evanlin-Documents-kkdai-github-io")
    }

    @Test func mapsLongestPrefixFirst() {
        #expect(mapper.map(path: "/Users/evanlin/Documents/app/src") == "/Users/evan/Code/app/src")
        #expect(mapper.map(path: "/Users/evanlin/Documents/other") == "/Users/evan/Documents/other")
        #expect(mapper.map(path: "/Users/evanlinx") == "/Users/evanlinx")
    }

    @Test func rewritesTextOnSegmentBoundariesOnly() {
        let text = #"{"cwd":"/Users/evanlin/Documents/app","x":"/Users/evanlinx/a /Users/evanlin"}"#
        #expect(mapper.rewrite(text) == #"{"cwd":"/Users/evan/Code/app","x":"/Users/evanlinx/a /Users/evan"}"#)
    }

    @Test func rewritesPathsAfterJSONEscapes() {
        #expect(mapper.rewrite(#"{"content":"Exit 1\n/Users/evanlin/go\t/Users/evanlin/x"}"#)
            == #"{"content":"Exit 1\n/Users/evan/go\t/Users/evan/x"}"#)
        #expect(mapper.rewrite("plain/Users/evanlin") == "plain/Users/evanlin")
    }

    @Test func doesNotRemapAlreadyMappedOutput() {
        // `/Users/evan` is the output of one rule and must not be fed to another.
        let swap = PathMapper(rules: [.init(from: "/a", to: "/b"), .init(from: "/b", to: "/a")])
        #expect(swap.rewrite("/a/x /b/y") == "/b/x /a/y")
    }

    @Test func mapsEncodedDirNamesWhenPathUnknown() {
        #expect(mapper.mapClaudeProjectDirName("-Users-evanlin-Documents-foo") == "-Users-evan-Documents-foo")
    }
}
