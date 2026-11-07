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
    /// 实际选中的服务/特征值，排查连不上、没数据时第一眼看这个
    @Published var gattInfo: String?

    static let serviceUUID = CBUUID(string: "FFE0")
    static let notifyUUID = CBUUID(string: "FFE1")
    static let writeUUID = CBUUID(string: "FFE2")
    /// 允许系统在后台自动重连，短距离掉线后更容易自己回来
    static let connectOptions: [String: Any] = [
        CBConnectPeripheralOptionEnableAutoReconnect: true
    ]
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
    /// 连接失败后还剩几次自动重试
    private var pendingRetries = 0
    /// 这次连的设备信号强度，用来给超时提示加料
    private var connectRSSI = 0

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
        beginConnect(p, retries: 3, rssi: device.rssi)
    }

    /// 重连上次的设备（不重新扫描，省时间）
    func reconnectLast() {
        guard let raw = UserDefaults.standard.string(forKey: BmsCentral.lastDeviceKey),
              let uuid = UUID(uuidString: raw) else { return }
        if manager == nil {
            manager = CBCentralManager(delegate: self, queue: nil)
        }
        guard let p = found[uuid]
                ?? manager?.retrievePeripherals(withIdentifiers: [uuid]).first else {
            lastError = "找不到上次那块电池，请重新扫描"
            return
        }
        let rssi = devices.first { $0.id == uuid }?.rssi ?? 0
        beginConnect(p, retries: 3, rssi: rssi)
    }

    /// 统一入口：连不上会自动重试，iOS 的 BLE 建链超时是常态
    private func beginConnect(_ p: CBPeripheral, retries: Int, rssi: Int) {
        phase = .connecting
        if pendingRetries == 0 { lastError = nil }
        pendingRetries = retries
        connectRSSI = rssi
        gotFrame = false
        started = false
        gattInfo = nil
        peripheral = p
        p.delegate = self
        manager?.connect(p, options: BmsCentral.connectOptions)
    }

    /// 把 CBError 翻成人话
    private func describe(_ error: Error?) -> String {
        guard let error else { return "连接失败" }
        let ns = error as NSError
        guard ns.domain == CBErrorDomain, let code = CBError.Code(rawValue: ns.code) else {
            return ns.localizedDescription
        }
        switch code {
        case .connectionTimeout:
            if connectRSSI != 0 && connectRSSI < -85 {
                return "连接超时：信号太弱（\(connectRSSI) dBm），走近电池再试"
            }
            return "连接超时：走近电池、确认没被蚂蚁板 App 或别的手机占着，再试一次"
        case .peripheralDisconnected:
            return "连接被断开，可能同时被别的 App 连了"
        case .connectionFailed:
            return "连接失败，重试中…"
        case .peerRemovedPairingInformation:
            return "配对信息失效：去系统设置 → 蓝牙，忽略这块电池再连"
        default:
            return ns.localizedDescription
        }
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
        // 有 withResponse 就用它：这些串口模块在 withoutResponse 下偶尔丢包
        let type: CBCharacteristicWriteType =
            w.properties.contains(.write) ? .withResponse : .withoutResponse
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
        let msg = describe(error)
        // iOS 的 BLE 建链超时很常见（信号弱/对端刚醒），自动重试两次再认输
        if pendingRetries > 1 {
            pendingRetries -= 1
            lastError = msg + "，正在自动重试…"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self, self.phase == .connecting, let p = self.peripheral else { return }
                self.manager?.connect(p, options: BmsCentral.connectOptions)
            }
        } else {
            pendingRetries = 0
            lastError = msg
            teardown()
        }
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

        func notifiable(_ c: CBCharacteristic) -> Bool {
            c.properties.contains(.notify) || c.properties.contains(.indicate)
        }
        func writable(_ c: CBCharacteristic) -> Bool {
            c.properties.contains(.write) || c.properties.contains(.writeWithoutResponse)
        }

        // 你的这块 ANT 板（ANT~BLE24EAUB）在 FFE0 下挂了 7 个特征值：
        // Data / honeTX / honeRX / screenTX / screenRX / powerTX / powerRX，
        // 只有 Data 是「通知+读+写」全能的——所以先找全能型，别死认 FFE1/FFE2。
        if notifyChar == nil || writeChar == nil {
            let combo = chars.filter { notifiable($0) && writable($0) }
            if let c = combo.first(where: { $0.uuid == BmsCentral.notifyUUID }) ?? combo.first {
                notifyChar = notifyChar ?? c
                writeChar = writeChar ?? c
            }
        }

        // 退路：标准 ANT 板 FFE1 通知 / FFE2 写
        if notifyChar == nil {
            notifyChar = chars.first { $0.uuid == BmsCentral.notifyUUID && notifiable($0) }
                ?? chars.first(where: notifiable)
        }
        if writeChar == nil {
            writeChar = chars.first { $0.uuid == BmsCentral.writeUUID && writable($0) }
                ?? chars.first { writable($0) && !notifiable($0) }
                ?? chars.first(where: writable)
        }

        if let n = notifyChar, let w = writeChar {
            gattInfo = "FFE0 / \(short(n.uuid)) 通知 → \(short(w.uuid)) 写入"
            _ = n; _ = w
        }
        startIfReady()
    }

    private func short(_ u: CBUUID) -> String {
        let s = u.uuidString
        // 16 位短 UUID 会补成 0000xxxx-0000-1000-8000-00805F9B34FB，只留中间四位
        if s.count == 36, s.hasPrefix("0000"), s.hasSuffix("-0000-1000-8000-00805F9B34FB") {
            return String(s.dropFirst(4).prefix(4))
        }
        return s
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
