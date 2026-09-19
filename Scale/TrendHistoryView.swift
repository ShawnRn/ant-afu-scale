import SwiftUI
import Charts

/// 趋势分析关注的身体指标
enum TrendMetric: String, CaseIterable, Identifiable {
    case weight = "体重"
    case bodyFat = "体脂率"
    case muscle = "肌肉量"
    case visceralFat = "内脏脂肪"
    case water = "水分率"

    var id: String { rawValue }

    var unit: String {
        switch self {
        case .weight, .muscle: return "kg"
        case .bodyFat, .water: return "%"
        case .visceralFat: return "级"
        }
    }

    func value(from m: Measurement) -> Double {
        switch self {
        case .weight: return m.weightKg
        case .bodyFat: return m.bodyFatPercent
        case .muscle: return m.muscleMassKg
        case .visceralFat: return m.visceralFat
        case .water: return m.waterPercent
        }
    }

    func value(from r: DailyTrendRecord) -> Double {
        switch self {
        case .weight: return r.weightKg
        case .bodyFat: return r.bodyFatPercent
        case .muscle: return r.muscleMassKg
        case .visceralFat: return r.visceralFat
        case .water: return r.waterPercent
        }
    }

    var chartColor: Color {
        switch self {
        case .weight: return .blue
        case .bodyFat: return .orange
        case .muscle: return .purple
        case .visceralFat: return .red
        case .water: return .cyan
        }
    }
}

/// 按自然日聚合的身体测量记录点（解决同日多次测量导致的重复打点与锯齿折线）
struct DailyTrendRecord: Identifiable, Equatable {
    let id: Date // 当天 00:00:00 (startOfDay)，用于 X 轴自然日刻度严格对齐
    let date: Date // 当天代表记录（最新一次测量）的实际时间戳
    let weightKg: Double
    let bodyFatPercent: Double
    let muscleMassKg: Double
    let visceralFat: Double
    let waterPercent: Double
    let bmi: Double
    let countOfDay: Int // 当天测量次数
    let sourceRecord: Measurement // 当天最新一条原始记录

    static func == (lhs: DailyTrendRecord, rhs: DailyTrendRecord) -> Bool {
        lhs.id == rhs.id &&
        lhs.date == rhs.date &&
        lhs.weightKg == rhs.weightKg &&
        lhs.bodyFatPercent == rhs.bodyFatPercent &&
        lhs.countOfDay == rhs.countOfDay
    }
}

/// 时间/记录跨度范围
enum TrendTimeRange: String, CaseIterable, Identifiable {
    case recent7 = "近7天"
    case recent30 = "近30天"
    case all = "全部"

    var id: String { rawValue }
}

/// 趋势页面分批渲染阶段（保障 TabView 切换动画 120Hz 满帧秒切）
enum TrendRenderPhase: Int, Comparable {
    case skeleton = 0 // 阶段 0：仅顶栏控制器与骨架占位，主线程 0 阻塞完成切页
    case summary = 1  // 阶段 1：展示统计摘要（当前最新、较前日、区间）
    case chart = 2    // 阶段 2：淡入 Swift Charts 趋势折线图
    case full = 3     // 阶段 3：挂载完整历史记录流水列表

