# 北京时间 · 悬浮时钟（iOS 画中画 PiP 悬浮窗）

始终匹配**北京时间（UTC+8）**，且**不受设备系统时间影响**；以 iOS **画中画（PiP）**形式**悬浮在所有 App 上方、秒级跳动**，即使在后台也持续运行。

> 实现方式与"zk助手"一致：用 `AVSampleBufferDisplayLayer` 逐帧播放时间画面 → `AVPictureInPictureController` 把它变成系统级悬浮窗；静音后台音频保活让秒针在后台也走。

---

## 它怎么做到"不受系统时间影响"

1. 启动时向若干公共站点（apple / baidu / cloudflare / microsoft）读响应头 `Date`（服务器权威 GMT）。
2. 算出偏差 `offset = 网络UTC − 设备UTC` 并保存。
3. 之后显示 = `设备当前时间 + offset`，再按 `UTC+8` 格式化。
4. 悬浮窗每秒推一帧，且每 5 分钟自动重新校时修正漂移。

只要成功校时过一次，系统时间再怎么乱都不影响显示；无网络时回退到最近一次校时结果。

---

## 拿到 IPA（不需要 Mac）

本工程用 **XcodeGen 描述 + GitHub Actions 在免费 macOS runner 上编译**，你全程不需要 Mac。

1. 新建一个 **GitHub 仓库**（推荐**公开库**，macOS 构建免费不限量）。
2. 把本目录（含 `project.yml`、`.github/`、`BeijingClock/`）推上去。
3. 在仓库 **Actions** 里运行 `Build IPA (TrollStore)` 工作流。
4. 跑完在 **Artifacts** 下载 `BeijingClock.ipa`。
5. 通过隔空投送 / 文件 App / 微信等传到手机，用 **TrollStore** 打开安装。

> 前提：设备需被 TrollStore 支持（常见 iOS 14.x–16.6.1 / 17.0），且系统支持画中画（iPhone iOS 14+）。

---

## 想自己用 Mac 编译（可选）

```bash
brew install xcodegen
xcodegen generate
open BeijingClock.xcodeproj
# 选 BeijingClock scheme → 真机 → 用你的账号签名运行
```

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
│   ├── SampleBufferDisplayView.swift# 承载 AVSampleBufferDisplayLayer 的视图
│   ├── ClockFrameRenderer.swift      # 把北京时间画进 CVPixelBuffer→CMSampleBuffer
│   └── FloatingClockManager.swift    # PiP 启停 + 秒级推帧 + 静音后台保活
└── README.md
```

## 已知边界
- 悬浮窗靠画中画实现，**需系统支持 PiP**（iPhone iOS 14+；iPad 一直支持）。不支持 PiP 的设备无法悬浮。
- 静音后台音频用于保活，状态栏可能显示音频/投屏图标，属正常。
- 需要联网才能首次/持续校准；纯离线且设备时钟被改 → 显示会失效（设计边界）。
- 悬浮窗默认尺寸由帧比例(480×160)决定，可在 PiP 里缩放，但无法做到任意位置自由拖拽（受系统 PiP 窗口约束）。
