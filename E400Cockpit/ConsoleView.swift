import SwiftUI
import UIKit

struct ConsoleView: View {
    @EnvironmentObject var central: CockpitCentral

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("原始帧监视")
                    .font(.headline)
                Spacer()
                Button {
                    UIPasteboard.general.string = central.console
                        .map { "\($0.time)  \($0.hex)  \($0.note)" }
                        .joined(separator: "\n")
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                Button {
                    central.console.removeAll()
                } label: {
                    Image(systemName: "trash")
                }
            }
            .padding()
            if central.console.isEmpty {
                Spacer()
                Text("连接控制器后，这里会显示收到的每一帧原始字节\n\n用于核对协议：0x60 = 标定帧\n0x62 = 实时帧")
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
            } else {
                List(Array(central.console.reversed())) { line in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(timeStr(line.time))
                                .font(.caption2.monospaced())
                                .foregroundColor(.gray)
                            Spacer()
                            Text(line.note)
                                .font(.caption2)
                                .foregroundColor(line.note.contains("标定") ? .orange : .secondary)
                                .lineLimit(1)
                        }
                        Text(line.hex.isEmpty ? "—" : line.hex)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.green)
                            .textSelection(.enabled)
                    }
                }
                .listStyle(.plain)
            }
        }
        .background(Color.black.ignoresSafeArea())
    }

    private func timeStr(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: d)
    }
}
