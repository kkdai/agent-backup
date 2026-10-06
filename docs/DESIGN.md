# Agent Backup for macOS — 設計草案 v0.1

> 狀態：方向已定（2026-10-06），見 §9。標記 ❓ 的地方還沒決定。

## 1. 目標

一個 macOS App，把多個 coding agent 的設定與聊天記錄備份到 Google Drive，
並能在另一台 Mac 安裝同一個 App 後一鍵還原。

**範圍內**
- MCP server 設定（全域 + 專案層級）
- 聊天記錄 / sessions
- （延伸）agent 的一般設定、skills、memory、custom commands、plugins 清單

**範圍外（至少 MVP 不做）**
- 即時雙向同步（像 Dropbox 那樣）— 定位是「備份 / 搬家」
- Windows / Linux
- 備份 IDE 本身（VS Code、Cursor 的 extension 等）

## 2. 支援的 Agent 與資料位置

以這台 Mac 實際看到的路徑為準（✅ = 本機已確認存在）：

| Agent | MCP 設定 | Sessions | 其他值得備份 | 機密檔（預設不備份） |
|---|---|---|---|---|
| Claude Code ✅ | `~/.claude.json` 的 `mcpServers` 及 `projects[path].mcpServers`；專案內 `.mcp.json` | `~/.claude/projects/<編碼後路徑>/*.jsonl`、`~/.claude/history.jsonl` | `~/.claude/settings.json`、`skills/`、`plugins/`（清單）、`CLAUDE.md`、`projects/*/memory/` | `~/.claude.json` 的 `oauthAccount`、Keychain token |
| Claude Desktop ✅ | `~/Library/Application Support/Claude/claude_desktop_config.json` | 雲端（不需備份） | — | — |
| Codex CLI ✅ | `~/.codex/config.toml` 的 `[mcp_servers.*]` | `~/.codex/sessions/**/rollout-*.jsonl` + `state_5.sqlite`（`threads` 表索引） | `config.toml`、`skills/`、`memories/`、`AGENTS.md` | `~/.codex/auth.json` |
| Gemini CLI ✅ | `~/.gemini/settings.json` 的 `mcpServers` | `~/.gemini/tmp/<project>/chats/`、`~/.gemini/history/` | `settings.json`、`GEMINI.md`、`projects.json` | `oauth_creds.json`、`google_accounts.json` |
| GitHub Copilot CLI ✅ | `~/.copilot/mcp-config.json` | `~/.copilot/session-state/` ❓待確認 | `config.json` | token |
| Cursor | `~/.cursor/mcp.json` | SQLite（`state.vscdb`）❓格式不穩定 | — | — |

> 各 agent 的路徑會隨版本改變，所以路徑**不能寫死在程式碼**，而是放在可更新的 Provider 定義裡（見 §4）。

## 3. 核心難題（要先討論清楚的）

### 3.1 路徑重寫（最重要）
Sessions 裡大量嵌入絕對路徑：
- Claude Code 的資料夾名稱就是編碼後的路徑：`-Users-alice-Documents-my-app`
- jsonl 每一行都有 `cwd` 欄位
- Codex `threads.cwd`、`rollout_path`
- `~/.claude.json` 的 `projects` key 就是專案絕對路徑

新電腦如果使用者名稱或專案位置不同（`/Users/alice` → `/Users/al`），還原後 agent 會「找不到」這些 session。
**方案**：備份時把 `$HOME` 正規化成 `{{HOME}}` 佔位符；還原時讓使用者確認路徑對應表（例如 `~/Documents/x` → `~/Code/x`），再重寫資料夾名稱與內容。

### 3.2 機密資料
MCP 設定裡常有 API key（`env` 裡的 `GITHUB_TOKEN` 等），OAuth 憑證更敏感。
**方案**：
- 備份檔一律 **端對端加密**（AES-GCM，CryptoKit），金鑰由使用者的 passphrase 衍生（Argon2/scrypt），存在本機 Keychain；Google 只看得到密文。
- OAuth / auth 檔**一律排除**（已決定），還原後在新電腦重新登入。
- MCP 的 secret 可選擇「抽出成變數」：還原時要求重新輸入，或從加密區塊還原。

