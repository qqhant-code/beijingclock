import SwiftUI
import UIKit

struct ContentView: View {

    @State private var running = false
    @State private var status = "校时中…"
    @State private var lastSync = ""
    @State private var floating = false
    @State private var lastError: String?
    @State private var crashText: String?
    @State private var logText = ""
    @State private var showLog = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 22) {
                Text("北京时间 · 悬浮时钟")
                    .foregroundColor(.gray)
                    .font(.title3)

                // 崩溃日志（闪退后下次进入会显示，等效崩溃报告）
                if let crash = crashText {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("⚠️ 检测到上次闪退，点下面复制发我")
                            .foregroundColor(.red)
                            .font(.caption)
                        ScrollView(.vertical, showsIndicators: true) {
                            Text(crash)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 140)
                        .padding(6)
                        .background(Color(.darkGray))
                        .cornerRadius(6)
                        HStack {
                            Button("复制崩溃日志") {
                                UIPasteboard.general.string = crash
                            }
                            .foregroundColor(.red)
                            .font(.caption)
                            Button("清除") {
                                CrashLogger.shared.clearCrash()
                                crashText = nil
                            }
                            .foregroundColor(.gray)
                            .font(.caption)
                        }
                    }
                    .padding(.horizontal, 16)
                }

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

                Button("查看运行日志") {
                    logText = CrashLogger.shared.lastLog() ?? "（暂无日志）"
                    showLog = true
                }
                .foregroundColor(.gray)
                .font(.caption)
            }
        }
        .sheet(isPresented: $showLog) {
            NavigationView {
                ScrollView {
                    Text(logText)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .navigationTitle("运行日志")
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("复制") { UIPasteboard.general.string = logText }
                    }
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("关闭") { showLog = false }
                    }
                }
            }
        }
        .onAppear {
            crashText = CrashLogger.shared.lastCrash()
            resync()
            FloatingClockManager.shared.updateTime()
        }
        .onReceive(NotificationCenter.default.publisher(for: FloatingClockManager.pipStateNotification)) { _ in
            running = FloatingClockManager.shared.isRunning
            floating = FloatingClockManager.shared.floating
            lastError = FloatingClockManager.shared.lastError
        }
    }

    private func toggle() {
        if running {
            FloatingClockManager.shared.stop()
        } else {
            resync {
                FloatingClockManager.shared.start()
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
