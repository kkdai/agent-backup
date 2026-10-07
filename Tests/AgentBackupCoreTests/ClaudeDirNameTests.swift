import Testing
@testable import AgentBackupCore

/// Expected names were produced by Claude Code's own sanitizer (extracted from its bundled JS
/// and run in node): replace non-alphanumerics with "-", and above 200 characters truncate
/// and append the base-36 Java-style hash of the original path.
struct ClaudeDirNameTests {
    @Test func matchesClaudeCode() {
        let cases: [(String, String)] = [
            ("/Users/alice/Documents/app", "-Users-alice-Documents-app"),
            ("/Users/alice/very-long-folder-name/very-long-folder-name/very-long-folder-name/very-long-folder-name/very-long-folder-name/very-long-folder-name/very-long-folder-name/very-long-folder-name/very-long-folder-name/very-long-folder-name/very-long-folder-name/very-long-folder-name/project", "-Users-alice-very-long-folder-name-very-long-folder-name-very-long-folder-name-very-long-folder-name-very-long-folder-name-very-long-folder-name-very-long-folder-name-very-long-folder-name-very-long-f-fghjog"),
            ("/Users/a/中文資料夾/中文資料夾/中文資料夾/中文資料夾/中文資料夾/中文資料夾/中文資料夾/中文資料夾/中文資料夾/中文資料夾/中文資料夾/中文資料夾/中文資料夾/中文資料夾/中文資料夾/中文資料夾/中文資料夾/中文資料夾/中文資料夾/中文資料夾/中文資料夾/中文資料夾/中文資料夾/中文資料夾/中文資料夾/中文資料夾/中文資料夾/中文資料夾/中文資料夾/中文資料夾/中文資料夾/中文資料夾/中文資料夾/中文資料夾/中文資料夾/中文資料夾/中文資料夾/中文資料夾/中文資料夾/中文資料夾/x", "-Users-a-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------bl0css"),
            ("/Users/a/xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", "-Users-a-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx-ons97o"),
        ]
        for (path, expected) in cases {
            #expect(PathMapper.claudeProjectDirName(for: path) == expected)
        }
    }
}
