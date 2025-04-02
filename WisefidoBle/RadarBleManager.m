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

// 日志宏定义
#define RDRLOG(fmt, ...) NSLog((@"[RadarBleManager] " fmt), ##__VA_ARGS__)

// 默认超时常量
#define DEFAULT_SCAN_TIMEOUT 15.0
#define DEFAULT_CONFIG_TIMEOUT 30.0
#define DEFAULT_CONNECT_TIMEOUT 10.0
#define DEFAULT_COMMAND_DELAY 1.0 // 延迟执行命令的时间
#define DEFAULT_QUERY_TIMEOUT 20.0

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
        RDRLOG("Lazy initializing BlufiClient for device: %@", _currentDevice.uuid);
        
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
        RDRLOG("Releasing BlufiClient instance");
        [_blufiClient close];
        _blufiClient = nil;
        _isConnected = NO;
    }
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
    RDRLOG(@"Error callback set successfully");
}

// 重置错误计数
- (void)resetErrorCount {
    _errorCount = 0;
}
#pragma mark - Public Methods - connectDevice/Disconnect
// 根据UUID获取peripheral对象
- (void)setCurrentDevice:(DeviceInfo *)device {
    if (!device || !device.uuid) {
        RDRLOG(@"Error: Invalid device information");
        if (_errorCallback) {
            _errorCallback(RadarBleErrorInvalidParameter, @"Invalid device information");
        }
        return;
    }
    
    // Check if already connected to this device
    if (_isConnected && _currentDevice && [_currentDevice.uuid isEqualToString:device.uuid]) {
        RDRLOG(@"Already connected to device: %@", device.deviceName);
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
        RDRLOG(@"Error: Invalid device information");
        if (_errorCallback) {
            _errorCallback(RadarBleErrorInvalidParameter, @"Invalid device information");
        }
        return;
    }
    
    // Check if already connected to this device
    if (_isConnected && _currentDevice && [_currentDevice.uuid isEqualToString:device.uuid]) {
        RDRLOG(@"Already connected to device: %@", device.deviceName);
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
      RDRLOG(@"Connecting to device UUID: %@", device.uuid);
    [_blufiClient connect:device.uuid]; // 关键：通过 UUID 发起连接
}

  - (void)disconnect {
      RDRLOG(@"Disconnecting device");

      // 清理 BlufiClient
      if (_blufiClient) {
          @try {
              [_blufiClient close];
          } @catch (NSException *exception) {
              RDRLOG(@"Exception during blufiClient close: %@", exception);
          }
          _blufiClient = nil;
      }

      // 清理资源
      _currentDevice = nil;
      _currentPeripheral = nil;
      _currentDeviceUUID = nil;

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

      // 重置状态
      _isConnected = NO;
      _isConfiguring = NO;
      _isQueryComplete = NO;
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
        // 保存过滤参数
    _currentFilterPrefix = filterPrefix;
    _currentFilterType = filterType;
    
    // 检查蓝牙状态
    if (_centralManager.state != CBManagerStatePoweredOn) {
        RDRLOG(@"Bluetooth not enabled, delay rescan");
        __weak typeof(self) weakSelf = self;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
                        if (!strongSelf) return;
            if (strongSelf.centralManager.state == CBManagerStatePoweredOn) {
                RDRLOG(@"after delay ble is ready,start  scan");
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
    RDRLOG(@"Starting scan: timeout=%.1fs",timeout);
    
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
        RDRLOG(@"Cached peripheral for UUID: %@", uuid);
    }

    // 打印详细日志
    RDRLOG(@"设备信息:");
    RDRLOG(@"Peripheral: %@", peripheral);
    RDRLOG(@"Peripheral name: %@", peripheral.name ?: @"nil");
    RDRLOG(@"Peripheral ID: %@", peripheral.identifier);
    RDRLOG(@"Peripheral state: %ld", (long)peripheral.state);
    RDRLOG(@"RSSI: %@", RSSI);
    
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
    RDRLOG(@"Starting device configuration for: %@", device.deviceName);
    
    // 参数验证
    if (!device || !device.uuid) {
        RDRLOG(@"Error: Invalid device information");
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
        RDRLOG(@"Device not connected, connecting first...");
        
        [self connectDevice:device];
        
        // 使用延迟执行，确保连接有时间完成
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self->_blufiClient) {
                // 进行安全协商
                [self->_blufiClient negotiateSecurity];
                
                // 等待安全协商完成，在回调中继续执行配置
                RDRLOG(@"Waiting for security negotiation to complete...");
            } else {
                // 连接失败
                RDRLOG(@"Failed to connect to device");
                [self configurationDidFailWithError:@"Failed to connect to device"];
            }
        });
    } else {
        // 设备已连接，直接进行安全协商
        RDRLOG(@"Device already connected, proceeding with security negotiation...");
        [_blufiClient negotiateSecurity];
    }
    
    // 注意：实际的配置操作将在didNegotiateSecurity回调中执行
}
/**
 * 安全协商结果回调 - 继续执行配置流程
 */
