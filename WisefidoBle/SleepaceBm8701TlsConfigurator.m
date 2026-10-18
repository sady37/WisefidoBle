//
//  SleepaceBm8701TlsConfigurator.m
//
//  实现见 docs/kimi3_sleepace_bm8701_2_tls.md（Android SDK 字节码逆向结果）。
//  传输：Sleepace SocketFrame（TCP 帧格式）隧道在 BLE 上，20 字节分包写 FFE9，
//  FFE4 接收通知，"$@_-" 结束标记 + CRC32 校验，按 frameSeq 匹配应答。
//

#import "SleepaceBm8701TlsConfigurator.h"

// 日志宏，带前缀方便与 Android SdkLog 对照
#define BM8701TLSLOG(fmt, ...) NSLog((@"[BM8701TLS] " fmt), ##__VA_ARGS__)

// 协议常量（文档第 3-5 节）
static const NSTimeInterval kConnectTimeout     = 10.0; // 连接超时（Android CONNECT_TIMEOUT）
static const NSTimeInterval kScanTimeout        = 6.0;  // retrieve 失败后的短扫描
static const NSTimeInterval kRequestTimeout     = 3.0;  // 单请求应答超时（Android 3000ms）
static const NSTimeInterval kRetryGap           = 0.1;  // 重试间隔 100ms
static const NSUInteger     kMaxInfoAttempts    = 3;    // 0x0202 最多 3 次
static const NSTimeInterval kPostNotifyDelay    = 0.7;  // 订阅后 200ms + 连接后 500ms
static const NSTimeInterval kSuccessDisconnectDelay = 0.4; // 成功后延时断开
static const NSUInteger     kBleChunkSize       = 20;   // BLE 写包固定 20 字节

static const uint8_t kFrameEndBytes[4] = {'$', '_', '@', '-'}; // "$_@-" 结束标记

// msgType（文档第 5 节，getMsgType(BM8701_2) = {514, 930, 928}）
static const uint16_t kMsgGetDeviceInfo = 0x0202;
static const uint16_t kMsgSetServer     = 0x03A2;
static const uint16_t kMsgSetWiFi       = 0x03A0;
static const uint16_t kMsgGetWiFi       = 0x03A1;

// 内部状态机
typedef NS_ENUM(NSInteger, Bm8701State) {
    Bm8701StateIdle = 0,
    Bm8701StateWaitPoweredOn,
    Bm8701StateScanning,
    Bm8701StateConnecting,
    Bm8701StateDiscovering,
    Bm8701StateEnablingNotify,
    Bm8701StateGetDeviceInfo,
    Bm8701StateSetServer,
    Bm8701StateSetWiFi,
    Bm8701StateGetWiFi,
    Bm8701StateFinished,
};

NSErrorDomain const SleepaceBm8701ErrorDomain = @"SleepaceBm8701ErrorDomain";

@interface SleepaceBm8701TlsConfigurator () <CBCentralManagerDelegate, CBPeripheralDelegate>

// BLE 对象（私有 central，所有回调在 _queue 串行队列上）
@property (nonatomic, strong) CBCentralManager *central;
@property (nonatomic, strong) CBPeripheral *peripheral;
@property (nonatomic, strong) CBCharacteristic *notifyChar;  // FFE4
@property (nonatomic, strong) CBCharacteristic *writeChar;   // FFE9
@property (nonatomic, strong) NSUUID *identifier;
@property (nonatomic, strong) dispatch_queue_t queue;

// 配置参数与回调
@property (nonatomic, copy) NSString *serverAddress;
@property (nonatomic, assign) uint16_t port;
@property (nonatomic, assign) BOOL tls;
@property (nonatomic, copy, nullable) NSString *ssid;
@property (nonatomic, copy, nullable) NSString *password;
@property (nonatomic, copy, nullable) NSString *staticIp;
@property (nonatomic, copy, nullable) NSString *subnetMask;
@property (nonatomic, copy, nullable) NSString *gateway;
@property (nonatomic, copy, nullable) void (^progress)(SleepaceBm8701Step step);
@property (nonatomic, copy, nullable) SleepaceBm8701Completion completion;

// 预先构造好的 payload（configure 时构造，参数错误提前失败）
@property (nonatomic, strong) NSData *serverPayload;
@property (nonatomic, strong, nullable) NSData *wifiPayload;

// 运行状态
@property (nonatomic, assign) Bm8701State state;
@property (nonatomic, assign) BOOL finished;
@property (nonatomic, assign) BOOL queryMode; // YES = 只读 WiFi 设置，不下发配置
@property (nonatomic, assign) uint16_t nextSeq;     // 帧序号，从 1 开始
@property (nonatomic, assign) uint16_t pendingSeq;  // 等待应答的 seq
@property (nonatomic, assign) NSUInteger infoAttempt;
@property (nonatomic, assign) NSUInteger requestEpoch; // 请求代际，用于取消旧超时
@property (nonatomic, strong) NSMutableData *rxBuffer;

