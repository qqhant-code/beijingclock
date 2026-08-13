# 北京时间悬浮时钟 · 超详细出包流程（Windows 用户，无需 Mac）

目标：把 `BeijingClock` 工程编译成 `BeijingClock.ipa`，装到你的 iPhone（TrollStore）上跑画中画悬浮时钟。
全程不碰 Mac、不需要 Apple 开发者账号。唯一要用的"电脑"是 GitHub 的免费云端 Mac 编译机。

---

## 前置条件（先自查）

| 项目 | 要求 | 说明 |
|---|---|---|
| GitHub 账号 | 免费即可 | 用你日常账号，无需付费 |
| 仓库类型 | **公开库** | 公开库的 macOS 构建免费且不限量；私有库有分钟数限制，容易额度用完 |
| iPhone 已装 TrollStore | iOS 14.x–16.6.1 / 17.0 | 且支持画中画（iPhone iOS 14+ 都支持） |
| 本机 Git | 已装（已验证 git 2.47） | 工程目录 `BeijingClock/` 已 `git init` 完成，首个 commit 已打好 |
| 网络 | 能上 github.com | 本机上传源码 + 手机下载 IPA 都要联网 |

> 如果你还没装 TrollStore：先按你越狱/巨魔对应的教程把 TrollStore 装好，再走本流程。

---

## 第 0 步：确认本地已就绪（你应该已经好了）

打开终端（Git Bash / PowerShell 都行），进入工程目录看一眼：

```bash
cd /f/WorkBuddy/2026-08-13-12-06-34/BeijingClock
git log --oneline -1
git status
```

应看到一条 `BeijingClock: PiP floating Beijing-time clock ...` 的提交，且 `git status` 显示 `nothing to commit, working tree clean`。
如果不是，回到工程目录执行：

```bash
git init
git add -A
git -c user.name="YourName" -c user.email="you@example.com" commit -m "init"
```

---

## 第 1 步：在 GitHub 网页新建一个空仓库

1. 浏览器打开 https://github.com 并登录。
2. 右上角点 **"+"** → 选 **"New repository"**。
3. 填写：
   - **Repository name**：`BeijingClock`（随便起，建议这个）
   - **Description**：可留空或写「北京时间画中画悬浮时钟」
   - **Public / Private**：选 **Public**（公开，保证免费 Mac 构建）
   - ⚠️ **不要**勾选 "Add a README file"
   - ⚠️ **不要**勾选 "Add .gitignore" / "Choose a license"
   - 保持仓库是**完全空的**（否则和本地已提交的内容冲突，push 会失败）
4. 点 **"Create repository"**。
5. 创建成功后，页面会显示一个仓库地址，形如：
   `https://github.com/<你的用户名>/BeijingClock.git`
   把 `<你的用户名>` 记下来，下一步要用。

---

## 第 2 步：把本地工程推到 GitHub（复制粘贴即可）

回到终端，在工程目录里执行（把下面网址换成你自己的）：

```bash
# 把 <你的用户名> 换成第 1 步看到的真实用户名
git remote add origin https://github.com/<你的用户名>/BeijingClock.git

# 推送（HEAD 会自动用本地当前分支名，master 或 main 都行）
git push -u origin HEAD
```

- 若弹出登录：GitHub 现在一般用 **浏览器授权** 或 **Personal Access Token**。
  - 推荐做法：GitHub 网页 → 右上角头像 → **Settings** → **Developer settings** → **Personal access tokens** → **Tokens (classic)** → **Generate new token**，勾 `repo` 权限，生成后复制。
  - `git push` 要输用户名时填你的 GitHub 用户名；要输密码时**粘贴刚才的 token**（不是账号密码）。
- 看到 `100%` + `main`/`master -> main`/`master` 这类提示即成功。
- 回到仓库网页刷新，应能看到 `project.yml`、`BeijingClock/`、`README.md`、`.github/` 等文件。

> 推送失败常见原因：第 1 步勾了 README 导致远程非空。解决：网页删除该仓库重建成空库，再 push；或本地 `git pull --rebase origin HEAD` 后再 push。

---

## 第 3 步：触发 GitHub Actions 自动编译 IPA

1. 进入你的仓库页面。
2. 顶部标签栏点 **"Actions"**。
3. 左侧工作流列表里点 **"Build IPA (TrollStore)"**（这就是 `build.yml` 里定义的工作流）。
4. 右侧点 **"Run workflow"**（绿色按钮，有时在右边下拉里）。
5. 分支选你刚 push 的分支（默认 `master` 或 `main`），点 **"Run workflow"** 确认。
6. 页面会出现一个黄色/蓝色圆点的运行记录，点进去看实时日志。

