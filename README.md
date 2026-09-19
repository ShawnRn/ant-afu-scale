<div align="center">

<img src="Scale/Assets.xcassets/AppIcon.appiconset/Scale_1024.png" width="128" alt="Scale App Icon" />

# Scale · 蚂蚁阿福体脂秤

一个纯原生 iOS 体脂秤应用，通过蓝牙低功耗（BLE）直连蚂蚁阿福（沃莱）体脂秤，读取实时体重与生物阻抗，本地高精度算法估算 18 项身体成分，支持 Swift Charts 平滑趋势分析、iCloud 无感云端同步，并双向联动 Apple「健康」。

</div>

---

## ✨ 核心特性

- **极简无感直连**：无需点击任何多余按钮，轻踩唤醒体脂秤即可通过 CoreBluetooth 自动扫描并直连（服务 UUID `FFB0`），记住常用设备秒级回连。
- **协议深度解析**：完整支持沃莱 "Scale27" 蓝牙协议编解码，自动下发用户身体资料触发高精度交流测脂，实时锁定稳定读数。
- **18 项身体成分本地估算**：纯离线运行生物电阻抗（BIA）算法，精准估算体脂率、BMI、去脂体重、肌肉量、骨量、内脏脂肪等级、体水分率、基础代谢等全面生理指标。
- **Swift Charts 趋势分析**：
  - 基于 iOS 原生 `Charts` 打造，使用 `.monotone` 单调 Hermite 平滑曲线与渐变区域图；
  - 涵盖近 7 次、近 30 次与全部历史跨度；
  - 支持在「体重」、「体脂率」、「肌肉量」、「内脏脂肪」、「体水分率」之间自由切换分析；
  - 测量完成界面搭载「近期走势」卡片与「较上次变化」即时微胶囊反馈，折线图高亮标记本次测量。
- **iCloud 云端跨设备同步**：基于 `NSUbiquitousKeyValueStore` 实现端到端增量同步，支持多设备静默同步与实时状态指示（空闲、同步中、完成、错误），离线时自动优雅降级。
- **Apple「健康」双向联动**：
  - 测量完成后静默写入体重、体脂率、BMI、去脂体重；
  - 首次或按需从「健康」自动拉取最新的身高、生理性别与实际年龄，免去手动配置。
- **高质感 Apple 原生交互**：
  - 支持自定义个人大头像持久化存储；
  - 历史记录支持长按唤起完整功能菜单（查看详情、拷贝数据、删除记录）并呈现精致的**快照卡片预览**；
  - 页面支持全屏从任意位置边缘与中央平滑右滑返回。

> ⚠️ 体脂等身体成分为基于体脂秤硬件提供的原始阻抗通过本地公式估算，与原厂 App 的计算模型可能略有出入，仅供日常健身健康管理参考。

---

## 📱 使用方法

本项目未上架 App Store，可下载打包好的 IPA 后通过自有开发者账号或工具自行安装到 iPhone。整体流程：**下载 IPA → 签名 → 安装 → 首次运行授权**。

### 1. 下载 IPA

从 Releases 下载最新安装包：

