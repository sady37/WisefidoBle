//
//  SLPBleWifiConfig.h
//  SDK
//
//  Created by Martin on 2018/1/25.
//  Copyright © 2018年 Martin. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <BluetoothManager/BluetoothManager.h>
#import <CoreBluetooth/CoreBluetooth.h>

@class CBPeripheral;
@interface SLPBleWifiConfig : NSObject

@property (nonatomic , readonly) CBPeripheral *peripheral;

+ (SLPBleWifiConfig *)sharedBleWifiConfig;

/**
连接设备并获取设备信息
@param peripheral 外设
@param deviceType 设备类型
@param completion 回调WiFi连接状态
*/

- (void)connectAndGetDeviceInfoWithPeripheral:(CBPeripheral *)peripheral
               deviceType:(SLPDeviceTypes)deviceType
               completion:(void(^)(SLPDataTransferStatus status, id data))completion;

/**
给设备配置WiFi，包含服务地址
@param peripheral 外设
@param deviceType 设备类型
@param address  服务地址
@param port 服务端口
@param name WiFi名
@param password WiFi密码
@param completion 回调WiFi连接状态
*/
- (void)configPeripheral:(CBPeripheral *)peripheral deviceType:(SLPDeviceTypes)deviceType
           serverAddress:(NSString *)address port:(NSInteger)port
                wifiName:(NSString *)name
                password:(NSString *)password
              completion:(void(^)(SLPDataTransferStatus status, id data))completion;

/**
给设备配置WiFi
@param peripheral 外设
@param deviceType 设备类型
@param name WiFi名
@param password WiFi密码
@param completion 回调WiFi连接状态
*/
- (void)configPeripheral:(CBPeripheral *)peripheral deviceType:(SLPDeviceTypes)deviceType
                wifiName:(NSString *)name
                password:(NSString *)password
              completion:(void(^)(SLPDataTransferStatus status, id data))completion;

/**
 查询设备WiFi状态是否已经连接上(针对特定设备有效，支持设备<EW202W,>)
 @param peripheral 外设
 @param deviceType 设备类型
 @param completion 回调WiFi连接状态
 */
- (void)checkDeviceConnectWiFiStatus:(CBPeripheral *)peripheral
                          deviceType:(SLPDeviceTypes)deviceType
                          completion:(void(^)(BOOL succeed ,id data))completion;

/**
获取ip信息(针对特定设备有效，支持设备<FH61W,>)
 @param peripheral 外设
 @param deviceType 设备类型
 @param completion 回调WiFi连接状态
 */
- (void)getIpInfo:(CBPeripheral *)peripheral
       deviceType:(SLPDeviceTypes)deviceType
       completion:(void(^)(BOOL succeed, id data))completion;


/**
给设备配置APN
@param peripheral 外设
@param deviceType 设备类型
@param apn APN
@param username 用户名
@param password 密码
@param completion 回调WiFi连接状态
*/
- (void)configPeripheral:(CBPeripheral *)peripheral deviceType:(SLPDeviceTypes)deviceType
                apn:(NSString *)apn
                    user:(NSString *)username
                password:(NSString *)password
              completion:(void (^)(SLPDataTransferStatus status, id data))completion;

@end
