import Foundation
import CoreBluetooth

// MARK: - 保护板品牌

/// 只把「保护板」放进电池列表：蚂蚁 / 极空 / 嘉佰达 / 彦阳 / 达锂…
/// 否则扫出来一堆耳机、车机、手表，翻半天找不到板子。
enum BmsBrand {

    struct Rule {
        let label: String
        /// 大小写不敏感的广播名前缀
        let prefixes: [String]
        /// 名字中间包含就算
        let contains: [String]
    }

    static let rules: [Rule] = [
        Rule(label: "蚂蚁", prefixes: ["ANT"], contains: ["ANTBMS", "ANT-BMS"]),
        Rule(label: "极空", prefixes: ["JK", "JIKONG"], contains: ["JIKONG", "JK-BMS", "JK-B"]),
        Rule(label: "嘉佰达", prefixes: ["JBD", "JIABAIDA"], contains: ["JIABAIDA"]),
        Rule(label: "彦阳", prefixes: ["YY", "YANYANG"], contains: ["YANYANG"]),
        Rule(label: "达锂", prefixes: ["DALY", "DL-"], contains: ["DALY"]),
        Rule(label: "力恒", prefixes: ["LIANHE", "LITH"], contains: ["LIANHE"]),
        Rule(label: "通用板", prefixes: ["BMS", "LLT", "SMARTBMS"], contains: [])
    ]

    /// 命中就返回品牌中文名，没命中返回 nil
    static func match(_ name: String) -> String? {
        let u = name.uppercased()
        for r in rules {
            if r.prefixes.contains(where: { u.hasPrefix($0) }) { return r.label }
            if r.contains.contains(where: { u.contains($0) }) { return r.label }
        }
        return nil
    }

    static func isBoard(_ name: String) -> Bool { match(name) != nil }
}

// MARK: - 电池 BMS（保护板）蓝牙通道

/// 和控制器是两条完全独立的 BLE 链路：控制器走 FFF0/FFF1/FFF2 读 AA55 帧，
/// 保护板走 FFE0 读 7EA1 帧。所以这里单独一个 CBCentralManager，
/// 断了也不影响仪表主链路。
final class BmsCentral: NSObject, ObservableObject {

    enum Phase: String {
        case idle = "未连接"
        case scanning = "扫描中"
        case connecting = "连接中"
        /// BLE 建链成功、特征值已拿到，但还没解析出第一帧
        case connected = "已连接"
        case online = "在线"
    }

    struct Device: Identifiable {
        let id: UUID
        let name: String
        var rssi: Int
        /// 名字或广播里像保护板的
        var likely: Bool
        /// 命中的品牌（蚂蚁 / 极空 / …）
        var brand: String?
    }

    @Published var phase: Phase = .idle
    @Published var devices: [Device] = []
    @Published var telemetry: AntBmsParser.Telemetry?
    @Published var connectedName: String?
    @Published var frameCount = 0
    @Published var lastError: String?
    /// 最近一帧原始字节（数据台用）
    @Published var lastFrame: [UInt8] = []
    /// 最近收到的原始通知字节（不管能不能解析都记下来）——不通时全靠它定位
    @Published var lastRX = ""
    @Published var rxTotal = 0
    /// 实际选中的服务/特征值，排查连不上、没数据时第一眼看这个
    @Published var gattInfo: String?

    static let serviceUUID = CBUUID(string: "FFE0")
    static let notifyUUID = CBUUID(string: "FFE1")
    static let writeUUID = CBUUID(string: "FFE2")
    /// 允许系统在后台自动重连，短距离掉线后更容易自己回来。
    /// 用原始 key 而不是 CBConnectPeripheralOptionEnableAutoReconnect 常量——
    /// 那个常量是 iOS 17 才有的，直接引用会让 iOS 16 的部署目标编译不过。
    static let connectOptions: [String: Any] = [
        "kCBConnectPeripheralOptionEnableAutoReconnect": true
    ]
    /// 记住上次连过的设备，下次一键重连
    static let lastDeviceKey = "bms_last_device"
    static let lastNameKey = "bms_last_name"

