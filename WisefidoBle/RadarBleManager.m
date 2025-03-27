//
//  RadarBleManager.m
//


/*ESPESP
  - `didPostConfigureParams`         ESP SDK  WiFi 配置的封装方法。
  - `didReceiveDeviceStatusResponse` ESP SDK设备状态查询的封装方法
  - `postCustomData` 和 `didPostCustomData` 专注于自定义命令的发送和处理，适用于服务器配置等场
  所有命令都统一通过BlufiClient发送
  所有响应都统一在BlufiDelegate的回调方法中处理
  - `didReceiveCustomData` 处理所有自定义命令的响应，解析响应数据并根据命令类型调用相应的处理方法。
  - `didPostConfigureParams` 处理 WiFi 配置的结果，主要用于 WiFi 配置完成后的回调。
  - `didPostCustomData` 处理服务器配置的结果，主要用于服务器配置完成后的回调。

*/

#import "RadarBleManager.h"
#import <CoreBluetooth/CoreBluetooth.h>

// 日志宏定义
#define RDRLOG(fmt, ...) NSLog((@"[RadarBleManager] " fmt), ##__VA_ARGS__)

// 默认超时常量
#define DEFAULT_SCAN_TIMEOUT 10.0
#define DEFAULT_CONFIG_TIMEOUT 30.0
#define DEFAULT_CONNECT_TIMEOUT 10.0
#define DEFAULT_COMMAND_DELAY 1.0 // 延迟执行命令的时间

@interface RadarBleManager() <CBCentralManagerDelegate, BlufiDelegate>

// 蓝牙相关属性 (BlufiClient、Central Manager)
@property (nonatomic, strong) BlufiClient *blufiClient;
@property (nonatomic, strong) CBCentralManager *centralManager;

// 状态标志 (是否扫描、连接中)
@property (nonatomic, assign) BOOL isScanning;
@property (nonatomic, assign) BOOL isConnecting;
@property (nonatomic, assign) BOOL isConfiguring;

// 回调属性 (扫描、配置、状态查询回调)
@property (nonatomic, copy) RadarScanCallback scanCallback;
@property (nonatomic, copy) RadarConfigCallback configCallback;
@property (nonatomic, copy) RadarStatusCallback statusCallback;
@property (nonatomic, copy) void(^connectCallback)(BOOL success);

// 与服务器配置相关的属性
@property (nonatomic, strong) NSMutableDictionary *configServerResult;
@property (nonatomic, assign) NSInteger configRetryCount;
@property (nonatomic, assign) NSInteger configServerSendStage;
@property (nonatomic, copy) NSString *serverAddress;
@property (nonatomic, assign) NSInteger serverPort;
@property (nonatomic, copy) NSString *serverProtocol;
@property (nonatomic, copy) NSString *wifiSsid;
@property (nonatomic, copy) NSString *wifiPassword;

// 超时管理属性
@property (nonatomic, strong) NSTimer *scanTimer;
@property (nonatomic, strong) NSTimer *configTimer;
@property (nonatomic, strong) NSTimer *connectTimer;
@property (nonatomic, strong) NSTimer *queryTimer; 

// 查询状态控制
@property (nonatomic, assign) BOOL isQueryComplete;
@property (nonatomic, assign) BOOL hasWifiStatus;
@property (nonatomic, assign) BOOL hasUID;
@property (nonatomic, assign) BOOL hasMacAddress; 

// 设备相关属性
@property (nonatomic, strong) DeviceInfo *currentDevice;
@property (nonatomic, copy) NSString *currentDeviceUUID;
@property (nonatomic, strong) NSMutableDictionary *deviceCache; 
@property (nonatomic, strong) NSMutableDictionary *statusMap; 

// 过滤属性
@property (nonatomic, copy) NSString *currentFilterPrefix;
@property (nonatomic, assign) FilterType currentFilterType;

// 错误处理
@property (nonatomic, assign) NSInteger errorCount;
@property (nonatomic, copy) void(^errorCallback)(RadarBleErrorType errorType, NSString *errorMessage);

@end

@implementation RadarBleManager

// 单例方法
+ (instancetype)sharedManager {
    static RadarBleManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[RadarBleManager alloc] init];
    });
    return instance;
}

// 初始化方法
- (instancetype)init {
    self = [super init];
    if (self) {
        // 初始化BlufiClient
        _blufiClient = [[BlufiClient alloc] init];
        
        // 初始化Central Manager
        _centralManager = [[CBCentralManager alloc] initWithDelegate:self queue:nil];
        
        // 设置BlufiClient代理
        _blufiClient.blufiDelegate = self;
        _blufiClient.centralManagerDelete = self;
        _blufiClient.peripheralDelegate = (id<CBPeripheralDelegate>)self;
        
        // 初始化其他属性
        _isScanning = NO;
        _isConnecting = NO;
        _isConfiguring = NO;
        _errorCount = 0;
        
        // 设置默认过滤类型
        _currentFilterType = FilterTypeDeviceName;
    }
    return self;
}

// 资源释放方法
- (void)dealloc {
    RDRLOG(@"Releasing RadarBleManager resources");
    
    // 停止所有操作
    [self stopScan];
    [self disconnect];
    
    // 取消定时器
    [_scanTimer invalidate];
    [_configTimer invalidate];
    [_connectTimer invalidate];
    
    // 清空回调
    _scanCallback = nil;
    _configCallback = nil;
    _statusCallback = nil;
    _errorCallback = nil;
    
    // 清理BlufiClient
    _blufiClient.blufiDelegate = nil;
    _blufiClient.centralManagerDelete = nil;
    _blufiClient = nil;
}

#pragma mark - 错误处理

// 设置错误回调
- (void)setErrorCallback:(void (^)(RadarBleErrorType, NSString *))callback {
    _errorCallback = callback;
    RDRLOG(@"Error callback set successfully");
}

