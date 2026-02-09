import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var organizer: FileOrganizer
    @StateObject private var updateChecker = UpdateChecker()
    @State private var selectedTab = 0
    
    var body: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                Section("メイン") {
                    Label("整理", systemImage: "folder.badge.gearshape")
                        .tag(0)
                    Label("プレビュー", systemImage: "eye")
                        .tag(1)
                }
                
                Section("設定") {
                    Label("フォルダ", systemImage: "folder.badge.plus")
                        .tag(2)
                    Label("ルール", systemImage: "list.bullet.rectangle")
                        .tag(3)
                    Label("除外", systemImage: "xmark.circle")
                        .tag(4)
                }
                
                Section("情報") {
                    Label("統計", systemImage: "chart.bar.xaxis")
                        .tag(5)
                    Label("アップデート", systemImage: "arrow.down.circle")
                        .tag(6)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 250)
        } detail: {
            Group {
                switch selectedTab {
                case 0:
                    OrganizeView {
                        selectedTab = 2
                    }
                case 1: PreviewView()
                case 2: FoldersView()
                case 3: RulesView()
                case 4: ExclusionsView()
                case 5: StatsView()
                case 6: UpdateView(checker: updateChecker)
                default:
                    OrganizeView {
                        selectedTab = 2
                    }
                }
            }
            .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Folder Tidy")
        .frame(minWidth: 700, minHeight: 500)
        .onAppear {
            organizer.preview()
            updateChecker.checkForUpdates()
        }
        .onChange(of: selectedTab) { newValue in
            if newValue == 6 {
                updateChecker.acknowledgeUpdateBadge()
            }
        }
        .overlay(alignment: .topTrailing) {
            if updateChecker.shouldShowUpdateBadge {
                Button {
                    updateChecker.acknowledgeUpdateBadge()
                    selectedTab = 6
                } label: {
                    Label("アップデートあり", systemImage: "arrow.down.circle.fill")
                        .font(.caption)
                        .padding(8)
                        .background(.blue)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding()
            }
        }
    }
}

// MARK: - 整理ビュー
struct OrganizeView: View {
    @EnvironmentObject private var organizer: FileOrganizer
    let onOpenFolders: () -> Void
    
    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Image(systemName: "folder.badge.gearshape")
                    .font(.system(size: 64))
                    .foregroundStyle(.blue.gradient)
                
