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
    /// 收到多少条通知 / 最近几帧的形状（功能码·字节数）。
    /// 条数一直涨、解析成功数不涨，就说明板子在回、但我们拼不出来——一眼能分清是断流还是解析不了。
    @Published var rxCount = 0
    /// 已经往板子写出去多少帧。收不到数据时用来区分「根本没写出去」和「写了板子不回」
    @Published var txCount = 0
    @Published var rxShape = ""
    private var shapeQueue: [String] = []
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
    /// 上次跑通的写入通道（FFF3 这类短名）。存下来下次优先用它，
    /// 免掉一上来挨个试通道的那十几秒。
    static let savedWriteKey = "bms_write_char"

    /// 特征值 UUID 的稳定短名，用来在 UserDefaults 里记通道
    static func key(for uuid: CBUUID) -> String {
        let s = uuid.uuidString
        if s.count == 36, s.hasPrefix("0000"), s.hasSuffix("-0000-1000-8000-00805F9B34FB") {
            return String(s.dropFirst(4).prefix(4))
        }
        return s
    }

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
    /// 带响应写出去后，等回音期间不再追写
    private var awaitingReply = false
    /// 发出去的那一帧还没等到应答的时间点。应答到了就清空——下一帧立刻可以发。
    /// 这是解决「空转时数据不动」的关键：模块把一帧拆成七八个通知慢慢吐，
    /// 固定 400ms 一追问就会把上一帧截断，CRC 永远过不了，于是只停留在连上时那第一帧。
    private var pendingSince: Date?
    private var lastWriteAt = Date.distantPast
    private var lastProbeAt = Date.distantPast
    /// 断线自动重连
    private var reconnectTimer: Timer?
    private var reconnectAttempts = 0
    /// 上一条数据的时间，用来判断「假在线」
    @Published var lastFrameAt = Date.distantPast
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
    /// 「假在线」连续命中次数：先换通道，再考虑断链
    private var staleHits = 0
    private var lastStaleAt = Date.distantPast
    /// 还没收到过帧时，两种写模式轮着试（见 writeStatus）
    private var tryWithResponse = false
    /// 全量枚举过特征值没有（防止 FFE0 下没通道时死循环）
    private var enumeratedAll = false
    /// 连上后「零字节」软复位只做一次，避免反复断链
    private var didSoftReset = false

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
        cancelReconnect()
        phase = .connecting
        if pendingRetries == 0 { lastError = nil }
        pendingRetries = retries
        connectRSSI = rssi
        gotFrame = false
        started = false
        staleHits = 0
        lastStaleAt = .distantPast
        gattInfo = nil
        lastRX = ""
        rxTotal = 0
        txCount = 0
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
        UserDefaults.standard.removeObject(forKey: BmsCentral.savedWriteKey)
        disconnect()
    }

    func disconnect() {
        cancelReconnect()
        if let p = peripheral { manager?.cancelPeripheralConnection(p) }
        teardown(clearData: true)
    }

    private func teardown(clearData: Bool = true) {
        pollTimer?.invalidate()
        pollTimer = nil
        probeTimer?.invalidate()
        probeTimer = nil
        started = false
        gotFrame = false
        pendingRetries = 0
        probeIndex = 0
        staleHits = 0
        lastStaleAt = .distantPast
        awaitingReply = false
        pendingSince = nil
        rxCount = 0
        txCount = 0
        rxShape = ""
        shapeQueue = []
        notifyCandidates = []
        writeCandidates = []
        parser.reset()
        notifyChar = nil
        writeChar = nil
        gattInfo = nil
        enumeratedAll = false
        // 意外掉线时先留着上一条数据，仪表页不会闪成「——」
        if clearData {
            telemetry = nil
            connectedName = nil
            lastFrame = []
            phase = .idle
        }
    }

    // MARK: 断线自动重连

    private func cancelReconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        reconnectAttempts = 0
    }

    private func scheduleReconnect() {
        reconnectTimer?.invalidate()
        guard peripheral != nil else { return }
        let delay = min(0.4 * Double(reconnectAttempts + 1), 3.0)
        reconnectAttempts += 1
        if reconnectAttempts > 8 {
            cancelReconnect()
            teardown(clearData: true)
            lastError = "重连 8 次都没成功，请靠近电池或重新搜索"
            return
        }
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self, let p = self.peripheral else { return }
            self.phase = .connecting
            p.delegate = self
            self.manager?.connect(p, options: BmsCentral.connectOptions)
        }
        RunLoop.main.add(t, forMode: .common)
        reconnectTimer = t
    }

    // MARK: 轮询 + 试通道

    /// 轮询周期：默认 400ms（2.5 次/秒）。以前 1 秒一次，肉眼看就是「数据慢半拍」。
    private var pollInterval: TimeInterval {
        let ms = UserDefaults.standard.double(forKey: "bms_poll_ms")
        return ms >= 200 ? ms / 1000.0 : 0.4
    }

    private func beginPolling() {
        pollTimer?.invalidate()
        let t = Timer(timeInterval: pollInterval, target: self, selector: #selector(tick),
                      userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
        tick()
    }

    @objc private func tick() {
        guard let p = peripheral, !writeCandidates.isEmpty else { return }

        // 假在线：还连着但 6 秒没有一帧。先换写入通道试（模块复位后通道可能变了），
        // 两次都不行才断链重建——重建一次要好几秒，能不断就不断。
        if gotFrame, Date().timeIntervalSince(lastFrameAt) > 6,
           Date().timeIntervalSince(lastStaleAt) > 2.5 {
            lastStaleAt = Date()
            staleHits += 1
            awaitingReply = false
            pendingSince = nil
            if staleHits <= 2, writeCandidates.count > 1 {
                probeIndex = (probeIndex + 1) % writeCandidates.count
                writeChar = writeCandidates[probeIndex]
                updateGattInfo()
                lastError = "数据停了，正在换通道重试（\(staleHits)/2）…"
                writeStatus(p)
                return
            }
            lastError = "连不上数据了，正在重建连接…"
            manager?.cancelPeripheralConnection(p)
            return
        }

        // 上一次请求出去还没等到应答就先别追着写。1.2 秒是给模块吐完整一帧的余量：
        // 蚂蚁板一帧 152 字节，MTU 20 时要拆成八条通知，固定 400ms 催一次会把帧截断，
        // 截断帧 CRC 必错，于是永远停在连上时的第一帧。等应答再发，节奏自然跟着模块走。
        if let sentAt = pendingSince, Date().timeIntervalSince(sentAt) < 1.2 { return }

        // 频率改了就地重建定时器
        if abs((pollTimer?.timeInterval ?? 0) - pollInterval) > 0.01 {
            beginPolling()
            return
        }

        switchProbeIfNeeded()
        writeChar = writeCandidates[min(probeIndex, writeCandidates.count - 1)]
        writeStatus(p)
    }

    /// 往当前写入通道发一帧状态查询
    private func writeStatus(_ p: CBPeripheral) {
        guard let w = writeChar else { return }
        // 能不带响应就不带：省一个来回，数据更跟手；模块不支持再退回 withResponse
        var type: CBCharacteristicWriteType =
            w.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        // 还没收到过帧时两种模式轮流试。有的保护板只认「带响应」的写，
        // 光按「支持哪个用哪个」会一直撞在模块不理的那一边，看上去就是连上了没数据。
        if !gotFrame, w.properties.contains(.write), w.properties.contains(.writeWithoutResponse) {
            tryWithResponse.toggle()
            type = tryWithResponse ? .withResponse : .withoutResponse
        }
        // 但「2.5 秒没有新帧」时改成要响应的写：有的模块在没有响应的写队列里卡住后会静默丢包，
        // 带响应的一次写能把队列和链路都拽回来，顺便还能拿到系统的写入错误。
        if gotFrame, Date().timeIntervalSince(lastFrameAt) > 2.5, w.properties.contains(.write) {
            type = .withResponse
        }
        awaitingReply = (type == .withResponse)
        lastWriteAt = Date()
        pendingSince = Date()
        txCount += 1
        p.writeValue(Data(AntBmsParser.statusRequest), for: w, type: type)
    }

    /// 还没出数据时，每 1.5 秒换下一个写特征值试。
    /// 保护板模块的分通道五花八门（Data / honeTX / screenTX / powerTX…），
    /// 与其猜，不如一个个试过去，哪条回数据就锁定哪条。
    private func switchProbeIfNeeded() {
        guard !gotFrame, writeCandidates.count > 1 else { return }
        guard Date().timeIntervalSince(lastProbeAt) > 1.5 else { return }
        lastProbeAt = Date()
        probeIndex = (probeIndex + 1) % writeCandidates.count
        updateGattInfo()
    }

    private func startProbeWatchdog() {
        // 探测已经合进 tick()，这里只留个入口兼容旧的调用点
        lastProbeAt = Date()
    }

    private func updateGattInfo() {
        guard let n = notifyChar, let w = writeChar else { return }
        var s = "FFE0 / \(short(n.uuid)) 通知 → \(short(w.uuid)) 写入"
        if gotFrame {
            s += " · 已锁定"
        } else if writeCandidates.count > 1 {
            s += " · 试 \(probeIndex + 1)/\(writeCandidates.count)"
        }
        gattInfo = s
    }

    private func short(_ u: CBUUID) -> String {
        BmsCentral.key(for: u)
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
        cancelReconnect()
        phase = .connected
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: BmsCentral.lastDeviceKey)
        if let n = peripheral.name {
            UserDefaults.standard.set(n, forKey: BmsCentral.lastNameKey)
        }
        peripheral.delegate = self
        scheduleConnectWatchdog()
        peripheral.discoverServices([BmsCentral.serviceUUID])
    }

    /// 连上后 10 秒仍是「零字节」就自我修复一次，不管界面停在哪一步：
    /// ① 通道都没找到 → 全量枚举服务/特征值；
    /// ② 通道找到了、通知也订阅了、却一个字节没来 → 断链重连一次
    ///    （有的模块只在「新连接」上推数据，旧链路会静默）。
    private func scheduleConnectWatchdog() {
        didSoftReset = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.phase != .idle, !self.gotFrame else { return }

            if !self.started {
                self.lastError = "已连上，但没找到可通知/可写入的通道：这块板可能不支持蓝牙读取"
                if !self.enumeratedAll {
                    self.enumeratedAll = true
                    self.peripheral?.discoverServices(nil)
                }
                return
            }
            guard self.rxTotal == 0 else { return }

            if !self.didSoftReset, let p = self.peripheral {
                self.didSoftReset = true
                self.lastError = "已连上但收不到任何字节，正在重连一次…"
                self.manager?.cancelPeripheralConnection(p)
                return
            }
            self.lastError = "已连上但 10 秒没收到任何数据：确认这块板支持蓝牙读取"
        }
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
        // 蚂蚁板这类模块时不时自己掉一下，掉线先别把数据清空，直接进重连
        let auto = UserDefaults.standard.object(forKey: "bms_auto_reconnect") as? Bool ?? true
        teardown(clearData: false)
        guard auto else {
            teardown(clearData: true)
            lastError = describe(error)
            return
        }
        phase = .connecting
        lastError = "连接断了，正在重连（第 \(reconnectAttempts + 1) 次）…"
        scheduleReconnect()
    }
}

