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

    let downloadsPath: String
    private let historyURL: URL
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

    @Published var rules: [String: [String]] = FileOrganizer.defaultRules {
        didSet {
            guard !isRestoringSettings else { return }
            rules = normalizedRules(rules)
            saveSettings()
        }
    }

    private let ignoreExtensions: Set<String> = [
        ".crdownload", ".part", ".partial", ".opdownload", ".download", ".tmp",
    ]

    var sortedRuleCategories: [String] {
        rules.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    init() {
        self.downloadsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads").path
        self.historyURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".downloads_organizer_history.json")

        loadSettings()
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

    func preview() {
        pendingMoves = []
        statusMessage = nil
        isError = false

        var allMoves: [FileMove] = []
        var scannedFolderCount = 0
        var scannedFileCount = 0
        var excludedFileCount = 0
        var unclassifiedFileCount = 0

        for folderPath in targetFolders {
            let sourceFolderURL = URL(fileURLWithPath: folderPath)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: sourceFolderURL.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }

            scannedFolderCount += 1

            guard let files = try? FileManager.default.contentsOfDirectory(
                at: sourceFolderURL,
                includingPropertiesForKeys: [.isRegularFileKey],
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

                guard let category = categoryForFile(fileURL, fileName: fileName, matchedExtension: ext) else {
                    unclassifiedFileCount += 1
                    continue
                }

                let destinationDirectory = destinationRoot.appendingPathComponent(category)
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
                    category: category,
                    sourceFolderName: sourceFolderURL.lastPathComponent
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

        if pendingMoves.isEmpty {
            statusMessage = "\(scannedFolderCount)フォルダ / ファイル\(scannedFileCount)件を確認（整理対象0件・未分類\(unclassifiedFileCount)件）"
        } else {
            statusMessage = "\(scannedFolderCount)フォルダ / 対象\(pendingMoves.count)件（除外\(excludedFileCount)・未分類\(unclassifiedFileCount)）"
        }
    }

    @discardableResult
    func organize(sendNotification: Bool = true, automatic: Bool = false) -> Int {
        guard !pendingMoves.isEmpty else { return 0 }

        var movedFiles: [[String: String]] = []
        var successCount = 0

        for move in pendingMoves {
            do {
                let destinationDirectory = URL(fileURLWithPath: move.destination).deletingLastPathComponent()
                try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
                try FileManager.default.moveItem(atPath: move.source, toPath: move.destination)

                movedFiles.append([
                    "source": move.source,
                    "destination": move.destination,
                ])
                successCount += 1
            } catch {
                print("Error moving \(move.fileName): \(error)")
            }
        }

        if !movedFiles.isEmpty {
            saveHistory(moves: movedFiles)
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
                    !FileManager.default.fileExists(atPath: source)
                {
                    try FileManager.default.moveItem(atPath: destination, toPath: source)
                    restoredCount += 1

                    let destinationDirectory = URL(fileURLWithPath: destination).deletingLastPathComponent()
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

        try? FileManager.default.removeItem(at: historyURL)

        statusMessage = "\(restoredCount)件のファイルを元に戻しました"
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

    private func getCategoryForExtension(_ ext: String) -> String? {
        for (category, extensions) in rules {
            if extensions.contains(ext) {
                return category
            }
        }
        return nil
    }

    private func categoryForFile(_ fileURL: URL, fileName: String, matchedExtension: String?) -> String? {
        // 1) 拡張子ルール（default + custom）を最優先
        if let matchedExtension, let category = getCategoryForExtension(matchedExtension) {
            return category
        }

        // 2) 未分類のみ MIME/UTType でフォールバック
        return categoryByMIME(for: fileURL, fileName: fileName)
    }

    private func categoryByMIME(for fileURL: URL, fileName: String) -> String? {
        let resourceType = try? fileURL.resourceValues(forKeys: [.contentTypeKey]).contentType
        let extensionType: UTType? = fileURL.pathExtension.isEmpty ? nil : UTType(filenameExtension: fileURL.pathExtension)
        let type = resourceType ?? extensionType

        guard let type else { return nil }

        if type.conforms(to: .image) {
            return "Images"
        }
        if type.conforms(to: .movie) {
            return "Videos"
        }
        if type.conforms(to: .audio) {
            return "Audio"
        }
        if type.conforms(to: .text) || type.conforms(to: .pdf) {
            return "Documents"
        }
        if type.conforms(to: .archive) {
            return "Archives"
        }

        let identifier = type.identifier.lowercased()
        let mimeType = type.preferredMIMEType?.lowercased()

        if let mimeType {
            if mimeType.hasPrefix("image/") {
                return "Images"
            }
            if mimeType.hasPrefix("video/") {
                return "Videos"
            }
            if mimeType.hasPrefix("audio/") {
                return "Audio"
            }
            if mimeType.hasPrefix("text/") || mimeType == "application/pdf" || mimeType == "application/msword" {
                return "Documents"
            }
            if mimeType.hasPrefix("application/vnd"), mimeType.contains("document") {
                return "Documents"
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
                return "Archives"
            }
        }

        if identifier.contains("word") || identifier.contains("document") || identifier.contains("opendocument") {
            return "Documents"
        }
        if identifier.contains("zip") || identifier.contains("tar") || identifier.contains("gzip") || identifier.contains("archive") {
            return "Archives"
        }

        let lowerName = fileName.lowercased()
        if lowerName.hasSuffix(".pages") || lowerName.hasSuffix(".numbers") || lowerName.hasSuffix(".key") {
            return "Documents"
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

    private func checkUndoAvailability() {
        canUndo = FileManager.default.fileExists(atPath: historyURL.path)
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

        statsByMonth = loadStatsFromSettings()
        refreshStats()

        isRestoringSettings = false
    }

    private func saveSettings() {
        settings.set(targetFolders, forKey: SettingsKey.targetFolders)
        settings.set(autoOrganizeEnabled, forKey: SettingsKey.autoOrganizeEnabled)
        settings.set(exclusionPatterns, forKey: SettingsKey.exclusionPatterns)
        settings.set(groupByMonthFolderEnabled, forKey: SettingsKey.groupByMonthFolderEnabled)
        settings.set(rules, forKey: SettingsKey.customRules)
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
    }

    private func runAutoOrganize() {
        guard autoOrganizeEnabled, !isAutoOrganizing else {
            return
        }

        isAutoOrganizing = true
        defer { isAutoOrganizing = false }

        preview()
        guard !pendingMoves.isEmpty else { return }

        _ = organize(sendNotification: true, automatic: true)
    }
}

// MARK: - Update Checker
@MainActor
final class UpdateChecker: ObservableObject {
    @Published var updateAvailable = false
    @Published var latestVersion: String?
    @Published var downloadURL: URL?
    @Published var downloadFileName: String?
    @Published var downloadedFileURL: URL?
    @Published var isChecking = false
    @Published var isDownloading = false
    @Published var statusMessage: String?
    @Published var lastCheckedAt: Date?

    static var currentVersion: String {
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !version.isEmpty {
            return version
        }
        return "1.0.0"
    }

    private let repoOwner = "Factbact"
    private let repoName = "folder_tidy"

    private struct ReleaseAsset {
        let name: String
        let url: URL
    }

    func checkForUpdates() {
        guard !isChecking else { return }
        isChecking = true
        statusMessage = nil

        Task {
            defer {
                isChecking = false
                lastCheckedAt = Date()
            }

            let urlString = "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest"
            guard let url = URL(string: urlString) else {
                statusMessage = "アップデート確認URLの生成に失敗しました"
                return
            }

            var request = URLRequest(url: url)
            request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 20

            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tagName = json["tag_name"] as? String else {
                    statusMessage = "アップデート情報の取得に失敗しました"
                    return
                }

                let latest = normalizedVersionText(tagName)
                latestVersion = latest
                downloadedFileURL = nil

                let assets = json["assets"] as? [[String: Any]] ?? []
                let preferredAsset = preferredAsset(from: assets)
                downloadURL = preferredAsset?.url
                downloadFileName = preferredAsset?.name

                if isNewerVersion(latest, than: Self.currentVersion) {
                    updateAvailable = true
                    if preferredAsset == nil {
                        statusMessage = "新しいバージョンがありますが、配布ファイルが見つかりません"
                    }
                } else {
                    updateAvailable = false
                    statusMessage = "最新バージョンです"
                }
            } catch {
                statusMessage = "アップデート確認に失敗しました: \(error.localizedDescription)"
            }
        }
    }

    func downloadAndOpenUpdate() {
        guard !isDownloading else { return }
        guard let downloadURL else {
            statusMessage = "ダウンロードURLが見つかりません"
            return
        }

        isDownloading = true
        statusMessage = "アップデートをダウンロード中..."

        let preferredName = downloadFileName?.isEmpty == false ? downloadFileName! : downloadURL.lastPathComponent

        Task {
            defer { isDownloading = false }

            do {
                let (tempURL, _) = try await URLSession.shared.download(from: downloadURL)
                let localFileURL = try saveDownloadedFile(tempURL: tempURL, preferredName: preferredName)
                downloadedFileURL = localFileURL
                statusMessage = "ダウンロード完了: \(localFileURL.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([localFileURL])
                NSWorkspace.shared.open(localFileURL)
            } catch {
                statusMessage = "ダウンロードに失敗しました: \(error.localizedDescription)"
            }
        }
    }

    func openDownloadedFile() {
        guard let downloadedFileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([downloadedFileURL])
        NSWorkspace.shared.open(downloadedFileURL)
    }

    func openReleasePage() {
        let url = URL(string: "https://github.com/\(repoOwner)/\(repoName)/releases/latest")!
        NSWorkspace.shared.open(url)
    }

    private func preferredAsset(from rawAssets: [[String: Any]]) -> ReleaseAsset? {
        let assets: [ReleaseAsset] = rawAssets.compactMap { raw in
            guard let name = raw["name"] as? String,
                  let urlText = raw["browser_download_url"] as? String,
                  let url = URL(string: urlText) else {
                return nil
            }
            return ReleaseAsset(name: name, url: url)
        }

        let prioritySuffixes = [".dmg", ".pkg", ".zip"]
        for suffix in prioritySuffixes {
            if let hit = assets.first(where: { asset in
                asset.name.lowercased().hasSuffix(suffix) || asset.url.path.lowercased().hasSuffix(suffix)
            }) {
                return hit
            }
        }

        return assets.first
    }

    private func saveDownloadedFile(tempURL: URL, preferredName: String) throws -> URL {
        let fileManager = FileManager.default
        let downloadsFolder = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)

        try fileManager.createDirectory(at: downloadsFolder, withIntermediateDirectories: true)

        let originalDestination = downloadsFolder.appendingPathComponent(preferredName)
        let baseName = originalDestination.deletingPathExtension().lastPathComponent
        let ext = originalDestination.pathExtension

        var destination = originalDestination
        var index = 1
        while fileManager.fileExists(atPath: destination.path) {
            let candidateName = ext.isEmpty ? "\(baseName) (\(index))" : "\(baseName) (\(index)).\(ext)"
            destination = downloadsFolder.appendingPathComponent(candidateName)
            index += 1
        }

        try fileManager.moveItem(at: tempURL, to: destination)
        return destination
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
