import Foundation
import CoreBluetooth

/// 蓝牙中枢：扫描 LBMC- 设备 → 连接 → 订阅 FFF1 → 轮询发帧 → 发布遥测
final class CockpitCentral: NSObject, ObservableObject {

    enum Phase: String {
        case idle = "未连接"
        case scanning = "扫描中"
        case connecting = "连接中"
        case connected = "已连接"
        case calibrated = "已标定"
        case online = "数据在线"
    }

    struct DiscoveredDevice: Identifiable {
        let id: UUID
        let name: String
        var rssi: Int
        /// 是否为已知控制器（LBMC 前缀）
        var isKnown: Bool = false
    }

    struct ConsoleLine: Identifiable {
        let id = UUID()
        let time: Date
        let hex: String
        let note: String
    }

    @Published var phase: Phase = .idle
    @Published var devices: [DiscoveredDevice] = []
    @Published var telemetry: LingboParser.Telemetry?
    @Published var speedKmh: Double = 0
    @Published var tripKm: Double = 0
    @Published var console: [ConsoleLine] = []
    @Published var connectedName: String?
    /// 当前生效的滚动周长（mm），供仪表页显示来源
    @Published var wheelCircMM: Double = 1426
    @Published var wheelCircSource: String = "估算"
    /// 连上后实际用的是哪个通道，如 "FFF0 (凌博/通用)"
    @Published var transportLabel: String?
    /// 实际发现到的服务/特征摘要，未知设备时用于 dump
    @Published var gattSummary: String?
    /// 识别出的控制器身份（广播名 / 帧内字符串）
    @Published var identity: ControllerIdentity?
    /// 帧里扫出的型号候选，供设置页一键采用
    @Published var modelCandidates: [String] = []

    static let serviceUUID = CBUUID(string: "FFF0")
    static let notifyUUID = CBUUID(string: "FFF1")
    static let writeUUID = CBUUID(string: "FFF2")
    static let namePrefix = "LBMC"
    static let defaultWheelCircMM: Double = 1466
    /// 设置项：扫描时是否显示全部蓝牙设备（默认只显示 LBMC）
    static let showAllDevicesKey = "scan_all_devices"

    private var manager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var notifyChar: CBCharacteristic?
    private var writeChar: CBCharacteristic?
    /// 协议驱动：默认凌博，换品牌只需换这一行 + 新增驱动文件
    private var driver: ControllerDriver = ControllerDrivers.makeDefault()
    private var pollTimer: Timer?
    private var lastTelemetryDate = Date.distantPast
    private var reconnectAttempts = 0
    /// 防止多个服务重复触发轮询
    private var pollingStarted = false
    /// 未知设备自动探测：待枚举的服务数与候选通道
    private var pendingServiceCount = 0
    private var autoCandidates: [(CBUUID, CBCharacteristic, CBCharacteristic)] = []

    // MARK: - 对外操作

    func startScan() {
        reconnectAttempts = 0
        devices.removeAll()
        phase = .scanning
        if manager == nil {
            manager = CBCentralManager(delegate: self, queue: nil)
        } else if manager?.state == .poweredOn {
            manager?.scanForPeripherals(withServices: nil, options: nil)
        }
    }

    func stopScan() {
        if manager?.isScanning == true { manager?.stopScan() }
        if phase == .scanning { phase = .idle }
    }

    func connect(_ device: DiscoveredDevice) {
        stopScan()
        guard let p = manager?.retrievePeripherals(withIdentifiers: [device.id]).first else {
            log("未找到设备，请重新扫描")
            return
        }
        phase = .connecting
        peripheral = p
        p.delegate = self
        manager?.connect(p, options: nil)
    }

    func disconnect() {
        reconnectAttempts = 99
        if let p = peripheral { manager?.cancelPeripheralConnection(p) }
    }

    func log(_ text: String) {
        appendLine("", text)
    }

    // MARK: - 轮询

