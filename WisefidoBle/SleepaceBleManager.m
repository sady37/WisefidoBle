//
//  SleepaceBleManager.m
//

#import "SleepaceBleManager.h"

// Define log macro for debugging
#define SLPLOG(fmt, ...) NSLog((@"[SleepaceBleManager] " fmt), ##__VA_ARGS__)

// Define timeout constants
#define DEFAULT_SCAN_TIMEOUT 10.0
#define DEFAULT_CONFIG_TIMEOUT 30.0
#define DEFAULT_CONNECT_TIMEOUT 5.0

@interface SleepaceBleManager ()

// SDK managers
@property (nonatomic, strong) SLPBLEManager *bleManager;
@property (nonatomic, strong) SLPBleWifiConfig *bleWifiConfig;
@property (nonatomic, strong) CBCentralManager *cbManager;

// Status and callbacks
@property (nonatomic, copy) SleepaceScanCallback scanCallback;
@property (nonatomic, copy) SleepaceConfigCallback configCallback;
@property (nonatomic, copy) SleepaceStatusCallback statusCallback;
@property (nonatomic, copy) void(^errorCallback)(SleepaceBleErrorType errorType, NSString *errorMessage);

// Device tracking
@property (nonatomic, strong) DeviceInfo *currentDevice;
@property (nonatomic, copy) NSString *currentDeviceUUID;
@property (nonatomic, strong) CBPeripheral *currentPeripheral;
@property (nonatomic, strong) NSMutableDictionary *deviceCache;

// State flags
@property (nonatomic, assign) BOOL isScanning;
@property (nonatomic, assign) BOOL isConnecting;
@property (nonatomic, assign) BOOL isConnected;
@property (nonatomic, assign) BOOL isConfiguring;
@property (nonatomic, assign) BOOL isDisconnecting;

// Timers
@property (nonatomic, strong) NSTimer *scanTimer;
@property (nonatomic, strong) NSTimer *configTimer;
@property (nonatomic, strong) NSTimer *connectTimer;


// Private methods
- (void)handleBluetoothStateChange:(NSNotification *)notification;
- (void)handleDeviceDisconnected:(NSNotification *)notification;
- (void)scanTimedOut;
- (void)connectionTimedOut;
- (void)configurationTimedOut:(NSTimer *)timer;

- (DeviceInfo *)createDeviceInfoFromPeripheral:(CBPeripheral *)peripheral withName:(NSString *)name;
- (NSString *)stringForTransferStatus:(SLPDataTransferStatus)status;

- (void)invalidateScanTimer;
- (void)invalidateConfigTimer;


@end

@implementation SleepaceBleManager

#pragma mark - Lifecycle

+ (instancetype)getInstance:(nullable id)delegate {
    static SleepaceBleManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        SLPLOG(@"Initializing SleepaceBleManager");
        
        // Initialize SDK managers
        _bleManager = [SLPBLEManager sharedBLEManager];
        _bleWifiConfig = [SLPBleWifiConfig sharedBleWifiConfig];
        
        // Initialize direct CoreBluetooth manager
        _cbManager = [[CBCentralManager alloc] initWithDelegate:self queue:nil];
        
        // Initialize status variables
        _isScanning = NO;
		_isConnecting = NO;
		_isConnected = NO;
		_isDisconnecting = NO;
        _deviceCache = [NSMutableDictionary dictionary];

		// 设备追踪初始化
		_currentPeripheral = nil;
		_currentDevice = nil;
		_currentDeviceUUID = nil;

        
        // Register for notifications
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        
        // Bluetooth state change notifications
        [center addObserver:self 
                   selector:@selector(handleBluetoothStateChange:) 
                       name:kNotificationNameBLEEnable 
                     object:nil];
        
        [center addObserver:self 
                   selector:@selector(handleBluetoothStateChange:) 
                       name:kNotificationNameBLEDisable 
                     object:nil];
        
        // Device disconnect notification
        [center addObserver:self 
                   selector:@selector(handleDeviceDisconnected:) 
                       name:kNotificationNameBLEDeviceDisconnect 
                     object:nil];
        
        SLPLOG(@"SleepaceBleManager initialization completed");
    }
    return self;
}

