# agent-backup-macos

一個 macOS App：把 coding agent（Claude Code、Codex、Gemini CLI、Copilot…）的 MCP 設定與聊天記錄加密備份到 Google Drive，並在另一台 Mac 上還原。

- 設計文件：[docs/DESIGN.md](docs/DESIGN.md)
- 目前進度：**M0**（Claude Code、備份到本機資料夾、還原 + 路徑重寫）— 尚未加密

## CLI（M0）

```sh
swift build
B=.build/debug/agent-backup

$B detect                                  # 偵測 agent、session 數、MCP servers
$B backup --to ~/BackupFolder              # 建立快照（增量，只存新的 blob）
$B snapshots --from ~/BackupFolder         # 列出快照

# 還原：預設只顯示計畫（dry run），加 --apply 才寫入
$B restore --from ~/BackupFolder \
    --map "~/Documents=~/Code" \             # 額外路徑對應（~ 左邊是舊電腦、右邊是新電腦）
    --on-conflict keep|replace|rename \      # 兩邊都改過時的處理方式，預設 keep
    --apply

# 想安全試玩：還原到假的 home
$B restore --from ~/BackupFolder --home /tmp/fakehome --apply
```

被覆蓋的檔案會先複製到 `~/Library/Application Support/AgentBackup/rollback/<時間>/`，新建立的檔案列在該資料夾的 `created-files.txt`。

## 測試

```sh
swift test
```
