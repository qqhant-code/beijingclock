# 北京时间 · 悬浮时钟（iOS 自建悬浮窗）

始终匹配**北京时间（UTC+8）**，且**不受设备系统时间影响**；以**自建悬浮窗**形式**悬浮在所有 App 上方、秒级跳动**，切到别的 App 后依然显示。

> 实现方式与"zk助手"一致（经反编译其 IPA 确认）：用一个 **高 windowLevel 的 `UIWindow`** 当悬浮层（不是系统画中画 PiP）；靠 **后台静音音频(audio) + 可选定位(location)** 双保活，让 App 退到后台也不被挂起，悬浮窗持续跳秒。

---

## 它怎么做到"不受系统时间影响"

1. 启动时向若干公共站点（apple / baidu / cloudflare / microsoft）读响应头 `Date`（服务器权威 GMT）。
2. 算出偏差 `offset = 网络UTC − 设备UTC` 并保存。
3. 之后显示 = `设备当前时间 + offset`，再按 `UTC+8` 格式化。
4. 悬浮窗每 0.1 秒刷新一次，且每 5 分钟自动重新校时修正漂移。

只要成功校时过一次，系统时间再怎么乱都不影响显示；无网络时回退到最近一次校时结果。

---

## 拿到 IPA（不需要 Mac）

本工程用 **XcodeGen 描述 + GitHub Actions 在免费 macOS runner 上编译**，你全程不需要 Mac。

1. 把本目录（含 `project.yml`、`.github/`、`BeijingClock/`）推到你的 GitHub 仓库。
2. 在仓库 **Actions** 里运行 `Build IPA (TrollStore)` 工作流。
3. 跑完在 **Artifacts** 下载 `BeijingClock.ipa`。
4. 通过隔空投送 / 文件 App / 微信等传到手机，用 **TrollStore** 打开安装（装前删掉旧版）。

> 前提：设备需被 TrollStore 支持（常见 iOS 14.x–16.6.1 / 17.0）。

---

## 使用

1. 打开 App，等"已校准"。
2. 点「开启悬浮时钟」→ 屏幕顶部出现细长条时钟，可拖动，点右侧 ✕ 关闭。
3. 切到别的 App，悬浮条仍在最上方显示。
4. 若切 App 后悬浮条消失，回 App 点「增强保活(定位)」开启 location 双保活（仿 zk 助手）。

---

## 文件结构

```
BeijingClock/
├── project.yml                       # XcodeGen 工程描述（单 App target）
├── .github/workflows/build.yml       # GitHub Actions 自动出 IPA
├── BeijingClock/                     # App 源码
│   ├── BeijingClockApp.swift         # @main 入口
│   ├── ContentView.swift             # 界面：开启/关闭 悬浮时钟、校时状态
│   ├── TimeSync.swift                # 网络授时模块
│   ├── FloatingClockWindow.swift     # 自建高 windowLevel 悬浮窗 + 可拖动时钟条
│   └── FloatingClockManager.swift    # 悬浮窗启停 + 秒级刷新 + 静音/定位后台保活
└── README.md
```

## 已知边界
- 悬浮窗是自建 `UIWindow`（非系统 PiP），可自由拖动到屏幕任意位置。
- 静音后台音频用于保活，状态栏可能显示音频/投屏图标，属正常。
- 需要联网才能首次/持续校准；纯离线且设备时钟被改 → 显示会失效（设计边界）。
- 部分系统版本下纯音频保活可能不足以长时间悬浮，可在 App 内开启「增强保活(定位)」。
