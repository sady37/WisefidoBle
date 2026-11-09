//
//  AngleMeasureViewController.swift
//  WisefidoBle
//
//  Measure：用手机测单轴角度（界面风格参考 phyphox「Inclination」：深灰底、橙色强调、
//  顶部分页、大号数值卡 + 实时曲线；代码自写，未复用 phyphox 的 GPL 源码）。
//
//    Pitch（俯仰）：绕屏幕横轴（X）转，屏幕上沿抬起为 +
//    Roll （横滚）：绕屏幕竖轴（Y）转，屏幕右沿压低为 +
//    Yaw  （偏航）：绕竖直轴（Z）在水平面内转，俯视逆时针为 +
//
//  每次只测一种，不做欧拉角换算（欧拉分解在大角度时各轴互相耦合，读数会乱跳）：
//    Pitch / Roll 直接由重力在「屏幕坐标」两个平面上的投影求角，只看这一个轴；
//    Yaw 取相对起点姿态的旋转在竖直轴上的分量（swing-twist 分解），不受轻微倾斜影响。
//  手机平放、屏幕朝上，按 ▶ 即以当前姿态为零点。
//  Pitch / Roll 支持横屏（双手持握更稳，贴雷达方便）：按 ▶ 时锁定当前屏幕方向，测量中不随手机转屏。
//

import UIKit
import CoreMotion
import simd


final class AngleMeasureViewController: UIViewController {

    static func present(from vc: UIViewController) {
        let m = AngleMeasureViewController()
        m.modalPresentationStyle = .fullScreen
        vc.present(m, animated: true)
    }

    // MARK: - 模式

    private enum Mode: Int, CaseIterable {
        case pitch, roll, yaw
        var title: String { ["Pitch", "Roll", "Yaw"][rawValue] }
        var axis: String { ["X axis", "Y axis", "Z axis"][rawValue] }
        var hint: String {
            switch self {
            case .pitch: return "Rotation around the screen's X axis: tilt forward / backward. Top edge up = +."
            case .roll:  return "Rotation around the screen's Y axis: tilt left / right. Right edge down = +."
            case .yaw:   return "Rotation around the vertical Z axis: turn the phone flat on the table. Counter-clockwise (seen from above) = +."
            }
        }
    }

    // MARK: - phyphox 风格配色

    private enum Palette {
        static let background = UIColor(white: 0.25, alpha: 1)     // #404040
        static let bar = UIColor(white: 0.13, alpha: 1)            // 顶栏 / 分页
        static let card = UIColor(white: 0.19, alpha: 1)
        static let accent = UIColor(red: 1.0, green: 0.494, blue: 0.133, alpha: 1)   // #ff7e22
        static let text = UIColor.white
        static let secondary = UIColor(white: 0.72, alpha: 1)
        static let warning = UIColor(red: 1.0, green: 0.8, blue: 0.3, alpha: 1)
    }

    // MARK: - 状态

    private let motion = CMMotionManager()
    private var mode: Mode = .pitch
    private var running = false
    private var needsZero = false
    /// 测量中锁定的界面方向（Pitch/Roll 的屏幕坐标轴据此确定）；nil = 未锁，可随手机转屏
    private var lockedOrientation: UIInterfaceOrientation?
    private var zeroAngle = 0.0                 // Pitch/Roll 零点（度）
    private var zeroAttitude = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    private var filtered = 0.0                  // 平滑后的读数（度）
    private var startTime: TimeInterval = 0
    private var lastLabelUpdate: TimeInterval = 0

    // MARK: - 视图

