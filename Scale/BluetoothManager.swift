import Foundation
import Combine
import CoreBluetooth

/// 蓝牙连接状态，用于驱动界面。
enum ScaleState: Equatable {
    case idle            // 未开始/空闲
    case poweredOff      // 蓝牙没开
    case scanning        // 正在寻找/扫描体脂秤
    case connecting      // 正在连接
    case connected       // 已连接，等待赤脚上秤
    case measuring       // 已上秤，正在测量体重与阻抗
    case done            // 本次测量完成
    case scanTimeout     // 扫描超时（省电停止扫描，等待用户手动刷新）
    case bodyFatUnavailable(String)  // 称到体重，但阻抗无效，测不出体脂
    case error(String)
}

/// 负责：扫描秤 → 连接 → 订阅通知 → 解析 0xAC 数据包 → 稳定判定。
/// 解析逻辑对应 icomon_scale 的简化协议（沃莱/Welland 芯片，服务 FFB0）。
///
/// 全类主 actor 隔离：CoreBluetooth 用 `queue: .main` 回调，所有 `@Published`
/// 状态也都在主线程更新，标 `@MainActor` 后隔离与执行器一致，避免运行时的
/// “unsafeForcedSync”跨上下文强制同步。
@MainActor
final class BluetoothManager: NSObject, ObservableObject {

    // 目标秤的服务 UUID（沃莱系列）。iOS 拿不到 MAC，只能靠服务/名字过滤。
    private let serviceUUID = CBUUID(string: "FFB0")
    /// 改成 true 可在控制台打印每一包原始字节与状态机流转
    private let debugLog = true
    @Published var state: ScaleState = .idle
    @Published var liveWeight: Double? = nil        // 实时体重（未稳定）
    @Published var lastMeasurement: Measurement? = nil

    var profile: UserProfile = .load()
    /// 测量稳定并算完后回调（用来写 HealthKit）
    var onMeasurementReady: ((Measurement) -> Void)?

    private var central: CBCentralManager!
    private var scale: CBPeripheral?
    private var notifyChar: CBCharacteristic?
    private var writeChar: CBCharacteristic?

    private var stableBuffer: [Double] = []
    private var locked = false
    private var didSendProfile = false

    // 扫描超时任务（25秒无响应自动停扫省电）
    private var scanTimeoutTask: Task<Void, Never>?
    // 离秤守护与防抖任务（用户下秤平滑重置回主页）
    private var stepOffDebounceTask: Task<Void, Never>?
    private var isStepOffTimerActive = false

