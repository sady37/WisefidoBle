//
//  HeightMeasureViewController.swift
//  WisefidoBle (ported from owlCare)
//
//  安装高度测量（拍照 + 手点，无需手持稳定）：
//    1. 扫盒底 ArUco 进入本页，ARKit 全程跑着提供内参 + 重力方向 + 手机位姿（世界坐标）；
//    2. 拍「码」的照片（尽量近）→ 检测码（亚像素角点 + 码面竖直约束）→ 地面基准 floorY；
//    3. 雷达在同一张里就直接点；不在（卫生间等站不开）就按 Radar photo 把手机朝上补拍一张再点——
//       两张照片的位姿都在 ARKit 同一世界系里，不用拼图；
//    4. 回到码那张照片，沿虚线点雷达正下方的地面点（拖动有放大镜）→
//       「雷达射线 × 过地面点的竖线」求交 → 高度 = 交点.y - floorY。
//

import UIKit
import ARKit

@MainActor

final class HeightMeasureViewController: UIViewController {

    enum State {
        case aim            // 取景中（live）
        case reviewing      // 已冻结，等用户点雷达（或 Retake）
        case done(Double)   // 出结果

        var allowsAim: Bool {
            if case .aim = self { return false }
            return true
        }
    }

    private let onResult: (Double) -> Void
    private let sceneView = ARSCNView()
    private let frozenView = UIImageView()      // 冻结照片
    private let statusLabel = UILabel()
    private let resultLabel = UILabel()
    private let snapButton = UIButton(type: .custom)
    private let useButton = UIButton(type: .system)
    private let retryButton = UIButton(type: .system)   // Restart：重拍合影，从头测量
    private let reaimButton = UIButton(type: .system)   // Re-aim：保留照片，重选雷达
    private let radarPhotoButton = UIButton(type: .system)   // 雷达不在码的照片里 → 补拍
    private let loupe = UIView()                 // 拖动瞄准时的放大镜
    private let loupeImage = CALayer()
    private let loupeCross = CAShapeLayer()
    private let ciContext = CIContext()
    private let debugLabel = UILabel()
    private var quadLayer: CAShapeLayer?

    private var state: State = .aim { didSet { updateUI() } }

    /// 一张照片：拍照瞬间的相机位姿/内参 + 竖屏图（不留 ARFrame，ARKit 帧池有限）
    private struct Shot {
        let transform: simd_float4x4
        let intrinsics: simd_float3x3
        let bufferW: CGFloat, bufferH: CGFloat   // 缓冲为横屏
        let image: CGImage                       // 竖屏（缓冲顺时针转 90°），宽 = bufferH
    }
    private var markerShot: Shot?              // 带码的照片：地面基准 + 点地面点
    private var radarShot: Shot?               // 补拍的雷达照片；nil = 雷达就在 markerShot 里
    private var pendingShot: Shot?             // 正在检测码的照片
    private var shown: Shot?                   // 当前显示的照片
    private var shownIsMarker = false
    private var markerQuad: [CGPoint]?         // markerShot 缓冲坐标
    private var markerWorld: simd_float3?      // 码心世界坐标
    private var floorY: Float?


