# 悬浮时钟 5.1.9 (com.hzjuzhi.FloatingClock) 反编译拆解

> 目标 IPA：`悬浮时钟_5.1.9_𝑌𝑄𝐶.ipa`（57MB，TrollStore/esign 重签）
> 拆解日期：2026-08-14
> 目的：搞清它如何在 iPhone 上实现「跨 App 真·悬浮时钟」，复用到 BeijingClock 项目。

## 一、基本身份
- BundleID：`com.hzjuzhi.FloatingClock`，DisplayName「悬浮时钟」，版本 5.1.9
- 真实上架 App（App Store id `1546947240`，links.json 可见）。
- 最低系统 iOS 15.4，arm64。
- 开发商签名：`iPhone Distribution: Beijing Zhizhangyi Inc.`
- 后台模式 `UIBackgroundModes = [audio, location, remote-notification, fetch, processing]`（含 `audio`，PiP 必需）。

## 二、悬浮机制结论（最重要）
**跨 App 悬浮 = iOS 系统 PiP（画中画），不是自建 UIWindow，也不是越狱钩子。**

证据链：
1. 主二进制链接 `AVKit` / `AVFoundation`，引用 `_OBJC_CLASS_$_AVPictureInPictureController`、`AVPictureInPictureControllerDelegate` 全套回调（`pictureInPictureControllerDidStart/WillStart/DidStop...`）。
2. 主二进制同时引用 `AVPlayerViewController` 与 `AVPictureInPictureController(playerLayer:)`，且有自定义 `playerLayer` / `videoGravity` 属性——即「自建 AVPlayerLayer → 由 AVPlayerViewController 托管取 PiP 控制器」的标准路线。
3. **关键**：`AVAudioSession` 用 `AVAudioSessionCategoryPlayback` + `AVAudioSessionModeMoviePlayback`（主二进制字符串 `Setting category to AVAudioSessionCategoryPlayback failed.` / `_AVAudioSessionModeMoviePlayback`）。这是 iPhone 上 PiP 资格通过的核心之一。
4. 时钟本体不是那堆 `.mov` 文件（那些只是 1KB 占位小视频，无音轨、尺寸≈0，是广告/开屏动效）。时钟是运行时用 `ClockHandRotationKit.framework`（与 zk 助手**同一个框架**）现画成视频，再送 PiP。
5. `FloatingClockH00k.dylib`（`libsubstrate.dylib` + `MSHookMessageEx`）里的类叫 `YQCDIView`（`actHld:`/`audRun:`/`initBox:refKey:`/`vibNow:`），引用 Apple OCSP 证书与 `initWithBase64EncodedString`——这是**反盗版 / 激活校验（DRM）组件，不是 PiP 钩子**。即：iPhone PiP 是原生就能通的，根本不需要越狱钩子。

## 三、时间源（授时）
- 框架 `Kronos.framework`（Swift NTP 客户端，与我们的 `TimeSync` 思路一致）。
- `timeSource.json`：`fallbackNTPHosts = [ntp.aliyun.com, time.cloud.tencent.com, ntp1.volces.com]`，`timeZone: Asia/Shanghai`。
- `ping.json`：默认 DNS 探测 `223.5.5.5`（阿里云）。
- 结论：用 NTP 取北京时间，不受系统时间影响——和我们方案一致，方向正确。

## 四、对我们项目（BeijingClock）的关键修正
| 项 | 我们之前（卡死） | 悬浮时钟 5.1.9 正确做法 |
|---|---|---|
| PiP 取法 | 裸 `AVPictureInPictureController(playerLayer:)` | **经 `AVPlayerViewController` 托管**，从 `playerVC.pictureInPictureController` 取（iPhone 上裸 playerLayer 的 `isPictureInPicturePossible` 永远 false） |
| 音频会话 | `.playback` + `.moviePlayback`（已对） | 同 |
| 后台模式 | `audio` + `location`（已对） | 含 `audio` |
| 视频音轨 | 静音 AAC（已加） | 需要音频轨道 |
| playerLayer 可见性 | hostView 挂在根 VC | `AVPlayerViewController.view` 必须挂在可见窗口层级，否则 `pictureInPictureController` 为 nil |

> 已据此重写 `ClockPIPManager.swift`（v2）：
> - 改用 `AVPlayerViewController` 托管，`playerVC.view` 嵌入可见 hostView，KVC 取 `pictureInPictureController`（兼容旧 SDK）。
> - `AVAudioSession` `.playback` + `.moviePlayback`。
> - `canStartPictureInPictureAutomaticallyFromInline = true`：切到别 App 自动接管浮窗（满足「切 App 仍显示」）。
> - 保留「悬浮窗」按钮（手势内 `startPictureInPicture()`）和「关闭」按钮，防卡死。
> - 视频仍含静音 AAC 音轨；轮询 `possible` 自动 start + 诊断日志。

## 五、其它发现（暂未采用）
- 广告 SDK 一大堆（CSJ/穿山甲、GDT/广点通、KS/快手、QuMeng、Oct、baidu、UMPush）——与悬浮功能无关，可忽略。
- `ttplayer.metallib`：Metal 着色器库，疑似用于某些 3D/特效页面，与时钟 PiP 无关。
- `VeLive` / `TTSDK*`：字节火山引擎直播 SDK（开播/电商相关），无关。
- `LiveActivityHelper` / `OpenDynamicIslandWidgetEntryView`：灵动岛 / 实时活动，是它另一个「悬浮」形态（锁屏/灵动岛），不是我们要的跨 App 顶部条。
