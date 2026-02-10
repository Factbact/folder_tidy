import Darwin
import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

struct FileMove: Equatable {
    let source: String
    let destination: String
    let fileName: String
    let category: String
    let sourceFolderName: String
    let classificationReason: String
}

struct SessionMoveRecord: Codable, Equatable {
    let source: String
    let destination: String
}

struct OrganizeSession: Codable, Equatable, Identifiable {
    let id: String
    let executedAt: Date
    let automatic: Bool
    let moves: [SessionMoveRecord]

    var movedCount: Int {
        moves.count
    }
}

struct RuleTestResult {
    let fileName: String
    let category: String?
    let reason: String
    let excluded: Bool
}

@MainActor
class FileOrganizer: ObservableObject {
    @Published var pendingMoves: [FileMove] = []
    @Published var statusMessage: String?
    @Published var isError: Bool = false
    @Published var canUndo: Bool = false
    @Published var targetFolders: [String] = [] {
        didSet {
            guard !isRestoringSettings else { return }
            saveSettings()
            updateMonitoringState()
        }
    }
    @Published var autoOrganizeEnabled: Bool = false {
        didSet {
            guard !isRestoringSettings else { return }
            updateMonitoringState()
            saveSettings()
        }
    }
    @Published var exclusionPatterns: [String] = [] {
        didSet {
            guard !isRestoringSettings else { return }
            saveSettings()
        }
    }
    @Published var groupByMonthFolderEnabled: Bool = false {
        didSet {
            guard !isRestoringSettings else { return }
            saveSettings()
        }
    }
    @Published private(set) var isMonitoringFolder: Bool = false
    @Published private(set) var monitoredFolderPaths: [String] = []
    @Published private(set) var currentMonthMovedCount: Int = 0
    @Published private(set) var totalMovedCount: Int = 0
    @Published private(set) var undoSessions: [OrganizeSession] = []
    @Published var autoOrganizeWaitSeconds: Int = 3 {
        didSet {
            let clamped = max(0, min(60, autoOrganizeWaitSeconds))
            if clamped != autoOrganizeWaitSeconds {
                autoOrganizeWaitSeconds = clamped
                return
            }
            guard !isRestoringSettings else { return }
            saveSettings()
        }
    }

    let downloadsPath: String
    private let historyURL: URL
    private let sessionHistoryURL: URL
    private let settings = UserDefaults.standard

    private var monitorDebounceWorkItem: DispatchWorkItem?
    private let monitorQueue = DispatchQueue(label: "downloads.organizer.monitor")
    private var monitorEntries: [String: FolderMonitor] = [:]
    private var isAutoOrganizing = false
    private var isRestoringSettings = false
    private var statsByMonth: [String: Int] = [:]

    private struct FolderMonitor {
        let descriptor: CInt
        let source: DispatchSourceFileSystemObject
    }

    private enum SettingsKey {
        static let targetFolders = "downloadsOrganizer.targetFolders"
        static let autoOrganizeEnabled = "downloadsOrganizer.autoOrganizeEnabled"
        static let exclusionPatterns = "downloadsOrganizer.exclusionPatterns"
        static let groupByMonthFolderEnabled = "downloadsOrganizer.groupByMonthFolderEnabled"
        static let customRules = "downloadsOrganizer.customRules"
        static let ruleOrder = "downloadsOrganizer.ruleOrder"
        static let autoOrganizeWaitSeconds = "downloadsOrganizer.autoOrganizeWaitSeconds"
        static let statsByMonth = "downloadsOrganizer.statsByMonth"
    }

    static let defaultRules: [String: [String]] = [
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

    static let defaultRuleOrder: [String] = [
        "Documents", "Text", "Spreadsheets", "Presentations", "Images", "Videos", "Audio", "Archives", "Installers",
    ]

    @Published var rules: [String: [String]] = FileOrganizer.defaultRules {
        didSet {
            guard !isRestoringSettings else { return }
            rules = normalizedRules(rules)
            normalizeRuleOrderForCurrentRules()
            saveSettings()
        }
    }

    @Published private(set) var ruleOrder: [String] = FileOrganizer.defaultRuleOrder

    private let ignoreExtensions: Set<String> = [
        ".crdownload", ".part", ".partial", ".opdownload", ".download", ".tmp",
    ]

    var sortedRuleCategories: [String] {
        let available = Set(rules.keys)
        var ordered: [String] = []

        for category in ruleOrder where available.contains(category) {
            if !ordered.contains(category) {
                ordered.append(category)
            }
        }

        for category in rules.keys where !ordered.contains(category) {
            ordered.append(category)
        }

        return ordered
    }

    init() {
        self.downloadsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads").path
        self.historyURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".downloads_organizer_history.json")
        self.sessionHistoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".downloads_organizer_sessions.json")