// 发送队列（20 字节分包）
@property (nonatomic, strong) NSArray<NSData *> *txChunks;
@property (nonatomic, assign) NSUInteger txChunkIndex;
@property (nonatomic, assign) BOOL writeWithoutResponse;
@property (nonatomic, assign) BOOL waitingWriteReady;

// 结果
@property (nonatomic, copy, nullable) NSString *deviceId;
@property (nonatomic, copy, nullable) NSString *version;

@end

@implementation SleepaceBm8701TlsConfigurator

#pragma mark - 初始化

- (instancetype)initWithPeripheralIdentifier:(NSUUID *)identifier {
    self = [super init];
    if (self) {
        _identifier = identifier;
        _queue = dispatch_queue_create("com.wisefido.bm8701tls", DISPATCH_QUEUE_SERIAL);
        _rxBuffer = [NSMutableData data];
        _nextSeq = 0;
    }
    return self;
}

#pragma mark - 对外接口

- (void)configureWithServerAddress:(NSString *)serverAddress
                              port:(uint16_t)port
                               tls:(BOOL)tls
                              ssid:(nullable NSString *)ssid
                          password:(nullable NSString *)password
                          staticIp:(nullable NSString *)staticIp
                        subnetMask:(nullable NSString *)subnetMask
                           gateway:(nullable NSString *)gateway
                          progress:(nullable void (^)(SleepaceBm8701Step step))progress
                        completion:(SleepaceBm8701Completion)completion {
    NSParameterAssert(completion);
    _serverAddress = serverAddress;
    _port = port;
    _tls = tls;
    _ssid = ssid;
    _password = password;
    _staticIp = staticIp;
    _subnetMask = subnetMask;
    _gateway = gateway;
    _progress = progress;
    _completion = completion;

    // 参数提前构造，失败直接回调（对应 Android status -5）
    NSError *err = nil;
    _serverPayload = [[self class] serverPayloadWithAddress:serverAddress port:port tls:tls error:&err];
    if (!_serverPayload) {
        BM8701TLSLOG(@"setNet 参数错误: %@", err.localizedDescription);
        [self finishSuccess:NO info:@{@"failedStep": @(SleepaceBm8701StepSetServer)} error:err];
        return;
    }
    BM8701TLSLOG(@"setNet payload(%luB): %@", (unsigned long)_serverPayload.length,
                 [[self class] hexString:_serverPayload]);

    if (ssid) {
        NSData *ssidData = [ssid dataUsingEncoding:NSUTF8StringEncoding];
        _wifiPayload = [[self class] wifiPayloadWithSSID:ssidData password:password
                                                staticIp:staticIp mask:subnetMask gateway:gateway error:&err];
        if (!_wifiPayload) {
            BM8701TLSLOG(@"setWiFi 参数错误: %@", err.localizedDescription);
            [self finishSuccess:NO info:@{@"failedStep": @(SleepaceBm8701StepSetWiFi)} error:err];
            return;
        }
    } else {
        _wifiPayload = nil; // 仅配置服务器模式（Android：ssidRaw == null 时跳过 setWifi）
    }

    [self reportProgress:SleepaceBm8701StepConnecting];
    _state = Bm8701StateWaitPoweredOn;
    // 自建私有 CBCentralManager（SDK 的 CBPeripheral 属于 SDK 的 central，不能复用）
    _central = [[CBCentralManager alloc] initWithDelegate:self queue:_queue];
}

- (void)queryWiFiWithCompletion:(SleepaceBm8701Completion)completion {
    NSParameterAssert(completion);
    _queryMode = YES;
    _completion = completion;
    [self reportProgress:SleepaceBm8701StepConnecting];
    _state = Bm8701StateWaitPoweredOn;
    _central = [[CBCentralManager alloc] initWithDelegate:self queue:_queue];
}

- (void)cancel {
    dispatch_async(self.queue, ^{
        if (self.finished) return;
        BM8701TLSLOG(@"cancel");
        [self failWithCode:SleepaceBm8701ErrorCancelled message:@"cancelled by caller" step:self.currentStep];
    });
}

- (SleepaceBm8701Step)currentStep {
    switch (_state) {
        case Bm8701StateGetDeviceInfo: return SleepaceBm8701StepGetDeviceInfo;
        case Bm8701StateSetServer:     return SleepaceBm8701StepSetServer;
        case Bm8701StateSetWiFi:       return SleepaceBm8701StepSetWiFi;
        case Bm8701StateGetWiFi:       return SleepaceBm8701StepGetWiFi;
        default:                       return SleepaceBm8701StepConnecting;
    }
}

#pragma mark - 纯函数：大端写入辅助

static void PutU16BE(NSMutableData *d, uint16_t v) {
    uint8_t b[2] = {(uint8_t)(v >> 8), (uint8_t)(v & 0xFF)};
    [d appendBytes:b length:2];
}