- (void)blufi:(BlufiClient *)client didNegotiateSecurity:(BlufiStatusCode)status {
    RDRLOG(@"Security negotiation result: %d", status);
    
    if (status != StatusSuccess) {
        // 安全协商失败
        _errorCount++;
        
        if (_errorCount < 2 && _isConfiguring) {
            // 最多重试一次
            RDRLOG(@"Security negotiation failed, retrying once...");
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
        if (_wifiSsid) {
            // 有WiFi配置，发送WiFi配置
            [self sendWifiConfiguration];
        } else if (_serverAddress) {
            // 只有服务器配置，发送服务器配置
            [self sendServerConfiguration];
        } else {
            // 没有有效的配置参数
            [self configurationDidFailWithError:@"No valid configuration parameters"];
        }
    } else if (_queryCallback) {
        // 查询设备状态
        [self sendUIDQuery];
    }
}

/**
 * 发送WiFi配置
 */
- (void)sendWifiConfiguration {
    RDRLOG(@"Sending WiFi configuration: SSID=%@", _wifiSsid);
    
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
    
    RDRLOG(@"Sending server configuration: %@:%ld", _serverAddress, (long)_serverPort);
    
    // 创建结果字典
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    [result setObject:_currentDevice.deviceId forKey:@"deviceId"];
    [result setObject:_currentDevice.uuid ?: @"" forKey:@"uuid"];
    
    // 发送服务器地址命令
    NSString *serverCmd = [NSString stringWithFormat:@"1:%@", _serverAddress];
    NSData *data = [serverCmd dataUsingEncoding:NSUTF8StringEncoding];
    
    if (data) {
        [_blufiClient postCustomData:data];
        RDRLOG(@"Server address command sent");
        
        // 延迟发送端口命令（等待地址命令处理完成）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            // 发送服务器端口命令
            NSString *portCmd = [NSString stringWithFormat:@"2:%ld", (long)self->_serverPort];
            NSData *portData = [portCmd dataUsingEncoding:NSUTF8StringEncoding];
            
            if (portData) {
                [self->_blufiClient postCustomData:portData];
                RDRLOG(@"Server port command sent");
                
                // 延迟发送其他命令
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    // 发送额外命令
                    [self->_blufiClient postCustomData:[@"3:0" dataUsingEncoding:NSUTF8StringEncoding]];
                    RDRLOG(@"Extra command sent");
                    
                    // 最后发送重启命令
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        [self->_blufiClient postCustomData:[@"8:" dataUsingEncoding:NSUTF8StringEncoding]];
                        RDRLOG(@"Restart command sent");
                        
                        // 假设命令都已成功发送，等待设备重启
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            // 配置完成，返回成功结果
                            [result setObject:@(YES) forKey:@"success"];
                            [result setObject:@"Server configuration completed" forKey:@"message"];
                            
                            if (self->_configCallback) {
                                dispatch_async(dispatch_get_main_queue(), ^{
                                    self->_configCallback(YES, result);
                                });
                            }
                            
                            // 清理状态
                            self->_isConfiguring = NO;
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
        RDRLOG(@"WiFi configuration successful");
        
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
            [_configTimer invalidate];
            _configTimer = nil;
        }
    } else {
        // 配置失败
        RDRLOG(@"WiFi configuration failed: %d", status);
        [result setObject:[NSString stringWithFormat:@"WiFi configuration failed: %d", status] forKey:@"error"];
        
        // 通知主界面
        if (_configCallback) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_configCallback(NO, result);
            });
        }
        
        // 清理状态
        _isConfiguring = NO;
        [_configTimer invalidate];
        _configTimer = nil;
    }
}