        loadSettings()
        loadUndoSessions()
        checkUndoAvailability()
        requestNotificationPermission()
        updateMonitoringState()
    }

    func addTargetFolder(path: String) -> Bool {
        let standardized = standardizedPath(path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized, isDirectory: &isDir), isDir.boolValue else {
            return false
        }

        let contains = targetFolders.contains { existing in
            existing.caseInsensitiveCompare(standardized) == .orderedSame
        }
        guard !contains else { return false }

        targetFolders.append(standardized)
        targetFolders.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return true
    }

    func removeTargetFolder(path: String) {
        let standardized = standardizedPath(path)
        targetFolders.removeAll {
            $0.caseInsensitiveCompare(standardized) == .orderedSame
        }
    }

    func isFolderMonitored(path: String) -> Bool {
        let standardized = standardizedPath(path)
        return monitoredFolderPaths.contains {
            $0.caseInsensitiveCompare(standardized) == .orderedSame
        }
    }

    func extensions(for category: String) -> [String] {
        (rules[category] ?? []).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func addRuleCategory(name rawName: String, firstExtension rawExtension: String) -> Bool {
        let category = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !category.isEmpty else { return false }
        guard rules[category] == nil else { return false }

        let ext = normalizeExtension(rawExtension)
        guard let ext else { return false }

        rules[category] = [ext]
        return true
    }

    func removeRuleCategory(_ category: String) {
        guard rules.count > 1 else { return }
        rules.removeValue(forKey: category)
    }

    func addRuleExtension(_ rawExtension: String, to category: String) -> Bool {
        guard var extensions = rules[category] else { return false }
        guard let normalized = normalizeExtension(rawExtension) else { return false }
        if extensions.contains(normalized) {
            return false
        }
        extensions.append(normalized)
        rules[category] = extensions
        return true
    }

    func removeRuleExtension(_ extensionValue: String, from category: String) {
        guard var extensions = rules[category] else { return }
        extensions.removeAll { $0 == extensionValue }
        rules[category] = extensions
    }

    func canMoveRuleCategoryUp(_ category: String) -> Bool {
        guard let index = sortedRuleCategories.firstIndex(of: category) else { return false }
        return index > 0
    }

    func canMoveRuleCategoryDown(_ category: String) -> Bool {
        guard let index = sortedRuleCategories.firstIndex(of: category) else { return false }
        return index < sortedRuleCategories.count - 1
    }

    func moveRuleCategoryUp(_ category: String) {
        var ordered = sortedRuleCategories
        guard let index = ordered.firstIndex(of: category), index > 0 else { return }
        ordered.swapAt(index, index - 1)
        applyRuleCategoryOrder(ordered)
    }

    func moveRuleCategoryDown(_ category: String) {
        var ordered = sortedRuleCategories
        guard let index = ordered.firstIndex(of: category), index < ordered.count - 1 else { return }
        ordered.swapAt(index, index + 1)
        applyRuleCategoryOrder(ordered)
    }

    func testRule(for fileURL: URL) -> RuleTestResult {
        let fileName = fileURL.lastPathComponent

        if shouldExclude(fileName: fileName) {
            return RuleTestResult(fileName: fileName, category: nil, reason: "除外ルールに一致", excluded: true)
        }

        let ext = getMatchingExtension(fileName: fileName)
        if let ext, ignoreExtensions.contains(ext) {
            return RuleTestResult(fileName: fileName, category: nil, reason: "一時拡張子 \(ext) のためスキップ", excluded: true)
        }

        if let decision = categoryForFile(fileURL, fileName: fileName, matchedExtension: ext) {
            return RuleTestResult(fileName: fileName, category: decision.category, reason: decision.reason, excluded: false)
        }

        return RuleTestResult(fileName: fileName, category: nil, reason: "一致するルールがないため未分類", excluded: false)
    }

    func preview() {
        preview(minimumAgeSeconds: 0)
    }

    private func preview(minimumAgeSeconds: TimeInterval) {
        pendingMoves = []
        statusMessage = nil
        isError = false

        var allMoves: [FileMove] = []
        var scannedFolderCount = 0
        var scannedFileCount = 0
        var excludedFileCount = 0
        var unclassifiedFileCount = 0
        var waitingFileCount = 0

        for folderPath in targetFolders {
            let sourceFolderURL = URL(fileURLWithPath: folderPath)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: sourceFolderURL.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }

            scannedFolderCount += 1

            guard let files = try? FileManager.default.contentsOfDirectory(
                at: sourceFolderURL,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .creationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            let destinationRoot = destinationRoot(for: sourceFolderURL)

            for fileURL in files {
                guard let isFile = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile,
                      isFile == true else {
                    continue
                }

                scannedFileCount += 1
                let fileName = fileURL.lastPathComponent
                if shouldExclude(fileName: fileName) {
                    excludedFileCount += 1
                    continue
                }

                let ext = getMatchingExtension(fileName: fileName)
                if let ext, ignoreExtensions.contains(ext) {
                    excludedFileCount += 1
                    continue
                }

                if minimumAgeSeconds > 0, !isFileStableForMove(fileURL, minimumAgeSeconds: minimumAgeSeconds) {
                    waitingFileCount += 1
                    continue
                }

                guard let decision = categoryForFile(fileURL, fileName: fileName, matchedExtension: ext) else {
                    unclassifiedFileCount += 1
                    continue
                }

                let destinationDirectory = destinationRoot.appendingPathComponent(decision.category)
                var destinationURL = destinationDirectory.appendingPathComponent(fileName)

                var counter = 1
                while FileManager.default.fileExists(atPath: destinationURL.path) {
                    destinationURL = collisionDestination(baseFileURL: fileURL, destinationDirectory: destinationDirectory, index: counter)
                    counter += 1
                }

                allMoves.append(FileMove(
                    source: fileURL.path,
                    destination: destinationURL.path,
                    fileName: fileName,
                    category: decision.category,
                    sourceFolderName: sourceFolderURL.lastPathComponent,
                    classificationReason: decision.reason
                ))
            }
        }

        allMoves.sort {
            if $0.fileName.lowercased() == $1.fileName.lowercased() {
                return $0.sourceFolderName.lowercased() < $1.sourceFolderName.lowercased()
            }
            return $0.fileName.lowercased() < $1.fileName.lowercased()
        }
        pendingMoves = allMoves

        if scannedFolderCount == 0 {
            statusMessage = "対象フォルダがありません。フォルダを追加してください"
            isError = true
            return
        }

        let waitingText = waitingFileCount > 0 ? "・待機\(waitingFileCount)" : ""

        if pendingMoves.isEmpty {
            statusMessage = "\(scannedFolderCount)フォルダ / ファイル\(scannedFileCount)件を確認（整理対象0件・未分類\(unclassifiedFileCount)\(waitingText)件）"
        } else {
            statusMessage = "\(scannedFolderCount)フォルダ / 対象\(pendingMoves.count)件（除外\(excludedFileCount)・未分類\(unclassifiedFileCount)\(waitingText)）"
        }
    }

    @discardableResult
    func organize(sendNotification: Bool = true, automatic: Bool = false) -> Int {
        guard !pendingMoves.isEmpty else { return 0 }

        var movedFiles: [SessionMoveRecord] = []
        var successCount = 0

        for move in pendingMoves {
            do {
                let destinationDirectory = URL(fileURLWithPath: move.destination).deletingLastPathComponent()
                try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
                try FileManager.default.moveItem(atPath: move.source, toPath: move.destination)

                movedFiles.append(SessionMoveRecord(source: move.source, destination: move.destination))
                successCount += 1
            } catch {
                print("Error moving \(move.fileName): \(error)")
            }
        }

        if !movedFiles.isEmpty {
            appendUndoSession(moves: movedFiles, automatic: automatic)
            saveHistory(moves: movedFiles.map { ["source": $0.source, "destination": $0.destination] })
        }

        if successCount > 0 {
            recordStats(movedCount: successCount)
        }

        pendingMoves = []
        statusMessage = "\(successCount)件のファイルを整理しました！"
        isError = false
        checkUndoAvailability()

        if sendNotification {
            postCompletionNotification(movedCount: successCount, automatic: automatic)
        }

        return successCount
    }

    func quickOrganize() {
        preview()
        _ = organize()
    }

    func undo() {
        if let latest = undoSessions.first {
            undoSession(id: latest.id)
            return
        }

        guard let history = loadHistory(), !history.isEmpty else {
            statusMessage = "元に戻す履歴がありません"
            isError = true
            return
        }

        let moves: [SessionMoveRecord] = history.compactMap { item -> SessionMoveRecord? in
            guard let source = item["source"], let destination = item["destination"] else {
                return nil
            }
            return SessionMoveRecord(source: source, destination: destination)
        }

        let restoredCount = restoreMoves(moves)
        try? FileManager.default.removeItem(at: historyURL)

        statusMessage = "\(restoredCount)件のファイルを元に戻しました"
        isError = false
        preview()
        checkUndoAvailability()
    }

    func undoSession(id: String) {
        guard let index = undoSessions.firstIndex(where: { $0.id == id }) else {
            statusMessage = "指定したセッションが見つかりません"
            isError = true
            return
        }

        let session = undoSessions[index]
        let restoredCount = restoreMoves(session.moves)
        undoSessions.remove(at: index)
        persistUndoSessions()
        syncLegacyHistoryWithLatestSession()

        statusMessage = "\(restoredCount)件のファイルをセッション履歴から元に戻しました"
        isError = false
        preview()
        checkUndoAvailability()
    }

    func addExclusionPattern(_ rawPattern: String) -> Bool {
        let pattern = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else {
            return false
        }

        let exists = exclusionPatterns.contains { existing in
            existing.caseInsensitiveCompare(pattern) == .orderedSame
        }
        guard !exists else {
            return false
        }

        exclusionPatterns.append(pattern)
        exclusionPatterns.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return true
    }

    func removeExclusionPattern(_ pattern: String) {
        exclusionPatterns.removeAll { $0 == pattern }
    }

    private func normalizeExtension(_ rawExtension: String) -> String? {
        var extensionValue = rawExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !extensionValue.isEmpty else { return nil }

        if !extensionValue.hasPrefix(".") {
            extensionValue = ".\(extensionValue)"
        }

        return extensionValue
    }

    private func normalizedRules(_ rawRules: [String: [String]]) -> [String: [String]] {
        var normalized: [String: [String]] = [:]

        for (rawCategory, rawExtensions) in rawRules {
            let category = rawCategory.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !category.isEmpty else { continue }

            var unique: [String] = []
            for rawExtension in rawExtensions {
                guard let normalizedExtension = normalizeExtension(rawExtension), !unique.contains(normalizedExtension) else {
                    continue
                }
                unique.append(normalizedExtension)
            }

            normalized[category] = unique
        }

        return normalized.isEmpty ? FileOrganizer.defaultRules : normalized
    }

    private func normalizeRuleOrderForCurrentRules() {
        let available = Set(rules.keys)
        var ordered: [String] = []

        for category in ruleOrder where available.contains(category) {
            if !ordered.contains(category) {
                ordered.append(category)
            }
        }

        for category in rules.keys where !ordered.contains(category) {
            ordered.append(category)
        }

        ruleOrder = ordered
    }

    private func applyRuleCategoryOrder(_ orderedCategories: [String]) {
        ruleOrder = orderedCategories
        normalizeRuleOrderForCurrentRules()
        saveSettings()
    }

    private func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
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

    private struct ClassificationDecision {
        let category: String
        let reason: String
    }

    private func getCategoryForExtension(_ ext: String) -> String? {
        for category in sortedRuleCategories {
            if rules[category]?.contains(ext) == true {
                return category
            }
        }
        return nil
    }

    private func categoryForFile(_ fileURL: URL, fileName: String, matchedExtension: String?) -> ClassificationDecision? {
        if let matchedExtension, let category = getCategoryForExtension(matchedExtension) {
            return ClassificationDecision(category: category, reason: "拡張子ルール: \(matchedExtension) -> \(category)")
        }

        return categoryByMIME(for: fileURL, fileName: fileName)
    }

    private func categoryByMIME(for fileURL: URL, fileName: String) -> ClassificationDecision? {
        let resourceType = try? fileURL.resourceValues(forKeys: [.contentTypeKey]).contentType
        let extensionType: UTType? = fileURL.pathExtension.isEmpty ? nil : UTType(filenameExtension: fileURL.pathExtension)
        let type = resourceType ?? extensionType

        guard let type else { return nil }

        let identifier = type.identifier
        let identifierLower = identifier.lowercased()

        if type.conforms(to: .image) {
            return ClassificationDecision(category: "Images", reason: "MIMEフォールバック(UTType): \(identifier)")
        }
        if type.conforms(to: .movie) {
            return ClassificationDecision(category: "Videos", reason: "MIMEフォールバック(UTType): \(identifier)")
        }
        if type.conforms(to: .audio) {
            return ClassificationDecision(category: "Audio", reason: "MIMEフォールバック(UTType): \(identifier)")
        }
        if type.conforms(to: .text) || type.conforms(to: .pdf) {
            return ClassificationDecision(category: "Documents", reason: "MIMEフォールバック(UTType): \(identifier)")
        }
        if type.conforms(to: .archive) {
            return ClassificationDecision(category: "Archives", reason: "MIMEフォールバック(UTType): \(identifier)")
        }

        let mimeType = type.preferredMIMEType?.lowercased()

        if let mimeType {
            if mimeType.hasPrefix("image/") {
                return ClassificationDecision(category: "Images", reason: "MIMEフォールバック: \(mimeType)")
            }
            if mimeType.hasPrefix("video/") {
                return ClassificationDecision(category: "Videos", reason: "MIMEフォールバック: \(mimeType)")
            }
            if mimeType.hasPrefix("audio/") {
                return ClassificationDecision(category: "Audio", reason: "MIMEフォールバック: \(mimeType)")
            }
            if mimeType.hasPrefix("text/") || mimeType == "application/pdf" || mimeType == "application/msword" {
                return ClassificationDecision(category: "Documents", reason: "MIMEフォールバック: \(mimeType)")
            }
            if mimeType.hasPrefix("application/vnd"), mimeType.contains("document") {
                return ClassificationDecision(category: "Documents", reason: "MIMEフォールバック: \(mimeType)")
            }

            let archiveMIMEs: Set<String> = [
                "application/zip",
                "application/x-zip-compressed",
                "application/x-tar",
                "application/gzip",
                "application/x-gzip",
                "application/x-7z-compressed",
                "application/x-rar-compressed",
            ]
            if archiveMIMEs.contains(mimeType) {
                return ClassificationDecision(category: "Archives", reason: "MIMEフォールバック: \(mimeType)")
            }
        }

        if identifierLower.contains("word") || identifierLower.contains("document") || identifierLower.contains("opendocument") {
            return ClassificationDecision(category: "Documents", reason: "MIMEフォールバック(識別子): \(identifier)")
        }
        if identifierLower.contains("zip") || identifierLower.contains("tar") || identifierLower.contains("gzip") || identifierLower.contains("archive") {
            return ClassificationDecision(category: "Archives", reason: "MIMEフォールバック(識別子): \(identifier)")
        }

        let lowerName = fileName.lowercased()
        if lowerName.hasSuffix(".pages") || lowerName.hasSuffix(".numbers") || lowerName.hasSuffix(".key") {
            return ClassificationDecision(category: "Documents", reason: "拡張子ヒント: \(fileURL.pathExtension)")
        }

        return nil
    }

    private func destinationRoot(for sourceFolder: URL) -> URL {
        guard groupByMonthFolderEnabled else { return sourceFolder }
        return sourceFolder.appendingPathComponent(currentMonthKey())
    }

    private func currentMonthKey() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: Date())
    }

    private func collisionDestination(baseFileURL: URL, destinationDirectory: URL, index: Int) -> URL {
        let baseName = baseFileURL.deletingPathExtension().lastPathComponent
        let ext = baseFileURL.pathExtension
        let fileName: String
        if ext.isEmpty {
            fileName = "\(baseName) (\(index))"
        } else {
            fileName = "\(baseName) (\(index)).\(ext)"
        }
        return destinationDirectory.appendingPathComponent(fileName)
    }

    private func isFileStableForMove(_ fileURL: URL, minimumAgeSeconds: TimeInterval) -> Bool {
        guard minimumAgeSeconds > 0 else { return true }
        let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        let referenceDate = values?.contentModificationDate ?? values?.creationDate ?? .distantPast
        return Date().timeIntervalSince(referenceDate) >= minimumAgeSeconds
    }

    private func shouldExclude(fileName: String) -> Bool {
        let lowerName = fileName.lowercased()

        for rawPattern in exclusionPatterns {
            let pattern = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !pattern.isEmpty else { continue }

            if pattern.hasPrefix(".") && lowerName.hasSuffix(pattern) {
                return true
            }

            if pattern.contains("*") || pattern.contains("?") {
                if wildcardMatch(fileName: lowerName, pattern: pattern) {
                    return true
                }
            }

            if lowerName == pattern {
                return true
            }
        }

        return false
    }

    private func wildcardMatch(fileName: String, pattern: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".")

        guard let regex = try? NSRegularExpression(pattern: "^\(escaped)$", options: [.caseInsensitive]) else {
            return false
        }

        let range = NSRange(fileName.startIndex..<fileName.endIndex, in: fileName)
        return regex.firstMatch(in: fileName, options: [], range: range) != nil
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

    private func loadUndoSessions() {
        if let data = try? Data(contentsOf: sessionHistoryURL),
           let sessions = try? JSONDecoder().decode([OrganizeSession].self, from: data) {
            undoSessions = sessions.sorted { $0.executedAt > $1.executedAt }
        } else {
            undoSessions = []
        }

        if undoSessions.isEmpty, let legacy = loadHistory(), !legacy.isEmpty {
            let records = legacy.compactMap { item -> SessionMoveRecord? in
                guard let source = item["source"], let destination = item["destination"] else {
                    return nil
                }
                return SessionMoveRecord(source: source, destination: destination)
            }
            if !records.isEmpty {
                undoSessions = [OrganizeSession(id: UUID().uuidString, executedAt: Date(), automatic: false, moves: records)]
                persistUndoSessions()
            }
        }
    }

    private func appendUndoSession(moves: [SessionMoveRecord], automatic: Bool) {
        let session = OrganizeSession(id: UUID().uuidString, executedAt: Date(), automatic: automatic, moves: moves)
        undoSessions.insert(session, at: 0)
        if undoSessions.count > 100 {
            undoSessions = Array(undoSessions.prefix(100))
        }
        persistUndoSessions()
        syncLegacyHistoryWithLatestSession()
    }

    private func restoreMoves(_ moves: [SessionMoveRecord]) -> Int {
        var restoredCount = 0

        for move in moves.reversed() {
            do {
                if FileManager.default.fileExists(atPath: move.destination) &&
                    !FileManager.default.fileExists(atPath: move.source)
                {
                    try FileManager.default.moveItem(atPath: move.destination, toPath: move.source)
                    restoredCount += 1

                    let destinationDirectory = URL(fileURLWithPath: move.destination).deletingLastPathComponent()
                    if let contents = try? FileManager.default.contentsOfDirectory(atPath: destinationDirectory.path),
                       contents.isEmpty
                    {
                        try? FileManager.default.removeItem(at: destinationDirectory)
                    }
                }
            } catch {
                print("Error restoring: \(error)")
            }
        }

        return restoredCount
    }

    private func persistUndoSessions() {
        do {
            let data = try JSONEncoder().encode(undoSessions)
            try data.write(to: sessionHistoryURL)
        } catch {
            print("Failed to save session history: \(error)")
        }
    }

    private func syncLegacyHistoryWithLatestSession() {
        guard let latest = undoSessions.first else {
            try? FileManager.default.removeItem(at: historyURL)
            return
        }

        let moves = latest.moves.map { ["source": $0.source, "destination": $0.destination] }
        saveHistory(moves: moves)
    }

    private func checkUndoAvailability() {
        canUndo = !undoSessions.isEmpty || FileManager.default.fileExists(atPath: historyURL.path)
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func postCompletionNotification(movedCount: Int, automatic: Bool) {
        guard movedCount > 0 else { return }

        let content = UNMutableNotificationContent()
        content.title = automatic ? "自動整理が完了しました" : "整理が完了しました"
        content.body = "\(movedCount)件のファイルを整理しました"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    private func recordStats(movedCount: Int) {
        guard movedCount > 0 else { return }
        let month = currentMonthKey()
        statsByMonth[month, default: 0] += movedCount
        refreshStats()
        saveSettings()
    }

    private func refreshStats() {
        let currentMonth = currentMonthKey()
        currentMonthMovedCount = statsByMonth[currentMonth] ?? 0
        totalMovedCount = statsByMonth.values.reduce(0, +)
    }

    private func loadRulesFromSettings() -> [String: [String]]? {
        guard let raw = settings.dictionary(forKey: SettingsKey.customRules) else {
            return nil
        }

        var parsed: [String: [String]] = [:]
        for (category, value) in raw {
            guard let arr = value as? [String] else { continue }
            parsed[category] = arr
        }

        return parsed
    }

    private func loadStatsFromSettings() -> [String: Int] {
        guard let raw = settings.dictionary(forKey: SettingsKey.statsByMonth) else {
            return [:]
        }

        var parsed: [String: Int] = [:]
        for (key, value) in raw {
            if let intValue = value as? Int {
                parsed[key] = intValue
            } else if let strValue = value as? String, let intValue = Int(strValue) {
                parsed[key] = intValue
            }
        }

        return parsed
    }

    private func loadSettings() {
        isRestoringSettings = true

        autoOrganizeEnabled = settings.bool(forKey: SettingsKey.autoOrganizeEnabled)
        groupByMonthFolderEnabled = settings.bool(forKey: SettingsKey.groupByMonthFolderEnabled)

        let storedWaitSeconds = settings.object(forKey: SettingsKey.autoOrganizeWaitSeconds) as? Int ?? 3
        autoOrganizeWaitSeconds = max(0, min(60, storedWaitSeconds))

        let loadedFolders: [String]
        if settings.object(forKey: SettingsKey.targetFolders) == nil {
            loadedFolders = [downloadsPath]
        } else {
            loadedFolders = settings.stringArray(forKey: SettingsKey.targetFolders) ?? []
        }
        let cleanedFolders = loadedFolders
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            .filter { !$0.isEmpty }

        targetFolders = Array(Set(cleanedFolders)).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }

        let loadedPatterns = settings.stringArray(forKey: SettingsKey.exclusionPatterns) ?? []
        exclusionPatterns = loadedPatterns
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        if let loadedRules = loadRulesFromSettings() {
            rules = normalizedRules(loadedRules)
        } else {
            rules = FileOrganizer.defaultRules
        }

        let loadedOrder = settings.stringArray(forKey: SettingsKey.ruleOrder) ?? FileOrganizer.defaultRuleOrder
        ruleOrder = loadedOrder
        normalizeRuleOrderForCurrentRules()

        statsByMonth = loadStatsFromSettings()
        refreshStats()

        isRestoringSettings = false
    }

    private func saveSettings() {
        settings.set(targetFolders, forKey: SettingsKey.targetFolders)
        settings.set(autoOrganizeEnabled, forKey: SettingsKey.autoOrganizeEnabled)
        settings.set(exclusionPatterns, forKey: SettingsKey.exclusionPatterns)
        settings.set(groupByMonthFolderEnabled, forKey: SettingsKey.groupByMonthFolderEnabled)
        settings.set(autoOrganizeWaitSeconds, forKey: SettingsKey.autoOrganizeWaitSeconds)
        settings.set(rules, forKey: SettingsKey.customRules)
        settings.set(sortedRuleCategories, forKey: SettingsKey.ruleOrder)
        settings.set(statsByMonth, forKey: SettingsKey.statsByMonth)
    }

    private func updateMonitoringState() {
        if autoOrganizeEnabled {
            startFolderMonitoring()
        } else {
            stopFolderMonitoring()
        }
    }

    private func startFolderMonitoring() {
        stopFolderMonitoring()

        for folderPath in targetFolders {
            let normalizedPath = standardizedPath(folderPath)
            let descriptor = open(normalizedPath, O_EVTONLY)
            guard descriptor >= 0 else { continue }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .rename, .delete, .extend, .attrib, .link, .revoke],
                queue: monitorQueue
            )

            source.setEventHandler { [weak self] in
                Task { @MainActor in
                    self?.scheduleAutoOrganize()
                }
            }

            source.resume()
            monitorEntries[normalizedPath] = FolderMonitor(descriptor: descriptor, source: source)
        }

        refreshMonitoredFolderPaths()
        isMonitoringFolder = !monitorEntries.isEmpty
    }

    private func stopFolderMonitoring() {
        monitorDebounceWorkItem?.cancel()
        monitorDebounceWorkItem = nil

        for (_, entry) in monitorEntries {
            entry.source.cancel()
            close(entry.descriptor)
        }

        monitorEntries.removeAll()
        refreshMonitoredFolderPaths()
        isMonitoringFolder = false
    }

    private func refreshMonitoredFolderPaths() {
        monitoredFolderPaths = monitorEntries.keys.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    private func scheduleAutoOrganize() {
        guard autoOrganizeEnabled else { return }

        monitorDebounceWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.runAutoOrganize()
        }

        monitorDebounceWorkItem = workItem
        let delay = max(0.3, TimeInterval(autoOrganizeWaitSeconds))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func runAutoOrganize() {
        guard autoOrganizeEnabled, !isAutoOrganizing else {
            return
        }

        isAutoOrganizing = true
        defer { isAutoOrganizing = false }

        preview(minimumAgeSeconds: TimeInterval(autoOrganizeWaitSeconds))
        guard !pendingMoves.isEmpty else { return }

        _ = organize(sendNotification: true, automatic: true)
    }
}

