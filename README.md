# agent-backup-macos

一個 macOS App：把 coding agent（Claude Code、Codex、Gemini CLI、Copilot…）的 MCP 設定與聊天記錄加密備份到 Google Drive，並在另一台 Mac 上還原。

![Agent Backup 總覽](docs/images/overview.png)

- 設計文件：[docs/DESIGN.md](docs/DESIGN.md)
- UI 設計：[docs/UI.md](docs/UI.md)
- Roadmap：[docs/ROADMAP.md](docs/ROADMAP.md)（[GitHub Milestones](https://github.com/kkdai/agent-backup/milestones)）
- 支援備份：**Claude Code**、**Codex CLI**、**Gemini CLI**、**GitHub Copilot CLI**、**Claude Desktop**（MCP 設定）

## App

```sh
scripts/build-app.sh --open     # 打包並開啟 build/Agent Backup.app
```

## 連接 Google Drive（第一次）

```sh
scripts/setup-google-drive.sh
```

互動式步驟會帶你建立 Google Cloud OAuth client（Desktop app、`drive.file` scope）並登入。

## CLI

```sh
swift build
B=.build/debug/agent-backup

$B detect                                  # 偵測 agent、session 數、MCP servers
$B backup --to gdrive                      # 備份到 My Drive/AgentBackup（第一次會設定 passphrase）
$B backup --to ~/BackupFolder              # 或備份到本機資料夾
$B snapshots --from gdrive                 # 列出快照

# 還原：預設只顯示計畫（dry run），加 --apply 才寫入
$B restore --from gdrive \
    --map "~/Documents=~/Code" \             # 額外路徑對應（~ 左邊是舊電腦、右邊是新電腦）
    --on-conflict keep|replace|rename \      # 兩邊都改過時的處理方式，預設 keep
    --apply

# 想安全試玩：還原到假的 home
$B restore --from gdrive --home /tmp/fakehome --apply

$B drive status | login | logout           # Google Drive 連線
$B lock --from gdrive                      # 從 Keychain 移除已解鎖的金鑰
```

- 所有存到備份位置的東西（檔案內容、快照清單）都用 AES-GCM 加密；Google 只看得到密文。
- 解鎖後的金鑰會存在本機 Keychain，之後不用每次輸入 passphrase。
- 環境變數：`AGENT_BACKUP_PASSPHRASE`（跳過輸入）、`AGENT_BACKUP_NO_KEYCHAIN=1`（不存 Keychain）。

被覆蓋的檔案會先複製到 `~/Library/Application Support/AgentBackup/rollback/<時間>/`，新建立的檔案列在該資料夾的 `created-files.txt`。

## 測試

```sh
swift test
```