- (void)dealloc {
    SLPLOG(@"Releasing SleepaceBleManager");
    
    // Remove notification observers
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    // Stop scanning and timers
    [self stopScan];
    [self invalidateConfigTimer];
}

#pragma mark - Public Methods - Scanning
- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    NSString *stateString;
    switch (central.state) {
        case CBManagerStatePoweredOn:
            stateString = @"Powered ON";
            break;
        case CBManagerStatePoweredOff:
            stateString = @"Powered OFF";
            break;
        case CBManagerStateUnauthorized:
            stateString = @"Unauthorized";
            break;
        case CBManagerStateUnsupported:
            stateString = @"Unsupported";
            break;
        case CBManagerStateResetting:
            stateString = @"Resetting";
            break;
        case CBManagerStateUnknown:
            stateString = @"Unknown";
            break;
        default:
            stateString = @"Invalid State";
            break;
    }
    
    SLPLOG(@"CoreBluetooth state updated: %@", stateString);
}

- (void)centralManager:(CBCentralManager *)central
 didDiscoverPeripheral:(CBPeripheral *)peripheral
     advertisementData:(NSDictionary<NSString *,id> *)advertisementData
                  RSSI:(NSNumber *)RSSI {
    NSString *name = peripheral.name ?:
                    [advertisementData objectForKey:CBAdvertisementDataLocalNameKey] ?:
                    @"Unknown";
    
    SLPLOG(@"CoreBluetooth discovered device: %@ (UUID: %@, RSSI: %@)",
           name, peripheral.identifier.UUIDString, RSSI);
    
    // Create DeviceInfo object
    DeviceInfo *deviceInfo = [[DeviceInfo alloc]
                             initWithProductorName:ProductorSleepBoardHS
                                       deviceName:name
                                         deviceId:peripheral.identifier.UUIDString
                                      macAddress:nil
                                            uuid:peripheral.identifier.UUIDString
                                            rssi:[RSSI integerValue]];
    
    // Cache the peripheral for later use
    if (!_deviceCache) {
        _deviceCache = [NSMutableDictionary dictionary];
    }
    [_deviceCache setObject:peripheral forKey:peripheral.identifier.UUIDString];
    
    // Notify scan callback
    if (_scanCallback) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_scanCallback(deviceInfo);
        });
    }
}
- (void)setScanCallback:(SleepaceScanCallback)callback {
    _scanCallback = callback;
    SLPLOG(@"Scan callback set");
}

- (void)startScan {
    SLPLOG(@"Starting scan (default timeout: %.1f seconds)", DEFAULT_SCAN_TIMEOUT);
    [self startScanWithTimeout:DEFAULT_SCAN_TIMEOUT filterPrefix:nil filterType:FilterTypeDeviceName];
}