static void PutU32BE(NSMutableData *d, uint32_t v) {
    uint8_t b[4] = {(uint8_t)(v >> 24), (uint8_t)(v >> 16), (uint8_t)(v >> 8), (uint8_t)v};
    [d appendBytes:b length:4];
}

+ (uint32_t)crc32:(NSData *)data {
    const uint8_t *p = data.bytes;
    size_t n = data.length;
    uint32_t c = 0xFFFFFFFFu;
    for (size_t i = 0; i < n; i++) {
        c ^= p[i];
        for (int k = 0; k < 8; k++) {
            c = (c >> 1) ^ (0xEDB88320u & (uint32_t)-(int32_t)(c & 1));
        }
    }
    return c ^ 0xFFFFFFFFu;
}

+ (NSData *)frameWithMessageType:(uint16_t)msgType sequence:(uint16_t)seq content:(NSData *)content {
    NSMutableData *f = [NSMutableData data];
    uint8_t head[2] = {0x00 /* versionCode */, 0x01 /* from */};
    [f appendBytes:head length:2];
    PutU32BE(f, 0);        // gallery（channel），请求时恒为 0
    uint8_t frameType = 0x02; // 请求
    [f appendBytes:&frameType length:1];
    PutU16BE(f, 1);        // frameCount：单分片
    PutU16BE(f, 0);        // frameNum
    PutU16BE(f, seq);      // frameSeq
    PutU16BE(f, msgType);  // deviceType == 0，故无 0xC350/deviceType 字段
    if (content) [f appendData:content];
    PutU32BE(f, [self crc32:f]);
    [f appendBytes:kFrameEndBytes length:4];
    return f;
}

// 检查输入是否包含 "$_@-"（避免触发 Android createFrames 的分片逻辑，直接拒绝）
+ (BOOL)containsFrameEnd:(NSData *)data {
    if (data.length < 4) return NO;
    NSData *marker = [NSData dataWithBytes:kFrameEndBytes length:4];
    return [data rangeOfData:marker options:0 range:NSMakeRange(0, data.length)].location != NSNotFound;
}

+ (NSError *)paramError:(NSString *)msg {
    return [NSError errorWithDomain:SleepaceBm8701ErrorDomain
                               code:SleepaceBm8701ErrorParameter
                           userInfo:@{NSLocalizedDescriptionKey: msg}];
}

+ (NSData *)serverPayloadWithAddress:(NSString *)address
                                port:(uint16_t)port
                                 tls:(BOOL)tls
                               error:(NSError **)error {
    NSData *a = [address dataUsingEncoding:NSUTF8StringEncoding];
    if (a.length == 0 || a.length > 32) {
        if (error) *error = [self paramError:@"server address must be 1..32 UTF-8 bytes"];
        return nil;
    }
    if (port == 0) {
        if (error) *error = [self paramError:@"server port must be 1..65535"];
        return nil;
    }
    if ([self containsFrameEnd:a]) {
        if (error) *error = [self paramError:@"server address must not contain \"$_@-\""];
        return nil;
    }
    NSMutableData *p = [NSMutableData dataWithLength:36];
    uint8_t *b = p.mutableBytes;
    memcpy(b, a.bytes, a.length);
    // 明文端口槽在 [32..33]，TLS 端口槽在 [34..35]，另一槽保持 00 00
    uint8_t *slot = tls ? b + 34 : b + 32;
    slot[0] = (uint8_t)(port >> 8);
    slot[1] = (uint8_t)(port & 0xFF);
    return p;
}

// 解析 "a.b.c.d" 为 4 字节，失败返回 NO
static BOOL ParseIPv4(NSString *s, uint8_t *out4) {
    NSArray<NSString *> *parts = [s componentsSeparatedByString:@"."];
    if (parts.count != 4) return NO;
    for (int i = 0; i < 4; i++) {
        NSScanner *sc = [NSScanner scannerWithString:parts[i]];
        NSInteger v = 0;
        if (![sc scanInteger:&v] || !sc.isAtEnd || v < 0 || v > 255) return NO;
        out4[i] = (uint8_t)v;
    }
    return YES;
}