    private let playButton = UIButton(type: .system)
    private var tabButtons: [UIButton] = []
    private let tabIndicator = UIView()
    private var tabIndicatorLeading: NSLayoutConstraint?
    private let hintLabel = UILabel()
    private let warningLabel = UILabel()
    private let nameLabel = UILabel()
    private let valueLabel = UILabel()
    private let zeroLabel = UILabel()
    private let dial = AngleDialView()
    private let graph = AngleGraphView()
    private let contentStack = UIStackView()
    private let leftColumn = UIStackView()

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        guard let o = lockedOrientation else { return .allButUpsideDown }
        switch o {
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        case .portraitUpsideDown: return .portraitUpsideDown
        default: return .portrait
        }
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Palette.background
        buildTopBar()
        buildContent()
        selectMode(.pitch)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stop()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyLayoutAxis()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { _ in self.moveTabIndicator() })
    }

    // MARK: - 顶栏 + 分页（phyphox：深色工具栏，右侧播放键；下方大写分页 + 橙色下划线）

    private func buildTopBar() {
        let bar = UIView()
        bar.backgroundColor = Palette.bar
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)

        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)), for: .normal)
        close.tintColor = Palette.text
        close.accessibilityLabel = "Close"
        close.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)

        let title = UILabel()
        title.text = "Measure angle"
        title.textColor = Palette.text
        title.font = .systemFont(ofSize: 19, weight: .medium)

        playButton.tintColor = Palette.accent
        playButton.addAction(UIAction { [weak self] _ in self?.togglePlay() }, for: .touchUpInside)

        let row = UIStackView(arrangedSubviews: [close, title, UIView(), playButton])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(row)

        let tabs = UIStackView()
        tabs.axis = .horizontal
        tabs.distribution = .fillEqually
        tabs.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(tabs)
        for m in Mode.allCases {
            let b = UIButton(type: .system)
            b.setTitle(m.title.uppercased(), for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
            b.tag = m.rawValue
            b.addAction(UIAction { [weak self] _ in self?.selectMode(m) }, for: .touchUpInside)
            tabs.addArrangedSubview(b)
            tabButtons.append(b)
        }

        tabIndicator.backgroundColor = Palette.accent
        tabIndicator.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(tabIndicator)
        let lead = tabIndicator.leadingAnchor.constraint(equalTo: tabs.leadingAnchor)
        tabIndicatorLeading = lead

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.topAnchor),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            row.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            row.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            row.heightAnchor.constraint(equalToConstant: 44),
            close.widthAnchor.constraint(equalToConstant: 32),
            playButton.widthAnchor.constraint(equalToConstant: 44),
            playButton.heightAnchor.constraint(equalToConstant: 44),

            tabs.topAnchor.constraint(equalTo: row.bottomAnchor),
            tabs.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            tabs.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            tabs.heightAnchor.constraint(equalToConstant: 42),

            tabIndicator.bottomAnchor.constraint(equalTo: tabs.bottomAnchor),
            tabIndicator.heightAnchor.constraint(equalToConstant: 3),
            tabIndicator.widthAnchor.constraint(equalTo: tabs.widthAnchor, multiplier: 1.0 / CGFloat(Mode.allCases.count)),
            lead,
            bar.bottomAnchor.constraint(equalTo: tabs.bottomAnchor),
        ])
        barView = bar
    }

    private var barView: UIView?

    // MARK: - 内容：说明卡、数值卡（含刻度盘）、曲线卡。竖屏上下排，横屏左右排

    private func buildContent() {
        hintLabel.textColor = Palette.secondary
        hintLabel.font = .systemFont(ofSize: 14)
        hintLabel.numberOfLines = 0

        warningLabel.textColor = Palette.warning
        warningLabel.font = .systemFont(ofSize: 14, weight: .medium)
        warningLabel.numberOfLines = 0
        warningLabel.isHidden = true

        let hintCard = card(stack([hintLabel, warningLabel], spacing: 6))

        nameLabel.textColor = Palette.text
        nameLabel.font = .systemFont(ofSize: 17, weight: .medium)
        valueLabel.textColor = Palette.text
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 52, weight: .regular)
        valueLabel.textAlignment = .right
        valueLabel.adjustsFontSizeToFitWidth = true
        valueLabel.minimumScaleFactor = 0.5
        zeroLabel.textColor = Palette.secondary
        zeroLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        zeroLabel.textAlignment = .right

        let nameCol = stack([nameLabel, zeroLabel], spacing: 4)
        nameCol.alignment = .leading
        let valueRow = UIStackView(arrangedSubviews: [nameCol, valueLabel])
        valueRow.axis = .horizontal
        valueRow.alignment = .center
        valueRow.spacing = 12
        nameCol.setContentHuggingPriority(.required, for: .horizontal)

        dial.translatesAutoresizingMaskIntoConstraints = false
        dial.heightAnchor.constraint(equalTo: dial.widthAnchor, multiplier: 0.55).isActive = true
        let valueCard = card(stack([valueRow, dial], spacing: 8))

        let graphTitle = UILabel()
        graphTitle.textColor = Palette.text
        graphTitle.font = .systemFont(ofSize: 15, weight: .medium)
        graphTitle.text = "Angle over time"
        graph.translatesAutoresizingMaskIntoConstraints = false
        graph.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        let graphCard = card(stack([graphTitle, graph], spacing: 6))
        graphTitleLabel = graphTitle

        leftColumn.axis = .vertical
        leftColumn.spacing = 10
        leftColumn.addArrangedSubview(hintCard)
        leftColumn.addArrangedSubview(valueCard)

        contentStack.spacing = 10
        contentStack.distribution = .fill
        contentStack.addArrangedSubview(leftColumn)
        contentStack.addArrangedSubview(graphCard)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentStack)

        guard let bar = barView else { return }
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 10),
            contentStack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 10),
            contentStack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -10),
            contentStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10),
        ])
        applyLayoutAxis()
    }

    private var graphTitleLabel: UILabel?
    private var landscapeWidthConstraint: NSLayoutConstraint?

    /// 横屏（高度紧凑）左右排：左列说明+数值，右列曲线
    private func applyLayoutAxis() {
        let landscape = traitCollection.verticalSizeClass == .compact
        contentStack.axis = landscape ? .horizontal : .vertical
        contentStack.alignment = .fill
        landscapeWidthConstraint?.isActive = false
        if landscape {
            landscapeWidthConstraint = leftColumn.widthAnchor.constraint(equalTo: contentStack.widthAnchor, multiplier: 0.45)
            landscapeWidthConstraint?.isActive = true
        }
        // 横屏高度有限：刻度盘让位给数值
        dial.isHidden = landscape
    }

    private func stack(_ views: [UIView], spacing: CGFloat) -> UIStackView {
        let s = UIStackView(arrangedSubviews: views)
        s.axis = .vertical
        s.spacing = spacing
        return s
    }

    private func card(_ content: UIView) -> UIView {
        let c = UIView()
        c.backgroundColor = Palette.card
        c.layer.cornerRadius = 6
        content.translatesAutoresizingMaskIntoConstraints = false
        c.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: c.topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -12),
            content.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -14),
        ])
        return c
    }

    // MARK: - 交互

    private func selectMode(_ m: Mode) {
        stop()
        mode = m
        for b in tabButtons {
            b.setTitleColor(b.tag == m.rawValue ? Palette.text : Palette.secondary, for: .normal)
        }
        moveTabIndicator()
        nameLabel.text = "\(m.title) (\(m.axis))"
        graphTitleLabel?.text = "\(m.title) (°) over time"
        resetReadout()
    }

    private func moveTabIndicator() {
        guard let first = tabButtons.first else { return }
        view.layoutIfNeeded()
        tabIndicatorLeading?.constant = first.bounds.width * CGFloat(mode.rawValue)
        view.layoutIfNeeded()
    }

    private func resetReadout() {
        hintLabel.text = "Lay the phone flat, screen up, then tap ▶ to set zero.\n" + mode.hint
            + (mode == .yaw ? "" : "\nLandscape works too: turn the phone first — the screen orientation locks when you tap ▶.")
        warningLabel.isHidden = true
        valueLabel.text = "—"
        zeroLabel.text = " "
        dial.angle = nil
        graph.clear()
        updatePlayButton()
    }

    private func updatePlayButton() {
        let name = running ? "pause.fill" : "play.fill"
        playButton.setImage(UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .bold)), for: .normal)
        playButton.accessibilityLabel = running ? "Stop" : "Start"
    }

    private func togglePlay() {
        if running { stop() } else { start() }
    }

    /// ▶：锁定当前屏幕方向，下一帧作为零点，开始测
    private func start() {
        guard motion.isDeviceMotionAvailable else {
            warningLabel.text = "Motion sensors aren't available on this device."
            warningLabel.isHidden = false
            return
        }
        lockedOrientation = view.window?.windowScene?.interfaceOrientation ?? .portrait
        setNeedsUpdateOfSupportedInterfaceOrientations()
        graph.clear()
        running = true
        needsZero = true
        UIApplication.shared.isIdleTimerDisabled = true
        updatePlayButton()
        hintLabel.text = mode.hint
        // 只用陀螺 + 加速度计（不用磁力计：雷达/金属附近会被拉偏）
        motion.deviceMotionUpdateInterval = 1.0 / 60.0
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] dm, _ in
            guard let self, let dm else { return }
            self.handle(dm)
        }
    }

    /// ❚❚：停在最后读数（phyphox 同款：暂停即冻结），解锁屏幕方向
    private func stop() {
        guard running else { return }
        motion.stopDeviceMotionUpdates()
        running = false
        lockedOrientation = nil
        setNeedsUpdateOfSupportedInterfaceOrientations()
        UIApplication.shared.isIdleTimerDisabled = false
        updatePlayButton()
    }

    // MARK: - 计算

    /// 重力在「屏幕坐标」中的分量：sx 指屏幕右、sy 指屏幕上，z 指出屏幕（单位 g）
    private func screenGravity(_ g: CMAcceleration) -> (sx: Double, sy: Double, z: Double) {
        switch lockedOrientation ?? .portrait {
        case .landscapeRight:     return (-g.y, g.x, g.z)   // 机身顶部朝左
        case .landscapeLeft:      return (g.y, -g.x, g.z)   // 机身顶部朝右
        case .portraitUpsideDown: return (-g.x, -g.y, g.z)
        default:                  return (g.x, g.y, g.z)
        }
    }

    private static func deg(_ r: Double) -> Double { r * 180 / .pi }

    /// 归到 (-180, 180]
    private static func wrap(_ a: Double) -> Double {
        var x = a.truncatingRemainder(dividingBy: 360)
        if x > 180 { x -= 360 }
        if x <= -180 { x += 360 }
        return x
    }

    private func handle(_ dm: CMDeviceMotion) {
        let g = screenGravity(dm.gravity)
        let q = dm.attitude.quaternion
        let attitude = simd_quatd(ix: q.x, iy: q.y, iz: q.z, r: q.w)

        // 单轴原始角（度）+ 另一方向的倾斜（用于提示「别歪」）
        let raw: Double
        let offAxis: Double
        switch mode {
        case .pitch:
            raw = Self.deg(atan2(-g.sy, -g.z))
            offAxis = Self.deg(asin(max(-1, min(1, g.sx))))
        case .roll:
            raw = Self.deg(atan2(g.sx, -g.z))
            offAxis = Self.deg(asin(max(-1, min(1, g.sy))))
        case .yaw:
            if needsZero { zeroAttitude = attitude }
            // 起点以来的转动（参考系下）在竖直轴上的分量
            var rel = attitude * zeroAttitude.inverse
            if rel.real < 0 { rel = simd_quatd(ix: -rel.imag.x, iy: -rel.imag.y, iz: -rel.imag.z, r: -rel.real) }
            raw = Self.deg(2 * atan2(rel.imag.z, rel.real))
            offAxis = Self.deg(acos(max(-1, min(1, -g.z))))   // 屏幕偏离水平
        }

        let now = dm.timestamp
        if needsZero {
            needsZero = false
            zeroAngle = mode == .yaw ? 0 : raw
            filtered = 0
            startTime = now
            let tilt = Self.deg(acos(max(-1, min(1, -g.z))))
            zeroLabel.text = mode == .yaw ? "zero: start heading" : String(format: "zero: %.1f°", zeroAngle)
            if tilt > 10 {
                warningLabel.text = String(format: "Not flat at start (tilted %.0f°). Lay the phone flat, screen up, and tap ▶ again.", tilt)
                warningLabel.isHidden = false
            } else {
                warningLabel.isHidden = true
            }
        } else if offAxis.magnitude > 20, warningLabel.isHidden || warningLabel.tag == 1 {
            warningLabel.tag = 1
            warningLabel.text = mode == .yaw
                ? String(format: "Keep the phone flat (tilted %.0f°) — yaw is measured around the vertical axis.", offAxis.magnitude)
                : String(format: "The other axis is tilted %.0f° — keep it level for an accurate %@.", offAxis.magnitude, mode.title.lowercased())
            warningLabel.isHidden = false
        } else if warningLabel.tag == 1, offAxis.magnitude <= 15 {
            warningLabel.tag = 0
            warningLabel.isHidden = true
        }

        // 低通平滑（~0.1 s），跨 ±180° 时按最短差值走
        let value = Self.wrap(raw - zeroAngle)
        filtered = Self.wrap(filtered + 0.2 * Self.wrap(value - filtered))

        graph.append(t: now - startTime, value: filtered)
        if now - lastLabelUpdate >= 0.1 {
            lastLabelUpdate = now
            valueLabel.text = String(format: "%.1f °", filtered)
            dial.angle = filtered
        }
    }
}