### 3.3 一致性
- SQLite（Codex `state_5.sqlite`，有 WAL）不能直接複製檔案 → 用 SQLite backup API 或 `VACUUM INTO`。
- agent 正在執行時寫入 jsonl → 備份前偵測正在跑的 process 並提示，或只取完整的行。

### 3.4 還原時的合併策略
新電腦可能已經有自己的設定：
- **MCP 設定**：逐個 server 合併，衝突時顯示 diff 讓使用者選（保留本機 / 用備份 / 都保留改名）。
- **Sessions**：只新增、不覆蓋（以 session ID 判斷）。
- **一般設定檔**：預設覆蓋前先在本機做一份 `.pre-restore` 備份，可一鍵回滾。

### 3.5 App Sandbox
App Sandbox 無法自由讀取 `~/.claude`、`~/.codex` 這類隱藏資料夾。
**建議**：不上 Mac App Store，用 Developer ID 簽章 + notarization 發佈（DMG / Homebrew cask），非 sandbox。❓（見 §10）

## 4. 架構

```
┌─────────────── SwiftUI App ───────────────┐
│  主視窗（備份/還原/歷史）  +  Menu bar 圖示   │
└──────────────────┬─────────────────────────┘
                   │
┌──────────── AgentBackupCore (Swift Package) ────────────┐
│ ProviderRegistry   ── ClaudeCodeProvider / CodexProvider │
│                       GeminiProvider / CopilotProvider … │
│ SnapshotBuilder    ── 收集檔案、正規化路徑、打包          │
│ Crypto             ── 加密 / 解密、Keychain              │
│ StorageBackend     ── GoogleDriveBackend（之後可加 iCloud/S3/本機資料夾）│
│ RestorePlanner     ── 產生還原計畫（diff、衝突、路徑對應）  │
│ RestoreExecutor    ── 執行 + 本機回滾點                    │
└──────────────────────────────────────────────────────────┘
                   │
           CLI（`agent-backup`）── 方便測試與自動化
```

### Provider 介面（草案）
```swift
protocol AgentProvider {
    var id: String { get }                 // "claude-code"
    var displayName: String { get }
    func detect() -> Bool                  // 這台電腦有沒有裝
    func collect(options: BackupOptions) throws -> [BackupItem]
    func mcpServers() throws -> [MCPServer]        // 統一格式，給 UI 顯示與合併
    func planRestore(_ snapshot: AgentSnapshot, pathMap: PathMap) throws -> RestorePlan
}
```
`BackupItem` 有分類：`.mcp`、`.session`、`.settings`、`.secret`，UI 讓使用者勾選。

### 統一 MCP 模型
各家格式不同（JSON / TOML、欄位名 `command`/`args`/`env`/`url`/`type`），
內部轉成統一的 `MCPServer`，因此可以做 **跨 agent 複製 MCP 設定**（例如把 Claude Code 的 MCP 套到 Codex）— 已決定要做（M3）。

## 5. 備份格式（存在 Google Drive）

```
AgentBackup/                       ← 使用者看得到的資料夾（已決定）
  devices/<device-id>.json         ← 裝置名稱、最後備份時間
  snapshots/<timestamp>-<device>/
      manifest.json                ← 版本、agent 清單、每個檔案的 hash、路徑對應
      blobs 參照
  blobs/<sha256>.enc               ← 內容定址、加密後的檔案（去重）
```
- **內容定址 + 去重**：sessions 是 append-only，大部分檔案不會變，第二次之後的備份只上傳新的 blob → 增量備份很便宜。
- 本機目前約：Claude 61MB、Codex 223MB、Gemini 17MB；壓縮（zstd/lzfse）後應小很多。
- 保留策略：保留最近 N 份 + 每週/每月各一份，舊的 blob 做 GC。