+ (NSData *)wifiPayloadWithSSID:(NSData *)ssid
                       password:(NSString *)password
                       staticIp:(NSString *)ip
                           mask:(NSString *)mask
                        gateway:(NSString *)gw
                          error:(NSError **)error {
    NSData *pw = [(password ?: @"") dataUsingEncoding:NSUTF8StringEncoding];
    if (ssid.length == 0 || ssid.length > 32) {
        if (error) *error = [self paramError:@"ssid must be 1..32 bytes"];
        return nil;
    }
    if (pw.length > 64) {
        if (error) *error = [self paramError:@"password must be <= 64 UTF-8 bytes"];
        return nil;
    }
    if ([self containsFrameEnd:ssid] || [self containsFrameEnd:pw]) {
        if (error) *error = [self paramError:@"ssid/password must not contain \"$_@-\""];
        return nil;
    }
    NSMutableData *p = [NSMutableData dataWithLength:120];
    uint8_t *b = p.mutableBytes;
    memcpy(b, ssid.bytes, ssid.length);      // [0..32] SSID
    b[33] = pw.length ? 1 : 0;               // [33] 密码标志
    memcpy(b + 34, pw.bytes, pw.length);     // [34..98] 密码
    if (ip.length) {
        // 静态 IP：掩码和网关必须同时有效
        b[99] = 1;
        if (!ParseIPv4(ip, b + 100) || !ParseIPv4(mask, b + 104) || !ParseIPv4(gw, b + 108)) {
            if (error) *error = [self paramError:@"invalid static ip/mask/gateway"];
            return nil;
        }
    } // 否则 DHCP：b[99] = 0，[100..119] 全零
    return p;
}

+ (NSString *)hexString:(NSData *)data {
    if (!data.length) return @"(empty)";
    const uint8_t *b = data.bytes;
    NSMutableString *s = [NSMutableString stringWithCapacity:data.length * 3];
    for (NSUInteger i = 0; i < data.length; i++) {
        [s appendFormat:@"%s%02X", i ? " " : "", b[i]];
    }
    return s;
}

#pragma mark - 纯函数：帧解析

+ (NSDictionary *)extractFrameFromBuffer:(NSMutableData *)buffer {
    NSData *marker = [NSData dataWithBytes:kFrameEndBytes length:4];
    while (YES) {
        NSRange r = [buffer rangeOfData:marker options:0 range:NSMakeRange(0, buffer.length)];
        if (r.location == NSNotFound) return nil; // 数据不完整，等更多通知

        NSUInteger frameLen = r.location + 4; // 候选帧全长（含标记）
        if (frameLen <= 8) {
            // 太短不可能是合法帧，丢弃到标记处继续找
            [buffer replaceBytesInRange:NSMakeRange(0, frameLen) withBytes:NULL length:0];
            continue;
        }
        NSData *frame = [buffer subdataWithRange:NSMakeRange(0, frameLen)];
        const uint8_t *b = frame.bytes;
        // CRC 校验：覆盖 [0, len-8)，与 [len-8, len-4) 的 BE u32 比较
        uint32_t expect = ((uint32_t)b[frameLen - 8] << 24) | ((uint32_t)b[frameLen - 7] << 16) |
                          ((uint32_t)b[frameLen - 6] << 8)  | (uint32_t)b[frameLen - 5];
        uint32_t actual = [self crc32:[frame subdataWithRange:NSMakeRange(0, frameLen - 8)]];
        if (expect != actual) {
            BM8701TLSLOG(@"CRC mismatch (expect %08X actual %08X)，丢弃该候选帧", expect, actual);
            [buffer replaceBytesInRange:NSMakeRange(0, frameLen) withBytes:NULL length:0];
            continue;
        }
        // 解析头：兼容 15 字节（无 0xC350）与 19 字节（有 0xC350 + deviceType）两种
        NSUInteger headerLen;
        uint16_t msgType;
        if (frameLen >= 19 && b[13] == 0xC3 && b[14] == 0x50) {
            headerLen = 19;
            msgType = ((uint16_t)b[17] << 8) | b[18];
        } else {
            headerLen = 15;
            msgType = ((uint16_t)b[13] << 8) | b[14];
        }
        if (frameLen < headerLen + 8) {
            [buffer replaceBytesInRange:NSMakeRange(0, frameLen) withBytes:NULL length:0];
            continue;
        }
        NSDictionary *result = @{
            @"frameType": @(b[6]),
            @"frameSeq":  @(((uint16_t)b[11] << 8) | b[12]),
            @"msgType":   @(msgType),
            @"content":   [frame subdataWithRange:NSMakeRange(headerLen, frameLen - 8 - headerLen)],
        };
        [buffer replaceBytesInRange:NSMakeRange(0, frameLen) withBytes:NULL length:0];
        return result;
    }
}

#pragma mark - CBCentralManagerDelegate

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    if (self.finished) return;
    BM8701TLSLOG(@"central state: %ld", (long)central.state);
    if (central.state == CBManagerStatePoweredOn) {
        if (self.state != Bm8701StateWaitPoweredOn) return;
        // 先尝试按 identifier 直接找回外设
        NSArray *found = [central retrievePeripheralsWithIdentifiers:@[self.identifier]];
        if (found.firstObject) {
            self.peripheral = found.firstObject;
            [self connectPeripheral];
        } else {
            // 找不到则短扫描（按 FFE0 服务过滤），按 identifier 匹配
            BM8701TLSLOG(@"retrieve 未命中，开始短扫描");
            self.state = Bm8701StateScanning;
            [central scanForPeripheralsWithServices:@[[CBUUID UUIDWithString:@"FFE0"]] options:nil];
            [self armTimeout:kScanTimeout handler:^{
                [self.central stopScan];
                [self failWithCode:SleepaceBm8701ErrorConnectFailed
                           message:@"peripheral not found" step:SleepaceBm8701StepConnecting];
            }];
        }
    } else if (central.state == CBManagerStatePoweredOff) {
        [self failWithCode:SleepaceBm8701ErrorBluetoothOff message:@"bluetooth powered off" step:self.currentStep];
    } else if (central.state == CBManagerStateUnauthorized) {
        [self failWithCode:SleepaceBm8701ErrorBluetoothOff message:@"bluetooth unauthorized" step:self.currentStep];
    }
}

