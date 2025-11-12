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
#import "ConfigModels.h"
#import <os/log.h>

// 日志宏定义
#define RDRLOG(fmt, ...) NSLog((@"[RadarBleManager] " fmt), ##__VA_ARGS__)

// 默认超时常量
#define DEFAULT_SCAN_TIMEOUT 15.0
#define DEFAULT_CONFIG_TIMEOUT 30.0
#define DEFAULT_CONNECT_TIMEOUT 10.0
#define DEFAULT_COMMAND_DELAY 1.0 // 延迟执行命令的时间
#define DEFAULT_QUERY_TIMEOUT 20.0
#define DEFAULT_PREHEAT_TIMEOUT 8.0

typedef NS_ENUM(NSUInteger, RadarQueryCommand) {
    RadarQueryCommandUID = 0,
    RadarQueryCommandMAC,
    RadarQueryCommandWifiStatus,
    RadarQueryCommandOperateStatus
};

static NSTimeInterval const kRadarQueryCommandDelay = 0.4;
static NSTimeInterval const kRadarWifiScanTimeout = 8.0;

NSString * const RadarBlePreheatDidFinishNotification = @"RadarBlePreheatDidFinishNotification";
NSString * const RadarBlePreheatResultKeySuccess = @"success";
NSString * const RadarBlePreheatResultKeyUID = @"uid";

@interface RadarBleManager() <CBCentralManagerDelegate, BlufiDelegate>

// SDK managers
@property (nonatomic, strong) BlufiClient *blufiClient;
@property (nonatomic, strong) CBCentralManager *centralManager;

// // Status and callbacks
@property (nonatomic, copy) RadarScanCallback scanCallback;
@property (nonatomic, copy) RadarConfigCallback configCallback;
@property (nonatomic, copy) RadarStatusCallback queryCallback;
@property (nonatomic, copy) void(^connectCallback)(BOOL success);

// Device tracking
@property (nonatomic, strong) DeviceInfo *currentDevice;
@property (nonatomic, copy) NSString *currentDeviceUUID;
@property (nonatomic, strong) CBPeripheral *currentPeripheral;
@property (nonatomic, strong) NSMutableDictionary<NSString *, CBPeripheral *> *peripheralCache;
//@property (nonatomic, strong) NSMutableSet *discoveredDeviceUUIDs; // 存储已发现设备的UUID
@property (nonatomic, strong) NSMutableDictionary *statusMap; 

// State flags
@property (nonatomic, assign) BOOL isScanning;
@property (nonatomic, assign) BOOL isConnected;
@property (nonatomic, assign) BOOL isConfiguring;


// Timers
@property (nonatomic, strong) NSTimer *scanTimer;
@property (nonatomic, strong) NSTimer *configTimer;
@property (nonatomic, strong) NSTimer *connectTimer;
@property (nonatomic, strong) NSTimer *queryTimer; 

// 查询状态控制
@property (nonatomic, assign) BOOL isQueryComplete;
@property (nonatomic, assign) BOOL hasWifiStatus;
@property (nonatomic, assign) BOOL hasUID;
@property (nonatomic, assign) BOOL hasMacAddress; 
@property (nonatomic, strong, nullable) NSArray<NSNumber *> *queryCommandSequence;
@property (nonatomic, assign) NSUInteger currentQueryCommandIndex;
@property (nonatomic, assign) BOOL isPerformingQueryPipeline;

// 与服务器配置相关的属性
@property (nonatomic, copy) NSString *serverAddress;
@property (nonatomic, assign) NSInteger serverPort;
@property (nonatomic, copy) NSString *serverProtocol;
@property (nonatomic, copy) NSString *wifiSsid;
@property (nonatomic, copy) NSString *wifiPassword;
@property (nonatomic, assign) NSInteger configRetryCount;



// 过滤属性
@property (nonatomic, copy) NSString *currentFilterPrefix;
@property (nonatomic, assign) FilterType currentFilterType;

// 错误处理
@property (nonatomic, assign) NSInteger errorCount;
@property (nonatomic, copy) void(^errorCallback)(RadarBleErrorType errorType, NSString *errorMessage);

// Wi-Fi 扫描
@property (nonatomic, assign) BOOL isScanningNearbyWiFi;
@property (nonatomic, strong, nullable) NSTimer *wifiScanTimer;
@property (nonatomic, copy, nullable) void (^wifiScanCompletionBlock)(BOOL success);
@property (nonatomic, strong, nullable) NSMutableArray<NSDictionary *> *wifiScanResultsBuffer;
@property (nonatomic, assign) BOOL isEspScanOnly;

// 预热控制
@property (nonatomic, assign) BOOL shouldPerformPreheat;
@property (nonatomic, assign) BOOL isPreheatingForConfiguration;
@property (nonatomic, strong, nullable) NSTimer *preheatTimer;

- (void)startQueryCommandPipeline;
- (void)sendQueryCommandAtIndex:(NSUInteger)index;
- (void)advanceQueryPipeline;
- (BOOL)isCurrentQueryCommand:(RadarQueryCommand)command;
- (void)queryPipelineDidComplete;
- (void)startNearbyWiFiScan;
- (void)wifiScanTimedOut;
- (void)completeNearbyWiFiScanWithResults:(nullable NSArray<NSDictionary *> *)results success:(BOOL)success;
- (void)sendOperationStatusQuery;
- (void)handleOperationStatusResponse:(NSString *)responseStr;
- (BOOL)startConfigurationPreheatIfNeeded;
- (void)completeConfigurationPreheatWithSuccess:(BOOL)success uid:(nullable NSString *)uid;
- (void)preheatTimedOut;
- (void)performConfigurationCommands;
- (void)resetPreheatState;

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
        _blufiClient = nil;
        
        // 初始化Central Manager
        _centralManager = [[CBCentralManager alloc] initWithDelegate:self queue:nil];
        
        // 设置BlufiClient代理
        _blufiClient.blufiDelegate = self;
        _blufiClient.centralManagerDelete = self;
        _blufiClient.peripheralDelegate = (id<CBPeripheralDelegate>)self;
        
        // 初始化其他属性
        _isScanning = NO;
        _isConfiguring = NO;
        _errorCount = 0;
        
        // 设置默认过滤类型
        _currentFilterType = FilterTypeDeviceName;
    }
    return self;
}
//BlufiClient lazy 
- (BlufiClient *)blufiClient {
    if (!_blufiClient && _currentDevice) {
        //RDRLOG("Lazy initializing BlufiClient for device: ");
        
        _blufiClient = [[BlufiClient alloc] init];
        // 保留必要的代理设置
        _blufiClient.blufiDelegate = self;
        _blufiClient.centralManagerDelete = self;
        _blufiClient.peripheralDelegate = self;
        
        // 设置默认包长度限制
        _blufiClient.postPackageLengthLimit = 128;
        
        // 自动连接目标设备
        [_blufiClient connect:_currentDevice.uuid];
        
        // 标记连接状态
        _isConnected = YES;
    }
    return _blufiClient;
}

- (void)_cleanupBlufiClient {
    if (_blufiClient) {
        //RDRLOG("Releasing BlufiClient instance");
        [_blufiClient close];
        _blufiClient = nil;
        _isConnected = NO;
    }
}

// 资源释放方法
- (void)dealloc {
    //RDRLOG(@"Releasing RadarBleManager resources");
    
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
    _queryCallback = nil;
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
    //RDRLOG(@"Error callback set successfully");
}

