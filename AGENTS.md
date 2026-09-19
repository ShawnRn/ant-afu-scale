# AGENTS.md · 协作与工程规范指南

本项目是基于原生 SwiftUI 与 CoreBluetooth 开发的 **Scale（蚂蚁阿福体脂秤）** iOS 客户端。
本文档面向参与本项目演进与维护的 AI Agents 及开发者，阐述工程架构、设计哲学、核心模块及开发规范。

---

## 1. 项目定位与设计哲学

- **纯原生性能优先**：零第三方庞大依赖，全面采用 Apple 官方最新原生技术栈（SwiftUI, CoreBluetooth, HealthKit, Swift Charts, NSUbiquitousKeyValueStore）。
- **极简通透美学**：遵循 Apple Human Interface Guidelines（HIG），无感蓝牙自动发现连接、丝滑 120Hz 高刷图表流转、原生触觉与快照交互。
- **隐私与本地化优先**：核心 BIA 身体成分算法完全本地离线计算；历史数据持久化于应用沙盒，支持端到端 iCloud 无感多端同步。

---

## 2. 代码库核心架构与模块全景

```
Scale/
├── BodyScaleApp.swift        # App 生命周期入口与 AppIntents 依赖配置
├── ContentView.swift         # 主交互中枢：TabView 容器、极简上秤测量页、测量结果详情页（含近期趋势卡片）及个人资料设置
├── TrendHistoryView.swift    # 趋势分析与历史列表：Swift Charts 走势图、分段指标切换、解耦懒加载流水列表与长按快照
├── HistoryStore.swift        # 本地历史持久化存储：沙盒 measurements_history.json 增删改查、排序与去重
├── CloudSyncManager.swift    # iCloud 增量双向同步引擎：基于 NSUbiquitousKeyValueStore 的静默同步与状态机
├── BluetoothManager.swift    # CoreBluetooth 通信管线：自动扫描重连、服务与特征订阅、稳定重量判定
├── Scale27.swift             # 沃莱 "Scale27" 协议编解码：包头校验、阻抗解析与用户信息下发包构造
├── BodyComposition.swift     # 18 项身体成分 BIA 估算算法（体脂、肌肉、骨量、内脏脂肪、去脂体重等）
├── HealthKitManager.swift    # Apple「健康」双向桥接：读取个人生理资料、自动写入测量指标
├── AvatarManager.swift       # 个人头像持久化管理器：沙盒图片存储与内存缓存
└── UserProfile.swift         # 用户生理资料模型（身高、年龄、生理性别）与 UserDefaults 持久化
```

---

## 3. 开发准则与约束

参与本项目修改与扩展时，必须严格遵守以下规则：

### 3.1 零警告（Zero Warnings）交付
- 所有的改动必须确保在严格模式下编译通过：
  ```bash
  xcrun -sdk iphoneos swiftc -target arm64-apple-ios26.0 -warnings-as-errors -c Scale/*.swift -parse-as-library
  ```
- 严禁引入任何编译器 Warning 或 Xcode 构建 Warning。
- 严禁使用任何已被标记为 `@deprecated` 的 API（例如：禁止使用单参数 `.onChange(of:perform:)`，必须使用 iOS 17+ 的双参数闭包 `.onChange(of:initial:)` 或 `.onChange(of:) { _, newValue in }`）。

### 3.2 界面与语言规范
- **语言**：UI 界面文字、日志注释、技术文档（`AGENTS.md`、`README.md`、`implementation_plan.md`、`walkthrough.md` 等）必须使用 **简体中文**。
- **UI 纯粹性**：避免在正式 UI 文本中随意硬编码 Emoji，优先使用 SF Symbols 与 Apple 原生语义样式。
- **Toolbar 按钮形态**：当在 NavigationBar 工具栏中放置正圆形按钮时，必须显式附加 `.buttonBorderShape(.circle)`，杜绝容器因横向扩展而形变为横向胶囊/椭圆。

### 3.3 图表与渲染性能优化
- 在使用 `Swift Charts` 时，曲线拟合算法推荐使用 **`.monotone`（单调三次 Hermite 曲线）**，以取得最佳性能并避免数值过冲。
- 分段选择器（Segmented Control）与图表联动时，必须注意组件解耦隔离（通过独立子 View + `.id` 刷新域），阻断跨维度图元的插值补间开销，避免主线程掉帧。
- 历史流水列表务必使用 `LazyVStack`，结合全局静态 `DateFormatter`，避免在列表单元格重绘时重复进行高开销的对象实例化。

### 3.4 签名身份与 iPhone 17 Pro 专用自签

- 必须同时校验 App 的 `CFBundleIdentifier`、代码签名中的 `application-identifier` 以及嵌入描述文件的 `application-identifier`；三者的 Bundle ID 部分必须完全一致。
- 免费 Apple ID 7 天签名使用工程默认 Bundle ID `shuhui.scaleapp`。
- Shawn 的 iPhone 17 Pro（UDID `00008150-001E58CA3E84401C`）专用自签描述文件授权 Bundle ID `app.tourmaline5269.brown6028`，Team ID 为 `8CAEUC6576`。生成给全能签的 IPA 时，必须在编译阶段显式传入 `PRODUCT_BUNDLE_IDENTIFIER=app.tourmaline5269.brown6028`，不得在签名后仅修改外层 `Info.plist`。
- 已经过真机验证：若外层 Bundle ID 为 `shuhui.scaleapp`，但签名 App ID 为 `8CAEUC6576.app.tourmaline5269.brown6028`，文件选择器虽能展示，但选择 iCloud 文件夹时会无法正常完成授权。该现象不是同步 merge 死锁，也不应通过改写文件选择器业务逻辑规避。
- 全能签中必须保留专用 IPA 自带的 `app.tourmaline5269.brown6028`，禁止再改回 `shuhui.scaleapp`。签名后必须运行 `Scripts/verify-iphone17pro-signature.sh <已签名 IPA>` 复核身份、HealthKit 能力与签名完整性。
- 两种签名的 Team ID 不同，iOS 会将它们视为不同应用身份。首次切换时需重新授权 Apple「健康」并重新选择 iCloud 同步文件夹，不得承诺继承旧签名身份的系统权限或安全范围书签。
- 不得将 p12 密码、私钥或临时 Keychain 提交到仓库，也不得在构建日志中输出这些敏感信息。

---

## 4. 验证与构建指令

每完成一项需求或修复后，务必依次运行以下验证：

1. **Swift 编译器零警告检查**：
   ```bash
   xcrun -sdk iphoneos swiftc -target arm64-apple-ios26.0 -warnings-as-errors -c Scale/*.swift -parse-as-library
   ```
2. **Xcode 真机构建**：
   ```bash
   xcodebuild -project Scale.xcodeproj -scheme "Scale App" -destination 'id=00008150-001E58CA3E84401C' CODE_SIGNING_ALLOWED=NO build
   ```
3. **扫描最新构建日志确保 Warning 计数为 0**。

### 4.1 iPhone 17 Pro 专用自签工作流

为 Shawn 的 iPhone 17 Pro 制作自签包时，必须使用专用工作流 [`.agent/workflows/iphone17-pro-self-sign.md`](.agent/workflows/iphone17-pro-self-sign.md)，禁止直接将默认 `shuhui.scaleapp` IPA 交给全能签。
