import Foundation
import Combine
import SwiftUI

/// 负责体脂秤历史测量记录的本地持久化存储与增删改查。
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var records: [Measurement] = []

    private let fileURL: URL

    init() {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let scaleDir = appSupport.appendingPathComponent("Scale", isDirectory: true)

        if !fileManager.fileExists(atPath: scaleDir.path) {
            try? fileManager.createDirectory(at: scaleDir, withIntermediateDirectories: true)
        }

        self.fileURL = scaleDir.appendingPathComponent("measurements_history.json")
        load()
    }

    /// 从本地磁盘加载所有历史记录
    func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            self.records = []
            return
        }

        do {
            let decoded = try JSONDecoder().decode([Measurement].self, from: data)
            // 按日期倒序排列（最新的在最前面）
            self.records = decoded.sorted(by: { $0.date > $1.date })
        } catch {
            print("⚠️ 读取历史测量记录失败: \(error)")
            self.records = []
        }
    }

    /// 保存一条新的测量记录
    func save(measurement: Measurement) {
        // 避免重复插入（如果已存在相同 ID 则更新）
        var updated = records.filter { $0.id != measurement.id }
        updated.insert(measurement, at: 0)
        updated.sort(by: { $0.date > $1.date })
        self.records = updated
        persist()
    }

    /// 删除指定位置的记录
    func delete(at offsets: IndexSet) {
        records.remove(atOffsets: offsets)
        persist()
    }

    /// 删除单条记录
    func delete(record: Measurement) {
        records.removeAll(where: { $0.id == record.id })
        persist()
    }

    /// 清空所有历史记录
    func clearAll() {
        records.removeAll()
        persist()
    }

    /// 与云端拉取到的记录做增量合并（以 UUID 去重，按测量时间倒序重排）
    @discardableResult
    func merge(cloudRecords: [Measurement]) -> Int {
        guard !cloudRecords.isEmpty else { return 0 }
        let existingIds = Set(records.map(\.id))
        let newItems = cloudRecords.filter { !existingIds.contains($0.id) }

        if !newItems.isEmpty {
            var combined = records
            combined.append(contentsOf: newItems)
            combined.sort(by: { $0.date > $1.date })
            self.records = combined
            persist()
        }
        return newItems.count
    }

    /// 将记录写回本地沙盒文件
    private func persist() {
        do {
            let data = try JSONEncoder().encode(records)
            try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
        } catch {
            print("⚠️ 写入历史记录文件失败: \(error)")
        }
    }
}