// MARK: - 刻度盘：半圆量角器，橙色弧 + 指针（读数一眼看出方向和大小）

private final class AngleDialView: UIView {
    var angle: Double? { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentMode = .redraw
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        let r = min(bounds.width / 2, bounds.height) - 14
        guard r > 10 else { return }
        let c = CGPoint(x: bounds.midX, y: bounds.maxY - 6)
        // 0° 朝上，±90° 在两侧；超出 ±90° 时指针压到底（数值照常显示）
        func point(_ deg: Double, _ radius: CGFloat) -> CGPoint {
            let a = (deg - 90) * .pi / 180
            return CGPoint(x: c.x + radius * CGFloat(cos(a)), y: c.y + radius * CGFloat(sin(a)))
        }
        let grey = UIColor(white: 0.55, alpha: 1)
        let arc = UIBezierPath(arcCenter: c, radius: r, startAngle: .pi, endAngle: 0, clockwise: true)
        grey.setStroke(); arc.lineWidth = 1.5; arc.stroke()

        let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 10), .foregroundColor: grey]
        for d in stride(from: -90, through: 90, by: 10) {
            let major = d % 30 == 0
            let p = UIBezierPath()
            p.move(to: point(Double(d), r)); p.addLine(to: point(Double(d), r - (major ? 10 : 5)))
            p.lineWidth = major ? 1.5 : 1; p.stroke()
            if major {
                let s = "\(d)" as NSString
                let sz = s.size(withAttributes: attrs)
                let lp = point(Double(d), r - 20)
                s.draw(at: CGPoint(x: lp.x - sz.width / 2, y: lp.y - sz.height / 2), withAttributes: attrs)
            }
        }

        guard let angle else { return }
        let shown = max(-90, min(90, angle))   // 正值指针偏右
        let accent = UIColor(red: 1.0, green: 0.494, blue: 0.133, alpha: 1)
        let a0 = -CGFloat.pi / 2, a1 = CGFloat((shown - 90) * .pi / 180)
        let sweep = UIBezierPath(arcCenter: c, radius: r - 2, startAngle: a0, endAngle: a1, clockwise: shown >= 0)
        accent.withAlphaComponent(0.6).setStroke(); sweep.lineWidth = 6; sweep.stroke()

        let needle = UIBezierPath()
        needle.move(to: c); needle.addLine(to: point(shown, r - 4))
        accent.setStroke(); needle.lineWidth = 3; needle.lineCapStyle = .round; needle.stroke()
        accent.setFill()
        UIBezierPath(ovalIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)).fill()
    }
}

