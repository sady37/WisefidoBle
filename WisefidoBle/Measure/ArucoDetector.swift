//
//  ArucoDetector.swift
//  WisefidoBle (ported from owlCare)
//
//  包装盒底贴 ArUco 检测（OpenCV DICT_4X4_50 标准图案，只认 #0 = 120mm 盒贴 v2、#7 = 110mm 旧盒贴）：
//  黑方块 = 6×6 网格，最外圈全黑边框 + 内部 4×4 数据位。
//  检测流程：灰度图找黑色方形连通块（PCA 四角）→ 单应拉正 →
//  最大黑色连通块抠出真正的码 → 6×6 网格采样解码。
//  不用 Vision 矩形检测（实测会把码内部白格当矩形、外框不报）。
//  不依赖 OpenCV；输入 CVPixelBuffer，输出图像像素坐标四角。
//

import AVFoundation
import Vision
import CoreImage
import OSLog
import simd

nonisolated private let arucoLog = Logger(subsystem: "com.wisefido.ble", category: "aruco")

struct ArucoDetection {
    /// 图像像素坐标（y 向下），顺序：画面中看到的 左上、右上、右下、左下。
    var corners: [CGPoint]  // 4: TL TR BR BL（按画面中看到的方向）
    /// 码相对标准朝向的顺时针旋转（0-3）。几何测高不依赖它，仅诊断用。
    var rotation: Int
    /// 码 ID：0 = 12cm 盒贴 v2；7 = 11cm 旧盒贴。测高据此自动定实物尺寸和码心离地。
    var markerId: Int
    /// 码心在图像中的位置（y 向下像素）。
    var center: CGPoint {
        corners.reduce(.zero) { CGPoint(x: $0.x + $1.x / 4, y: $0.y + $1.y / 4) }
    }
    /// 码的像素边长（四边平均）。
    var pixelSize: CGFloat {
        let e = zip(corners, [corners[1], corners[2], corners[3], corners[0]])
        return e.reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) } / 4
    }
}