// 重置错误计数
- (void)resetErrorCount {
    _errorCount = 0;
}

#pragma mark - Scan Methods

// 设置扫描回调
- (void)setScanCallback:(RadarScanCallback)callback {
    _scanCallback = callback;
    RDRLOG(@"Scan callback set successfully");
}

// 开始扫描，使用默认参数
- (void)startScan {
    [self startScanWithTimeout:DEFAULT_SCAN_TIMEOUT 
               filterPrefix:nil 
                 filterType:FilterTypeDeviceName];
}

// 开始扫描，指定超时时间、过滤前缀和过滤类型
- (void)startScanWithTimeout:(NSTimeInterval)timeout 
               filterPrefix:(nullable NSString *)filterPrefix 
                 filterType:(FilterType)filterType {
    if (_isScanning) {
        RDRLOG(@"Scan already in progress, ignoring request");
        return;
    }
    
    // 检查蓝牙状态
    if (_centralManager.state != CBManagerStatePoweredOn) {
        RDRLOG(@"Bluetooth not enabled, cannot start scan");
        if (_errorCallback) {
            _errorCallback(RadarBleErrorBluetoothDisabled, @"Bluetooth is disabled");
        }
        return;
    }
    
    // 保存过滤参数
    _currentFilterPrefix = filterPrefix;
    _currentFilterType = filterType;
    
    RDRLOG(@"Starting scan: timeout=%.1fs, filter=%@, type=%@", 
           timeout, 
           filterPrefix ?: @"None", 
           filterType == FilterTypeDeviceName ? @"DeviceName" : (filterType == FilterTypeMac ? @"MAC" : @"UUID"));
    
    // 设置扫描标志
    _isScanning = YES;
    
    // 设置扫描超时计时器
    _scanTimer = [NSTimer scheduledTimerWithTimeInterval:timeout
                                                  target:self
                                                selector:@selector(scanTimedOut)
                                                userInfo:nil
                                                 repeats:NO];
    
    // 开始扫描，不使用过滤器参数，而是在回调中处理过滤
    NSDictionary *options = @{CBCentralManagerScanOptionAllowDuplicatesKey: @NO};
    [_centralManager scanForPeripheralsWithServices:nil options:options];
}

// 停止扫描
- (void)stopScan {
    if (!_isScanning) {
        return;
    }
    
    RDRLOG(@"Stopping scan");
    
    // 停止蓝牙扫描
    [_centralManager stopScan];
    
    // 取消超时计时器
    [_scanTimer invalidate];
    _scanTimer = nil;
    
    _isScanning = NO;
}

// 扫描超时处理
- (void)scanTimedOut {
    RDRLOG(@"Scan timed out");
    [self stopScan];
}

#pragma mark - CBCentralManagerDelegate Methods

// 蓝牙状态变化回调
- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    RDRLOG(@"Bluetooth state updated: %ld", (long)central.state);
    
    // 蓝牙关闭时停止扫描
    if (central.state != CBManagerStatePoweredOn && _isScanning) {
        [self stopScan];
    }
    
    // 通知蓝牙状态变化
    if (central.state != CBManagerStatePoweredOn && _errorCallback) {
        NSString *stateMessage;
        switch(central.state) {
            case CBManagerStatePoweredOff:
                stateMessage = @"Bluetooth is powered off";
                break;
            case CBManagerStateResetting:
                stateMessage = @"Bluetooth is resetting";
                break;
            case CBManagerStateUnsupported:
                stateMessage = @"Bluetooth is not supported";
                break;
            case CBManagerStateUnauthorized:
                stateMessage = @"Bluetooth is not authorized";
                break;
            default:
                stateMessage = @"Bluetooth state is unknown";
                break;
        }
        _errorCallback(RadarBleErrorBluetoothDisabled, stateMessage);
    }
}

// 发现外设回调
- (void)centralManager:(CBCentralManager *)central 
 didDiscoverPeripheral:(CBPeripheral *)peripheral 
     advertisementData:(NSDictionary<NSString *,id> *)advertisementData 
                  RSSI:(NSNumber *)RSSI {
    // 获取设备名称
    NSString *deviceName = peripheral.name ?: 
        advertisementData[CBAdvertisementDataLocalNameKey] ?: @"Unknown";
    
    RDRLOG(@"Discovered device: %@ (UUID: %@, RSSI: %@)", deviceName, peripheral.identifier.UUIDString, RSSI);
    
    // 执行过滤
    if (_currentFilterPrefix && _currentFilterPrefix.length > 0) {
        BOOL matchFound = NO;
        
        switch (_currentFilterType) {
            case FilterTypeDeviceName: {
                // 设备名称过滤
                if (deviceName && [deviceName containsString:_currentFilterPrefix]) {
                    matchFound = YES;
                }
                break;
            }
                
            case FilterTypeMac: {
                // MAC地址过滤 (iOS中使用UUID字符串)
                NSString *addressString = peripheral.identifier.UUIDString;
                // 去除分隔符，与Android端保持一致
                addressString = [addressString stringByReplacingOccurrencesOfString:@"-" withString:@""];
                addressString = [addressString stringByReplacingOccurrencesOfString:@":" withString:@""];
                addressString = [addressString stringByReplacingOccurrencesOfString:@"." withString:@""];
                
                if ([addressString containsString:_currentFilterPrefix]) {
                    matchFound = YES;
                }
                break;
            }
                
            case FilterTypeUUID: {
                // 服务UUID过滤
                NSArray *serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey];
                if (serviceUUIDs) {
                    for (CBUUID *uuid in serviceUUIDs) {
                        if ([uuid.UUIDString containsString:_currentFilterPrefix]) {
                            matchFound = YES;
                            break;
                        }
                    }
                }
                break;
            }
        }
        
        // 如果不匹配过滤条件，跳过此设备
        if (!matchFound) {
            return;
        }
    }

    Productor productorType = ProductorEspBle; // 默认为 ESP

    // 根据设备名或广告数据分析设备类型
    if ([deviceName hasPrefix:@"TSBLU"] || [deviceName containsString:@"Radar"]) {
        productorType = ProductorRadarQL;
    }
    
    // 创建DeviceInfo对象
    DeviceInfo *deviceInfo = [[DeviceInfo alloc] initWithProductorName:productorType
                                                           deviceName:deviceName
                                                             deviceId:deviceName.length > 0 ? deviceName : peripheral.identifier.UUIDString
                                                           deviceType:@"Radar" // 设置为Radar类型
                                                              version:nil     // 版本暂不设置
                                                                  uid:nil     // UID暂不设置
                                                          macAddress:@"unknown" // iOS中无法获取MAC地址
                                                                 uuid:peripheral.identifier.UUIDString
                                                                 rssi:-255];
    
    // 通知扫描回调
    if (_scanCallback) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_scanCallback(deviceInfo);
        });
    }
    
    // 缓存设备引用，以便后续连接
    if (!_deviceCache) {
        _deviceCache = [NSMutableDictionary dictionary];
    }
    [_deviceCache setObject:peripheral forKey:peripheral.identifier.UUIDString];
    
    // 如果正在尝试连接此设备，停止扫描并开始连接
    if (_isConnecting && _currentDeviceUUID && 
        [peripheral.identifier.UUIDString isEqualToString:_currentDeviceUUID]) {
        RDRLOG(@"Found target device, stopping scan and connecting");
        [self stopScan];
        [self connectPeripheral:peripheral];
    }
}