## 6. Google Drive 整合
- OAuth 2.0 Desktop app + PKCE，透過系統瀏覽器（`ASWebAuthenticationSession`）登入。
- Scope：`drive.file`（只能動 App 自己建的檔案）或 `drive.appdata`（隱藏資料夾）— 兩者都不需要 Google 嚴格審查。
- 上傳：resumable upload，支援大檔續傳。
- refresh token 存 Keychain。
- ❓需要你建立 Google Cloud 專案的 OAuth client（之後可用 wizard 帶你做）。

## 7. 使用流程

**第一次（舊電腦）**
1. 開 App → 自動偵測已安裝的 agents，列出找到的 MCP servers 與 session 數量
2. 登入 Google → 設定加密 passphrase（提醒：忘記就無法還原）
3. 勾選要備份的項目 → 備份

**新電腦**
1. 安裝 App → 登入同一個 Google 帳號 → 輸入 passphrase
2. 選擇來源裝置與快照
3. 路徑對應確認（自動猜測，例如偵測到 `~/Documents/my-app` 不存在時提示）
4. 預覽還原計畫（新增 / 衝突 / 跳過）→ 執行
5. 提示需要重新登入的 agent（claude login、codex login…）與需要安裝的 MCP 依賴（`npx`、`uvx`、Docker）

**日常**
- Menu bar：「立即備份」、上次備份時間
- 排程自動備份（每天 / agent 結束 session 後），用 `SMAppService` 註冊 login item

## 8. 分階段

| 階段 | 內容 |
|---|---|
| **M0** ✅ | Swift Package + CLI；Claude Code provider；備份到**本機資料夾**；還原 + 路徑重寫（見 §11） |
| **M1** ✅ | 加密；Google Drive backend；增量 blob（見 §12） |
| **M2** | SwiftUI App（偵測、勾選、還原預覽、衝突處理） |
| **M3** | Codex、Gemini、Copilot、Claude Desktop providers；**跨 agent MCP 複製** |
| **M4** | 排程備份、menu bar、保留策略、簽章與 notarization |
| 之後 | session 瀏覽/搜尋、其他雲端 |

## 9. 已決定（2026-10-06）

| # | 問題 | 決定 |
|---|---|---|
| 1 | 定位 | **備份 / 搬家**，不做持續同步 |
| 2 | 第一個 agent | **Claude Code**，之後 Codex、Gemini |
| 3 | 憑證 | **不備份**，到新電腦重新登入（還原完成後列出需要登入的 agent） |
| 4 | Drive 位置 | 使用者看得到的 **`AgentBackup/`** 資料夾（scope `drive.file`） |
| 5 | 技術 | **純 Swift**（Swift Package + CLI + SwiftUI） |
| 6 | 跨 agent MCP 複製 | **要做**，放在 M3（有第二個 provider 後） |

## 10. 還沒決定 ❓

- App 名稱（暫定 `agent-backup-macos`）
- 發佈方式：Developer ID + DMG/Homebrew（建議）
- 專案內的 `.mcp.json` / `CLAUDE.md` 要不要備份（通常已在 git）

## 11. M0 實作紀錄（2026-10-06）

程式碼：`Sources/AgentBackupCore`（核心）、`Sources/agent-backup`（CLI）、`Tests/`。

**Claude Code 實際備份內容**
- `~/.claude/`：`settings.json`、`CLAUDE.md`、`history.jsonl`、`skills/`、`commands/`、`agents/`、`output-styles/`
- `~/.claude/projects/**`：session `.jsonl`、session 附件（`<uuid>/tool-results` 等）、`memory/`
- `~/.claude.json` **只取**：`mcpServers` 與各專案的 `mcpServers`、`allowedTools`、`enabled/disabledMcpjsonServers`（登入、統計等全部排除）
- 外掛：只備份清單，還原時列出 `claude plugin install …` 指令（不複製 plugin cache）
- 排除：`skills/synced`（登入後會從 claude.ai 同步）、cache、telemetry、`sessions/`（執行中狀態）、shell snapshots
- symlink 的 skill（例如指向 `~/.agents/skills`）會備份實際內容