    static func < (lhs: TrendRenderPhase, rhs: TrendRenderPhase) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// 将倒序的历史记录按自然日聚合（每组取当天最新一次测量作为代表），返回按日期升序排列的日聚合列表
nonisolated func aggregateDailyRecords(from records: [Measurement]) -> [DailyTrendRecord] {
    guard !records.isEmpty else { return [] }

    let calendar = Calendar.current
    var dayMap: [Date: [Measurement]] = [:]
    var dayOrder: [Date] = []

    for record in records {
        let startOfDay = calendar.startOfDay(for: record.date)
        if dayMap[startOfDay] == nil {
            dayMap[startOfDay] = [record]
            dayOrder.append(startOfDay)
        } else {
            dayMap[startOfDay]?.append(record)
        }
    }

    var dailyRecords: [DailyTrendRecord] = []
    for day in dayOrder {
        guard let group = dayMap[day], let latest = group.first else { continue }
        dailyRecords.append(
            DailyTrendRecord(
                id: day,
                date: latest.date,
                weightKg: latest.weightKg,
                bodyFatPercent: latest.bodyFatPercent,
                muscleMassKg: latest.muscleMassKg,
                visceralFat: latest.visceralFat,
                waterPercent: latest.waterPercent,
                bmi: latest.bmi,
                countOfDay: group.count,
                sourceRecord: latest
            )
        )
    }

    // 按自然日升序排列（从早到晚，以便折线图从左向右呈现时间流）
    return dailyRecords.sorted { $0.id < $1.id }
}

/// 根据时间跨度筛选日聚合记录
nonisolated func filterDailyRecords(_ daily: [DailyTrendRecord], for range: TrendTimeRange) -> [DailyTrendRecord] {
    switch range {
    case .recent7:
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        if let sevenDaysAgo = calendar.date(byAdding: .day, value: -6, to: today) {
            let inRange = daily.filter { $0.id >= sevenDaysAgo }
            // 若近 7 个自然日内至少有 2 个点，严格按近 7 日；若数据稀疏（< 2个点），智能兜底展示最近至多 7 个有记录日
            if inRange.count >= 2 {
                return inRange
            }
        }
        return Array(daily.suffix(7))

    case .recent30:
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        if let thirtyDaysAgo = calendar.date(byAdding: .day, value: -29, to: today) {
            let inRange = daily.filter { $0.id >= thirtyDaysAgo }
            if inRange.count >= 2 {
                return inRange
            }
        }
        return Array(daily.suffix(30))

    case .all:
        return daily
    }
}

/// 历史测量记录与趋势分析视图
struct TrendHistoryView<AvatarContent: View>: View {
    @ObservedObject var historyStore: HistoryStore
    @ObservedObject var cloudSync: CloudSyncManager
    let profile: UserProfile
    let onShowProfile: () -> Void
    @ViewBuilder let avatarView: () -> AvatarContent

    @State private var selectedMetric: TrendMetric = .weight
    @State private var selectedRange: TrendTimeRange = .recent30
    @State private var renderPhase: TrendRenderPhase = .skeleton
    @State private var allDailyRecords: [DailyTrendRecord] = []

    /// 根据选中的时间跨度筛选出的日聚合数据
    private var currentDailyRecords: [DailyTrendRecord] {
        filterDailyRecords(allDailyRecords, for: selectedRange)
    }