#pragma mark - connectDevice Methods
// 内部使用的连接方法，使用CBPeripheral对象
- (void)connectPeripheral:(CBPeripheral *)peripheral {
    if (!peripheral) {
        RDRLOG(@"Cannot connect: peripheral is nil");
        return;
    }
    
    RDRLOG(@"Connecting to peripheral: %@", peripheral.identifier.UUIDString);
    
    // 停止任何正在进行的扫描
    [self stopScan];
    
    // 设置为连接中状态
    _isConnecting = YES;
    _currentDeviceUUID = peripheral.identifier.UUIDString;
    
    // 设置连接超时
    _connectTimer = [NSTimer scheduledTimerWithTimeInterval:DEFAULT_CONNECT_TIMEOUT
                                                    target:self
                                                  selector:@selector(connectionTimedOut)
                                                  userInfo:nil
                                                   repeats:NO];
    
    // 使用BlufiClient连接设备 - 直接使用ESP SDK提供的方法
    if (_blufiClient) {
        [_blufiClient close]; // 确保关闭任何现有连接
    }
    
    _blufiClient = [[BlufiClient alloc] init];
    _blufiClient.blufiDelegate = self;
    _blufiClient.centralManagerDelete = self;
    _blufiClient.peripheralDelegate = (id<CBPeripheralDelegate>)self;
    
    // 设置包长度限制 - 使用ESP SDK的参数设置
    _blufiClient.postPackageLengthLimit = 128;
    
    // 开始连接 - 使用ESP SDK的连接方法
    [_blufiClient connect:peripheral.identifier.UUIDString];
}

// 对外公开的连接方法，使用DeviceInfo对象
- (void)connectDevice:(DeviceInfo *)device {
    if (!device || !device.uuid) {
        RDRLOG(@"Error: Invalid device information");
        if (_errorCallback) {
            _errorCallback(RadarBleErrorInvalidParameter, @"Invalid device information");
        }
        return;
    }
    
    RDRLOG(@"Connecting to device: %@", device.deviceName);

	// 检查当前连接的设备 UUID 是否匹配
    if (_blufiClient && _blufiClient.peripheralDelegate) {
        CBPeripheral *connectedPeripheral = (CBPeripheral *)_blufiClient.peripheralDelegate;
        if (connectedPeripheral && ![connectedPeripheral.identifier.UUIDString isEqualToString:device.uuid]) {
            RDRLOG(@"Currently connected device UUID (%@) does not match target UUID (%@). Disconnecting.", connectedPeripheral.identifier.UUIDString, device.uuid);
            [self disconnect]; // 断开当前连接
        }
    }
    
    // 保存当前设备信息
    _currentDevice = device;
    _currentDeviceUUID = device.uuid;

	    // 初始化连接回调
    _connectCallback = ^(BOOL success) {
        if (success) {
            RDRLOG(@"Device connected successfully");
            // 连接成功后的逻辑
        } else {
            RDRLOG(@"Failed to connect to device");
            // 连接失败后的逻辑
        }
    };
    
    // 尝试从缓存中获取外设对象
    CBPeripheral *peripheral = [_deviceCache objectForKey:device.uuid];
    
    if (peripheral) {
        // 使用缓存的外设对象连接
        [self connectPeripheral:peripheral];
    } else {
        // 如果缓存中没有找到，可能需要先扫描
        RDRLOG(@"Device not in cache, attempting to scan");
        _isConnecting = YES;
        
        // 使用系统API尝试检索外设
        NSArray *knownPeripherals = [_centralManager retrievePeripheralsWithIdentifiers:@[[[NSUUID alloc] initWithUUIDString:device.uuid]]];
        
        if (knownPeripherals.count > 0) {
            // 设备已知，直接连接
            [self connectPeripheral:knownPeripherals[0]];
        } else {
            // 设备未知，需要扫描
            _currentDeviceUUID = device.uuid; // 设置当前期望连接的设备UUID
            [self startScanWithTimeout:DEFAULT_SCAN_TIMEOUT filterPrefix:nil filterType:FilterTypeUUID];
        }
    }
}

// 连接超时处理
- (void)connectionTimedOut {
    RDRLOG(@"Connection timed out");
    
    if (_isConnecting) {
        [self disconnect];
        
        if (_errorCallback) {
            _errorCallback(RadarBleErrorConnectionTimeout, @"Connection to device timed out");
        }
    }
}


