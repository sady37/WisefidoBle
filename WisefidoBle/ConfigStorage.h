// ConfigStorage.h
#import <Foundation/Foundation.h>
#import "ConfigModels.h"  // 引用 ConfigModels

@interface ConfigStorage : NSObject

// 服务器配置管理
- (void)saveServerConfig:(NSString *_Nullable)serverAddress port:(NSInteger)serverPort protocol:(nullable NSString *)serverProtocol;
- (NSArray<NSDictionary *> *_Nullable)getServerConfigs;

// WiFi配置管理
- (void)saveWiFiConfigWithSsid:(NSString *_Nullable)wifiSsid password:(NSString *_Nullable)wifiPassword;
- (NSArray<NSDictionary<NSString *, NSString *> *> *_Nullable)getWiFiConfigs;

// 雷达设备名称管理
- (void)saveRadarDeviceName:(NSString *_Nullable)name;
- (NSString *_Nullable)getRadarDeviceName;

// 过滤器类型管理
- (void)saveFilterType:(FilterType)filterType;
- (FilterType)getFilterType;

@end

// 默认配置常量，外部可见
// 定义 UserDefaults 键
extern NSString * _Nullable const kServerConfigsKey;
extern NSString * _Nullable const kWiFiConfigsKey;
extern NSString * _Nullable const kRadarDeviceNameKey;
extern NSString * _Nullable const kFilterTypeKey;
extern NSString * _Nullable const kDefaultRadarDeviceName;