    var body: some View {
        NavigationStack {
            Group {
                if historyStore.records.isEmpty {
                    emptyStateView
                } else {
                    ScrollView {
                        VStack(spacing: 20) {
                            // 1. 顶部控制栏（指标选择 + 范围选择，首帧立即立即可交互）
                            controlHeader

                            // 2. 独立摘要统计卡片（展示按天聚合后的当前最新、较前日与区间）
                            if renderPhase >= .summary {
                                TrendSummaryCardView(metric: selectedMetric, records: currentDailyRecords)
                                    .transition(.opacity)
                            } else {
                                summarySkeleton
                            }

                            // 3. 独立 Swift Charts 图表（分批按日打点 + Monotone 极速曲线 + ID 状态隔离）
                            TrendChartSectionView(
                                metric: selectedMetric,
                                range: selectedRange,
                                records: currentDailyRecords,
                                isReady: renderPhase >= .chart
                            )

                            // 4. 独立历史记录流水列表（分批延后挂载，消除 TabView 切换时的主线程大列表渲染掉帧）
                            if renderPhase >= .full {
                                TrendHistoryListView(
                                    records: historyStore.records,
                                    onClear: { historyStore.clearAll() },
                                    onDelete: { historyStore.delete(record: $0) }
                                )
                                .transition(.opacity)
                            } else {
                                historyListSkeleton
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("趋势与历史")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    cloudSyncButton
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onShowProfile()
                    } label: {
                        avatarView()
                    }
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("个人资料")
                }
            }
            .navigationDestination(for: Measurement.self) { m in
                MeasurementResultView(
                    m: m,
                    profile: profile,
                    healthMessage: nil,
                    onRefresh: {
                        // 历史回看不需要重新测量
                    },
                    onShowProfile: onShowProfile,
                    avatarView: {
                        avatarView()
                    }
                )
            }
            .task(id: historyStore.records.count) {
                let raw = historyStore.records
                if raw.isEmpty {
                    allDailyRecords = []
                    renderPhase = .full
                    return
                }

                // 阶段 1: 异步后台执行日聚合计算，彻底释放主线程切换动画
                let aggregated = await Task.detached(priority: .userInitiated) {
                    aggregateDailyRecords(from: raw)
                }.value
                allDailyRecords = aggregated

                if renderPhase < .summary {
                    renderPhase = .summary
                }

                // 阶段 2: 让渡 25ms（等待 TabBar 切换过渡动画过半），平滑淡入折线图
                if renderPhase < .chart {
                    try? await Task.sleep(nanoseconds: 25_000_000)
                    withAnimation(.easeOut(duration: 0.2)) {
                        renderPhase = .chart
                    }
                }

                // 阶段 3: 再让渡 25ms，挂载历史记录列表
                if renderPhase < .full {
                    try? await Task.sleep(nanoseconds: 25_000_000)
                    withAnimation(.easeOut(duration: 0.2)) {
                        renderPhase = .full
                    }
                }
            }
        }
    }

    // MARK: - 骨架占位组件（用于阶梯渲染，维持尺寸稳定杜绝跳动）
    private var summarySkeleton: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(Color(.secondarySystemGroupedBackground))
            .frame(height: 74)
    }

    private var historyListSkeleton: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(Color(.secondarySystemGroupedBackground))
            .frame(height: 120)
    }

    // MARK: - iCloud 同步指示按钮（保持原生圆盘，彻底杜绝拉伸形变）
    private var cloudSyncButton: some View {
        Button {
            if cloudSync.isFolderBound {
                cloudSync.syncNow(historyStore: historyStore)
            } else {
                onShowProfile()
            }
        } label: {
            syncButtonIcon
        }
        .buttonBorderShape(.circle)
        .disabled(cloudSync.isSyncing)
        .accessibilityLabel(syncAccessibilityLabel)
    }

