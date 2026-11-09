import Foundation

// MARK: - 演示模式

/// 不连蓝牙也能看仪表效果：一个假数据发生器。
///
/// 原理很直接——按 10Hz 往 CockpitCentral / BmsCentral 里写**和真车一模一样的
/// 遥测结构**，仪表层一行都不用改。速度走一段 36 秒的循环脚本：
/// 停车 → 起步 → 巡航 → 刹车 → 全油门（NOS 会亮）→ 巡航 → 刹停，
/// 冲击光晕、抖屏、残影线这些加速特效全都会被带出来。
///
/// 不持久化：关掉 App 或点「退出预览」就恢复真实状态，
/// 免得哪天忘了它在演示，以为车连不上。
final class DemoPlayer {
    static let shared = DemoPlayer()

    private var timer: Timer?
    private var start = Date()

    /// 36 秒速度脚本：(起点, 终点, 起始车速, 结束车速)
    private static let plan: [(Double, Double, Double, Double)] = [
        (0, 3, 0, 0),       // 停车
        (3, 9, 0, 52),      // 起步
        (9, 15, 52, 52),    // 巡航
        (15, 19, 52, 12),   // 刹车
        (19, 23, 12, 88),   // 全油门，NOS
        (23, 29, 88, 88),   // 巡航
        (29, 34, 88, 0),    // 刹停
        (34, 36, 0, 0),
    ]

    func begin(central: CockpitCentral, bms: BmsCentral) {
        end(central: central, bms: bms)
        start = Date()
        central.demoMode = true

        // 10Hz 够顺：60fps 的插值来自冲击模型里的 EMA，不是数据帧率
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.tick(central: central, bms: bms)
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func end(central: CockpitCentral, bms: BmsCentral) {
        timer?.invalidate()
        timer = nil
        // 清干净，别让假数据残留到真实连接里
        central.demoMode = false
        central.speedKmh = 0
        central.telemetry = nil
        bms.telemetry = nil
    }

    private func tick(central: CockpitCentral, bms: BmsCentral) {
        let t = Date().timeIntervalSince(start)
        let v = speed(at: t)

        central.speedKmh = v
        central.tripKm += v * 0.1 / 3600

        // 控制器：电流跟车速走，电压跟着压降掉一点
        let a = v / 88 * 42 + (v > 1 ? 1.2 : 0)
        var ct = LingboParser.Telemetry()
        ct.busVoltage = 72.6 - a * 0.045
        ct.busCurrent = a
        ct.powerW = ct.busVoltage * a
        ct.phaseCurrentInferred = a * 0.72
        ct.rpm = Int(v * 38)
        ct.controllerTemp = 31 + v * 0.09
        ct.motorTemp = 28 + v * 0.12
        central.telemetry = ct

        // 电池：76% · 20S · 30Ah，放电电流取负
        var bt = AntBmsParser.Telemetry()
        bt.cellCount = 20
        bt.temps = [31, 30]
        bt.mosTemp = 33
        bt.packVoltage = 72.1
        bt.current = -a
        bt.soc = 76
        bt.soh = 98
        bt.capacityAh = 30
        bt.remainingAh = 22.8
        bt.power = 72.1 * a
        bt.deltaV = 0.012
        bms.telemetry = bt
    }

    /// smoothstep 插值：起步和刹车两头都缓，不会一格一格跳
    private func speed(at t: Double) -> Double {
        let c = t.truncatingRemainder(dividingBy: 36)
        for (a0, b0, v0, v1) in Self.plan where c >= a0 && c <= b0 {
            let p = (c - a0) / max(b0 - a0, 0.001)
            let e = p * p * (3 - 2 * p)
            return v0 + (v1 - v0) * e
        }
        return 0
    }
}
