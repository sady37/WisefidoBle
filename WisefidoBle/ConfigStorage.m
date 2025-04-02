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

    // 使用统一的 loadArrayForKey: 方法加载数据
    NSMutableArray *wifiConfigs = [self loadArrayForKey:kWiFiConfigsKey];
    
    // 创建新的配置字典
    NSDictionary *newConfig = @{
        @"ssid": wifiSsid,
        @"password": wifiPassword ?: @""
    };

    // 移除所有同名的旧配置
    [wifiConfigs filterUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(NSDictionary *config, NSDictionary *bindings) {
            return ![config[@"ssid"] isEqualToString:wifiSsid];
        }]];

    // 插入到数组开头
    [wifiConfigs insertObject:newConfig atIndex:0];

    // 限制最大数量
    if (wifiConfigs.count > kMaxConfigCount) {
        [wifiConfigs removeLastObject];
    }

    // 使用统一的 saveArray:forKey: 方法保存 ✅ 修复了键名问题
    [self saveArray:wifiConfigs forKey:kWiFiConfigsKey];
    
    NSLog(@"✅ Saved WiFi config: %@ (Count: %lu)", wifiSsid, (unsigned long)wifiConfigs.count);
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
        // 显式允许所有可能的数据类型
        NSSet *allowedClasses = [NSSet setWithObjects:
                                [NSMutableArray class],
                                [NSDictionary class],
                                [NSString class],
                                [NSNumber class],
                                nil];
        array = [NSKeyedUnarchiver unarchivedObjectOfClasses:allowedClasses 
                                                   fromData:data 
                                                      error:&error];
    } else {
        // iOS 11 及以下保持原逻辑
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wdeprecated-declarations"
        array = [NSKeyedUnarchiver unarchiveObjectWithData:data];
        #pragma clang diagnostic pop
    }
    
    if (error) {
        NSLog(@"Error unarchiving array (key: %@): %@", key, error);
        return [NSMutableArray array];
    }
    
    // 类型安全校验
    return ([array isKindOfClass:[NSMutableArray class]]) ? array : [NSMutableArray array];
}

@end