                Text("Folder Tidy")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                Text("ファイルを自動で整理")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 40)
            
            // 警告: フォルダ未設定
            if organizer.targetFolders.isEmpty {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("整理対象のフォルダが設定されていません")
                    Button("フォルダを追加") {
                        onOpenFolders()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .background(.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal)
            }
            
            HStack(spacing: 16) {
                StatusCard(icon: "folder", title: "対象フォルダ", value: "\(organizer.targetFolders.count)", color: .blue)
                StatusCard(icon: "doc", title: "整理対象", value: "\(organizer.pendingMoves.count)件", color: .orange)
                StatusCard(icon: "checkmark.circle", title: "今月整理済み", value: "\(organizer.currentMonthMovedCount)件", color: .green)
            }
            .padding(.horizontal)
            
            HStack(spacing: 16) {
                Button { organizer.preview() } label: {
                    Label("プレビュー", systemImage: "eye")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                
                Button { organizer.undo() } label: {
                    Label("元に戻す", systemImage: "arrow.uturn.backward")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(!organizer.canUndo)
                
                Button { organizer.quickOrganize() } label: {
                    Label("整理実行", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(organizer.targetFolders.isEmpty)
            }
            .padding(.horizontal)
            
            GroupBox {
                VStack(spacing: 12) {
                    Toggle("フォルダ監視で自動整理", isOn: $organizer.autoOrganizeEnabled)
                        .disabled(organizer.targetFolders.isEmpty)
                    Toggle("月別フォルダで整理 (YYYY-MM)", isOn: $organizer.groupByMonthFolderEnabled)
                    
                    HStack {
                        Circle()
                            .fill(organizer.isMonitoringFolder ? Color.green : Color.gray)
                            .frame(width: 8, height: 8)
                        Text(organizer.isMonitoringFolder ? "監視中" : "監視停止")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                .padding(4)
            } label: {
                Label("オプション", systemImage: "gearshape")
            }
            .padding(.horizontal)
            
            if let message = organizer.statusMessage {
                HStack {
                    Image(systemName: organizer.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(organizer.isError ? .red : .green)
                    Text(message)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(organizer.isError ? Color.red.opacity(0.1) : Color.green.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal)
            }
            
            Spacer()
        }
        .padding()
    }
}

struct StatusCard: View {
    let icon: String
    let title: String
    let value: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title)
                .foregroundStyle(color)
            Text(value)
                .font(.title2)
                .fontWeight(.semibold)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - プレビュービュー
struct PreviewView: View {
    @EnvironmentObject private var organizer: FileOrganizer
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("整理プレビュー")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button { organizer.preview() } label: {
                    Label("更新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal)
            .padding(.top)
            
            if organizer.pendingMoves.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("整理するファイルがありません")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List {
                    ForEach(organizer.pendingMoves, id: \.source) { move in
                        HStack {
                            Image(systemName: iconForCategory(move.category))
                                .foregroundStyle(colorForCategory(move.category))
                                .frame(width: 24)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(move.fileName).fontWeight(.medium)
                                Text(move.sourceFolderName).font(.caption).foregroundStyle(.secondary)
                            }
                            
                            Spacer()
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            
                            Text(move.category)
                                .font(.callout)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(colorForCategory(move.category).opacity(0.15))
                                .clipShape(Capsule())
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.inset)
            }
        }
    }
    
    private func iconForCategory(_ category: String) -> String {
        switch category {
        case "Documents": return "doc.text.fill"
        case "Text": return "doc.plaintext.fill"
        case "Images": return "photo.fill"
        case "Videos": return "film.fill"
        case "Audio": return "music.note"
        case "Archives": return "doc.zipper"
        case "Installers": return "app.badge.checkmark.fill"
        case "Spreadsheets": return "tablecells.fill"
        case "Presentations": return "play.rectangle.fill"
        default: return "doc.fill"
        }
    }
    
    private func colorForCategory(_ category: String) -> Color {
        switch category {
        case "Documents": return .red
        case "Text": return .orange
        case "Images": return .green
        case "Videos": return .purple
        case "Audio": return .pink
        case "Archives": return .yellow
        case "Installers": return .blue
        case "Spreadsheets": return .teal
        case "Presentations": return .indigo
        default: return .gray
        }
    }
}

// MARK: - フォルダ設定ビュー
struct FoldersView: View {
    @EnvironmentObject private var organizer: FileOrganizer
    @State private var selectedFolder: String?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("対象フォルダ")
                .font(.title2)
                .fontWeight(.semibold)
                .padding(.horizontal)
                .padding(.top)
            
            Text("整理したいフォルダを追加してください。デフォルトはダウンロードフォルダです。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            if organizer.autoOrganizeEnabled {
                Text("監視中: \(organizer.monitoredFolderPaths.count)/\(organizer.targetFolders.count) フォルダ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
            
            if organizer.targetFolders.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 48))
                        .foregroundStyle(.orange)
                    Text("フォルダが設定されていません")
                        .foregroundStyle(.secondary)
                    Text("「フォルダを追加」をクリックして整理対象を選択してください")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding()
            } else {
                List(selection: $selectedFolder) {
                    ForEach(organizer.targetFolders, id: \.self) { folder in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(.blue)
                                .padding(.top, 2)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(folderName(from: folder))
                                    .font(.headline)
                                Text(folder)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer(minLength: 8)

                            VStack(alignment: .trailing, spacing: 6) {
                                Text(monitorState(for: folder))
                                    .font(.caption2)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(monitorStateColor(for: folder).opacity(0.15))
                                    .foregroundStyle(monitorStateColor(for: folder))
                                    .clipShape(Capsule())

                                Button(role: .destructive) {
                                    removeFolder(folder)
                                } label: {
                                    Label("削除", systemImage: "trash")
                                }
                                .buttonStyle(.borderless)
                                .font(.caption)
                            }
                        }
                        .padding(.vertical, 4)
                        .tag(folder)
                    }
                }
                .listStyle(.inset)
            }
            
            HStack {
                Button { selectFolders() } label: {
                    Label("フォルダを追加", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button(role: .destructive) {
                    removeSelectedFolder()
                } label: {
                    Label("選択を削除", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(selectedFolder == nil)
                
                if !organizer.targetFolders.isEmpty {
                    Button { addDownloadsFolder() } label: {
                        Label("ダウンロード追加", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
            .padding()
        }
    }
    
    private func selectFolders() {
        let panel = NSOpenPanel()
        panel.title = "整理対象フォルダを選択"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        
        if panel.runModal() == .OK {
            for url in panel.urls {
                _ = organizer.addTargetFolder(path: url.path)
            }
            selectedFolder = panel.urls.last?.path
            organizer.preview()
        }
    }
    
    private func addDownloadsFolder() {
        let downloadsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads").path
        _ = organizer.addTargetFolder(path: downloadsPath)
        selectedFolder = downloadsPath
        organizer.preview()
    }

    private func removeSelectedFolder() {
        guard let selectedFolder else { return }
        removeFolder(selectedFolder)
    }

    private func removeFolder(_ folder: String) {
        organizer.removeTargetFolder(path: folder)
        if selectedFolder == folder {
            selectedFolder = nil
        }
        organizer.preview()
    }

    private func folderName(from path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    private func monitorState(for folder: String) -> String {
        if !organizer.autoOrganizeEnabled {
            return "手動整理"
        }
        return organizer.isFolderMonitored(path: folder) ? "監視中" : "未監視"
    }

    private func monitorStateColor(for folder: String) -> Color {
        if !organizer.autoOrganizeEnabled {
            return .secondary
        }
        return organizer.isFolderMonitored(path: folder) ? .green : .orange
    }
}

// MARK: - ルール設定ビュー
struct RulesView: View {
    @EnvironmentObject private var organizer: FileOrganizer
    @State private var newCategory = ""
    @State private var newExtension = ""
    @State private var extensionInputs: [String: String] = [:]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("分類ルール")
                .font(.title2)
                .fontWeight(.semibold)
                .padding(.horizontal)
                .padding(.top)
            
            List {
                ForEach(organizer.sortedRuleCategories, id: \.self) { category in
                    DisclosureGroup {
                        HStack {
                            Text("拡張子 \(organizer.extensions(for: category).count) 件")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(role: .destructive) {
                                organizer.removeRuleCategory(category)
                                organizer.preview()
                            } label: {
                                Label("カテゴリ削除", systemImage: "trash")
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .disabled(organizer.sortedRuleCategories.count <= 1)
                        }

                        ForEach(organizer.extensions(for: category), id: \.self) { ext in
                            HStack {
                                Text(ext).font(.system(.body, design: .monospaced))
                                Spacer()
                                Button {
                                    organizer.removeRuleExtension(ext, from: category)
                                    organizer.preview()
                                } label: {
                                    Image(systemName: "minus.circle").foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        HStack {
                            TextField("拡張子を追加", text: extensionBinding(for: category))
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { addExtension(to: category) }
                            Button("追加") { addExtension(to: category) }
                                .buttonStyle(.bordered)
                        }
                        .padding(.top, 4)
                    } label: {
                        Label(category, systemImage: "folder")
                    }
                }
                
                Section {
                    HStack {
                        TextField("新しいカテゴリ", text: $newCategory)
                            .textFieldStyle(.roundedBorder)
                        TextField("拡張子", text: $newExtension)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                        Button("追加") {
                            if organizer.addRuleCategory(name: newCategory, firstExtension: newExtension) {
                                newCategory = ""
                                newExtension = ""
                                organizer.preview()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } header: {
                    Text("カテゴリを追加")
                }
            }
            .listStyle(.inset)
        }
    }
    
    private func extensionBinding(for category: String) -> Binding<String> {
        Binding(get: { extensionInputs[category] ?? "" }, set: { extensionInputs[category] = $0 })
    }
    
    private func addExtension(to category: String) {
        let ext = extensionInputs[category] ?? ""
        if organizer.addRuleExtension(ext, to: category) {
            extensionInputs[category] = ""
            organizer.preview()
        }
    }
}

// MARK: - 除外設定ビュー
struct ExclusionsView: View {
    @EnvironmentObject private var organizer: FileOrganizer
    @State private var newPattern = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("除外リスト")
                .font(.title2)
                .fontWeight(.semibold)
                .padding(.horizontal)
                .padding(.top)
            
            Text("拡張子 (.dmg)、ファイル名 (sample.zip)、ワイルドカード (*.tmp) で指定")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            
            List {
                ForEach(organizer.exclusionPatterns, id: \.self) { pattern in
                    HStack {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                        Text(pattern).font(.system(.body, design: .monospaced))
                        Spacer()
                        Button {
                            organizer.removeExclusionPattern(pattern)
                            organizer.preview()
                        } label: {
                            Image(systemName: "trash").foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
                
                if organizer.exclusionPatterns.isEmpty {
                    Text("除外リストは空です").foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)
            
            HStack {
                TextField("除外パターンを追加", text: $newPattern)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addPattern() }
                Button("追加") { addPattern() }
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        }
    }
    
    private func addPattern() {
        if organizer.addExclusionPattern(newPattern) {
            newPattern = ""
            organizer.preview()
        }
    }
}

// MARK: - 統計ビュー
struct StatsView: View {
    @EnvironmentObject private var organizer: FileOrganizer
    
    var body: some View {
        VStack(spacing: 24) {
            Text("統計情報")
                .font(.title2)
                .fontWeight(.semibold)
                .padding(.top)
            
            HStack(spacing: 24) {
                StatCard(icon: "calendar", title: "今月", value: "\(organizer.currentMonthMovedCount)", subtitle: "件整理", color: .blue)
                StatCard(icon: "sum", title: "累計", value: "\(organizer.totalMovedCount)", subtitle: "件整理", color: .green)
                StatCard(icon: "folder", title: "監視フォルダ", value: "\(organizer.targetFolders.count)", subtitle: "フォルダ", color: .orange)
            }
            .padding(.horizontal)
            
            Spacer()
        }
        .padding()
    }
}

struct StatCard: View {
    let icon: String
    let title: String
    let value: String
    let subtitle: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 32)).foregroundStyle(color)
            Text(value).font(.system(size: 36, weight: .bold))
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
            Text(title).font(.callout).fontWeight(.medium)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - アップデートビュー
struct UpdateView: View {
    @ObservedObject var checker: UpdateChecker

    private var phaseLabel: String {
        switch checker.phase {
        case .idle:
            return ""
        case .checking:
            return "更新を確認しています"
        case .downloading:
            return "更新ファイルをダウンロードしています"
        case .extracting:
            return "ZIPファイルを展開しています"
        case .ready:
            return "更新準備が完了しました"
        case .failed:
            return "更新処理に失敗しました"
        }
    }

    var body: some View {
        VStack(spacing: 24) {
            Text("アップデート")
                .font(.title2)
                .fontWeight(.semibold)
                .padding(.top)

            VStack(spacing: 16) {
                Image(systemName: checker.updateAvailable ? "arrow.down.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(checker.updateAvailable ? .blue : .green)

                Text("現在のバージョン: \(UpdateChecker.currentVersion)")
                    .font(.headline)

                if let latest = checker.latestVersion {
                    Text("公開中の最新バージョン: \(latest)")
                        .font(.subheadline)
                        .foregroundStyle(checker.updateAvailable ? .blue : .secondary)
                }

                if checker.updateAvailable {
                    if checker.downloadURL != nil {
                        Button {
                            checker.downloadAndInstallUpdate()
                        } label: {
                            Label(
                                checker.isDownloading || checker.phase == .extracting ? "更新を準備中..." : "今すぐ更新",
                                systemImage: "arrow.down.circle"
                            )
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(checker.isChecking || checker.isDownloading)
                    } else {
                        Text("このリリースはアプリ内更新に未対応です。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 12) {
                        Button {
                            checker.openReleasePage()
                        } label: {
                            Label("リリースページ", systemImage: "safari")
                        }
                        .buttonStyle(.bordered)

                        Button {
                            checker.checkForUpdates()
                        } label: {
                            Label("再確認", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .disabled(checker.isChecking || checker.isDownloading)
                    }
                } else {
                    Button {
                        checker.checkForUpdates()
                    } label: {
                        Label("アップデートを確認", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(checker.isChecking || checker.isDownloading)
                }

                if checker.isChecking || checker.isDownloading || checker.phase == .extracting {
                    ProgressView()
                        .padding(.top, 2)
                    Text(phaseLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if checker.updateAvailable, let notes = checker.releaseNotesPreview {
                    GroupBox("リリースノート（抜粋）") {
                        ScrollView {
                            Text(notes)
                                .font(.callout)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 140)
                    }
                    .padding(.top, 2)
                }

                if let status = checker.statusMessage {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }

                if let lastCheckedAt = checker.lastCheckedAt {
                    Text("最終確認: \(lastCheckedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()

            Spacer()
        }
        .padding()
    }
}
// MARK: - メニューバー
struct MenuBarContentView: View {
    @EnvironmentObject private var organizer: FileOrganizer
    @Environment(\.openWindow) private var openWindow
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) } label: {
                Label("設定を開く", systemImage: "gearshape")
            }
            .buttonStyle(.plain)
            
            Divider()
            
            Button { organizer.preview() } label: { Label("プレビュー", systemImage: "eye") }.buttonStyle(.plain)
            Button { organizer.quickOrganize() } label: { Label("整理実行", systemImage: "sparkles") }.buttonStyle(.plain)
            
            Divider()
            
            Toggle("自動整理", isOn: $organizer.autoOrganizeEnabled)
            Toggle("月別フォルダ", isOn: $organizer.groupByMonthFolderEnabled)
            
            Divider()
            
            HStack { Text("今月").foregroundStyle(.secondary); Spacer(); Text("\(organizer.currentMonthMovedCount)件") }.font(.caption)
            HStack { Text("累計").foregroundStyle(.secondary); Spacer(); Text("\(organizer.totalMovedCount)件") }.font(.caption)
            
            if let msg = organizer.statusMessage {
                Text(msg).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            
            Divider()
            
            Button { NSApp.terminate(nil) } label: { Label("終了", systemImage: "power") }.buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: 240)
    }
}

#Preview {
    ContentView().environmentObject(FileOrganizer())
}
