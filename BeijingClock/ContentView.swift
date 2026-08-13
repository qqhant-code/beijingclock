import SwiftUI
import UIKit

struct ContentView: View {

    @State private var running = false
    @State private var status = "校时中…"
    @State private var lastSync = ""
    @State private var floating = false
    @State private var lastError: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 22) {
                Text("北京时间 · 悬浮时钟")
                    .foregroundColor(.gray)
                    .font(.title3)

                VStack(spacing: 6) {
                    Text("开启后，时钟以悬浮窗形式盖在所有 App 上方")
                    Text("秒级跳动 · 不受系统时间影响 · 后台持续运行")
                }
                .font(.caption)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

                HStack(spacing: 8) {
                    Image(systemName: FloatingClockManager.shared.offset != 0
                          ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                        .foregroundColor(FloatingClockManager.shared.offset != 0 ? .green : .orange)
                    Text(status).foregroundColor(.gray)
                    if !lastSync.isEmpty {
                        Text("· \(lastSync)").foregroundColor(.gray).font(.caption)
                    }
                }

                // 悬浮窗状态
                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: floating ? "rectangle.on.rectangle" : "rectangle.dashed")
                            .foregroundColor(floating ? .green : (lastError == nil ? .gray : .red))
                        Text(floating ? "悬浮窗运行中" : (lastError == nil ? "悬浮窗未开启" : "悬浮窗未开启"))
                            .foregroundColor(lastError == nil ? .gray : .red)
                            .font(.caption)
                    }
                    if let err = lastError {
                        Text(err)
                            .font(.caption2)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 30)
                    }
                }

                Button(action: toggle) {
                    Text(running ? "关闭悬浮时钟" : "开启悬浮时钟")
                        .padding(.horizontal, 26).padding(.vertical, 11)
                        .background(running ? Color.red.opacity(0.18) : Color.cyan.opacity(0.15))
                        .foregroundColor(running ? .red : .cyan)
                        .clipShape(Capsule())
                }

                if running {
                    Text("提示：悬浮条可拖动；点右侧 ✕ 关闭。切到别的 App 后它仍会显示。")
                        .font(.caption2)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 36)

                    Button("增强保活(定位，仿 zk 双保活)") {
                        FloatingClockManager.shared.enableLocationKeepAlive()
                    }
                    .foregroundColor(.orange)
                    .font(.caption)
                }

                Button("立即校时") { resync() }
                    .foregroundColor(.cyan)
            }
        }
        .onAppear {
            resync()
            FloatingClockManager.shared.updateTime()
        }
        .onReceive(NotificationCenter.default.publisher(for: FloatingClockManager.pipStateNotification)) { _ in
            floating = FloatingClockManager.shared.floating
            lastError = FloatingClockManager.shared.lastError
        }
    }

    private func toggle() {
        if running {
            FloatingClockManager.shared.stop()
            running = false
            floating = false
        } else {
            resync {
                FloatingClockManager.shared.start()
                running = true
                floating = true
            }
        }
    }

    private func resync(completion: (() -> Void)? = nil) {
        TimeSync.fetchOffset { off in
            DispatchQueue.main.async {
                if let off = off {
                    FloatingClockManager.shared.offset = off
                    status = "已校准"
                    lastSync = TimeSync.formatBeijing(Date().addingTimeInterval(off))
                } else {
                    status = "校时失败(将用上次结果)"
                }
                completion?()
            }
        }
    }
}
