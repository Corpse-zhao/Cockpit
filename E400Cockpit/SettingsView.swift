import SwiftUI

struct SettingsView: View {
    @AppStorage("wheel_circ_mm") private var wheelCirc: Double = 1466
    @AppStorage("rpm_scale") private var rpmScale: Double = 1

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("轮周长")
                    Spacer()
                    TextField("mm", value: $wheelCirc, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                    Text("mm").foregroundColor(.gray)
                }
                Text("滚动法实测：气门嘴对地做记号 → 向前推一圈量距离。默认 1466 为 90/90-12 理论值，量好后替换成实测值，速度才准。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("车速标定")
            }

            Section {
                Picker("RPM 倍率", selection: $rpmScale) {
                    Text("×1").tag(1.0)
                    Text("×0.1").tag(0.1)
                    Text("×0.01").tag(0.01)
                    Text("×10").tag(10.0)
                }
                .pickerStyle(.segmented)
                Text("若仪表速度明显不对：在「数据台」看原始 rpm 值，与已知车速对比后选倍率（官方 App 显示过 x100RPM，故留此开关）。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("转速换算")
            }

            Section {
                LabeledContent("版本", value: "0.1.0")
                LabeledContent("协议", value: "凌博 AA55 / FFF0·FFF1·FFF2")
                LabeledContent("控制器", value: "E400Max-CAN")
                LabeledContent("车型", value: "九号 E80c MK2")
            } header: {
                Text("关于")
            }
        }
    }
}