- (void)startScanWithTimeout:(NSTimeInterval)timeout 
               filterPrefix:(nullable NSString *)filterPrefix
                 filterType:(FilterType)filterType {
    if (_isScanning) {
        SLPLOG(@"Scan already in progress, ignoring request");
        return;
    }
    
    // Check Bluetooth status
    if (![self.bleManager blueToothIsOpen]) {
        SLPLOG(@"Bluetooth not enabled, cannot start scan");
        return;
    }
    
    // Clear device cache
    [_deviceCache removeAllObjects];
    
    // Set timeout
    NSTimeInterval scanTimeout = (timeout > 0) ? timeout : DEFAULT_SCAN_TIMEOUT;
    
    SLPLOG(@"Starting device scan, timeout: %.1f seconds, filterPrefix: %@, filterType: %ld", 
           scanTimeout, filterPrefix ?: @"None", (long)filterType);
    
    // Set scanning flag
    _isScanning = YES;
    
    // Set scan timeout timer
    self.scanTimer = [NSTimer scheduledTimerWithTimeInterval:scanTimeout
                                                      target:self
                                                    selector:@selector(scanTimedOut)
                                                    userInfo:nil
                                                     repeats:NO];
    
    // Call SDK to start scanning
    BOOL scanStarted = [_bleManager scanBluetoothWithTimeoutInterval:scanTimeout completion:^(SLPBLEScanReturnCodes code, NSInteger handleID, SLPPeripheralInfo *peripheralInfo) {
        if (code == SLPBLEScanReturnCode_Normal && peripheralInfo && peripheralInfo.peripheral) {
            // Get device information
            CBPeripheral *peripheral = peripheralInfo.peripheral;
            NSString *name = peripheralInfo.name ?: peripheral.name ?: @"Unknown";
            NSString *uuid = peripheral.identifier.UUIDString;
            
            // Apply filter if specified
            if (filterPrefix.length > 0) {
                BOOL shouldSkip = YES;
                
                switch (filterType) {
                    case FilterTypeDeviceName:
                        shouldSkip = ![name containsString:filterPrefix];
                        break;
                    case FilterTypeMac:
                        // iOS doesn't provide MAC address, so just check UUID
                        shouldSkip = ![uuid containsString:filterPrefix];
                        break;
                    case FilterTypeUUID:
                        shouldSkip = ![uuid containsString:filterPrefix];
                        break;
                }
                
                if (shouldSkip) {
                    return;
                }
            }
            
            SLPLOG(@"Device found: %@ (UUID: %@)", name, uuid);
            
            // Create device info object
            DeviceInfo *deviceInfo = [self createDeviceInfoFromPeripheral:peripheral withName:name];
            
            if (deviceInfo) {
                // Cache device to avoid duplicates
                NSString *deviceId = deviceInfo.deviceId;
                if (![self->_deviceCache objectForKey:deviceId]) {
                    [self->_deviceCache setObject:deviceInfo forKey:deviceId];
                    
                    // Notify app about new device
                    if (self.scanCallback) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            self.scanCallback(deviceInfo);
                        });
                    }
                }
            }
        } else if (code != SLPBLEScanReturnCode_Normal) {
            // Scan ended or error
            NSString *codeString = @"Unknown";
            switch (code) {
                case SLPBLEScanReturnCode_Disable:
                    codeString = @"Disabled";
                    break;
                case SLPBLEScanReturnCode_TimeOut:
                    codeString = @"Timeout";
                    break;
                default:
                    codeString = [NSString stringWithFormat:@"Code %ld", (long)code];
                    break;
            }
            
            SLPLOG(@"Scan ended, reason: %@", codeString);
            self.isScanning = NO;
            [self invalidateScanTimer];
        }
    }];
    
    if (!scanStarted) {
        SLPLOG(@"Failed to start scan, Bluetooth may be disabled or permission denied");
        _isScanning = NO;
        [self invalidateScanTimer];
    }
}

- (void)stopScan {
    if (!_isScanning) {
        return;
    }
    
    SLPLOG(@"Stopping CoreBluetooth scan");
    // Stop CoreBluetooth scanning
    [_cbManager stopScan];
    
    //SLPLOG(@"Stopping scan");
    // Stop SDK scanning
    //[_bleManager stopAllPeripheralScan];
    
    // Cancel timer
    [self invalidateScanTimer];
    
    _isScanning = NO;
}

#pragma mark - Public Methods - Configuration

