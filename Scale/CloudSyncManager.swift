import Foundation
import Combine
import SwiftUI

/// iCloud 同步状态
enum CloudSyncState: Equatable {
    case idle
    case syncing
    case success
    case error(String)
}

/// 负责体脂秤历史测量数据的 iCloud 跨设备自动同步与合并。
///
/// 核心架构：基于 Apple 官方「安全范围书签（Security-Scoped Bookmark）」机制。
/// - 用户在「我的资料」中通过系统文件选择器指定一次「iCloud 云盘」中的目标文件夹（如 Scale）；
/// - App 获得持久化安全书签后，每次测量完成自动静默向该 iCloud 目录读写 `measurements_history.json`；
/// - 彻底摆脱 99 美元付费开发者账号限制，在普通自签 / TrollStore 环境下均可无感跨设备自动同步！
@MainActor
final class CloudSyncManager: ObservableObject {
    static let shared = CloudSyncManager()

    private let bookmarkKey = "icloud_drive_folder_bookmark_v2"
    private let folderNameKey = "icloud_drive_folder_name_v2"
    private let lastSyncKey = "icloud_drive_last_sync_time_v2"
    private let syncFileName = "measurements_history.json"

    @Published var isSyncing: Bool = false
    @Published var syncState: CloudSyncState = .idle
    @Published var lastSyncTime: Date? = nil
    @Published var statusMessage: String = "未绑定 iCloud 云盘文件夹"
    @Published var isFolderBound: Bool = false
    @Published var boundFolderName: String = ""

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    init() {
        // 加载已保存的文件夹名称与同步时间
        if let folderName = UserDefaults.standard.string(forKey: folderNameKey),
           UserDefaults.standard.data(forKey: bookmarkKey) != nil {
            self.isFolderBound = true
            self.boundFolderName = folderName
            if let ts = UserDefaults.standard.object(forKey: lastSyncKey) as? Date {
                self.lastSyncTime = ts
                self.statusMessage = "上次同步：" + Self.dateFormatter.string(from: ts)
            } else {
                self.statusMessage = "已绑定文件夹「\(folderName)」，等待首次同步"
            }
        } else {
            self.isFolderBound = false
            self.statusMessage = "未绑定 iCloud 云盘文件夹"
        }
    }

    /// 绑定用户通过系统文件选择器选中的 iCloud 云盘目录（或其中的数据文件）
    func bindFolder(url: URL, historyStore: HistoryStore) {
        AppLog("📁 [CloudSync] 开始绑定 URL: \(url.path)")
        let isAccessing = url.startAccessingSecurityScopedResource()
        AppLog("📁 [CloudSync] startAccessingSecurityScopedResource 授权结果: \(isAccessing)")
        defer {
            if isAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        // 智能兼容：若用户直接点选了 measurements_history.json 文件，自动取其父目录
        var targetFolderURL = url
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
            if !isDir.boolValue {
                targetFolderURL = url.deletingLastPathComponent()
                AppLog("📁 [CloudSync] 选中的是文件，提取所在目录: \(targetFolderURL.path)")
            }
        } else if url.pathExtension.lowercased() == "json" {
            targetFolderURL = url.deletingLastPathComponent()
            AppLog("📁 [CloudSync] 选中的是 .json 后缀，提取所在目录: \(targetFolderURL.path)")
        }

        do {
            // 生成持久化安全书签（注意：不能使用 .minimalBookmark，必须使用标准 options: [] 以包含 security scope 授权）
            let bookmarkData = try targetFolderURL.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            let folderName = targetFolderURL.lastPathComponent.isEmpty ? "iCloud 文件夹" : targetFolderURL.lastPathComponent
            UserDefaults.standard.set(bookmarkData, forKey: bookmarkKey)
            UserDefaults.standard.set(folderName, forKey: folderNameKey)

            self.isFolderBound = true
            self.boundFolderName = folderName
            self.statusMessage = "已绑定「\(folderName)」，正在同步..."
            AppLog("✅ [CloudSync] 成功生成持久化安全书签，目标目录: \(folderName)，书签大小: \(bookmarkData.count) 字节")

            // 绑定后立即触发首次双向同步
            syncNow(historyStore: historyStore)
        } catch {
            self.syncState = .error(error.localizedDescription)
            self.statusMessage = "绑定失败: \(error.localizedDescription)"
            AppLog("⚠️ [CloudSync] 创建安全书签失败: \(error.localizedDescription)")
        }
    }