// 重置错误计数
- (void)resetErrorCount {
    _errorCount = 0;
}
#pragma mark - Public Methods - connectDevice/Disconnect
// 根据UUID获取peripheral对象
- (void)setCurrentDevice:(DeviceInfo *)device {
    if (!device || !device.uuid) {
        //RDRLOG(@"Error: Invalid device information");
        if (_errorCallback) {
            _errorCallback(RadarBleErrorInvalidParameter, @"Invalid device information");
        }
        return;
    }
    
    // Check if already connected to this device
    if (_isConnected && _currentDevice && [_currentDevice.uuid isEqualToString:device.uuid]) {
        //RDRLOG(@"Already connected to device");
        return;
    }
    // If connected to different device, disconnect first
    if (_isConnected && _blufiClient) {
        [self disconnect];
    }
    // If connected to different device, disconnect first
    if (_isConnected && _blufiClient) {
        [self disconnect];
    }
    
    // Save current device info
    _currentDevice = device;
    _currentDeviceUUID = device.uuid;
    
    // Access blufiClient through lazy getter to establish connection
    [self blufiClient];
}



/**
 * 准备使用设备 - 从缓存获取peripheral对象
 *  * @param device 设备信息
 */
 
- (void)connectDevice:(DeviceInfo *)device {
    if (!device || !device.uuid) {
        //RDRLOG(@"Error: Invalid device information");
        if (_errorCallback) {
            _errorCallback(RadarBleErrorInvalidParameter, @"Invalid device information");
        }
        return;
    }
    
    // Check if already connected to this device
    if (_isConnected && _currentDevice && [_currentDevice.uuid isEqualToString:device.uuid]) {
        //RDRLOG(@"Already connected to device");
        return;
    }
    
    // If connected to different device, disconnect first
    if (_isConnected && _blufiClient) {
        [self disconnect];
    }
    
    // Save current device info
    _currentDevice = device;
    _currentDeviceUUID = device.uuid;
    
    // Access blufiClient through lazy getter to establish connection
    [self blufiClient];

    //RDRLOG(@"Connecting to device");
    
    // 设置连接超时
    _connectTimer = [NSTimer scheduledTimerWithTimeInterval:DEFAULT_CONNECT_TIMEOUT
                                                     target:self
                                                   selector:@selector(connectionTimedOut)
                                                   userInfo:nil
                                                    repeats:NO];
    
    [_blufiClient connect:device.uuid];

}

  - (void)disconnect {
      //RDRLOG(@"Disconnecting device");

      BOOL hasPendingQuery = (_queryCallback != nil);

      // 清理 BlufiClient
      if (_blufiClient) {
          @try {
              [_blufiClient close];
          } @catch (NSException *exception) {
              //RDRLOG(@"Exception during blufiClient close: %@", exception);
          }
          _blufiClient = nil;
      }

      // 取消所有定时器
      if (_scanTimer) {
          [_scanTimer invalidate];
          _scanTimer = nil;
      }

      if (_configTimer) {
          [_configTimer invalidate];
          _configTimer = nil;
      }

      if (_connectTimer) {
          [_connectTimer invalidate];
          _connectTimer = nil;
      }

      if (_queryTimer) {
          [_queryTimer invalidate];
          _queryTimer = nil;
      }

      if (_wifiScanTimer) {
          [_wifiScanTimer invalidate];
          _wifiScanTimer = nil;
      }

      [self resetPreheatState];
      _isEspScanOnly = NO;

      if (_isScanningNearbyWiFi) {
          [self completeNearbyWiFiScanWithResults:nil success:NO];
      }

      if (!hasPendingQuery && !_isConfiguring) {
          _currentDevice = nil;
          _currentPeripheral = nil;
          _currentDeviceUUID = nil;
      }

      // 重置状态
      _isConnected = NO;
      if (!_isConfiguring) {
          _isConfiguring = NO;
      }
      if (!hasPendingQuery) {
          _isQueryComplete = NO;
          _isPerformingQueryPipeline = NO;
          _wifiScanResultsBuffer = nil;
          _wifiScanCompletionBlock = nil;
      }
  }


- (void)connectionTimedOut {
    //RDRLOG(@"Connection timed out for device");
    
    // 通知错误回调
    if (_errorCallback) {
        _errorCallback(RadarBleErrorConnectionTimeout, @"Connection to device timed out");
    }
    
    // 如果正在查询，通知查询失败
    if (_queryCallback && !_isQueryComplete) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_queryCallback(self->_currentDevice, NO);
            self->_queryCallback = nil;
        });
    }
    
    // 断开连接，清理资源
    [self disconnect];
}

//等待蓝牙服务和特征被发现后再进行安全协商：
/*
- (void)blufi:(BlufiClient *)client gattPrepared:(BlufiStatusCode)status service:(nullable CBService *)service writeChar:(nullable CBCharacteristic *)writeChar notifyChar:(nullable CBCharacteristic *)notifyChar {
    [_connectTimer invalidate];
    _connectTimer = nil;
    
    if (status == StatusSuccess) {
        //RDRLOG(@"BluFi GATT prepared successfully with service");
        _isConnected = YES;
        
        // 如果正在查询，自动开始安全协商
        if (_queryCallback && !_isQueryComplete) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self->_blufiClient negotiateSecurity];
            });
        }
    } else {
        _isConnected = NO;
        
        NSString *errorMsg = @"Blufi GATT preparation failed";
        if (!service) {
            errorMsg = @"Failed to discover Blufi service";
        } else if (!writeChar) {
            errorMsg = @"Failed to discover Blufi write characteristic";
        } else if (!notifyChar) {
            errorMsg = @"Failed to discover Blufi notify characteristic";
        }
        
        //RDRLOG(@"%@: %d", errorMsg, status);
        
        if (_queryCallback) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_queryCallback(self->_currentDevice, NO);
                self->_queryCallback = nil;
            });
        }
        
        // 清理资源
        [self disconnect];
    }
}
*/
- (void)blufi:(BlufiClient *)client gattPrepared:(BlufiStatusCode)status service:(nullable CBService *)service writeChar:(nullable CBCharacteristic *)writeChar notifyChar:(nullable CBCharacteristic *)notifyChar {
    [_connectTimer invalidate];
    _connectTimer = nil;
    
    if (status == StatusSuccess && service && writeChar && notifyChar) {
        RDRLOG(@"GATT prepared successfully, services and characteristics available - delaying security negotiation");
        _isConnected = YES;
        
        // 关键改进：延长等待时间，确保BLE堆栈完全稳定
        // 3秒是一个相对保守的延迟，但可确保高成功率
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            @try {
                RDRLOG(@"Starting security negotiation...");
                [self->_blufiClient negotiateSecurity];
            } @catch (NSException *exception) {
                RDRLOG(@"Security negotiation exception: %@", exception.reason);
                
                // 如果是特征为空的异常，可能需要重新初始化连接
                if ([exception.reason containsString:@"characteristic != nil"]) {
                    RDRLOG(@"Characteristic is null, need to re-establish connection");
                    [self disconnect];
                    
                    // 延迟一段时间后重新连接
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        if (self->_currentDevice) {
                            [self connectDevice:self->_currentDevice];
                        }
                    });
                }
            }
        });
    } else {
        _isConnected = NO;
        RDRLOG(@"GATT preparation failed: status=%d, service=%@, write characteristic=%@, notify characteristic=%@", 
            status, 
            service ? @"available" : @"unavailable", 
            writeChar ? @"available" : @"unavailable", 
            notifyChar ? @"available" : @"unavailable");
        
        // 如果正在查询，通知查询失败
        if (_queryCallback && !_isQueryComplete) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_queryCallback(self->_currentDevice, NO);
                self->_queryCallback = nil;
            });
        }
        
        // 断开连接，清理资源
        [self disconnect];
    }
}

#pragma mark - Scan Methods