- (void)configureDevice:(DeviceInfo *)device
              wifiSsid:(nullable NSString *)wifiSsid
          wifiPassword:(nullable NSString *)wifiPassword
         serverAddress:(nullable NSString *)serverAddress
            serverPort:(NSInteger)serverPort
        serverProtocol:(nullable NSString *)serverProtocol
            completion:(SleepaceConfigCallback)completion {
    
    // 参数验证
    if (!device || !device.deviceId) {
        SLPLOG(@"Error: Invalid device information");
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, @{@"error": @"Invalid device information"});
            });
        }
        return;
    }
    
    // 检查当前设备和peripheral
    if (!_currentPeripheral || ![_currentPeripheral.identifier.UUIDString isEqualToString:device.uuid]) {
        SLPLOG(@"Error: Device not connected or UUID mismatch");
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, @{@"error": @"Device not connected or has been changed"});
            });
        }
        return;
    }
    
    // 保存当前设备信息
    _currentDevice = device;
    _currentDeviceUUID = device.uuid;
    
    // 设置配置超时
    NSTimeInterval configTimeout = DEFAULT_CONFIG_TIMEOUT;
    SLPLOG(@"Configuration timeout set to: %.1f seconds", configTimeout);
    
    self.configTimer = [NSTimer scheduledTimerWithTimeInterval:configTimeout
                                                       target:self
                                                     selector:@selector(configurationTimedOut:)
                                                     userInfo:@{@"completion": completion ? [completion copy] : [NSNull null]}
                                                      repeats:NO];
    
    // 指定设备类型为 SLPDeviceType_BM8701_2
    SLPDeviceTypes deviceType = SLPDeviceType_BM8701_2;
    SLPLOG(@"Device type: %@", @(deviceType));
    
    // 标记配置状态
    _isConfiguring = YES;
    
    // 创建进度回调
    void (^wrappedCompletion)(SLPDataTransferStatus status, id data) = ^(SLPDataTransferStatus status, id data) {
        // 取消超时计时器
        [self invalidateConfigTimer];
        
        // 更新状态
        self->_isConfiguring = NO;
        
        // 执行状态判断
        BOOL success = (status == SLPDataTransferStatus_Succeed);
        
        // 构建结果字典
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        [result setObject:@(status) forKey:@"status"];
        [result setObject:@(success) forKey:@"success"];
        
        // 添加状态消息
        NSString *statusMessage = [self stringForTransferStatus:status];
        [result setObject:statusMessage forKey:@"statusMessage"];
        
        if (success) {
            // 处理成功情况
            if (serverAddress && serverPort > 0) {
                [result setObject:@"wifi_server" forKey:@"configType"];
                [result setObject:@"WiFi & Server configuration successful" forKey:@"message"];
            } else {
                [result setObject:@"wifi_only" forKey:@"configType"];
                [result setObject:@"WiFi configuration successful" forKey:@"message"];
            }
            
            // 保存设备信息更新
            device.wifiSsid = wifiSsid;
            device.wifiPassword = wifiPassword;
            device.serverAddress = serverAddress;
            device.serverPort = serverPort;
            device.serverProtocol = serverProtocol;
            device.lastUpdateTime = [[NSDate date] timeIntervalSince1970];
        } else {
            // 处理失败情况
            [result setObject:[NSString stringWithFormat:@"Configuration failed: %@", statusMessage] forKey:@"error"];
        }
        
        // 添加原始数据
        if (data) {
            [result setObject:data forKey:@"rawData"];
        }
        
        // 通知主界面
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(success, result);
            });
        }
    };
    
    // 开始配置
    if (wifiSsid) {
        SLPLOG(@"Starting WiFi configuration: SSID: %@", wifiSsid);
        
        if (serverAddress && serverPort > 0) {
            // 配置WiFi和服务器
            SLPLOG(@"Including server configuration: %@:%ld", serverAddress, (long)serverPort);
            [_bleWifiConfig configPeripheral:_currentPeripheral 
                                  deviceType:deviceType
                               serverAddress:serverAddress 
                                        port:serverPort
                                    wifiName:wifiSsid
                                    password:wifiPassword
                                  completion:wrappedCompletion];
        } else {
            // 仅配置WiFi
            SLPLOG(@"WiFi-only configuration");
            [_bleWifiConfig configPeripheral:_currentPeripheral
                                  deviceType:deviceType
                                    wifiName:wifiSsid
                                    password:wifiPassword
                                  completion:wrappedCompletion];
        }
    } else {
        // 无有效配置参数
        SLPLOG(@"Error: No configuration parameters provided");
        [self invalidateConfigTimer];
        _isConfiguring = NO;
        
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, @{@"error": @"No configuration parameters provided"});
            });
        }
    }
}