// MARK: - Update Checker
@MainActor
final class UpdateChecker: ObservableObject {
    enum Phase: String {
        case idle
        case checking
        case downloading
        case extracting
        case ready
        case failed
    }

    @Published var updateAvailable = false
    @Published var latestVersion: String?
    @Published var downloadURL: URL?
    @Published var downloadFileName: String?
    @Published var downloadedFileURL: URL?
    @Published var isChecking = false
    @Published var isDownloading = false
    @Published var statusMessage: String?
    @Published var lastCheckedAt: Date?
    @Published var releaseNotesPreview: String?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var acknowledgedUpdateVersion: String?

    var shouldShowUpdateBadge: Bool {
        guard updateAvailable, let latestVersion else { return false }
        return acknowledgedUpdateVersion != latestVersion
    }

    func acknowledgeUpdateBadge() {
        guard let latestVersion else { return }
        acknowledgedUpdateVersion = latestVersion
    }

    static var currentVersion: String {
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !version.isEmpty {
            return version
        }
        return "1.0.0"
    }

    private let repoOwner = "Factbact"
    private let repoName = "folder_tidy"
    private var releasePageURL: URL?

    private struct ReleaseAsset {
        let name: String
        let url: URL
    }

    private struct ReleaseResponse: Decodable {
        let tag_name: String
        let body: String?
        let html_url: String?
        let assets: [ReleaseAssetResponse]
    }

