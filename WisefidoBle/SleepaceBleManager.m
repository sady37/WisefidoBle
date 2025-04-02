//
//  SleepaceBleManager.m
//

#import "SleepaceBleManager.h"
// 需要确保这些SDK相关的头文件被正确引入
#import <BluetoothManager/BluetoothManager.h>  // 包含了SLPBLEManager等
#import <BLEWifiConfig/BLEWifiConfig.h>        // WiFi配置相关



// Define log macro for debugging
#define SLPLOG(fmt, ...) NSLog((@"[SleepaceBleManager] " fmt), ##__VA_ARGS__)

// Define timeout constants
#define DEFAULT_SCAN_TIMEOUT 15.0
#define DEFAULT_CONFIG_TIMEOUT 30.0
#define DEFAULT_CONNECT_TIMEOUT 10.0
#define DEFAULT_COMMAND_DELAY 1.0 // 延迟执行命令的时间
#define DEFAULT_QUERY_TIMEOUT 20.0


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
@property (nonatomic, strong) NSMutableDictionary<NSString *, CBPeripheral *> *peripheralCache;
@property (nonatomic, strong) NSMutableDictionary *rssiNotifiedDevices; // 记录已获取RSSI的设备

// State flags
@property (nonatomic, assign) BOOL isScanning;
@property (nonatomic, assign) BOOL isConnected;
@property (nonatomic, assign) BOOL isConfiguring;

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
- (NSString *)deviceTypeNameForCode:(SLPDeviceTypes)typeCode;

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


        // Initialize status variables
        _isScanning = NO;
		_isConnected = NO;
        _isConfiguring = NO;
        if (!_peripheralCache) {
            _peripheralCache = [NSMutableDictionary dictionary];
        }
        _peripheralCache = [NSMutableDictionary dictionary];

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


// SDK扫描方式
- (void)startSDKScanWithTimeout:(NSTimeInterval)timeout {
    // 首先确保停止任何可能正在进行的扫描
      [_bleManager stopAllPeripheralScan];
      _isScanning = NO;

      // 清空设备缓存，确保能接收所有设备
      @synchronized(_peripheralCache) {
          [_peripheralCache removeAllObjects];
      }
    _isScanning = YES;

    // 使用SDK方法进行扫描
    __weak typeof(self) weakSelf = self;
    NSTimeInterval scanTimeout = (timeout > 0) ? timeout : DEFAULT_SCAN_TIMEOUT;
    BOOL scanStarted = [_bleManager scanBluetoothWithTimeoutInterval:scanTimeout
                                                  completion:^(SLPBLEScanReturnCodes code, 
                                                              NSInteger handleID, 
                                                              SLPPeripheralInfo *peripheralInfo) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        
        // 处理扫描结果
        if (code == SLPBLEScanReturnCode_Normal && peripheralInfo && peripheralInfo.peripheral) {
            // 获取设备信息
            CBPeripheral *peripheral = peripheralInfo.peripheral;
            // 获取服务UUID（从服务或硬编码）
            NSString *deviceName = peripheralInfo.name ?: @"Unknown"; //BM87224601903
            NSString *deviceType = peripheral.name ?: @"Unknown";  //bm8701-2-ble
            NSString *uuid = peripheral.identifier.UUIDString; //iOS自定的
            
            //去重并保存peripheral到缓存中，使用UUID作为键
            @synchronized(strongSelf->_peripheralCache) {
                if (strongSelf->_peripheralCache[uuid]) { // 先检查是否已存在
                    return; // 已存在则直接返回
                }
                [strongSelf->_peripheralCache setObject:peripheral forKey:uuid]; // 不存在才存储
                SLPLOG(@"Cached peripheral for UUID: %@", uuid);
            }

            // ===== 在这里添加详细日志 =====
            //SLPLOG(@"device info:");
            //SLPLOG(@"Peripheral: %@", peripheral);
            //SLPLOG(@"Peripheral name: %@", peripheral.name ?: @"nil");  
            //SLPLOG(@"Peripheral ID: %@", peripheral.identifier);
            //SLPLOG(@"Peripheral state: %ld", (long)peripheral.state);
            //SLPLOG(@"PeripheralInfo name: %@", peripheralInfo.name ?: @"nil");

            // =========================

          
            // 创建设备信息对象
            DeviceInfo *deviceInfo = [[DeviceInfo alloc] initWithProductorName:ProductorSleepBoardHS
                                                       deviceName:deviceName
                                                         deviceId:deviceName
                                                       deviceType:deviceType  // 设置设备类型
                                                          version:nil        // 版本暂不设置
                                                              uid:nil        // UID暂不设置
                                                      macAddress:nil
                                                             uuid:uuid
                                                             rssi:-255];     // 初始RSSI值
          
            // 通知扫描回调
            if (strongSelf->_scanCallback) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    strongSelf->_scanCallback(deviceInfo);
                });
            }
        } 
        else if (code != SLPBLEScanReturnCode_Normal) {
            // 扫描结束或出错
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
            strongSelf->_isScanning = NO;
            [strongSelf invalidateScanTimer];
        }
    }];
    
    if (!scanStarted) {
        SLPLOG(@"Failed to start scan, Bluetooth may be disabled or permission denied");
        _isScanning = NO;
    } else {
        SLPLOG(@"Sleepace SDK scan started");
    }
}