    // 记住上次连过的秤，下次直连
    private var lastPeripheralID: UUID? {
        get { UserDefaults.standard.string(forKey: "last_peripheral").flatMap(UUID.init) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: "last_peripheral") }
    }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    /// 开始扫描并连接体脂秤（带 25 秒超时机制）
    func startScanning() {
        profile = .load()
        scanTimeoutTask?.cancel()
        scanTimeoutTask = nil

        guard central.state == .poweredOn else {
            state = .poweredOff
            return
        }

        // 如果已连上并且特征就绪，直接保持已连接状态
        if let scale, scale.state == .connected, notifyChar != nil {
            state = .connected
            return
        }

        // 先尝试直连上次的秤
        if let id = lastPeripheralID,
           let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(known)
            return
        }

        state = .scanning
        central.scanForPeripherals(withServices: [serviceUUID], options: nil)

        // 启动 25 秒超时定时器，超时未搜到则停止扫描并更新状态
        scanTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            guard let self, self.state == .scanning else { return }
            self.central.stopScan()
            self.state = .scanTimeout
        }
    }

    /// 开始或重新开始一次测量
    func startMeasurement() {
        profile = .load()
        stableBuffer = []
        locked = false
        didSendProfile = false
        liveWeight = nil
        lastMeasurement = nil
        isStepOffTimerActive = false
        stepOffDebounceTask?.cancel()
        stepOffDebounceTask = nil

        startScanning()
    }

    /// 测量完成或返回后，重置状态回到准备测量状态，并重新开始扫描连接
    func resetToReady() {
        scanTimeoutTask?.cancel()
        scanTimeoutTask = nil
        isStepOffTimerActive = false
        stepOffDebounceTask?.cancel()
        stepOffDebounceTask = nil
        lastMeasurement = nil
        liveWeight = nil
        locked = false
        didSendProfile = false
        startScanning()
    }

    func cancel() {
        scanTimeoutTask?.cancel()
        scanTimeoutTask = nil
        isStepOffTimerActive = false
        stepOffDebounceTask?.cancel()
        stepOffDebounceTask = nil
        central.stopScan()
        if let scale { central.cancelPeripheralConnection(scale) }
        liveWeight = nil
        state = .idle
    }

    private func connect(_ peripheral: CBPeripheral) {
        scanTimeoutTask?.cancel()
        scanTimeoutTask = nil
        central.stopScan()
        scale = peripheral
        peripheral.delegate = self
        state = .connecting
        if debugLog { print("[BLE] 🔗 正在连接设备: \(peripheral.name ?? peripheral.identifier.uuidString)") }
        central.connect(peripheral, options: nil)
    }

    /// 把用户资料写给秤，触发它做体脂(阻抗)测量。
    private func sendUserProfile(deviceType: Int) {
        guard let scale, let writeChar else {
            print("⚠️ 没有可写特征，无法下发用户资料")
            return
        }
        let packet = Scale27.encodeUserInfo(deviceType: deviceType, profile: profile)
        let type: CBCharacteristicWriteType =
            writeChar.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        scale.writeValue(packet, for: writeChar, type: type)
        if debugLog {
            print("📤 已下发用户资料: \(packet.map { String(format: "%02X", $0) }.joined(separator: " "))")
        }
    }

    /// 解析一包通知数据（AFU/沃莱 Scale27 协议）。
    /// 体重包(213)只更新实时体重；收到阻抗包(214)代表测量结束 → 锁定并计算。
    private func handle(_ data: Data) {
        if debugLog {
            let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
            print("[BLE] 📦 收到原始数据 (\(data.count)B): \(hex)")
        }

        // 收到第一包时下发用户资料
        if !didSendProfile, data.count >= 2 {
            didSendProfile = true
            profile = .load()
            sendUserProfile(deviceType: Int(data[1]))
        }

        guard let packet = Scale27.decode([UInt8](data)) else { return }

        switch packet {
        case .weight(let kg, let stable):
            guard !locked else { return }

            if kg > 2.0 {
                // 收到有效人体体重
                let roundedKg = (kg * 100).rounded() / 100
                liveWeight = roundedKg
                if state != .measuring {
                    state = .measuring
                    if debugLog { print("[BLE] 🔄 状态切换 -> 测量中 (.measuring)") }
                }

                // 取消离秤倒计时
                if isStepOffTimerActive {
                    isStepOffTimerActive = false
                    stepOffDebounceTask?.cancel()
                    stepOffDebounceTask = nil
                }

                if debugLog {
                    print("[BLE] ⚖️ 实时读数: \(String(format: "%.2f", roundedKg)) kg (稳定: \(stable))")
                }
            } else {
                // 收到空秤或归零数据 (<= 2.0kg)
                // 绝不立即置空 liveWeight，彻底杜绝在已连接与数字之间的高频剧烈闪烁！
                // 仅当持续 1.0 秒无有效体重时，才确认用户真正离开秤面
                if (state == .measuring || liveWeight != nil) && !isStepOffTimerActive {
                    isStepOffTimerActive = true
                    stepOffDebounceTask?.cancel()
                    stepOffDebounceTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1.0 秒平滑防抖确认
                        guard let self, !self.locked, self.lastMeasurement == nil else { return }
                        if self.debugLog { print("[BLE] 🚶 持续 1.0 秒归零，确认用户离秤，平滑复位回准备状态") }
                        self.liveWeight = nil
                        self.state = (self.scale?.state == .connected && self.notifyChar != nil) ? .connected : .idle
                        self.didSendProfile = false
                        self.isStepOffTimerActive = false
                        self.stepOffDebounceTask = nil
                    }
                }
            }

        case .adc(let kg, let impedances):
            guard !locked else { return }

            // 沃莱秤在测量阻抗的过程中也会持续发送 ADC 包，未完成时阻抗通常为 0 或超出有效范围。
            // 此时代表秤还在测量阻抗中（跑马灯采样），绝对不能断开蓝牙或切回错误/就绪状态，直接等待下一包！
            guard let impedance = impedances.first(where: { $0 >= 100 && $0 <= 1500 }) else {
                if debugLog {
                    print("[BLE] ⏳ 阻抗采样中（未锁定）：\(impedances)，保持测量状态继续等待有效值...")
                }
                return
            }

            let weightKg = kg > 2.0 ? kg : (liveWeight ?? 0)
            guard weightKg > 2.0 else { return }

            // 成功获取有效阻抗与体重，测量圆满完成！
            locked = true
            isStepOffTimerActive = false
            stepOffDebounceTask?.cancel()
            stepOffDebounceTask = nil

            if debugLog {
                print("[BLE] ✅ 测量锁定：体重 \(String(format: "%.2f", weightKg))kg, 阻抗 \(impedance)Ω (全部: \(impedances))")
            }
            let m = BodyComposition.calculate(weightKg: weightKg,
                                              impedance: impedance,
                                              profile: profile)
            lastMeasurement = m
            state = .done
            onMeasurementReady?(m)
            // 测完主动断开
            if let scale { central.cancelPeripheralConnection(scale) }
        }
    }
}

// MARK: - CBCentralManagerDelegate
extension BluetoothManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            if central.state == .poweredOn {
                if lastMeasurement == nil && state != .measuring && state != .connected && state != .connecting {
                    startScanning()
                }
            } else {
                scanTimeoutTask?.cancel()
                scanTimeoutTask = nil
                state = .poweredOff
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        MainActor.assumeIsolated { connect(peripheral) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            lastPeripheralID = peripheral.identifier
            peripheral.discoverServices([serviceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            state = .error("连接失败：\(error?.localizedDescription ?? "未知")")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            if debugLog { print("[BLE] 🔌 蓝牙外设已断开连接: \(peripheral.name ?? "未知设备")") }
            scanTimeoutTask?.cancel()
            scanTimeoutTask = nil
            stepOffDebounceTask?.cancel()
            stepOffDebounceTask = nil
            isStepOffTimerActive = false
            notifyChar = nil
            writeChar = nil
            scale = nil
            if !locked && lastMeasurement == nil {
                liveWeight = nil
                didSendProfile = false
                state = .idle
            }
        }
    }
}

// MARK: - CBPeripheralDelegate
extension BluetoothManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            for service in peripheral.services ?? [] {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            for c in service.characteristics ?? [] {
                if c.properties.contains(.notify) {
                    notifyChar = c
                    peripheral.setNotifyValue(true, for: c)
                }
                if c.properties.contains(.write) || c.properties.contains(.writeWithoutResponse) {
                    writeChar = c
                }
            }
            if state != .measuring {
                state = .connected
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        MainActor.assumeIsolated { handle(data) }
    }
}
