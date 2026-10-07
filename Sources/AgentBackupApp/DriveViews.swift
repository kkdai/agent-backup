import AgentBackupCore
import AppKit
import SwiftUI

struct DriveView: View {
    @Environment(AppModel.self) private var model
    @State private var setupError: String?
    @State private var changingPassphrase = false
    @State private var pruning = false
    @State private var passphraseChanged = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 14) {
                Image(systemName: model.location == .gdrive ? "externaldrive.fill.badge.icloud" : "icloud.fill")
                    .font(.system(size: 26)).foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(.blue.gradient, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text("備份位置").font(.largeTitle.weight(.semibold))
                    Text(model.location == .gdrive
                         ? "備份存在 My Drive › AgentBackup，App 只能存取自己建立的檔案。"
                         : "備份存在 iCloud 雲碟 › AgentBackup，由 iCloud 同步到你的其他 Mac。")
                        .foregroundStyle(.secondary)
                }
            }
            Picker("", selection: Binding(get: { model.location }, set: { model.location = $0 })) {
                ForEach(BackupLocation.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 320)
            Text("兩種位置都用同樣的端對端加密；各自有自己的 passphrase。")
                .font(.caption).foregroundStyle(.secondary)
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
                StatCard(title: status.location == .gdrive ? "帳號" : "位置", symbol: status.location == .gdrive ? "person.crop.circle" : "icloud",
                         value: status.account.displayName ?? "已連線",
                         detail: status.account.email ?? "iCloud 雲碟 › AgentBackup", tint: .primary)
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
            ScheduleCard()
            HStack {
                Button("重新整理") { Task { await model.refreshDrive() } }
                if status.initialized {
                    Button("更換 passphrase…") { changingPassphrase = true }
                    Button("清理舊備份…") { pruning = true }
                        .disabled(status.snapshots.count < 2)
                }
                if passphraseChanged {
                    Label("已更換 passphrase", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Spacer()
                if status.location == .gdrive {
                    Button("登出", role: .destructive) { Task { await model.logout() } }
                }
            }
            .sheet(isPresented: $changingPassphrase) {
                ChangePassphraseSheet { passphraseChanged = true }.environment(model)
            }
            .sheet(isPresented: $pruning) {
                PruneSheet().environment(model)
            }
        }
    }
}

struct ScheduleCard: View {
    @Environment(AppModel.self) private var model
    @State private var hour = 3

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("自動備份").font(.headline)
                        Text(model.schedule.map { "每天 \(String(format: "%02d:%02d", $0.hour, $0.minute)) 備份並清理舊備份；錯過的會在 Mac 喚醒後補做。" }
                             ?? "每天固定時間自動備份到 \(model.location.title)，不需要打開 App。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.schedule == nil {
                        Picker("", selection: $hour) {
                            ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
                        }
                        .labelsHidden().frame(width: 90)
                    }
                    Toggle("", isOn: Binding(
                        get: { model.schedule != nil },
                        set: { model.setSchedule($0 ? .init(hour: hour, minute: 0) : nil) }
                    ))
                    .toggleStyle(.switch).labelsHidden()
                }
                if let error = model.scheduleError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                if model.schedule != nil, let last = BackupSchedule().recentLog(lines: 1).first {
                    Text("最近一次：\(last)").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

struct SnapshotsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("備份紀錄").font(.largeTitle.weight(.semibold))
            snapshots
            RollbackSection()
        }
        .padding(24)
    }

    @ViewBuilder private var snapshots: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let status = model.driveStatus {
                if status.snapshots.isEmpty {
                    Card { Text("\(model.location.title) 上還沒有備份。到「總覽」按「立即備份」。").foregroundStyle(.secondary) }
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
            } else {
                Card {
                    HStack {
                        Text("連線 \(model.location.title) 後才能看到備份紀錄。").foregroundStyle(.secondary)
                        Spacer()
                        Button("前往備份位置") { model.route = .drive }
                    }
                }
            }
        }
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
            Button("瀏覽…") { Task { await model.browse(snapshot) } }
                .help("閱讀、搜尋這份備份裡的聊天記錄")
            Button("還原…") { Task { await model.startRestore(snapshotID: snapshot.id) } }
                .help("把這份備份還原到這台 Mac")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// Restores done on this Mac, each undoable.