// 设置扫描回调
- (void)setScanCallback:(RadarScanCallback)callback {
    _scanCallback = callback;
    //RDRLOG(@"Scan callback set successfully");
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
        //RDRLOG(@"Scan already in progress, ignoring request");
        return;
    }
        // 保存过滤参数
    _currentFilterPrefix = filterPrefix;
    _currentFilterType = filterType;
    
    // 检查蓝牙状态
    if (_centralManager.state != CBManagerStatePoweredOn) {
        //RDRLOG(@"Bluetooth not enabled, delay rescan");
        __weak typeof(self) weakSelf = self;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
                        if (!strongSelf) return;
            if (strongSelf.centralManager.state == CBManagerStatePoweredOn) {
                //RDRLOG(@"after delay ble is ready,start  scan");
                [strongSelf startActualScan:timeout];
            } else {
                if (strongSelf.errorCallback) {
                    strongSelf.errorCallback(RadarBleErrorBluetoothDisabled, @"Bluetooth is disabled");
                }
            }
        });
        return;
    }
    
    // 蓝牙已启用，直接开始扫描
    [self startActualScan:timeout];
}
    
// 实际开始扫描的内部方法
- (void)startActualScan:(NSTimeInterval)timeout {
    //RDRLOG(@"Starting scan: timeout=%.1fs",timeout);
    
    // 设置扫描标志
    _isScanning = YES;
    
    // 设置扫描超时计时器
    _scanTimer = [NSTimer scheduledTimerWithTimeInterval:timeout
                                                  target:self
                                                selector:@selector(scanTimedOut)
                                                userInfo:nil
                                                 repeats:NO];
    
    // 开始扫描，不使用过滤器参数，由scanviewcontroller处理过滤
    NSDictionary *options = @{CBCentralManagerScanOptionAllowDuplicatesKey: @NO};
    [_centralManager scanForPeripheralsWithServices:nil options:options];
}

// 停止扫描
- (void)stopScan {
    if (!_isScanning) {
        return;
    }
    
    //RDRLOG(@"Stopping scan");
    
    // 停止蓝牙扫描
    [_centralManager stopScan];
    
    // 取消超时计时器
    [_scanTimer invalidate];
    _scanTimer = nil;
    
    _isScanning = NO;

}

// 扫描超时处理
- (void)scanTimedOut {
    //RDRLOG(@"Scan timed out");
    [self stopScan];
}

#pragma mark - CBCentralManagerDelegate Methods

// 蓝牙状态变化回调
- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    //RDRLOG(@"Bluetooth state updated: %ld", (long)central.state);
    
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
    
    __weak typeof(self) weakSelf = self;
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf) return;

    // 获取设备UUID
    NSString *uuid = peripheral.identifier.UUIDString;
    
    // 去重并保存peripheral到缓存中
    @synchronized(strongSelf->_peripheralCache) {
        if (strongSelf->_peripheralCache[uuid]) {
            return; // 已存在则跳过
        }
        strongSelf->_peripheralCache[uuid] = peripheral; // 不存在才存储
        ////RDRLOG(@"Cached peripheral for UUID: %@", uuid);
    }

    // 打印详细日志
    ////RDRLOG(@"设备信息:");
    ////RDRLOG(@"Peripheral: %@", peripheral);
    ////RDRLOG(@"Peripheral name: %@", peripheral.name ?: @"nil");
    ////RDRLOG(@"Peripheral ID: %@", peripheral.identifier);
    ////RDRLOG(@"Peripheral state: %ld", (long)peripheral.state);
    ////RDRLOG(@"RSSI: %@", RSSI);
    
    // 创建设备信息对象
    DeviceInfo *deviceInfo = [[DeviceInfo alloc] initWithProductorName:ProductorRadarQL
                                                           deviceName:peripheral.name ?: @"Unknown"
                                                             deviceId:peripheral.name ?: @"Unknown"
                                                           deviceType:nil
                                                              version:nil
                                                                  uid:nil
                                                          macAddress:nil
                                                                 uuid:uuid
                                                                 rssi:[RSSI integerValue]];
    
    // 通知扫描回调
    if (strongSelf->_scanCallback) {
        dispatch_async(dispatch_get_main_queue(), ^{
            strongSelf->_scanCallback(deviceInfo);
        });
    }
}

- (void)resetPreheatState {
    _shouldPerformPreheat = NO;
    _isPreheatingForConfiguration = NO;
    if (_preheatTimer) {
        [_preheatTimer invalidate];
        _preheatTimer = nil;
    }
}

- (BOOL)startConfigurationPreheatIfNeeded {
    if (!_isConfiguring || !_shouldPerformPreheat) {
        return NO;
    }
    if (_isPreheatingForConfiguration) {
        return YES;
    }
    
    _isPreheatingForConfiguration = YES;
    _shouldPerformPreheat = NO;
    
    [_preheatTimer invalidate];
    _preheatTimer = [NSTimer scheduledTimerWithTimeInterval:DEFAULT_PREHEAT_TIMEOUT
                                                     target:self
                                                   selector:@selector(preheatTimedOut)
                                                   userInfo:nil
                                                    repeats:NO];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self->_isPreheatingForConfiguration) {
            RDRLOG(@"Starting configuration preheat (UID query)");
            [self sendUIDQuery];
        }
    });
    
    return YES;
}

- (void)preheatTimedOut {
    if (!_isPreheatingForConfiguration) {
        return;
    }
    RDRLOG(@"Configuration preheat timed out");
    [self completeConfigurationPreheatWithSuccess:NO uid:nil];
}

- (void)completeConfigurationPreheatWithSuccess:(BOOL)success uid:(nullable NSString *)uid {
    if (!_isPreheatingForConfiguration) {
        return;
    }
    
    [_preheatTimer invalidate];
    _preheatTimer = nil;
    _isPreheatingForConfiguration = NO;
    
    NSMutableDictionary *userInfo = [@{ RadarBlePreheatResultKeySuccess : @(success) } mutableCopy];
    if (uid.length > 0) {
        userInfo[RadarBlePreheatResultKeyUID] = uid;
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:RadarBlePreheatDidFinishNotification
                                                        object:_currentDevice
                                                      userInfo:userInfo];
    
    if (!success) {
        RDRLOG(@"Preheat failed, aborting configuration");
        [self configurationDidFailWithError:@"Failed to retrieve UID before configuration"];
        return;
    }
    
    RDRLOG(@"Preheat succeeded with UID: %@", uid ?: @"(nil)");
    [self performConfigurationCommands];
}

- (void)performConfigurationCommands {
    if (!_isConfiguring) {
        return;
    }
    
    if (_wifiSsid) {
        [self sendWifiConfiguration];
    } else if (_serverAddress) {
        [self sendServerConfiguration];
    } else {
        [self configurationDidFailWithError:@"No valid configuration parameters"];
    }
}

#pragma mark - 配置方法
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
    //RDRLOG(@"Starting device configuration");
    
    // 参数验证
    if (!device || !device.uuid) {
        //RDRLOG(@"Error: Invalid device information");
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, @{@"error": @"Invalid device information"});
            });
        }
        return;
    }
    
    // 保存回调和配置参数
    _configCallback = completion;
    _currentDevice = device;
    _serverAddress = serverAddress;
    _serverPort = serverPort;
    _serverProtocol = serverProtocol;
    _wifiSsid = wifiSsid;
    _wifiPassword = wifiPassword;
    
    [self resetPreheatState];
    if (device.productorName == ProductorRadarQL) {
        _shouldPerformPreheat = YES;
    }
    
    // 设置配置超时
    [_configTimer invalidate];
    _configTimer = [NSTimer scheduledTimerWithTimeInterval:DEFAULT_CONFIG_TIMEOUT
                                                   target:self
                                                 selector:@selector(configurationTimedOut)
                                                 userInfo:nil
                                                  repeats:NO];
    
    _isConfiguring = YES;
    
    // 检查连接状态
    BOOL isDeviceConnected = (_isConnected && _blufiClient && 
                             [_currentDevice.uuid isEqualToString:device.uuid]);
    
    if (!isDeviceConnected) {
        // 设备未连接，先连接设备
        //RDRLOG(@"Device not connected, connecting first...");
        
        [self connectDevice:device];
    } else {
        // 设备已连接，直接进行安全协商
        //RDRLOG(@"Device already connected, proceeding with security negotiation...");
        @try {
            [_blufiClient negotiateSecurity];
        } @catch (NSException *exception) {
            RDRLOG(@"negotiateSecurity exception (already connected path): %@", exception.reason);
            [self configurationDidFailWithError:@"Failed to negotiate security for existing connection"];
        }
    }
    
    // 注意：实际的配置操作将在didNegotiateSecurity回调中执行
}
/**
 * 安全协商结果回调 - 继续执行配置流程
 */