- (void)dealloc {
    SLPLOG(@"Releasing SleepaceBleManager");
    
    // Remove notification observers
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    // Stop scanning and timers
    [self stopScan];
    [self invalidateConfigTimer];
}

// CBCentralManagerDelegate 检测蓝牙状态变化
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

#pragma mark - Public Methods - Scanning
- (void)startScan {
    SLPLOG(@"Starting scan (default timeout: %.1f seconds)", DEFAULT_SCAN_TIMEOUT);
    [self startScanWithTimeout:DEFAULT_SCAN_TIMEOUT filterPrefix:nil filterType:FilterTypeDeviceName];
}

- (void)startScanWithTimeout:(NSTimeInterval)timeout 
               filterPrefix:(nullable NSString *)filterPrefix
                 filterType:(FilterType)filterType { 
      // 确保扫描前总是重置状态
      _isScanning = NO;
      [self invalidateScanTimer];
        
    // 检查蓝牙是否打开 (使用SDK方法)
    if (![self.bleManager blueToothIsOpen]) {
        SLPLOG(@"Bluetooth not enabled according to SDK, requesting to enable");
        
        // 设置一个短暂的延迟，等待蓝牙初始化
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if ([self.bleManager blueToothIsOpen] || self.cbManager.state == CBManagerStatePoweredOn) {
                SLPLOG(@"Bluetooth now available, starting delayed scan");
                [self startScanWithTimeout:timeout filterPrefix:filterPrefix filterType:filterType];
            } else {
                SLPLOG(@"Bluetooth still not available after delay");
                // 通知UI蓝牙未准备好
                if (self->_scanCallback) {
                    DeviceInfo *errorInfo = [[DeviceInfo alloc] initWithProductorName:ProductorSleepBoardHS
                                            deviceName:@"ERROR: Bluetooth not ready"
                                            deviceId:@"error"  // 注意这里的u@"error"是错误的，应该是@"error"
                                            deviceType:nil     // 设置设备类型
                                            version:nil        // 版本暂不设置
                                            uid:nil            // UID暂不设置
                                            macAddress:nil
                                            uuid:@"error-uuid" // uuid变量可能未定义，所以用一个固定值替代
                                            rssi:-255];       // 初始RSSI值


                    self->_scanCallback(errorInfo);
                }
            }
        });
        return;
    }

    // 更新UI状态
    _isScanning = YES;
    SLPLOG(@"Starting scan (timeout: %.1f seconds)", timeout);


    // 先调用SDK扫描方法
    [self startSDKScanWithTimeout:timeout];
 
}
- (void)stopScan {
    SLPLOG(@"stopScan called");
    
    // 使用try-catch包装SDK调用，防止崩溃
    @try {
        // 使用 SDK 方法停止扫描
        [_bleManager stopAllPeripheralScan];
    } @catch (NSException *exception) {
        SLPLOG(@"Exception while stopping SDK scan: %@", exception);
        // 即使发生异常也继续执行
    }
    
    // 无条件重置扫描状态
    _isScanning = NO;

    // 清理资源(添加一个小延时以确保安全)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SLPLOG(@"Scan stopped");
    });
}

