import Foundation
import CoreBluetooth

/// 电池 BMS（蚂蚁板）蓝牙通道
///
/// 和控制器是两条完全独立的 BLE 链路：控制器走 FFF0/FFF1/FFF2 读 AA55 帧，
/// 电池走 FFE0/FFE1/FFE2 读 7EA1 帧。所以这里单独一个 CBCentralManager，
/// 断了也不影响仪表主链路。
final class BmsCentral: NSObject, ObservableObject {

    enum Phase: String {
        case idle = "未连接"
        case scanning = "扫描中"
        case connecting = "连接中"
        case online = "在线"
    }

    struct Device: Identifiable {
        let id: UUID
        let name: String
        var rssi: Int
        /// 名字或广播里像 BMS 的（排前面）
        var likely: Bool
    }

    @Published var phase: Phase = .idle
    @Published var devices: [Device] = []
    @Published var telemetry: AntBmsParser.Telemetry?
    @Published var connectedName: String?
    @Published var frameCount = 0
    @Published var lastError: String?
    /// 最近一帧原始字节（数据台用）
    @Published var lastFrame: [UInt8] = []

    static let serviceUUID = CBUUID(string: "FFE0")
    static let notifyUUID = CBUUID(string: "FFE1")
    static let writeUUID = CBUUID(string: "FFE2")
    /// 记住上次连过的设备，下次一键重连
    static let lastDeviceKey = "bms_last_device"

    private var manager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var notifyChar: CBCharacteristic?
    private var writeChar: CBCharacteristic?
    private var pollTimer: Timer?
    private let parser = AntBmsParser()
    private var started = false
    /// 扫描时拿到的外设引用：retrievePeripherals 有时拿不到刚发现的设备，自己留一份最稳
    private var found: [UUID: CBPeripheral] = [:]
    /// 是否已经拿到过第一帧（用来区分「连上了但没数据」和「真在线」）
    private var gotFrame = false

    var isUsable: Bool { phase == .online }

    // MARK: 对外

    func startScan() {
        devices.removeAll()
        phase = .scanning
        if manager == nil {
            manager = CBCentralManager(delegate: self, queue: nil)
        } else if manager?.state == .poweredOn {
            manager?.scanForPeripherals(withServices: nil, options: nil)
        }
    }

    func stopScan() {
        manager?.stopScan()
        if phase == .scanning { phase = .idle }
    }

    func connect(_ device: Device) {
        manager?.stopScan()
        let p = found[device.id]
            ?? manager?.retrievePeripherals(withIdentifiers: [device.id]).first
        guard let p else {
            lastError = "设备已不可用，请重新扫描"
            return
        }
        phase = .connecting
        lastError = nil
        gotFrame = false
        peripheral = p
        p.delegate = self
        manager?.connect(p, options: nil)
    }

    /// 重连上次的设备（不重新扫描，省时间）
    func reconnectLast() {
        guard let raw = UserDefaults.standard.string(forKey: BmsCentral.lastDeviceKey),
              let uuid = UUID(uuidString: raw) else { return }
        if manager == nil {
            manager = CBCentralManager(delegate: self, queue: nil)
        }
        guard let p = found[uuid]
                ?? manager?.retrievePeripherals(withIdentifiers: [uuid]).first else { return }
        phase = .connecting
        lastError = nil
        gotFrame = false
        peripheral = p
        p.delegate = self
        manager?.connect(p, options: nil)
    }

    /// 启动时自动重连（设置里可关）。没有记录过设备就什么都不做。
    func autoReconnectIfNeeded() {
        guard phase == .idle || phase == .scanning else { return }
        let auto = UserDefaults.standard.object(forKey: "bms_auto_reconnect") as? Bool ?? true
        guard auto else { return }
        guard let raw = UserDefaults.standard.string(forKey: BmsCentral.lastDeviceKey),
              UUID(uuidString: raw) != nil else { return }
        reconnectLast()
    }

    var hasLastDevice: Bool {
        guard let raw = UserDefaults.standard.string(forKey: BmsCentral.lastDeviceKey) else { return false }
        return UUID(uuidString: raw) != nil
    }

    func forgetLast() {
        UserDefaults.standard.removeObject(forKey: BmsCentral.lastDeviceKey)
        disconnect()
    }

