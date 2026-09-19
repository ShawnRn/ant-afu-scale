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

/// 时间/记录范围
enum TrendTimeRange: String, CaseIterable, Identifiable {
    case recent7 = "近7次"
    case recent30 = "近30次"
    case all = "全部"

    var id: String { rawValue }
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
    @State private var isChartReady = false

    /// 根据范围筛选并按时间正序排列（利用 records 本身已倒序存储的特性，O(1) 取 prefix 并反转）
    private var chartRecords: [Measurement] {
        switch selectedRange {
        case .recent7:
            return Array(historyStore.records.prefix(7).reversed())
        case .recent30:
            return Array(historyStore.records.prefix(30).reversed())
        case .all:
            return Array(historyStore.records.reversed())
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if historyStore.records.isEmpty {
                    emptyStateView
                } else {
                    ScrollView {
                        VStack(spacing: 20) {
                            // 1. 顶部控制栏（指标选择 + 范围选择）
                            controlHeader

                            // 2. 独立摘要统计卡片（纯轻量渲染）
                            TrendSummaryCardView(metric: selectedMetric, records: chartRecords)

                            // 3. 独立 Swift Charts 图表（带 id 隔离，杜绝指标切换时的庞大图元插值计算）
                            TrendChartSectionView(
                                metric: selectedMetric,
                                range: selectedRange,
                                records: chartRecords,
                                isReady: isChartReady
                            )

                            // 4. 独立历史记录流水列表（切换指标/范围时完全无需 Diff 或重绘）
                            TrendHistoryListView(
                                records: historyStore.records,
                                onClear: { historyStore.clearAll() },
                                onDelete: { historyStore.delete(record: $0) }
                            )
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
            .task {
                if !isChartReady {
                    await Task.yield()
                    withAnimation(.easeOut(duration: 0.15)) {
                        isChartReady = true
                    }
                }
            }
        }
    }

    // MARK: - iCloud 同步指示按钮（保持原生圆盘，彻底杜绝拉伸形变）
    private var cloudSyncButton: some View {
        Button {
            cloudSync.syncNow(historyStore: historyStore)
        } label: {
            syncButtonIcon
        }
        .buttonBorderShape(.circle)
        .disabled(cloudSync.isSyncing)
        .accessibilityLabel(syncAccessibilityLabel)
    }

    @ViewBuilder
    private var syncButtonIcon: some View {
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

    private var syncAccessibilityLabel: String {
        switch cloudSync.syncState {
        case .syncing: return "正在同步 iCloud"
        case .success: return "iCloud 同步成功"
        case .error(let msg): return "iCloud 同步失败: \(msg)"
        case .idle: return "同步 iCloud"
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
    let records: [Measurement]

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
                    Text(String(format: "%.1f", latest))
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
                Text("较上次")
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

// MARK: - 独立 Swift Charts 图表视图（分批次 Mark 构建 + Monotone 极速曲线 + ID 状态隔离）
private struct TrendChartSectionView: View {
    let metric: TrendMetric
    let range: TrendTimeRange
    let records: [Measurement]
    let isReady: Bool

    var body: some View {
        let color = metric.chartColor
        let values = records.map { metric.value(from: $0) }
        let minVal = (values.min() ?? 0) * 0.95
        let maxVal = (values.max() ?? 100) * 1.05

        VStack(alignment: .leading, spacing: 12) {
            Label("\(metric.rawValue)变化趋势", systemImage: "waveform.path.ecg")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            if isReady {
                let count = records.count
                let method: InterpolationMethod = count > 1 ? .monotone : .linear

                Chart {
                    ForEach(records) { m in
                        let val = metric.value(from: m)
                        AreaMark(
                            x: .value("时间", m.date),
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

                    ForEach(records) { m in
                        let val = metric.value(from: m)
                        LineMark(
                            x: .value("时间", m.date),
                            y: .value("数值", val)
                        )
                        .interpolationMethod(method)
                        .lineStyle(StrokeStyle(lineWidth: 2.5))
                        .foregroundStyle(color)
                    }

                    ForEach(records) { m in
                        let val = metric.value(from: m)
                        PointMark(
                            x: .value("时间", m.date),
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
                        AxisValueLabel(format: .dateTime.month().day())
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

