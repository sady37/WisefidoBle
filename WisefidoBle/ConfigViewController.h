//
//  ConfigViewController.h
//

#import <UIKit/UIKit.h>
#import "ConfigModels.h"
#import "ConfigStorage.h"


NS_ASSUME_NONNULL_BEGIN

// 配置完成回调块
typedef void(^ConfigCompletionBlock)(NSString *radarDeviceName, FilterType filterType);

// 配置视图控制器 - 负责设置雷达设备名和过滤类型
@interface ConfigViewController : UIViewController

@property (nonatomic, strong) UITextField *textField; // Add this property to resolve the issue

// 初始化方法 - 传入当前配置和完成回调
- (instancetype)initWithRadarDeviceName:(NSString *)radarDeviceName 
                             filterType:(FilterType)filterType
                             completion:(ConfigCompletionBlock)completion;

@end

NS_ASSUME_NONNULL_END