/**
 * 断开连接
 */
- (void)disconnect {
    RDRLOG(@"Disconnecting");
    
    // 取消定时器
    [_connectTimer invalidate];
    _connectTimer = nil;
    
    // 断开设备连接
    _isConnecting = NO;
    _currentDeviceUUID = nil;
    
    if (_blufiClient) {
        [_blufiClient close];
        _blufiClient = nil;
    }
}

/**
 * 检查设备是否已连接
 */
- (BOOL)isConnected {
    if (_blufiClient && _blufiClient.peripheralDelegate) {
    // 假设通过 peripheralDelegate 是否为空来判断连接状态
    RDRLOG(@"BlufiClient is connected");
	return YES; 
} else {
    RDRLOG(@"BlufiClient is not connected");
	return NO; 
}
}


/**
 * 获取当前连接的设备
 */
- (nullable DeviceInfo *)connectedDevice {
    return _currentDevice;
}

#pragma mark - 配置方法

/**
 * 配置设备WiFi
 * @param device 设备信息，必须包含有效的id
 * @param wifiSsid WiFi SSID
 * @param wifiPassword WiFi密码
 * @param completion 配置结果回调
 */
- (void)configureWiFi:(DeviceInfo *)device
             wifiSsid:(NSString *)wifiSsid
         wifiPassword:(nullable NSString *)wifiPassword
           completion:(RadarConfigCallback)completion {
    RDRLOG(@"Starting WiFi configuration for: %@", device.deviceName);
    
    // 保存WiFi配置
    _wifiSsid = wifiSsid;
    _wifiPassword = wifiPassword;
    
    // 调用配置逻辑
    [self startWifiConfiguration];
}

/**
 * 配置设备服务器
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
             completion:(RadarConfigCallback)completion {
    RDRLOG(@"Starting server configuration for: %@", device.deviceName);
    
    // 保存服务器配置
    _serverAddress = serverAddress;
    _serverPort = serverPort;
    _serverProtocol = serverProtocol;
    
    // 调用配置逻辑
    [self startServerConfiguration];
}

/**
 * 配置设备WiFi和服务器
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
             completion:(RadarConfigCallback)completion {
    RDRLOG(@"Starting device configuration for: %@", device.deviceName);
    
    // 保存回调和配置
    _configCallback = completion;
    _currentDevice = device;
    _currentDeviceUUID = device.uuid;
    _serverAddress = serverAddress;
    _serverPort = serverPort;
    _serverProtocol = serverProtocol;
    _wifiSsid = wifiSsid;
    _wifiPassword = wifiPassword;
    
    // 设置配置超时
    [_configTimer invalidate];
    _configTimer = [NSTimer scheduledTimerWithTimeInterval:DEFAULT_CONFIG_TIMEOUT
                                                   target:self
                                                 selector:@selector(configurationTimedOut)
                                                 userInfo:nil
                                                  repeats:NO];
    
    // 确定配置流程
    if (wifiSsid && serverAddress) {
        // 同时配置WiFi和服务器：先配置WiFi，再配置服务器
        RDRLOG(@"Both WiFi and server config provided - configuring WiFi first");
        [self startWifiConfiguration];
    } else if (wifiSsid) {
        // 仅配置WiFi
        RDRLOG(@"WiFi configuration only");
        [self startWifiConfiguration];
    } else if (serverAddress) {
        // 仅配置服务器
        RDRLOG(@"Server configuration only");
        [self startServerConfiguration];
    }
}

/**
 * 开始WiFi配置流程
 * 先连接设备，然后发送配置参数
 */
- (void)startWifiConfiguration {
    _isConfiguring = YES;
    
    // 检查是否已连接
    if (_isConnecting && _blufiClient) {
        // 已连接，直接协商安全并发送配置
        [_blufiClient negotiateSecurity];
    } else {
        // 未连接，先连接设备
        [self connectDevice:_currentDevice];
        
        // 设置连接回调
        __weak typeof(self) weakSelf = self;
        _connectCallback = ^(BOOL success) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (success) {
                // 连接成功，开始安全协商
                [strongSelf->_blufiClient negotiateSecurity];
            } else {
                // 连接失败
                [strongSelf configurationDidFailWithError:@"Failed to connect to device"];
            }
        };
    }
}

/**
 * 开始服务器配置流程
 * 先连接设备，然后发送服务器配置命令
 */
- (void)startServerConfiguration {
    _isConfiguring = YES;
    _configServerSendStage = 0;
    _configRetryCount = 0;
    
    // 初始化服务器配置结果字典
    _configServerResult = [NSMutableDictionary dictionary];
    [_configServerResult setObject:_currentDevice.deviceId forKey:@"deviceId"];
    [_configServerResult setObject:_currentDevice.uuid ?: @"" forKey:@"uuid"];
    
    // 检查是否已连接
    if (_isConnecting && _blufiClient) {
        // 已连接，直接协商安全
        [_blufiClient negotiateSecurity];
    } else {
        // 未连接，先连接设备
        [self connectDevice:_currentDevice];
        
        // 设置连接回调
        __weak typeof(self) weakSelf = self;
        _connectCallback = ^(BOOL success) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (success) {
                // 连接成功，开始安全协商
                [strongSelf->_blufiClient negotiateSecurity];
            } else {
                // 连接失败
                [strongSelf configurationDidFailWithError:@"Failed to connect to device"];
            }
        };
    }
}

/**
 * 发送WiFi配置参数
 * 在安全协商成功后调用
 */