- (void)centralManager:(CBCentralManager *)central
  didDiscoverPeripheral:(CBPeripheral *)peripheral
      advertisementData:(NSDictionary *)advertisementData
                   RSSI:(NSNumber *)RSSI {
    if (self.finished || self.state != Bm8701StateScanning) return;
    if (![peripheral.identifier isEqual:self.identifier]) return;
    BM8701TLSLOG(@"扫描命中: %@", peripheral.name);
    [central stopScan];
    self.requestEpoch++; // 取消扫描超时
    self.peripheral = peripheral;
    [self connectPeripheral];
}

- (void)connectPeripheral {
    self.state = Bm8701StateConnecting;
    self.peripheral.delegate = self;
    [self.central connectPeripheral:self.peripheral options:nil];
    BM8701TLSLOG(@"connecting %@", self.peripheral.identifier);
    [self armTimeout:kConnectTimeout handler:^{
        [self failWithCode:SleepaceBm8701ErrorConnectFailed message:@"connect timeout" step:SleepaceBm8701StepConnecting];
    }];
}

- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral {
    if (self.finished) return;
    BM8701TLSLOG(@"connected");
    self.requestEpoch++; // 取消连接超时
    self.state = Bm8701StateDiscovering;
    // 不请求 MTU（Android 默认 mtu=20），直接发现两个服务
    [peripheral discoverServices:@[[CBUUID UUIDWithString:@"FFE0"], [CBUUID UUIDWithString:@"FFE5"]]];
}

- (void)centralManager:(CBCentralManager *)central didFailToConnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    if (self.finished) return;
    BM8701TLSLOG(@"connect failed: %@", error);
    [self failWithCode:SleepaceBm8701ErrorConnectFailed
               message:[NSString stringWithFormat:@"connect failed: %@", error.localizedDescription]
                  step:SleepaceBm8701StepConnecting];
}

- (void)centralManager:(CBCentralManager *)central didDisconnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    if (self.finished) return; // 成功后主动断开，忽略
    BM8701TLSLOG(@"disconnected: %@", error);
    [self failWithCode:SleepaceBm8701ErrorDisconnected message:@"device disconnected" step:self.currentStep];
}

#pragma mark - CBPeripheralDelegate：服务发现与订阅

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
    if (self.finished) return;
    if (error) {
        [self failWithCode:SleepaceBm8701ErrorServiceMissing message:error.localizedDescription step:SleepaceBm8701StepConnecting];
        return;
    }
    for (CBService *s in peripheral.services) {
        if ([s.UUID isEqual:[CBUUID UUIDWithString:@"FFE0"]]) {
            [peripheral discoverCharacteristics:@[[CBUUID UUIDWithString:@"FFE4"]] forService:s];
        } else if ([s.UUID isEqual:[CBUUID UUIDWithString:@"FFE5"]]) {
            [peripheral discoverCharacteristics:@[[CBUUID UUIDWithString:@"FFE9"]] forService:s];
        }
    }
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error {
    if (self.finished) return;
    if (error) {
        [self failWithCode:SleepaceBm8701ErrorServiceMissing message:error.localizedDescription step:SleepaceBm8701StepConnecting];
        return;
    }
    for (CBCharacteristic *c in service.characteristics) {
        if ([c.UUID isEqual:[CBUUID UUIDWithString:@"FFE4"]]) self.notifyChar = c;
        if ([c.UUID isEqual:[CBUUID UUIDWithString:@"FFE9"]]) {
            self.writeChar = c;
            // 与 Android 默认写类型对齐：按特征属性决定（UNVERIFIED，先记录日志）
            BM8701TLSLOG(@"FFE9 properties: 0x%02lX", (unsigned long)c.properties);
            self.writeWithoutResponse = (c.properties & CBCharacteristicPropertyWriteWithoutResponse) != 0;
        }
    }
    if (self.notifyChar && self.writeChar && self.state == Bm8701StateDiscovering) {
        self.state = Bm8701StateEnablingNotify;
        [peripheral setNotifyValue:YES forCharacteristic:self.notifyChar];
    }
}