    @ViewBuilder
    private var syncButtonIcon: some View {
        if !cloudSync.isFolderBound {
            Image(systemName: "icloud.slash")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
        } else {
            switch cloudSync.syncState {
            case .syncing:
                NativeActivityIndicator()
                    .frame(width: 16, height: 16)
            case .success:
                Image(systemName: "checkmark.icloud.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.green)
            case .error:
                Image(systemName: "exclamationmark.icloud.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.red)
            case .idle:
                Image(systemName: "icloud.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var syncAccessibilityLabel: String {
        if !cloudSync.isFolderBound {
            return "未绑定 iCloud 云盘文件夹，点击前往设置"
        }
        switch cloudSync.syncState {
        case .syncing: return "正在同步 iCloud 云盘"
        case .success: return "iCloud 云盘同步成功"
        case .error(let msg): return "iCloud 云盘同步失败: \(msg)"
        case .idle: return "同步 iCloud 云盘"
        }
    }

    // MARK: - 空状态视图
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 60))
                .foregroundStyle(.tertiary)

            Text("暂无测量记录")
                .font(.title3.weight(.medium))

            Text("轻踩秤面站上体脂秤，完成一次测量后将在此自动生成身体变化趋势图表。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 控制选择栏
    private var controlHeader: some View {
        VStack(spacing: 12) {
            Picker("分析指标", selection: $selectedMetric) {
                ForEach(TrendMetric.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)

            Picker("时间范围", selection: $selectedRange) {
                ForEach(TrendTimeRange.allCases) { r in
                    Text(r.rawValue).tag(r)
                }
            }
            .pickerStyle(.segmented)
        }
    }
}

// MARK: - 独立摘要统计卡片（解耦隔离，仅更新极简文字）
private struct TrendSummaryCardView: View {
    let metric: TrendMetric
    let records: [DailyTrendRecord]

    var body: some View {
        let values = records.map { metric.value(from: $0) }
        let latest = values.last ?? 0
        let maxVal = values.max() ?? 0
        let minVal = values.min() ?? 0
        let diff = (values.count >= 2) ? (latest - values[values.count - 2]) : 0

        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("当前最新")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(String(format: metric == .visceralFat ? "%.0f" : "%.1f", latest))
                        .font(.system(.title2, design: .rounded, weight: .bold))
                    Text(metric.unit)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()
                .frame(height: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text("较前日")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 2) {
                    if diff != 0 {
                        Image(systemName: diff > 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.caption2)
                            .foregroundStyle(diff > 0 ? Color.orange : Color.green)
                    }
                    Text(diff == 0 ? "持平" : String(format: "%+.1f%@", diff, metric.unit))
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(diff == 0 ? .secondary : (diff > 0 ? Color.orange : Color.green))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()
                .frame(height: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text("区间范围")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(String(format: "%.1f - %.1f", minVal, maxVal))
                    .font(.system(.caption, design: .rounded, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - 独立 Swift Charts 图表视图（按日打点 + Monotone 极速曲线 + ID 状态隔离）
private struct TrendChartSectionView: View {
    let metric: TrendMetric
    let range: TrendTimeRange
    let records: [DailyTrendRecord]
    let isReady: Bool

    var body: some View {
        let color = metric.chartColor
        let values = records.map { metric.value(from: $0) }
        let rawMin = values.min() ?? 0
        let rawMax = values.max() ?? 100
        let minVal = rawMin > 0 ? rawMin * 0.95 : 0
        let maxVal = rawMax * 1.05

        VStack(alignment: .leading, spacing: 12) {
            Label("\(metric.rawValue)变化趋势", systemImage: "waveform.path.ecg")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            if isReady {
                let count = records.count
                let method: InterpolationMethod = count > 1 ? .monotone : .linear

                Chart {
                    ForEach(records) { r in
                        let val = metric.value(from: r)
                        AreaMark(
                            x: .value("日期", r.id, unit: .day),
                            yStart: .value("基准", minVal),
                            yEnd: .value("数值", val)
                        )
                        .interpolationMethod(method)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [color.opacity(0.25), color.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    }

                    ForEach(records) { r in
                        let val = metric.value(from: r)
                        LineMark(
                            x: .value("日期", r.id, unit: .day),
                            y: .value("数值", val)
                        )
                        .interpolationMethod(method)
                        .lineStyle(StrokeStyle(lineWidth: 2.5))
                        .foregroundStyle(color)
                    }

                    ForEach(records) { r in
                        let val = metric.value(from: r)
                        PointMark(
                            x: .value("日期", r.id, unit: .day),
                            y: .value("数值", val)
                        )
                        .foregroundStyle(color)
                    }
                }
                .chartYScale(domain: minVal...maxVal)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel(format: .dateTime.month(.twoDigits).day(.twoDigits))
                    }
                }
                .frame(height: 200)
                .padding(.top, 6)
                .id(metric.id + "_" + range.id) // 彻底消除指标切换时异质图元插值计算
                .animation(nil, value: metric)
                .animation(nil, value: range)
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.tertiarySystemFill).opacity(0.25))
                    .frame(height: 200)
                    .padding(.top, 6)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - 独立历史记录流水列表（完全脱离 Segment 切换，彻底消除冗余 Diff 与主线程卡顿）
private struct TrendHistoryListView: View {
    let records: [Measurement]
    let onClear: () -> Void
    let onDelete: (Measurement) -> Void

    @State private var showAllHistory = false
    @State private var showingClearAlert = false

    private var displayedRecords: [Measurement] {
        if showAllHistory || records.count <= 15 {
            return records
        } else {
            return Array(records.prefix(15))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("历史记录（\(records.count) 次）", systemImage: "clock.arrow.circlepath")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                if !records.isEmpty {
                    Button(role: .destructive) {
                        showingClearAlert = true
                    } label: {
                        Text("清空")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            LazyVStack(spacing: 0) {
                ForEach(Array(displayedRecords.enumerated()), id: \.element.id) { index, m in
                    historyRow(m)
                    if index < displayedRecords.count - 1 {
                        Divider()
                            .padding(.horizontal, 4)
                    }
                }
            }

            if records.count > 15 && !showAllHistory {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        showAllHistory = true
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("展开查看全部 \(records.count) 条历史记录")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .alert("确认清空全部记录？", isPresented: $showingClearAlert) {
            Button("取消", role: .cancel) { }
            Button("清空", role: .destructive) {
                onClear()
            }
        } message: {
            Text("此操作将清空本地所有历史记录。")
        }
    }

    private func historyRow(_ m: Measurement) -> some View {
        NavigationLink(value: m) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(trendRowDateFormatter.string(from: m.date))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        Text("体脂率 \(String(format: "%.1f", m.bodyFatPercent))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("BMI \(String(format: "%.1f", m.bmi))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(String(format: "%.2f", m.weightKg))
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .foregroundStyle(.primary)
                    Text("kg")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            NavigationLink(value: m) {
                Label("查看详情", systemImage: "arrow.up.forward.app")
            }

            Button {
                UIPasteboard.general.string = String(
                    format: "%.2f kg (体脂率 %.1f%%, BMI %.1f)",
                    m.weightKg,
                    m.bodyFatPercent,
                    m.bmi
                )
            } label: {
                Label("拷贝数据", systemImage: "doc.on.doc")
            }

            Divider()

            Button(role: .destructive) {
                onDelete(m)
            } label: {
                Label("删除记录", systemImage: "trash")
            }
        } preview: {
            historyRowPreview(m)
        }
    }

    private func historyRowPreview(_ m: Measurement) -> some View {
        VStack(spacing: 12) {
            HStack {
                Text(trendRowDateFormatter.string(from: m.date))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("测量快照")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color(.tertiarySystemFill), in: Capsule())
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(String(format: "%.2f", m.weightKg))
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                Text("kg")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)

            Divider()

            HStack(spacing: 12) {
                previewMetricItem(title: "体脂率", value: String(format: "%.1f%%", m.bodyFatPercent))
                previewMetricItem(title: "BMI", value: String(format: "%.1f", m.bmi))
                previewMetricItem(title: "肌肉量", value: String(format: "%.1f kg", m.muscleMassKg))
                previewMetricItem(title: "水分率", value: String(format: "%.1f%%", m.waterPercent))
            }
        }
        .padding(16)
        .frame(width: 290)
        .background(Color(.secondarySystemGroupedBackground))
    }

    private func previewMetricItem(title: String, value: String) -> some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
    }
}

private let trendRowDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter
}()

/// 原生系统活动指示器（解决 SwiftUI 原生 ProgressView 在 Toolbar 中强制注入尾部边距导致向右撑大拉伸的系统 Bug）
private struct NativeActivityIndicator: UIViewRepresentable {
    func makeUIView(context: Context) -> UIActivityIndicatorView {
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.startAnimating()
        indicator.hidesWhenStopped = true
        indicator.setContentHuggingPriority(.required, for: .horizontal)
        indicator.setContentHuggingPriority(.required, for: .vertical)
        indicator.setContentCompressionResistancePriority(.required, for: .horizontal)
        indicator.setContentCompressionResistancePriority(.required, for: .vertical)
        return indicator
    }

    func updateUIView(_ uiView: UIActivityIndicatorView, context: Context) {
        uiView.startAnimating()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIActivityIndicatorView, context: Context) -> CGSize? {
        CGSize(width: 16, height: 16)
    }
}
