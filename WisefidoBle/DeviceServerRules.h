//
//  DeviceServerRules.h
//
//  设备前缀 -> 默认服务器映射；每条规则为 name + prefix + server + port + tls(Y/N)。
//  规则条数不限（新增硬件只需改在线 JSON），同一设备可配多组，有 TLS=Y 的优先。
//  是否 TLS 只由规则里的 tls 决定，不再由前端开关控制。
//  优先级：本地自定义规则 > 在线模板（含本地前缀修改）> 内置默认值
//

#import <Foundation/Foundation.h>
#import "ConfigModels.h"

NS_ASSUME_NONNULL_BEGIN

// 规则字典的 key
extern NSString * const kDeviceServerRuleNameKey;    // name (NSString)，例如 Radar，模板内唯一
extern NSString * const kDeviceServerRulePrefixKey;  // prefix (NSString)，例如 TSBLU
extern NSString * const kDeviceServerRuleServerKey;  // server (NSString)，例如 app.wisefido.com
extern NSString * const kDeviceServerRulePortKey;    // port (NSString，纯数字)，例如 8443
extern NSString * const kDeviceServerRuleTlsKey;     // tls (NSNumber BOOL)

@interface DeviceServerRules : NSObject

/// 在线/内置规则，叠加本地前缀修改
+ (NSArray<NSDictionary<NSString *, id> *> *)currentRules;

/// 不含本地修改的规则（在线模板缓存，没有则内置）
+ (NSArray<NSDictionary<NSString *, id> *> *)defaultRules;

/// 本地自定义规则（优先级最高），未设置返回 nil
+ (nullable NSDictionary<NSString *, id> *)customRule;

/// 保存某条规则的本地前缀；为空或与默认值相同则清除覆盖
+ (void)saveUserPrefix:(nullable NSString *)prefix forRuleName:(NSString *)name;
/// 保存本地自定义规则；前缀/服务器为空或端口非法则清除
+ (void)saveCustomRuleWithPrefix:(nullable NSString *)prefix server:(nullable NSString *)server port:(nullable NSString *)port tls:(BOOL)tls;
+ (void)clearUserOverrides;

/// 按 deviceName / deviceId / QR 码前缀匹配：本地自定义优先，其次模板中 TLS=Y 的，再其次第一条匹配；未匹配返回 nil
+ (nullable NSDictionary<NSString *, id> *)ruleForDevice:(DeviceInfo *)device qrCode:(nullable NSString *)qrCode;

/// 端口是否 TLS：按规则的 tls 判断，先匹配 server+port，再只匹配端口；没有对应规则按 TLS=N
+ (BOOL)isTlsPort:(NSInteger)port server:(nullable NSString *)server;

/// 用于界面显示："app.wisefido.com:8443  TLS=Y"
+ (NSString *)displayServerForRule:(NSDictionary<NSString *, id> *)rule;

/// 1~65535 的纯数字端口
+ (BOOL)isValidPort:(nullable NSString *)port;

/// 从 www.wisefido.com（失败则 pilot.wisefido.com）拉取在线模板，校验通过后缓存
+ (void)refreshFromRemoteWithCompletion:(nullable void (^)(BOOL updated))completion;

@end

NS_ASSUME_NONNULL_END
