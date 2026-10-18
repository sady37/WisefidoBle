//
//  SleepaceBm8701TlsConfigurator.h
//
//  Sleepace BM8701_2 睡眠垫 BLE TLS 配网器（方案 B：绕过 Sleepace iOS SDK，
//  自行实现 SocketFrame-over-BLE 协议）。协议细节见
//  docs/kimi3_sleepace_bm8701_2_tls.md。
//

#import <Foundation/Foundation.h>
#import <CoreBluetooth/CoreBluetooth.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const SleepaceBm8701ErrorDomain;

// 错误码与 Android SDK 对齐（-1 断连 / -2 超时 / -3 失败 / -4 蓝牙关闭 / -5 参数错误）
typedef NS_ERROR_ENUM(SleepaceBm8701ErrorDomain, SleepaceBm8701Error) {
    SleepaceBm8701ErrorBluetoothOff   = -4,
    SleepaceBm8701ErrorParameter      = -5,
    SleepaceBm8701ErrorDisconnected   = -1,
    SleepaceBm8701ErrorTimeout        = -2,
    SleepaceBm8701ErrorFailed         = -3,
    SleepaceBm8701ErrorServiceMissing = -10, // FFE0/FFE5 或 FFE4/FFE9 未找到
    SleepaceBm8701ErrorConnectFailed  = -11,
    SleepaceBm8701ErrorCancelled      = -12,
};

typedef NS_ENUM(NSInteger, SleepaceBm8701Step) {
    SleepaceBm8701StepConnecting = 0,   // 连接 + 服务发现 + 订阅
    SleepaceBm8701StepGetDeviceInfo,    // 0x0202 获取设备信息
    SleepaceBm8701StepSetServer,        // 0x03A2 设置服务器地址（36 字节，含 TLS 槽位）
    SleepaceBm8701StepSetWiFi,          // 0x03A0 设置 WiFi（120 字节）
    SleepaceBm8701StepGetWiFi,          // 0x03A1 读取 WiFi 设置（仅查询模式）
    SleepaceBm8701StepDone,
};

// completion 的 info 字典键：
//   @"deviceId"     NSString，设备返回的 13 位设备号（如 BM87224601903）
//   @"version"      NSString，固件版本 "%.2f"
//   @"failedStep"   NSNumber(SleepaceBm8701Step)，失败时存在
//   @"deviceStatus" NSNumber(u16)，设备应答状态非 0 时存在
// 查询模式（queryWiFiWithCompletion:）额外返回：
//   @"ssid" @"password" NSString；@"ipType" NSString（"0"=DHCP）；
//   @"staticIp" @"subnetMask" @"gateway" NSString（静态 IP 时有意义）
typedef void (^SleepaceBm8701Completion)(BOOL success,
                                         NSDictionary *info,
                                         NSError * _Nullable error);

@interface SleepaceBm8701TlsConfigurator : NSObject

/// 用扫描阶段拿到的 peripheral identifier 初始化（内部自建私有 CBCentralManager，
/// 不占用 Sleepace SDK 的 CBPeripheral 对象）
- (instancetype)initWithPeripheralIdentifier:(NSUUID *)identifier;

/// 完整流程：连接 -> 0x0202 -> 0x03A2 -> 0x03A0 -> 断开，结果在主线程回调一次。
/// staticIp/mask/gateway 全为 nil 表示 DHCP；ssid 为 nil 表示仅配置服务器（跳过 setWifi）。
- (void)configureWithServerAddress:(NSString *)serverAddress
                              port:(uint16_t)port
                               tls:(BOOL)tls
                              ssid:(nullable NSString *)ssid
                          password:(nullable NSString *)password
                          staticIp:(nullable NSString *)staticIp
                        subnetMask:(nullable NSString *)subnetMask
                           gateway:(nullable NSString *)gateway
                          progress:(nullable void (^)(SleepaceBm8701Step step))progress
                        completion:(SleepaceBm8701Completion)completion;

/// 查询：连接 -> 0x0202 -> 0x03A1 读取 WiFi 设置 -> 断开（与 Android SDK bleWiFiConfigGet 相同命令）。
/// 设备协议里没有已确认的服务器地址读取命令，查不到服务器 / TLS。
- (void)queryWiFiWithCompletion:(SleepaceBm8701Completion)completion;

- (void)cancel;

#pragma mark - 纯函数（无 BLE 依赖，可独立单元测试）

/// 组 SocketFrame 请求帧（15 字节头 + content + CRC32 + "$_@-"）
+ (NSData *)frameWithMessageType:(uint16_t)msgType sequence:(uint16_t)seq content:(nullable NSData *)content;

/// 0x03A2 payload（36 字节）：地址 32 字节零填充 + 明文端口槽 + TLS 端口槽
+ (nullable NSData *)serverPayloadWithAddress:(NSString *)address
                                         port:(uint16_t)port
                                          tls:(BOOL)tls
                                        error:(NSError **)error;

/// 0x03A0 payload（120 字节）：SSID 33 + 密码标志 1 + 密码 65 + IP 类型 1 + IP/掩码/网关/保留
+ (nullable NSData *)wifiPayloadWithSSID:(NSData *)ssid
                                password:(nullable NSString *)password
                                staticIp:(nullable NSString *)ip
                                    mask:(nullable NSString *)mask
                                 gateway:(nullable NSString *)gw
                                   error:(NSError **)error;

/// 标准 CRC-32 (IEEE 802.3 / zlib)：init/xorout 0xFFFFFFFF，poly 0xEDB88320
+ (uint32_t)crc32:(NSData *)data;

/// 流式帧解析：在 buffer 中查找 "$_@-" 结束标记并校验 CRC，
/// 成功返回 @{frameType, frameSeq, msgType, content} 并从 buffer 移除该帧；
/// 数据不完整返回 nil；CRC 错误丢弃到标记处后继续。兼容 15/19 字节两种头。
+ (nullable NSDictionary *)extractFrameFromBuffer:(NSMutableData *)buffer;

/// 十六进制打印（与 Android 日志对照用）
+ (NSString *)hexString:(nullable NSData *)data;

@end

NS_ASSUME_NONNULL_END