> 📦 [Scale.v0.1.ipa](https://github.com/ShawnRn/ant-afu-scale/releases)

---

### 2A. 自签名（免费，证书 7 天有效）

用普通 Apple ID（免费个人开发者）给 IPA 签名。证书有 **7 天有效期**，到期后需重新签名一次：

需要：一台电脑（Windows / macOS）+ 数据线 + 一个 Apple ID。

以 **Sideloadly**（[sideloadly.io](https://sideloadly.io)）为例：

1. 电脑安装好 Sideloadly，数据线连接 iPhone 并点击「信任此电脑」；
2. 打开 Sideloadly，将 `Scale.ipa` 拖入；
3. 在 Apple account 输入你的 Apple ID，点击 **Start** 并输入密码；
4. 进度完成后即可在手机上看到 App。

> AltStore、Feather、爱思助手等工具同理。

---

### 2B. 开发者账号代签（有效期约 1 年）

通过 99 美元/年的 Apple 开发者账号签名，有效期约为 1 年：

1. 提供 iPhone 的 **UDID**（设备唯一标识）；
2. 获取签名的证书（p12）与描述文件（mobileprovision）；
3. 使用 [**zsign**](https://github.com/zhlynn/zsign) 等支持修改 Bundle ID 的工具进行重签名，**必须把 Bundle ID 更改为描述文件中授权的 ID**：

   ```bash
   zsign -k cert.p12 -p 证书密码 -m profile.mobileprovision -b 授权BundleID -o Scale-signed.ipa Scale.ipa
   ```

4. 将签好的 IPA 安装至手机。

> ⚠️ **注意**：切勿直接使用第三方助手工具默认的「快捷签名」，若未同步修改 Bundle ID，iOS 会判定 entitlements 整体失效，导致 `Missing com.apple.developer.healthkit entitlement` 而无法读写苹果健康。

---

### 3. 首次运行配置

1. **信任证书**：若提示「未受信任的开发者」，前往 *设置 → 通用 → VPN 与设备管理* 选择信任；
2. **开发者模式**（iOS 16+）：前往 *设置 → 隐私与安全性 → 开发者模式* 开启并重启手机；
3. **权限授予**：
   - **蓝牙**：连接体脂秤必须权限；
   - **健康**：将数据自动同步至 Apple Health（可在「我的资料」中随时控制开关）；
4. **开始测量**：确保手机蓝牙开启，光脚站上体脂秤保持静止，读数稳定后自动保存并展示完整分析报告。

---

## 🛠️ 项目架构

| 文件 | 职责说明 |
| --- | --- |
| [ContentView.swift](Scale/ContentView.swift) | 主交互界面：测量状态、测量结果页（含近期走势图表与对比胶囊）、个人资料页 |
| [TrendHistoryView.swift](Scale/TrendHistoryView.swift) | 趋势与历史：Swift Charts 平滑图表、多指标/时间分段器、解耦懒加载流水列表与长按快照 |
| [HistoryStore.swift](Scale/HistoryStore.swift) | 本地持久化存储引擎：沙盒 JSON 数据读取、写入、排序去重与删除 |
| [CloudSyncManager.swift](Scale/CloudSyncManager.swift) | iCloud 增量双向同步：跨设备同步状态机、后台通知监听与优雅降级 |
| [BluetoothManager.swift](Scale/BluetoothManager.swift) | CoreBluetooth 通信：自动扫描连接、状态管理与稳定重量防抖判定 |
| [Scale27.swift](Scale/Scale27.swift) | 沃莱 "Scale27" 协议层：20 字节数据包解包、阻抗归一化与控制包封装 |
| [BodyComposition.swift](Scale/BodyComposition.swift) | 18 项身体成分生物阻抗估算算法模型与参考标准区间 |
| [HealthKitManager.swift](Scale/HealthKitManager.swift) | Apple「健康」写入（体重、体脂率、BMI、去脂体重）与生理信息读取 |
| [AvatarManager.swift](Scale/AvatarManager.swift) | 原生个人头像沙盒存储与缓存管理器 |
| [UserProfile.swift](Scale/UserProfile.swift) | 用户生理数据模型（身高、年龄、性别）持久化 |
| [AGENTS.md](AGENTS.md) | AI Agents 与工程开发指南、零警告规范与设计模式说明 |

---

## 🤝 致谢与参考

本项目的蓝牙通信协议与阻抗估算算法借鉴自开源项目 [`ant-afu-welland-scale`](https://github.com/Mzdyl/ant-afu-welland-scale)（基于 Python 的 macOS 命令行读秤工具）。本项目将其协议编解码与核心算法完整重构为原生 Swift 实现，并全面融入 iOS 生态体验。