/**
 * 配置失败处理
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
    RDRLOG(@"Start querying device status for: %@, UUID: %@", device.deviceName, device.uuid);
    
    // 参数验证
    if (!device || !device.uuid) {
        RDRLOG(@"Error: Invalid device information");
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
    
    // 重置查询状态
    _isQueryComplete = NO;
    _hasWifiStatus = NO;
    _hasUID = NO;
    _hasMacAddress = NO;
    
    // 初始化状态字典
    _statusMap = [NSMutableDictionary dictionary];
    
    // 设置查询超时
    [_queryTimer invalidate];
    _queryTimer = [NSTimer scheduledTimerWithTimeInterval:DEFAULT_QUERY_TIMEOUT
                                                  target:self
                                                selector:@selector(queryTimedOut)
                                                userInfo:nil
                                                 repeats:NO];
    
    // 检查连接状态
    BOOL isDeviceConnected = (_isConnected && _blufiClient && 
                             [_currentDevice.uuid isEqualToString:device.uuid]);
    
    if (!isDeviceConnected) {
        // 设备未连接，先连接设备
        RDRLOG(@"Device not connected, connecting first...");
        
        [self connectDevice:device];
        
        // 使用延迟执行，确保连接有时间完成
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self->_blufiClient) {
                // 进行安全协商
                [self->_blufiClient negotiateSecurity];
                
                // 等待安全协商完成，在回调中继续执行查询
                RDRLOG(@"Waiting for security negotiation to complete...");
            } else {
                // 连接失败
                RDRLOG(@"Failed to connect to device");
                if (self->_queryCallback) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        self->_queryCallback(self->_currentDevice, NO);
                    });
                }
                
                // 清理状态
                [self->_queryTimer invalidate];
                self->_queryTimer = nil;
            }
        });
    } else {
        // 设备已连接，直接进行安全协商
        RDRLOG(@"Device already connected, proceeding with security negotiation...");
        [_blufiClient negotiateSecurity];
    }
    
    // 注意：实际的查询操作将在didNegotiateSecurity回调中执行
}


/**
 * 查询超时处理 
 */