    func disconnect() {
        if let p = peripheral { manager?.cancelPeripheralConnection(p) }
        teardown()
    }

    private func teardown() {
        pollTimer?.invalidate()
        pollTimer = nil
        started = false
        gotFrame = false
        parser.reset()
        notifyChar = nil
        writeChar = nil
        telemetry = nil
        connectedName = nil
        lastFrame = []
        phase = .idle
    }

    // MARK: 轮询

    private func beginPolling() {
        pollTimer?.invalidate()
        let t = Timer(timeInterval: 1.0, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
        tick()
    }

    @objc private func tick() {
        guard let p = peripheral, let w = writeChar else { return }
        let type: CBCharacteristicWriteType =
            w.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        p.writeValue(Data(AntBmsParser.statusRequest), for: w, type: type)
    }
}

// MARK: - CBCentralManagerDelegate

extension BmsCentral: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if phase == .scanning {
                central.scanForPeripherals(withServices: nil, options: nil)
            }
        case .poweredOff:
            lastError = "蓝牙已关闭"
        case .unauthorized:
            lastError = "蓝牙权限未授权"
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? advName ?? "未知设备"
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let upper = name.uppercased()
        let likely = services.contains(BmsCentral.serviceUUID)
            || upper.contains("ANT")
            || upper.contains("BMS")
            || upper.contains("JBD")
            || upper.contains("DALY")
            || upper.contains("JK")
            || upper.contains("LLT")

        if let idx = devices.firstIndex(where: { $0.id == peripheral.identifier }) {
            devices[idx].rssi = RSSI.intValue
            devices[idx].likely = likely
        } else {
            found[peripheral.identifier] = peripheral
            devices.append(Device(id: peripheral.identifier, name: name,
                                  rssi: RSSI.intValue, likely: likely))
        }
        // 像 BMS 的排前面，同组内信号强的排前面
        devices.sort { a, b in
            if a.likely != b.likely { return a.likely }
            return a.rssi > b.rssi
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectedName = peripheral.name
        lastError = nil
        gotFrame = false
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: BmsCentral.lastDeviceKey)
        peripheral.delegate = self
        peripheral.discoverServices([BmsCentral.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        lastError = error?.localizedDescription ?? "连接失败"
        teardown()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        started = false
        teardown()
        lastError = error?.localizedDescription ?? "连接已断开"
    }
}

// MARK: - CBPeripheralDelegate

extension BmsCentral: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        if let ffe0 = services.first(where: { $0.uuid == BmsCentral.serviceUUID }) {
            peripheral.discoverCharacteristics(nil, for: ffe0)
        } else if services.isEmpty {
            // 有的固件不声明 FFE0，全量枚举再挑
            peripheral.discoverServices(nil)
        } else {
            for s in services { peripheral.discoverCharacteristics(nil, for: s) }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let chars = service.characteristics ?? []

        // 通知：优先 FFF1
        if notifyChar == nil {
            notifyChar = chars.first { $0.uuid == BmsCentral.notifyUUID }
                ?? chars.first { $0.properties.contains(.notify) || $0.properties.contains(.indicate) }
        }
        // 写入：优先 FFE2，其次 FFE1
        if writeChar == nil {
            writeChar = chars.first { $0.uuid == BmsCentral.writeUUID && ($0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse)) }
                ?? chars.first { $0.uuid == BmsCentral.notifyUUID && ($0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse)) }
                ?? chars.first { $0.properties.contains(.writeWithoutResponse) || $0.properties.contains(.write) }
        }

        startIfReady()
    }

    private func startIfReady() {
        guard !started, let p = peripheral, let n = notifyChar, let w = writeChar else { return }
        started = true
        p.setNotifyValue(true, for: n)
        _ = w
        beginPolling()

        // 5 秒还没回一帧，多半不是蚂蚁协议（或写特征选错了）——如实告诉用户
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self, self.started, !self.gotFrame else { return }
            self.lastError = "已连上但收不到数据，可能不是蚂蚁协议"
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value, !data.isEmpty else { return }
        if let t = parser.feed([UInt8](data)) {
            gotFrame = true
            telemetry = t
            lastFrame = parser.lastFrame
            lastError = nil
            phase = .online
            frameCount += 1
        }
    }
}
