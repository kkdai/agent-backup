import AgentBackupCore
import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class RestoreWizardModel: Identifiable {
    enum Step: Int, CaseIterable {
        case snapshot, paths, preview, done

        var title: String {
            switch self {
            case .snapshot: "選擇備份"
            case .paths: "路徑對應"
            case .preview: "預覽"
            case .done: "完成"
            }
        }
    }

    let id = UUID()
    private weak var app: AppModel?
    let engine: BackupEngine
    let snapshots: [SnapshotRef]
    let home: URL

    var step: Step = .snapshot
    var selectedID: String? {
        didSet { if selectedID != oldValue { Task { await loadManifest() } } }
    }
    var manifest: Manifest?
    var isLoadingManifest = false
    var projects: [ProjectMapping] = []
    /// sourcePath → chosen target, only where the user changed the default.
    var overrides: [String: String] = [:]
    var policy: ConflictPolicy = .keep
    var plans: [RestorePlan]?
    var isPlanning = false
    var isApplying = false
    var runningBlockers: [String] = []
    var result: ApplyResult?
    var error: String?

    init(app: AppModel?, engine: BackupEngine, snapshots: [SnapshotRef], selected: String?, home: URL? = nil) {
        self.app = app
        self.engine = engine
        self.snapshots = snapshots
        self.home = home ?? app?.home ?? URL(fileURLWithPath: NSHomeDirectory())
        selectedID = selected ?? snapshots.first?.id
        Task { await loadManifest() }
    }

    // MARK: - Steps

    var canGoNext: Bool {
        switch step {
        case .snapshot: manifest != nil && !isLoadingManifest
        case .paths: true
        case .preview: plans != nil && !isPlanning && !isApplying && writeCount > 0
        case .done: false
        }
    }

    func next() async {
        error = nil
        switch step {
        case .snapshot:
            step = .paths
        case .paths:
            step = .preview
            await buildPlan()
        case .preview:
            await apply()
        case .done:
            break
        }
    }

    func back() {
        error = nil
        runningBlockers = []
        if let previous = Step(rawValue: step.rawValue - 1), step != .done { step = previous }
    }

    // MARK: - Snapshot

    func loadManifest() async {
        guard let selectedID else { return }
        isLoadingManifest = true
        defer { isLoadingManifest = false }
        do {
            let manifest = try await engine.manifest(id: selectedID)
            guard selectedID == self.selectedID else { return }
            self.manifest = manifest
            let home = home
            projects = await Task.detached { RestoreAnalysis.projects(in: manifest, targetHome: home) }.value
            overrides = [:]
            for project in projects where !project.existsAtDefault {
                if let suggestion = project.suggestions.first { overrides[project.sourcePath] = suggestion }
            }
            plans = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Paths

    func target(for project: ProjectMapping) -> String {
        overrides[project.sourcePath] ?? project.defaultTarget
    }

    func setTarget(_ path: String, for project: ProjectMapping) {
        overrides[project.sourcePath] = path == project.defaultTarget ? nil : path
        plans = nil
    }

    var rules: [PathMapper.Rule] {
        overrides.map { PathMapper.Rule(from: $0.key, to: $0.value) }
    }

    var missingProjects: [ProjectMapping] { projects.filter { !$0.existsAtDefault } }

    // MARK: - Preview

    func buildPlan() async {
        guard let manifest else { return }
        isPlanning = true
        defer { isPlanning = false }
        do {
            plans = try await engine.planRestore(manifest: manifest, targetHome: home, extraRules: rules, policy: policy)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func setPolicy(_ policy: ConflictPolicy) async {
        guard policy != self.policy else { return }
        self.policy = policy
        await buildPlan()
    }

    var writes: [PlannedWrite] { plans?.flatMap(\.writes) ?? [] }
    /// The wizard checks for running agents itself, so that note is left out.
    var notes: [RestoreNote] {
        (plans?.flatMap(\.notes) ?? []).filter { if case .quitBeforeApplying = $0 { false } else { true } }
    }
    var writeCount: Int { writes.filter(\.writes).count }

    func writes(_ action: PlannedWrite.Action) -> [PlannedWrite] { writes.filter { $0.action == action } }

    // MARK: - Apply

    func apply() async {
        guard let plans else { return }
        // Only the live home matters: a running agent rewrites its config there, undoing the restore.
        let isLiveHome = home.standardizedFileURL.path == URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        let affected = Set(plans.filter { $0.writes.contains(where: \.writes) }.map(\.agentID))
        runningBlockers = isLiveHome ? RunningAgents.find().filter { affected.contains($0.key) }.keys.sorted() : []
        guard runningBlockers.isEmpty else { return }

        isApplying = true
        defer { isApplying = false }
        let home = home
        do {
            result = try await Task.detached { try BackupEngine.apply(plans, home: home) }.value
            step = .done
            await app?.refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - View

struct RestoreWizardView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var wizard: RestoreWizardModel
    /// False only for `--render-wizard`: ImageRenderer can't draw ScrollView contents.
    var scrollable = true

    var body: some View {
        VStack(spacing: 0) {
            StepIndicator(current: wizard.step)
                .padding(.vertical, 16)
            Divider()
            if scrollable {
                ScrollView { content }
            } else {
                content
            }
            if let error = wizard.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).padding(.horizontal, 24).padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer.padding(16)
        }
        .frame(width: 820, height: scrollable ? 620 : nil)
    }

    private var content: some View {
        Group {
            switch wizard.step {
            case .snapshot: SnapshotStep(wizard: wizard)
            case .paths: PathsStep(wizard: wizard)
            case .preview: PreviewStep(wizard: wizard)
            case .done: DoneStep(wizard: wizard)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack {
            if wizard.step != .done {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Spacer()
            if wizard.step != .snapshot && wizard.step != .done {
                Button("上一步") { wizard.back() }.disabled(wizard.isApplying)
            }
            if wizard.step == .done {
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            } else {
                Button {
                    Task { await wizard.next() }
                } label: {
                    if wizard.isApplying { ProgressView().controlSize(.small) }
                    else { Text(wizard.step == .preview ? "開始還原（\(wizard.writeCount) 個檔案）" : "下一步") }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!wizard.canGoNext)
            }
        }
    }
}

private struct StepIndicator: View {
    let current: RestoreWizardModel.Step

    var body: some View {
        HStack(spacing: 8) {
            ForEach(RestoreWizardModel.Step.allCases, id: \.self) { step in
                if step != .snapshot {
                    Rectangle().fill(step.rawValue <= current.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 40, height: 2)
                }
                HStack(spacing: 6) {
                    ZStack {
                        Circle().fill(step.rawValue <= current.rawValue ? Color.accentColor : Color.secondary.opacity(0.25))
                        if step.rawValue < current.rawValue {
                            Image(systemName: "checkmark").font(.caption2.weight(.bold)).foregroundStyle(.white)
                        } else {
                            Text("\(step.rawValue + 1)").font(.caption.weight(.semibold))
                                .foregroundStyle(step == current ? .white : .secondary)
                        }
                    }
                    .frame(width: 22, height: 22)
                    Text(step.title)
                        .font(.callout.weight(step == current ? .semibold : .regular))
                        .foregroundStyle(step == current ? .primary : .secondary)
                }
            }
        }
    }
}

// MARK: Step 1

private struct SnapshotStep: View {
    @Bindable var wizard: RestoreWizardModel

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("要還原哪一份？").font(.headline)
                Card(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(wizard.snapshots.enumerated()), id: \.element.id) { index, snapshot in
                            if index > 0 { Divider() }
                            Button { wizard.selectedID = snapshot.id } label: {
                                HStack {
                                    Image(systemName: wizard.selectedID == snapshot.id ? "largecircle.fill.circle" : "circle")
                                        .foregroundStyle(wizard.selectedID == snapshot.id ? Color.accentColor : .secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(Format.dateTime(snapshot.date)).fontWeight(.medium)
                                        Text("\(snapshot.hostname) · \(Format.relative(snapshot.date))")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                                .padding(.horizontal, 12).padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(width: 280)

            VStack(alignment: .leading, spacing: 8) {
                Text("內容").font(.headline)
                Card {
                    if wizard.isLoadingManifest {
                        HStack { ProgressView().controlSize(.small); Text("下載並解密快照清單…").foregroundStyle(.secondary) }
                    } else if let manifest = wizard.manifest {
                        ManifestSummary(manifest: manifest)
                    }
                }
            }
        }
    }
}

private struct ManifestSummary: View {
    let manifest: Manifest

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow { Text("來源").foregroundStyle(.secondary); Text(manifest.source.hostname) }
                GridRow { Text("家目錄").foregroundStyle(.secondary); Text(manifest.source.home).font(.callout.monospaced()) }
                GridRow { Text("大小").foregroundStyle(.secondary); Text(Format.bytes(manifest.totalSize)) }
            }
            ForEach(manifest.agents, id: \.agentID) { agent in
                Divider()
                Text(agent.agentID == "claude-code" ? "Claude Code" : agent.agentID).font(.subheadline.weight(.semibold))
                let counts = Dictionary(grouping: agent.items, by: \.kind)
                ForEach(ItemKind.allCases.filter { counts[$0] != nil }, id: \.self) { kind in
                    HStack {
                        Label(kind.chineseLabel, systemImage: kind.symbol)
                        Spacer()
                        Text("\(counts[kind]!.count) 個 · \(Format.bytes(counts[kind]!.reduce(0) { $0 + $1.size }))")
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                    .font(.callout)
                }
            }
        }
    }
}

// MARK: Step 2

private struct PathsStep: View {
    @Bindable var wizard: RestoreWizardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let manifest = wizard.manifest {
                Card {
                    HStack(spacing: 10) {
                        Image(systemName: "house").foregroundStyle(.secondary)
                        Text(manifest.source.home).font(.callout.monospaced())
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Text(wizard.home.path).font(.callout.monospaced())
                        Spacer()
                    }
                }
                Text("聊天記錄裡的路徑會一起改寫，Claude Code 才找得到原本的專案。").font(.callout).foregroundStyle(.secondary)
            }

            if wizard.missingProjects.isEmpty {
                Card {
                    Label("備份裡的 \(wizard.projects.count) 個專案路徑在這台 Mac 上都找得到。", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            } else {
                SectionHeader(title: "這台 Mac 上找不到的專案", trailing: "\(wizard.missingProjects.count) 個")
                Card(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(wizard.missingProjects.enumerated()), id: \.element.id) { index, project in
                            if index > 0 { Divider() }
                            ProjectRow(wizard: wizard, project: project)
                        }
                    }
                }
                Text("找不到也沒關係：保留原路徑時，聊天記錄仍會還原，之後把專案放到該路徑就能接續。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            let found = wizard.projects.filter(\.existsAtDefault)
            if !found.isEmpty && !wizard.missingProjects.isEmpty {
                DisclosureGroup("已找到的專案（\(found.count)）") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(found) { project in
                            Text((project.defaultTarget as NSString).abbreviatingWithTildeInPath)
                                .font(.callout.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                }
            }
        }
    }
}

private struct ProjectRow: View {
    @Bindable var wizard: RestoreWizardModel
    let project: ProjectMapping

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name).fontWeight(.medium)
                Text("原本：\(project.sourcePath) · \(project.fileCount) 個檔案")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Menu {
                Button("保留原路徑：\(abbreviate(project.defaultTarget))") { wizard.setTarget(project.defaultTarget, for: project) }
                if !project.suggestions.isEmpty {
                    Section("在這台 Mac 找到") {
                        ForEach(project.suggestions, id: \.self) { path in
                            Button(abbreviate(path)) { wizard.setTarget(path, for: project) }
                        }
                    }
                }
                Divider()
                Button("選擇資料夾…") { choose() }
            } label: {
                Text(abbreviate(wizard.target(for: project))).lineLimit(1).truncationMode(.head)
            }
            .frame(width: 300)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func abbreviate(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = wizard.home
        panel.message = "「\(project.name)」在這台 Mac 的位置"
        if panel.runModal() == .OK, let url = panel.url { wizard.setTarget(url.path, for: project) }
    }
}

// MARK: Step 3

private struct PreviewStep: View {
    @Bindable var wizard: RestoreWizardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("兩邊都改過的檔案或 MCP server：")
                Picker("", selection: Binding(get: { wizard.policy }, set: { policy in Task { await wizard.setPolicy(policy) } })) {
                    Text("保留這台 Mac 的").tag(ConflictPolicy.keep)
                    Text("用備份覆蓋").tag(ConflictPolicy.replace)
                    Text("兩份都留").tag(ConflictPolicy.rename)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 360)
                .disabled(wizard.isPlanning)
            }

            if wizard.isPlanning {
                Card {
                    HStack { ProgressView().controlSize(.small); Text("下載備份並比對這台 Mac 的檔案…").foregroundStyle(.secondary) }
                }
            } else if wizard.plans != nil {
                HStack(spacing: 12) {
                    count("新增", .create, "plus.circle", .green)
                    count("更新", .update, "arrow.triangle.2.circlepath", .blue)
                    count("衝突（保留本機）", .conflictKept, "exclamationmark.triangle", .orange)
                    count("不變", .unchanged, "equal.circle", .secondary)
                }
                if !wizard.runningBlockers.isEmpty {
                    Card {
                        HStack {
                            Label("請先關閉正在執行的 \(wizard.runningBlockers.joined(separator: "、"))，否則它會覆寫還原的設定。",
                                  systemImage: "exclamationmark.octagon.fill")
                                .foregroundStyle(.red)
                            Spacer()
                            Button("重新檢查") { Task { await wizard.apply() } }
                        }
                    }
                }
                fileList("會新增", .create)
                fileList("會更新", .update)
                fileList("兩邊不同、保留這台 Mac 的", .conflictKept)
                if !wizard.notes.isEmpty {
                    SectionHeader(title: "注意事項")
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(wizard.notes, id: \.self) { note in NoteRow(note: note) }
                        }
                    }
                }
                Text("還原前會保留復原點；不滿意可以在「備份紀錄 › 最近的還原」一鍵退回。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func count(_ title: String, _ action: PlannedWrite.Action, _ symbol: String, _ tint: Color) -> some View {
        StatCard(title: title, symbol: symbol, value: "\(wizard.writes(action).count)", detail: "", tint: tint)
    }

    @ViewBuilder private func fileList(_ title: String, _ action: PlannedWrite.Action) -> some View {
        let writes = wizard.writes(action)
        if !writes.isEmpty {
            DisclosureGroup("\(title)（\(writes.count)）") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(writes.enumerated()), id: \.offset) { _, write in
                        HStack(spacing: 6) {
                            Image(systemName: write.kind.symbol).foregroundStyle(.secondary).frame(width: 18)
                            Text((write.target.path as NSString).abbreviatingWithTildeInPath)
                                .font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                            if let detail = write.detail {
                                Text("— \(detail)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
            }
        }
    }
}

// MARK: Step 4

private struct DoneStep: View {
    let wizard: RestoreWizardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 4) {
                    Text("還原完成").font(.title.weight(.semibold))
                    Text("寫入 \(wizard.result?.written ?? 0) 個檔案。").foregroundStyle(.secondary)
                }
            }
            SectionHeader(title: "接下來")
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(wizard.notes, id: \.self) { note in NoteRow(note: note) }
                }
            }
            Text("不滿意的話，到「備份紀錄 › 最近的還原」可以一鍵退回還原前的狀態。")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

private struct NoteRow: View {
    let note: RestoreNote

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(text).font(.callout)
                if let command = note.command {
                    Text(command)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                }
            }
        }
    }

    private var symbol: String {
        switch note {
        case .mcpConflictKept: "exclamationmark.triangle"
        case .readdMarketplace, .reinstallPlugin: "puzzlepiece.extension"
        case .logInAfterRestore: "person.badge.key"
        case .quitBeforeApplying: "xmark.octagon"
        case .unsupportedAgent: "questionmark.circle"
        }
    }

    private var text: String {
        switch note {
        case .mcpConflictKept(let server, let scope): "MCP server「\(server)」（\(scope.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "全域")）兩邊設定不同，保留這台 Mac 的"
        case .readdMarketplace: "重新加入 plugin marketplace"
        case .reinstallPlugin(let name): "重新安裝 plugin：\(name.split(separator: "@").first.map(String.init) ?? name)"
        case .quitBeforeApplying(let agent): "還原前請先關閉 \(agent)"
        case .logInAfterRestore(let agent, _): "開啟 \(agent) 並重新登入（登入資訊不會備份）"
        case .unsupportedAgent(let id): "這個版本還不能還原「\(id)」，已略過"
        }
    }
}