- (void)sendWifiConfiguration {
    if (!_wifiSsid) {
        [self configurationDidFailWithError:@"WiFi configuration is missing"];
        return;
    }
    
    RDRLOG(@"Sending WiFi configuration: SSID=%@", _wifiSsid);
    
    // 创建BlufiConfigureParams对象
    BlufiConfigureParams *params = [[BlufiConfigureParams alloc] init];
    params.opMode = OpModeSta;  // Station模式
    params.staSsid = _wifiSsid;
    params.staPassword = _wifiPassword ?: @"";
    
    // 发送配置
    [_blufiClient configure:params];
}

/**
 * 发送服务器地址命令
 * 这是服务器配置的第一步
 */
- (void)sendServerAddressCommand {
    if (!_serverAddress) {
        [self configurationDidFailWithError:@"Server configuration is missing"];
        return;
    }
    
    _configServerSendStage = 1;
    
    RDRLOG(@"Sending server address command: %@", _serverAddress);
    
    // 格式化并发送命令
    NSString *serverCmd = [NSString stringWithFormat:@"1:%@", _serverAddress];
    NSData *data = [serverCmd dataUsingEncoding:NSUTF8StringEncoding];
    
    if (data) {
        [_blufiClient postCustomData:data];
    } else {
        [self configurationDidFailWithError:@"Failed to encode server address command"];
    }
}

/**
 * 发送服务器端口命令
 * 这是服务器配置的第二步
 */
- (void)sendServerPortCommand {
    if (!_serverAddress) {
        [self configurationDidFailWithError:@"Server configuration is missing"];
        return;
    }
    
    _configServerSendStage = 2;
    
    RDRLOG(@"Sending server port command: %d", (int)_serverPort);
    
    // 格式化并发送命令
    NSString *portCmd = [NSString stringWithFormat:@"2:%d", (int)_serverPort];
    NSData *data = [portCmd dataUsingEncoding:NSUTF8StringEncoding];
    
    if (data) {
        [_blufiClient postCustomData:data];
    } else {
        [self configurationDidFailWithError:@"Failed to encode server port command"];
    }
}

/**
 * 发送额外命令
 * 这是服务器配置的第三步
 */
- (void)sendExtraCommands {
    _configServerSendStage = 3;
    
    RDRLOG(@"Sending extra configuration command");
    
    // 发送命令 3:0
    NSData *data = [@"3:0" dataUsingEncoding:NSUTF8StringEncoding];
    
    if (data) {
        [_blufiClient postCustomData:data];
    } else {
        // 如果失败，直接进入下一步
        [self sendRestartCommand];
    }
}

/**
 * 发送重启命令
 * 这是服务器配置的最后一步
 */
- (void)sendRestartCommand {
    _configServerSendStage = 4;
    
    RDRLOG(@"Sending device restart command");
    
    // 发送重启命令
    NSData *data = [@"8:" dataUsingEncoding:NSUTF8StringEncoding];
    
    if (data) {
        [_blufiClient postCustomData:data];
        
        // 设置超时等待，如果5秒内没收到响应，认为已重启
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self->_configServerSendStage == 4 && self->_isConfiguring) {
                RDRLOG(@"No restart confirmation received, assuming device restarted");
                
                // 标记设备已重启
                [self->_configServerResult setObject:@"true" forKey:@"deviceRestarted"];
                
                // 检查整体配置是否成功
                BOOL addressSuccess = [[self->_configServerResult objectForKey:@"serverAddressSuccess"] boolValue];
                BOOL portSuccess = [[self->_configServerResult objectForKey:@"serverPortSuccess"] boolValue];
                BOOL overallSuccess = addressSuccess || portSuccess;
                
                // 完成配置
                [self completeServerConfigWithSuccess:overallSuccess];
            }
        });
    } else {
        [self configurationDidFailWithError:@"Failed to encode restart command"];
    }
}

/**
 * 完成服务器配置过程
 * @param success 配置是否成功
 */
- (void)completeServerConfigWithSuccess:(BOOL)success {
    RDRLOG(@"Completing server configuration: success=%d", success);
    
    // 取消超时计时器
    [_configTimer invalidate];
    _configTimer = nil;
    
    // 设置成功标志和完成时间戳
    [_configServerResult setObject:@(success) forKey:@"success"];
    [_configServerResult setObject:@((NSInteger)[[NSDate date] timeIntervalSince1970]) forKey:@"completedAt"];
    
    // 如果WiFi也配置了，添加到结果中
    if (_wifiSsid) {
        [_configServerResult setObject:@"true" forKey:@"wifiConfigured"];
    }
    
    // 调用回调
    if (_configCallback) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_configCallback(success, self->_configServerResult);
            self->_configCallback = nil;
        });
    }
    
    // 清理状态
    _isConfiguring = NO;
    _configServerSendStage = 0;
    _configRetryCount = 0;
    _configServerResult = nil;
    
    // 断开连接
   // [self disconnect];
}

/**
 * 配置失败处理
 * @param error 错误信息
 */
- (void)configurationDidFailWithError:(NSString *)error {
    RDRLOG(@"Configuration failed: %@", error);
    
    // 取消超时计时器
    [_configTimer invalidate];
    _configTimer = nil;
    
    // 创建结果字典
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    [result setObject:@(NO) forKey:@"success"];
    [result setObject:error forKey:@"error"];
    [result setObject:@((NSInteger)[[NSDate date] timeIntervalSince1970]) forKey:@"completedAt"];
    
    // 调用回调
    if (_configCallback) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_configCallback(NO, result);
            self->_configCallback = nil;
        });
    }
    
    // 清理状态
    _isConfiguring = NO;
    _configServerSendStage = 0;
    
    // 断开连接
    [self disconnect];
}

/**
 * 配置超时处理
 */
- (void)configurationTimedOut {
    RDRLOG(@"Configuration operation timed out");
    [self configurationDidFailWithError:@"Configuration timed out"];
}


#pragma mark - 查询设备状态

/**
 * 查询设备状态
 * @param device 设备信息
 * @param completion 查询结果回调
 */