// MARK: - 曲线：phyphox 式图框（深底、灰网格、橙色曲线），显示最近 30 s，纵轴自动缩放

private final class AngleGraphView: UIView {
    private var samples: [(t: Double, v: Double)] = []
    private let span = 30.0
    private var pendingRedraw = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.1, alpha: 1)
        layer.cornerRadius = 3
        contentMode = .redraw
    }
    required init?(coder: NSCoder) { fatalError() }

    func clear() { samples.removeAll(); setNeedsDisplay() }

    func append(t: Double, value: Double) {
        samples.append((t, value))
        if let last = samples.last, let i = samples.firstIndex(where: { $0.t >= last.t - span }), i > 0 {
            samples.removeFirst(i)
        }
        pendingRedraw += 1
        if pendingRedraw >= 3 { pendingRedraw = 0; setNeedsDisplay() }   // 60 Hz 数据，20 Hz 重绘
    }

    /// 1/2/5 × 10ⁿ 的刻度间隔
    private func niceStep(_ span: Double, ticks: Double) -> Double {
        let raw = span / ticks
        let mag = pow(10, floor(log10(raw)))
        for m in [1.0, 2.0, 5.0, 10.0] where raw <= m * mag { return m * mag }
        return 10 * mag
    }

    override func draw(_ rect: CGRect) {
        let font = UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let grey = UIColor(white: 0.6, alpha: 1)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: grey]
        let plot = bounds.inset(by: UIEdgeInsets(top: 8, left: 40, bottom: 20, right: 8))
        guard plot.width > 10, plot.height > 10 else { return }

        let tMax = max(span, samples.last?.t ?? 0)
        let tMin = tMax - span
        var lo = samples.map(\.v).min() ?? -1, hi = samples.map(\.v).max() ?? 1
        if hi - lo < 2 { let m = (hi + lo) / 2; lo = m - 1; hi = m + 1 }
        let pad = (hi - lo) * 0.1; lo -= pad; hi += pad

        func x(_ t: Double) -> CGFloat { plot.minX + CGFloat((t - tMin) / span) * plot.width }
        func y(_ v: Double) -> CGFloat { plot.maxY - CGFloat((v - lo) / (hi - lo)) * plot.height }

        let gridColor = UIColor(white: 0.3, alpha: 1)
        let vStep = niceStep(hi - lo, ticks: 5)
        var v = ceil(lo / vStep) * vStep
        while v <= hi {
            let p = UIBezierPath(); p.move(to: CGPoint(x: plot.minX, y: y(v))); p.addLine(to: CGPoint(x: plot.maxX, y: y(v)))
            gridColor.setStroke(); p.lineWidth = v == 0 ? 1.2 : 0.5; p.stroke()
            let s = (vStep < 1 ? String(format: "%.1f", v) : String(format: "%.0f", v)) as NSString
            let sz = s.size(withAttributes: attrs)
            s.draw(at: CGPoint(x: plot.minX - sz.width - 4, y: y(v) - sz.height / 2), withAttributes: attrs)
            v += vStep
        }
        var t = ceil(tMin / 5) * 5
        while t <= tMax {
            let p = UIBezierPath(); p.move(to: CGPoint(x: x(t), y: plot.minY)); p.addLine(to: CGPoint(x: x(t), y: plot.maxY))
            gridColor.setStroke(); p.lineWidth = 0.5; p.stroke()
            let s = String(format: "%.0f", t) as NSString
            let sz = s.size(withAttributes: attrs)
            s.draw(at: CGPoint(x: x(t) - sz.width / 2, y: plot.maxY + 3), withAttributes: attrs)
            t += 5
        }
        let unit = "t (s)" as NSString
        unit.draw(at: CGPoint(x: plot.maxX - unit.size(withAttributes: attrs).width, y: plot.maxY + 3), withAttributes: attrs)

        guard samples.count > 1 else { return }
        let line = UIBezierPath()
        line.move(to: CGPoint(x: x(samples[0].t), y: y(samples[0].v)))
        for s in samples.dropFirst() {
            line.addLine(to: CGPoint(x: x(s.t), y: y(s.v)))
        }
        UIColor(red: 1.0, green: 0.494, blue: 0.133, alpha: 1).setStroke()
        line.lineWidth = 2
        line.lineJoinStyle = .round
        line.stroke()
    }
}
