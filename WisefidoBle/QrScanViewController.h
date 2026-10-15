//
//  QrScanViewController.h
//  扫描设备二维码（AVFoundation）：扫到第一个 QR 即关闭并回调，对应 Android dialog_qr_scan
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class QrScanViewController;

@protocol QrScanViewControllerDelegate <NSObject>
- (void)qrScanViewController:(QrScanViewController *)controller didScanCode:(NSString *)code;
@end

@interface QrScanViewController : UIViewController

@property (nonatomic, weak, nullable) id<QrScanViewControllerDelegate> delegate;

@end

NS_ASSUME_NONNULL_END