- (void)peripheral:(CBPeripheral *)peripheral didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    if (self.finished) return;
    if (error || !characteristic.isNotifying) {
        [self failWithCode:SleepaceBm8701ErrorFailed
                   message:[NSString stringWithFormat:@"enable notify failed: %@", error]
                      step:SleepaceBm8701StepConnecting];
        return;
    }
    BM8701TLSLOG(@"FFE4 notify enabled, 等待 %.0fms 后开始步骤", kPostNotifyDelay * 1000);
    // Android 时序：发现服务后 200ms 开通知 + 连接后 500ms 才开始发命令
    NSUInteger epoch = ++self.requestEpoch;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPostNotifyDelay * NSEC_PER_SEC)), self.queue, ^{
        if (self.finished || epoch != self.requestEpoch) return;
        [self startGetDeviceInfo];
    });
}

#pragma mark - 发送：20 字节分包

// 组帧、切包、发出，并启动 3s 应答超时
- (void)sendRequest:(uint16_t)msgType content:(NSData *)content {
    uint16_t seq = ++self.nextSeq;
    if (self.nextSeq == 0) self.nextSeq = seq = 1; // 溢出回绕到 1（对齐 Android createNewSerialCode）
    self.pendingSeq = seq;

    NSData *frame = [[self class] frameWithMessageType:msgType sequence:seq content:content];
    BM8701TLSLOG(@"TX frame msgType=%04X seq=%u (%luB): %@", msgType, seq,
                 (unsigned long)frame.length, [[self class] hexString:frame]);

    // 固定 20 字节分包（不依赖 MTU）
    NSMutableArray *chunks = [NSMutableArray array];
    for (NSUInteger off = 0; off < frame.length; off += kBleChunkSize) {
        NSUInteger len = MIN(kBleChunkSize, frame.length - off);
        NSData *chunk = [frame subdataWithRange:NSMakeRange(off, len)];
        [chunks addObject:chunk];
        BM8701TLSLOG(@"TX chunk[%lu]: %@", (unsigned long)(chunks.count - 1), [[self class] hexString:chunk]);
    }
    self.txChunks = chunks;
    self.txChunkIndex = 0;
    self.waitingWriteReady = NO;

    // 应答超时
    NSUInteger epoch = ++self.requestEpoch;
    uint16_t expectSeq = seq;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kRequestTimeout * NSEC_PER_SEC)), self.queue, ^{
        if (self.finished || epoch != self.requestEpoch) return;
        [self requestTimedOut:expectSeq];
    });

    [self sendNextChunk];
}

- (void)sendNextChunk {
    if (self.finished) return;
    while (self.txChunkIndex < self.txChunks.count) {
        NSData *chunk = self.txChunks[self.txChunkIndex];
        if (self.writeWithoutResponse) {
            if (![self.peripheral canSendWriteWithoutResponse]) {
                self.waitingWriteReady = YES; // 等 peripheralIsReadyToSendWriteWithoutResponse
                return;
            }
            [self.peripheral writeValue:chunk forCharacteristic:self.writeChar type:CBCharacteristicWriteWithoutResponse];
            self.txChunkIndex++;
        } else {
            // WithResponse：等 didWriteValueForCharacteristic 再发下一包
            [self.peripheral writeValue:chunk forCharacteristic:self.writeChar type:CBCharacteristicWriteWithResponse];
            return;
        }
    }
}

- (void)peripheralIsReadyToSendWriteWithoutResponse:(CBPeripheral *)peripheral {
    if (self.finished) return;
    if (self.waitingWriteReady) {
        self.waitingWriteReady = NO;
        [self sendNextChunk];
    }
}

- (void)peripheral:(CBPeripheral *)peripheral didWriteValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    if (self.finished) return;
    if (error) {
        [self failWithCode:SleepaceBm8701ErrorFailed
                   message:[NSString stringWithFormat:@"write failed: %@", error.localizedDescription]
                      step:self.currentStep];
        return;
    }
    self.txChunkIndex++;
    [self sendNextChunk];
}

#pragma mark - 接收：重组 + 应答匹配

- (void)peripheral:(CBPeripheral *)peripheral didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    if (self.finished || error) return;
    if (![characteristic.UUID isEqual:self.notifyChar.UUID]) return;
    NSData *value = characteristic.value;
    if (!value.length) return;
    BM8701TLSLOG(@"RX raw (%luB): %@", (unsigned long)value.length, [[self class] hexString:value]);
    [self.rxBuffer appendData:value];

    // 循环抽帧（一个通知里可能拼多帧，或一帧跨多个通知）
    NSDictionary *frameDict = nil;
    while ((frameDict = [[self class] extractFrameFromBuffer:self.rxBuffer])) {
        [self handleFrame:frameDict];
        if (self.finished) return;
    }
}

