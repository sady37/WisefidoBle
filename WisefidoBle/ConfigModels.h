//
//  ConfigModels.h
//
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// 信号不可用的常量值
extern NSInteger const kSignalUnavailable;

// 设备生产商枚举
typedef NS_ENUM(NSInteger, Productor) {
    ProductorRadarQL,      // A厂雷达设备
    ProductorSleepBoardHS, // B厂睡眠板设备
    ProductorEspBle        // 通用蓝牙设备
};

// 过滤器类型枚举
typedef NS_ENUM(NSInteger, FilterType) {
    FilterTypeDeviceName,  // 设备名称过滤
    FilterTypeMac,         // MAC地址过滤
    FilterTypeUUID         // UUID过滤
};

// 设备信息类
@interface DeviceInfo : NSObject <NSCoding>

// 基本设备信息
@property (nonatomic, assign) Productor productorName;      // 设备生产商
@property (nonatomic, copy) NSString *deviceName;           // 设备名称
@property (nonatomic, copy) NSString *deviceId;             // 设备ID
@property (nonatomic, copy, nullable) NSString *deviceType;  // 设备类型（可为nil）
@property (nonatomic, copy, nullable) NSString *version;    // 设备版本（可为nil）
@property (nonatomic, copy, nullable) NSString *uid;        // 设备UID（可为nil）
@property (nonatomic, copy, nullable) NSString *macAddress; // MAC地址（可为nil）
@property (nonatomic, copy, nullable) NSString *uuid;       // iOS设备UUID（可为nil）
@property (nonatomic, assign) NSInteger rssi;               // 信号强度（-255表示不可用）

// WiFi状态属性
@property (nonatomic, copy, nullable) NSString *wifiSsid;        // 当前连接的WiFi SSID（可为nil）
@property (nonatomic, copy, nullable) NSString *wifiPassword;    // WiFi密码（可为nil，仅用于配置）
@property (nonatomic, assign) BOOL wifiConnected;                // WiFi是否已连接
@property (nonatomic, copy, nullable) NSString *wifiMode;        // WiFi模式(STA/AP/STASOFTAP)（可为nil）
@property (nonatomic, assign) NSInteger wifiSignal;              // WiFi信号强度（-255表示不可用）
@property (nonatomic, copy, nullable) NSString *wifiMacAddress;  // WiFi MAC地址（可为nil）

// 服务器状态属性
@property (nonatomic, copy, nullable) NSString *serverAddress;    // 服务器地址（可为nil）
@property (nonatomic, assign) NSInteger serverPort;               // 服务器端口（可能不可用）
@property (nonatomic, copy, nullable) NSString *serverProtocol;   // 服务器协议(TCP/UDP)（可为nil）
@property (nonatomic, assign) BOOL serverConnected;               // 是否已连接服务器

// 其他状态信息
@property (nonatomic, assign) NSTimeInterval lastUpdateTime; // 最后更新时间

// 初始化方法
// 保留原有方法
- (instancetype)initWithProductorName:(Productor)productorName
                           deviceName:(NSString *)deviceName
                             deviceId:(NSString *)deviceId
                            deviceType:(NSString *)deviceType   
                               version:(NSString *)version
                                   uid:(NSString *)uid
                           macAddress:(nullable NSString *)macAddress
                                uuid:(nullable NSString *)uuid
                                rssi:(NSInteger)rssi;
@end

// 默认配置常量，外部可见
extern NSString * const kDefaultServerAddress;
extern NSInteger const kDefaultServerPort;
extern NSString * const kDefaultServerProtocol;

NS_ASSUME_NONNULL_END