// MARK: - CBPeripheralDelegate

extension BmsCentral: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        if let ffe0 = services.first(where: { $0.uuid == BmsCentral.serviceUUID }) {
            peripheral.discoverCharacteristics(nil, for: ffe0)
        } else if services.isEmpty {
            // 有的固件不声明 FFE0，全量枚举再挑（只做一次，避免空结果时无限重来）
            if !enumeratedAll {
                enumeratedAll = true
                peripheral.discoverServices(nil)
            }
        } else {
            for s in services { peripheral.discoverCharacteristics(nil, for: s) }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let chars = service.characteristics ?? []

        // FFE0 底下一条特征值都没有：说明数据通道挂在别的服务上（有的固件 FFE0 只是壳）。
        // 只回退一次：把其余服务的特征值都枚举出来，别停在「连上但没通道」。
        if chars.isEmpty, !enumeratedAll {
            enumeratedAll = true
            if let all = peripheral.services, all.count > 1 {
                for s in all where s.uuid != service.uuid {
                    peripheral.discoverCharacteristics(nil, for: s)
                }
            } else {
                peripheral.discoverServices(nil)
            }
            return
        }
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

        // 上次跑通的通道排最前：一上来就命中，省掉挨个试通道的十几秒
        let saved = UserDefaults.standard.string(forKey: BmsCentral.savedWriteKey)
        var usingSaved = false
        if let saved, let idx = ordered.firstIndex(where: { BmsCentral.key(for: $0.uuid) == saved }) {
            let c = ordered.remove(at: idx)
            ordered.insert(c, at: 0)
            usingSaved = true
        }

        for c in ordered where !writeCandidates.contains(where: { $0.uuid == c.uuid }) {
            writeCandidates.append(c)
        }

        if usingSaved { probeIndex = 0 }
        startIfReady()
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

    /// 订阅有没有成功，直接决定了收不收得到数据。
    /// 以前这里失败是静默的：界面上就是「已连接」，永远等不到帧。
    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            lastError = "订阅 \(short(characteristic.uuid)) 失败：\(error.localizedDescription)"
            return
        }
        guard characteristic.isNotifying else { return }
        // 订阅成功却一直没字节，多半是写通道没猜对，催一次探测
        if !gotFrame { lastProbeAt = .distantPast }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value, !data.isEmpty else { return }

        // 不管能不能解析，先把收到的原始字节记下来——不通时全靠这个定位
        let bytes = [UInt8](data)
        rxTotal += bytes.count
        rxCount += 1
        lastRX = bytes.prefix(48).map { String(format: "%02X", $0) }.joined(separator: " ")
        let shape = bytes.count > 2
            ? String(format: "%02X·%d", bytes[2], bytes.count)
            : "\(bytes.count)B"
        shapeQueue.append(shape)
        if shapeQueue.count > 3 { shapeQueue.removeFirst(shapeQueue.count - 3) }
        rxShape = shapeQueue.joined(separator: " ")

        if let t = parser.feed(bytes) {
            gotFrame = true
            awaitingReply = false
            pendingSince = nil
            staleHits = 0
            lastStaleAt = .distantPast
            lastFrameAt = Date()
            probeTimer?.invalidate()
            probeTimer = nil
            telemetry = t
            lastFrame = parser.lastFrame
            lastError = nil
            phase = .online
            frameCount += 1
            // 这条通道是好的，记下来，下次连上直接用它
            if let w = writeChar {
                let k = BmsCentral.key(for: w.uuid)
                if UserDefaults.standard.string(forKey: BmsCentral.savedWriteKey) != k {
                    UserDefaults.standard.set(k, forKey: BmsCentral.savedWriteKey)
                }
            }
            updateGattInfo()
        }
    }
}
