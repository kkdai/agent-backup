import AgentBackupCore
import AppKit
import SwiftUI

struct DriveView: View {
    @Environment(AppModel.self) private var model
    @State private var setupError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 14) {
                Image(systemName: "icloud.fill")
                    .font(.system(size: 26)).foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(.blue.gradient, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Google Drive").font(.largeTitle.weight(.semibold))
                    Text("備份存在 My Drive › AgentBackup，App 只能存取自己建立的檔案。")
                        .foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(24)
    }

    @ViewBuilder private var content: some View {
        switch model.drive {
        case .checking:
            Card { HStack { ProgressView().controlSize(.small); Text("正在連線…") } }
        case .notConfigured:
            setup
        case .loggedOut:
            Card {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("尚未登入").font(.headline)
                        Text("會打開瀏覽器讓你選擇 Google 帳號並授權。").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { Task { await model.login() } } label: {
                        if model.isLoggingIn { ProgressView().controlSize(.small) } else { Text("登入 Google") }
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(model.isLoggingIn)
                }
            }
        case .connected(let status):
            connected(status)
        case .failed(let message):
            Card {
                HStack {
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Spacer()
                    Button("重試") { Task { await model.refreshDrive() } }
                }
            }
        }
    }

    private var setup: some View {
        Card(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                Text("第一次使用：設定 Google OAuth client").font(.headline)
                Text("目前版本需要你在 Google Cloud Console 建立自己的 OAuth client（Desktop app），之後的正式版會內建。")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    step(1, "在終端機執行 scripts/setup-google-drive.sh，跟著步驟建立 client 並下載 JSON")
                    step(2, "回到這裡，選擇下載的 client_secret_….json")
                    step(3, "登入 Google 帳號")
                }
                HStack {
                    Button("選擇 OAuth client JSON…") { chooseClientJSON() }
                        .buttonStyle(.borderedProminent)
                    Link("設定說明", destination: URL(string: "https://github.com/kkdai/agent-backup#連接-google-drive第一次")!)
                }
                if let setupError {
                    Text(setupError).font(.callout).foregroundStyle(.red)
                }
            }
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(.caption.weight(.bold)).foregroundStyle(.white)
                .frame(width: 18, height: 18).background(.blue, in: Circle())
            Text(text)
        }
    }

    private func chooseClientJSON() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.message = "選擇從 Google Cloud Console 下載的 client_secret_….json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await model.installClient(from: url)
                setupError = nil
            } catch {
                setupError = error.localizedDescription
            }
        }
    }

    private func connected(_ status: AppModel.DriveStatus) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                StatCard(title: "帳號", symbol: "person.crop.circle",
                         value: status.account.displayName ?? "已連線", detail: status.account.email ?? "", tint: .primary)
                StatCard(title: "備份", symbol: "clock.arrow.circlepath",
                         value: "\(status.snapshots.count) 份",
                         detail: status.snapshots.first.map { "最近：\(Format.dateTime($0.date))" } ?? "還沒有備份")
                StatCard(title: "加密", symbol: "lock.fill",
                         value: status.initialized ? "已設定" : "尚未設定",
                         detail: status.initialized ? "需要 passphrase 才能還原" : "第一次備份時設定 passphrase",
                         tint: status.initialized ? .green : .orange)
            }
            if let used = status.account.usedBytes {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Google 帳號儲存空間").font(.headline)
                            Spacer()
                            Text(status.account.limitBytes.map { "\(Format.bytes(used)) / \(Format.bytes($0))" } ?? Format.bytes(used))
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                        if let limit = status.account.limitBytes, limit > 0 {
                            ShareBar(fraction: min(1, Double(used) / Double(limit)), tint: .blue)
                        }
                    }
                }
            }
            HStack {
                Button("重新整理") { Task { await model.refreshDrive() } }
                Spacer()
                Button("登出", role: .destructive) { Task { await model.logout() } }
            }
        }
    }
}

struct SnapshotsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("備份紀錄").font(.largeTitle.weight(.semibold))
            if let status = model.driveStatus {
                if status.snapshots.isEmpty {
                    Card { Text("Google Drive 上還沒有備份。到「總覽」按「立即備份」。").foregroundStyle(.secondary) }
                } else {
                    Card(padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(Array(status.snapshots.enumerated()), id: \.element.id) { index, snapshot in
                                if index > 0 { Divider() }
                                row(snapshot, isLatest: index == 0)
                            }
                        }
                    }
                }
                Text("還原精靈即將推出（#9）。目前可以用 CLI：agent-backup restore --from gdrive")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Card {
                    HStack {
                        Text("連線 Google Drive 後才能看到備份紀錄。").foregroundStyle(.secondary)
                        Spacer()
                        Button("前往 Google Drive") { model.route = .drive }
                    }
                }
            }
        }
        .padding(24)
    }

    private func row(_ snapshot: SnapshotRef, isLatest: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "archivebox").foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(Format.dateTime(snapshot.date)).fontWeight(.medium)
                    if isLatest { Badge(text: "最新", color: .green) }
                }
                Text("\(snapshot.hostname) · \(Format.relative(snapshot.date))").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("還原…") {}
                .disabled(true)
                .help("還原精靈即將推出（#9）")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

struct PassphraseSheet: View {
    @Environment(AppModel.self) private var model
    let prompt: PassphrasePrompt
    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var error: String?
    @State private var working = false

    private var isNew: Bool { if case .create = prompt { true } else { false } }

    private var valid: Bool {
        isNew ? passphrase.count >= 8 && passphrase == confirmation : !passphrase.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(isNew ? "設定備份 passphrase" : "輸入備份 passphrase", systemImage: "lock.fill")
                .font(.title2.weight(.semibold))
            Text(isNew
                 ? "所有備份都會用這組 passphrase 加密。在新電腦還原時需要它——忘記就無法還原，Google 和我們都救不回來。"
                 : "這台 Mac 還沒有解鎖過 Google Drive 上的備份。輸入後會記在 Keychain，下次不用再輸入。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Passphrase", text: $passphrase)
            if isNew {
                SecureField("再輸入一次", text: $confirmation)
                Text(passphrase.isEmpty || passphrase.count >= 8 ? "至少 8 個字元，建議用一句好記的話。" : "至少需要 8 個字元")
                    .font(.caption).foregroundStyle(passphrase.isEmpty || passphrase.count >= 8 ? Color.secondary : Color.orange)
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { model.passphrasePrompt = nil }
                    .keyboardShortcut(.cancelAction)
                Button {
                    working = true
                    Task {
                        do { try await model.submitPassphrase(passphrase) } catch { self.error = error.localizedDescription }
                        working = false
                    }
                } label: {
                    if working { ProgressView().controlSize(.small) } else { Text(isNew ? "設定並開始備份" : "解鎖並備份") }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!valid || working)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(24)
        .frame(width: 440)
    }
}