- (void)queryDeviceStatus:(DeviceInfo *)device completion:(RadarStatusCallback)completion {
    RDRLOG(@"Start querying device status for: %@, UUID: %@", device.deviceName, device.uuid);
    
    // 保存当前设备信息和回调
    _currentDevice = device;
    
    // 开始查询流程：先查 UID
    [self sendUIDQuery];
}

/**
 * 发送 UID 查询命令
 */
- (void)sendUIDQuery {
    RDRLOG(@"Sending UID query command");
    NSData *uidCmd = [@"12:" dataUsingEncoding:NSUTF8StringEncoding];
    [_blufiClient postCustomData:uidCmd];
}

/**
 * 发送 MAC 地址查询命令
 */
- (void)sendMACQuery {
    RDRLOG(@"Sending MAC address query command");
    NSData *macCmd = [@"65:" dataUsingEncoding:NSUTF8StringEncoding];
    [_blufiClient postCustomData:macCmd];
}

/**
 * 发送 WiFi 状态查询命令
 */
- (void)sendWiFiStatusQuery {
    RDRLOG(@"Requesting device WiFi status");
    NSData *wifiCmd = [@"62:" dataUsingEncoding:NSUTF8StringEncoding];
    [_blufiClient postCustomData:wifiCmd];
}


/**
 * 处理 WiFi 状态查询结果
 */
- (void)handleWiFiStatusResponse:(NSString *)wifiMode connected:(BOOL)connected ssid:(NSString *)ssid {
    RDRLOG(@"Received WiFi status: mode=%@, connected=%d, SSID=%@", wifiMode, connected, ssid);
    _currentDevice.wifiMode = wifiMode;
    _currentDevice.wifiConnected = connected;
    _currentDevice.wifiSsid = ssid;
    
    // 所有查询完成，回调结果
    if (_statusCallback) {
        dispatch_async(dispatch_get_main_queue(), ^{
            RDRLOG(@"Query completed, notifying main thread.");
            self->_statusCallback(self->_currentDevice, YES);
            self->_statusCallback = nil;
        });
    }
    
    // 断开连接
    //[self disconnect];
	RDRLOG(@"Query completed, keeping connection active until timeout.");
}

/**
 * 所有命令响应统一处理
 */
- (void)blufi:(BlufiClient *)client didReceiveCustomData:(NSData *)data status:(BlufiStatusCode)status {
    if (status != StatusSuccess || !data) {
        RDRLOG(@"Failed to receive custom data: status=%d", status);

        // 如果是状态查询失败，直接回调失败
        if (_statusCallback) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_statusCallback(self->_currentDevice, NO);
            });
        }
        return;
    }

    // 将接收到的数据转换为字符串
    NSString *responseStr = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    RDRLOG(@"Received custom data: %@", responseStr);

    // 检查响应是否包含分隔符 ":"
    if (![responseStr containsString:@":"]) {
        RDRLOG(@"Invalid response format: missing separator ':'");
        return;
    }

    // 分割响应字符串
    NSArray *parts = [responseStr componentsSeparatedByString:@":"];
    NSInteger command = [[parts objectAtIndex:0] integerValue]; // 解析命令类型

    // 根据命令类型处理响应
    switch (command) {
        case 12: // UID 查询响应
            [self handleUIDResponse:responseStr];
            break;
        case 65: // MAC 地址查询响应
            [self handleMACResponse:responseStr];
            break;
        case 62: // WiFi 状态查询响应
            [self handleWiFiStatusResponse:parts];
            break;
        case 1:  // 服务器地址配置响应
            [self handleServerAddressResponse:parts];
            break;
        case 2:  // 服务器端口配置响应
            [self handleServerPortResponse:parts];
            break;
        case 3:  // 额外命令响应
            [self handleExtraCommandResponse:parts];
            break;
        case 8:  // 重启命令响应
            [self handleRestartCommandResponse:parts];
            break;
        default:
            RDRLOG(@"Unknown command response: %ld", (long)command);
            break;
    }
}

//每种命令类型定义独立的处理方法
// 处理 UID 查询响应
- (void)handleUIDResponse:(NSString *)responseStr {
    NSArray *parts = [responseStr componentsSeparatedByString:@":"];
    NSString *uid = [parts objectAtIndex:1];
    uid = [uid stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    _currentDevice.uid = uid; // 更新 DeviceInfo
    RDRLOG(@"Got UID: %@", uid);

    // 延迟发送 MAC 查询
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self sendMACQuery];
    });
}
// 处理 MAC 地址查询响应
- (void)handleMACResponse:(NSString *)responseStr {
    NSArray *parts = [responseStr componentsSeparatedByString:@":"];
    if (parts.count >= 3 && [@"0" isEqualToString:[parts objectAtIndex:1]]) {
        NSString *macAddress = [parts objectAtIndex:2];
        macAddress = [macAddress stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        _currentDevice.macAddress = macAddress; // 更新 DeviceInfo
        RDRLOG(@"Got MAC Address: %@", macAddress);

        // 延迟发送 WiFi 状态查询
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self sendWiFiStatusQuery];
        });
    } else {
        RDRLOG(@"Failed to get MAC address");
    }
}
// 处理 WiFi 状态查询响应
- (void)handleWiFiStatusResponse:(NSArray *)parts {
    if (parts.count >= 3) {
        NSString *mode = [parts objectAtIndex:1];
        BOOL connected = [@"0" isEqualToString:[parts objectAtIndex:2]];
        NSString *ssid = parts.count > 3 ? [parts objectAtIndex:3] : nil;

        // 映射 WiFi 模式
        NSString *wifiModeString = @"Unknown";
        if ([mode isEqualToString:@"1"]) {
            wifiModeString = @"STA";
        } else if ([mode isEqualToString:@"2"]) {
            wifiModeString = @"AP";
        } else if ([mode isEqualToString:@"3"]) {
            wifiModeString = @"APSTA";
        }

        // 更新 DeviceInfo
        _currentDevice.wifiMode = wifiModeString;
        _currentDevice.wifiConnected = connected;
        _currentDevice.wifiSsid = ssid;

        RDRLOG(@"Got WiFi status: mode=%@, connected=%d, SSID=%@", wifiModeString, connected, ssid);

        // 所有查询完成，回调结果
        if (_statusCallback) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_statusCallback(self->_currentDevice, YES);
                self->_statusCallback = nil;
            });
        }

        // 断开连接
        [self disconnect];
    } else {
        RDRLOG(@"Failed to get WiFi status");
    }
}