//扫描回调设置
- (void)setScanCallback:(SleepaceScanCallback)callback {
    _scanCallback = callback;
    SLPLOG(@"Scan callback set");
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
- (DeviceInfo *)createDeviceInfoFromPeripheral:(CBPeripheral *)peripheral withName:(NSString *)name {
    NSString *deviceName = name ?: peripheral.name ?: @"Unknown";
    NSString *uuid = peripheral.identifier.UUIDString;
    NSString *deviceType = peripheral.name ?: @"Unknown";
    
    // 尝试获取设备类型
    @try {
        //SLPDeviceTypes deviceTypeCode = [_bleManager deviceTypeOfPeripheral:peripheral];
        NSString *sdkDeviceName = [_bleManager deviceNameOfPeripheral:peripheral];
        
        if (sdkDeviceName && sdkDeviceName.length > 0) {
            deviceType = sdkDeviceName;
        }
    } @catch (NSException *exception) {
        SLPLOG(@"Exception getting device type: %@", exception.reason);
    }
    
    // 创建设备信息对象
    DeviceInfo *deviceInfo = [[DeviceInfo alloc] initWithProductorName:ProductorSleepBoardHS
                                                   deviceName:deviceName
                                                     deviceId:uuid
                                                   deviceType:deviceType
                                                        version:nil
                                                          uid:nil
                                                  macAddress:nil
                                                         uuid:uuid
                                                         rssi:-255];
    
    return deviceInfo;
}

- (NSString *)deviceTypeNameForCode:(SLPDeviceTypes)typeCode {
    // 根据设备类型代码返回可读的设备类型名称
    switch (typeCode) {
        case 0x01: // 假设这是BM8701_2的值，需要根据实际情况调整
            return @"SleepBoard BM8701-2";
        case 0x35: // 假设这是EW202W的值，需要根据实际情况调整
            return @"EW202W";
        // 其他设备类型...
        default:
            return [NSString stringWithFormat:@"Unknown Type (%ld)", (long)typeCode];
    }
}
#pragma mark - Public Methods - connectDevice/Disconnect
/**
 * 准备使用设备 - 从缓存获取peripheral对象
 * 注意：此方法不实际建立BLE连接，而是获取peripheral对象供后续使用
 * @param device 设备信息
 */
- (void)connectDevice:(DeviceInfo *)device {
    if (!device || !device.uuid) {
        SLPLOG(@"Error: Invalid device or missing UUID");
        return;
    }
    
    SLPLOG(@"Connecting to device: %@, UUID: %@", device.deviceName, device.uuid);
    
    // 保存设备信息
    _currentDevice = device;
    _currentDeviceUUID = device.uuid;
    
    // 从缓存中查找peripheral
    CBPeripheral *peripheral = nil;
    @synchronized(_peripheralCache) {
        peripheral = [_peripheralCache objectForKey:device.uuid];
    }
    
    if (peripheral) {
        SLPLOG(@"Found peripheral for UUID: %@", device.uuid);
        _currentPeripheral = peripheral;
        _isConnected = YES; 
    } else {
        SLPLOG(@"Warning: No peripheral found for UUID: %@", device.uuid);
        _currentPeripheral = nil;
    }
}

- (void)disconnect {
    SLPLOG(@"Disconnecting device");
    
    // 先调用SDK的断开连接方法 
    if (_currentPeripheral) {
        // 使用SDK的断开连接方法
        SLPLOG(@"Calling SDK disconnect for peripheral: %@", _currentPeripheral.identifier.UUIDString);
        [[SLPBLEManager sharedBLEManager] disconnectPeripheral:_currentPeripheral 
                                                      timeout:2.0
                                                   completion:^(SLPBLEDisconnectReturnCodes code, NSInteger disconnectHandleID) {
            SLPLOG(@"SDK disconnect completed with code: %ld", (long)code);
        }];
    }
    
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
    _isConnected = NO;
    _isConfiguring = NO;
    
    SLPLOG(@"Device disconnected");
}

// 根据UUID获取peripheral对象
- (void)setCurrentDevice:(DeviceInfo *)device {
    if (!device || !device.uuid) {
        SLPLOG(@"Error: Invalid device information");
        return;
    }
    
    // 保存设备信息
    _currentDevice = device;
    _currentDeviceUUID = device.uuid;
    
    // 从缓存查找peripheral
    CBPeripheral *peripheral = nil;
    @synchronized(_peripheralCache) {
        peripheral = [_peripheralCache objectForKey:device.uuid];
    }
    
    if (peripheral) {
        SLPLOG(@"Found peripheral for device: %@, UUID: %@", device.deviceName, device.uuid);
        _currentPeripheral = peripheral;
    } else {
        SLPLOG(@"Warning: No peripheral found for device UUID: %@", device.uuid);
        _currentPeripheral = nil;
    }
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