**路徑處理**
- 專案資料夾名稱是有損編碼（`a.b` 與 `a-b` 都變成 `a-b`），所以從 `~/.claude.json`、history 或 session 的 `cwd` 還原真正路徑後再對應
- 文字內容用 regex 重寫，左右兩邊都檢查路徑邊界（`/Users/al` 不會誤中 `/Users/alice`），JSON 跳脫字元（`\n/Users/…`）也算邊界
- 還原後保留檔案的修改時間，`claude --resume` 的排序不會亂

**合併規則**
- Session：只往後加。備份比較長就更新；本機比較長（新電腦已經繼續聊）就保留本機
- `history.jsonl`：兩邊合併、去重、依時間排序
- MCP：逐個 server 合併，依 `--on-conflict` 處理衝突
- 其他檔案：依 `--on-conflict`（`rename` 會另存成 `*.restored.*`）

**實測（本機資料）**：31 個檔案 16 MB → 壓縮後 5 MB；第二次備份 0 個新 blob；還原到不同使用者名稱 + `~/Documents→~/Code` 後，沒有殘留舊路徑。

**已知限制 / 下一步**
- 很長的專案路徑 Claude Code 會截斷並加 hash，目前沒處理
- 還原必須先關閉 Claude Code（它執行時會覆寫 `~/.claude.json`）；App 版要自動偵測
- 回滾目前要手動（把 rollback 資料夾複製回去、刪除 `created-files.txt` 列出的檔案）；App 版要一鍵回滾

## 12. M1 實作紀錄（2026-10-06）

**加密**（`Vault.swift`）
- 隨機 256-bit data key；`keyfile.json` 存的是用 passphrase 衍生金鑰（PBKDF2-HMAC-SHA256，600k 次）包起來的 data key → 之後換 passphrase 不用重新加密整個備份
- 每個 blob 與快照清單：先 lzfse 壓縮，再 AES-256-GCM 加密（HKDF 衍生出加密用與 ID 用兩把子金鑰）
- Blob ID = HMAC-SHA256(子金鑰, 明文)：仍可去重，但 Google 無法比對「是否包含某個已知檔案」
- 解鎖後的 data key 快取在 Keychain（`AgentBackup` / `vault-<keyfile 指紋>`，ThisDeviceOnly）
- 快照格式升到 v2；M0 的未加密快照不再支援

**Google Drive**（`GoogleOAuth.swift`、`GoogleDriveStore.swift`）
- OAuth：系統瀏覽器 + `127.0.0.1` loopback redirect + PKCE + state；refresh token 存 Keychain
- Scope `drive.file`：只看得到 App 自己建立的檔案；同一個 OAuth client 在不同 Mac 上看得到同一份備份
- `My Drive/AgentBackup/{keyfile.json, blobs/, snapshots/}`；開始時一次列出 blob 清單（分頁），之後只上傳缺少的
- ≤5 MB 用 multipart 上傳，更大用 resumable session
- 429 / 5xx / rateLimitExceeded：指數退避重試 5 次；401：刷新 token 重試一次
- `invalid_grant`（被撤銷，或 App 停在 Testing 狀態 7 天到期）→ 清除登入，提示重新 `drive login`
- 拒絕覆蓋已存在的 `keyfile.json`（覆蓋會讓舊快照全部無法解密）

**測試**：28 個（含假 Drive 的分頁、resumable、重試、401；用真實 loopback socket 跑完整 OAuth + PKCE 流程；端對端「舊 Mac 備份 → 新 Mac 只靠 passphrase 還原」）。

**還沒做**
- 用真的 Google 帳號實測（需要先跑 `scripts/setup-google-drive.sh`）
- 上傳是逐一進行；Codex 這種上百 MB 的資料要改成平行上傳 + 進度顯示
- resumable 上傳中斷時是整個檔案重傳，還不會從中斷點續傳
- 換 passphrase 的指令（`Vault.keyfile(passphrase:)` 已經有，CLI 還沒接）
- 舊快照清理（保留策略 + 刪除沒被引用的 blob）
- 正式 App 要內建 OAuth client，使用者就不用自己建 Google Cloud 專案
