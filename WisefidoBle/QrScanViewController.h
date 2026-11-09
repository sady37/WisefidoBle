//
//  QrScanViewController.h
//  扫描设备二维码（系统 AVFoundation 检测）：作为顶部浮层显示，扫到第一个 QR 即关闭并回调，对应 Android dialog_qr_scan
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class QrScanViewController;

@protocol QrScanViewControllerDelegate <NSObject>
- (void)qrScanViewController:(QrScanViewController *)controller didScanCode:(NSString *)code;
@optional
/// 扫到包装盒底 ArUco 码（连续 2 帧）→ 面板已关闭，调用方进入测高
- (void)qrScanViewControllerDidDetectAruco:(QrScanViewController *)controller;
@end

@interface QrScanViewController : UIViewController

@property (nonatomic, weak, nullable) id<QrScanViewControllerDelegate> delegate;

/// 关闭扫码面板：作为顶部子控制器时上滑移除，作为模态时 dismiss；完成后调用 completion
- (void)closeAnimated:(BOOL)animated completion:(nullable void (^)(void))completion;

@end

NS_ASSUME_NONNULL_END
