import UIKit

/// 透明穿透根视图：自身不拦截触摸，只有内部子视图（时钟条）可交互，
/// 条外区域触摸会穿透到下方 App。
final class PassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        // 点到空白处时 super 会返回 self（因为 self 可交互），这里改返回 nil 实现穿透
        return hit === self ? nil : hit
    }
}

/// 悬浮时钟窗口：一个 windowLevel 高于状态栏的 UIWindow，盖在所有 App 之上。
///
/// 模仿「zk助手」的实现方式（与系统画中画 PiP 无关）：
/// - 自建 UIWindow + 高 windowLevel，所以能悬浮在任何 App 上方；
/// - 根视图透明且触摸穿透，只有时钟条本身可拖动/点击；
/// - 配合后台静音音频保活（见 FloatingClockManager），切到别的 App 后窗口仍持续显示。
final class FloatingClockWindow: UIWindow {

    /// 单例
    static var shared: FloatingClockWindow?

    /// 悬浮条尺寸（细长条，类似 zk 助手顶部）
    static let barWidth: CGFloat = 320
    static let barHeight: CGFloat = 64

    private let clockBar = UIView()
    private let timeLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private var dragOffset = CGPoint.zero
    private var barCenterX: NSLayoutConstraint!
    private var barTop: NSLayoutConstraint!

    init(scene: UIWindowScene) {
        super.init(windowScene: scene)
        // 高于状态栏，低于系统 alert，保证盖在所有普通 App 之上。
        // 用硬编码安全值避免依赖已废弃的 UIWindow.Level.statusBar。
        self.windowLevel = UIWindow.Level(rawValue: 2001)
        self.frame = scene.screen.bounds
        self.backgroundColor = .clear
        self.isHidden = true
        setupRoot()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func setupRoot() {
        let vc = UIViewController()
        let root = PassthroughView()
        root.backgroundColor = .clear
        vc.view = root

        // 时钟条：固定尺寸，可交互、可拖动；其余区域穿透
        clockBar.backgroundColor = UIColor(white: 0.05, alpha: 0.82)
        clockBar.layer.cornerRadius = 14
        clockBar.layer.masksToBounds = true
        root.addSubview(clockBar)
        clockBar.translatesAutoresizingMaskIntoConstraints = false
        barTop = clockBar.topAnchor.constraint(equalTo: root.topAnchor, constant: 8)
        barCenterX = clockBar.centerXAnchor.constraint(equalTo: root.centerXAnchor)
        NSLayoutConstraint.activate([
            barTop,
            barCenterX,
            clockBar.widthAnchor.constraint(equalToConstant: FloatingClockWindow.barWidth),
            clockBar.heightAnchor.constraint(equalToConstant: FloatingClockWindow.barHeight)
        ])

        // 时间文本（等宽字体，秒级跳动不抖动）
        timeLabel.text = "--:--:--.-"
        timeLabel.textColor = .white
        timeLabel.font = UIFont.monospacedSystemFont(ofSize: 30, weight: .semibold)
        timeLabel.textAlignment = .center
        clockBar.addSubview(timeLabel)
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            timeLabel.leadingAnchor.constraint(equalTo: clockBar.leadingAnchor, constant: 14),
            timeLabel.centerYAnchor.constraint(equalTo: clockBar.centerYAnchor),
            timeLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -6)
        ])

        // 关闭按钮：点击停止悬浮
        closeButton.setTitle("✕", for: .normal)
        closeButton.setTitleColor(.lightGray, for: .normal)
        closeButton.titleLabel?.font = UIFont.systemFont(ofSize: 20, weight: .medium)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        clockBar.addSubview(closeButton)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            closeButton.trailingAnchor.constraint(equalTo: clockBar.trailingAnchor, constant: -10),
            closeButton.centerYAnchor.constraint(equalTo: clockBar.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 30),
            closeButton.heightAnchor.constraint(equalToConstant: 30)
        ])

        // 拖动整个浮窗
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        clockBar.addGestureRecognizer(pan)

        self.rootViewController = vc
    }

    /// 显示并定位（默认顶部居中）。window 的 frame 由系统给定，时钟条在内部定位。
    func showFloating() {
        self.isHidden = false
        // 若系统给的 frame 是整屏，时钟条已在顶部居中；若为自定义小窗也一样显示。
    }

    func hideFloating() {
        self.isHidden = true
    }

    /// 由 FloatingClockManager 每秒调用，更新显示
    func setTime(_ text: String) {
        timeLabel.text = text
    }

    @objc private func closeTapped() {
        FloatingClockManager.shared.stop()
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        guard let scene = windowScene else { return }
        let loc = g.location(in: nil)
        let barW = FloatingClockWindow.barWidth
        let barH = FloatingClockWindow.barHeight
        let sw = scene.screen.bounds.width
        let sh = scene.screen.bounds.height
        switch g.state {
        case .began:
            // 记录手指在条内的相对偏移
            let barX = (sw - barW) / 2 + barCenterX.constant
            let barY = barTop.constant
            dragOffset = CGPoint(x: loc.x - barX, y: loc.y - barY)
        case .changed:
            var newX = loc.x - dragOffset.x
            var newY = loc.y - dragOffset.y
            newX = max(0, min(newX, sw - barW))
            newY = max(0, min(newY, sh - barH))
            // centerX 约束的 constant 是相对屏幕中心的偏移
            barCenterX.constant = newX - (sw - barW) / 2
            barTop.constant = newY
        default:
            break
        }
    }
}
