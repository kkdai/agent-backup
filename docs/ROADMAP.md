# Roadmap

進度以 GitHub 為準：[Milestones](https://github.com/kkdai/agent-backup/milestones) · [Issues](https://github.com/kkdai/agent-backup/issues)。設計細節見 [DESIGN.md](DESIGN.md)。

## 已完成

| 階段 | 內容 |
|---|---|
| **M0** · CLI 原型 | Claude Code provider、本機資料夾備份、還原 + 路徑重寫、MCP 逐項合併、session 只增不覆蓋、回滾副本（DESIGN §11） |
| **M1** · 核心 | 端對端加密（passphrase 包裝 data key、AES-GCM、keyed blob ID）、Google Drive store（`drive.file`）、OAuth loopback + PKCE、設定精靈（DESIGN §12） |

## [M1 · 加密 + Google Drive](https://github.com/kkdai/agent-backup/milestone/1)

核心已完成；剩下真實帳號實測與效能、維運功能。

- [ ] [#1](https://github.com/kkdai/agent-backup/issues/1) 用真實 Google 帳號實測 Drive 備份 / 還原 `drive`
- [ ] [#2](https://github.com/kkdai/agent-backup/issues/2) 平行上傳 + 進度顯示 `drive` `core`
- [ ] [#3](https://github.com/kkdai/agent-backup/issues/3) Resumable 上傳從中斷點續傳 `drive`
- [ ] [#4](https://github.com/kkdai/agent-backup/issues/4) 更換 passphrase 指令 `core`
- [ ] [#5](https://github.com/kkdai/agent-backup/issues/5) 快照保留策略 + 未引用 blob 清理 `core`

## [M2 · SwiftUI App](https://github.com/kkdai/agent-backup/milestone/2)

原生 Mac App：偵測、備份、還原精靈、衝突處理、回滾。

- [ ] [#6](https://github.com/kkdai/agent-backup/issues/6) App 外殼：SwiftUI 主視窗 + Xcode 專案 `app`
- [ ] [#7](https://github.com/kkdai/agent-backup/issues/7) 首次啟動流程：Google 登入 + 設定 passphrase `app` `drive`
- [ ] [#8](https://github.com/kkdai/agent-backup/issues/8) 偵測畫面 + 選擇要備份的項目 `app`
- [ ] [#9](https://github.com/kkdai/agent-backup/issues/9) 還原精靈：選快照 → 路徑對應 → 預覽 → 套用 `app`
- [ ] [#10](https://github.com/kkdai/agent-backup/issues/10) 還原前偵測正在執行的 Claude Code `app` `provider`
- [ ] [#11](https://github.com/kkdai/agent-backup/issues/11) 一鍵回滾 `app` `core`

## [M3 · 更多 Agent + 跨 Agent MCP](https://github.com/kkdai/agent-backup/milestone/3)

Codex、Gemini CLI、Copilot CLI、Claude Desktop；統一 MCP 模型與跨 agent 複製。

- [ ] [#12](https://github.com/kkdai/agent-backup/issues/12) Codex CLI provider `provider`
- [ ] [#13](https://github.com/kkdai/agent-backup/issues/13) Gemini CLI provider `provider`
- [ ] [#14](https://github.com/kkdai/agent-backup/issues/14) GitHub Copilot CLI provider `provider`
- [ ] [#15](https://github.com/kkdai/agent-backup/issues/15) Claude Desktop MCP 設定 `provider`
- [ ] [#16](https://github.com/kkdai/agent-backup/issues/16) 統一 MCP 模型 + 跨 Agent 複製 MCP 設定 `core` `provider`
- [ ] [#17](https://github.com/kkdai/agent-backup/issues/17) 處理 Claude Code 長路徑專案資料夾（截斷 + hash） `provider` `core`
- [ ] [#18](https://github.com/kkdai/agent-backup/issues/18) 調查 Cursor 的 MCP / 聊天記錄格式 `provider`
- [ ] [#19](https://github.com/kkdai/agent-backup/issues/19) 決定：是否備份專案內的 .mcp.json / CLAUDE.md / AGENTS.md `decision` `provider`

## [M4 · 自動化與發佈](https://github.com/kkdai/agent-backup/milestone/4)

排程備份、menu bar、簽章 + notarization、內建 OAuth client。

- [ ] [#20](https://github.com/kkdai/agent-backup/issues/20) 排程自動備份 + Menu bar `distribution` `app`
- [ ] [#21](https://github.com/kkdai/agent-backup/issues/21) Developer ID 簽章 + Notarization + DMG / Homebrew cask `distribution`
- [ ] [#22](https://github.com/kkdai/agent-backup/issues/22) 內建 OAuth client（使用者不用自建 Google Cloud 專案） `distribution` `drive`
- [ ] [#23](https://github.com/kkdai/agent-backup/issues/23) 決定：App 名稱 `decision`

## [Later](https://github.com/kkdai/agent-backup/milestone/5)

之後再說的想法。

- [ ] [#24](https://github.com/kkdai/agent-backup/issues/24) Session 瀏覽 / 搜尋 `app`
- [ ] [#25](https://github.com/kkdai/agent-backup/issues/25) 其他儲存位置：iCloud Drive / S3 / WebDAV `core`
