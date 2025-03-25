//
//  MainViewController.h
//

#import <UIKit/UIKit.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import "ConfigModels.h"       // 引入设备信息模型定义
#import "ConfigStorage.h"      // 引入配置存储类
#import "ScanViewController.h" // 引入扫描视图控制器

NS_ASSUME_NONNULL_BEGIN

// 主视图控制器 - 负责展示和管理雷达设备的配置和扫描
@interface MainViewController : UIViewController <ScanViewControllerDelegate, UITextFieldDelegate, CBCentralManagerDelegate>

// 蓝牙中心管理器
@property (nonatomic, strong) CBCentralManager *centralManager;



// 方法声明

/**
 * 初始化方法
 * @param centralManager 蓝牙中心管理器
 */
- (instancetype)initWithCentralManager:(CBCentralManager *)centralManager;

/**
 * 处理搜索按钮点击事件
 * 跳转到扫描视图控制器
 */
 - (void)handleSearchButton:(id)sender;

/**
 * 更新设备信息
 * @param deviceInfo 包含设备信息的对象，包括设备名称、设备 ID 和信号强度
 */
 - (void)updateDeviceInfo:(DeviceInfo *)deviceInfo;

@end

NS_ASSUME_NONNULL_END
