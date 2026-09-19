import Foundation
import Combine

/// iCloud 同步状态
enum CloudSyncState: Equatable {
    case idle
    case syncing
    case success
    case error(String)
}

/// 负责体脂秤历史测量数据的 iCloud 跨设备自动同步与合并。
/// 采用「本地优先 + NSUbiquitousKeyValueStore 增量双向同步」架构。
@MainActor
final class CloudSyncManager: ObservableObject {
    static let shared = CloudSyncManager()

    private let cloudKey = "cloud_scale_measurements_v1"
    private let lastSyncKey = "cloud_scale_last_sync_time"

    @Published var isSyncing: Bool = false
    @Published var syncState: CloudSyncState = .idle
    @Published var lastSyncTime: Date? = nil
    @Published var statusMessage: String = "未同步"
    @Published var isCloudAvailable: Bool = true

    private var cancellables = Set<AnyCancellable>()

    init() {
        // 从本地加载上次同步时间戳
        if let ts = UserDefaults.standard.object(forKey: lastSyncKey) as? Date {
            self.lastSyncTime = ts
            self.syncState = .success
            self.statusMessage = "上次同步：" + Self.formatDate(ts)
        }

        // 监听云端从其他设备推送过来的变更通知
        NotificationCenter.default.publisher(for: NSUbiquitousKeyValueStore.didChangeExternallyNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.handleCloudChanges()
            }
            .store(in: &cancellables)

        // 首次启动时尝试同步
        NSUbiquitousKeyValueStore.default.synchronize()
    }

    /// 执行双向同步：拉取云端新记录合并入本地，并将本地最新全量记录同步至云端
    func syncNow(historyStore: HistoryStore) {
        guard !isSyncing else { return }
        isSyncing = true
        syncState = .syncing
        statusMessage = "正在同步 iCloud..."

        Task {
            // 平滑视觉体验，避免菊花一闪即逝
            try? await Task.sleep(nanoseconds: 350_000_000)

            do {
                // 1. 同步云端存储
                NSUbiquitousKeyValueStore.default.synchronize()

                // 2. 从云端拉取数据并合并到本地
                let cloudRecords = try fetchCloudRecords()
                let newCount = historyStore.merge(cloudRecords: cloudRecords)

                // 3. 将本地完整的最新记录集上传到云端
                try uploadToCloudInternal(records: historyStore.records)

                let now = Date()
                self.lastSyncTime = now
                UserDefaults.standard.set(now, forKey: lastSyncKey)
                self.isSyncing = false
                self.syncState = .success

                if newCount > 0 {
                    self.statusMessage = "同步完成，自云端获取了 \(newCount) 条新记录"
                } else {
                    self.statusMessage = "已是最新（\(Self.formatDate(now))）"
                }
            } catch {
                self.isSyncing = false
                self.syncState = .error(error.localizedDescription)
                self.statusMessage = "同步失败：\(error.localizedDescription)"
                AppLog("⚠️ iCloud 同步失败: \(error)")
            }
        }
    }

    /// 当本地有新测量产生时，在后台静默推送到云端
    func uploadToCloud(records: [Measurement]) {
        do {
            try uploadToCloudInternal(records: records)
            self.syncState = .success
        } catch {
            self.syncState = .error(error.localizedDescription)
            AppLog("⚠️ 上传至 iCloud 失败: \(error)")
        }
    }

    private func uploadToCloudInternal(records: [Measurement]) throws {
        let data = try JSONEncoder().encode(records)
        NSUbiquitousKeyValueStore.default.set(data, forKey: cloudKey)
        NSUbiquitousKeyValueStore.default.synchronize()
        let now = Date()
        self.lastSyncTime = now
        UserDefaults.standard.set(now, forKey: lastSyncKey)
    }

    /// 从云端解码测量记录
    private func fetchCloudRecords() throws -> [Measurement] {
        guard let data = NSUbiquitousKeyValueStore.default.data(forKey: cloudKey) else {
            return []
        }
        do {
            let records = try JSONDecoder().decode([Measurement].self, from: data)
            return records
        } catch {
            AppLog("⚠️ 解析云端数据失败: \(error)")
            throw error
        }
    }

    /// 接收到外部云端变更通知时的处理
    private func handleCloudChanges() {
        do {
            let cloudRecords = try fetchCloudRecords()
            let count = HistoryStore.shared.merge(cloudRecords: cloudRecords)
            let now = Date()
            self.lastSyncTime = now
            self.syncState = .success
            UserDefaults.standard.set(now, forKey: lastSyncKey)
            if count > 0 {
                self.statusMessage = "已从其他设备同步 \(count) 条记录"
            }
        } catch {
            self.syncState = .error(error.localizedDescription)
            AppLog("⚠️ 响应云端变更失败: \(error)")
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    private static func formatDate(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }
}