- (void)blufi:(BlufiClient *)client didNegotiateSecurity:(BlufiStatusCode)status {
    //RDRLOG(@"Security negotiation result: %d", status);
    
    if (status != StatusSuccess) {
        // 安全协商失败
        _errorCount++;
        
        if (_errorCount < 2 && _isConfiguring) {
            // 最多重试一次
            //RDRLOG(@"Security negotiation failed, retrying once...");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [client negotiateSecurity];
            });
            return;
        }
        
        // 重试失败或不重试
        if (_isConfiguring) {
            [self configurationDidFailWithError:@"Security negotiation failed"];
        } else if (_queryCallback) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_queryCallback(self->_currentDevice, NO);
            });
        }
        return;
    }
    
    // 安全协商成功
    _errorCount = 0;
    
    // 根据配置参数选择适当的配置方法
    if (_isConfiguring) {
        if ([self startConfigurationPreheatIfNeeded]) {
            return;
        }
        [self performConfigurationCommands];
    } else if (_queryCallback) {
        if (_isEspScanOnly) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self startNearbyWiFiScan];
            });
        } else {
            // 查询设备状态
            [self startQueryCommandPipeline];
        }
    }
}

/**
 * 发送WiFi配置
 */
- (void)sendWifiConfiguration {
    //RDRLOG(@"Sending WiFi configuration: SSID=%@", _wifiSsid);
    
    // 创建配置参数对象
    BlufiConfigureParams *params = [[BlufiConfigureParams alloc] init];
    params.opMode = OpModeSta;  // 设置为Station模式
    params.staSsid = _wifiSsid;
    params.staPassword = _wifiPassword ?: @"";
    
    // 发送配置
    [_blufiClient configure:params];
    
    // 配置结果会在didPostConfigureParams回调中处理
}

/**
 * 发送服务器配置
 */
- (void)sendServerConfiguration {
    if (!_serverAddress || _serverPort <= 0) {
        [self configurationDidFailWithError:@"Invalid server configuration"];
        return;
    }
    
    //RDRLOG(@"Sending server configuration: %@:%ld", _serverAddress, (long)_serverPort);
    
    // 创建结果字典
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    [result setObject:_currentDevice.deviceId forKey:@"deviceId"];
    [result setObject:_currentDevice.uuid ?: @"" forKey:@"uuid"];
    
    // 发送服务器地址命令
    NSString *serverCmd = [NSString stringWithFormat:@"1:%@", _serverAddress];
    NSData *data = [serverCmd dataUsingEncoding:NSUTF8StringEncoding];
    
    if (data) {
        [_blufiClient postCustomData:data];
        //RDRLOG(@"Server address command sent");
        
        // 延迟发送端口命令（等待地址命令处理完成）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            // 发送服务器端口命令
            NSString *portCmd = [NSString stringWithFormat:@"2:%ld", (long)self->_serverPort];
            NSData *portData = [portCmd dataUsingEncoding:NSUTF8StringEncoding];
            
            if (portData) {
                [self->_blufiClient postCustomData:portData];
                //RDRLOG(@"Server port command sent");
                
                // 延迟发送其他命令
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    // 发送额外命令
                    [self->_blufiClient postCustomData:[@"3:0" dataUsingEncoding:NSUTF8StringEncoding]];
                    //RDRLOG(@"Extra command sent");
                    
                    // 最后发送重启命令
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        [self->_blufiClient postCustomData:[@"8:" dataUsingEncoding:NSUTF8StringEncoding]];
                        //RDRLOG(@"Restart command sent");
                        
                        // 假设命令都已成功发送，等待设备重启
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            // 配置完成，返回成功结果
                            [result setObject:@(YES) forKey:@"success"];
                            [result setObject:@"Server configuration completed\nwait 10 seconds for restart" forKey:@"message"];
                            
                            if (self->_configCallback) {
                                dispatch_async(dispatch_get_main_queue(), ^{
                                    self->_configCallback(YES, result);
                                });
                            }
                            
                            // 清理状态
                            self->_isConfiguring = NO;
                            [self resetPreheatState];
                            [self->_configTimer invalidate];
                            self->_configTimer = nil;
                        });
                    });
                });
            } else {
                [self configurationDidFailWithError:@"Failed to encode server port command"];
            }
        });
    } else {
        [self configurationDidFailWithError:@"Failed to encode server address command"];
    }
}

/**
 * WiFi配置结果回调处理
 */
- (void)blufi:(BlufiClient *)client didPostConfigureParams:(BlufiStatusCode)status {
    if (!_isConfiguring) return;
    
    BOOL success = (status == StatusSuccess);
    
    // 创建结果字典
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    [result setObject:@(status) forKey:@"status"];
    [result setObject:@(success) forKey:@"success"];
    
    if (success) {
        //RDRLOG(@"WiFi configuration successful");
        
        // 设置成功信息
        if (_serverAddress && _serverPort > 0) {
            // 如果同时配置WiFi和服务器，继续服务器配置
            [result setObject:@"WiFi configuration successful, proceeding to server configuration" forKey:@"message"];
            
            // 更新设备WiFi信息
            _currentDevice.wifiSsid = _wifiSsid;
            _currentDevice.wifiPassword = _wifiPassword;
            
            // 延迟开始服务器配置
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (self->_isConfiguring) {
                    [self sendServerConfiguration];
                }
            });
            
            // 通知主界面WiFi配置成功
            if (_configCallback) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self->_configCallback(YES, result);
                });
            }
        } else {
            // 只配置WiFi，直接完成
            [result setObject:@"WiFi configuration successful" forKey:@"message"];
            
            // 更新设备信息
            _currentDevice.wifiSsid = _wifiSsid;
            _currentDevice.wifiPassword = _wifiPassword;
            _currentDevice.lastUpdateTime = [[NSDate date] timeIntervalSince1970];
            
            // 通知主界面
            if (_configCallback) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self->_configCallback(YES, result);
                });
            }
            
            // 清理状态
            _isConfiguring = NO;
            [self resetPreheatState];
            [_configTimer invalidate];
            _configTimer = nil;
        }
    } else {
        // 配置失败
        //RDRLOG(@"WiFi configuration failed: %d", status);
        [result setObject:[NSString stringWithFormat:@"WiFi configuration failed: %d", status] forKey:@"error"];
        
        // 通知主界面
        if (_configCallback) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_configCallback(NO, result);
            });
        }
        
        // 清理状态
        _isConfiguring = NO;
        [self resetPreheatState];
        [_configTimer invalidate];
        _configTimer = nil;
    }
}

/**
 * 配置失败处理
 */
