//
//  RadarBleManager.h
//

#import <Foundation/Foundation.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import "ConfigModels.h"

// ESP BluFi SDK头文件
#import "BlufiClient.h" 
#import "BlufiConfigureParams.h"
#import "BlufiConstants.h"
#import "BlufiStatusResponse.h"
#import "BlufiScanResponse.h"
#import "BlufiVersionResponse.h"

NS_ASSUME_NONNULL_BEGIN

// 错误类型枚举，基于ESP Blufi SDK的状态
typedef NS_ENUM(NSInteger, RadarBleErrorType) {
    RadarBleErrorNone = 0,              // 无错误
    RadarBleErrorConnectionTimeout,      // 连接超时
    RadarBleErrorSecurityNegotiation,    // 安全协商失败
    RadarBleErrorDataTransmission,       // 数据传输错误
    RadarBleErrorDeviceNotFound,         // 设备未找到
    RadarBleErrorBluetoothDisabled,      // 蓝牙已禁用
    RadarBleErrorInvalidParameter,       // 无效参数
    RadarBleErrorUnknown                 // 未知错误
};

/**
 * Radar设备扫描结果回调
 * @param deviceInfo 发现的设备信息
 */
typedef void(^RadarScanCallback)(DeviceInfo * _Nonnull deviceInfo);

/**
 * Radar设备配置结果回调
 * @param success 配置是否成功
 * @param result 配置结果详情，包含状态码、错误信息等
 */
typedef void(^RadarConfigCallback)(BOOL success, NSDictionary * _Nonnull result);

/**
 * Radar设备状态查询回调
 * @param updatedDevice 更新后的设备信息，包含WiFi连接状态等
 * @param success 查询是否成功
 */
typedef void(^RadarStatusCallback)(DeviceInfo * _Nonnull updatedDevice, BOOL success);

/**
 * Radar蓝牙管理器
 * 提供Radar设备的扫描、连接、配置和状态查询功能
 */
@interface RadarBleManager : NSObject

/**
 * 获取单例实例
 * @return RadarBleManager单例对象
 */
+ (instancetype)sharedManager;

/**
 * 设置扫描回调
 * @param callback 扫描结果回调，每发现一个设备触发一次
 */
- (void)setScanCallback:(RadarScanCallback)callback;

/**
 * 开始扫描设备，使用默认超时时间
 */
- (void)startScan;

/**
 * 开始扫描设备，指定超时时间和过滤前缀
 * @param timeout 扫描超时时间(秒)，0表示使用默认值(10秒)
 * @param filterPrefix 过滤前缀，只扫描名称包含该前缀的设备，nil表示不过滤
 * @param filterType 过滤类型，默认为设备名称过滤
 */
- (void)startScanWithTimeout:(NSTimeInterval)timeout 
               filterPrefix:(nullable NSString *)filterPrefix
                 filterType:(FilterType)filterType;

/**
 * 停止扫描设备
 */
- (void)stopScan;

/**
 * 配置设备WiFi，使用默认超时时间
 * @param device 设备信息，必须包含有效的id
 * @param wifiSsid WiFi SSID
 * @param wifiPassword WiFi密码
 * @param completion 配置结果回调
 */
- (void)configureWiFi:(DeviceInfo *)device
             wifiSsid:(NSString *)wifiSsid
         wifiPassword:(nullable NSString *)wifiPassword
           completion:(RadarConfigCallback)completion;



/**
 * 配置设备服务器，使用默认超时时间
 * @param device 设备信息，必须包含有效的id
 * @param serverAddress 服务器地址
 * @param serverPort 服务器端口
 * @param serverProtocol 服务器协议
 * @param completion 配置结果回调
 */
- (void)configureServer:(DeviceInfo *)device
          serverAddress:(NSString *)serverAddress
            serverPort:(NSInteger)serverPort
         serverProtocol:(nullable NSString *)serverProtocol
             completion:(RadarConfigCallback)completion;


/**
 * 配置设备WiFi和服务器，使用默认超时时间
 * @param device 设备信息，必须包含有效的id
 * @param serverAddress 服务器地址，可为nil
 * @param serverPort 服务器端口
 * @param serverProtocol 服务器协议，可为nil
 * @param wifiSsid WiFi SSID，可为nil
 * @param wifiPassword WiFi密码，可为nil
 * @param completion 配置结果回调
 */
- (void)configureDevice:(DeviceInfo *)device
          serverAddress:(nullable NSString *)serverAddress
            serverPort:(NSInteger)serverPort
         serverProtocol:(nullable NSString *)serverProtocol
               wifiSsid:(nullable NSString *)wifiSsid
           wifiPassword:(nullable NSString *)wifiPassword
             completion:(RadarConfigCallback)completion;


/**
 * 查询设备状态
 * @param device 设备信息，必须包含有效的id
 * @param completion 查询结果回调，返回更新后的设备信息
 */
- (void)queryDeviceStatus:(DeviceInfo *)device
              completion:(RadarStatusCallback)completion;



/**
 * 设置错误回调
 * @param callback 错误回调函数
 */
- (void)setErrorCallback:(void(^)(RadarBleErrorType errorType, NSString *errorMessage))callback;

/**
 * 连接设备
 * @param device 设备信息
 */
- (void)connectDevice:(DeviceInfo *)device;

/**
 * 断开连接
 */
- (void)disconnect;

@end

NS_ASSUME_NONNULL_END
