//
//  DeviceServerRules.m
//

#import "DeviceServerRules.h"

#define RULESLOG(fmt, ...) NSLog((@"[DeviceServerRules] " fmt), ##__VA_ARGS__)

NSString * const kDeviceServerRuleNameKey = @"name";
NSString * const kDeviceServerRulePrefixKey = @"prefix";
NSString * const kDeviceServerRuleServerKey = @"server";
NSString * const kDeviceServerRulePortKey = @"port";
NSString * const kDeviceServerRuleTlsKey = @"tls";

static NSString * const kCustomRuleName = @"Custom";

// UserDefaults 键（v4：任意条数规则）
static NSString * const kRemoteTemplateCacheKey = @"deviceServerRemoteTemplateV4";  // 原始 JSON 数据
static NSString * const kUserPrefixesKey = @"deviceServerUserPrefixesV4";          // {name: prefix}
static NSString * const kUserCustomRuleKey = @"deviceServerUserCustomV4";          // 本地自定义规则

// 在线模板地址：官网 www 优先，pilot 备用（同一台服务器，仅防域名/站点调整）
static NSString * const kRemoteRuleURLs[] = {
    @"https://www.wisefido.com/device_config.json",
    @"https://pilot.wisefido.com/device_config.json",
};
static const NSUInteger kRemoteRuleURLCount = sizeof(kRemoteRuleURLs) / sizeof(kRemoteRuleURLs[0]);

@implementation DeviceServerRules

#pragma mark - 规则读取

+ (NSArray<NSDictionary *> *)builtInRules {
    return @[
        @{kDeviceServerRuleNameKey: @"Radar",   kDeviceServerRulePrefixKey: @"TSBLU", kDeviceServerRuleServerKey: @"app.wisefido.com", kDeviceServerRulePortKey: @"8443",  kDeviceServerRuleTlsKey: @YES},
        @{kDeviceServerRuleNameKey: @"Sleepad", kDeviceServerRulePrefixKey: @"BM87",  kDeviceServerRuleServerKey: @"app.wisefido.com", kDeviceServerRulePortKey: @"29010", kDeviceServerRuleTlsKey: @NO},
    ];
}

+ (NSArray<NSDictionary *> *)defaultRules {
    NSData *data = [[NSUserDefaults standardUserDefaults] dataForKey:kRemoteTemplateCacheKey];
    return (data ? [self parseTemplateData:data] : nil) ?: [self builtInRules];
}

+ (NSArray<NSDictionary *> *)currentRules {
    NSDictionary *userPrefixes = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kUserPrefixesKey];
    NSMutableArray *rules = [NSMutableArray array];
    for (NSDictionary *def in [self defaultRules]) {
        NSString *prefix = userPrefixes[def[kDeviceServerRuleNameKey]];
        if ([prefix isKindOfClass:[NSString class]] && prefix.length > 0) {
            NSMutableDictionary *rule = [def mutableCopy];
            rule[kDeviceServerRulePrefixKey] = prefix;
            [rules addObject:[rule copy]];
        } else {
            [rules addObject:def];
        }
    }
    return rules;
}

+ (nullable NSDictionary *)customRule {
    NSDictionary *saved = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kUserCustomRuleKey];
    return saved ? [self parseRule:saved] : nil;
}

#pragma mark - 解析