#pragma mark - Public Methods - Status Query
- (void)queryDeviceStatus:(DeviceInfo *)deviceInfo
               completion:(SleepaceStatusCallback)completion {
    // 检查 CBPeripheral 的 UUID 是否与 DeviceInfo 的 UUID 匹配
    if ([self.currentPeripheral.identifier.UUIDString isEqualToString:deviceInfo.uuid]) {
        // 打印日志
        SLPLOG(@"Querying device status: %@ (UUID: %@)", deviceInfo.deviceName, deviceInfo.uuid);
        // 创建 SLPDeviceTypes 对象，指定设备类型
		SLPDeviceTypes deviceType = SLPDeviceType_BM8701_2;
        // 查询设备 WiFi 连接状态
        [_bleWifiConfig checkDeviceConnectWiFiStatus:self.currentPeripheral
                                          deviceType:deviceType
                                          completion:^(BOOL succeed, id data) {
            BOOL success = NO;
            
            if (succeed && data && [data isKindOfClass:[SLPWiFiConnectStatus class]]) {
                SLPWiFiConnectStatus *wifiStatus = (SLPWiFiConnectStatus *)data;
                BOOL isConnected = wifiStatus.isConnected;
                
                SLPLOG(@"Device WiFi status query successful: %@, connection status: %@", 
                      deviceInfo.deviceName, isConnected ? @"Connected" : @"Disconnected");
                
                // 更新 DeviceInfo 的 WiFi 状态
                deviceInfo.wifiConnected = isConnected;
                deviceInfo.lastUpdateTime = [[NSDate date] timeIntervalSince1970];
                
                success = YES;
            } else {
                SLPLOG(@"Device WiFi status query failed: %@", deviceInfo.deviceName);
            }
            
            // 通知主界面查询完成
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(deviceInfo, success);
                });
            }
        }];
    } else {
        // UUID 不匹配，返回查询失败
        SLPLOG(@"Error: Peripheral UUID does not match DeviceInfo UUID");
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(deviceInfo, NO);
            });
        }
    }
}

#pragma mark - Private Methods - Timer Handlers

- (void)connectionTimedOut {
    SLPLOG(@"Connection timed out");
    
    if (_errorCallback) {
        _errorCallback(SleepaceBleErrorConnectionTimeout, @"Connection to device timed out");
    }
    
    [self disconnect];
}

- (void)configurationTimedOut:(NSTimer *)timer {
    SLPLOG(@"Configuration timed out");
    
    NSDictionary *userInfo = timer.userInfo;
    id completion = userInfo[@"completion"];
    
    if (completion && completion != [NSNull null]) {
        SleepaceConfigCallback callback = (SleepaceConfigCallback)completion;
        dispatch_async(dispatch_get_main_queue(), ^{
            callback(NO, @{
                @"status": @(SLPDataTransferStatus_TimeOut),
                @"success": @(NO),
                @"error": @"Configuration timed out"
            });
        });
    }
    
    [self invalidateConfigTimer];
}

- (void)scanTimedOut {
    SLPLOG(@"Scan timed out");
    [self stopScan];
}

- (void)invalidateScanTimer {
    if (_scanTimer && [_scanTimer isValid]) {
        [_scanTimer invalidate];
        _scanTimer = nil;
    }
}

- (void)invalidateConfigTimer {
    if (_configTimer && [_configTimer isValid]) {
        [_configTimer invalidate];
        _configTimer = nil;
    }
}

#pragma mark - Private Methods - Bluetooth State Change

- (void)handleBluetoothStateChange:(NSNotification *)notification {
    BOOL isEnabled = [notification.name isEqualToString:kNotificationNameBLEEnable];
    SLPLOG(@"Bluetooth state changed: %@", isEnabled ? @"Enabled" : @"Disabled");
    
    if (!isEnabled && _isScanning) {
        // 蓝牙被禁用，停止扫描
        [self stopScan];
    }
    
    // 通知错误回调
    if (!isEnabled && _errorCallback) {
        _errorCallback(SleepaceBleErrorBluetoothDisabled, @"Bluetooth has been disabled");
    }
}

- (void)handleDeviceDisconnected:(NSNotification *)notification {
	SLPLOG(@"Device disconnected notification received");
    
    // 如果配置定时器存在，表示正在配置中，需要取消并通知失败
    if (_configTimer && [_configTimer isValid]) {
        SLPLOG(@"Device disconnected during configuration");
        
        NSDictionary *userInfo = _configTimer.userInfo;
        id completion = userInfo[@"completion"];
        
        if (completion && completion != [NSNull null]) {
            SleepaceConfigCallback callback = (SleepaceConfigCallback)completion;
            dispatch_async(dispatch_get_main_queue(), ^{
                callback(NO, @{
                    @"status": @(SLPDataTransferStatus_ConnectionDisconnected),
                    @"success": @(NO),
                    @"error": @"Device disconnected during configuration"
                });
            });
        }
        
        [self invalidateConfigTimer];
    }
    
    // 清理当前设备信息
    _currentDevice = nil;
    _currentDeviceUUID = nil;
}

