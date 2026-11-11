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
        /// 是否为已知控制器品牌（凌博 / 远驱 / Sabvoton / Kelly…）
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

    /// 演示模式：没连蓝牙也把仪表画出来（DemoPlayer 喂假数据）。
    /// 只存在内存里，不进 UserDefaults——关掉 App 自动恢复真实状态。
    @Published var demoMode = false
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
    /// 最近一帧的完整长度（含帧头与校验）——挡位/转把显示不出来时，先看这个
    @Published var lastFrameLength = 0
    /// 最近一帧实时帧原始字节，供数据台逐字节核对
    @Published var lastRealtimeFrame: [UInt8] = []
    /// 最近一帧配置帧（0x60）原始字节
    @Published var lastConfigFrame: [UInt8] = []
    /// 最近一次解析实际用了哪些偏移
    @Published var fieldTrace = LingboParser.FieldTrace()

    // MARK: 测速（GPS 优先，轮速兜底）

    private let gps = GPSSpeedProvider()
    /// 由控制器转速 + 轮周长换算出来的车速
    @Published var wheelSpeedKmh: Double = 0
    /// GPS 解算出来的车速
    @Published var gpsSpeedKmh: Double = 0
    @Published var gpsActive = false
    @Published var gpsAccuracyM: Double = -1
    @Published var gpsStatusText = "未启用"
    /// 当前速度来自哪里："GPS" / "轮速" / "GPS 无信号"
    @Published var speedSourceLabel = "—"
    private var lastSpeedDate = Date()

    override init() {
        super.init()
        gps.onUpdate = { [weak self] kmh, acc, valid in
            guard let self else { return }
            self.gpsSpeedKmh = kmh
            self.gpsAccuracyM = acc
            self.gpsActive = valid
            self.recomputeSpeed()
        }
        gps.onStatus = { [weak self] text, ok in
            guard let self else { return }
            self.gpsStatusText = text
            if !ok {
                self.gpsActive = false
                self.recomputeSpeed()
            }
        }
    }

    static let serviceUUID = CBUUID(string: "FFF0")
    static let notifyUUID = CBUUID(string: "FFF1")
    static let writeUUID = CBUUID(string: "FFF2")
    static let namePrefix = "LBMC"
    static let defaultWheelCircMM: Double = 1466
    /// 设置项：扫描时是否显示全部蓝牙设备（默认只显示 LBMC）
    static let showAllDevicesKey = "scan_all_devices"
    /// 上次连过的控制器，下次开机直接连（跟电池那套一个思路）
    static let lastDeviceKey = "ctrl_last_device"
    static let lastNameKey = "ctrl_last_name"
    /// 设置项：自动连接上次的控制器，默认开
    static let autoConnectKey = "ctrl_auto_reconnect"

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
    /// 自动连接：等待出现的上次那台控制器名字（大写）
    private var autoConnectName: String?
    /// 已收到的通知帧数。远驱那种「订阅了不推」的情况靠它判断要不要探活
    private var rxFrames = 0
    /// 探活性读取只做一次，别把通道当缓存轮询
    private var probedRead = false
    /// 用户手动点了「断开」之后，就别再自动连回来，免得甩不掉
    private var suppressAutoConnect = false

    // MARK: - 对外操作

    func startScan() {
        reconnectAttempts = 0
        suppressAutoConnect = false
        devices.removeAll()
        phase = .scanning
        if manager == nil {
            manager = CBCentralManager(delegate: self, queue: nil)
        } else if manager?.state == .poweredOn {
            manager?.scanForPeripherals(withServices: nil, options: nil)
        }
    }

    /// 启动 / 回到扫描页时调用：能直连上次那台就直连，直连不了就静默扫一轮，
    /// 扫到同名设备自动连——跟电池那边的 beginAutoConnect 一个套路。
    func beginAutoConnect() {
        guard phase == .idle, !suppressAutoConnect else { return }
        let auto = UserDefaults.standard.object(forKey: CockpitCentral.autoConnectKey) as? Bool ?? true
        guard auto else { return }

        if manager == nil { manager = CBCentralManager(delegate: self, queue: nil) }

        // 1) 系统还认得上一次那台 → 直接连，不用扫
        if let raw = UserDefaults.standard.string(forKey: CockpitCentral.lastDeviceKey),
           let uuid = UUID(uuidString: raw),
           let p = manager?.retrievePeripherals(withIdentifiers: [uuid]).first {
            log("自动连接上次的控制器 \(p.name ?? "")")
            phase = .connecting
            peripheral = p
            p.delegate = self
            manager?.connect(p, options: nil)
            return
        }

        // 2) 认不得（换了手机、系统清了缓存）→ 静默扫，按名字等它出现
        guard let last = UserDefaults.standard.string(forKey: CockpitCentral.lastNameKey),
              !last.isEmpty else { return }
        autoConnectName = last.uppercased()
        startScan()
        log("正在等上次那台 \(last) 出现…")
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self else { return }
            self.autoConnectName = nil
            if self.phase == .scanning { self.stopScan() }
        }
    }

    var hasLastDevice: Bool {
        guard let raw = UserDefaults.standard.string(forKey: CockpitCentral.lastDeviceKey) else { return false }
        return UUID(uuidString: raw) != nil
    }

    /// 忘掉这台控制器：下次不再自动连
    func forgetLast() {
        UserDefaults.standard.removeObject(forKey: CockpitCentral.lastDeviceKey)
        UserDefaults.standard.removeObject(forKey: CockpitCentral.lastNameKey)
        suppressAutoConnect = true
        disconnect()
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
        // 记住这台，下次开机自动连
        UserDefaults.standard.set(device.id.uuidString, forKey: CockpitCentral.lastDeviceKey)
        UserDefaults.standard.set(device.name, forKey: CockpitCentral.lastNameKey)
        suppressAutoConnect = false
        phase = .connecting
        peripheral = p
        p.delegate = self
        manager?.connect(p, options: nil)
    }

    func disconnect() {
        reconnectAttempts = 99
        // 手动断开就是不想连了，别再被自动连接拽回来
        suppressAutoConnect = true
        if let p = peripheral { manager?.cancelPeripheralConnection(p) }
    }

    func log(_ text: String) {
        appendLine("", text)
    }

    /// 主动再读一次配置帧（0x60）。只读命令，用来把配置区完整抓下来查挡位。
    func requestConfigFrame() {
        guard let p = peripheral, let w = writeChar else { return }
        p.writeValue(Data(Lingbo.calibrationRequest), for: w, type: .withoutResponse)
        log("手动重读配置帧（0x60）")
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
        driver.applyLayoutFromDefaults()
        // 长帧请求是为了逼出带转把/挡位的完整帧；控制器不认这个 LEN 就会一直不回应，
        // 3 秒没有有效实时帧就自动退回标准帧，避免把仪表搞成一片「——」。
        if UserDefaults.standard.bool(forKey: "long_realtime_request"),
           Date().timeIntervalSince(lastTelemetryDate) > 3.0 {
            driver.disableLongRequest()
            log("长帧请求 3 秒无有效回应，已自动回退标准实时帧")
        }
        let cmd = driver.nextRequestFrame()
        // 远驱这类「只推不接」的控制器不返回请求帧，直接跳过写入
        guard !cmd.isEmpty else { return }
        p.writeValue(Data(cmd), for: w, type: .withoutResponse)
    }

    // MARK: - 遥测发布

    private func publish(_ t: LingboParser.Telemetry) {
        // 周长来源优先级：实测覆盖 > 轮胎模型估算（含车重/人重/胎压/下沉量）
        let circumf = TireModel.effectiveCircumferenceMM()
        let scale = UserDefaults.standard.object(forKey: "rpm_scale") as? Double ?? 1.0
        var v = Double(t.rpm) * scale * circumf * 60.0 / 1_000_000.0
        if v < 0 { v = 0 }
        if v > 200 { v = 200 }
        wheelSpeedKmh = v
        wheelCircMM = circumf
        wheelCircSource = TireModel.circumferenceSourceText()
        lastTelemetryDate = Date()
        recomputeSpeed()
    }

    /// 按设置决定仪表用哪个速度，并顺带积分本次里程
    private func recomputeSpeed() {
        let mode = UserDefaults.standard.string(forKey: "speed_source") ?? "auto"
        var v: Double = 0
        var label = "轮速"

        switch mode {
        case "wheel":
            v = wheelSpeedKmh
            label = "轮速"
        case "gps":
            v = gpsActive ? gpsSpeedKmh : 0
            label = gpsActive ? "GPS" : "GPS 无信号"
        default:   // auto：GPS 优先，失锁时退回轮速
            if gpsActive {
                v = gpsSpeedKmh
                label = "GPS"
            } else {
                v = wheelSpeedKmh
                label = "轮速"
            }
        }

        if v < 0 { v = 0 }
        if v > 200 { v = 200 }
        speedKmh = v
        speedSourceLabel = label

        let now = Date()
        let dt = now.timeIntervalSince(lastSpeedDate)
        if dt > 0 && dt < 5 {
            tripKm += v * dt / 3600.0
        }
        lastSpeedDate = now
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
                    let len = t.raw.count
                    var extras: [String] = []
                    if let to = driver.trace.throttleOffset {
                        extras.append("转把@\(to)=\(String(format: "%.2f", t.throttleVolts ?? 0))V")
                    } else {
                        extras.append("转把 无")
                    }
                    if let go = driver.trace.gearOffset {
                        extras.append("挡位@\(go)=\(t.gear ?? 0)\(driver.trace.gearFallback ? "(回退)" : "")")
                    } else {
                        extras.append("挡位 无")
                    }
                    note = String(format: "实时 len=%d rpm=%d V=%.1f A=%.1f 故障=0x%X | ",
                                  len, t.rpm, t.busVoltage, t.busCurrent, t.fault & 0xFFFF)
                        + extras.joined(separator: " ")
                } else {
                    note = "实时帧（等待标定）"
                }
            default:
                note = String(format: "其它帧 cmd=0x%02X", bytes[3])
            }
        }
        appendLine(hex, note)
    }

    // MARK: - 诊断导出

    /// 把最近一帧实时帧 + 关键解码结果拼成一段可直接发出去的文本
    func diagnosticReport() -> String {
        var lines: [String] = []
        lines.append("控制器 \(connectedName ?? "-") / \(identity?.suggestedLabel ?? "未识别")")
        lines.append("通道 \(transportLabel ?? "-")")
        lines.append("标定 \(driver.calibrationSummary ?? "未标定")")
        lines.append("最近帧长 \(driver.lastFrameLength) 字节")
        let f = lastRealtimeFrame
        if f.isEmpty {
            lines.append("（尚无实时帧）")
        } else {
            let cmd = f.count > 3 ? f[3] : 0
            lines.append("命令 0x" + String(format: "%02X", cmd))
            for row in stride(from: 0, to: f.count, by: 8) {
                let end = min(row + 8, f.count)
                var hexPart = ""
                for i in row..<end { hexPart += String(format: "%02X ", f[i]) }
                while hexPart.count < 24 { hexPart += " " }
                var ascii = ""
                for i in row..<end {
                    let b = f[i]
                    ascii += (b >= 0x20 && b < 0x7F) ? String(UnicodeScalar(b)) : "."
                }
                let offsetText = String(format: "%02X", row)
                lines.append("\(offsetText)  \(hexPart) \(ascii)")
            }
            if f.count >= 22 {
                let v = telemetry?.busVoltage ?? 0
                let a = telemetry?.busCurrent ?? 0
                let r = telemetry?.rpm ?? 0
                lines.append("解码 V=" + String(format: "%.2f", v)
                             + " A=" + String(format: "%.2f", a)
                             + " rpm=\(r)")
            }
            lines.append("转把: " + (telemetry?.throttleVolts.map { String(format: "%.2f V", $0) } ?? "无")
                         + "  偏移 " + (fieldTrace.throttleOffset.map { "@\($0)" } ?? "未取到"))
            lines.append("挡位: " + (telemetry?.gear.map { "P\($0)" } ?? "无")
                         + "  偏移 " + (fieldTrace.gearOffset.map { "@\($0)" } ?? "未取到"))
        }
        return lines.joined(separator: "\n")
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

        // 自动连接：扫到上次那台（广播名可能被截断，两边互相前缀都算同一台）
        if let want = autoConnectName {
            let cur = name.uppercased()
            if cur == want || cur.hasPrefix(want) || want.hasPrefix(cur) {
                autoConnectName = nil
                central.stopScan()
                UserDefaults.standard.set(peripheral.identifier.uuidString,
                                          forKey: CockpitCentral.lastDeviceKey)
                UserDefaults.standard.set(name, forKey: CockpitCentral.lastNameKey)
                phase = .connecting
                self.peripheral = peripheral
                peripheral.delegate = self
                central.connect(peripheral, options: nil)
                log("自动连接 \(name)")
                return
            }
        }

        let isKnown = ControllerIdentifier.isKnownName(name)
        let showAll = UserDefaults.standard.bool(forKey: CockpitCentral.showAllDevicesKey)
        guard isKnown || showAll else { return }
        if let idx = devices.firstIndex(where: { $0.id == peripheral.identifier }) {
            devices[idx].rssi = RSSI.intValue
            devices[idx].isKnown = isKnown
        } else {
            devices.append(DiscoveredDevice(id: peripheral.identifier, name: name,
                                            rssi: RSSI.intValue, isKnown: isKnown))
            // 已知控制器排前面
            devices.sort { ($0.isKnown ? 0 : 1, $0.name) < ($1.isKnown ? 0 : 1, $1.name) }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        reconnectAttempts = 0
        connectedName = peripheral.name
        // 连上了就记住，下次开机自动连这一台
        UserDefaults.standard.set(peripheral.identifier.uuidString,
                                  forKey: CockpitCentral.lastDeviceKey)
        if let n = peripheral.name, !n.isEmpty {
            UserDefaults.standard.set(n, forKey: CockpitCentral.lastNameKey)
        }
        autoConnectName = nil
        driver.reset()
        rxFrames = 0
        probedRead = false
        transportLabel = nil
        gattSummary = nil
        pollingStarted = false
        tripKm = 0
        lastSpeedDate = Date()
        lastFrameLength = 0
        lastRealtimeFrame = []
        lastConfigFrame = []
        fieldTrace = LingboParser.FieldTrace()
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
        gps.stop()
        gpsActive = false
        speedKmh = 0
        speedSourceLabel = "—"
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
            // 对照表落的通道对不上时（远驱 FFE0 服务里用的是 FFEC，不是 FFE1），
            // 退一步认这条服务里第一个能通知的特征
            if notifyChar == nil {
                notifyChar = chars.first {
                    $0.properties.contains(.notify) || $0.properties.contains(.indicate)
                }
                if let n = notifyChar {
                    transportLabel = "\(hint.service) / \(n.uuid.uuidString)（\(hint.label) 回退）"
                    log("\(hint.service) 里没有 \(hint.notify)，改用 \(n.uuid.uuidString) 订阅")
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

        // 未知设备：等所有服务都枚举完，取第一个可用的候选对。
        // 关键：只在「还没有通知通道」时才采纳。像 YuanQuFOC972 这种
        // FFE0/FFEC 已绑定 + FFF6/FFF7 配置通道的双服务设备，后枚举到的
        // FFF7 会把 FFEC 顶掉，结果订阅的是 FFEC、比对的是 FFF7，第一帧都进不来。
        if pendingServiceCount > 0 {
            pendingServiceCount -= 1
            if pendingServiceCount == 0, notifyChar == nil,
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
        // 远驱是「只推不接」：有通知通道就够，写通道可以没有
        guard !pollingStarted, let n = notifyChar else { return }
        pollingStarted = true
        peripheral.setNotifyValue(true, for: n)
        if let w = writeChar {
            log("通道就绪：通知 \(n.uuid.uuidString) → 写入 \(w.uuid.uuidString)")
        } else {
            log("通道就绪：通知 \(n.uuid.uuidString)（只订阅，不发请求）")
        }
        log("协议驱动：\(driver.displayName)")
        UserDefaults.standard.set(transportLabel ?? "\(n.uuid.uuidString)",
                                  forKey: "last_transport")
        // 速度主干走 GPS：连上控制器就开始定位
        lastSpeedDate = Date()
        gps.start()
        beginPolling()

        // 「只推不接」的设备订阅完可能是哑的（有的批次要主机先读一次才开流）。
        // 3 秒一帧没有就非破坏性读一次探活：读得到说明通道是通的、只是不推；
        // 读不到就说明得发开流命令——两种情况日志里能区分开。
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.rxFrames == 0, !self.probedRead else { return }
            self.probedRead = true
            self.log("订阅 3 秒无数据，读一次 \(n.uuid.uuidString) 探活")
            peripheral.readValue(for: n)
        }
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
        rxFrames += 1
        // 帧里若藏有型号字符串（版本帧常见），收集成候选
        for cand in ControllerIdentifier.asciiCandidates(in: bytes)
        where !modelCandidates.contains(cand) && modelCandidates.count < 6 {
            modelCandidates.append(cand)
            log("帧内发现字符串：\(cand)")
        }
        // 首帧嗅探：凌博还没标定时，如果这帧长得像远驱（16B + 0xAA + 0x7F3C 校验），
        // 就地换成远驱驱动。凌博一旦标定成功就不再切，避免误伤已经在跑的车。
        if !driver.isCalibrated, !(driver is FardriverParser), FardriverParser.looksLike(bytes) {
            driver = FardriverParser()
            driver.applyLayoutFromDefaults()
            lastFrameLength = 0
            lastRealtimeFrame = []
            lastConfigFrame = []
            fieldTrace = LingboParser.FieldTrace()
            log("首帧嗅探：判定为远驱控制器，切换协议驱动")
        }
        let wasCalibrated = driver.isCalibrated
        let t = driver.feed(bytes)
        lastFrameLength = driver.lastFrameLength
        if !driver.lastRealtimeFrame.isEmpty { lastRealtimeFrame = driver.lastRealtimeFrame }
        if !driver.lastConfigFrame.isEmpty { lastConfigFrame = driver.lastConfigFrame }
        fieldTrace = driver.trace
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