    /// 相机缓冲按竖屏处理（.right），本页锁竖屏
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }

    static func present(from vc: UIViewController, onResult: @escaping (Double) -> Void) {
        let m = HeightMeasureViewController(onResult: onResult)
        m.modalPresentationStyle = .fullScreen
        vc.present(m, animated: true)
    }

    private init(onResult: @escaping (Double) -> Void) {
        self.onResult = onResult
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        sceneView.automaticallyUpdatesLighting = false
        sceneView.session.delegate = self
        sceneView.session.delegateQueue = .main   // 回调落在 MainActor
        view.addSubview(sceneView)
        pinEdges(sceneView)

        frozenView.contentMode = .scaleAspectFit
        frozenView.backgroundColor = .black
        frozenView.isUserInteractionEnabled = true
        frozenView.clipsToBounds = true
        frozenView.isHidden = true
        frozenView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTapOnFrozen(_:))))
        frozenView.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handlePanOnFrozen(_:))))
        view.addSubview(frozenView)
        pinEdges(frozenView)

        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        statusLabel.layer.cornerRadius = 10
        statusLabel.layer.masksToBounds = true
        view.addSubview(statusLabel)
        activate(statusLabel, [
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 56),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
        ])

        resultLabel.textColor = .systemGreen
        resultLabel.font = .monospacedDigitSystemFont(ofSize: 44, weight: .bold)
        resultLabel.textAlignment = .center
        view.addSubview(resultLabel)
        activate(resultLabel, [
            resultLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            resultLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        // 中央大拍照钮（底部居中，单手可及）
        snapButton.backgroundColor = .systemRed
        snapButton.layer.cornerRadius = 38
        snapButton.layer.borderWidth = 4
        snapButton.layer.borderColor = UIColor.white.cgColor
        snapButton.addAction(UIAction { [weak self] _ in self?.snap() }, for: .touchUpInside)
        view.addSubview(snapButton)
        activate(snapButton, [
            snapButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            snapButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -36),
            snapButton.widthAnchor.constraint(equalToConstant: 76),
            snapButton.heightAnchor.constraint(equalToConstant: 76),
        ])

        for (btn, title) in [(useButton, "Use this height"), (retryButton, "Restart"), (reaimButton, "Re-aim"),
                             (radarPhotoButton, "Radar not in photo? Take radar photo")] {
            btn.setTitle(title, for: .normal)
            btn.setTitleColor(.white, for: .normal)
            btn.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
            btn.backgroundColor = btn == useButton ? .systemGreen : (btn == radarPhotoButton ? .systemBlue : .systemGray)
            btn.layer.cornerRadius = 12
            btn.isHidden = true
            view.addSubview(btn)
        }
        activate(useButton, [
            useButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            useButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            useButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),
            useButton.heightAnchor.constraint(equalToConstant: 50),
        ])
        activate(retryButton, [
            retryButton.bottomAnchor.constraint(equalTo: useButton.topAnchor, constant: -12),
            retryButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            retryButton.heightAnchor.constraint(equalToConstant: 44),
        ])
        activate(reaimButton, [
            reaimButton.bottomAnchor.constraint(equalTo: useButton.topAnchor, constant: -12),
            reaimButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),
            reaimButton.leadingAnchor.constraint(equalTo: retryButton.trailingAnchor, constant: 12),
            reaimButton.widthAnchor.constraint(equalTo: retryButton.widthAnchor),
            reaimButton.heightAnchor.constraint(equalToConstant: 44),
        ])
        activate(radarPhotoButton, [
            radarPhotoButton.topAnchor.constraint(equalTo: useButton.topAnchor),
            radarPhotoButton.bottomAnchor.constraint(equalTo: useButton.bottomAnchor),
            radarPhotoButton.leadingAnchor.constraint(equalTo: useButton.leadingAnchor),
            radarPhotoButton.trailingAnchor.constraint(equalTo: useButton.trailingAnchor),
        ])
        radarPhotoButton.addAction(UIAction { [weak self] _ in self?.startRadarPhoto() }, for: .touchUpInside)
        useButton.addAction(UIAction { [weak self] _ in self?.confirmResult() }, for: .touchUpInside)
        retryButton.addAction(UIAction { [weak self] _ in self?.retake() }, for: .touchUpInside)
        reaimButton.addAction(UIAction { [weak self] _ in self?.reaim() }, for: .touchUpInside)

        // 放大镜（左上，手指在下方拖，不挡）
        loupe.isHidden = true
        loupe.layer.cornerRadius = 70
        loupe.layer.masksToBounds = true
        loupe.layer.borderWidth = 3
        loupe.layer.borderColor = UIColor.white.cgColor
        loupe.backgroundColor = .black
        loupeImage.frame = CGRect(x: 0, y: 0, width: 140, height: 140)
        loupeImage.contentsGravity = .resize
        loupe.layer.addSublayer(loupeImage)
        let cp = UIBezierPath()
        cp.move(to: CGPoint(x: 58, y: 70)); cp.addLine(to: CGPoint(x: 82, y: 70))
        cp.move(to: CGPoint(x: 70, y: 58)); cp.addLine(to: CGPoint(x: 70, y: 82))
        loupeCross.path = cp.cgPath
        loupeCross.lineWidth = 1.5
        loupe.layer.addSublayer(loupeCross)
        view.addSubview(loupe)
        activate(loupe, [
            loupe.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 12),
            loupe.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            loupe.widthAnchor.constraint(equalToConstant: 140),
            loupe.heightAnchor.constraint(equalToConstant: 140),
        ])

        debugLabel.textColor = .white.withAlphaComponent(0.7)
        debugLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        view.addSubview(debugLabel)
        activate(debugLabel, [
            debugLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            debugLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
        ])

        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)), for: .normal)
        close.tintColor = .white
        close.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        close.layer.cornerRadius = 20
        close.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
        view.addSubview(close)
        activate(close, [
            close.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            close.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            close.widthAnchor.constraint(equalToConstant: 40),
            close.heightAnchor.constraint(equalToConstant: 40),
        ])

        updateUI()
    }

    // MARK: - 布局小工具（替代 owlCare 的 SnapKit）

    private func activate(_ v: UIView, _ cs: [NSLayoutConstraint]) {
        v.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate(cs)
    }

    private func pinEdges(_ v: UIView) {
        activate(v, [
            v.topAnchor.constraint(equalTo: view.topAnchor),
            v.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard ARWorldTrackingConfiguration.isSupported else {
            statusLabel.text = "This device doesn't support ARKit"
            snapButton.isHidden = true
            return
        }
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sceneView.session.pause()
    }

    // MARK: - 状态机

    private var statusGeneration = 0

    /// 提示语显示 1.5s 后淡出，不挡取景/照片；autoHide=false 常驻（处理中提示）
    private func showStatus(_ text: String, autoHide: Bool = true) {
        statusGeneration += 1
        let gen = statusGeneration
        statusLabel.text = text
        statusLabel.alpha = 1
        guard autoHide else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.statusGeneration == gen else { return }
            UIView.animate(withDuration: 0.3) { self.statusLabel.alpha = 0 }
        }
    }

    private func updateUI() {
        switch state {
        case .aim:
            showStatus(markerShot == nil
                       ? "Frame the box label (and the radar if you can), then tap the shutter"
                       : "Tilt up to the radar, keep it in view, tap the shutter", autoHide: markerShot == nil)
            resultLabel.text = nil
            frozenView.isHidden = true
            snapButton.isHidden = false
            useButton.isHidden = true; reaimButton.isHidden = true; radarPhotoButton.isHidden = true
            retryButton.isHidden = markerShot == nil
        case .reviewing:
            frozenView.isHidden = false
            snapButton.isHidden = true
            useButton.isHidden = true; retryButton.isHidden = false
            reaimButton.isHidden = radarRay == nil
            radarPhotoButton.isHidden = !(markerShot != nil && radarRay == nil && radarShot == nil)
            resultLabel.text = nil
        case .done(let height):
            showStatus("Radar installation height")
            resultLabel.text = String(format: "%.2f m", height)
            frozenView.isHidden = false
            snapButton.isHidden = true
            useButton.isHidden = false; retryButton.isHidden = false; reaimButton.isHidden = false
            radarPhotoButton.isHidden = true
        }
    }

    private func retake() {
        markerShot = nil; radarShot = nil; pendingShot = nil; shown = nil
        markerQuad = nil; markerWorld = nil; floorY = nil
        aimLocked = false
        aimStage = .radar
        radarRay = nil; guideLine = nil
        clearOverlays()
        quadLayer?.removeFromSuperlayer(); quadLayer = nil
        state = .aim
    }

    private func clearOverlays() {
        radarPinLayer?.removeFromSuperlayer(); radarPinLayer = nil
        guideLayer?.removeFromSuperlayer(); guideLayer = nil
        reticleLayer?.removeFromSuperlayer(); reticleLayer = nil
    }

    /// 补拍雷达：回到取景，保留码那张
    private func startRadarPhoto() {
        clearOverlays()
        state = .aim
    }

    /// 显示某张照片（码那张会画绿框）
    private func show(_ shot: Shot, isMarker: Bool) {
        shown = shot
        shownIsMarker = isMarker
        frozenView.image = UIImage(cgImage: shot.image)
        quadLayer?.removeFromSuperlayer(); quadLayer = nil
        if isMarker, let q = markerQuad { drawQuad(q) }
    }

    private func confirmResult() {
        guard case .done(let height) = state else { return }
        dismiss(animated: true) { [onResult] in onResult(height) }
    }

    // MARK: - 拍照 → 冻结帧 → 检测 ArUco

    private var latestFrame: ARFrame?

    private func snap() {
        guard let frame = latestFrame else { return }
        // 两张照片靠 ARKit 世界系对齐，跟踪不正常时拍的位姿不可信
        guard case .normal = frame.camera.trackingState else {
            showStatus("Hold on — move the phone slowly for a second, then tap again")
            return
        }
        let buffer = frame.capturedImage
        let ci = CIImage(cvPixelBuffer: buffer).oriented(.right)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return }
        let shot = Shot(transform: frame.camera.transform, intrinsics: frame.camera.intrinsics,
                        bufferW: CGFloat(CVPixelBufferGetWidth(buffer)),
                        bufferH: CGFloat(CVPixelBufferGetHeight(buffer)), image: cg)

        if markerShot != nil {
            // 补拍的雷达照片：不需要码
            radarShot = shot
            show(shot, isMarker: false)
            aimStage = .radar
            aimLocked = false
            state = .reviewing
            showStatus("Tap the center of the radar, or drag below it to fine-aim", autoHide: false)
            saveSnapshot(buffer: buffer, shot: shot, corners: [], tag: "radar")
            return
        }

        pendingShot = shot
        show(shot, isMarker: false)
        state = .reviewing
        // 在冻结帧上检测 ArUco（全分辨率，可花 0.2s）
        showStatus("Reading the marker…", autoHide: false)
        let detector = ArucoDetector()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let det = detector.detect(in: buffer, orientation: .up)
            DispatchQueue.main.async { [weak self] in
                guard let self, let shot = self.pendingShot else { return }
                self.pendingShot = nil
                let size = det.map { Float(ArucoDetector.markerSize(forId: $0.markerId)) } ?? 0
                guard let det,
                      let pose = PlanarPose(corners: det.corners, intrinsics: shot.intrinsics, markerSize: size) else {
                    self.showStatus("Marker not readable — move closer and retake", autoHide: false)
                    self.saveSnapshot(buffer: buffer, shot: shot, corners: det?.corners ?? [], tag: "fail")
                    return
                }
                // 盒子立在地上 → 码面竖直：4 自由度约束解（失败退回单应位姿）
                let c = pose.centerInCamera
                let w4 = shot.transform * simd_float4(c.x, c.y, c.z, 1)
                let upright = PlanarPose.uprightCenterWorld(corners: det.corners, intrinsics: shot.intrinsics,
                                                            cameraTransform: shot.transform, markerSize: size,
                                                            initial: pose)
                let world = upright ?? simd_float3(w4.x, w4.y, w4.z)
                self.markerWorld = world
                self.floorY = world.y - ArucoDetector.centerAboveFloor(forId: det.markerId)
                self.markerQuad = det.corners
                self.markerShot = shot
                self.show(shot, isMarker: true)
                self.debugLabel.text = String(format: "id%d %.0fpx d:%.2f camH:%.2f %@",
                                              det.markerId, det.pixelSize, pose.distance,
                                              shot.transform.columns.3.y - self.floorY!, upright == nil ? "H" : "U")
                self.saveSnapshot(buffer: buffer, shot: shot, corners: det.corners, tag: "snap")
                self.aimLocked = false
                self.state = .reviewing
                self.showStatus(det.pixelSize < 60
                                ? "Marker is small — closer is more accurate. Tap the radar, or take the radar as a 2nd photo"
                                : "Tap the center of the radar — not in this photo? Take a radar photo", autoHide: false)
            }
        }
    }

    /// 快照 + 全部中间量存 Documents（PNG 为缓冲原始朝向，JSON 存内参/姿态/角点/地面基准），离线复算用
    private func saveSnapshot(buffer: CVPixelBuffer, shot: Shot, corners: [CGPoint], tag: String) {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let ts = Int(Date().timeIntervalSince1970)
        let ctx = ciContext
        var json: [String: Any] = [
            "bufferSize": [shot.bufferW, shot.bufferH],
            "intrinsics": [shot.intrinsics.columns.0, shot.intrinsics.columns.1, shot.intrinsics.columns.2]
                .flatMap { [$0.x, $0.y, $0.z] },
            "cameraTransform": [shot.transform.columns.0, shot.transform.columns.1,
                                shot.transform.columns.2, shot.transform.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] },
            "corners": corners.map { [$0.x, $0.y] },
        ]
        if let m = markerWorld { json["markerWorld"] = [m.x, m.y, m.z] }
        if let f = floorY { json["floorY"] = f }
        DispatchQueue.global(qos: .utility).async {
            let ci = CIImage(cvPixelBuffer: buffer)
            if let cg = ctx.createCGImage(ci, from: ci.extent),
               let png = UIImage(cgImage: cg).pngData() {
                try? png.write(to: dir.appendingPathComponent("\(tag)_\(ts).png"))
            }
            if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) {
                try? data.write(to: dir.appendingPathComponent("\(tag)_\(ts).json"))
            }
        }
    }

    // MARK: - 两点瞄准：先点雷达球心，再点杆底（杆与地面的交点）

    private enum AimStage { case radar, base }
    private var aimStage: AimStage = .radar
    private var aimLocked = false
    private var radarRay: (origin: simd_float3, dir: simd_float3)?   // 雷达中心射线（世界系）
    private var radarPinLayer: CAShapeLayer?   // 球心已锁定的小红点
    private var guideLine: (a: CGPoint, b: CGPoint)?   // markerShot 缓冲坐标：估计地面点 → 其正上方 1m
    private var guideLayer: CAShapeLayer?

    /// 点按：未锁定 → 锁定该点；已锁定 → 解锁重选当前阶段
    @objc private func handleTapOnFrozen(_ g: UITapGestureRecognizer) {
        guard state.allowsAim else { return }
        if aimLocked {
            unlockAim()
            return
        }
        lockAim(at: g.location(in: frozenView))
    }

    /// 拖动微调：手指在下方拖，瞄准点显示在触点上方（不挡视线），实时刷新高度；松手即锁定
    @objc private func handlePanOnFrozen(_ g: UIPanGestureRecognizer) {
        guard state.allowsAim else { return }
        let touch = g.location(in: frozenView)
        let aim = CGPoint(x: touch.x, y: touch.y - 110)
        switch g.state {
        case .began, .changed:
            aimLocked = false
            drawReticle(at: aim, dragging: true)
            updateLoupe(at: aim)
            _ = measure(atViewPoint: aim, lock: false)
        case .ended, .cancelled:
            loupe.isHidden = true
            lockAim(at: aim)
        default: break
        }
    }

    private func unlockAim() {
        aimLocked = false
        reticleLayer?.removeFromSuperlayer(); reticleLayer = nil
        if case .done = state { state = .reviewing }
        if aimStage == .base {
            showStatus("Re-aim the floor point on the dashed line, tap to lock")
        } else {
            radarPinLayer?.removeFromSuperlayer(); radarPinLayer = nil
            guideLayer?.removeFromSuperlayer(); guideLayer = nil
            radarRay = nil; guideLine = nil
            showStatus("Re-aim the radar, tap to lock")
        }
    }

    /// Re-aim 按钮：保留照片，回到点雷达阶段（有补拍就回到补拍那张）
    private func reaim() {
        aimLocked = false
        aimStage = .radar
        radarRay = nil; guideLine = nil
        clearOverlays()
        if let r = radarShot { show(r, isMarker: false) } else if let m = markerShot { show(m, isMarker: true) }
        state = .reviewing
        showStatus("Tap the center of the radar, or drag below it to fine-aim")
    }

    private func lockAim(at p: CGPoint) {
        drawReticle(at: p, dragging: false)
        if measure(atViewPoint: p, lock: true) != nil { aimLocked = true }
    }

    /// 竖屏图在视图里的 aspectFit 缩放和偏移
    private func displayTransform(_ shot: Shot) -> (scale: CGFloat, ox: CGFloat, oy: CGFloat) {
        let iv = frozenView.bounds.size
        let w = CGFloat(shot.image.width), h = CGFloat(shot.image.height)
        let scale = min(iv.width / w, iv.height / h)
        return (scale, (iv.width - w * scale) / 2, (iv.height - h * scale) / 2)
    }

    /// 视图点 → 当前照片的缓冲像素
    private func viewPointToBuffer(_ point: CGPoint) -> CGPoint? {
        guard let shot = shown else { return nil }
        let t = displayTransform(shot)
        let ix = (point.x - t.ox) / t.scale, iy = (point.y - t.oy) / t.scale
        guard ix >= 0, iy >= 0, ix < CGFloat(shot.image.width), iy < CGFloat(shot.image.height) else { return nil }
        return CGPoint(x: iy, y: shot.bufferH - ix)   // 竖屏图像 → 横屏缓冲
    }

    /// 缓冲像素 → 视图坐标（当前照片）
    private func bufferToView(_ p: CGPoint) -> CGPoint? {
        guard frozenView.bounds.width > 0, let shot = shown else { return nil }
        let t = displayTransform(shot)
        return CGPoint(x: t.ox + (shot.bufferH - p.y) * t.scale, y: t.oy + p.x * t.scale)
    }

    /// 缓冲像素 → 世界射线（原点相机，方向世界系）
    private func rayFor(pixel p: CGPoint, in shot: Shot) -> (origin: simd_float3, dir: simd_float3) {
        let intr = shot.intrinsics
        let rayCam = simd_normalize(simd_float3(
            (Float(p.x) - intr.columns.2.x) / intr.columns.0.x,
            -(Float(p.y) - intr.columns.2.y) / intr.columns.1.y, -1))
        let ct = shot.transform
        let rd4 = ct * simd_float4(rayCam.x, rayCam.y, rayCam.z, 0)
        return (simd_float3(ct.columns.3.x, ct.columns.3.y, ct.columns.3.z),
                simd_normalize(simd_float3(rd4.x, rd4.y, rd4.z)))
    }

    /// 世界点 → 缓冲像素（与 rayFor 互逆：相机 y 向上，图像 y 向下）
    private func projectToBuffer(_ w: simd_float3, in shot: Shot) -> CGPoint? {
        let cam = simd_inverse(shot.transform) * simd_float4(w.x, w.y, w.z, 1)
        guard cam.z < -0.05 else { return nil }
        let intr = shot.intrinsics
        return CGPoint(x: CGFloat(intr.columns.0.x * cam.x / -cam.z + intr.columns.2.x),
                       y: CGFloat(intr.columns.2.y - intr.columns.1.y * cam.y / -cam.z))
    }

    /// 点 p 到直线 ab 的垂足
    private func nearestOnLine(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGPoint {
        let ab = CGVector(dx: b.x - a.x, dy: b.y - a.y)
        let len2 = ab.dx * ab.dx + ab.dy * ab.dy
        guard len2 > 1e-6 else { return a }
        let t = ((p.x - a.x) * ab.dx + (p.y - a.y) * ab.dy) / len2
        return CGPoint(x: a.x + ab.dx * t, y: a.y + ab.dy * t)
    }

    /// 当前视图点 → 按阶段推进。lock=false 只实时刷新读数，lock=true 锁定并进入下一阶段/出结果
    @discardableResult
    private func measure(atViewPoint point: CGPoint, lock: Bool) -> Double? {
        guard let floorY, let marker = markerWorld, let mShot = markerShot,
              let shot = shown, let px = viewPointToBuffer(point) else { return nil }

        switch aimStage {
        case .radar:
            guard lock else { return 0 }
            let ray = rayFor(pixel: px, in: shot)
            radarRay = ray
            // 估计雷达正下方地面点：雷达射线上与码等水平距离处（盒子就在杆底/墙脚）
            let rho0 = max(0.5, hypot(marker.x - ray.origin.x, marker.z - ray.origin.z))
            let hd = simd_normalize(simd_float2(ray.dir.x, ray.dir.z))
            let base0 = simd_float3(ray.origin.x + hd.x * rho0, floorY, ray.origin.z + hd.y * rho0)
            let up0 = base0 + simd_float3(0, 1, 0)
            // 地面点在码那张照片上点（近、清楚）；补拍的情况切回码那张
            if !shownIsMarker { show(mShot, isMarker: true) }
            clearOverlays()
            if let b0 = projectToBuffer(base0, in: mShot), let u0 = projectToBuffer(up0, in: mShot) {
                guideLine = (b0, u0)
                drawGuide()
            } else {
                guideLine = nil
            }
            // 雷达在这张里能看到就留红钉
            let top = ray.origin + ray.dir * (rho0 / max(1e-3, simd_length(simd_float2(ray.dir.x, ray.dir.z))))
            if let tp = projectToBuffer(top, in: mShot), let tv = bufferToView(tp),
               frozenView.bounds.contains(tv) { drawPin(at: tv) }
            aimStage = .base
            showStatus("Tap where the dashed line meets the floor — drag for a magnifier", autoHide: false)
            return 0

        case .base:
            guard let ballRay = radarRay else { return nil }
            // 地面点吸附到参考线上
            let snapped = guideLine.map { nearestOnLine(px, $0.a, $0.b) } ?? px
            let baseRay = rayFor(pixel: snapped, in: mShot)
            guard baseRay.dir.y < -0.02 else {
                if lock { self.showStatus("The floor point must be below the camera — aim lower", autoHide: false) }
                return nil
            }
            let t = (floorY - baseRay.origin.y) / baseRay.dir.y
            let base = baseRay.origin + baseRay.dir * t
            // 雷达射线 × 过地面点的竖线 → 高度
            let num = ballRay.dir.x * (base.x - ballRay.origin.x) + ballRay.dir.z * (base.z - ballRay.origin.z)
            let den = ballRay.dir.x * ballRay.dir.x + ballRay.dir.z * ballRay.dir.z
            guard den > 1e-6 else { return nil }
            let d = num / den
            guard d > 0.3, d < 15 else {
                if lock { self.showStatus("Aim looks off — drag again or restart", autoHide: false) }
                return nil
            }
            let height = Double(ballRay.origin.y + ballRay.dir.y * d - floorY)
            guard height > 0.3, height < 5.0 else {
                if lock { self.showStatus(String(format: "Implausible %.2f m — drag again or restart", height), autoHide: false) }
                return nil
            }
            debugLabel.text = String(format: "d:%.2f camH:%.2f %@", d, ballRay.origin.y - floorY,
                                     radarShot == nil ? "1 photo" : "2 photos")
            if lock {
                state = .done(height)
            } else {
                resultLabel.text = String(format: "%.2f m", height)
            }
            return height
        }
    }

    /// 放大镜：显示瞄准点周围、屏幕 3 倍放大
    private func updateLoupe(at p: CGPoint) {
        guard let shot = shown else { return }
        let t = displayTransform(shot)
        let w = CGFloat(shot.image.width), h = CGFloat(shot.image.height)
        let ix = (p.x - t.ox) / t.scale, iy = (p.y - t.oy) / t.scale
        let span = 140 / (t.scale * 3)   // 放大镜覆盖的图像像素
        CATransaction.begin(); CATransaction.setDisableActions(true)
        loupeImage.contents = shot.image
        loupeImage.contentsRect = CGRect(x: (ix - span / 2) / w, y: (iy - span / 2) / h, width: span / w, height: span / h)
        loupeCross.strokeColor = stageColor.cgColor
        CATransaction.commit()
        loupe.isHidden = false
    }

    // MARK: - 覆盖层

    private var reticleLayer: CAShapeLayer?

    /// 当前阶段颜色：雷达=红，杆底=蓝
    private var stageColor: UIColor { aimStage == .radar ? .systemRed : .systemBlue }

    /// 瞄准镜。dragging=true：中心一个半透明淡色点（拖动中）；false：锁定，大圆环 + 中心短十字
    private func drawReticle(at p: CGPoint, dragging: Bool = false) {
        reticleLayer?.removeFromSuperlayer()
        let layer = CAShapeLayer()
        let color = stageColor
        if dragging {
            let r: CGFloat = 9
            layer.path = UIBezierPath(ovalIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)).cgPath
            layer.fillColor = color.withAlphaComponent(0.4).cgColor
            layer.strokeColor = color.withAlphaComponent(0.7).cgColor
            layer.lineWidth = 1
        } else {
            let r: CGFloat = 30
            let c: CGFloat = 8   // 十字半长（只在中心，不触圈）
            let path = UIBezierPath(ovalIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            path.move(to: CGPoint(x: p.x - c, y: p.y)); path.addLine(to: CGPoint(x: p.x + c, y: p.y))
            path.move(to: CGPoint(x: p.x, y: p.y - c)); path.addLine(to: CGPoint(x: p.x, y: p.y + c))
            layer.path = path.cgPath
            layer.strokeColor = color.cgColor
            layer.lineWidth = 2.5
            layer.fillColor = UIColor.clear.cgColor
        }
        frozenView.layer.addSublayer(layer)
        reticleLayer = layer
    }

    /// 画"雷达正下方"参考虚线：过估计地面点的世界竖线，在照片上贯穿画出（向下多留一段）
    private func drawGuide() {
        guideLayer?.removeFromSuperlayer()
        guard let g = guideLine,
              let vb = bufferToView(g.a), let vu = bufferToView(g.b) else { return }
        let len = max(1, hypot(vu.x - vb.x, vu.y - vb.y))
        let u = CGPoint(x: (vu.x - vb.x) / len, y: (vu.y - vb.y) / len)
        let path = UIBezierPath()
        path.move(to: CGPoint(x: vb.x - u.x * 120, y: vb.y - u.y * 120))
        path.addLine(to: CGPoint(x: vb.x + u.x * 3000, y: vb.y + u.y * 3000))
        let layer = CAShapeLayer()
        layer.path = path.cgPath
        layer.strokeColor = UIColor.systemRed.withAlphaComponent(0.8).cgColor
        layer.lineWidth = 1.5
        layer.lineDashPattern = [6, 5]
        frozenView.layer.addSublayer(layer)
        guideLayer = layer
    }

    /// 球心锁定后留下的小红钉，点杆底阶段仍可见
    private func drawPin(at p: CGPoint) {
        radarPinLayer?.removeFromSuperlayer()
        let r: CGFloat = 5
        let layer = CAShapeLayer()
        layer.path = UIBezierPath(ovalIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)).cgPath
        layer.fillColor = UIColor.systemRed.cgColor
        frozenView.layer.addSublayer(layer)
        radarPinLayer = layer
    }
    /// 在码那张照片上画绿框（缓冲坐标 → 视图）
    private func drawQuad(_ corners: [CGPoint]) {
        quadLayer?.removeFromSuperlayer()
        guard corners.count == 4 else { return }
        let pts = corners.compactMap { bufferToView($0) }
        guard pts.count == 4 else { return }
        let path = UIBezierPath()
        path.move(to: pts[0]); for p in pts.dropFirst() { path.addLine(to: p) }
        path.close()
        let layer = CAShapeLayer()
        layer.path = path.cgPath
        layer.strokeColor = UIColor.systemGreen.cgColor
        layer.lineWidth = 3
        layer.fillColor = UIColor.systemGreen.withAlphaComponent(0.1).cgColor
        frozenView.layer.addSublayer(layer)
        quadLayer = layer
    }
}

// MARK: - ARSessionDelegate

extension HeightMeasureViewController: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        MainActor.assumeIsolated { latestFrame = frame }
    }
}