#pragma mark - Private Methods - Device Management

#pragma mark - Private Methods - Utility

// 将 SLPDataTransferStatus 转换为字符串
- (NSString *)stringForTransferStatus:(SLPDataTransferStatus)status {
    switch (status) {
        case SLPDataTransferStatus_Succeed:
            return @"Success";
        case SLPDataTransferStatus_ConnectionDisconnected:
            return @"Connection Disconnected";
        case SLPDataTransferStatus_TimeOut:
            return @"Timeout";
        case SLPDataTransferStatus_Failed:
            return @"Failed";
        case SLPDataTransferStatus_ConnectionDisabled:
            return @"Connection Disabled";
        case SLPDataTransferStatus_ParameterError:
            return @"Parameter Error";
        default:
            return [NSString stringWithFormat:@"Unknown Status: %d", (int)status];
    }
}

#pragma mark - Private Methods - Device Info Creation

// 创建设备信息对象
- (DeviceInfo *)createDeviceInfoFromPeripheral:(CBPeripheral *)peripheral withName:(NSString *)name {
    // 创建对象时必须指定 ProductorSleepBoardHS
    DeviceInfo *deviceInfo = [[DeviceInfo alloc] initWithProductorName:ProductorSleepBoardHS
                                                            deviceName:name
                                                              deviceId:peripheral.identifier.UUIDString
                                                           macAddress:nil
                                                                 uuid:peripheral.identifier.UUIDString
                                                                 rssi:-255]; // 初始 RSSI 值，后续会更新
    
    // 尝试从 peripheral 获取额外的 Sleepace 特有信息
    @try {
        deviceInfo.sleepaceDeviceType = [self.bleManager deviceTypeOfPeripheral:peripheral];
        deviceInfo.sleepaceVersionCode = [peripheral.name stringByReplacingOccurrencesOfString:@"SleepaceHS_" withString:@""];
    } @catch (NSException *exception) {
        SLPLOG(@"Failed to get Sleepace device-specific info: %@", exception.reason);
    }
    
    return deviceInfo;
}

#pragma mark - Public Methods - connectDevice/Disconnect
- (void)connectDevice:(DeviceInfo *)device {
    // 只记录设备信息，实际连接由SDK处理
    SLPLOG(@"Device selected for later operations: %@", device.deviceName);
    
    _currentDevice = device;
    _currentDeviceUUID = device.uuid;
    
    // 不尝试自己获取或管理CBPeripheral对象
    _currentPeripheral = nil;
}

- (void)disconnect {
    SLPLOG(@"Disconnecting device");
    
    // 清理资源
    _currentDevice = nil;
    _currentDeviceUUID = nil;
    _currentPeripheral = nil;
    
    // 取消所有定时器
    [_scanTimer invalidate];
    [_configTimer invalidate];
    [_connectTimer invalidate];
    
    _scanTimer = nil;
    _configTimer = nil;
    _connectTimer = nil;
    
    // 重置状态
    _isConnecting = NO;
    _isConnected = NO;
    _isConfiguring = NO;
    _isDisconnecting = NO;
    
    // 实际断开连接通常由SDK自己处理
}

// 查询WiFi状态 当前仅支持EW02
- (void)checkWiFiStatus:(CBPeripheral *)bleDevice 
             completion:(void(^)(BOOL success, id data))completion {
    if (!bleDevice) {
        SLPLOG(@"Error: Invalid peripheral");
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, nil);
            });
        }
        return;
    }
    
    // 指定设备类型为 SLPDeviceType_BM8701_2
	// 目前仅支持EW02设备SLPDeviceType_EW202W = 0x35, // EW202W
    SLPDeviceTypes deviceType = SLPDeviceType_BM8701_2;
    
    // 调用SDK方法查询WiFi状态
    [_bleWifiConfig checkDeviceConnectWiFiStatus:bleDevice
                                      deviceType:deviceType
                                      completion:^(BOOL succeed, id data) {
        SLPLOG(@"WiFi status check %@", succeed ? @"successful" : @"failed");
        
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(succeed, data);
            });
        }
    }];
}

@end
