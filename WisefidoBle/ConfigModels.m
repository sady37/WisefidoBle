//
//  ConfigModels.m
//

#import "ConfigModels.h"

// 定义常量
NSInteger const kSignalUnavailable = -255;  // 信号不可用的常量值
NSString * const kDefaultServerAddress = @"app.wisefido.com";
NSInteger const kDefaultServerPort = 29010;
NSString * const kDefaultServerProtocol = @"tcp";

#pragma mark - DeviceInfo 实现

@implementation DeviceInfo

- (instancetype)initWithProductorName:(Productor)productorName
                           deviceName:(NSString *)deviceName
                             deviceId:(nullable NSString *)deviceId
                          deviceType:(nullable NSString *)deviceType
                             version:(nullable NSString *)version
                                 uid:(nullable NSString *)uid
                          macAddress:(nullable NSString *)macAddress
                                 uuid:(nullable NSString *)uuid
                                 rssi:(NSInteger)rssi {
    self = [super init];
    if (self) {
        _productorName = productorName;
        _deviceName = [deviceName copy];
        _deviceId = [deviceId copy];
        _deviceType = [deviceType copy];  
        _version = [version copy];        
        _uid = [uid copy];                
        _macAddress = [macAddress copy];
        _uuid = [uuid copy];
        
        // 设置 rssi 默认值，如果传入 0 则设为不可用值
        _rssi = (rssi == 0) ? kSignalUnavailable : rssi;
        
        // 初始化其他属性
        _wifiConnected = NO;
        _wifiSignal = kSignalUnavailable; // 默认设置为不可用
        _serverPort = 0;
        _serverConnected = NO;
        _lastUpdateTime = 0;
    }
    return self;
}

#pragma mark - NSCoding

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) {
        _productorName = [coder decodeIntegerForKey:@"productorName"];
        _deviceName = [coder decodeObjectForKey:@"deviceName"];
        _deviceId = [coder decodeObjectForKey:@"deviceId"];
        _deviceType = [coder decodeObjectForKey:@"deviceType"];  // 新增 deviceType
        _version = [coder decodeObjectForKey:@"version"];        // 新增 version
        _uid = [coder decodeObjectForKey:@"uid"];                // 新增 uid
        _macAddress = [coder decodeObjectForKey:@"macAddress"];
        _uuid = [coder decodeObjectForKey:@"uuid"];
        _rssi = [coder decodeIntegerForKey:@"rssi"];
        
        // WiFi相关属性
        _wifiSsid = [coder decodeObjectForKey:@"wifiSsid"];
        _wifiPassword = [coder decodeObjectForKey:@"wifiPassword"];
        _wifiConnected = [coder decodeBoolForKey:@"wifiConnected"];
        _wifiMode = [coder decodeObjectForKey:@"wifiMode"];
        _wifiSignal = [coder decodeIntegerForKey:@"wifiSignal"];
        _wifiMacAddress = [coder decodeObjectForKey:@"wifiMacAddress"];
        
        // 服务器相关属性
        _serverAddress = [coder decodeObjectForKey:@"serverAddress"];
        _serverPort = [coder decodeIntegerForKey:@"serverPort"];
        _serverProtocol = [coder decodeObjectForKey:@"serverProtocol"];
        _serverConnected = [coder decodeBoolForKey:@"serverConnected"];
        
        // 其他状态信息
        _lastUpdateTime = [coder decodeDoubleForKey:@"lastUpdateTime"];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeInteger:_productorName forKey:@"productorName"];
    [coder encodeObject:_deviceName forKey:@"deviceName"];
    [coder encodeObject:_deviceId forKey:@"deviceId"];
    [coder encodeObject:_deviceType forKey:@"deviceType"];  // 新增 deviceType
    [coder encodeObject:_version forKey:@"version"];        // 新增 version
    [coder encodeObject:_uid forKey:@"uid"];                // 新增 uid
    [coder encodeObject:_macAddress forKey:@"macAddress"];
    [coder encodeObject:_uuid forKey:@"uuid"];
    [coder encodeInteger:_rssi forKey:@"rssi"];
    
    // WiFi相关属性
    [coder encodeObject:_wifiSsid forKey:@"wifiSsid"];
    [coder encodeObject:_wifiPassword forKey:@"wifiPassword"];
    [coder encodeBool:_wifiConnected forKey:@"wifiConnected"];
    [coder encodeObject:_wifiMode forKey:@"wifiMode"];
    [coder encodeInteger:_wifiSignal forKey:@"wifiSignal"];
    [coder encodeObject:_wifiMacAddress forKey:@"wifiMacAddress"];
    
    // 服务器相关属性
    [coder encodeObject:_serverAddress forKey:@"serverAddress"];
    [coder encodeInteger:_serverPort forKey:@"serverPort"];
    [coder encodeObject:_serverProtocol forKey:@"serverProtocol"];
    [coder encodeBool:_serverConnected forKey:@"serverConnected"];
    
    // 其他状态信息
    [coder encodeDouble:_lastUpdateTime forKey:@"lastUpdateTime"];
}

@end