- (void)queryTimedOut {
    RDRLOG(@"Query operation timed out");
    
    // 如果查询正在进行且未完成
    if (!_isQueryComplete) {
        RDRLOG(@"Query timeout, checking partial results...");
        
        // 检查是否有部分数据可用
        BOOL hasPartialData = (_hasUID || _hasMacAddress || _hasWifiStatus);
        
        if (hasPartialData) {
            RDRLOG(@"Some data available (UID:%d, MAC:%d, WiFi:%d), returning partial results",
                   _hasUID, _hasMacAddress, _hasWifiStatus);
            [self finishQuery:YES]; // 返回部分数据
        } else {
            RDRLOG(@"No data available, query failed");
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
    RDRLOG(@"Sending UID query command");
    NSData *uidCmd = [@"12:" dataUsingEncoding:NSUTF8StringEncoding];
    [_blufiClient postCustomData:uidCmd];
}

/**
 * 发送MAC地址查询命令
 */
- (void)sendMACQuery {
    RDRLOG(@"Sending MAC address query command");
    NSData *macCmd = [@"65:" dataUsingEncoding:NSUTF8StringEncoding];
    [_blufiClient postCustomData:macCmd];
}

/**
 * 发送 WiFi 状态查询命令 - 使用 ESP SDK 标准方法
 */
- (void)sendWiFiStatusQuery {
    RDRLOG(@"Requesting device WiFi status using standard BluFi method");
    [_blufiClient requestDeviceStatus];
    // 结果将在 didReceiveDeviceStatusResponse 回调中处理
    
    //radar self command
    //    NSData *wifiCmd = [@"62:" dataUsingEncoding:NSUTF8StringEncoding];
    //[_blufiClient postCustomData:wifiCmd];
}


/**
 * 处理查询完成
 * 更新设备信息并通知回调
 */
- (void)finishQuery:(BOOL)success {
    if (_isQueryComplete) return;
    
    _isQueryComplete = YES;
    
    // 更新设备信息
    if (success) {
        // 更新UID
        if (_statusMap[@"uid"]) {
            _currentDevice.uid = _statusMap[@"uid"];
        }
        
        // 更新MAC地址
        if (_statusMap[@"macAddress"]) {
            _currentDevice.macAddress = _statusMap[@"macAddress"];
        }
        
        // 更新WiFi状态
        if (_statusMap[@"wifiOpMode"]) {
            _currentDevice.wifiMode = _statusMap[@"wifiOpMode"];
        }
        
        if (_statusMap[@"staConnected"]) {
            _currentDevice.wifiConnected = [_statusMap[@"staConnected"] boolValue];
        }
        
        if (_statusMap[@"staSSID"]) {
            _currentDevice.wifiSsid = _statusMap[@"staSSID"];
        }
        
        // 更新时间戳
        _currentDevice.lastUpdateTime = [[NSDate date] timeIntervalSince1970];
    }
    
    // 通知回调
    if (_queryCallback) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_queryCallback(self->_currentDevice, success);
        });
    }
    
    // 清理状态
    [_queryTimer invalidate];
    _queryTimer = nil;
    _statusMap = nil;
}

/**
 * 处理UID响应
 */
- (void)handleUIDResponse:(NSString *)responseStr {
    NSArray *parts = [responseStr componentsSeparatedByString:@":"];
    if (parts.count >= 2) {
        NSString *uid = [parts objectAtIndex:1];
        uid = [uid stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        
        // 保存UID
        [_statusMap setObject:uid forKey:@"uid"];
        _hasUID = YES;
        
        RDRLOG(@"Received device UID: %@", uid);
        
        // 继续查询MAC地址
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self sendMACQuery];
        });
    } else {
        RDRLOG(@"Invalid UID response format");
        
        // 继续查询MAC地址，不中断流程
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self sendMACQuery];
        });
    }
}

/**
 * 处理MAC地址响应
 */
- (void)handleMACResponse:(NSString *)responseStr {
    NSArray *parts = [responseStr componentsSeparatedByString:@":"];
    if (parts.count >= 3 && [@"0" isEqualToString:[parts objectAtIndex:1]]) {
        NSString *macAddress = [parts objectAtIndex:2];
        macAddress = [macAddress stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        
        // 保存MAC地址
        [_statusMap setObject:macAddress forKey:@"macAddress"];
        _hasMacAddress = YES;
        
        RDRLOG(@"Received device MAC address: %@", macAddress);
        
        // 继续查询WiFi状态
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self sendWiFiStatusQuery];
        });
    } else {
        RDRLOG(@"Invalid MAC address response format");
        
        // 继续查询WiFi状态，不中断流程
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self sendWiFiStatusQuery];
        });
    }
}

/**
 * 处理WiFi状态响应
 */
- (void)handleWiFiStatusResponse:(NSArray *)parts {
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
        
        RDRLOG(@"Received WiFi status: mode=%@, connected=%d, SSID=%@", wifiMode, connected, ssid ?: @"Unknown");
        
        // 查询完成，通知结果
        [self finishQuery:YES];
    } else {
        RDRLOG(@"Invalid WiFi status response format");
        
        // 查询不完整，但仍然返回结果
        [self finishQuery:(_hasUID || _hasMacAddress)];
    }
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
    if (_queryCallback) {
        dispatch_async(dispatch_get_main_queue(), ^{
            RDRLOG(@"Query completed, notifying main thread.");
            self->_queryCallback(self->_currentDevice, YES);
            self->_queryCallback = nil;
        });
    }
    
    // 断开连接
    //[self disconnect];
	RDRLOG(@"Query completed, keeping connection active until timeout.");
}

