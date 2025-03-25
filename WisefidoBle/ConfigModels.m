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
                             deviceId:(NSString *)deviceId
                          macAddress:(nullable NSString *)macAddress
                                uuid:(nullable NSString *)uuid
                                rssi:(NSInteger)rssi {
    self = [super init];
    if (self) {
        _productorName = productorName;
        _deviceName = [deviceName copy];
        _deviceId = [deviceId copy];
        _macAddress = [macAddress copy];
        _uuid = [uuid copy];
        
        // 设置 rssi 默认值，如果传入 0 则设为不可用值
        _rssi = (rssi == 0) ? kSignalUnavailable : rssi;
        
        // 初始化其他属性
        _sleepaceProtocolType = 0;
        _sleepaceDeviceType = 0;
        _sleepaceVersionCode = nil;
        
        // 初始化 WiFi 相关属性
        _wifiConnected = NO;
        _wifiSignal = kSignalUnavailable; // 默认设置为不可用
        _serverPort = 0;
        _serverConnected = NO;
        _lastUpdateTime = 0;
    }
    return self;
}

- (NSString *)displayName {
    return _deviceName.length > 0 ? _deviceName : _deviceId;
}

- (NSString *)bestIdentifier {
    if (_uuid.length > 0) {
        return _uuid;  // 在iOS上优先使用UUID
    } else if (_macAddress.length > 0) {
        return _macAddress;  // 在Android上优先使用MAC地址
    } else {
        return _deviceId;  // 兜底使用deviceId
    }
}

#pragma mark - NSCoding

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) {
        _productorName = [coder decodeIntegerForKey:@"productorName"];
        _deviceName = [coder decodeObjectForKey:@"deviceName"];
        _deviceId = [coder decodeObjectForKey:@"deviceId"];
        _macAddress = [coder decodeObjectForKey:@"macAddress"];
        _uuid = [coder decodeObjectForKey:@"uuid"];
        _rssi = [coder decodeIntegerForKey:@"rssi"];
        _version = [coder decodeObjectForKey:@"version"];
        _uid = [coder decodeObjectForKey:@"uid"];
        
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
        
        // Sleepace特有属性
        _sleepaceProtocolType = [coder decodeIntegerForKey:@"sleepaceProtocolType"];
        _sleepaceDeviceType = [coder decodeIntegerForKey:@"sleepaceDeviceType"];
        _sleepaceVersionCode = [coder decodeObjectForKey:@"sleepaceVersionCode"];
        
        // 其他状态信息
        _lastUpdateTime = [coder decodeDoubleForKey:@"lastUpdateTime"];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeInteger:_productorName forKey:@"productorName"];
    [coder encodeObject:_deviceName forKey:@"deviceName"];
    [coder encodeObject:_deviceId forKey:@"deviceId"];
    [coder encodeObject:_macAddress forKey:@"macAddress"];
    [coder encodeObject:_uuid forKey:@"uuid"];
    [coder encodeInteger:_rssi forKey:@"rssi"];
    [coder encodeObject:_version forKey:@"version"];
    [coder encodeObject:_uid forKey:@"uid"];
    
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
    
    // Sleepace特有属性
    [coder encodeInteger:_sleepaceProtocolType forKey:@"sleepaceProtocolType"];
    [coder encodeInteger:_sleepaceDeviceType forKey:@"sleepaceDeviceType"];
    [coder encodeObject:_sleepaceVersionCode forKey:@"sleepaceVersionCode"];
    
    // 其他状态信息
    [coder encodeDouble:_lastUpdateTime forKey:@"lastUpdateTime"];
}

@end