/// 字段转成去空格的字符串；端口允许 JSON 里写数字。类型不对返回 nil
+ (nullable NSString *)stringValue:(id)value {
    if (!value || value == [NSNull null]) return @"";
    if ([value isKindOfClass:[NSNumber class]]) return [value stringValue];
    if (![value isKindOfClass:[NSString class]]) return nil;
    return [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

/// tls 支持 true/false 和 "Y"/"N"；非法返回 nil
+ (nullable NSNumber *)tlsValue:(id)value {
    if (!value || value == [NSNull null]) return @NO;
    if ([value isKindOfClass:[NSNumber class]]) return @([value boolValue]);
    if (![value isKindOfClass:[NSString class]]) return nil;
    NSString *text = [[value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] uppercaseString];
    if ([@[@"Y", @"YES", @"TRUE", @"1"] containsObject:text]) return @YES;
    if ([@[@"N", @"NO", @"FALSE", @"0", @""] containsObject:text]) return @NO;
    return nil;
}

/// 校验单条规则：name/prefix/server/port 必填，非法返回 nil；未知字段忽略，便于以后扩展
+ (nullable NSDictionary *)parseRule:(NSDictionary *)item {
    NSString *name = [self stringValue:item[kDeviceServerRuleNameKey]];
    NSString *prefix = [self stringValue:item[kDeviceServerRulePrefixKey]];
    NSString *server = [[self stringValue:item[kDeviceServerRuleServerKey]] lowercaseString];
    NSString *port = [self stringValue:item[kDeviceServerRulePortKey]];
    NSNumber *tls = [self tlsValue:item[kDeviceServerRuleTlsKey]];
    if (name.length == 0 || prefix.length == 0 || server.length == 0 || !tls || ![self isValidPort:port]) return nil;
    return @{kDeviceServerRuleNameKey: name,
             kDeviceServerRulePrefixKey: prefix,
             kDeviceServerRuleServerKey: server,
             kDeviceServerRulePortKey: port,
             kDeviceServerRuleTlsKey: tls};
}

/// 解析整份模板；任一条非法或 name 重复则整体视为无效，保留上次缓存
+ (nullable NSArray<NSDictionary *> *)parseTemplateData:(NSData *)data {
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) return nil;
    NSArray *array = json[@"rules"];
    if (![array isKindOfClass:[NSArray class]] || array.count == 0) return nil;

    NSMutableArray *rules = [NSMutableArray array];
    NSMutableSet *names = [NSMutableSet set];
    for (id item in array) {
        if (![item isKindOfClass:[NSDictionary class]]) return nil;
        NSDictionary *rule = [self parseRule:item];
        NSString *lowerName = [rule[kDeviceServerRuleNameKey] lowercaseString];
        if (!rule || [names containsObject:lowerName]) return nil;
        [names addObject:lowerName];
        [rules addObject:rule];
    }
    return rules;
}

#pragma mark - 本地修改

+ (void)saveUserPrefix:(nullable NSString *)prefix forRuleName:(NSString *)name {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *userPrefixes = [[defaults dictionaryForKey:kUserPrefixesKey] mutableCopy] ?: [NSMutableDictionary dictionary];
    NSString *trimmed = [prefix stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
    NSString *defaultPrefix = @"";
    for (NSDictionary *rule in [self defaultRules]) {
        if ([rule[kDeviceServerRuleNameKey] isEqualToString:name]) defaultPrefix = rule[kDeviceServerRulePrefixKey];
    }
    if (trimmed.length == 0 || [trimmed caseInsensitiveCompare:defaultPrefix] == NSOrderedSame) {
        [userPrefixes removeObjectForKey:name];
    } else {
        userPrefixes[name] = trimmed;
    }
    [defaults setObject:userPrefixes forKey:kUserPrefixesKey];
}

+ (void)saveCustomRuleWithPrefix:(nullable NSString *)prefix server:(nullable NSString *)server port:(nullable NSString *)port tls:(BOOL)tls {
    NSDictionary *rule = [self parseRule:@{kDeviceServerRuleNameKey: kCustomRuleName,
                                           kDeviceServerRulePrefixKey: prefix ?: @"",
                                           kDeviceServerRuleServerKey: server ?: @"",
                                           kDeviceServerRulePortKey: port ?: @"",
                                           kDeviceServerRuleTlsKey: @(tls)}];
    if (rule) {
        [[NSUserDefaults standardUserDefaults] setObject:rule forKey:kUserCustomRuleKey];
    } else {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kUserCustomRuleKey];
    }
}

+ (void)clearUserOverrides {
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kUserPrefixesKey];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kUserCustomRuleKey];
}

#pragma mark - 匹配

