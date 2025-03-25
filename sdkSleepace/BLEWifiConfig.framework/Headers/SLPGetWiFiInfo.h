//
//  SLPGetWiFiInfo.h
//  BLEWifiConfig
//
//  Created by San on 23/6/2020.
//  Copyright © 2020 Martin. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SLPGetWiFiInfo : NSObject

@property (nonatomic, copy) NSString *ssid;
@property (nonatomic, copy) NSString *password;
@property (nonatomic, assign) NSInteger encryptionType;//加密类型

@end


@interface SLPGetServiceInfo : NSObject

@property (nonatomic, copy) NSString *address;
@property (nonatomic, assign) UInt16 port;

@end

NS_ASSUME_NONNULL_END
