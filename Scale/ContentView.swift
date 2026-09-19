import SwiftUI
import PhotosUI
import Charts

struct ContentView: View {
    @StateObject private var ble = BluetoothManager()
    @StateObject private var avatarManager = AvatarManager.shared
    @StateObject private var historyStore = HistoryStore.shared
    @StateObject private var cloudSync = CloudSyncManager.shared
    private let health = HealthKitManager()

    @Environment(\.scenePhase) private var scenePhase
    @State private var profile = UserProfile.load()
    @State private var showProfile = false
    @State private var healthMessage: String?
    @State private var showResult = false
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            measuringNavigationStack
                .tabItem {
                    Label("测量", systemImage: "scalemass.fill")
                }
                .tag(0)

            TrendHistoryView(
                historyStore: historyStore,
                cloudSync: cloudSync,
                profile: profile,
                onShowProfile: { showProfile = true },
                avatarView: { avatarButtonView }
            )
            .tabItem {
                Label("趋势", systemImage: "chart.xyaxis.line")
            }
            .tag(1)
        }
        .sheet(isPresented: $showProfile) {
            ProfileView(
                profile: $profile,
                health: health,
                avatarManager: avatarManager,
                cloudSync: cloudSync,
                historyStore: historyStore
            )
        }
    }

    private var measuringNavigationStack: some View {
        NavigationStack {
            measuringView
                .navigationTitle("体脂秤")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            ble.startScanning()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .accessibilityLabel("刷新搜索")
                    }

                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showProfile = true
                        } label: {
                            avatarButtonView
                        }
                        .accessibilityLabel("个人资料")
                    }
                }
                .navigationDestination(isPresented: $showResult) {
                    if let m = ble.lastMeasurement {
                        MeasurementResultView(
                            m: m,
                            profile: profile,
                            healthMessage: healthMessage,
                            onRefresh: {
                                showResult = false
                                ble.startMeasurement()
                            },
                            onShowProfile: {
                                showProfile = true
                            },
                            avatarView: {
                                avatarButtonView
                            }
                        )
                    }
                }
                .task {
                    await syncProfileFromHealth()
                    // 启动时主动开始扫描与连接体脂秤
                    if ble.lastMeasurement == nil {
                        ble.startScanning()
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        Task {
                            // 每次 App 切回前台均重新同步 Apple Health（保障年龄与身体信息随时间自动更新）
                            await syncProfileFromHealth()
                            if ble.lastMeasurement == nil && ble.state != .measuring && ble.state != .connected {
                                ble.startScanning()
                            }
                        }
                    }
                }
                .onChange(of: showResult) { _, isPresented in
                    if !isPresented {
                        ble.resetToReady()
                    }
                }
                .onAppear {
                    ble.onMeasurementReady = { m in
                        Task { @MainActor in
                            // 1. 自动写入本地持久化历史记录
                            historyStore.save(measurement: m)

                            // 2. 自动触发云端静默上传备份
                            cloudSync.uploadToCloud(records: historyStore.records)

                            // 3. 推栈展示测量结果
                            showResult = true

                            // 4. 写入 Apple「健康」
                            guard UserProfile.load().autoSyncHealth else {
                                healthMessage = nil
                                return
                            }
                            do {
                                try await health.save(m)
                                healthMessage = "已同步到「健康」App"
                            } catch {
                                healthMessage = "同步失败：\(error.localizedDescription)"
                            }
                        }
                    }
                }
        }
    }

    /// 导航栏右上角头像视图
    private var avatarButtonView: some View {
        Group {
            if let img = avatarManager.avatarImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 32, height: 32)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 1))
            } else {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 24))
                    .foregroundStyle(.primary)
            }
        }
    }

    /// 主动从 Apple「健康」拉取并更新个人最新信息（身高、最新计算的年龄、生理性别）
    private func syncProfileFromHealth() async {
        do {
            try await health.requestAuthorization()
            let data = try await health.fetchUserProfile()
            if data.hasAnyData {
                var updated = false
                if let h = data.heightCm, h != profile.heightCm {
                    profile.heightCm = h
                    updated = true
                }
                if let a = data.age, a != profile.age {
                    profile.age = a
                    updated = true
                }
                if let m = data.isMale, m != profile.isMale {
                    profile.isMale = m
                    updated = true
                }
                if updated {
                    profile.save()
                }
            }
        } catch {
            print("HealthKit 同步失败: \(error)")
        }
    }

    // MARK: - 测量中或准备就绪视图
    private var measuringView: some View {
        VStack(spacing: 24) {
            Spacer()
            statusCard
            Spacer()
            userProfilePromptCard
        }
        .padding()
    }

    private var statusCard: some View {
        VStack(spacing: 14) {
            if let w = ble.liveWeight, ble.lastMeasurement == nil {
                VStack(spacing: 4) {
                    Text(String(format: "%.2f", w))
                        .font(.system(size: 60, weight: .bold, design: .rounded))
                    Text("kg")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: statusIcon)
                    .font(.system(size: 52))
                    .foregroundStyle(statusColor)
                    .padding(.bottom, 6)
            }

            Text(statusText)
                .font(.headline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private var statusIcon: String {
        switch ble.state {
        case .idle: return "scalemass"
        case .poweredOff: return "bolt.slash"
        case .scanning: return "wave.3.forward"
        case .connecting: return "antenna.radiowaves.left.and.right"
        case .connected: return "checkmark.circle"
        case .measuring: return "figure.stand"
        case .done: return "checkmark.circle.fill"
        case .scanTimeout: return "arrow.clockwise.circle"
        case .bodyFatUnavailable: return "exclamationmark.triangle.fill"
        case .error: return "xmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch ble.state {
        case .idle: return .secondary
        case .poweredOff, .error: return .red
        case .scanning, .connecting: return .accentColor
        case .connected, .done: return .green
        case .measuring: return .blue
        case .scanTimeout, .bodyFatUnavailable: return .orange
        }
    }

    private var statusText: String {
        switch ble.state {
        case .idle: return "轻踩秤面唤醒体脂秤"
        case .poweredOff: return "请先打开手机蓝牙"
        case .scanning: return "正在寻找体脂秤…\n轻踩秤面即可唤醒"
        case .connecting: return "连接中…"
        case .connected: return "体脂秤已连接\n请赤脚站上秤，保持静止"
        case .measuring: return "正在测量中，请保持静止…"
        case .done: return "测量完成"
        case .scanTimeout: return "未找到体脂秤\n轻踩秤面唤醒后点击刷新"
        case .bodyFatUnavailable(let hint): return "测不出体脂：\(hint)"
        case .error(let msg): return msg
        }
    }

    private var userProfilePromptCard: some View {
        Button {
            showProfile = true
        } label: {
            HStack(spacing: 12) {
                if let img = avatarManager.avatarImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 40, height: 40)
                        .clipShape(Circle())
                } else {
                    Image(systemName: "person.text.rectangle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("当前参考身体资料")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(profile.isMale ? "男" : "女") · \(profile.age) 岁 · \(Int(profile.heightCm)) cm")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }


}

// MARK: - 测量结果独立详情视图（支持系统级右滑手势返回）
struct MeasurementResultView<AvatarContent: View>: View {
    let m: Measurement
    let profile: UserProfile
    let healthMessage: String?
    let onRefresh: () -> Void
    let onShowProfile: () -> Void
    @ViewBuilder let avatarView: () -> AvatarContent

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var historyStore = HistoryStore.shared

    private var chronologicalRecordsUpToM: [Measurement] {
        var list = historyStore.records.filter { $0.date <= m.date }
        if !list.contains(where: { $0.id == m.id }) {
            list.insert(m, at: 0)
            list.sort(by: { $0.date > $1.date })
        }
        return Array(list.prefix(7).reversed())
    }

    private var previousMeasurement: Measurement? {
        let list = historyStore.records.filter { $0.id != m.id && $0.date <= m.date }
        return list.first
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                heroWeightCard(m)

                RecentTrendCardView(
                    current: m,
                    records: chronologicalRecordsUpToM,
                    previous: previousMeasurement
                )

                // 1. 核心身体概览
                MetricSectionView(title: "核心概览", systemImage: "figure.walk") {
                    MetricCardView(title: "BMI", value: String(format: "%.1f", m.bmi), unit: "", rating: m.bmiRating)
                    MetricCardView(title: "体脂率", value: String(format: "%.1f", m.bodyFatPercent), unit: "%", rating: m.bodyFatRating(isMale: profile.isMale))
                    MetricCardView(title: "去脂体重", value: String(format: "%.1f", m.leanBodyMassKg), unit: "kg", rating: .normal)
                    MetricCardView(title: "基础代谢", value: "\(m.bmr)", unit: "kcal", rating: m.bmrRating(profile: profile))
                }

                // 2. 脂肪管理
                MetricSectionView(title: "脂肪管理", systemImage: "flame.fill") {
                    MetricCardView(title: "脂肪量", value: String(format: "%.1f", m.fatMassKg), unit: "kg", rating: m.fatMassRating)
                    MetricCardView(title: "皮下脂肪率", value: String(format: "%.1f", m.subcutaneousFatPercent), unit: "%", rating: m.subcutaneousFatRating(isMale: profile.isMale))
                    MetricCardView(title: "皮下脂肪量", value: String(format: "%.1f", m.subcutaneousFatMassKg), unit: "kg", rating: m.subcutaneousFatRating(isMale: profile.isMale))
                    MetricCardView(title: "内脏脂肪等级", value: String(format: "%.1f", m.visceralFat), unit: "级", rating: m.visceralFatRating)
                }

                // 3. 肌肉与骨骼指标
                MetricSectionView(title: "肌肉与骨骼", systemImage: "figure.strengthtraining.traditional") {
                    MetricCardView(title: "肌肉率", value: String(format: "%.1f", m.muscleRate), unit: "%", rating: m.muscleRating(isMale: profile.isMale))
                    MetricCardView(title: "肌肉量", value: String(format: "%.1f", m.muscleMassKg), unit: "kg", rating: m.muscleRating(isMale: profile.isMale))
                    MetricCardView(title: "骨骼肌率", value: String(format: "%.1f", m.skeletalMusclePercent), unit: "%", rating: m.skeletalMuscleRating(isMale: profile.isMale))
                    MetricCardView(title: "骨骼肌量", value: String(format: "%.1f", m.skeletalMuscleMassKg), unit: "kg", rating: m.skeletalMuscleRating(isMale: profile.isMale))
                    MetricCardView(title: "骨量占比", value: String(format: "%.1f", m.bonePercent), unit: "%", rating: m.boneRating(isMale: profile.isMale))
                    MetricCardView(title: "骨量", value: String(format: "%.1f", m.boneMassKg), unit: "kg", rating: m.boneRating(isMale: profile.isMale))
                }

                // 4. 水分与营养指标
                MetricSectionView(title: "水分与营养", systemImage: "drop.fill") {
                    MetricCardView(title: "体水分率", value: String(format: "%.1f", m.waterPercent), unit: "%", rating: m.waterRating(isMale: profile.isMale))
                    MetricCardView(title: "体水分量", value: String(format: "%.1f", m.waterMassKg), unit: "kg", rating: m.waterRating(isMale: profile.isMale))
                    MetricCardView(title: "蛋白量占比", value: String(format: "%.1f", m.proteinPercent), unit: "%", rating: m.proteinRating)
                    MetricCardView(title: "蛋白量含量", value: String(format: "%.1f", m.proteinMassKg), unit: "kg", rating: m.proteinRating)
                }

                // 重新测量主操作按钮
                Button {
                    onRefresh()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                        Text("重新测量")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
                }
                .padding(.top, 8)

                Text("身体成分指标基于生物电阻抗分析算法估算，仅供日常健康参考")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
            .padding()
        }
        .navigationTitle("测量结果")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                }
                .accessibilityLabel("返回")
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    onShowProfile()
                } label: {
                    avatarView()
                }
                .accessibilityLabel("个人资料")
            }
        }
    }

    private func heroWeightCard(_ m: Measurement) -> some View {
        VStack(spacing: 12) {
            Text("体重")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(String(format: "%.2f", m.weightKg))
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                Text("kg")
                    .font(.title2)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
            }

            if let prev = previousMeasurement {
                let diff = m.weightKg - prev.weightKg
                HStack(spacing: 4) {
                    Image(systemName: diff < 0 ? "arrow.down.right" : (diff > 0 ? "arrow.up.right" : "equal"))
                        .font(.system(size: 11, weight: .bold))
                    Text(diff == 0 ? "较上次持平" : String(format: "较上次 %+.2f kg", diff))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(diff < 0 ? Color.green : (diff > 0 ? Color.orange : Color.secondary))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    (diff < 0 ? Color.green : (diff > 0 ? Color.orange : Color.secondary)).opacity(0.12),
                    in: Capsule()
                )
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .bold))
                    Text("初次记录")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.12), in: Capsule())
            }

            if let healthMessage {
                HStack(spacing: 4) {
                    Image(systemName: "heart.fill")
                        .font(.caption2)
                        .foregroundStyle(.pink)
                    Text(healthMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - 测量结果近期趋势指标定义
private enum ResultTrendMetric: String, CaseIterable, Identifiable {
    case weight = "体重"
    case bodyFat = "体脂率"

    var id: String { rawValue }

    var unit: String {
        switch self {
        case .weight: return "kg"
        case .bodyFat: return "%"
        }
    }

    var chartColor: Color {
        switch self {
        case .weight: return Color.blue
        case .bodyFat: return Color.orange
        }
    }

    func value(from m: Measurement) -> Double {
        switch self {
        case .weight: return m.weightKg
        case .bodyFat: return m.bodyFatPercent
        }
    }
}

// MARK: - 测量结果「近期走势」原生卡片
private struct RecentTrendCardView: View {
    let current: Measurement
    let records: [Measurement]
    let previous: Measurement?

    @State private var selectedMetric: ResultTrendMetric = .weight

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 顶栏：标题与分段切换
            HStack {
                Label("近期走势", systemImage: "chart.line.uptrend.xyaxis")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer()

                Picker("指标切换", selection: $selectedMetric) {
                    ForEach(ResultTrendMetric.allCases) { metric in
                        Text(metric.rawValue).tag(metric)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 130)
            }

            // 统计指标行
            statsRow

            // 图表展示
            if records.count >= 2 {
                miniChart
            } else {
                singleRecordHint
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var statsRow: some View {
        let values = records.map { selectedMetric.value(from: $0) }
        let latestVal = selectedMetric.value(from: current)
        let minVal = values.min() ?? latestVal
        let maxVal = values.max() ?? latestVal
        let diff: Double = {
            if let prev = previous {
                return latestVal - selectedMetric.value(from: prev)
            }
            return 0
        }()

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("本次数据")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(String(format: selectedMetric == .weight ? "%.2f" : "%.1f", latestVal))
                        .font(.system(.body, design: .rounded, weight: .bold))
                    Text(selectedMetric.unit)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()
                .frame(height: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text("较上次")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if previous != nil {
                    HStack(spacing: 2) {
                        if diff != 0 {
                            Image(systemName: diff > 0 ? "arrow.up.right" : "arrow.down.right")
                                .font(.caption2)
                                .foregroundStyle(diff > 0 ? Color.orange : Color.green)
                        }
                        Text(diff == 0 ? "持平" : String(format: selectedMetric == .weight ? "%+.2f%@" : "%+.1f%@", diff, selectedMetric.unit))
                            .font(.system(.footnote, design: .rounded, weight: .semibold))
                            .foregroundStyle(diff == 0 ? .secondary : (diff > 0 ? Color.orange : Color.green))
                    }
                } else {
                    Text("首次测量")
                        .font(.system(.footnote, design: .rounded, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()
                .frame(height: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text("近\(records.count)次区间")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(String(format: selectedMetric == .weight ? "%.1f - %.1f" : "%.1f - %.1f", minVal, maxVal))
                    .font(.system(.footnote, design: .rounded, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var miniChart: some View {
        let color = selectedMetric.chartColor
        let values = records.map { selectedMetric.value(from: $0) }
        let minRaw = values.min() ?? 0
        let maxRaw = values.max() ?? 100
        let span = max(maxRaw - minRaw, selectedMetric == .weight ? 1.0 : 0.5)
        let minVal = max(0, minRaw - span * 0.25)
        let maxVal = maxRaw + span * 0.25

        return Chart {
            // 渐变面积图
            ForEach(records) { r in
                let val = selectedMetric.value(from: r)
                AreaMark(
                    x: .value("时间", r.date),
                    yStart: .value("基准", minVal),
                    yEnd: .value("数值", val)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(
                    LinearGradient(
                        colors: [color.opacity(0.22), color.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }

            // 平滑曲线
            ForEach(records) { r in
                let val = selectedMetric.value(from: r)
                LineMark(
                    x: .value("时间", r.date),
                    y: .value("数值", val)
                )
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 2.5))
                .foregroundStyle(color)
            }

            // 普通数据点
            ForEach(records.filter { $0.id != current.id }) { r in
                let val = selectedMetric.value(from: r)
                PointMark(
                    x: .value("时间", r.date),
                    y: .value("数值", val)
                )
                .foregroundStyle(color)
                .symbolSize(32)
            }

            // 本次测量专属高亮点
            let currentVal = selectedMetric.value(from: current)
            PointMark(
                x: .value("时间", current.date),
                y: .value("数值", currentVal)
            )
            .foregroundStyle(color)
            .symbolSize(75)
            .annotation(position: .top, alignment: .center) {
                Text("本次")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(color, in: Capsule())
                    .offset(y: -4)
            }
        }
        .chartYScale(domain: minVal...maxVal)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: min(records.count, 5))) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    .foregroundStyle(Color.secondary.opacity(0.2))
                AxisTick()
                if let date = value.as(Date.self) {
                    AxisValueLabel {
                        Text(miniChartDateFormatter.string(from: date))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    .foregroundStyle(Color.secondary.opacity(0.2))
                AxisValueLabel()
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 145)
        .padding(.top, 6)
    }

    private var singleRecordHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.subheadline)
                .foregroundStyle(Color.accentColor)
            Text("已记录本次测量。持续使用体脂秤测量，将在此呈现近7次身体成分走势曲线。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private let miniChartDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "M/d"
    return formatter
}()

// MARK: - 支持从屏幕任意位置（包括中央）向右滑动的全屏原生返回手势
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        setupFullScreenPopGesture()
    }

    private func setupFullScreenPopGesture() {
        guard let popGesture = interactivePopGestureRecognizer,
              let targets = popGesture.value(forKey: "targets") as? [NSObject],
              let targetObj = targets.first,
              let target = targetObj.value(forKey: "target") else {
            interactivePopGestureRecognizer?.delegate = self
            return
        }

        let action = Selector(("handleNavigationTransition:"))
        let fullScreenPan = UIPanGestureRecognizer(target: target, action: action)
        fullScreenPan.delegate = self
        view.addGestureRecognizer(fullScreenPan)
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard viewControllers.count > 1 else { return false }
        if let pan = gestureRecognizer as? UIPanGestureRecognizer {
            let translation = pan.translation(in: view)
            let velocity = pan.velocity(in: view)
            // 必须是从左往右滑（translation.x > 0 且 velocity.x > 0），且水平位移大于垂直位移，避免拦截 ScrollView 竖向滚动
            return translation.x > 0 && velocity.x > 0 && abs(translation.x) > abs(translation.y)
        }
        return true
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }
}

// MARK: - 评级徽章
struct RatingBadgeView: View {
    let rating: HealthRating

    var color: Color {
        switch rating {
        case .optimal:
            return .cyan
        case .normal:
            return .green
        case .low, .high:
            return .orange
        case .veryHigh:
            return .red
        }
    }

    var body: some View {
        Text(rating.rawValue)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }
}

// MARK: - 单项指标卡片
struct MetricCardView: View {
    let title: String
    let value: String
    let unit: String
    var rating: HealthRating? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let rating {
                    RatingBadgeView(rating: rating)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundStyle(.primary)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - 指标分组容器
struct MetricSectionView<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 4)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                content()
            }
        }
        .padding(14)
        .background(Color(.systemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - 资料设置
struct ProfileView: View {
    @Binding var profile: UserProfile
    let health: HealthKitManager
    @ObservedObject var avatarManager: AvatarManager
    @ObservedObject var cloudSync: CloudSyncManager
    @ObservedObject var historyStore: HistoryStore
    @Environment(\.dismiss) private var dismiss

    @State private var isSyncingHealth = false
    @State private var healthSyncStatus: String?
    @State private var healthSyncSuccess: Bool = true

    @State private var selectedPhotoItem: PhotosPickerItem? = nil

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - 用户头像（Apple 原生居中大头像设计）
                Section {
                    VStack(spacing: 8) {
                        ZStack(alignment: .bottomTrailing) {
                            if let img = avatarManager.avatarImage {
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 80, height: 80)
                                    .clipShape(Circle())
                                    .overlay(Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                                    .shadow(color: Color.black.opacity(0.08), radius: 6, x: 0, y: 3)
                            } else {
                                Image(systemName: "person.crop.circle.fill")
                                    .font(.system(size: 80))
                                    .foregroundStyle(.tertiary)
                            }

                            // 底部角标相机徽章按钮
                            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                                Image(systemName: "camera.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 28, height: 28)
                                    .background(Color.accentColor, in: Circle())
                                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                                    .shadow(color: Color.black.opacity(0.12), radius: 3, x: 0, y: 2)
                            }
                            .accessibilityLabel("拍摄或选择照片")
                        }
                        .padding(.top, 4)

                        // 原生菜单：选择照片或恢复默认
                        Menu {
                            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                                Label("从相册选择照片", systemImage: "photo.on.rectangle")
                            }

                            if avatarManager.avatarImage != nil {
                                Button(role: .destructive) {
                                    avatarManager.clearAvatar()
                                } label: {
                                    Label("恢复默认头像", systemImage: "trash")
                                }
                            }
                        } label: {
                            Text("编辑头像")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .padding(.vertical, 4)
                }

                // MARK: - iCloud 云端同步
                Section {
                    HStack {
                        Image(systemName: "icloud.fill")
                            .font(.title3)
                            .foregroundStyle(Color.accentColor)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("iCloud 跨设备同步")
                                .font(.body)
                            Text(cloudSync.statusMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button {
                            cloudSync.syncNow(historyStore: historyStore)
                        } label: {
                            if cloudSync.isSyncing {
                                ProgressView()
                            } else {
                                Text("立即同步")
                                    .font(.subheadline)
                            }
                        }
                        .disabled(cloudSync.isSyncing)
                    }
                } header: {
                    Text("云端同步")
                } footer: {
                    Text("历史测量数据将通过 iCloud 在您的各台 iPhone 和 iPad 间自动加密同步。")
                }

                // MARK: - Apple「健康」同步
                Section {
                    Button {
                        syncFromHealth()
                    } label: {
                        HStack {
                            Image(systemName: "heart.text.square.fill")
                                .font(.title3)
                                .foregroundStyle(.pink)
                            Text("从 Apple「健康」同步资料")
                                .foregroundStyle(.primary)
                            Spacer()
                            if isSyncingHealth {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isSyncingHealth)

                    if let healthSyncStatus {
                        Text(healthSyncStatus)
                            .font(.footnote)
                            .foregroundStyle(healthSyncSuccess ? Color.secondary : Color.red)
                    }
                } header: {
                    Text("Apple「健康」")
                } footer: {
                    Text("App 启动或回到前台时会自动从「健康」同步最新年龄与身体数据。您也可点击上方按钮随时手动同步。")
                }

                // MARK: - 身体资料
                Section("身体资料（用于精准估算体脂）") {
                    Stepper("身高：\(Int(profile.heightCm)) cm",
                            value: $profile.heightCm, in: 80...230)
                    Stepper("年龄：\(profile.age) 岁",
                            value: $profile.age, in: 5...120)
                    Picker("性别", selection: $profile.isMale) {
                        Text("男").tag(true)
                        Text("女").tag(false)
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Toggle("测量后自动写入「健康」", isOn: $profile.autoSyncHealth)
                } footer: {
                    Text("开启后，每次测量完成将自动把体重、体脂率、BMI、去脂体重同步到 Apple「健康」App。")
                }
            }
            .navigationTitle("我的资料")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        profile.save()
                        dismiss()
                    }
                }
            }
            .onChange(of: selectedPhotoItem) { _, newItem in
                guard let newItem else { return }
                Task {
                    if let data = try? await newItem.loadTransferable(type: Data.self),
                       let img = UIImage(data: data) {
                        avatarManager.saveAvatar(img)
                    }
                }
            }
        }
    }

    private func syncFromHealth() {
        Task {
            isSyncingHealth = true
            defer { isSyncingHealth = false }
            do {
                try await health.requestAuthorization()
                let data = try await health.fetchUserProfile()
                guard data.hasAnyData else {
                    healthSyncSuccess = false
                    healthSyncStatus = "未在 Apple「健康」中找到身体资料，请先在「健康」App 中填写身高、生日或性别。"
                    return
                }
                var syncedItems: [String] = []
                if let h = data.heightCm {
                    profile.heightCm = h
                    syncedItems.append("身高 \(Int(h))cm")
                }
                if let a = data.age {
                    profile.age = a
                    syncedItems.append("年龄 \(a)岁")
                }
                if let m = data.isMale {
                    profile.isMale = m
                    syncedItems.append("性别 \(m ? "男" : "女")")
                }
                profile.save()
                healthSyncSuccess = true
                healthSyncStatus = "已同步：" + syncedItems.joined(separator: "，")
            } catch {
                healthSyncSuccess = false
                healthSyncStatus = "同步失败：\(error.localizedDescription)"
            }
        }
    }
}