- (void)configurationDidFailWithError:(NSString *)error {
    //RDRLOG(@"Configuration failed: %@", error);
    
    [self resetPreheatState];
    
    // 取消超时计时器
    [_configTimer invalidate];
    _configTimer = nil;
    
    // 创建结果字典
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    [result setObject:@(NO) forKey:@"success"];
    [result setObject:error forKey:@"error"];
    
    // 通知主界面
    if (_configCallback) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_configCallback(NO, result);
        });
    }
    
    // 清理状态
    _isConfiguring = NO;
}

/**
 * 配置超时处理
 */
- (void)configurationTimedOut {
    [self configurationDidFailWithError:@"Configuration operation timed out"];
}

#pragma mark - 查询设备状态
/**
 * 查询设备状态
 * @param device 设备信息
 * @param completion 查询结果回调，返回更新后的设备信息
 */
- (void)queryDeviceStatus:(DeviceInfo *)device
              completion:(void(^)(DeviceInfo *updatedDevice, BOOL success))completion {
    ////RDRLOG(@"Start querying device status for: %@, UUID: %@", device.deviceName, device.uuid);
    
    // 参数验证
    if (!device || !device.uuid) {
        //RDRLOG(@"Error: Invalid device information");
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(device, NO);
            });
        }
        return;
    }
    
    // 保存状态回调和设备信息
    _queryCallback = completion;
    _currentDevice = device;  
    _isEspScanOnly = NO;
    
    // 重置查询状态
    _isQueryComplete = NO;
    _hasWifiStatus = NO;
    _hasUID = NO;
    _hasMacAddress = NO;
    // 初始化状态字典
    _statusMap = [NSMutableDictionary dictionary];
    _queryCommandSequence = nil;
    _currentQueryCommandIndex = 0;
    _isPerformingQueryPipeline = NO;
    _isScanningNearbyWiFi = NO;
    [_wifiScanTimer invalidate];
    _wifiScanTimer = nil;
    _wifiScanCompletionBlock = nil;
    
    // 设置查询超时
    [_queryTimer invalidate];
    _queryTimer = [NSTimer scheduledTimerWithTimeInterval:DEFAULT_QUERY_TIMEOUT
                                                  target:self
                                                selector:@selector(queryTimedOut)
                                                userInfo:nil
                                                 repeats:NO];
    
    // 如果已连接到该设备，直接开始安全协商
    if (_isConnected && _blufiClient && 
        [_currentDevice.uuid isEqualToString:device.uuid]) {
        //RDRLOG(@"Device already connected, proceeding with security negotiation...");
        
        // 注意：延迟调用安全协商，确保特征已就绪
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            @try {
                [self->_blufiClient negotiateSecurity];
            } @catch (NSException *exception) {
                //RDRLOG(@"negotiateSecurity exception: %@", exception.reason);
                // 连接可能已失效，需要重新连接
                [self connectDevice:device];
            }
        });
    } else {
        // 需要重新连接设备
        //RDRLOG(@"Device not connected, connecting first...");
        [self connectDevice:device];
        // 注意：连接成功后的安全协商会在 gattPrepared 回调中处理
    }
}

- (void)scanNearbyWiFiForDevice:(DeviceInfo *)device completion:(RadarStatusCallback)completion {
    if (!device || !device.uuid) {
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(device, NO);
            });
        }
        return;
    }
    
    _queryCallback = completion;
    _currentDevice = device;
    _isEspScanOnly = YES;
    _isQueryComplete = NO;
    _hasWifiStatus = NO;
    _hasUID = NO;
    _hasMacAddress = NO;
    _queryCommandSequence = nil;
    _currentQueryCommandIndex = 0;
    _isPerformingQueryPipeline = NO;
    _isScanningNearbyWiFi = NO;
    [_wifiScanTimer invalidate];
    _wifiScanTimer = nil;
    _wifiScanResultsBuffer = nil;
    _statusMap = [NSMutableDictionary dictionary];
    
    [_queryTimer invalidate];
    _queryTimer = [NSTimer scheduledTimerWithTimeInterval:DEFAULT_QUERY_TIMEOUT
                                                  target:self
                                                selector:@selector(queryTimedOut)
                                                userInfo:nil
                                                 repeats:NO];
    
    __weak typeof(self) weakSelf = self;
    _wifiScanCompletionBlock = ^(BOOL success) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) { return; }
        if (success) {
            [strongSelf finishQuery:YES];
        } else {
            [strongSelf finishQuery:NO];
        }
    };
    
    BOOL isDeviceConnected = (_isConnected && _blufiClient &&
                              [_currentDevice.uuid isEqualToString:device.uuid]);
    
    if (!isDeviceConnected) {
        [self connectDevice:device];
    } else {
        @try {
            [_blufiClient negotiateSecurity];
        } @catch (NSException *exception) {
            RDRLOG(@"negotiateSecurity exception (ESP scan path): %@", exception.reason);
            [self finishQuery:NO];
        }
    }
}

/**
 * 查询超时处理 
 */
- (void)queryTimedOut {
    //RDRLOG(@"Query operation timed out");
    
    // 如果查询正在进行且未完成
    if (!_isQueryComplete) {
        //RDRLOG(@"Query timeout, checking partial results...");
        
        // 检查是否有部分数据可用
        BOOL hasPartialData = (_hasUID || _hasMacAddress || _hasWifiStatus);
        
        if (hasPartialData) {
            ////RDRLOG(@"Some data available (UID:%d, MAC:%d, WiFi:%d), returning partial results",_hasUID, _hasMacAddress, _hasWifiStatus);
            [self finishQuery:YES]; // 返回部分数据
        } else {
            //RDRLOG(@"No data available, query failed");
            [self finishQuery:NO]; // 完全失败
        }
    }
    
    // 如果需要,断开连接 
        [self disconnect];
    
}

/**
 * 发送UID查询命令
 */
- (void)sendUIDQuery {
    //RDRLOG(@"Sending UID query command");
    RDRLOG(@"Sending UID query command (12:)");
    NSData *uidCmd = [@"12:" dataUsingEncoding:NSUTF8StringEncoding];
    [_blufiClient postCustomData:uidCmd];
}

/**
 * 发送MAC地址查询命令
 */
- (void)sendMACQuery {
    //RDRLOG(@"Sending MAC address query command");
    RDRLOG(@"Sending MAC query command (65:)");
    NSData *macCmd = [@"65:" dataUsingEncoding:NSUTF8StringEncoding];
    [_blufiClient postCustomData:macCmd];
}

/**
 * 发送 WiFi 状态查询命令 - 使用 ESP SDK 标准方法
 */
- (void)sendWiFiStatusQuery {
    RDRLOG(@"Sending WiFi status query command (62:)");
    NSData *wifiCmd = [@"62:" dataUsingEncoding:NSUTF8StringEncoding];
    [_blufiClient postCustomData:wifiCmd];
}

- (void)sendOperationStatusQuery {
    RDRLOG(@"Sending operate status query command (10:)");
    NSString *commandString = @"10:";
    NSData *operateCmd = [commandString dataUsingEncoding:NSASCIIStringEncoding];
    [_blufiClient postCustomData:operateCmd];
}

- (void)startQueryCommandPipeline {
    if (!_queryCallback) {
        return;
    }
    _queryCommandSequence = @[
        @(RadarQueryCommandMAC),
        @(RadarQueryCommandUID),
        @(RadarQueryCommandWifiStatus),
        @(RadarQueryCommandOperateStatus)
    ];
    _currentQueryCommandIndex = 0;
    _isPerformingQueryPipeline = YES;
    RDRLOG(@"Starting query pipeline: MAC -> UID -> WiFiStatus -> OperateStatus");
    
    // 清理之前的状态
    if (_statusMap) {
        [_statusMap removeAllObjects];
    } else {
        _statusMap = [NSMutableDictionary dictionary];
    }
    _hasUID = NO;
    _hasMacAddress = NO;
    _hasWifiStatus = NO;
    
    // 顺序执行命令
    [self sendQueryCommandAtIndex:_currentQueryCommandIndex];
}

