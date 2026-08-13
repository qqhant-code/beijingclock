import Combine
import SwiftUI
import UIKit

struct ContentView: View {

    @State private var running = false
    @State private var status = "校时中…"
    @State private var lastSync = ""
    @State private var pipActive = false
    @State private var pipError: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 22) {
                Text("北京时间 · 悬浮时钟")
                    .foregroundColor(.gray)
                    .font(.title3)

                // 说明
                VStack(spacing: 6) {
                    Text("开启后，时钟以画中画形式悬浮在所有 App 上方")
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

                // 悬浮窗状态（诊断用）
                HStack(spacing: 6) {
                    Image(systemName: "airplayvideo")
                        .foregroundColor(pipActive ? .green : (pipError == nil ? .gray : .red))
                    Text(pipActive ? "悬浮窗运行中" : (pipError == nil ? "悬浮窗未启动" : "悬浮窗启动失败"))
                        .foregroundColor(pipError == nil ? .gray : .red)
                        .font(.caption)
                }

                Button(action: toggle) {
                    Text(running ? "关闭悬浮时钟" : "开启悬浮时钟")
                        .padding(.horizontal, 26).padding(.vertical, 11)
                        .background(running ? Color.red.opacity(0.18) : Color.cyan.opacity(0.15))
                        .foregroundColor(running ? .red : .cyan)
                        .clipShape(Capsule())
                }

                if running {
                    Button("画面翻转（若字倒着点这里）") {
                        ClockFrameRenderer.flipVertical.toggle()
                        FloatingClockManager.shared.enqueueFrame()
                    }
                    .foregroundColor(.orange)
                    .font(.caption)
                }

                Button("立即校时") { resync() }
                    .foregroundColor(.cyan)
            }
        }
        .onAppear { resync() }
        .onReceive(NotificationCenter.default.publisher(for: FloatingClockManager.pipStateNotification)) { _ in
            pipActive = FloatingClockManager.shared.pipActive
            pipError = FloatingClockManager.shared.pipError
        }
    }

    private func toggle() {
        if running {
            FloatingClockManager.shared.stop()
            running = false
            pipActive = false
        } else {
            // 先确保已校时，再启动悬浮窗
            resync {
                FloatingClockManager.shared.start()
                running = true
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
