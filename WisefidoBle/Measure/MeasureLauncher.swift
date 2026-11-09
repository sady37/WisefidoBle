//
//  MeasureLauncher.swift
//  WisefidoBle
//
//  给 ObjC 用的测量入口（app target 的 -Swift.h 只导出 public 声明，页面类本身保持 internal）。
//

import UIKit

@objc(MeasureLauncher)
public final class MeasureLauncher: NSObject {
    /// 手机测角：Pitch / Roll / Yaw（每次一种）
    @objc public static func presentAngleMeasure(from vc: UIViewController) {
        AngleMeasureViewController.present(from: vc)
    }

    /// 盒底 ArUco 测雷达安装高度；确认后回调高度（米）
    @objc public static func presentHeightMeasure(from vc: UIViewController, onResult: @escaping (Double) -> Void) {
        HeightMeasureViewController.present(from: vc, onResult: onResult)
    }
}