+ (BOOL)rule:(NSDictionary *)rule matchesCandidates:(NSArray<NSString *> *)candidates {
    NSString *prefix = rule[kDeviceServerRulePrefixKey];
    for (NSString *candidate in candidates) {
        if ([candidate rangeOfString:prefix options:NSCaseInsensitiveSearch | NSAnchoredSearch].location != NSNotFound) return YES;
    }
    return NO;
}

+ (nullable NSDictionary *)ruleForDevice:(DeviceInfo *)device qrCode:(nullable NSString *)qrCode {
    NSArray<NSString *> *candidates = @[device.deviceName ?: @"", device.deviceId ?: @"", qrCode ?: @""];
    NSDictionary *custom = [self customRule];
    if (custom && [self rule:custom matchesCandidates:candidates]) return custom;

    // 同一设备可配多组（如 Radar 的 MQTT / MQTTS），有 TLS=Y 的优先，否则取模板中第一条
    NSDictionary *firstMatch = nil;
    for (NSDictionary *rule in [self currentRules]) {
        if (![self rule:rule matchesCandidates:candidates]) continue;
        if ([rule[kDeviceServerRuleTlsKey] boolValue]) return rule;
        if (!firstMatch) firstMatch = rule;
    }
    return firstMatch;
}

+ (BOOL)isTlsPort:(NSInteger)port server:(nullable NSString *)server {
    NSString *portText = [NSString stringWithFormat:@"%ld", (long)port];
    NSString *host = [[server stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString] ?: @"";
    NSMutableArray *rules = [NSMutableArray array];
    NSDictionary *custom = [self customRule];
    if (custom) [rules addObject:custom];
    [rules addObjectsFromArray:[self currentRules]];

    NSDictionary *portOnlyMatch = nil;
    for (NSDictionary *rule in rules) {
        if (![rule[kDeviceServerRulePortKey] isEqualToString:portText]) continue;
        if ([rule[kDeviceServerRuleServerKey] isEqualToString:host]) return [rule[kDeviceServerRuleTlsKey] boolValue];
        if (!portOnlyMatch) portOnlyMatch = rule;
    }
    return [portOnlyMatch[kDeviceServerRuleTlsKey] boolValue];
}

#pragma mark - 文本转换

+ (BOOL)isValidPort:(nullable NSString *)port {
    if (port.length == 0 || port.length > 5) return NO;
    if ([port rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location != NSNotFound) return NO;
    NSInteger value = port.integerValue;
    return value > 0 && value <= 65535;
}

+ (NSString *)displayServerForRule:(NSDictionary *)rule {
    return [NSString stringWithFormat:@"%@:%@  TLS=%@", rule[kDeviceServerRuleServerKey], rule[kDeviceServerRulePortKey],
            [rule[kDeviceServerRuleTlsKey] boolValue] ? @"Y" : @"N"];
}

#pragma mark - 在线更新

+ (void)refreshFromRemoteWithCompletion:(nullable void (^)(BOOL updated))completion {
    [self fetchRemoteAtIndex:0 completion:completion];
}

+ (void)fetchRemoteAtIndex:(NSUInteger)index completion:(nullable void (^)(BOOL updated))completion {
    if (index >= kRemoteRuleURLCount) {
        RULESLOG(@"All remote rule URLs failed, keep cached/built-in rules");
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
        return;
    }

    NSURL *url = [NSURL URLWithString:kRemoteRuleURLs[index]];
    NSURLRequest *request = [NSURLRequest requestWithURL:url
                                             cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                         timeoutInterval:8];
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        // pilot 站是 SPA，未知路径也返回 200 + HTML，必须以 JSON 解析结果为准
        BOOL valid = !error && status == 200 && data.length > 0 && [self parseTemplateData:data] != nil;
        if (!valid) {
            RULESLOG(@"Remote rules invalid from %@ (status=%ld, error=%@)", url, (long)status, error.localizedDescription);
            [self fetchRemoteAtIndex:index + 1 completion:completion];
            return;
        }

        RULESLOG(@"Remote rules updated from %@", url);
        [[NSUserDefaults standardUserDefaults] setObject:data forKey:kRemoteTemplateCacheKey];
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(YES); });
    }] resume];
}

@end
