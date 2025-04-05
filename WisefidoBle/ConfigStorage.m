// ConfigStorage.m
#import "ConfigStorage.h"
#import <Security/Security.h>
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

//wifi password  save to Keychain
// 保存字符串到Keychain
- (BOOL)saveSecureString:(NSString *)string forKey:(NSString *)key {
    if (!string || !key) return NO;
    
    // 删除可能存在的旧数据
    [self deleteSecureItemForKey:key];
    
    // 准备数据
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    
    // 准备查询字典
    NSMutableDictionary *query = [NSMutableDictionary dictionary];
    [query setObject:(__bridge id)kSecClassGenericPassword forKey:(__bridge id)kSecClass];
    [query setObject:key forKey:(__bridge id)kSecAttrAccount];
    [query setObject:data forKey:(__bridge id)kSecValueData];
    [query setObject:(__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly 
              forKey:(__bridge id)kSecAttrAccessible];
    
    // 添加到Keychain
    OSStatus status = SecItemAdd((__bridge CFDictionaryRef)query, NULL);
    return (status == errSecSuccess);
}

// 从Keychain加载字符串
- (NSString *)loadSecureStringForKey:(NSString *)key {
    if (!key) return nil;
    
    // 准备查询字典
    NSMutableDictionary *query = [NSMutableDictionary dictionary];
    [query setObject:(__bridge id)kSecClassGenericPassword forKey:(__bridge id)kSecClass];
    [query setObject:key forKey:(__bridge id)kSecAttrAccount];
    [query setObject:@YES forKey:(__bridge id)kSecReturnData];
    [query setObject:(__bridge id)kSecMatchLimitOne forKey:(__bridge id)kSecMatchLimit];
    
    // 查询Keychain
    CFTypeRef dataTypeRef = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &dataTypeRef);
    
    if (status == errSecSuccess && dataTypeRef) {
        NSData *data = (__bridge_transfer NSData *)dataTypeRef;
        return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    }
    
    return nil;
}

// 从Keychain删除项
- (BOOL)deleteSecureItemForKey:(NSString *)key {
    if (!key) return NO;
    
    // 准备查询字典
    NSMutableDictionary *query = [NSMutableDictionary dictionary];
    [query setObject:(__bridge id)kSecClassGenericPassword forKey:(__bridge id)kSecClass];
    [query setObject:key forKey:(__bridge id)kSecAttrAccount];
    
    // 删除匹配项
    OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query);
    return (status == errSecSuccess || status == errSecItemNotFound);
}



// 修改保存WiFi配置的方法
- (void)saveWiFiConfigWithSsid:(NSString *_Nullable)wifiSsid password:(NSString *_Nullable)wifiPassword {
    if (wifiSsid.length == 0) {
        return;
    }

    // 加载现有配置
    NSMutableArray *wifiConfigs = [self loadArrayForKey:kWiFiConfigsKey];
    
    // 创建新配置，不包含密码
    NSDictionary *newConfig = @{
        @"ssid": wifiSsid,
        @"hasPassword": wifiPassword.length > 0 ? @YES : @NO
    };

    // 如有密码，存入Keychain
    if (wifiPassword.length > 0) {
        NSString *keychainKey = [NSString stringWithFormat:@"wifi_password_%@", wifiSsid];
        [self saveSecureString:wifiPassword forKey:keychainKey];
    }

    // 移除同名旧配置
    [wifiConfigs filterUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(NSDictionary *config, NSDictionary *bindings) {
            return ![config[@"ssid"] isEqualToString:wifiSsid];
        }]];

    // 插入新配置
    [wifiConfigs insertObject:newConfig atIndex:0];

    // 限制配置数量
    if (wifiConfigs.count > kMaxConfigCount) {
        // 清理多余配置的Keychain条目
        NSDictionary *configToRemove = wifiConfigs.lastObject;
        if ([configToRemove[@"hasPassword"] boolValue]) {
            NSString *keychainKey = [NSString stringWithFormat:@"wifi_password_%@", configToRemove[@"ssid"]];
            [self deleteSecureItemForKey:keychainKey];
        }
        [wifiConfigs removeLastObject];
    }

    // 保存配置
    [self saveArray:wifiConfigs forKey:kWiFiConfigsKey];
}

// 修改获取WiFi配置的方法
- (NSArray<NSDictionary<NSString *, NSString *> *> *)getWiFiConfigs {
    NSArray *savedConfigs = [self loadArrayForKey:kWiFiConfigsKey] ?: @[];
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:savedConfigs.count];
    
    for (NSDictionary *config in savedConfigs) {
        NSString *ssid = config[@"ssid"];
        NSString *password = @"";
        
        // 从Keychain获取密码
        if ([config[@"hasPassword"] boolValue]) {
            NSString *keychainKey = [NSString stringWithFormat:@"wifi_password_%@", ssid];
            password = [self loadSecureStringForKey:keychainKey] ?: @"";
        }
        
        // 创建包含密码的配置
        [result addObject:@{
            @"ssid": ssid,
            @"password": password
        }];
    }
    
    return result;
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
