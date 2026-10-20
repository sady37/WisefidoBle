//
//  BlufiClientSimStub.m
//  模拟器不链接 OpenSSL（无模拟器切片），BlufiClient.m/BlufiDH.m/BlufiSecurity.m 在
//  iphonesimulator 下被 EXCLUDED_SOURCE_FILE_NAMES 排除；这里提供空的 BlufiClient
//  实现以满足 RadarBleManager 等的链接。模拟器上雷达配网功能不可用。
//

#import <TargetConditionals.h>

#if TARGET_OS_SIMULATOR

#import "BlufiClient.h"

@implementation BlufiClient
@end

#endif
