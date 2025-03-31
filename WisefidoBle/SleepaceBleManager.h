//
//  SleepaceBleManager.h
//

#import <Foundation/Foundation.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import "ConfigModels.h"

// Sleepace SDKs
#import <BluetoothManager/BluetoothManager.h>
#import <BLEWifiConfig/BLEWifiConfig.h>
#import <SLPCommon/SLPCommon.h>

NS_ASSUME_NONNULL_BEGIN


// 错误类型枚举
typedef NS_ENUM(NSInteger, SleepaceBleErrorType) {
    SleepaceBleErrorNone = 0,              // 无错误
    SleepaceBleErrorConnectionTimeout,      // 连接超时
    SleepaceBleErrorSecurityNegotiation,    // 安全协商失败
    SleepaceBleErrorDataTransmission,       // 数据传输错误
    SleepaceBleErrorDeviceNotFound,         // 设备未找到
    SleepaceBleErrorBluetoothDisabled,      // 蓝牙已禁用
    SleepaceBleErrorInvalidParameter,       // 无效参数
    SleepaceBleErrorUnknown                 // 未知错误
};

/**
 * Sleepace设备扫描结果回调
 * @param deviceInfo 发现的设备信息
 */
typedef void(^SleepaceScanCallback)(DeviceInfo * _Nonnull deviceInfo);

/**
 * Sleepace设备配置结果回调
 * @param success 配置是否成功
 * @param result 配置结果详情，包含状态码、错误信息等
 */
typedef void(^SleepaceConfigCallback)(BOOL success, NSDictionary * _Nonnull result);

/**
 * Sleepace设备状态查询回调
 * @param updatedDevice 更新后的设备信息，包含WiFi连接状态等
 * @param success 查询是否成功
 */
typedef void(^SleepaceStatusCallback)(DeviceInfo * _Nonnull updatedDevice, BOOL success);

/**
 * Sleepace蓝牙管理器
 * 提供Sleepace设备的扫描、连接、配置和状态查询功能
 */
//@interface SleepaceBleManager : NSObject
@interface SleepaceBleManager : NSObject <CBCentralManagerDelegate, CBPeripheralDelegate>
#pragma mark - 初始化和单例方法

/**
 * 获取单例实例
 * @param delegate 可选代理对象，用于处理Sleepace SDK的回调
 * @return SleepaceBleManager单例对象
 */
+ (instancetype)getInstance:(nullable id)delegate;

/**
 * 设置错误回调
 * @param callback 错误回调函数，当操作过程中出现错误时调用
 */
- (void)setErrorCallback:(void(^)(SleepaceBleErrorType errorType, NSString *errorMessage))callback;

#pragma mark - 扫描方法

/**
 * 设置扫描回调
 * @param callback 扫描结果回调，每发现一个设备触发一次
 */
- (void)setScanCallback:(SleepaceScanCallback)callback;

/**
 * 开始扫描设备，使用默认超时时间
 */
- (void)startScan;

/**
 * 开始扫描设备，指定超时时间和过滤选项
 * 注意：Sleepace SDK不支持过滤功能，传入的过滤参数将被忽略
 *
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

#pragma mark - 设备连接方法

/**
 * 连接设备
 * @param device 设备信息，必须包含有效的deviceId
 */
- (void)connectDevice:(DeviceInfo *)device;

/**
 * 断开当前设备连接
 */
- (void)disconnect;

#pragma mark - 设备配置方法

/**
 * 配置设备的 WiFi 和服务器
 * 如果某项不需要配置，传递 nil 或 0 即可
 *
 * @param device 目标设备
 * @param wifiSsid WiFi 的 SSID（可为 nil）
 * @param wifiPassword WiFi 的密码（可为 nil）
 * @param serverAddress 服务器地址（可为 nil）
 * @param serverPort 服务器端口（可为 0）
 * @param serverProtocol 服务器协议（TCP/UDP，可为 nil）
 * @param completion 配置结果回调
 */
- (void)configureDevice:(DeviceInfo *)device
              wifiSsid:(nullable NSString *)wifiSsid
          wifiPassword:(nullable NSString *)wifiPassword
         serverAddress:(nullable NSString *)serverAddress
            serverPort:(NSInteger)serverPort
        serverProtocol:(nullable NSString *)serverProtocol
            completion:(SleepaceConfigCallback)completion;

#pragma mark - 设备状态查询方法

/**
 * 查询设备WiFi连接状态（直接使用CBPeripheral对象）
 * 此方法为底层实现，通常建议使用queryDeviceStatus:方法
 *
 * @param bleDevice 蓝牙设备对象，从扫描结果获取
 * @param completion 查询结果回调，success表示查询是否成功，data包含查询结果
 */
- (void)checkWiFiStatus:(CBPeripheral *)bleDevice 
             completion:(void(^)(BOOL success, id data))completion;

/**
 * 查询设备状态
 * 获取设备的WiFi连接状态、版本信息等
 *
 * @param device 设备信息，必须包含有效的deviceId
 * @param completion 查询结果回调，返回更新后的设备信息
 */
- (void)queryDeviceStatus:(DeviceInfo *)device
               completion:(SleepaceStatusCallback)completion;


@end

NS_ASSUME_NONNULL_END