- (void)sendQueryCommandAtIndex:(NSUInteger)index {
    if (!_isPerformingQueryPipeline || index >= _queryCommandSequence.count) {
        [self queryPipelineDidComplete];
        return;
    }
    
    RadarQueryCommand command = (RadarQueryCommand)[_queryCommandSequence[index] unsignedIntegerValue];
    switch (command) {
        case RadarQueryCommandUID: {
            [self sendUIDQuery];
            break;
        }
        case RadarQueryCommandMAC: {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kRadarQueryCommandDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self sendMACQuery];
            });
            break;
        }
        case RadarQueryCommandWifiStatus: {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kRadarQueryCommandDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self sendWiFiStatusQuery];
            });
            break;
        }
        case RadarQueryCommandOperateStatus: {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kRadarQueryCommandDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self sendOperationStatusQuery];
            });
            break;
        }
    }
}

- (BOOL)isCurrentQueryCommand:(RadarQueryCommand)command {
    if (!_isPerformingQueryPipeline || _currentQueryCommandIndex >= _queryCommandSequence.count) {
        return NO;
    }
    RadarQueryCommand current = (RadarQueryCommand)[_queryCommandSequence[_currentQueryCommandIndex] unsignedIntegerValue];
    return current == command;
}

- (void)advanceQueryPipeline {
    if (!_isPerformingQueryPipeline) {
        return;
    }
    _currentQueryCommandIndex++;
    if (_currentQueryCommandIndex >= _queryCommandSequence.count) {
        [self queryPipelineDidComplete];
    } else {
        [self sendQueryCommandAtIndex:_currentQueryCommandIndex];
    }
}

- (void)queryPipelineDidComplete {
    if (!_isPerformingQueryPipeline) {
        return;
    }
    _isPerformingQueryPipeline = NO;
    
    // 查询主超时计时器已经完成任务，此处交由 Wi-Fi 扫描计时器管理
    [_queryTimer invalidate];
    _queryTimer = nil;
    
    __weak typeof(self) weakSelf = self;
    _wifiScanCompletionBlock = ^(BOOL success) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) { return; }
        if (!success && !strongSelf->_hasUID && !strongSelf->_hasMacAddress && !strongSelf->_hasWifiStatus) {
            [strongSelf finishQuery:NO];
        } else {
            [strongSelf finishQuery:YES];
        }
    };
    [self startNearbyWiFiScan];
}

- (void)startNearbyWiFiScan {
    if (_isScanningNearbyWiFi) {
        return;
    }
    _isScanningNearbyWiFi = YES;
    RDRLOG(@"Requesting nearby Wi-Fi scan via BluFi");
    _wifiScanResultsBuffer = [NSMutableArray array];
    [_wifiScanTimer invalidate];
    _wifiScanTimer = [NSTimer scheduledTimerWithTimeInterval:kRadarWifiScanTimeout
                                                     target:self
                                                   selector:@selector(wifiScanTimedOut)
                                                   userInfo:nil
                                                    repeats:NO];
    @try {
        [_blufiClient requestDeviceScan];
    } @catch (NSException *exception) {
        RDRLOG(@"Failed to request nearby Wi-Fi scan: %@", exception.reason);
        [self completeNearbyWiFiScanWithResults:nil success:NO];
    }
}

- (void)wifiScanTimedOut {
    NSArray<NSDictionary *> *results = _wifiScanResultsBuffer.count > 0 ? [_wifiScanResultsBuffer copy] : nil;
    [self completeNearbyWiFiScanWithResults:results success:(results != nil)];
}

- (void)completeNearbyWiFiScanWithResults:(NSArray<NSDictionary *> *)results success:(BOOL)success {
    if (!_isScanningNearbyWiFi) {
        return;
    }
    _isScanningNearbyWiFi = NO;
    [_wifiScanTimer invalidate];
    _wifiScanTimer = nil;
    
    if (results) {
        [_statusMap setObject:results forKey:@"nearbyWiFiNetworks"];
        _currentDevice.nearbyWiFiNetworks = results;
    } else if (!_currentDevice.nearbyWiFiNetworks) {
        _currentDevice.nearbyWiFiNetworks = @[];
    }
    _wifiScanResultsBuffer = nil;
    
    if (_wifiScanCompletionBlock) {
        _wifiScanCompletionBlock(success);
    } else {
        if (success || _hasUID || _hasMacAddress || _hasWifiStatus) {
            [self finishQuery:YES];
        } else {
            [self finishQuery:NO];
        }
    }
    _wifiScanCompletionBlock = nil;
}

/**
 * 处理查询完成
 * 更新设备信息并通知回调
 */
- (void)finishQuery:(BOOL)success {
    if (_isQueryComplete) return;
    
    _isQueryComplete = YES;
    _isPerformingQueryPipeline = NO;
    _isEspScanOnly = NO;
    
    DeviceInfo *resultDevice = _currentDevice;
    
    // 更新设备信息
    if (success) {
        // 更新UID
        if (_statusMap[@"uid"]) {
            resultDevice.uid = _statusMap[@"uid"];
        }
        
        // 更新MAC地址
        if (_statusMap[@"macAddress"]) {
            resultDevice.macAddress = _statusMap[@"macAddress"];
        }
        
        // 更新WiFi状态
        if (_statusMap[@"wifiOpMode"]) {
            resultDevice.wifiMode = _statusMap[@"wifiOpMode"];
        }
        
        if (_statusMap[@"staConnected"]) {
            resultDevice.wifiConnected = [_statusMap[@"staConnected"] boolValue];
        }
        
        if (_statusMap[@"staSSID"]) {
            resultDevice.wifiSsid = _statusMap[@"staSSID"];
        }
        
        if (_statusMap[@"radarRunStatus"]) {
            resultDevice.radarRunStatus = _statusMap[@"radarRunStatus"];
        }
        
        if (_statusMap[@"nearbyWiFiNetworks"]) {
            resultDevice.nearbyWiFiNetworks = _statusMap[@"nearbyWiFiNetworks"];
        } else if (!resultDevice.nearbyWiFiNetworks) {
            resultDevice.nearbyWiFiNetworks = @[];
        }
        
        // 更新时间戳
        resultDevice.lastUpdateTime = [[NSDate date] timeIntervalSince1970];
    }
    
    // 通知回调
    if (_queryCallback) {
        DeviceInfo *callbackDevice = resultDevice;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self->_queryCallback) {
                self->_queryCallback(callbackDevice, success);
                self->_queryCallback = nil;
            }
        });
    }
    
    // 清理状态
    [_queryTimer invalidate];
    _queryTimer = nil;
    [_wifiScanTimer invalidate];
    _wifiScanTimer = nil;
    _wifiScanCompletionBlock = nil;
    _isScanningNearbyWiFi = NO;
    _statusMap = nil;
    if (!_isConfiguring) {
        _currentDevice = nil;
        _currentPeripheral = nil;
        _currentDeviceUUID = nil;
    }
}

/**
 * 处理UID响应
 */