    /// 解除 iCloud 云盘目录绑定
    func unbindFolder() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        UserDefaults.standard.removeObject(forKey: folderNameKey)
        UserDefaults.standard.removeObject(forKey: lastSyncKey)
        self.isFolderBound = false
        self.boundFolderName = ""
        self.lastSyncTime = nil
        self.syncState = .idle
        self.statusMessage = "未绑定 iCloud 云盘文件夹"
        AppLog("📁 [CloudSync] 已解除 iCloud 云盘目录绑定并清理书签")
    }

    /// 执行双向同步：从 iCloud 目录拉取新数据合并入本地，并将本地完整数据回写至该 iCloud 目录
    func syncNow(historyStore: HistoryStore) {
        guard isFolderBound else {
            self.statusMessage = "请先在设置中选择 iCloud 云盘文件夹"
            AppLog("ℹ️ [CloudSync] syncNow 跳过：尚未绑定文件夹")
            return
        }
        guard !isSyncing else {
            AppLog("ℹ️ [CloudSync] syncNow 跳过：正在同步中")
            return
        }
        isSyncing = true
        syncState = .syncing
        statusMessage = "正在同步 iCloud 云盘..."
        AppLog("☁️ [CloudSync] 启动双向同步任务...")

        Task.detached(priority: .userInitiated) {
            guard let bookmarkData = UserDefaults.standard.data(forKey: self.bookmarkKey) else {
                await MainActor.run {
                    self.isSyncing = false
                    self.syncState = .error("书签数据丢失")
                    self.statusMessage = "同步失败：未找到目录书签"
                }
                return
            }

            var isStale = false
            guard let folderURL = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else {
                await MainActor.run {
                    self.isSyncing = false
                    self.syncState = .error("无法访问授权目录")
                    self.statusMessage = "同步失败：授权已失效，请重新选择文件夹"
                }
                return
            }

            if isStale {
                if let newBookmark = try? folderURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                    UserDefaults.standard.set(newBookmark, forKey: self.bookmarkKey)
                }
            }

            guard folderURL.startAccessingSecurityScopedResource() else {
                await MainActor.run {
                    self.isSyncing = false
                    self.syncState = .error("目录安全权限已过期")
                    self.statusMessage = "同步失败：目录无访问权限"
                }
                return
            }
            defer { folderURL.stopAccessingSecurityScopedResource() }

            let fileURL = folderURL.appendingPathComponent(self.syncFileName)
            let coordinator = NSFileCoordinator()
            var mergeCount = 0

            // 1. 协调读取云端文件
            if FileManager.default.fileExists(atPath: fileURL.path) {
                var readError: NSError?
                var loadedRecords: [Measurement]? = nil
                coordinator.coordinate(readingItemAt: fileURL, options: [], error: &readError) { readURL in
                    if let cloudData = try? Data(contentsOf: readURL),
                       let cloudRecords = try? JSONDecoder().decode([Measurement].self, from: cloudData) {
                        loadedRecords = cloudRecords
                    }
                }
                if let loadedRecords = loadedRecords {
                    mergeCount = await MainActor.run {
                        historyStore.merge(cloudRecords: loadedRecords)
                    }
                }
                if let readError = readError {
                    AppLog("⚠️ 协调读取云端文件警告: \(readError.localizedDescription)")
                }
            }

            // 2. 协调回写最新完整数据集至云端
            let currentRecords = await MainActor.run { historyStore.records }
            do {
                let encodedData = try JSONEncoder().encode(currentRecords)
                var writeError: NSError?
                coordinator.coordinate(writingItemAt: fileURL, options: [], error: &writeError) { writeURL in
                    do {
                        try encodedData.write(to: writeURL)
                    } catch {
                        AppLog("⚠️ 写入云端文件失败: \(error)")
                    }
                }

                let now = Date()
                let finalMergeCount = mergeCount
                await MainActor.run {
                    self.lastSyncTime = now
                    UserDefaults.standard.set(now, forKey: self.lastSyncKey)
                    self.isSyncing = false
                    self.syncState = .success
                    if finalMergeCount > 0 {
                        self.statusMessage = "同步成功，已合并 \(finalMergeCount) 条云端记录"
                    } else {
                        self.statusMessage = "已是最新（\(Self.dateFormatter.string(from: now))）"
                    }
                }
                AppLog("✅ iCloud 云盘同步成功完成")
            } catch {
                await MainActor.run {
                    self.isSyncing = false
                    self.syncState = .error(error.localizedDescription)
                    self.statusMessage = "同步失败：\(error.localizedDescription)"
                }
                AppLog("⚠️ 编码或写入云端文件失败: \(error)")
            }
        }
    }

    /// 当本地有新测量产生时，静默推送到绑定的 iCloud 云盘目录
    func uploadToCloud(records: [Measurement]) {
        guard isFolderBound,
              let bookmarkData = UserDefaults.standard.data(forKey: bookmarkKey) else { return }

        Task.detached(priority: .utility) {
            var isStale = false
            guard let folderURL = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ), folderURL.startAccessingSecurityScopedResource() else { return }
            defer { folderURL.stopAccessingSecurityScopedResource() }

            let fileURL = folderURL.appendingPathComponent(self.syncFileName)
            let coordinator = NSFileCoordinator()
            do {
                let data = try JSONEncoder().encode(records)
                var writeError: NSError?
                coordinator.coordinate(writingItemAt: fileURL, options: [], error: &writeError) { writeURL in
                    try? data.write(to: writeURL)
                }
                AppLog("☁️ 静默向 iCloud 云盘推送最新数据完成")
            } catch {
                AppLog("⚠️ 静默推送至 iCloud 云盘失败: \(error)")
            }
        }
    }
}
