// ConfigStorage.m
#import "ConfigStorage.h"
//#import "ConfigModels.h" // Ensure this is imported for the extern declaration of kDefaultRadarDeviceName

// 定义 UserDefaults 键
 NSString * const kServerConfigsKey = @"serverConfigs";
 NSString * const kWiFiConfigsKey = @"wifiConfigs";
 NSString * const kRadarDeviceNameKey = @"radarDeviceName";
 NSString * const kFilterTypeKey = @"filterType";
 NSString * const kDefaultRadarDeviceName = @"TSBLU";

static const NSInteger kMaxConfigCount = 5;


@implementation ConfigStorage {
    NSUserDefaults *_userDefaults;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _userDefaults = [NSUserDefaults standardUserDefaults];
    }
    return self;
}

// 更新服务器配置保存逻辑
- (void)saveServerConfig:(NSString *)serverAddress port:(NSInteger)serverPort protocol:(nullable NSString *)serverProtocol {
    NSMutableArray *configs = [self loadArrayForKey:kServerConfigsKey];
    
    // 移除重复配置
    [configs removeObjectsInArray:[configs filteredArrayUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(NSDictionary *existingConfig, NSDictionary *bindings) {
            return [existingConfig[@"serverAddress"] isEqualToString:serverAddress] &&
                   [existingConfig[@"serverPort"] integerValue] == serverPort;
        }]]];
    
    // 插入新配置到开头
    NSDictionary *serverConfig = @{
        @"serverAddress": serverAddress ?: @"",
        @"serverPort": @(serverPort),
        @"serverProtocol": serverProtocol ?: @"tcp"
    };
    [configs insertObject:serverConfig atIndex:0];
    
    // 保持最多5条记录
    if (configs.count > kMaxConfigCount) {
        [configs removeLastObject];
    }
    
    [self saveArray:configs forKey:kServerConfigsKey];
}

- (NSArray<NSDictionary *> *)getServerConfigs {
    return [self loadArrayForKey:kServerConfigsKey] ?: @[];
}

// 更新 WiFi 配置保存逻辑
- (void)saveWiFiConfigWithSsid:(NSString *)wifiSsid password:(NSString *)wifiPassword {
    if (wifiSsid.length == 0) {
        return;
    }

    // 获取当前保存的WiFi配置列表
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableArray *wifiConfigs = [[defaults objectForKey:@"WiFiConfigs"] mutableCopy];
    if (!wifiConfigs) {
        wifiConfigs = [NSMutableArray array];
    }

    // 创建新的WiFi配置字典
    NSDictionary *wifiConfig = @{
        @"ssid": wifiSsid,
        @"password": wifiPassword ?: @""
    };

    // 检查是否已存在相同的SSID配置，存在则替换
    NSUInteger existingIndex = [wifiConfigs indexOfObjectPassingTest:^BOOL(NSDictionary *config, NSUInteger idx, BOOL *stop) {
        return [config[@"ssid"] isEqualToString:wifiSsid];
    }];
    if (existingIndex != NSNotFound) {
        [wifiConfigs replaceObjectAtIndex:existingIndex withObject:wifiConfig];
    } else {
        [wifiConfigs addObject:wifiConfig];
    }

    // 保存更新后的配置列表
    [defaults setObject:wifiConfigs forKey:@"WiFiConfigs"];
    [defaults synchronize];
}
- (NSArray<NSDictionary<NSString *, NSString *> *> *)getWiFiConfigs {
    return [self loadArrayForKey:kWiFiConfigsKey] ?: @[];
}

// 雷达设备名称管理
- (void)saveRadarDeviceName:(NSString *)name {
    [_userDefaults setObject:name forKey:kRadarDeviceNameKey];
    [_userDefaults synchronize];
}

- (NSString *)getRadarDeviceName {
    return [_userDefaults stringForKey:kRadarDeviceNameKey] ?: kDefaultRadarDeviceName;
}

// 过滤器类型管理
- (void)saveFilterType:(FilterType)filterType {
    [[NSUserDefaults standardUserDefaults] setInteger:filterType forKey:@"FilterType"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (FilterType)getFilterType {
    NSInteger filterTypeValue = [[NSUserDefaults standardUserDefaults] integerForKey:@"FilterType"];
    return (FilterType)filterTypeValue;
}

// 私有辅助方法：保存数组到 UserDefaults
- (void)saveArray:(NSArray *)array forKey:(NSString *)key {
    NSError *error = nil;
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:array requiringSecureCoding:NO error:&error];
    if (error) {
        NSLog(@"Error archiving array: %@", error);
        return;
    }
    [_userDefaults setObject:data forKey:key];
    [_userDefaults synchronize];
}

// 私有辅助方法：从 UserDefaults 加载数组
- (NSMutableArray *)loadArrayForKey:(NSString *)key {
    NSData *data = [_userDefaults objectForKey:key];
    if (!data) {
        return [NSMutableArray array];
    }
    
    NSError *error = nil;
    NSMutableArray *array = nil;
    
    if (@available(iOS 12.0, *)) {
        // iOS 12+使用新API
        array = [NSKeyedUnarchiver unarchivedObjectOfClass:[NSMutableArray class] fromData:data error:&error];
    } else {
        // iOS 12以下继续使用旧API
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wdeprecated-declarations"
        array = [NSKeyedUnarchiver unarchiveObjectWithData:data];
        #pragma clang diagnostic pop
    }
    
    if (error) {
        NSLog(@"Error unarchiving array: %@", error);
        return [NSMutableArray array];
    }
    
    return array ?: [NSMutableArray array];
}

@end
