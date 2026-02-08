import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var organizer: FileOrganizer
    @State private var showingPreview = false
    @State private var newExclusionPattern = ""
    @State private var newRuleCategory = ""
    @State private var newRuleExtension = ""
    @State private var newExtensionInputs: [String: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "folder.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Downloads Organizer")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("複数フォルダを自動整理")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding()
            .background(.ultraThinMaterial)

            Divider()

            VStack(spacing: 14) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(organizer.targetFolders, id: \.self) { folder in
                            HStack {
                                Image(systemName: "folder")
                                    .foregroundStyle(.secondary)
                                Text(folder)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Button {
                                    organizer.removeTargetFolder(path: folder)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .disabled(organizer.targetFolders.count <= 1)
                            }
                        }

                        Button {
                            selectFolders()
                        } label: {
                            Label("フォルダを追加", systemImage: "plus")
                        }
                        .buttonStyle(.bordered)
                    }
                } label: {
                    Label("対象フォルダ", systemImage: "folder.badge.plus")
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("フォルダ監視で自動整理", isOn: $organizer.autoOrganizeEnabled)
                        Toggle("月別フォルダで整理 (YYYY-MM)", isOn: $organizer.groupByMonthFolderEnabled)

                        HStack(spacing: 6) {
                            Circle()
                                .fill(organizer.isMonitoringFolder ? Color.green : Color.secondary)
                                .frame(width: 8, height: 8)
                            Text(organizer.isMonitoringFolder ? "監視中" : "監視停止")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("今月: \(organizer.currentMonthMovedCount)件")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("累計: \(organizer.totalMovedCount)件")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } label: {
                    Label("自動整理 / 統計", systemImage: "chart.bar.xaxis")
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            TextField("除外を追加 (.dmg / sample.zip / *.tmp)", text: $newExclusionPattern)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit {
                                    addExclusionPattern()
                                }

                            Button("追加") {
                                addExclusionPattern()
                            }
                            .buttonStyle(.borderedProminent)
                        }

                        if organizer.exclusionPatterns.isEmpty {
                            Text("除外リストは空です")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 6) {
                                    ForEach(organizer.exclusionPatterns, id: \.self) { pattern in
                                        HStack {
                                            Text(pattern)
                                                .font(.system(.body, design: .monospaced))
                                                .lineLimit(1)
                                                .truncationMode(.middle)

                                            Spacer()

                                            Button {
                                                organizer.removeExclusionPattern(pattern)
                                            } label: {
                                                Image(systemName: "minus.circle.fill")
                                                    .foregroundStyle(.secondary)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                            }
                            .frame(height: 76)
                        }
                    }
                } label: {
                    Label("除外リスト", systemImage: "line.3.horizontal.decrease.circle")
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(organizer.sortedRuleCategories, id: \.self) { category in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(category)
                                        .font(.headline)
                                    Spacer()
                                    Button {
                                        organizer.removeRuleCategory(category)
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(organizer.sortedRuleCategories.count <= 1)
                                }

                                if organizer.extensions(for: category).isEmpty {
                                    Text("拡張子なし")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 6)], alignment: .leading, spacing: 6) {
                                        ForEach(organizer.extensions(for: category), id: \.self) { ext in
                                            HStack(spacing: 4) {
                                                Text(ext)
                                                    .font(.caption)
                                                Button {
                                                    organizer.removeRuleExtension(ext, from: category)
                                                } label: {
                                                    Image(systemName: "xmark.circle.fill")
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                }
                                                .buttonStyle(.plain)
                                            }
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 4)
                                            .background(Color.secondary.opacity(0.15))
                                            .clipShape(Capsule())
                                        }
                                    }
                                }

                                HStack(spacing: 8) {
                                    TextField("拡張子 (.pdf)", text: extensionInputBinding(for: category))
                                        .textFieldStyle(.roundedBorder)
                                    Button("追加") {
                                        addExtension(to: category)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }

                        Divider()

                        HStack(spacing: 8) {
                            TextField("新カテゴリ", text: $newRuleCategory)
                                .textFieldStyle(.roundedBorder)
                            TextField("最初の拡張子 (.abc)", text: $newRuleExtension)
                                .textFieldStyle(.roundedBorder)
                            Button("カテゴリ追加") {
                                if organizer.addRuleCategory(name: newRuleCategory, firstExtension: newRuleExtension) {
                                    newRuleCategory = ""
                                    newRuleExtension = ""
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                } label: {
                    Label("ルール編集", systemImage: "slider.horizontal.3")
                }

                if !organizer.pendingMoves.isEmpty || showingPreview {
                    GroupBox {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 5) {
                                if organizer.pendingMoves.isEmpty {
                                    Text("整理するファイルがありません")
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .center)
                                        .padding()
                                } else {
                                    ForEach(organizer.pendingMoves, id: \.source) { move in
                                        HStack {
                                            Image(systemName: iconForCategory(move.category))
                                                .foregroundStyle(colorForCategory(move.category))
                                                .frame(width: 20)

                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(move.fileName)
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                                Text(move.sourceFolderName)
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }

                                            Image(systemName: "arrow.right")
                                                .foregroundStyle(.secondary)
                                                .font(.caption)

                                            Text(move.category)
                                                .font(.caption)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 2)
                                                .background(colorForCategory(move.category).opacity(0.2))
                                                .clipShape(Capsule())
                                        }
                                        .font(.system(.body, design: .monospaced))
                                    }
                                }
                            }
                            .padding(8)
                        }
                        .frame(height: 170)
                    } label: {
                        HStack {
                            Label("プレビュー", systemImage: "eye")
                            Spacer()
                            if !organizer.pendingMoves.isEmpty {
                                Text("\(organizer.pendingMoves.count)件")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if let message = organizer.statusMessage {
                    HStack {
                        Image(systemName: organizer.isError ? "exclamationmark.triangle" : "checkmark.circle")
                            .foregroundStyle(organizer.isError ? .red : .green)
                        Text(message)
                            .font(.callout)
                    }
                    .padding(.horizontal)
                }

                Spacer()

                HStack(spacing: 12) {
                    Button {
                        organizer.preview()
                        showingPreview = true
                    } label: {
                        Label("プレビュー", systemImage: "magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    Button {
                        organizer.undo()
                    } label: {
                        Label("元に戻す", systemImage: "arrow.uturn.backward")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(!organizer.canUndo)

                    Button {
                        organizer.quickOrganize()
                        showingPreview = true
                    } label: {
                        Label("整理実行", systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding()
        }
        .frame(width: 660, height: 860)
        .background(.background)
    }

    private func addExclusionPattern() {
        if organizer.addExclusionPattern(newExclusionPattern) {
            newExclusionPattern = ""
        }
    }

    private func extensionInputBinding(for category: String) -> Binding<String> {
        Binding(
            get: {
                newExtensionInputs[category] ?? ""
            },
            set: { newValue in
                newExtensionInputs[category] = newValue
            }
        )
    }

    private func addExtension(to category: String) {
        let raw = newExtensionInputs[category] ?? ""
        if organizer.addRuleExtension(raw, to: category) {
            newExtensionInputs[category] = ""
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
        }
    }

    private func iconForCategory(_ category: String) -> String {
        switch category {
        case "Documents": return "doc.text"
        case "Text": return "doc.plaintext"
        case "Images": return "photo"
        case "Videos": return "film"
        case "Audio": return "music.note"
        case "Archives": return "doc.zipper"
        case "Installers": return "app.badge.checkmark"
        case "Spreadsheets": return "tablecells"
        case "Presentations": return "play.rectangle"
        default: return "doc"
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

struct MenuBarContentView: View {
    @EnvironmentObject private var organizer: FileOrganizer
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("設定を開く") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }

            Button("プレビュー更新") {
                organizer.preview()
            }

            Button("整理実行") {
                organizer.quickOrganize()
            }

            Toggle("自動整理", isOn: $organizer.autoOrganizeEnabled)
            Toggle("月別フォルダ", isOn: $organizer.groupByMonthFolderEnabled)

            Text("対象フォルダ: \(organizer.targetFolders.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("今月: \(organizer.currentMonthMovedCount)件 / 累計: \(organizer.totalMovedCount)件")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let message = organizer.statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(organizer.isError ? .red : .secondary)
                    .lineLimit(2)
            }

            Divider()

            Button("終了") {
                NSApp.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 300)
    }
}

#Preview {
    ContentView()
        .environmentObject(FileOrganizer())
}
