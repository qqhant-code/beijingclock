import SwiftUI
import UIKit

struct ContentView: View {

    @State private var status = "校时中…"
    @State private var lastSync = ""
    @State private var lastError: String?
    @State private var crashText: String?
    @State private var logText = ""
    @State private var showLog = false

    /// 刷新触发器：每次收到状态通知时 + 每秒主动刷新一次，保证按钮状态始终与 manager 同步。
    @State private var refreshTick = 0

    private var isRunning: Bool {
        FloatingClockManager.shared.isRunning
    }

    private var isFloating: Bool {
        ClockPIPManager.shared.isPictureInPictureActive
    }

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
                        Text("检测到上次闪退，点下面复制发我")
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
                    Text("开启后，时钟以系统画中画悬浮在所有 App 上方")
                    Text("秒级跳动 · 不受系统时间影响 · 切 App 仍可显示")
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
                        Image(systemName: isFloating ? "rectangle.on.rectangle" : "rectangle.dashed")
                            .foregroundColor(isFloating ? .green : .gray)
                        Text(isFloating ? "画中画时钟已显示" : (isRunning ? "画中画启动中…" : "画中画未开启"))
                            .foregroundColor(isFloating ? .green : .gray)
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
                    Text(isRunning ? "关闭悬浮时钟" : "开启悬浮时钟")
                        .padding(.horizontal, 26).padding(.vertical, 11)
                        .background(isRunning ? Color.red.opacity(0.18) : Color.cyan.opacity(0.15))
                        .foregroundColor(isRunning ? .red : .cyan)
                        .clipShape(Capsule())
                }

                if isRunning || isFloating {
                    Text("提示：画中画窗口可拖动到任意角落，点窗口上的 ✕ 也可关闭。")
                        .font(.caption2)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 36)

                    Button("增强保活(定位)") {
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
        }
        .onReceive(NotificationCenter.default.publisher(for: FloatingClockManager.pipStateNotification)) { _ in
            refreshTick += 1
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            refreshTick += 1
        }
        .onChange(of: refreshTick) { _ in
            lastError = FloatingClockManager.shared.lastError
        }
    }

    private func toggle() {
        if isRunning {
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