    private struct ReleaseAssetResponse: Decodable {
        let name: String
        let browser_download_url: String
    }

    private enum UpdateError: LocalizedError {
        case invalidRequest
        case missingDownloadURL
        case missingInstallTarget
        case installFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidRequest:
                return "アップデート情報の取得先URLを生成できませんでした"
            case .missingDownloadURL:
                return "このリリースに配布ファイルが見つかりません"
            case .missingInstallTarget:
                return "展開後のインストール対象が見つかりませんでした"
            case let .installFailed(message):
                return message
            }
        }
    }

    func checkForUpdates() {
        guard !isChecking else { return }
        isChecking = true
        phase = .checking
        statusMessage = "最新バージョンを確認中..."

        Task {
            defer {
                isChecking = false
                lastCheckedAt = Date()
                if phase == .checking {
                    phase = .idle
                }
            }

            do {
                let release = try await fetchLatestRelease()
                let latest = normalizedVersionText(release.tag_name)
                latestVersion = latest
                releaseNotesPreview = summarizedReleaseNotes(from: release.body)
                releasePageURL = release.html_url.flatMap(URL.init(string:))
                downloadedFileURL = nil

                let preferred = preferredAsset(from: release.assets, latestVersion: latest)
                downloadURL = preferred?.url
                downloadFileName = preferred?.name

                if isNewerVersion(latest, than: Self.currentVersion) {
                    updateAvailable = true
                    phase = .idle
                    if preferred == nil {
                        statusMessage = "新しいバージョンがありますが、配布ファイルが見つかりません"
                    } else {
                        statusMessage = "新しいバージョン \(latest) が見つかりました"
                    }
                } else {
                    updateAvailable = false
                    acknowledgedUpdateVersion = nil
                    downloadURL = nil
                    downloadFileName = nil
                    phase = .idle
                    statusMessage = "最新バージョンです"
                }
            } catch {
                updateAvailable = false
                phase = .failed
                statusMessage = "アップデート確認に失敗しました: \(error.localizedDescription)"
            }
        }
    }

    func downloadAndInstallUpdate() {
        guard !isDownloading else { return }
        guard let downloadURL else {
            phase = .failed
            statusMessage = UpdateError.missingDownloadURL.localizedDescription
            return
        }

        isDownloading = true
        phase = .downloading
        statusMessage = "更新ファイルをダウンロード中..."

        let preferredName = downloadFileName?.isEmpty == false ? downloadFileName! : downloadURL.lastPathComponent

        Task {
            defer { isDownloading = false }

            do {
                var request = URLRequest(url: downloadURL)
                request.timeoutInterval = 120
                let (tempURL, _) = try await URLSession.shared.download(for: request)
                let localFileURL = try saveDownloadedFile(tempURL: tempURL, preferredName: preferredName)

                if localFileURL.pathExtension.lowercased() == "zip" {
                    phase = .extracting
                    statusMessage = "更新ファイルを展開中..."
                }

                let installTarget = try await prepareInstallTarget(from: localFileURL)
                downloadedFileURL = installTarget
                phase = .ready
                openPreparedUpdate(at: installTarget)
            } catch {
                phase = .failed
                statusMessage = "ダウンロードに失敗しました: \(error.localizedDescription)"
            }
        }
    }

    func downloadAndOpenUpdate() {
        downloadAndInstallUpdate()
    }

    func openDownloadedFile() {
        guard let downloadedFileURL else { return }
        openPreparedUpdate(at: downloadedFileURL)
    }

    func openReleasePage() {
        let url = releasePageURL
            ?? URL(string: "https://github.com/\(repoOwner)/\(repoName)/releases/latest")!
        NSWorkspace.shared.open(url)
    }

    private func fetchLatestRelease() async throws -> ReleaseResponse {
        let urlString = "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest"
        guard let url = URL(string: urlString) else {
            throw UpdateError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            throw URLError(.badServerResponse)
        }

        return try JSONDecoder().decode(ReleaseResponse.self, from: data)
    }

    private func preferredAsset(from rawAssets: [ReleaseAssetResponse], latestVersion: String) -> ReleaseAsset? {
        let assets: [ReleaseAsset] = rawAssets.compactMap { raw in
            let lowerName = raw.name.lowercased()
            if lowerName.contains("source code") {
                return nil
            }

            guard let url = URL(string: raw.browser_download_url) else {
                return nil
            }

            return ReleaseAsset(name: raw.name, url: url)
        }

        let normalizedLatest = normalizedVersionText(latestVersion).lowercased()
        let compactLatest = normalizedLatest.replacingOccurrences(of: ".", with: "")
        let versionHints = [
            normalizedLatest,
            "v\(normalizedLatest)",
            normalizedLatest.replacingOccurrences(of: ".", with: "_"),
            normalizedLatest.replacingOccurrences(of: ".", with: "-"),
            compactLatest,
            "v\(compactLatest)",
        ]

        func isLatestHintedAsset(_ asset: ReleaseAsset) -> Bool {
            let haystack = "\(asset.name.lowercased()) \(asset.url.lastPathComponent.lowercased())"
            return versionHints.contains { hint in
                !hint.isEmpty && haystack.contains(hint)
            }
        }

        let prioritySuffixes = [".dmg", ".pkg", ".zip"]
        for suffix in prioritySuffixes {
            let candidates = assets.filter { asset in
                asset.name.lowercased().hasSuffix(suffix) || asset.url.path.lowercased().hasSuffix(suffix)
            }

            if let hit = candidates.first(where: { isLatestHintedAsset($0) }) {
                return hit
            }

            if let hit = candidates.first {
                return hit
            }
        }

        return assets.first
    }

    private func saveDownloadedFile(tempURL: URL, preferredName: String) throws -> URL {
        let fileManager = FileManager.default
        let downloadsFolder = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        let updatesFolder = downloadsFolder.appendingPathComponent("Folder Tidy Updates", isDirectory: true)

        try fileManager.createDirectory(at: updatesFolder, withIntermediateDirectories: true)

        let originalDestination = updatesFolder.appendingPathComponent(preferredName)
        let baseName = originalDestination.deletingPathExtension().lastPathComponent
        let ext = originalDestination.pathExtension

        var destination = originalDestination
        var index = 1
        while fileManager.fileExists(atPath: destination.path) {
            let candidateName = ext.isEmpty ? "\(baseName) (\(index))" : "\(baseName) (\(index)).\(ext)"
            destination = updatesFolder.appendingPathComponent(candidateName)
            index += 1
        }

        try fileManager.moveItem(at: tempURL, to: destination)
        return destination
    }

    private func prepareInstallTarget(from localFileURL: URL) async throws -> URL {
        if localFileURL.pathExtension.lowercased() != "zip" {
            return localFileURL
        }

        return try await Task.detached(priority: .userInitiated) {
            let extractionRoot = localFileURL.deletingLastPathComponent()
            let baseName = localFileURL.deletingPathExtension().lastPathComponent
            let extractionDirectory = try Self.makeUniqueDirectory(baseName: baseName, in: extractionRoot)
            try Self.extractZipArchive(at: localFileURL, to: extractionDirectory)
            guard let installTarget = Self.preferredInstallTarget(in: extractionDirectory) else {
                throw UpdateError.missingInstallTarget
            }
            return installTarget
        }.value
    }

    private func openPreparedUpdate(at fileURL: URL) {
        let fileExtension = fileURL.pathExtension.lowercased()
        switch fileExtension {
        case "dmg":
            do {
                phase = .extracting
                statusMessage = "更新ディスクイメージを展開中..."
                let stagedAppURL = try installTargetFromDiskImage(at: fileURL)
                let installedAppURL = try installAppUpdate(from: stagedAppURL)
                downloadedFileURL = installedAppURL
                phase = .ready
                updateAvailable = false
                acknowledgedUpdateVersion = latestVersion
                statusMessage = "更新をインストールしました。アプリを再起動します..."
                scheduleRelaunchAndTerminate(at: installedAppURL)
            } catch {
                phase = .idle
                if NSWorkspace.shared.open(fileURL) {
                    statusMessage = "自動インストールに失敗しました。表示されたウィンドウで Folder Tidy.app を Applications にドラッグしてください: \(error.localizedDescription)"
                } else {
                    statusMessage = "ディスクイメージを開けませんでした。Finderでファイルを確認してください: \(error.localizedDescription)"
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                }
            }
        case "pkg":
            if NSWorkspace.shared.open(fileURL) {
                statusMessage = "インストーラーを開きました。画面の案内に従って更新してください。"
            } else {
                statusMessage = "インストーラーを開けませんでした。Finderでファイルを確認してください。"
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            }
        case "app":
            do {
                let installedAppURL = try installAppUpdate(from: fileURL)
                downloadedFileURL = installedAppURL
                phase = .ready
                updateAvailable = false
                acknowledgedUpdateVersion = latestVersion
                statusMessage = "更新をインストールしました。アプリを再起動します..."
                scheduleRelaunchAndTerminate(at: installedAppURL)
            } catch {
                statusMessage = "自動インストールに失敗しました。Finderで置き換えてください: \(error.localizedDescription)"
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            }
        default:
            statusMessage = "更新ファイルを保存しました: \(fileURL.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        }
    }

    private func installAppUpdate(from stagedAppURL: URL) throws -> URL {
        let destinationURL = resolveInstallDestination(for: stagedAppURL)

        do {
            try installAppWithoutPrivileges(from: stagedAppURL, to: destinationURL)
            return destinationURL
        } catch {
            do {
                try installAppWithAdministratorPrivileges(from: stagedAppURL, to: destinationURL)
                return destinationURL
            } catch let privilegeError {
                throw UpdateError.installFailed("管理者権限でのインストールに失敗しました: \(privilegeError.localizedDescription)")
            }
        }
    }

    private func resolveInstallDestination(for stagedAppURL: URL) -> URL {
        let runningAppURL = Bundle.main.bundleURL.standardizedFileURL
        let appName = stagedAppURL.lastPathComponent
        let applicationsURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let applicationsDestination = applicationsURL.appendingPathComponent(appName, isDirectory: true)

        if runningAppURL.pathExtension.lowercased() == "app",
           runningAppURL.lastPathComponent.caseInsensitiveCompare(appName) == .orderedSame
        {
            return runningAppURL
        }

        if FileManager.default.fileExists(atPath: applicationsDestination.path) {
            return applicationsDestination
        }

        if runningAppURL.path.hasPrefix("/Applications/") {
            return applicationsDestination
        }

        return applicationsDestination
    }

    private func installAppWithoutPrivileges(from stagedAppURL: URL, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        let destinationDirectory = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: destinationURL.path) {
            do {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: stagedAppURL)
            } catch {
                try fileManager.removeItem(at: destinationURL)
                try fileManager.copyItem(at: stagedAppURL, to: destinationURL)
            }
        } else {
            try fileManager.copyItem(at: stagedAppURL, to: destinationURL)
        }

        clearQuarantineAttributeIfNeeded(at: destinationURL)
    }

    private func installAppWithAdministratorPrivileges(from stagedAppURL: URL, to destinationURL: URL) throws {
        let destinationDirectory = destinationURL.deletingLastPathComponent().path
        let shellCommand = [
            "/bin/mkdir -p \(Self.shellEscaped(destinationDirectory))",
            "/bin/rm -rf \(Self.shellEscaped(destinationURL.path))",
            "/usr/bin/ditto \(Self.shellEscaped(stagedAppURL.path)) \(Self.shellEscaped(destinationURL.path))",
            "/usr/bin/xattr -dr com.apple.quarantine \(Self.shellEscaped(destinationURL.path)) || true",
        ].joined(separator: "; ")

        let appleScript = "do shell script \(Self.appleScriptQuoted(shellCommand)) with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let messageData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let rawMessage = String(data: messageData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let message = (rawMessage?.isEmpty == false) ? rawMessage! : "管理者権限でのインストールが完了しませんでした"
            throw UpdateError.installFailed(message)
        }
    }

    private func clearQuarantineAttributeIfNeeded(at appURL: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-dr", "com.apple.quarantine", appURL.path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // Ignore xattr failures; installation can proceed without it.
        }
    }

    private func scheduleRelaunchAndTerminate(at appURL: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        /bin/sleep 1
        while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.3; done
        /usr/bin/open \(Self.shellEscaped(appURL.path))
        """

        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        launcher.arguments = ["-c", "\(script) >/dev/null 2>&1 &"]
        try? launcher.run()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApp.terminate(nil)
        }
    }

    private func installTargetFromDiskImage(at diskImageURL: URL) throws -> URL {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let mountPoint = try Self.makeUniqueDirectory(baseName: "FolderTidyUpdateMount", in: tempRoot)
        var mounted = false
        defer {
            if mounted {
                try? Self.detachDiskImage(at: mountPoint)
            }
            try? fileManager.removeItem(at: mountPoint)
        }

        try Self.attachDiskImage(at: diskImageURL, to: mountPoint)
        mounted = true

        guard let appURL = Self.preferredAppBundle(in: mountPoint) else {
            throw UpdateError.missingInstallTarget
        }

        let stagingRoot = tempRoot.appendingPathComponent("FolderTidyUpdateStage", isDirectory: true)
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        return try Self.copyItemToUniqueLocation(appURL, in: stagingRoot)
    }

    nonisolated private static func shellEscaped(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escaped)'"
    }

    nonisolated private static func appleScriptQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    nonisolated private static func makeUniqueDirectory(baseName: String, in root: URL) throws -> URL {
        let fileManager = FileManager.default
        var candidate = root.appendingPathComponent(baseName, isDirectory: true)
        var index = 1
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(baseName) (\(index))", isDirectory: true)
            index += 1
        }
        try fileManager.createDirectory(at: candidate, withIntermediateDirectories: true)
        return candidate
    }

    nonisolated private static func copyItemToUniqueLocation(_ sourceURL: URL, in directory: URL) throws -> URL {
        let fileManager = FileManager.default
        let ext = sourceURL.pathExtension
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        var candidate = directory.appendingPathComponent(sourceURL.lastPathComponent, isDirectory: true)
        var index = 1

        while fileManager.fileExists(atPath: candidate.path) {
            let fileName = ext.isEmpty ? "\(baseName) (\(index))" : "\(baseName) (\(index)).\(ext)"
            candidate = directory.appendingPathComponent(fileName, isDirectory: true)
            index += 1
        }

        try fileManager.copyItem(at: sourceURL, to: candidate)
        return candidate
    }

    nonisolated private static func attachDiskImage(at diskImageURL: URL, to mountPoint: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = [
            "attach", diskImageURL.path,
            "-nobrowse", "-readonly",
            "-mountpoint", mountPoint.path,
            "-quiet",
        ]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let messageData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: messageData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "UpdateChecker",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message?.isEmpty == false ? message! : "ディスクイメージをマウントできませんでした"]
            )
        }
    }

    nonisolated private static func detachDiskImage(at mountPoint: URL) throws {
        let attempts: [[String]] = [
            ["detach", mountPoint.path, "-quiet"],
            ["detach", mountPoint.path, "-force", "-quiet"],
        ]

        var lastMessage = "ディスクイメージを取り外せませんでした"
        var lastCode = -1
        for arguments in attempts {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = arguments
            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = outputPipe
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                return
            }

            lastCode = Int(process.terminationStatus)
            let messageData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            if let message = String(data: messageData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !message.isEmpty {
                lastMessage = message
            }
        }

        throw NSError(
            domain: "UpdateChecker",
            code: lastCode,
            userInfo: [NSLocalizedDescriptionKey: lastMessage]
        )
    }

    nonisolated private static func preferredAppBundle(in root: URL) -> URL? {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return nil
        }

        let preferredName = Bundle.main.bundleURL.lastPathComponent.lowercased()
        var fallbackApp: URL?

        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "app" else { continue }
            if url.lastPathComponent.lowercased() == preferredName {
                return url
            }
            if fallbackApp == nil {
                fallbackApp = url
            }
        }

        return fallbackApp
    }

    nonisolated private static func extractZipArchive(at archiveURL: URL, to destinationURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archiveURL.path, destinationURL.path]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "UpdateChecker",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "ZIPファイルの展開に失敗しました"]
            )
        }
    }

    nonisolated private static func preferredInstallTarget(in root: URL) -> URL? {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return nil
        }

        var packageURL: URL?
        var dmgURL: URL?
        var fallbackURL: URL?

        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            if ext == "app" { return url }
            if ext == "pkg", packageURL == nil { packageURL = url }
            if ext == "dmg", dmgURL == nil { dmgURL = url }
            if fallbackURL == nil { fallbackURL = url }
        }

        return packageURL ?? dmgURL ?? fallbackURL
    }

    private func summarizedReleaseNotes(from rawBody: String?) -> String? {
        guard let rawBody else { return nil }
        let lines = rawBody
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        guard !lines.isEmpty else { return nil }

        let clipped = lines.prefix(6).joined(separator: "\n")
        if clipped.count > 420 {
            return String(clipped.prefix(420)) + "..."
        }
        return clipped
    }

    private func normalizedVersionText(_ version: String) -> String {
        version.hasPrefix("v") ? String(version.dropFirst()) : version
    }

    private func versionParts(_ version: String) -> [Int] {
        version
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
    }

    private func isNewerVersion(_ new: String, than current: String) -> Bool {
        let newParts = versionParts(new)
        let currentParts = versionParts(current)

        for index in 0..<max(newParts.count, currentParts.count) {
            let left = index < newParts.count ? newParts[index] : 0
            let right = index < currentParts.count ? currentParts[index] : 0

            if left > right { return true }
            if left < right { return false }
        }
        return false
    }
}