编译过程（云端 Mac 自动做）：
- `brew install xcodegen` 装工程生成器
- `xcodegen generate` 用 `project.yml` 生成 `BeijingClock.xcodeproj`
- `xcodebuild archive` 以 **ad-hoc 无签名** 方式打包（`CODE_SIGN_IDENTITY=""`，正是 TrollStore 要的）
- 打成 `BeijingClock.ipa` 作为 Artifact 上传

> 总耗时通常 **3–6 分钟**（含装 XcodeGen 和编译）。耐心等圆点变绿 ✓。
> 如果变红 ✗：点开看日志，把报错贴给我，我直接改源码/配置。常见小问题是某个 API 的最低 iOS 版本或 PiP 调用时机。

---

## 第 4 步：下载编译好的 IPA

1. 编译成功后，在该次运行页面往下拉，找到 **"Artifacts"** 区域。
2. 点 **`BeijingClock.ipa`** 下载（是个 zip 包，里面就是 `.ipa`）。
3. 解压得到 `BeijingClock.ipa`（其实直接传手机也行，TrollStore 认 zip 里的 ipa；保险起见先解压出 `.ipa`）。

---

## 第 5 步：传到 iPhone 并安装（在手机上操作）

把 `BeijingClock.ipa` 弄到 iPhone 上，任选一种：

- **隔空投送**：Mac/iPhone 之间投送 `.ipa` 文件到手机"文件"App。
- **微信/QQ 文件传输**：发给"文件传输助手"，在手机端保存到"文件"App。
- **iCloud 云盘 / 百度网盘**：上传后在手机端下载。
- **数据线 + 爱思助手/3uTools**：连电脑直接导入。

装进 TrollStore（推荐最稳的做法）：

1. 手机上打开 **TrollStore** App。
2. 底部切到 **"Apps"** 标签 → 点右上角 **"+"**（或 "Install")。
3. 从"文件"App 里选中 `BeijingClock.ipa` → 等待安装（几秒到十几秒）。
4. 安装完成后，App 列表里出现 **BeijingClock**，点它打开即可。

> 替代方式：用"文件"App 打开 `.ipa` → 分享菜单 → 选 **"TrollStore"** 打开也能装。
> 装完**不必**信任描述文件（这就是 TrollStore 相比企业签的优势，不需要信任）。

---

## 第 6 步：使用悬浮时钟

1. 打开 **BeijingClock** App。
2. 首次会联网校时（读 apple/baidu/cloudflare/microsoft 的 `Date` 头），界面显示"已校准"。
3. 点 **"开启悬浮时钟"**（或类似按钮）→ 系统会弹出画中画窗口，浮在所有 App 之上。
4. 把 App 退到后台，悬浮窗**依然在跳秒**（靠静音后台音频保活）。
5. 拖动可移动窗口位置；双指捏合可缩放。不可任意自由拖到屏幕任意像素（受系统 PiP 约束）。
6. 想关：回 App 点关闭，或在悬浮窗上点收起/关闭按钮。

校准逻辑：每 5 分钟自动重新校时；只要成功校时过一次，你改手机系统时间/时区也不会影响显示——它始终显示真实北京时间。

---

## 排错清单

| 现象 | 原因 / 解决 |
|---|---|
| Actions 红 ✗ | 看日志，多半是源码 API 版本问题；把日志贴我，我改 |
| 没看到 Artifacts | 编译没成功（先变绿）；或用了私有库额度耗尽，换公开库 |
| TrollStore 装不上 IPA | 设备不在 TrollStore 支持范围；或 IPA 损坏，重新下载 |
| 开启后没有悬浮窗 | 设备不支持 PiP（iOS < 14）；或需在 App 内先内联播放再起 PiP，等首版验证 |
| 悬浮窗不跳秒 / 后台停 | 后台音频被系统杀；确认 App 在"后台 App 刷新"允许，且未开低电量模式极致省电 |
| 显示时间不对 | 没联网校时成功；检查网络，重开 App 让它校时 |
| 状态栏出现耳机/投屏图标 | 正常，那是静音保活音频的标识 |

---

## 一句话验证链路

`git push` → GitHub Actions 变绿 ✓ → 下载 `BeijingClock.ipa` → TrollStore 安装 → 打开 App 开启悬浮 → 系统时间随便改，北京时间不变 = 成功。
