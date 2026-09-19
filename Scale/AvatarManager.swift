import Foundation
import SwiftUI
import PhotosUI
import Combine

/// 管理用户头像：支持通过系统原生相册选择照片/拟我表情（Memoji），并持久化本地缓存。
/// 注：iOS 系统出于隐私保护，公开 API（HealthKit 与 Contacts）均禁止第三方应用直接静默读取 Apple ID 账号与系统名片头像（API 标记为 NA），
/// 因此通过 PhotosPicker 原生照片选取器让用户选择头像为 iOS 平台最佳原生实践。
@MainActor
final class AvatarManager: ObservableObject {
    static let shared = AvatarManager()

    @Published var avatarImage: UIImage? = nil

    private let cacheFileName = "user_avatar.jpg"

    private var cacheFileURL: URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return paths[0].appendingPathComponent(cacheFileName)
    }

    init() {
        loadCachedAvatar()
    }

    /// 从本地缓存加载已保存的头像
    func loadCachedAvatar() {
        guard let data = try? Data(contentsOf: cacheFileURL),
              let image = UIImage(data: data) else {
            return
        }
        self.avatarImage = image
    }

    /// 保存头像到本地文件缓存
    func saveAvatar(_ image: UIImage) {
        self.avatarImage = image
        if let data = image.jpegData(compressionQuality: 0.85) {
            try? data.write(to: cacheFileURL)
        }
    }

    /// 清除自定义头像缓存
    func clearAvatar() {
        self.avatarImage = nil
        try? FileManager.default.removeItem(at: cacheFileURL)
    }
}
