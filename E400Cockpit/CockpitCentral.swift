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

    static let serviceUUID = CBUUID(string: "FFF0")
    static let notifyUUID = CBUUID(string: "FFF1")
    static let writeUUID = CBUUID(string: "FFF2")
    static let namePrefix = "LBMC"
    static let defaultWheelCircMM: Double = 1466

    private var manager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var notifyChar: CBCharacteristic?
    private var writeChar: CBCharacteristic?
    private let parser = LingboParser()
    private var pollTimer: Timer?
    private var lastTelemetryDate = Date.distantPast
    private var reconnectAttempts = 0

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
        let cmd = parser.calibration.calibrated ? Lingbo.realtimeRequest : Lingbo.calibrationRequest
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
        guard name.hasPrefix(CockpitCentral.namePrefix) else { return }
        if let idx = devices.firstIndex(where: { $0.id == peripheral.identifier }) {
            devices[idx].rssi = RSSI.intValue
        } else {
            devices.append(DiscoveredDevice(id: peripheral.identifier, name: name, rssi: RSSI.intValue))
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        reconnectAttempts = 0
        connectedName = peripheral.name
        parser.reset()
        tripKm = 0
        lastTelemetryDate = Date()
        phase = .connected
        log("已连接 \(peripheral.name ?? "")，开始发现服务 FFF0…")
        peripheral.discoverServices([CockpitCentral.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        phase = .idle
        log("连接失败：\(error?.localizedDescription ?? "未知错误")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        phase = .idle
        notifyChar = nil
        writeChar = nil
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
        guard let svc = peripheral.services?.first(where: { $0.uuid == CockpitCentral.serviceUUID }) else {
            log("未找到 FFF0 服务（协议不匹配？）")
            return
        }
        log("发现 FFF0 服务，订阅 FFF1 / 找 FFF2…")
        peripheral.discoverCharacteristics([CockpitCentral.notifyUUID, CockpitCentral.writeUUID], for: svc)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] {
            if c.uuid == CockpitCentral.notifyUUID {
                notifyChar = c
                peripheral.setNotifyValue(true, for: c)
            }
            if c.uuid == CockpitCentral.writeUUID {
                writeChar = c
            }
        }
        if writeChar != nil, notifyChar != nil {
            log("FFF1(通知) + FFF2(写入) 就绪，开始轮询")
            beginPolling()
        } else {
            log("缺少 FFF1/FFF2 特征，无法通信")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            log("订阅通知失败：\(error.localizedDescription)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == CockpitCentral.notifyUUID,
              let data = characteristic.value, !data.isEmpty else { return }
        let bytes = [UInt8](data)
        let wasCalibrated = parser.calibration.calibrated
        let t = parser.feed(bytes)
        appendConsole(bytes, t)
        if !wasCalibrated, parser.calibration.calibrated {
            log("标定完成：电流分母=\(parser.calibration.busCurrentDiv) 电压分母=\(parser.calibration.busVoltageDiv)")
            if phase != .online { phase = .calibrated }
        }
        if let t {
            telemetry = t
            phase = .online
            publish(t)
        }
    }
}