// 处理服务器地址和端口配置响应
- (void)handleServerAddressResponse:(NSArray *)parts {
    BOOL commandSuccess = [[parts objectAtIndex:1] isEqualToString:@"0"];
    RDRLOG(@"Server address configuration %@", commandSuccess ? @"successful" : @"failed");
    [_configServerResult setObject:@(commandSuccess) forKey:@"serverAddressSuccess"];

    // 继续发送端口命令
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(DEFAULT_COMMAND_DELAY * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self sendServerPortCommand];
    });
}

- (void)handleServerPortResponse:(NSArray *)parts {
    BOOL commandSuccess = [[parts objectAtIndex:1] isEqualToString:@"0"];
    RDRLOG(@"Server port configuration %@", commandSuccess ? @"successful" : @"failed");
    [_configServerResult setObject:@(commandSuccess) forKey:@"serverPortSuccess"];

    // 继续发送额外命令
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(DEFAULT_COMMAND_DELAY * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self sendExtraCommands];
    });
}

- (void)handleExtraCommandResponse:(NSArray *)parts {
    RDRLOG(@"Extra command response: %@", [parts objectAtIndex:1]);

    // 继续发送重启命令
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(DEFAULT_COMMAND_DELAY * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self sendRestartCommand];
    });
}

- (void)handleRestartCommandResponse:(NSArray *)parts {
    RDRLOG(@"Device restart command received");
    [_configServerResult setObject:@"true" forKey:@"deviceRestarted"];

    // 检查整体配置是否成功
    BOOL addressSuccess = [[_configServerResult objectForKey:@"serverAddressSuccess"] boolValue];
    BOOL portSuccess = [[_configServerResult objectForKey:@"serverPortSuccess"] boolValue];
    BOOL overallSuccess = addressSuccess || portSuccess;

    // 完成配置
    [self completeServerConfigWithSuccess:overallSuccess];
}

#pragma mark - BlufiDelegate 配置相关回调

/**
 * 安全协商结果回调
 */
- (void)blufi:(BlufiClient *)client didNegotiateSecurity:(BlufiStatusCode)status {
    RDRLOG(@"Security negotiation result: %d", status);
    
    if (status != StatusSuccess) {
        // 安全协商失败处理
        _errorCount++;
        
        // 最多重试3次
        if (_errorCount < 3 && _isConnecting) {
            RDRLOG(@"Security negotiation failed, retrying (%ld/3)", (long)_errorCount);
            // 短暂延迟后重试
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [client negotiateSecurity];
            });
            return;
        }
        
        // 状态查询失败处理
        if (_statusCallback ) {
            RDRLOG(@"Query failed: Security negotiation failed: %d", status);
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_statusCallback(self->_currentDevice, NO);
            });
            return;
        }
        
        // 配置功能失败处理
        if (_isConfiguring) {
            [self configurationDidFailWithError:@"Security negotiation failed"];
            return;
        }
        
        // 通知错误回调
        if (_errorCallback) {
            _errorCallback(RadarBleErrorSecurityNegotiation, [NSString stringWithFormat:@"Security negotiation failed: %d", status]);
        }
        
        return;
    }
    
    // 安全协商成功，重置错误计数
    _errorCount = 0;
    
    // 状态查询处理 - 先发送 UID 查询命令
    if (_statusCallback ) {
        RDRLOG(@"Security negotiation successful, starting query sequence");
        // 首先查询 UID
        [self sendUIDQuery];
        return;
    }
    
    // 配置功能处理
    if (_isConfiguring) {
        if (_wifiSsid && _configServerSendStage == 0) {
            // WiFi配置
            [self sendWifiConfiguration];
        } else if (_serverAddress) {
            // 服务器配置
            [self sendServerAddressCommand];
        }
    }
    
    // 连接回调处理
    if (_connectCallback) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_connectCallback(YES);
            self->_connectCallback = nil;
        });
    }
}

/**
 * 设备状态响应回调 Esp自定义的状态查询响应，wifi状态查询
 */
