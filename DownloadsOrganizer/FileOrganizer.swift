import Foundation
import SwiftUI

struct FileMove: Equatable {
    let source: String
    let destination: String
    let fileName: String
    let category: String
}

@MainActor
class FileOrganizer: ObservableObject {
    @Published var pendingMoves: [FileMove] = []
    @Published var statusMessage: String?
    @Published var isError: Bool = false
    @Published var canUndo: Bool = false
    
    let downloadsPath: String
    private let historyURL: URL
    
    // カテゴリルール
    var rules: [String: [String]] = [
        "Documents": [".pdf", ".doc", ".docx", ".rtf"],
        "Text": [".txt", ".md", ".markdown"],
        "Spreadsheets": [".xls", ".xlsx", ".csv"],
        "Presentations": [".ppt", ".pptx"],
        "Images": [".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic", ".bmp", ".svg"],
        "Videos": [".mp4", ".mov", ".mkv", ".avi", ".wmv", ".webm"],
        "Audio": [".mp3", ".wav", ".m4a", ".aac", ".flac"],
        "Archives": [".zip", ".rar", ".7z", ".tar", ".gz", ".tar.gz", ".tgz"],
        "Installers": [".dmg", ".pkg", ".msi", ".exe"],
    ]
    
    private let ignoreExtensions: Set<String> = [".crdownload", ".part", ".download", ".tmp"]
    
    init() {
        self.downloadsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads").path
        self.historyURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".downloads_organizer_history.json")
        
        checkUndoAvailability()
    }
    
    func preview() {
        pendingMoves = []
        statusMessage = nil
        isError = false
        
        let downloadsURL = URL(fileURLWithPath: downloadsPath)
        
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: downloadsURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            statusMessage = "フォルダを読み取れませんでした"
            isError = true
            return
        }
        
        for fileURL in files {
            guard let isFile = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile,
                  isFile == true else {
                continue
            }
            
            let fileName = fileURL.lastPathComponent
            let ext = getMatchingExtension(fileName: fileName)
            
            guard let ext = ext, !ignoreExtensions.contains(ext) else {
                continue
            }
            
            guard let category = getCategoryForExtension(ext) else {
                continue
            }
            
            let destDir = downloadsURL.appendingPathComponent(category)
            var destURL = destDir.appendingPathComponent(fileName)
            
            var counter = 1
            while FileManager.default.fileExists(atPath: destURL.path) {
                let name = fileURL.deletingPathExtension().lastPathComponent
                let fileExt = fileURL.pathExtension
                destURL = destDir.appendingPathComponent("\(name) (\(counter)).\(fileExt)")
                counter += 1
            }
            
            pendingMoves.append(FileMove(
                source: fileURL.path,
                destination: destURL.path,
                fileName: fileName,
                category: category
            ))
        }
        
        pendingMoves.sort { $0.fileName.lowercased() < $1.fileName.lowercased() }
        
        if pendingMoves.isEmpty {
            statusMessage = "整理するファイルがありません"
        } else {
            statusMessage = "\(pendingMoves.count)件のファイルが整理対象です"
        }
    }
    
    func organize() {
        guard !pendingMoves.isEmpty else { return }
        
        var movedFiles: [[String: String]] = []
        var successCount = 0
        
        for move in pendingMoves {
            do {
                let destDir = URL(fileURLWithPath: move.destination).deletingLastPathComponent()
                try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
                try FileManager.default.moveItem(atPath: move.source, toPath: move.destination)
                
                movedFiles.append([
                    "source": move.source,
                    "destination": move.destination
                ])
                successCount += 1
            } catch {
                print("Error moving \(move.fileName): \(error)")
            }
        }
        
        if !movedFiles.isEmpty {
            saveHistory(moves: movedFiles)
        }
        
        pendingMoves = []
        statusMessage = "\(successCount)件のファイルを整理しました！"
        isError = false
        checkUndoAvailability()
    }
    
    func undo() {
        guard let history = loadHistory(), !history.isEmpty else {
            statusMessage = "元に戻す履歴がありません"
            isError = true
            return
        }
        
        var restoredCount = 0
        
        for move in history.reversed() {
            guard let source = move["source"],
                  let destination = move["destination"] else {
                continue
            }
            
            do {
                if FileManager.default.fileExists(atPath: destination) &&
                   !FileManager.default.fileExists(atPath: source) {
                    try FileManager.default.moveItem(atPath: destination, toPath: source)
                    restoredCount += 1
                    
                    let destDir = URL(fileURLWithPath: destination).deletingLastPathComponent()
                    if let contents = try? FileManager.default.contentsOfDirectory(atPath: destDir.path),
                       contents.isEmpty {
                        try? FileManager.default.removeItem(at: destDir)
                    }
                }
            } catch {
                print("Error restoring: \(error)")
            }
        }
        
        try? FileManager.default.removeItem(at: historyURL)
        
        statusMessage = "\(restoredCount)件のファイルを元に戻しました"
        isError = false
        preview()
        checkUndoAvailability()
    }
    
    private func getMatchingExtension(fileName: String) -> String? {
        let lowerName = fileName.lowercased()
        var allExtensions = Set<String>()
        
        for extensions in rules.values {
            allExtensions.formUnion(extensions)
        }
        allExtensions.formUnion(ignoreExtensions)
        
        var bestMatch: String?
        for ext in allExtensions {
            if lowerName.hasSuffix(ext) {
                if bestMatch == nil || ext.count > bestMatch!.count {
                    bestMatch = ext
                }
            }
        }
        return bestMatch
    }
    
    private func getCategoryForExtension(_ ext: String) -> String? {
        for (category, extensions) in rules {
            if extensions.contains(ext) {
                return category
            }
        }
        return nil
    }
    
    private func saveHistory(moves: [[String: String]]) {
        do {
            let data = try JSONSerialization.data(withJSONObject: moves, options: .prettyPrinted)
            try data.write(to: historyURL)
        } catch {
            print("Failed to save history: \(error)")
        }
    }
    
    private func loadHistory() -> [[String: String]]? {
        guard let data = try? Data(contentsOf: historyURL),
              let history = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else {
            return nil
        }
        return history
    }
    
    private func checkUndoAvailability() {
        canUndo = FileManager.default.fileExists(atPath: historyURL.path)
    }
}
