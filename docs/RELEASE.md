# 發佈流程

## 發一個版本

```sh
git tag v0.3.0 && git push origin v0.3.0
```

`.github/workflows/release.yml` 會：跑測試 → 打包 `Agent Backup.app`（內含 CLI）→ 製作 `AgentBackup-<版本>.dmg` 與 `.sha256` → 建立 GitHub Release。

想先試跑而不發佈：GitHub › Actions › Release › **Run workflow**（只產生 DMG artifact）。

本機也能做同樣的事：

```sh
VERSION=0.3.0 scripts/build-app.sh
VERSION=0.3.0 scripts/make-dmg.sh
```

## 簽章與 notarization（需要 Apple Developer Program）

沒有設定以下 secrets 時，App 會用 ad-hoc 簽章，Release 說明會提醒使用者「右鍵 › 打開」或執行
`xattr -dr com.apple.quarantine "/Applications/Agent Backup.app"`。設定好之後不需要改程式，下一個 tag 就會自動簽章並 notarize。

| Repo secret | 內容 | 怎麼取得 |
|---|---|---|
| `DEVELOPER_ID_P12` | Developer ID Application 憑證（含私鑰）的 `.p12`，**base64** | Keychain Access › 匯出憑證成 .p12 → `base64 -i cert.p12 \| pbcopy` |
| `DEVELOPER_ID_P12_PASSWORD` | 匯出 .p12 時設定的密碼 | |
| `DEVELOPER_ID_IDENTITY` | 例如 `Developer ID Application: Your Name (ABCDE12345)` | `security find-identity -v -p codesigning` |
| `APPLE_ID` | Apple 帳號 email | |
| `APPLE_TEAM_ID` | 10 碼 Team ID | developer.apple.com › Membership |
| `APPLE_APP_PASSWORD` | App 專用密碼 | appleid.apple.com › 登入與安全性 › App 專用密碼 |

```sh
gh secret set DEVELOPER_ID_P12 < <(base64 -i cert.p12)
gh secret set DEVELOPER_ID_P12_PASSWORD
gh secret set DEVELOPER_ID_IDENTITY
gh secret set APPLE_ID
gh secret set APPLE_TEAM_ID
gh secret set APPLE_APP_PASSWORD
```

App 不在 sandbox 裡（需要讀 `~/.claude` 等隱藏資料夾），不上 Mac App Store；以 hardened runtime 簽章即可 notarize，不需要額外的 entitlements。

## Homebrew

1. 建立 tap repo：`gh repo create kkdai/homebrew-tap --public`
2. 每次發佈後產生 cask 並放到 tap 的 `Casks/agent-backup.rb`：

```sh
scripts/update-cask.sh 0.3.0 > ../homebrew-tap/Casks/agent-backup.rb
```

3. 使用者安裝：`brew install --cask kkdai/tap/agent-backup`（同時會把 `agent-backup` CLI 放進 PATH）

## App 圖示

`Resources/AppIcon.icns` 由 `swift scripts/make-icon.swift` 產生（SF Symbol + 漸層），要換設計就改這個腳本後重新產生。
