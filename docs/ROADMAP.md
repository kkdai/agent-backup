# Roadmap

進度以 GitHub 為準：[Milestones](https://github.com/kkdai/agent-backup/milestones) · [Issues](https://github.com/kkdai/agent-backup/issues)。設計細節見 [DESIGN.md](DESIGN.md)、介面見 [UI.md](UI.md)。

## 目前狀態（2026-10-07）

- 支援 6 種 agent：Claude Code、Codex CLI、Gemini CLI、GitHub Copilot CLI、Claude Desktop、Cursor（後兩者為 MCP 設定）
- 備份位置：Google Drive、iCloud Drive、本機資料夾；端對端加密
- App：偵測、備份、還原精靈、回滾、跨 agent MCP 複製、瀏覽 / 搜尋備份、menu bar、每天自動備份

**需要你處理的項目**：#1、#7（用真實 Google 帳號實測）、#19、#23（決定）、#21（Apple Developer ID 憑證）、#22（Google OAuth 驗證）

## [M1 · 加密 + Google Drive](https://github.com/kkdai/agent-backup/milestone/1)（4/5）

- [ ] [#1](https://github.com/kkdai/agent-backup/issues/1) 用真實 Google 帳號實測 Drive 備份 / 還原 `drive`
- [x] [#2](https://github.com/kkdai/agent-backup/issues/2) 平行上傳 + 進度顯示 `core` `drive`
- [x] [#3](https://github.com/kkdai/agent-backup/issues/3) Resumable 上傳從中斷點續傳 `drive`
- [x] [#4](https://github.com/kkdai/agent-backup/issues/4) 更換 passphrase 指令 `core`
- [x] [#5](https://github.com/kkdai/agent-backup/issues/5) 快照保留策略 + 未引用 blob 清理 `core`

## [M2 · SwiftUI App](https://github.com/kkdai/agent-backup/milestone/2)（5/6）

- [x] [#6](https://github.com/kkdai/agent-backup/issues/6) App 外殼：SwiftUI 主視窗 + Xcode 專案 `app`
- [ ] [#7](https://github.com/kkdai/agent-backup/issues/7) 首次啟動流程：Google 登入 + 設定 passphrase `drive` `app`
- [x] [#8](https://github.com/kkdai/agent-backup/issues/8) 偵測畫面 + 選擇要備份的項目 `app`
- [x] [#9](https://github.com/kkdai/agent-backup/issues/9) 還原精靈：選快照 → 路徑對應 → 預覽 → 套用 `app`
- [x] [#10](https://github.com/kkdai/agent-backup/issues/10) 還原前偵測正在執行的 Claude Code `app` `provider`
- [x] [#11](https://github.com/kkdai/agent-backup/issues/11) 一鍵回滾 `core` `app`

## [M3 · 更多 Agent + 跨 Agent MCP](https://github.com/kkdai/agent-backup/milestone/3)（7/8）

- [x] [#12](https://github.com/kkdai/agent-backup/issues/12) Codex CLI provider `provider`
- [x] [#13](https://github.com/kkdai/agent-backup/issues/13) Gemini CLI provider `provider`
- [x] [#14](https://github.com/kkdai/agent-backup/issues/14) GitHub Copilot CLI provider `provider`
- [x] [#15](https://github.com/kkdai/agent-backup/issues/15) Claude Desktop MCP 設定 `provider`
- [x] [#16](https://github.com/kkdai/agent-backup/issues/16) 統一 MCP 模型 + 跨 Agent 複製 MCP 設定 `core` `provider`
- [x] [#17](https://github.com/kkdai/agent-backup/issues/17) 處理 Claude Code 長路徑專案資料夾（截斷 + hash） `core` `provider`
- [x] [#18](https://github.com/kkdai/agent-backup/issues/18) 調查 Cursor 的 MCP / 聊天記錄格式 `provider`
- [ ] [#19](https://github.com/kkdai/agent-backup/issues/19) 決定：是否備份專案內的 .mcp.json / CLAUDE.md / AGENTS.md `provider` `decision`

## [M4 · 自動化與發佈](https://github.com/kkdai/agent-backup/milestone/4)（0/4）

- [ ] [#20](https://github.com/kkdai/agent-backup/issues/20) 排程自動備份 + Menu bar `app` `distribution`
- [ ] [#21](https://github.com/kkdai/agent-backup/issues/21) Developer ID 簽章 + Notarization + DMG / Homebrew cask `distribution`
- [ ] [#22](https://github.com/kkdai/agent-backup/issues/22) 內建 OAuth client（使用者不用自建 Google Cloud 專案） `drive` `distribution`
- [ ] [#23](https://github.com/kkdai/agent-backup/issues/23) 決定：App 名稱 `decision`

## [Later](https://github.com/kkdai/agent-backup/milestone/5)（2/3）

- [x] [#24](https://github.com/kkdai/agent-backup/issues/24) Session 瀏覽 / 搜尋 `app`
- [x] [#25](https://github.com/kkdai/agent-backup/issues/25) 其他儲存位置：iCloud Drive / S3 / WebDAV `core`
- [ ] [#42](https://github.com/kkdai/agent-backup/issues/42) S3 / WebDAV 儲存位置 `core`
