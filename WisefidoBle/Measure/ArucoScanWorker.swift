//
//  ArucoScanWorker.swift
//  WisefidoBle
//
//  扫码面板的 ArUco 旁路：同一路相机画面里识别包装盒底 ArUco 码（与 owlCare 相同的 #0 / #7），
//  连续 2 帧命中返回 YES → 进入测高。只在调用方的专用串行队列上跑，线程安全靠队列封闭。
//

import Foundation
import CoreVideo

@objc(ArucoScanWorker)
public nonisolated final class ArucoScanWorker: NSObject, @unchecked Sendable {
    private let detector = ArucoDetector()
    private var streak = 0

    public override init() { super.init() }

    /// 竖屏采集的相机帧（缓冲为横屏，显示朝向 .right）
    @objc public func processFrame(_ buffer: CVPixelBuffer) -> Bool {
        let hit = detector.detect(in: buffer, orientation: .right) != nil
        streak = hit ? streak + 1 : 0
        return streak >= 2
    }
}