nonisolated final class ArucoDetector {

    /// 实物边长（米），按码 ID（OpenCV DICT_4X4_50 标准图案）：
    /// 0 = 盒底贴 v2，120 mm（install/amazon/amazonbox/make_bottom120.py）；7 = 旧盒底贴，110 mm。
    static func markerSize(forId id: Int) -> CGFloat { id == 7 ? 0.110 : 0.120 }

    /// 盒子竖放（贴纸那面朝人）时码心离地（米）：v2 设计 80 mm；旧 #7 实量 83 mm（码下沿距盒底 28 mm）。
    static func centerAboveFloor(forId id: Int) -> Float { id == 7 ? 0.083 : 0.080 }

    /// 内部 4×4 期望图案（行优先，1=黑；OpenCV 字节里 1=白，此处已取反）。
    private static let basePatterns: [Int: [UInt8]] = [
        0: [0, 1, 0, 0,   // 盒底贴 v2
            1, 0, 1, 0,
            1, 1, 0, 0,
            1, 1, 0, 1],
        7: [0, 0, 1, 1,   // 旧盒底贴
            1, 0, 1, 1,
            0, 0, 0, 0,
            1, 1, 0, 1],
    ]

    /// (id, 旋转) → 期望图案
    private let expected: [(id: Int, rot: Int, bits: [UInt8])] = {
        var out: [(Int, Int, [UInt8])] = []
        for (id, base) in basePatterns {
            var cur = base
            for r in 0..<4 {
                out.append((id, r, cur))
                // 顺时针旋转 90°：new[r][c] = old[3-c][r]
                var next = [UInt8](repeating: 0, count: 16)
                for rr in 0..<4 { for cc in 0..<4 { next[rr * 4 + cc] = cur[(3 - cc) * 4 + rr] } }
                cur = next
            }
        }
        return out
    }()

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// 角点亚像素精修开关（离线对比用；正常一直开）
    var subpixel = true

    /// 一帧的灰度位图（显示朝向，y 向下），供所有候选采样。
    private struct GrayFrame {
        var pixels: [UInt8]
        var width: Int
        var height: Int
        var rowBytes: Int
    }

    /// 检测一帧。orientation 为图像显示方向（竖屏采集通常 .right；ARKit 原始帧用 .up）。
    /// 返回「显示朝向」图像的像素坐标（y 向下）四角，未检测到返回 nil。
    func detect(in pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation = .right) -> ArucoDetection? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
        guard let gray = renderGray(ciImage) else { return nil }

        let quads = findBlackSquares(gray)
        if !quads.isEmpty {
            arucoLog.info("frame \(gray.width)x\(gray.height): \(quads.count) dark-square candidate(s)")
        }
        for quad in quads {
            if let r = decode(corners: quad, gray: gray) {
                // 亚像素精修两轮（第二轮以第一轮结果为起点，剖面更准）；失败保留整像素角点
                var corners = r.corners
                if subpixel {
                    for _ in 0..<2 { if let c = refineCorners(corners, gray: gray) { corners = c } }
                }
                arucoLog.info("decode OK id=\(r.id) rot=\(r.rot)")
                return ArucoDetection(corners: corners, rotation: r.rot, markerId: r.id)
            }
        }
        return nil
    }

    /// 整帧渲染为 8bit 灰度（y 向下，顶行在前）。
    private func renderGray(_ image: CIImage) -> GrayFrame? {
        let extent = image.extent
        guard extent.width > 0, extent.width < 4096, extent.height < 4096 else { return nil }
        let w = Int(extent.width), h = Int(extent.height)
        // CIContext.render(toBitmap:) 要求 rowBytes 16 字节对齐，否则静默输出全 0
        let rowBytes = (w + 15) & ~15
        var pixels = [UInt8](repeating: 0, count: rowBytes * h)
        ciContext.render(image,
                         toBitmap: &pixels,
                         rowBytes: rowBytes,
                         bounds: extent,
                         format: .L8,
                         colorSpace: CGColorSpaceCreateDeviceGray())
        return GrayFrame(pixels: pixels, width: w, height: h, rowBytes: rowBytes)
    }

    // MARK: - 黑色方形连通块

    /// 在灰度图里找黑色方形连通块，返回近似四角（TL TR BR BL，y 向下全尺寸像素）。
    private func findBlackSquares(_ gray: GrayFrame) -> [[CGPoint]] {
        // 降采样到短边 ≤ 768（512 时 2m 外的码只剩 ~25px，破碎到检不出）
        let scaleDown = max(1, min(gray.width, gray.height) / 768)
        let sw = gray.width / scaleDown, sh = gray.height / scaleDown
        var small = [UInt8](repeating: 255, count: sw * sh)
        for y in 0..<sh { for x in 0..<sw {
            small[y * sw + x] = gray.pixels[y * scaleDown * gray.rowBytes + x * scaleDown]
        } }

        // 阈值：暗部（5 分位）与中间亮度（60 分位）的中点（256 桶直方图，比 sorted() 快两个量级）
        var hist = [Int](repeating: 0, count: 256)
        for v in small { hist[Int(v)] += 1 }
        func percentile(_ q: Double) -> Int {
            let target = Int(Double(sw * sh) * q)
            var acc = 0
            for i in 0..<256 { acc += hist[i]; if acc > target { return i } }
            return 255
        }
        let lo = percentile(0.05), hi = percentile(0.60)
        guard hi - lo > 40 else { return [] }
        let thr = lo + (hi - lo) / 2

        // 暗像素连通块（4 连通 flood fill）
        var visited = [Bool](repeating: false, count: sw * sh)
        var quads: [[CGPoint]] = []
        var stack: [Int] = []
        for start in 0..<(sw * sh) {
            if visited[start] { continue }
            visited[start] = true
            guard Int(small[start]) < thr else { continue }
            stack.append(start)
            var pts: [(Int, Int)] = []
            while let idx = stack.popLast() {
                let x = idx % sw, y = idx / sw
                pts.append((x, y))
                for n in [idx - 1, idx + 1, idx - sw, idx + sw] {
                    guard n >= 0, n < sw * sh, !visited[n] else { continue }
                    if (n == idx - 1 && x == 0) || (n == idx + 1 && x == sw - 1) { continue }
                    visited[n] = true
                    if Int(small[n]) < thr { stack.append(n) }
                }
            }
            guard let quad = squareQuad(pts: pts, scaleDown: scaleDown) else { continue }
            quads.append(quad)
            if quads.count >= 8 { return quads }
        }
        return quads
    }

    /// 连通块是否像码：足够大、bbox 接近正方形、填充率兼容空心框
    /// （码的外边框+部分黑格是带孔结构，实心率只有 ~0.5-0.75，不能用实心方块判据）。
    /// 返回 bbox 四角（全尺寸坐标，TL TR BR BL）；倾斜导致的误差由 decode 的
    /// 二次连通块提取吸收。
    private func squareQuad(pts: [(Int, Int)], scaleDown: Int) -> [CGPoint]? {
        let n = pts.count
        guard n >= 180 else { return nil }  // 小图至少 ~13×13px
        var minX = Int.max, minY = Int.max, maxX = 0, maxY = 0
        for (x, y) in pts {
            minX = min(minX, x); minY = min(minY, y)
            maxX = max(maxX, x); maxY = max(maxY, y)
        }
        let w = maxX - minX + 1, h = maxY - minY + 1
        let aspect = Double(w) / Double(h)
        // 平放俯拍/斜视时透视缩短可达 ~2.5:1，不能按正方形卡死
        guard aspect > 0.35, aspect < 2.9 else { return nil }
        let fill = Double(n) / Double(w * h)
        guard fill > 0.3, fill < 1.0 else { return nil }
        let k = Double(scaleDown)
        return [
            CGPoint(x: Double(minX) * k, y: Double(minY) * k),
            CGPoint(x: Double(maxX + 1) * k, y: Double(minY) * k),
            CGPoint(x: Double(maxX + 1) * k, y: Double(maxY + 1) * k),
            CGPoint(x: Double(minX) * k, y: Double(maxY + 1) * k),
        ]
    }

    // MARK: - 解码

    /// 候选四角 → 拉正 → 找最大黑色连通块（真正的码）→ 在其 bbox 内切 6×6 解码。
    /// PCA 四角是近似值，连通块 bbox 二次校准边界，容忍四角误差。
    /// 返回解码 id + 旋转 + 精修四角（映射回原图坐标，供位姿解算用——粗 bbox 会偏）。
    private func decode(corners: [CGPoint], gray: GrayFrame) -> (id: Int, rot: Int, corners: [CGPoint])? {
        // 码平面坐标（单位：格，y 向下）：TL(0,0) TR(6,0) BR(6,6) BL(0,6)
        let src: [(Double, Double)] = [(0, 0), (6, 0), (6, 6), (0, 6)]
        let dst = corners.map { (Double($0.x), Double($0.y)) }
        guard let H = PlanarPose.homography(from: src, to: dst) else { return nil }
        func mapPoint(_ u: Double, _ v: Double) -> (Double, Double) {
            let x = H.columns.0.x * u + H.columns.1.x * v + H.columns.2.x
            let y = H.columns.0.y * u + H.columns.1.y * v + H.columns.2.y
            let z = H.columns.0.z * u + H.columns.1.z * v + H.columns.2.z
            return (x / z, y / z)
        }

        // 拉正到 240×240（40px/格）
        let W = 240
        var patch = [UInt8](repeating: 255, count: W * W)
        for py in 0..<W {
            for px in 0..<W {
                let (ix, iy) = mapPoint(Double(px) / Double(W) * 6, Double(py) / Double(W) * 6)
                patch[py * W + px] = UInt8(sample(gray, x: ix, y: iy))
            }
        }

        // 二值化：要求有足够对比
        guard let lo = patch.min(), let hi = patch.max(), Int(hi) - Int(lo) > 40 else {
            arucoLog.info("decode reject: low contrast \(patch.min() ?? 0)-\(patch.max() ?? 0)")
            return nil
        }
        let thr = (Int(lo) + Int(hi)) / 2

        // 找黑色方形在 patch 里的四个真实角点：
        // 方形的角 = 暗像素中沿两条对角线方向的极值点，容忍轻微残余倾斜/梯形畸变
        var tl = (x: 0, y: 0, s: Int.max)   // min x+y
        var tr = (x: 0, y: 0, s: Int.min)   // max x-y
        var br = (x: 0, y: 0, s: Int.min)   // max x+y
        var bl = (x: 0, y: 0, s: Int.min)   // max y-x
        for y in 0..<W { for x in 0..<W {
            guard Int(patch[y * W + x]) < thr else { continue }
            let xy = x + y, xy2 = x - y
            if xy < tl.s { tl = (x, y, xy) }
            if xy2 > tr.s { tr = (x, y, xy2) }
            if xy > br.s { br = (x, y, xy) }
            if -xy2 > bl.s { bl = (x, y, -xy2) }
        } }
        //  sanity：四角应构成大块区域（覆盖 patch 显著部分）
        let quadW = Double(br.x - tl.x), quadH = Double(br.y - tl.y)
        guard quadW > Double(W) * 0.2, quadH > Double(W) * 0.2 else {
            arucoLog.info("decode reject: corner span \(Int(quadW))x\(Int(quadH))")
            return nil
        }

        // 用真实四角再做一次单应：6×6 网格 → patch 坐标，直接逐格采样
        let srcG: [(Double, Double)] = [(0, 0), (6, 0), (6, 6), (0, 6)]
        let dstG: [(Double, Double)] = [(Double(tl.x), Double(tl.y)), (Double(tr.x), Double(tr.y)),
                                        (Double(br.x), Double(br.y)), (Double(bl.x), Double(bl.y))]
        guard let H2 = PlanarPose.homography(from: srcG, to: dstG) else { return nil }
        func mapGrid(_ u: Double, _ v: Double) -> (Double, Double) {
            let x = H2.columns.0.x * u + H2.columns.1.x * v + H2.columns.2.x
            let y = H2.columns.0.y * u + H2.columns.1.y * v + H2.columns.2.y
            let z = H2.columns.0.z * u + H2.columns.1.z * v + H2.columns.2.z
            return (x / z, y / z)
        }
        var means = [Double](repeating: 0, count: 36)
        for r in 0..<6 {
            for c in 0..<6 {
                var sum = 0, cnt = 0
                for iy in 0..<5 {
                    for ix in 0..<5 {
                        let (px, py) = mapGrid(Double(c) + 0.3 + 0.1 * Double(ix),
                                               Double(r) + 0.3 + 0.1 * Double(iy))
                        let x = Int(px), y = Int(py)
                        guard x >= 0, y >= 0, x < W, y < W else { continue }
                        sum += Int(patch[y * W + x]); cnt += 1
                    }
                }
                means[r * 6 + c] = Double(sum) / Double(max(cnt, 1))
            }
        }
        guard let l2 = means.min(), let h2 = means.max(), h2 - l2 > 30 else {
            arucoLog.info("decode reject: grid low contrast")
            return nil
        }
        let thr2 = (l2 + h2) / 2
        let bits = means.map { $0 < thr2 ? UInt8(1) : UInt8(0) }

        // 外圈必须全黑，允许 2 格误差
        let borderIdx: [Int] = (0..<6).map { $0 } + (0..<6).map { 30 + $0 }
            + (1..<5).map { $0 * 6 } + (1..<5).map { $0 * 6 + 5 }
        let borderErrors = borderIdx.reduce(0) { $0 + (bits[$1] == 1 ? 0 : 1) }
        guard borderErrors <= 2 else {
            arucoLog.info("decode reject: border errors \(borderErrors)")
            return nil
        }

        // 内部 4×4 与各 ID 期望图案的四个旋转比对，允许 1 位误差
        var inner = [UInt8](repeating: 0, count: 16)
        for r in 0..<4 { for c in 0..<4 { inner[r * 4 + c] = bits[(r + 1) * 6 + (c + 1)] } }
        var bestMismatch = 17
        for (id, rot, exp) in expected {
            let mismatch = zip(inner, exp).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
            bestMismatch = min(bestMismatch, mismatch)
            if mismatch <= 1 {
                // 精修四角（patch 坐标）映射回原图：patch px = 平面 u/6*W，走第一段单应
                func toImage(_ px: Int, _ py: Int) -> CGPoint {
                    let (ix, iy) = mapPoint(Double(px) / Double(W) * 6, Double(py) / Double(W) * 6)
                    return CGPoint(x: ix, y: iy)
                }
                return (id, rot, [toImage(tl.x, tl.y), toImage(tr.x, tr.y),
                                  toImage(br.x, br.y), toImage(bl.x, bl.y)])
            }
        }
        arucoLog.info("decode reject: inner mismatch best=\(bestMismatch) bits=\(inner.map(String.init).joined())")
        return nil
    }

    // MARK: - 亚像素角点

    /// 沿黑框四条外边逐点找明暗过渡（法向剖面，取暗/亮两侧均值的中点，线性插值到 0.25px 内），
    /// 总最小二乘拟合直线（剔除离群点后再拟一次），相邻两边求交得角点。
    /// 整像素角点在 3m 外（码 ~70px）差 1px ≈ 距离差 1.4%；精修后 ~0.1-0.2px。
    /// 返回 nil = 精修不可靠（对比不足/点太少/偏离原角点过远），调用方保留原角点。
    private func refineCorners(_ c: [CGPoint], gray: GrayFrame) -> [CGPoint]? {
        guard c.count == 4 else { return nil }
        let P = c.map { SIMD2<Double>(Double($0.x), Double($0.y)) }
        let center = (P[0] + P[1] + P[2] + P[3]) / 4
        var lines: [(p: SIMD2<Double>, d: SIMD2<Double>)] = []
        for i in 0..<4 {
            let a = P[i], b = P[(i + 1) % 4]
            let len = simd_length(b - a)
            guard len > 24 else { return nil }
            let dir = (b - a) / len
            var n = SIMD2<Double>(-dir.y, dir.x)
            if simd_dot(n, (a + b) / 2 - center) < 0 { n = -n }   // 法向指向码外
            // 剖面半长：不越过边框格（向内一格）和静区（向外一格）
            let reach = max(2.5, min(len / 6 * 0.45, 14))
            let step = 0.25
            let m = Int(2 * reach / step) + 1
            let samples = max(10, Int(len / 2))
            var pts: [SIMD2<Double>] = []
            var prof = [Double](repeating: 0, count: m)
            for k in 0..<samples {
                let t = 0.12 + 0.76 * Double(k) / Double(samples - 1)   // 避开两端角点附近
                let base = a + (b - a) * t
                for j in 0..<m {
                    let q = base + n * (-reach + Double(j) * step)
                    prof[j] = sampleD(gray, q.x, q.y)
                }
                let q4 = max(2, m / 4)
                let dark = prof.prefix(q4).reduce(0, +) / Double(q4)
                let light = prof.suffix(q4).reduce(0, +) / Double(q4)
                guard light - dark > 25 else { continue }
                let thr = (dark + light) / 2
                // 取离当前估计边（s=0）最近的上穿点
                var best: Double?
                for j in 1..<m where prof[j - 1] < thr && prof[j] >= thr {
                    let f = (thr - prof[j - 1]) / (prof[j] - prof[j - 1])
                    let s = -reach + (Double(j - 1) + f) * step
                    if best == nil || abs(s) < abs(best!) { best = s }
                }
                if let s = best { pts.append(base + n * s) }
            }
            guard pts.count >= max(6, samples / 3), var line = fitLine(pts) else { return nil }
            // 剔除离群点（残差 > max(0.75px, 3×中位数)）后重拟
            let res = pts.map { abs(simd_dot($0 - line.p, SIMD2(-line.d.y, line.d.x))) }
            let med = res.sorted()[res.count / 2]
            let keep = zip(pts, res).filter { $0.1 <= max(0.75, 3 * med) }.map(\.0)
            if keep.count >= 6, let l2 = fitLine(keep) { line = l2 }
            lines.append(line)
        }
        var out: [CGPoint] = []
        for i in 0..<4 {
            guard let x = intersect(lines[(i + 3) % 4], lines[i]) else { return nil }
            let side = simd_length(P[(i + 1) % 4] - P[i])
            guard simd_length(x - P[i]) < max(3, side * 0.08) else { return nil }
            out.append(CGPoint(x: x.x, y: x.y))
        }
        return out
    }

    /// 点集总最小二乘直线：过质心，方向 = 协方差主轴
    private func fitLine(_ pts: [SIMD2<Double>]) -> (p: SIMD2<Double>, d: SIMD2<Double>)? {
        guard pts.count >= 2 else { return nil }
        let m = pts.reduce(SIMD2<Double>(0, 0), +) / Double(pts.count)
        var sxx = 0.0, sxy = 0.0, syy = 0.0
        for p in pts { let v = p - m; sxx += v.x * v.x; sxy += v.x * v.y; syy += v.y * v.y }
        let theta = 0.5 * atan2(2 * sxy, sxx - syy)
        return (m, SIMD2(cos(theta), sin(theta)))
    }

    private func intersect(_ l1: (p: SIMD2<Double>, d: SIMD2<Double>),
                           _ l2: (p: SIMD2<Double>, d: SIMD2<Double>)) -> SIMD2<Double>? {
        let det = l1.d.x * l2.d.y - l1.d.y * l2.d.x
        guard abs(det) > 1e-6 else { return nil }
        let w = l2.p - l1.p
        let t = (w.x * l2.d.y - w.y * l2.d.x) / det
        return l1.p + l1.d * t
    }

    /// 双线性灰度采样（Double），越界返回白
    private func sampleD(_ g: GrayFrame, _ x: Double, _ y: Double) -> Double {
        let x0 = Int(floor(x)), y0 = Int(floor(y))
        guard x0 >= 0, y0 >= 0, x0 + 1 < g.width, y0 + 1 < g.height else { return 255 }
        let fx = x - Double(x0), fy = y - Double(y0)
        let r0 = y0 * g.rowBytes, r1 = r0 + g.rowBytes
        let top = Double(g.pixels[r0 + x0]) * (1 - fx) + Double(g.pixels[r0 + x0 + 1]) * fx
        let bot = Double(g.pixels[r1 + x0]) * (1 - fx) + Double(g.pixels[r1 + x0 + 1]) * fx
        return top * (1 - fy) + bot * fy
    }

    /// 双线性灰度采样，越界返回白色（255，不致误判为黑格）。
    private func sample(_ g: GrayFrame, x: Double, y: Double) -> Int {
        let x0 = Int(floor(x)), y0 = Int(floor(y))
        guard x0 >= 0, y0 >= 0, x0 + 1 < g.width, y0 + 1 < g.height else { return 255 }
        let fx = x - Double(x0), fy = y - Double(y0)
        let i00 = Int(g.pixels[y0 * g.rowBytes + x0])
        let i10 = Int(g.pixels[y0 * g.rowBytes + x0 + 1])
        let i01 = Int(g.pixels[(y0 + 1) * g.rowBytes + x0])
        let i11 = Int(g.pixels[(y0 + 1) * g.rowBytes + x0 + 1])
        let top = Double(i00) * (1 - fx) + Double(i10) * fx
        let bot = Double(i01) * (1 - fx) + Double(i11) * fx
        return Int(top * (1 - fy) + bot * fy)
    }
}