    private var manager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var notifyChar: CBCharacteristic?
    private var writeChar: CBCharacteristic?
    /// 所有能通知的特征值（一次全订阅，回应落在哪个通道都能收到）
    private var notifyCandidates: [CBCharacteristic] = []
    /// 所有能写的特征值（按可疑程度排序），收不到数据就挨个试
    private var writeCandidates: [CBCharacteristic] = []
    private var probeIndex = 0
    private var probeTimer: Timer?
    private var pollTimer: Timer?
    private let parser = AntBmsParser()
    private var started = false
    /// 扫描时拿到的外设引用：retrievePeripherals 有时拿不到刚发现的设备，自己留一份最稳
    private var found: [UUID: CBPeripheral] = [:]
    /// 是否已经拿到过第一帧
    private var gotFrame = false
    /// 连接失败后还剩几次自动重试
    private var pendingRetries = 0
    /// 这次连的设备信号强度，用来给超时提示加料
    private var connectRSSI = 0
    /// 启动时自动连：扫到名字跟上次一样的板子就直接连
    private var autoConnectArmed = false

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
        autoConnectArmed = false
        manager?.stopScan()
        let p = found[device.id]
            ?? manager?.retrievePeripherals(withIdentifiers: [device.id]).first
        guard let p else {
            lastError = "设备已不可用，请重新扫描"
            return
        }
        UserDefaults.standard.set(device.name, forKey: BmsCentral.lastNameKey)
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
            lastError = "找不到上次那块电池，正在重新搜索…"
            autoConnectArmed = true
            startScan()
            return
        }
        let rssi = devices.first { $0.id == uuid }?.rssi ?? 0
        beginConnect(p, retries: 3, rssi: rssi)
    }

    /// 启动 / 跳到仪表页时调用：能直连就直连，不能就静默扫一轮，
    /// 扫到名字跟上次一样的板子自动连上——不用人再跑去设置里点。
    func beginAutoConnect() {
        guard phase == .idle || phase == .scanning else { return }
        let auto = UserDefaults.standard.object(forKey: "bms_auto_reconnect") as? Bool ?? true
        guard auto else { return }

        let lastName = UserDefaults.standard.string(forKey: BmsCentral.lastNameKey)
        if let raw = UserDefaults.standard.string(forKey: BmsCentral.lastDeviceKey),
           let uuid = UUID(uuidString: raw) {
            if manager == nil { manager = CBCentralManager(delegate: self, queue: nil) }
            if let p = found[uuid] ?? manager?.retrievePeripherals(withIdentifiers: [uuid]).first {
                beginConnect(p, retries: 3, rssi: devices.first { $0.id == uuid }?.rssi ?? 0)
                return
            }
        }
        guard lastName != nil else { return }
        autoConnectArmed = true
        if phase != .scanning { startScan() }
        // 15 秒还没扫到就收手，别一直占着扫描
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            self?.autoConnectArmed = false
        }
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
        lastRX = ""
        rxTotal = 0
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
            return "连接超时：走近电池、确认没被官方 App 或别的手机占着，再试一次"
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

    var hasLastDevice: Bool {
        guard let raw = UserDefaults.standard.string(forKey: BmsCentral.lastDeviceKey) else { return false }
        return UUID(uuidString: raw) != nil
    }

    func forgetLast() {
        UserDefaults.standard.removeObject(forKey: BmsCentral.lastDeviceKey)
        UserDefaults.standard.removeObject(forKey: BmsCentral.lastNameKey)
        disconnect()
    }

    func disconnect() {
        if let p = peripheral { manager?.cancelPeripheralConnection(p) }
        teardown()
    }

    private func teardown() {
        pollTimer?.invalidate()
        pollTimer = nil
        probeTimer?.invalidate()
        probeTimer = nil
        started = false
        gotFrame = false
        pendingRetries = 0
        probeIndex = 0
        notifyCandidates = []
        writeCandidates = []
        parser.reset()
        notifyChar = nil
        writeChar = nil
        telemetry = nil
        connectedName = nil
        lastFrame = []
        gattInfo = nil
        phase = .idle
    }

    // MARK: 轮询 + 试通道

    private func beginPolling() {
        pollTimer?.invalidate()
        let t = Timer(timeInterval: 1.0, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
        tick()
    }

    @objc private func tick() {
        guard let p = peripheral else { return }
        guard !writeCandidates.isEmpty else { return }
        let w = writeCandidates[min(probeIndex, writeCandidates.count - 1)]
        writeChar = w
        // 有 withResponse 就用它：这些串口模块在 withoutResponse 下偶尔丢包
        let type: CBCharacteristicWriteType =
            w.properties.contains(.write) ? .withResponse : .withoutResponse
        p.writeValue(Data(AntBmsParser.statusRequest), for: w, type: type)
    }

    /// 2.5 秒还没回一帧就换下一个写特征值试试。
    /// 保护板模块的分通道五花八门（Data / honeTX / screenTX / powerTX…），
    /// 与其猜，不如一个个试过去，哪条回数据就记住哪条。
    private func startProbeWatchdog() {
        probeTimer?.invalidate()
        guard writeCandidates.count > 1 else { return }
        let t = Timer(timeInterval: 2.5, repeats: true) { [weak self] _ in
            guard let self, self.started, !self.gotFrame else { return }
            self.probeIndex = (self.probeIndex + 1) % self.writeCandidates.count
            self.writeChar = self.writeCandidates[self.probeIndex]
            self.updateGattInfo()
            self.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        probeTimer = t
    }

    private func updateGattInfo() {
        guard let n = notifyChar, let w = writeChar else { return }
        var s = "FFE0 / \(short(n.uuid)) 通知 → \(short(w.uuid)) 写入"
        if writeCandidates.count > 1 {
            s += " · 试 \(probeIndex + 1)/\(writeCandidates.count)"
        }
        gattInfo = s
    }

    private func short(_ u: CBUUID) -> String {
        let s = u.uuidString
        if s.count == 36, s.hasPrefix("0000"), s.hasSuffix("-0000-1000-8000-00805F9B34FB") {
            return String(s.dropFirst(4).prefix(4))
        }
        return s
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
        let brand = BmsBrand.match(name)
        let likely = brand != nil || services.contains(BmsCentral.serviceUUID)

        if let idx = devices.firstIndex(where: { $0.id == peripheral.identifier }) {
            devices[idx].rssi = RSSI.intValue
            devices[idx].likely = likely
            devices[idx].brand = brand
        } else {
            found[peripheral.identifier] = peripheral
            devices.append(Device(id: peripheral.identifier, name: name,
                                  rssi: RSSI.intValue, likely: likely, brand: brand))
        }
        // 保护板排前面，同组内信号强的排前面
        devices.sort { a, b in
            if a.likely != b.likely { return a.likely }
            return a.rssi > b.rssi
        }

        // 启动自动重连：扫到跟上次同名的板子，直接连
        if autoConnectArmed {
            let lastName = UserDefaults.standard.string(forKey: BmsCentral.lastNameKey)?.uppercased()
            let current = name.uppercased()
            // 广播名可能被截断，两边互相前缀都算同一个
            let same = lastName.map { current == $0 || current.hasPrefix($0) || $0.hasPrefix(current) } ?? false
            if same {
                autoConnectArmed = false
                central.stopScan()
                UserDefaults.standard.set(peripheral.identifier.uuidString,
                                          forKey: BmsCentral.lastDeviceKey)
                beginConnect(peripheral, retries: 3, rssi: RSSI.intValue)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectedName = peripheral.name
        lastError = nil
        gotFrame = false
        pendingRetries = 0
        phase = .connected
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: BmsCentral.lastDeviceKey)
        if let n = peripheral.name {
            UserDefaults.standard.set(n, forKey: BmsCentral.lastNameKey)
        }
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
        teardown()
        lastError = describe(error)
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

        // 通知：全部订阅，回应落在哪个通道都能收到
        let newNotify = chars.filter(notifiable)
        for c in newNotify where !notifyCandidates.contains(where: { $0.uuid == c.uuid }) {
            notifyCandidates.append(c)
        }

        // 写入：按可疑程度排序
        // 1) 「通知+写」全能型（多数保护板的 Data 通道，你这块板就是 FFE1）
        // 2) 显式 FFE2
        // 3) 只写不通知的（honeTX / screenTX / powerTX 这类）
        // 4) 其余能写的
        var ordered: [CBCharacteristic] = []
        let combo = chars.filter { notifiable($0) && writable($0) }
        if let c = combo.first(where: { $0.uuid == BmsCentral.notifyUUID }) ?? combo.first {
            ordered.append(c)
        }
        if let c = chars.first(where: { $0.uuid == BmsCentral.writeUUID && writable($0) }),
           !ordered.contains(where: { $0.uuid == c.uuid }) {
            ordered.append(c)
        }
        for c in chars where writable(c) && !notifiable(c) {
            if !ordered.contains(where: { $0.uuid == c.uuid }) { ordered.append(c) }
        }
        for c in chars where writable(c) {
            if !ordered.contains(where: { $0.uuid == c.uuid }) { ordered.append(c) }
        }
        for c in ordered where !writeCandidates.contains(where: { $0.uuid == c.uuid }) {
            writeCandidates.append(c)
        }

        startIfReady()
        // 特征值是分服务陆续报上来的，后面又发现新的可写通道就把试通道也开起来
        if started, probeTimer == nil, !gotFrame, writeCandidates.count > 1 {
            startProbeWatchdog()
            updateGattInfo()
        }
    }

    private func startIfReady() {
        guard !started,
              let p = peripheral,
              let n = notifyCandidates.first,
              !writeCandidates.isEmpty else { return }
        started = true
        notifyChar = n
        writeChar = writeCandidates[0]
        probeIndex = 0
        for c in notifyCandidates {
            p.setNotifyValue(true, for: c)
        }
        updateGattInfo()
        beginPolling()
        startProbeWatchdog()

        // 8 秒还没回一帧，如实告诉用户
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak self] in
            guard let self, self.started, !self.gotFrame else { return }
            if self.rxTotal > 0 {
                self.lastError = "收到 \(self.rxTotal) 字节但不认识：可能不是蚂蚁协议，去数据台看原始字节"
            } else {
                self.lastError = "已连上但 8 秒没收到任何数据：确认这块板支持蓝牙读取"
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            lastError = "写入失败（\(short(characteristic.uuid))）：\(error.localizedDescription)"
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value, !data.isEmpty else { return }

        // 不管能不能解析，先把收到的原始字节记下来——不通时全靠这个定位
        let bytes = [UInt8](data)
        rxTotal += bytes.count
        lastRX = bytes.prefix(48).map { String(format: "%02X", $0) }.joined(separator: " ")

        if let t = parser.feed(bytes) {
            gotFrame = true
            probeTimer?.invalidate()
            probeTimer = nil
            telemetry = t
            lastFrame = parser.lastFrame
            lastError = nil
            phase = .online
            frameCount += 1
            updateGattInfo()
        }
    }
}