struct RollbackSection: View {
    @Environment(AppModel.self) private var model
    @State private var confirming: RollbackPoint?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "最近的還原")
            if let message = model.rollbackMessage {
                Label(message, systemImage: "arrow.uturn.backward.circle").foregroundStyle(.secondary)
            }
            if model.rollbackPoints.isEmpty {
                Card { Text("這台 Mac 還沒有還原過。每次還原都會保留復原點，可以一鍵退回還原前的狀態。").foregroundStyle(.secondary) }
            } else {
                Card(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(model.rollbackPoints.enumerated()), id: \.element.id) { index, point in
                            if index > 0 { Divider() }
                            row(point, isLatest: index == 0)
                        }
                    }
                }
                Text("要依序從最新的開始復原；復原後該紀錄會移除。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("復原這次還原？", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            presenting: confirming) { point in
            Button("復原", role: .destructive) {
                if RunningAgents.isRunning("claude-code") {
                    model.rollbackMessage = "Claude Code 正在執行，請先關閉所有 Claude Code 視窗再復原。"
                } else {
                    Task { await model.undo(point) }
                }
            }
        } message: { point in
            let plan = point.plan(home: model.home)
            Text("會放回 \(plan.restore.count) 個被覆蓋的檔案，並刪除 \(plan.delete.count) 個還原時新增的檔案。請先關閉 Claude Code。")
        }
    }

    private func row(_ point: RollbackPoint, isLatest: Bool) -> some View {
        let plan = point.plan(home: model.home)
        return HStack(spacing: 12) {
            Image(systemName: "arrow.down.doc").foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text("還原於 \(Format.dateTime(point.date))").fontWeight(.medium)
                Text("覆蓋 \(plan.restore.count) 個檔案 · 新增 \(plan.delete.count) 個檔案").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("復原…") { confirming = point }
                .disabled(!isLatest)
                .help(isLatest ? "退回這次還原之前的狀態" : "請先復原較新的還原")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

struct PruneSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var engine: BackupEngine?
    @State private var plan: PrunePlan?
    @State private var error: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("清理舊備份", systemImage: "trash").font(.title2.weight(.semibold))
            let policy = RetentionPolicy.standard
            Text("每台 Mac 各自保留：最近 \(policy.keepLast) 份，以及最近 \(policy.keepDaily) 天、\(policy.keepWeekly) 週、\(policy.keepMonthly) 個月各一份。之後刪除沒有任何備份用到的資料。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let plan {
                Card {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        GridRow { Text("保留").foregroundStyle(.secondary); Text("\(plan.keptSnapshots.count) 份備份") }
                        GridRow { Text("刪除").foregroundStyle(.secondary); Text("\(plan.deletedSnapshots.count) 份備份") }
                        GridRow { Text("釋放空間").foregroundStyle(.secondary); Text("\(Format.bytes(plan.freedBytes))（\(plan.deletedBlobs.count) 個檔案）") }
                    }
                }
                if plan.youngUnreferencedBlobs > 0 {
                    Text("另有 \(plan.youngUnreferencedBlobs) 個 24 小時內上傳、尚未被使用的檔案先保留（可能有其他 Mac 正在備份）。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if error == nil {
                HStack { ProgressView().controlSize(.small); Text("計算中…").foregroundStyle(.secondary) }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(role: .destructive) {
                    guard let engine, let plan else { return }
                    working = true
                    Task {
                        do {
                            try await engine.prune(plan)
                            await model.refreshDrive()
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                        }
                        working = false
                    }
                } label: {
                    if working { ProgressView().controlSize(.small) } else { Text("刪除") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(plan == nil || working || (plan?.deletedSnapshots.isEmpty ?? true) && (plan?.deletedBlobs.isEmpty ?? true))
            }
        }
        .padding(24)
        .frame(width: 460)
        .task {
            do {
                (engine, plan) = try await model.planPrune()
            } catch is CancellationError {
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct ChangePassphraseSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var onChanged: () -> Void
    @State private var current = ""
    @State private var new = ""
    @State private var confirmation = ""
    @State private var error: String?
    @State private var working = false

    private var valid: Bool { !current.isEmpty && new.count >= 8 && new == confirmation && new != current }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("更換備份 passphrase", systemImage: "key.fill").font(.title2.weight(.semibold))
            Text("現有的備份不用重新加密，換完後舊的 passphrase 就不能用了。其他 Mac 下次會要求輸入新的。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SecureField("目前的 passphrase", text: $current)
            SecureField("新的 passphrase（至少 8 個字元）", text: $new)
            SecureField("再輸入一次新的", text: $confirmation)
            if !confirmation.isEmpty && new != confirmation {
                Text("兩次輸入不一樣").font(.caption).foregroundStyle(.orange)
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    working = true
                    Task {
                        do {
                            try await model.changePassphrase(current: current, new: new)
                            onChanged()
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                        }
                        working = false
                    }
                } label: {
                    if working { ProgressView().controlSize(.small) } else { Text("更換") }
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
                 : "這台 Mac 還沒有解鎖過 \(model.location.title) 上的備份。輸入後會記在 Keychain，下次不用再輸入。")
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
                Button("取消") { model.cancelPassphrase() }
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