- (void)handleUIDResponse:(NSString *)responseStr {
    BOOL isQueryCommand = [self isCurrentQueryCommand:RadarQueryCommandUID];
    BOOL isPreheatResponse = _isPreheatingForConfiguration;
    
    if (!isQueryCommand && !isPreheatResponse) {
        return;
    }
    NSArray *parts = [responseStr componentsSeparatedByString:@":"];
    NSString *uid = nil;
    if (parts.count >= 2) {
        uid = [parts objectAtIndex:1];
    } else if (parts.count == 1 && !isQueryCommand) {
        uid = parts.firstObject;
    }
    
    if ((!uid || uid.length == 0) && responseStr.length > 0) {
        NSRange range = [responseStr rangeOfString:@":"];
        if (range.location != NSNotFound && range.location + 1 < responseStr.length) {
            uid = [responseStr substringFromIndex:range.location + 1];
        } else {
            uid = responseStr;
        }
    }
    
    uid = [uid stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (uid.length > 0) {
        if (isQueryCommand) {
            [_statusMap setObject:uid forKey:@"uid"];
            _hasUID = YES;
            RDRLOG(@"Received UID response: %@", uid);
        }
        if (isPreheatResponse) {
            _currentDevice.uid = uid;
            [self completeConfigurationPreheatWithSuccess:YES uid:uid];
        }
    } else if (isPreheatResponse) {
        RDRLOG(@"Preheat UID response invalid: %@", responseStr);
        [self completeConfigurationPreheatWithSuccess:NO uid:nil];
    }
    
    if (isQueryCommand) {
        [self advanceQueryPipeline];
    }
}

/**
 * 处理MAC地址响应
 */
- (void)handleMACResponse:(NSString *)responseStr {
    if (![self isCurrentQueryCommand:RadarQueryCommandMAC]) {
        return;
    }
    NSArray *parts = [responseStr componentsSeparatedByString:@":"];
    NSString *macAddress = nil;
    if (parts.count >= 3 && [parts[2] length] > 0) {
        macAddress = parts[2];
    } else if (parts.count >= 2 && [parts[1] length] > 0) {
        macAddress = parts[1];
    }
    if (!macAddress || macAddress.length == 0) {
        // fall back to substring after first colon to keep compatibility
        NSRange range = [responseStr rangeOfString:@":"];
        if (range.location != NSNotFound && range.location + 1 < responseStr.length) {
            macAddress = [responseStr substringFromIndex:range.location + 1];
        }
    }
    
    macAddress = [macAddress stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (macAddress.length > 0) {
        [_statusMap setObject:macAddress forKey:@"macAddress"];
        _hasMacAddress = YES;
        RDRLOG(@"Received MAC address response: %@", macAddress);
    } else {
        RDRLOG(@"MAC response did not contain valid address: %@", responseStr);
    }
    [self advanceQueryPipeline];
}

/**
 * 处理WiFi状态响应
 */
- (void)handleWiFiStatusResponse:(NSArray *)parts {
    if (![self isCurrentQueryCommand:RadarQueryCommandWifiStatus]) {
        return;
    }
    if (parts.count >= 3) {
        NSString *mode = [parts objectAtIndex:1];
        BOOL connected = [@"0" isEqualToString:[parts objectAtIndex:2]];
        NSString *ssid = (parts.count > 3) ? [parts objectAtIndex:3] : nil;
        
        // 保存WiFi状态
        NSString *wifiMode;
        if ([mode isEqualToString:@"1"]) {
            wifiMode = @"STA";
        } else if ([mode isEqualToString:@"2"]) {
            wifiMode = @"AP";
        } else if ([mode isEqualToString:@"3"]) {
            wifiMode = @"APSTA";
        } else {
            wifiMode = @"Unknown";
        }
        
        [_statusMap setObject:wifiMode forKey:@"wifiOpMode"];
        [_statusMap setObject:@(connected) forKey:@"staConnected"];
        
        if (ssid) {
            [_statusMap setObject:ssid forKey:@"staSSID"];
        }
        
        _hasWifiStatus = YES;
        RDRLOG(@"Received Wi-Fi status response: mode=%@, connected=%d, ssid=%@", wifiMode, connected, ssid ?: @"");
    }
    [self advanceQueryPipeline];
}

- (void)handleOperationStatusResponse:(NSString *)responseStr {
    if (![self isCurrentQueryCommand:RadarQueryCommandOperateStatus]) {
        return;
    }
    NSString *statusValue = nil;
    NSRange range = [responseStr rangeOfString:@":"];
    if (range.location != NSNotFound && range.location + 1 < responseStr.length) {
        statusValue = [[responseStr substringFromIndex:range.location + 1]
                       stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    } else {
        statusValue = [responseStr stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    if (statusValue.length > 0) {
        [_statusMap setObject:statusValue forKey:@"radarRunStatus"];
        RDRLOG(@"Received operate status response: %@", statusValue);
    } else {
        RDRLOG(@"Operate status response empty: %@", responseStr);
    }
    [self advanceQueryPipeline];
}

/**
 * 处理 WiFi 状态查询结果
 */
- (void)handleWiFiStatusResponse:(NSString *)wifiMode connected:(BOOL)connected ssid:(NSString *)ssid {
    _currentDevice.wifiMode = wifiMode;
    _currentDevice.wifiConnected = connected;
    _currentDevice.wifiSsid = ssid;
    if (wifiMode) {
        [_statusMap setObject:wifiMode forKey:@"wifiOpMode"];
    }
    [_statusMap setObject:@(connected) forKey:@"staConnected"];
    if (ssid) {
        [_statusMap setObject:ssid forKey:@"staSSID"];
    }
    if ([self isCurrentQueryCommand:RadarQueryCommandWifiStatus]) {
        _hasWifiStatus = YES;
        [self advanceQueryPipeline];
    }
}

/**
 * 自定义数据响应处理 - 处理所有查询命令的响应
 */
- (void)blufi:(BlufiClient *)client didReceiveCustomData:(NSData *)data status:(BlufiStatusCode)status {
    if (data) {
        RDRLOG(@"didReceiveCustomData status=%d length=%lu", status, (unsigned long)data.length);
    } else {
        RDRLOG(@"didReceiveCustomData status=%d data=NULL", status);
    }
    if (status != StatusSuccess || !data) {
        //RDRLOG(@"Failed to receive custom data: status=%d", status);

        // 如果是状态查询失败，通知查询失败
        if (_queryCallback && !_isQueryComplete) {
            [self finishQuery:NO];
        }
        return;
    }

    // 将接收到的数据转换为字符串
    NSString *responseStr = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    RDRLOG(@"Received custom data raw: %@", responseStr);

    // 检查响应是否包含分隔符 ":"
    BOOL expectingOperateStatus = [self isCurrentQueryCommand:RadarQueryCommandOperateStatus];
    NSArray *parts = nil;
    NSInteger command = -1;
    
    if ([responseStr containsString:@":"]) {
        parts = [responseStr componentsSeparatedByString:@":"];
        command = [[parts objectAtIndex:0] integerValue];
    } else if (expectingOperateStatus) {
        NSString *trimmed = [responseStr stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length > 0) {
            [_statusMap setObject:trimmed forKey:@"radarRunStatus"];
            RDRLOG(@"Received operate status response (raw): %@", trimmed);
        }
        [self advanceQueryPipeline];
        return;
    } else {
        return;
    }

    // 根据命令类型处理响应
    switch (command) {
        case 12: // UID 查询响应
            // 查询和配置都可能使用这个命令
            if ((_queryCallback && !_isQueryComplete) || _isPreheatingForConfiguration) {
                [self handleUIDResponse:responseStr];
            }
            break;
            
        case 65: // MAC 地址查询响应
            // 主要用于查询
            if (_queryCallback && !_isQueryComplete) {
                [self handleMACResponse:responseStr];
            }
            break;
            
        case 62: // WiFi 状态查询响应
            // 主要用于查询
            if (_queryCallback && !_isQueryComplete) {
                [self handleWiFiStatusResponse:parts];
            }
            break;
            
        case 10: // 运行状态
            if (_queryCallback && !_isQueryComplete) {
                [self handleOperationStatusResponse:responseStr];
            }
            break;
            
        case 1:  // 服务器地址配置响应
        case 2:  // 服务器端口配置响应
        case 3:  // 额外命令响应
        case 8:  // 重启命令响应
            // 服务器配置相关响应
            if (_isConfiguring) {
                //RDRLOG(@"Received server configuration response: command=%ld, result=%@", 
                    //(long)command, parts.count > 1 ? parts[1] : @"unknown");
            }
            break;
            
        default:
            //RDRLOG(@"Unknown command response: %ld", (long)command);
            break;
    }
}



#pragma mark - BlufiDelegate 配置相关回调
/**
 * 设备状态响应回调 - ESP 标准 WiFi 状态查询
 */
- (void)blufi:(BlufiClient *)client didReceiveDeviceStatusResponse:(nullable BlufiStatusResponse *)response status:(BlufiStatusCode)status {
    //RDRLOG(@"Received device status response: %d", status);
    
    if (_queryCallback && !_isQueryComplete) {
        if (status == StatusSuccess && response) {
            // 记录设备信息
            // 更新 WiFi 模式
            NSString *wifiMode = @"Unknown";
            switch (response.opMode) {
                case OpModeNull:
                    [_statusMap setObject:@"NULL" forKey:@"wifiOpMode"];
                    wifiMode = @"NULL";
                    break;
                case OpModeSta:
                    [_statusMap setObject:@"STA" forKey:@"wifiOpMode"];
                    wifiMode = @"STA";
                    break;
                case OpModeSoftAP:
                    [_statusMap setObject:@"SOFTAP" forKey:@"wifiOpMode"];
                    wifiMode = @"SOFTAP";
                    break;
                case OpModeStaSoftAP:
                    [_statusMap setObject:@"STASOFTAP" forKey:@"wifiOpMode"];
                    wifiMode = @"STASOFTAP";
                    break;
                default:
                    [_statusMap setObject:[NSString stringWithFormat:@"UNKNOWN(%d)", response.opMode] forKey:@"wifiOpMode"];
                    wifiMode = [NSString stringWithFormat:@"UNKNOWN(%d)", response.opMode];
                    break;
            }
            
            // STA 模式信息
            if (response.opMode == OpModeSta || response.opMode == OpModeStaSoftAP) {
                BOOL isConnected = [response isStaConnectWiFi];
                [_statusMap setObject:@(isConnected) forKey:@"staConnected"];
                
                if (response.staSsid) {
                    [_statusMap setObject:response.staSsid forKey:@"staSSID"];
                }
                
                if (response.staBssid) {
                    [_statusMap setObject:response.staBssid forKey:@"staBSSID"];
                }
                
                //RDRLOG(@"STA Mode: connected=%@, SSID=%@", isConnected ? @"YES" : @"No", response.staSsid ?: @"unknow");
            }
            
            // AP 模式信息∫
            if (response.opMode == OpModeSoftAP || response.opMode == OpModeStaSoftAP) {
                if (response.softApSsid) {
                    [_statusMap setObject:response.softApSsid forKey:@"apSSID"];
                }
                
                [_statusMap setObject:[NSString stringWithFormat:@"%d", (int)response.softApSecurity] forKey:@"apSecurity"];
                [_statusMap setObject:[NSString stringWithFormat:@"%d", (int)response.softApChannel] forKey:@"apChannel"];
                [_statusMap setObject:[NSString stringWithFormat:@"%d", (int)response.softApConnectionCount] forKey:@"apConnCount"];
            }
            
            // 标记 WiFi 状态已获取
            _hasWifiStatus = YES;
            
            [self advanceQueryPipeline];
        } else {
            // WiFi 状态查询失败
            [_statusMap setObject:@"Failed to get status" forKey:@"wifiError"];
            
            //RDRLOG(@"Failed to get device WiFi status: %d", status);
            [self advanceQueryPipeline];
        }
    }
}

- (void)blufi:(BlufiClient *)client didReceiveDeviceScanResponse:(nullable NSArray<BlufiScanResponse *> *)scanResults status:(BlufiStatusCode)status {
    if (!_isScanningNearbyWiFi) {
        return;
    }
    if (status != StatusSuccess || !scanResults) {
        RDRLOG(@"Nearby Wi-Fi scan failed with status=%d", status);
        [self completeNearbyWiFiScanWithResults:nil success:NO];
        return;
    }
    
    BOOL shouldFinalize = NO;
    for (BlufiScanResponse *item in scanResults) {
        if (item.ssid.length > 0) {
            NSDictionary *entry = @{
                @"ssid": item.ssid ?: @"",
                @"rssi": @(item.rssi)
            };
            [_wifiScanResultsBuffer addObject:entry];
            RDRLOG(@"Nearby Wi-Fi scan result: ssid=%@ rssi=%d type=%d", item.ssid, item.rssi, item.type);
        }
        if (item.type == 0) {
            shouldFinalize = YES;
        }
    }
    
    if (shouldFinalize) {
        NSArray<NSDictionary *> *results = _wifiScanResultsBuffer.count > 0 ? [_wifiScanResultsBuffer copy] : @[];
        RDRLOG(@"Nearby Wi-Fi scan completed with %lu entries", (unsigned long)results.count);
        [self completeNearbyWiFiScanWithResults:results success:YES];
    } else {
        // 等待更多数据
    }
}

/**
 * 发送自定义数据结果回调
 */
- (void)blufi:(BlufiClient *)client didPostCustomData:(NSData *)data status:(BlufiStatusCode)status {
    //RDRLOG(@"Post custom data result: %d", status);
    
    if (status != StatusSuccess && _isConfiguring ) {
        // 发送失败，尝试重试
        _configRetryCount++;
        
    if (_configRetryCount < 3 && _isConfiguring) {
        //RDRLOG(@"Command failed, retry count: %ld", (long)_configRetryCount);
        
        // 可以添加一个简单的重试逻辑，如再次调用 sendServerConfiguration
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self->_isConfiguring) {
                // 重新发送配置命令
                [self sendServerConfiguration];
            }
        });
    }else {
            // 重试次数过多，报告失败
            [self configurationDidFailWithError:@"Failed to send command after multiple attempts"];
        }
    }
}

/**
 * 错误回调
 */
- (void)blufi:(BlufiClient *)client didReceiveError:(NSInteger)errCode {
    //RDRLOG(@"Received error: %ld", (long)errCode);
    
    _errorCount++;
    
    // 状态查询处理
    if (_queryCallback) {
        //RDRLOG(@"Query failed: Communication error: %ld", (long)errCode);
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_queryCallback(self->_currentDevice, NO);
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

#pragma mark - CBPeripheralDelegate Methods

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
    if (error) {
        //RDRLOG(@"Error discovering services: %@", [error localizedDescription]);
        return;
    }
    
    ////RDRLOG(@"Did discover services for peripheral: %@", peripheral.identifier.UUIDString);
    // BlufiClient会处理后续操作，这里不需要特别实现
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error {
    if (error) {
        //RDRLOG(@"Error discovering characteristics: %@", [error localizedDescription]);
        return;
    }
    
    ////RDRLOG(@"Did discover characteristics for service: %@", service.UUID.UUIDString);
    // BlufiClient会处理后续操作，这里不需要特别实现
}

- (void)peripheral:(CBPeripheral *)peripheral didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    if (error) {
        //RDRLOG(@"Error updating value for characteristic: %@", [error localizedDescription]);
        return;
    }
    
    // 特征值更新，通常由BlufiClient内部处理
}

- (void)peripheral:(CBPeripheral *)peripheral didWriteValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    if (error) {
        //RDRLOG(@"Error writing value for characteristic: %@", [error localizedDescription]);
        return;
    }
    
    // 写入特征值完成，通常由BlufiClient内部处理
}
@end