    private func beginPolling() {
        pollTimer?.invalidate()
        let t = Timer(timeInterval: 0.5, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
        tick()
    }

    @objc private func tick() {
        guard let p = peripheral, let w = writeChar else { return }
        let cmd = driver.nextRequestFrame()
        p.writeValue(Data(cmd), for: w, type: .withoutResponse)
    }

    // MARK: - 遥测发布

    private func publish(_ t: LingboParser.Telemetry) {
        // 周长来源优先级：实测覆盖 > 轮胎模型估算（含车重/人重/胎压/下沉量）
        let circumf = TireModel.effectiveCircumferenceMM()
        let scale = UserDefaults.standard.object(forKey: "rpm_scale") as? Double ?? 1.0
        var v = Double(t.rpm) * scale * circumf * 60.0 / 1_000_000.0
        if v < 0 { v = 0 }
        if v > 160 { v = 160 }
        speedKmh = v
        wheelCircMM = circumf
        wheelCircSource = TireModel.circumferenceSourceText()

        let now = Date()
        let dt = now.timeIntervalSince(lastTelemetryDate)
        if dt > 0 && dt < 5 {
            tripKm += v * dt / 3600.0
        }
        lastTelemetryDate = now
    }

    private func appendLine(_ hex: String, _ note: String) {
        console.append(ConsoleLine(time: Date(), hex: hex, note: note))
        if console.count > 300 { console.removeFirst(console.count - 300) }
    }

    private func appendConsole(_ bytes: [UInt8], _ t: LingboParser.Telemetry?) {
        let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        var note = ""
        if bytes.count >= 4 {
            switch bytes[3] {
            case 0x60:
                note = "标定参数帧"
            case 0x62:
                if let t {
                    note = String(format: "实时 rpm=%d V=%.1f A=%.1f 故障=0x%X", t.rpm, t.busVoltage, t.busCurrent, t.fault & 0xFFFF)
                } else {
                    note = "实时帧（等待标定）"
                }
            default:
                note = String(format: "其它帧 cmd=0x%02X", bytes[3])
            }
        }
        appendLine(hex, note)
    }
}

// MARK: - CBCentralManagerDelegate

extension CockpitCentral: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if phase == .scanning {
                central.scanForPeripherals(withServices: nil, options: nil)
            }
        case .unauthorized:
            phase = .idle
            log("蓝牙权限未授权，请到设置里允许")
        case .poweredOff:
            phase = .idle
            log("蓝牙已关闭")
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? "未知设备"
        let isLingbo = name.hasPrefix(CockpitCentral.namePrefix)
        let showAll = UserDefaults.standard.bool(forKey: CockpitCentral.showAllDevicesKey)
        guard isLingbo || showAll else { return }
        if let idx = devices.firstIndex(where: { $0.id == peripheral.identifier }) {
            devices[idx].rssi = RSSI.intValue
            devices[idx].isKnown = isLingbo
        } else {
            devices.append(DiscoveredDevice(id: peripheral.identifier, name: name,
                                            rssi: RSSI.intValue, isKnown: isLingbo))
            // 已知控制器排前面
            devices.sort { ($0.isKnown ? 0 : 1, $0.name) < ($1.isKnown ? 0 : 1, $1.name) }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        reconnectAttempts = 0
        connectedName = peripheral.name
        driver.reset()
        transportLabel = nil
        gattSummary = nil
        pollingStarted = false
        tripKm = 0
        lastTelemetryDate = Date()
        phase = .connected
        log("已连接 \(peripheral.name ?? "")，正在枚举全部 GATT 服务…")

        // 1) 先用广播名识别型号，识别到就回填（仅在用户没手动填过时）
        identity = ControllerIdentifier.fromName(peripheral.name)
        modelCandidates.removeAll()
        if let id = identity?.suggestedLabel {
            log("识别到控制器：\(id)（来源：\(identity?.source ?? "")）")
            let saved = UserDefaults.standard.string(forKey: "controller_label") ?? ""
            if saved.isEmpty || saved == "未设置" || saved == "E400Max-CAN" {
                UserDefaults.standard.set(id, forKey: "controller_label")
                log("已自动填入控制器型号：\(id)")
            }
        } else {
            log("广播名未匹配到已知品牌，可打开「显示所有蓝牙设备」后手动确认型号")
        }

        // 不指定 UUID：未知控制器也能把服务结构 dump 出来
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        phase = .idle
        log("连接失败：\(error?.localizedDescription ?? "未知错误")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        phase = .idle
        notifyChar = nil
        writeChar = nil
        pollingStarted = false
        pendingServiceCount = 0
        autoCandidates.removeAll()
        transportLabel = nil
        pollTimer?.invalidate()
        pollTimer = nil
        connectedName = nil
        log("连接已断开")
        if reconnectAttempts < 3 {
            reconnectAttempts += 1
            let p = peripheral
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, let mgr = self.manager else { return }
                self.phase = .connecting
                p.delegate = self
                mgr.connect(p, options: nil)
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension CockpitCentral: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            log("发现服务失败：\(error.localizedDescription)")
            return
        }
        let services = peripheral.services ?? []
        gattSummary = services.map { $0.uuid.uuidString }.joined(separator: " / ")
        log("发现 \(services.count) 个服务：\(gattSummary ?? "无")")

        // 优先级 1：命中已知通道（凌博 FFF0），直接按对照表订阅
        if let known = services.first(where: { $0.uuid == CockpitCentral.serviceUUID }) {
            transportLabel = "FFF0（凌博 / 通用透传）"
            log("命中 FFF0，按凌博通道订阅 FFF1 / FFF2")
            peripheral.discoverCharacteristics(nil, for: known)
            return
        }

        // 优先级 2：未知设备 → 全量枚举，找"可写 + 可通知"的组合
        log("未命中 FFF0，转为自动探测：遍历所有服务查找通知/写入特征")
        autoCandidates.removeAll()
        pendingServiceCount = services.count
        for s in services {
            peripheral.discoverCharacteristics(nil, for: s)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let chars = service.characteristics ?? []
        let uuidText = service.uuid.uuidString

        if let error {
            log("\(uuidText) 特征失败：\(error.localizedDescription)")
        } else if chars.isEmpty {
            log("\(uuidText) 无特征")
        } else {
            let desc = chars.map { c -> String in
                var p: [String] = []
                if c.properties.contains(.read) { p.append("R") }
                if c.properties.contains(.write) { p.append("W") }
                if c.properties.contains(.writeWithoutResponse) { p.append("WNR") }
                if c.properties.contains(.notify) { p.append("N") }
                if c.properties.contains(.indicate) { p.append("I") }
                return "\(c.uuid.uuidString)[\(p.joined(separator: "+"))]"
            }.joined(separator: " ")
            log("\(uuidText): \(desc)")
        }

        let hint = ControllerDrivers.knownTransports.first {
            $0.service.uppercased() == uuidText.uppercased()
        }

        if let hint {
            // 已知通道：严格按对照表绑定
            for c in chars {
                if c.uuid.uuidString.uppercased() == hint.notify.uppercased(),
                   c.properties.contains(.notify) || c.properties.contains(.indicate) {
                    notifyChar = c
                }
                if c.uuid.uuidString.uppercased() == hint.write.uppercased(),
                   c.properties.contains(.write) || c.properties.contains(.writeWithoutResponse) {
                    writeChar = c
                }
            }
        } else {
            // 未知通道：同一条服务里凑一对"通知 + 写入"
            let n = chars.first {
                $0.properties.contains(.notify) || $0.properties.contains(.indicate)
            }
            let w = chars.first {
                $0.properties.contains(.writeWithoutResponse) || $0.properties.contains(.write)
            }
            if let n, let w {
                autoCandidates.append((service.uuid, n, w))
            }
        }

        // 未知设备：等所有服务都枚举完，取第一个可用的候选对
        if pendingServiceCount > 0 {
            pendingServiceCount -= 1
            if pendingServiceCount == 0, writeChar == nil || notifyChar == nil,
               let best = autoCandidates.first {
                notifyChar = best.1
                writeChar = best.2
                transportLabel = "\(best.0.uuidString)（自动探测）"
            }
        }

        startIfReady(on: peripheral)
    }

    /// 通知/写入都齐了就开始订阅与轮询，且只做一次
    private func startIfReady(on peripheral: CBPeripheral) {
        guard !pollingStarted, let n = notifyChar, let w = writeChar else { return }
        pollingStarted = true
        peripheral.setNotifyValue(true, for: n)
        log("通道就绪：通知 \(n.uuid.uuidString) → 写入 \(w.uuid.uuidString)")
        log("协议驱动：\(driver.displayName)，开始 500ms 轮询")
        UserDefaults.standard.set(transportLabel ?? "\(n.uuid.uuidString)",
                                  forKey: "last_transport")
        beginPolling()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            log("订阅通知失败：\(error.localizedDescription)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        // 用实际绑定的通知特征判断，不再写死 FFF1
        guard characteristic.uuid == notifyChar?.uuid,
              let data = characteristic.value, !data.isEmpty else { return }
        let bytes = [UInt8](data)
        // 帧里若藏有型号字符串（版本帧常见），收集成候选
        for cand in ControllerIdentifier.asciiCandidates(in: bytes)
        where !modelCandidates.contains(cand) && modelCandidates.count < 6 {
            modelCandidates.append(cand)
            log("帧内发现字符串：\(cand)")
        }
        let wasCalibrated = driver.isCalibrated
        let t = driver.feed(bytes)
        appendConsole(bytes, t)
        if !wasCalibrated, driver.isCalibrated {
            log("标定完成：\(driver.calibrationSummary ?? "")")
            if phase != .online { phase = .calibrated }
        }
        if let t {
            telemetry = t
            phase = .online
            publish(t)
        }
    }
}
