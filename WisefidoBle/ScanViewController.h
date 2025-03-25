//
//  ScanViewController.h
//

#import <UIKit/UIKit.h>
#import "ConfigModels.h"  // 引入设备信息模型定义
#import <CoreBluetooth/CoreBluetooth.h> // 引入CoreBluetooth框架以使用蓝牙功能

NS_ASSUME_NONNULL_BEGIN

@class ScanViewController;

// 扫描视图控制器代理协议 - 用于设备选择回调
@protocol ScanViewControllerDelegate <NSObject>
/**
 * 当用户选择设备时回调
 * @param controller 调用回调的扫描视图控制器
 * @param device 选中的设备信息
 */
- (void)scanViewController:(ScanViewController *)controller didSelectDevice:(DeviceInfo *)device;
@end

// 扫描视图控制器 - 负责显示扫描界面和处理设备选择
@interface ScanViewController : UIViewController <UITableViewDelegate, UITableViewDataSource, UITextFieldDelegate>

// 代理属性 - 用于设备选择回调
@property (nonatomic, weak, nullable) id<ScanViewControllerDelegate> delegate;

/**
 * 初始化方法
 * @param centralManager 蓝牙中心管理器
 */
- (instancetype)initWithCentralManager:(CBCentralManager *)centralManager;

/**
 * 开始扫描设备
 * 会根据当前选择的扫描模块和过滤设置进行扫描
 */
- (void)startScan;

/**
 * 停止扫描设备
 * 会停止所有蓝牙扫描操作
 */
- (void)stopScan;

@end

NS_ASSUME_NONNULL_END