- (void)blufi:(BlufiClient *)client didReceiveDeviceStatusResponse:(nullable BlufiStatusResponse *)response status:(BlufiStatusCode)status {
    RDRLOG(@"Received device status response: %d", status);
    
    // 状态查询处理
    if (_statusCallback ) {
       
        if (status == StatusSuccess && response) {
            // 记录设备信息
            // 转换为可读的模式名称
            switch (response.opMode) {
                case OpModeNull:
                    [_statusMap setObject:@"NULL" forKey:@"wifiOpMode"];
                    break;
                case OpModeSta:
                    [_statusMap setObject:@"STA" forKey:@"wifiOpMode"];
                    break;
                case OpModeSoftAP:
                    [_statusMap setObject:@"SOFTAP" forKey:@"wifiOpMode"];
                    break;
                case OpModeStaSoftAP:
                    [_statusMap setObject:@"STASOFTAP" forKey:@"wifiOpMode"];
                    break;
                default:
                    [_statusMap setObject:[NSString stringWithFormat:@"UNKNOWN(%d)", response.opMode] forKey:@"wifiOpMode"];
                    break;
            }
            
            // STA模式信息
            if (response.opMode == OpModeSta || response.opMode == OpModeStaSoftAP) {
                [_statusMap setObject:[NSString stringWithFormat:@"%@", [response isStaConnectWiFi] ? @"true" : @"false"] forKey:@"staConnected"];
                
                if (response.staSsid) {
                    [_statusMap setObject:response.staSsid forKey:@"staSSID"];
                }
                
                if (response.staBssid) {
                    [_statusMap setObject:response.staBssid forKey:@"staBSSID"];
                }
            }
            
            // AP模式信息
            if (response.opMode == OpModeSoftAP || response.opMode == OpModeStaSoftAP) {
                if (response.softApSsid) {
                    [_statusMap setObject:response.softApSsid forKey:@"apSSID"];
                }
                
                [_statusMap setObject:[NSString stringWithFormat:@"%d", (int)response.softApSecurity] forKey:@"apSecurity"];
                [_statusMap setObject:[NSString stringWithFormat:@"%d", (int)response.softApChannel] forKey:@"apChannel"];
                [_statusMap setObject:[NSString stringWithFormat:@"%d", (int)response.softApConnectionCount] forKey:@"apConnCount"];
            }
            
            // 获取设备UID
            NSData *uidCmd = [@"12:" dataUsingEncoding:NSUTF8StringEncoding];
            [client postCustomData:uidCmd];
            
        } else {
            // 状态获取失败
            [_statusMap setObject:@"Failed to get status" forKey:@"wifiError"];
            
            // 尝试获取UID
            NSData *uidCmd = [@"12:" dataUsingEncoding:NSUTF8StringEncoding];
            [client postCustomData:uidCmd];
            
            // 尝试获取WiFi MAC地址
            NSData *macCmd = [@"65:" dataUsingEncoding:NSUTF8StringEncoding];
            [client postCustomData:macCmd];
        }
    }
}


/**
 * 配置参数结果回调
 */
- (void)blufi:(BlufiClient *)client didPostConfigureParams:(BlufiStatusCode)status {
    RDRLOG(@"Configure params result: %d", status);
    
    if (_isConfiguring && _wifiSsid && !_configServerSendStage) {
        BOOL success = (status == StatusSuccess);
        
        // 创建结果字典
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        [result setObject:@(success) forKey:@"success"];
        [result setObject:@(success) forKey:@"wifiConfigured"];
        
        if (!success) {
            [result setObject:@"WiFi configuration failed" forKey:@"error"];
        }
        
        [result setObject:@((NSInteger)[[NSDate date] timeIntervalSince1970]) forKey:@"completedAt"];
        
        // 检查是否需要继续配置服务器
        if (success && _serverAddress) {
            RDRLOG(@"WiFi configuration successful, proceeding to server configuration");
            
            // 延迟一段时间后进行服务器配置
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (self->_isConfiguring) {
                    [self startServerConfiguration];
                }
            });
            
            // 保存WiFi成功结果，等服务器配置完成后一起返回
            _configServerResult = [NSMutableDictionary dictionaryWithDictionary:result];
        } else {
            // 没有服务器配置或WiFi配置失败，直接返回结果
            if (_configCallback) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self->_configCallback(success, result);
                    self->_configCallback = nil;
                });
            }
            
            // 取消超时计时器
            [_configTimer invalidate];
            _configTimer = nil;
            
            // 清理状态
            _isConfiguring = NO;
            
            // 断开连接
            [self disconnect];
        }
    }
}

/**
 * 发送自定义数据结果回调
 */
- (void)blufi:(BlufiClient *)client didPostCustomData:(NSData *)data status:(BlufiStatusCode)status {
    RDRLOG(@"Post custom data result: %d", status);
    
    if (status != StatusSuccess && _isConfiguring && _configServerSendStage > 0) {
        // 发送失败，尝试重试
        _configRetryCount++;
        
        if (_configRetryCount < 3) {
            RDRLOG(@"Retrying command, attempt %ld", (long)_configRetryCount);
            
            // 延迟后重试
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                switch (self->_configServerSendStage) {
                    case 1:
                        [self sendServerAddressCommand];
                        break;
                    case 2:
                        [self sendServerPortCommand];
                        break;
                    case 3:
                        [self sendExtraCommands];
                        break;
                    case 4:
                        [self sendRestartCommand];
                        break;
                }
            });
        } else {
            // 重试次数过多，报告失败
            [self configurationDidFailWithError:@"Failed to send command after multiple attempts"];
        }
    }
}

/**
 * 错误回调
 */
- (void)blufi:(BlufiClient *)client didReceiveError:(NSInteger)errCode {
    RDRLOG(@"Received error: %ld", (long)errCode);
    
    _errorCount++;
    
    // 状态查询处理
    if (_statusCallback) {
        RDRLOG(@"Query failed: Communication error: %ld", (long)errCode);
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_statusCallback(self->_currentDevice, NO);
        });
        return;
    }
    
    // 配置处理
    if (_isConfiguring) {
        NSString *errorMessage = [NSString stringWithFormat:@"Communication error: %ld", (long)errCode];
        [self configurationDidFailWithError:errorMessage];
        return;
    }
    
    // 通用错误处理
    if (_errorCallback) {
        RadarBleErrorType errorType;
        NSString *errorMessage;
        
        switch (errCode) {
            case 100:
            case 101:
                errorType = RadarBleErrorConnectionTimeout;
                errorMessage = @"Connection timeout or lost";
                break;
                
            case 102:
            case 103:
                errorType = RadarBleErrorSecurityNegotiation;
                errorMessage = @"Security negotiation failed";
                break;
                
            case 104:
            case 105:
                errorType = RadarBleErrorDataTransmission;
                errorMessage = @"Data transmission error";
                break;
                
            default:
                errorType = RadarBleErrorUnknown;
                errorMessage = [NSString stringWithFormat:@"Unknown error: %ld", (long)errCode];
                break;
        }
        
        _errorCallback(errorType, errorMessage);
    }
}

@end