- (void)handleFrame:(NSDictionary *)frameDict {
    uint8_t frameType = [frameDict[@"frameType"] unsignedCharValue];
    uint16_t seq = [frameDict[@"frameSeq"] unsignedShortValue];
    uint16_t msgType = [frameDict[@"msgType"] unsignedShortValue];
    NSData *content = frameDict[@"content"];
    BM8701TLSLOG(@"RX frame type=%u seq=%u msgType=%04X content(%luB): %@",
                 frameType, seq, msgType, (unsigned long)content.length,
                 [[self class] hexString:content]);

    // type 1 = POST（心跳/设备推送），type 2 = 设备请求，配置流程中均忽略
    if (frameType == 1 || frameType == 2) return;

    // type 0 (ACK) / 3 (RESPONSE)：按 frameSeq 匹配（Android 只匹配 seq，不匹配 msgType）
    if (seq != self.pendingSeq) {
        BM8701TLSLOG(@"忽略 seq 不匹配的帧 (期望 %u)", self.pendingSeq);
        return;
    }
    self.requestEpoch++; // 取消该请求的超时

    if (content.length < 2) {
        // Android 此处会抛异常，状态保持 -3
        [self failWithCode:SleepaceBm8701ErrorFailed message:@"response content too short" step:self.currentStep];
        return;
    }
    const uint8_t *b = content.bytes;
    uint16_t status = ((uint16_t)b[0] << 8) | b[1];
    if (status != 0) {
        [self failWithCode:SleepaceBm8701ErrorFailed
                   message:[NSString stringWithFormat:@"device returned status %u", status]
                      step:self.currentStep
              deviceStatus:status];
        return;
    }

    switch (self.state) {
        case Bm8701StateGetDeviceInfo: [self onDeviceInfoResponse:content]; break;
        case Bm8701StateSetServer:     [self startSetWiFi]; break;
        case Bm8701StateSetWiFi:       [self onAllDone]; break;
        case Bm8701StateGetWiFi:       [self onWiFiResponse:content]; break;
        default: break;
    }
}

#pragma mark - 步骤流程

- (void)startGetDeviceInfo {
    self.state = Bm8701StateGetDeviceInfo;
    self.infoAttempt = 1;
    [self reportProgress:SleepaceBm8701StepGetDeviceInfo];
    BM8701TLSLOG(@"step 0x0202 getDeviceInfo (attempt 1/%lu)", (unsigned long)kMaxInfoAttempts);
    [self sendRequest:kMsgGetDeviceInfo content:[NSData data]];
}

- (void)requestTimedOut:(uint16_t)seq {
    if (seq != self.pendingSeq) return;
    if (self.state == Bm8701StateGetDeviceInfo && self.infoAttempt < kMaxInfoAttempts) {
        // 0x0202 重试：最多 3 次，间隔 100ms，每次用新 seq
        self.infoAttempt++;
        NSUInteger epoch = self.requestEpoch;
        BM8701TLSLOG(@"0x0202 超时，100ms 后重试 (attempt %lu/%lu)", (unsigned long)self.infoAttempt, (unsigned long)kMaxInfoAttempts);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kRetryGap * NSEC_PER_SEC)), self.queue, ^{
            if (self.finished || epoch != self.requestEpoch) return;
            [self sendRequest:kMsgGetDeviceInfo content:[NSData data]];
        });
        return;
    }
    [self failWithCode:SleepaceBm8701ErrorTimeout message:@"request timed out (3s)" step:self.currentStep];
}

- (void)onDeviceInfoResponse:(NSData *)content {
    // content: [0..1] status | [2..14] deviceId(13B ASCII) | [15] pad | [16..17] u16(未用) | [18..19] 固件版本x100
    if (content.length >= 20) {
        NSData *idData = [content subdataWithRange:NSMakeRange(2, 13)];
        self.deviceId = [[NSString alloc] initWithData:idData encoding:NSASCIIStringEncoding];
        const uint8_t *b = content.bytes;
        uint16_t verRaw = ((uint16_t)b[18] << 8) | b[19];
        self.version = [NSString stringWithFormat:@"%.2f", verRaw * 0.01];
        BM8701TLSLOG(@"deviceId=%@ version=%@", self.deviceId, self.version);
    } else {
        // Android 会抛异常并失败；iOS 容忍但记日志
        BM8701TLSLOG(@"警告: deviceInfo content 长度不足 (%lu < 20)，跳过解析", (unsigned long)content.length);
    }
    if (self.queryMode) {
        [self startGetWiFi];
    } else {
        [self startSetServer];
    }
}

- (void)startGetWiFi {
    self.state = Bm8701StateGetWiFi;
    [self reportProgress:SleepaceBm8701StepGetWiFi];
    BM8701TLSLOG(@"step 0x03A1 getWiFi");
    [self sendRequest:kMsgGetWiFi content:[NSData data]];
}

