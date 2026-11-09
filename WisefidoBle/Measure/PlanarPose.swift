//
//  PlanarPose.swift
//  WisefidoBle (ported from owlCare)
//
//  平面标记位姿解算：已知 ArUco 码四角（图像像素）+ 实际边长 + 相机内参，
//  用单应矩阵分解求出码相对相机的 3D 位姿（marker → camera 变换）。
//  平面目标无需迭代 PnP；4 点单应 + K⁻¹H 分解即可。
//

import simd
import CoreGraphics

nonisolated struct PlanarPose {
    /// marker → camera 的 4×4 变换（ARKit 相机系：x 右、y 上、z 朝后，前方为 -z）。
    /// 注意：该变换的平移分量是码平面原点（TL 角点），不是几何中心。
    var markerToCamera: simd_float4x4
    /// 码几何中心在相机坐标系的位置（米）。
    var centerInCamera: simd_float3
    /// 手机到码心的距离（米）。
    var distance: Float { simd_length(centerInCamera) }

    /// corners: TL TR BR BL（y 向下像素）；intrinsics: ARKit/AVCapture 的 3×3 内参；
    /// markerSize: 实物边长（米）。失败（退化/在相机后方）返回 nil。
    init?(corners: [CGPoint], intrinsics: simd_float3x3, markerSize: Float) {
        guard corners.count == 4 else { return nil }
        let s = Double(markerSize)
        // 码平面坐标（米，y 向下与图像一致）：TL(0,0) TR(s,0) BR(s,s) BL(0,s)
        let plane: [(Double, Double)] = [(0, 0), (s, 0), (s, s), (0, s)]
        let image: [(Double, Double)] = corners.map { (Double($0.x), Double($0.y)) }

        guard let H = PlanarPose.homography(from: plane, to: image) else { return nil }

        let K = simd_double3x3(rows: [
            simd_double3(Double(intrinsics.columns.0.x), Double(intrinsics.columns.1.x), Double(intrinsics.columns.2.x)),
            simd_double3(Double(intrinsics.columns.0.y), Double(intrinsics.columns.1.y), Double(intrinsics.columns.2.y)),
            simd_double3(Double(intrinsics.columns.0.z), Double(intrinsics.columns.1.z), Double(intrinsics.columns.2.z)),
        ])
        let G = K.inverse * H

        var g1 = simd_double3(G.columns.0.x, G.columns.0.y, G.columns.0.z)
        var g2 = simd_double3(G.columns.1.x, G.columns.1.y, G.columns.1.z)
        var g3 = simd_double3(G.columns.2.x, G.columns.2.y, G.columns.2.z)

        var lambda = 2.0 / (simd_length(g1) + simd_length(g2))
        // 单应分解出来的是 OpenCV 相机系（y 向下、z 朝前）：码在前方 ⇒ t.z > 0
        if lambda * g3.z < 0 { lambda = -lambda }
        g1 *= lambda; g2 *= lambda; g3 *= lambda

        // 正交化 r1、r2（Gram-Schmidt），r3 = r1 × r2
        let r1cv = simd_normalize(g1) as simd_double3
        var r2cv = g2 - simd_dot(g2, r1cv) * r1cv
        r2cv = simd_normalize(r2cv)
        let r3cv = simd_cross(r1cv, r2cv)

        // OpenCV(y下,z前) → ARKit(y上,z后)：逐列做 (x,-y,-z)
        func toARKit(_ v: simd_double3) -> simd_double3 { simd_double3(v.x, -v.y, -v.z) }
        let r1 = toARKit(r1cv), r2 = toARKit(r2cv), r3 = toARKit(r3cv), t = toARKit(g3)

        // 几何中心 = 平面原点(TL) + (r1+r2)·s/2
        let half = Float(s) / 2
        centerInCamera = simd_float3(Float(t.x), Float(t.y), Float(t.z))
            + simd_float3(Float(r1.x + r2.x), Float(r1.y + r2.y), Float(r1.z + r2.z)) * half

        markerToCamera = simd_float4x4(columns: (
            simd_float4(Float(r1.x), Float(r1.y), Float(r1.z), 0),
            simd_float4(Float(r2.x), Float(r2.y), Float(r2.z), 0),
            simd_float4(Float(r3.x), Float(r3.y), Float(r3.z), 0),
            simd_float4(Float(t.x), Float(t.y), Float(t.z), 1)
        ))
    }

    /// 竖直码约束精修：盒子立在地上 → 码面竖直、上下边水平。只解 码心(3) + 水平朝向(1) 共 4 个量，
    /// 对 8 个角点坐标做重投影最小二乘（Gauss-Newton）。比 6 自由度单应分解稳得多——
    /// 小码（3m 外 ~60px）单应分解的倾角解不准，距离会跟着错 5% 以上。
    /// cameraTransform：ARKit 相机→世界（世界 y 向上，worldAlignment = .gravity）。
    /// 返回码心世界坐标；码面明显不竖直（法向与水平夹角 > 30°）或角点对不上时返回 nil，调用方用原位姿。
    static func uprightCenterWorld(corners: [CGPoint], intrinsics: simd_float3x3,
                                   cameraTransform: simd_float4x4, markerSize: Float,
                                   initial: PlanarPose) -> simd_float3? {
        guard corners.count == 4 else { return nil }
        func dbl(_ m: simd_float4x4) -> simd_double4x4 {
            func c(_ v: simd_float4) -> simd_double4 { simd_double4(Double(v.x), Double(v.y), Double(v.z), Double(v.w)) }
            return simd_double4x4(columns: (c(m.columns.0), c(m.columns.1), c(m.columns.2), c(m.columns.3)))
        }
        let T = dbl(cameraTransform), Ti = T.inverse
        let fx = Double(intrinsics.columns.0.x), fy = Double(intrinsics.columns.1.y)
        let cx = Double(intrinsics.columns.2.x), cy = Double(intrinsics.columns.2.y)
        let s = Double(markerSize), h = s / 2
        let M = dbl(initial.markerToCamera)
        // 初始四角（世界）：平面坐标 TL(0,0) TR(s,0) BR(s,s) BL(0,s)
        let plane: [(Double, Double)] = [(0, 0), (s, 0), (s, s), (0, s)]
        let P0 = plane.map { uv -> simd_double3 in
            let w = T * (M * simd_double4(uv.0, uv.1, 0, 1)); return simd_double3(w.x, w.y, w.z)
        }
        let C0 = (P0[0] + P0[1] + P0[2] + P0[3]) / 4
        // 码面必须接近竖直：法向的 y 分量小
        let nrm = simd_normalize(simd_cross(P0[1] - P0[0], P0[3] - P0[0]))
        guard abs(nrm.y) < 0.5 else { return nil }
        // 水平轴 e：法向的水平垂线；每个角点在 (e, up) 上的符号
        var e = simd_normalize(simd_double3(-nrm.z, 0, nrm.x))
        let ab = P0.map { p -> (Double, Double) in
            let d = p - C0; return (simd_dot(d, e) >= 0 ? 1 : -1, d.y >= 0 ? 1 : -1)
        }
        guard Set(ab.map { "\($0.0),\($0.1)" }).count == 4 else { return nil }
        let obs = corners.map { simd_double2(Double($0.x), Double($0.y)) }
        func residuals(_ q: [Double]) -> [Double]? {
            e = simd_double3(cos(q[3]), 0, sin(q[3]))
            var r: [Double] = []
            for k in 0..<4 {
                let w = simd_double3(q[0], q[1], q[2]) + e * (ab[k].0 * h) + simd_double3(0, ab[k].1 * h, 0)
                let c = Ti * simd_double4(w.x, w.y, w.z, 1)
                guard c.z < -0.05 else { return nil }
                r.append(fx * c.x / -c.z + cx - obs[k].x)
                r.append(cy - fy * c.y / -c.z - obs[k].y)
            }
            return r
        }
        var q = [C0.x, C0.y, C0.z, atan2(e.z, e.x)]
        guard var r = residuals(q) else { return nil }
        var lambda = 1e-3
        for _ in 0..<30 {
            // 数值雅可比（8×4）
            var J = [[Double]](repeating: [Double](repeating: 0, count: 4), count: 8)
            for j in 0..<4 {
                var qp = q; let dq = j < 3 ? 1e-5 : 1e-6
                qp[j] += dq
                guard let rp = residuals(qp) else { return nil }
                for i in 0..<8 { J[i][j] = (rp[i] - r[i]) / dq }
            }
            // (JᵀJ + λ·diag) δ = -Jᵀr
            var A = [[Double]](repeating: [Double](repeating: 0, count: 4), count: 4)
            var g = [Double](repeating: 0, count: 4)
            for a in 0..<4 {
                for b in 0..<4 {
                    var acc = 0.0
                    for i in 0..<8 { acc += J[i][a] * J[i][b] }
                    A[a][b] = acc
                }
                A[a][a] *= 1 + lambda
                var acc = 0.0
                for i in 0..<8 { acc += J[i][a] * r[i] }
                g[a] = -acc
            }
            guard let d = gaussianSolve(A, g) else { return nil }
            let qn = zip(q, d).map { $0 + $1 }
            let cost: Double = r.reduce(0) { $0 + $1 * $1 }
            let newCost: Double? = residuals(qn).map { rn in rn.reduce(0) { $0 + $1 * $1 } }
            if let nc = newCost, nc < cost, let rn = residuals(qn) {
                q = qn; r = rn; lambda = max(1e-6, lambda / 3)
                if d.prefix(3).map(abs).max()! < 1e-6 { break }
            } else {
                lambda *= 10
            }
        }
        // 拟合残差过大（RMS > 3px）= 码并不竖直/角点错，放弃
        let sq: Double = r.reduce(0) { $0 + $1 * $1 }
        let rms = (sq / 8).squareRoot()
        guard rms < 3 else { return nil }
        return simd_float3(Float(q[0]), Float(q[1]), Float(q[2]))
    }

    /// 4 点单应（DLT，8×8 高斯消元）。from/to 一一对应。
    static func homography(from src: [(Double, Double)], to dst: [(Double, Double)]) -> simd_double3x3? {
        guard src.count == 4, dst.count == 4 else { return nil }
        // A h = b，h = [h11 h12 h13 h21 h22 h23 h31 h32]，h33 = 1
        var A = [[Double]](repeating: [Double](repeating: 0, count: 8), count: 8)
        var b = [Double](repeating: 0, count: 8)
        for i in 0..<4 {
            let (X, Y) = src[i]; let (x, y) = dst[i]
            A[2 * i]     = [X, Y, 1, 0, 0, 0, -x * X, -x * Y]
            b[2 * i]     = x
            A[2 * i + 1] = [0, 0, 0, X, Y, 1, -y * X, -y * Y]
            b[2 * i + 1] = y
        }
        guard let h = gaussianSolve(A, b) else { return nil }
        return simd_double3x3(rows: [
            simd_double3(h[0], h[1], h[2]),
            simd_double3(h[3], h[4], h[5]),
            simd_double3(h[6], h[7], 1),
        ])
    }

    static func gaussianSolve(_ A: [[Double]], _ b: [Double]) -> [Double]? {
        let n = b.count
        var m = A; var r = b
        for col in 0..<n {
            var pivot = col
            for row in col..<n where abs(m[row][col]) > abs(m[pivot][col]) { pivot = row }
            if abs(m[pivot][col]) < 1e-12 { return nil }
            m.swapAt(col, pivot); r.swapAt(col, pivot)
            let d = m[col][col]
            for j in col..<n { m[col][j] /= d }
            r[col] /= d
            for row in 0..<n where row != col {
                let f = m[row][col]
                guard f != 0 else { continue }
                for j in col..<n { m[row][j] -= f * m[col][j] }
                r[row] -= f * r[col]
            }
        }
        return r
    }
}