/**
 * 自定义数据响应处理 - 处理所有查询命令的响应
 */
- (void)blufi:(BlufiClient *)client didReceiveCustomData:(NSData *)data status:(BlufiStatusCode)status {
    if (status != StatusSuccess || !data) {
        RDRLOG(@"Failed to receive custom data: status=%d", status);

        // 如果是状态查询失败，通知查询失败
        if (_queryCallback && !_isQueryComplete) {
            [self finishQuery:NO];
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
            // 查询和配置都可能使用这个命令
            if (_queryCallback && !_isQueryComplete) {
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
            
        case 1:  // 服务器地址配置响应
        case 2:  // 服务器端口配置响应
        case 3:  // 额外命令响应
        case 8:  // 重启命令响应
            // 服务器配置相关响应
            if (_isConfiguring) {
                RDRLOG(@"Received server configuration response: command=%ld, result=%@", 
                    (long)command, parts.count > 1 ? parts[1] : @"unknown");
            }
            break;
            
        default:
            RDRLOG(@"Unknown command response: %ld", (long)command);
            break;
    }
}



#pragma mark - BlufiDelegate 配置相关回调
/**
 * 设备状态响应回调 - ESP 标准 WiFi 状态查询
 */
- (void)blufi:(BlufiClient *)client didReceiveDeviceStatusResponse:(nullable BlufiStatusResponse *)response status:(BlufiStatusCode)status {
    RDRLOG(@"Received device status response: %d", status);
    
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
                
                RDRLOG(@"STA Mode: connected=%@, SSID=%@", 
                      isConnected ? @"YES" : @"No", 
                      response.staSsid ?: @"unknow");
            }
            
            // AP 模式信息
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
            
            // 查询完成，返回结果
            [self finishQuery:YES];
        } else {
            // WiFi 状态查询失败
            [_statusMap setObject:@"Failed to get status" forKey:@"wifiError"];
            
            RDRLOG(@"Failed to get device WiFi status: %d", status);
            
            // 查询不完整，但仍然尝试返回部分结果
            [self finishQuery:(_hasUID || _hasMacAddress)];
        }
    }
}

/**
 * 发送自定义数据结果回调
 */
- (void)blufi:(BlufiClient *)client didPostCustomData:(NSData *)data status:(BlufiStatusCode)status {
    RDRLOG(@"Post custom data result: %d", status);
    
    if (status != StatusSuccess && _isConfiguring ) {
        // 发送失败，尝试重试
        _configRetryCount++;
        
    if (_configRetryCount < 3 && _isConfiguring) {
        RDRLOG(@"Command failed, retry count: %ld", (long)_configRetryCount);
        
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
    RDRLOG(@"Received error: %ld", (long)errCode);
    
    _errorCount++;
    
    // 状态查询处理
    if (_queryCallback) {
        RDRLOG(@"Query failed: Communication error: %ld", (long)errCode);
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
        RDRLOG(@"Error discovering services: %@", [error localizedDescription]);
        return;
    }
    
    RDRLOG(@"Did discover services for peripheral: %@", peripheral.identifier.UUIDString);
    // BlufiClient会处理后续操作，这里不需要特别实现
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error {
    if (error) {
        RDRLOG(@"Error discovering characteristics: %@", [error localizedDescription]);
        return;
    }
    
    RDRLOG(@"Did discover characteristics for service: %@", service.UUID.UUIDString);
    // BlufiClient会处理后续操作，这里不需要特别实现
}

- (void)peripheral:(CBPeripheral *)peripheral didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    if (error) {
        RDRLOG(@"Error updating value for characteristic: %@", [error localizedDescription]);
        return;
    }
    
    // 特征值更新，通常由BlufiClient内部处理
}

- (void)peripheral:(CBPeripheral *)peripheral didWriteValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    if (error) {
        RDRLOG(@"Error writing value for characteristic: %@", [error localizedDescription]);
        return;
    }
    
    // 写入特征值完成，通常由BlufiClient内部处理
}
@end