/// 0x03A1 应答：[0..1] status | [2..34] ssid(33) | [35] 有密码标志 | [36..100] 密码(65) |
/// [101] ipType | [102..105] ip | [106..109] mask | [110..113] gateway（同 setWiFi 布局前加 2 字节状态）
- (void)onWiFiResponse:(NSData *)content {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    if (self.deviceId) info[@"deviceId"] = self.deviceId;
    if (self.version) info[@"version"] = self.version;
    const uint8_t *b = content.bytes;
    NSString *(^cstr)(NSUInteger, NSUInteger) = ^NSString *(NSUInteger off, NSUInteger len) {
        if (content.length < off + len) return @"";
        NSUInteger n = 0;
        while (n < len && b[off + n] != 0) n++;
        return [[NSString alloc] initWithBytes:b + off length:n encoding:NSUTF8StringEncoding] ?: @"";
    };
    NSString *(^ip)(NSUInteger) = ^NSString *(NSUInteger off) {
        if (content.length < off + 4) return @"";
        return [NSString stringWithFormat:@"%u.%u.%u.%u", b[off], b[off + 1], b[off + 2], b[off + 3]];
    };
    info[@"ssid"] = cstr(2, 33);
    info[@"password"] = cstr(36, 65);
    if (content.length > 101) {
        info[@"ipType"] = [NSString stringWithFormat:@"%u", b[101]];
        info[@"staticIp"] = ip(102);
        info[@"subnetMask"] = ip(106);
        info[@"gateway"] = ip(110);
    }
    self.state = Bm8701StateFinished;
    [self reportProgress:SleepaceBm8701StepDone];
    [self finishSuccess:YES info:info error:nil];
}

- (void)startSetServer {
    self.state = Bm8701StateSetServer;
    [self reportProgress:SleepaceBm8701StepSetServer];
    BM8701TLSLOG(@"step 0x03A2 setNet (server=%@ port=%u tls=%@)", self.serverAddress, self.port, self.tls ? @"YES" : @"NO");
    [self sendRequest:kMsgSetServer content:self.serverPayload];
}

- (void)startSetWiFi {
    if (!self.wifiPayload) {
        // 仅配置服务器模式：setNet 成功即整体成功
        BM8701TLSLOG(@"无 WiFi 配置（server-only），跳过 0x03A0");
        [self onAllDone];
        return;
    }
    self.state = Bm8701StateSetWiFi;
    [self reportProgress:SleepaceBm8701StepSetWiFi];
    BM8701TLSLOG(@"step 0x03A0 setWiFi (ssid=%@)", self.ssid);
    [self sendRequest:kMsgSetWiFi content:self.wifiPayload];
}

- (void)onAllDone {
    self.state = Bm8701StateFinished;
    [self reportProgress:SleepaceBm8701StepDone];
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    if (self.deviceId) info[@"deviceId"] = self.deviceId;
    if (self.version) info[@"version"] = self.version;
    // 延时 400ms 断开（Android 不断开，iOS 主动断；UNVERIFIED 设备是否会自行断开）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSuccessDisconnectDelay * NSEC_PER_SEC)), self.queue, ^{
        [self finishSuccess:YES info:info error:nil];
    });
}

#pragma mark - 结束处理

- (void)reportProgress:(SleepaceBm8701Step)step {
    if (!self.progress) return;
    dispatch_async(dispatch_get_main_queue(), ^{ self.progress(step); });
}

- (void)failWithCode:(SleepaceBm8701Error)code message:(NSString *)msg step:(SleepaceBm8701Step)step {
    [self failWithCode:code message:msg step:step deviceStatus:0];
}

- (void)failWithCode:(SleepaceBm8701Error)code message:(NSString *)msg step:(SleepaceBm8701Step)step deviceStatus:(uint16_t)deviceStatus {
    NSError *err = [NSError errorWithDomain:SleepaceBm8701ErrorDomain code:code
                                   userInfo:@{NSLocalizedDescriptionKey: msg}];
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithDictionary:@{@"failedStep": @(step)}];
    if (deviceStatus != 0) info[@"deviceStatus"] = @(deviceStatus);
    BM8701TLSLOG(@"失败: code=%ld step=%ld %@", (long)code, (long)step, msg);
    [self finishSuccess:NO info:info error:err];
}

// 保证 completion 只调用一次，且回到主线程
- (void)finishSuccess:(BOOL)success info:(NSDictionary *)info error:(NSError *)error {
    void (^work)(void) = ^{
        if (self.finished) return;
        self.finished = YES;
        self.state = Bm8701StateFinished;
        self.requestEpoch++; // 取消所有挂起的超时
        if (self.peripheral) {
            [self.central cancelPeripheralConnection:self.peripheral];
        }
        SleepaceBm8701Completion completion = self.completion;
        self.completion = nil;
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(success, info ?: @{}, error);
            });
        }
    };
    // 统一异步到串行队列（参数错误路径可能在调用线程，正常路径已在队列上）
    if (self.queue) {
        dispatch_async(self.queue, work);
    } else {
        work();
    }
}

#pragma mark - 超时辅助

- (void)armTimeout:(NSTimeInterval)seconds handler:(dispatch_block_t)handler {
    NSUInteger epoch = ++self.requestEpoch;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), self.queue, ^{
        if (self.finished || epoch != self.requestEpoch) return;
        handler();
    });
}

@end
