import SwiftUI

struct ContentView: View {
    @StateObject private var organizer = FileOrganizer()
    @State private var showingPreview = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "folder.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.blue)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Downloads Organizer")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("ダウンロードフォルダを自動整理")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
            }
            .padding()
            .background(.ultraThinMaterial)
            
            Divider()
            
            // Main content
            VStack(spacing: 16) {
                // Target folder
                GroupBox {
                    HStack {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        Text(organizer.downloadsPath)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                    }
                } label: {
                    Label("対象フォルダ", systemImage: "folder.badge.gearshape")
                }
                
                // Preview
                if !organizer.pendingMoves.isEmpty || showingPreview {
                    GroupBox {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4) {
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
                                            
                                            Text(move.fileName)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                            
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
                        .frame(height: 150)
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
                
                // Status message
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
                
                // Buttons
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
                        organizer.organize()
                    } label: {
                        Label("整理実行", systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(organizer.pendingMoves.isEmpty)
                }
            }
            .padding()
        }
        .frame(width: 500, height: 450)
        .background(.background)
    }
    
    func iconForCategory(_ category: String) -> String {
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
    
    func colorForCategory(_ category: String) -> Color {
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

#Preview {
    ContentView()
}
