//
//  AppDelegate.m
//  WisefidoBle
//
//  Created by sady3721 on 3/24/25.
//

#import "AppDelegate.h"
#import "MainViewController.h"

@interface AppDelegate ()

@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // iOS 13 及以上版本不需要在这里设置 window 和 rootViewController
    if (@available(iOS 13.0, *)) {
        // 什么都不做，交给 SceneDelegate 处理
        NSLog(@"iOS 13+ detected, skipping window setup in AppDelegate");
    } else {
        // iOS 12 及以下版本，设置 window 和 rootViewController
        NSLog(@"iOS 12 or below, setting up window in AppDelegate");
        self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
        self.window.backgroundColor = [UIColor systemBackgroundColor];
        
        MainViewController *mainVC = [[MainViewController alloc] init];
        UINavigationController *navController = [[UINavigationController alloc] initWithRootViewController:mainVC];
        
        self.window.rootViewController = navController;
        [self.window makeKeyAndVisible];
    }
    return YES;
}

#pragma mark - UISceneSession 生命周期

// 以下方法仅在iOS 13及以上版本调用
- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession options:(UISceneConnectionOptions *)options API_AVAILABLE(ios(13.0)) {
    return [[UISceneConfiguration alloc] initWithName:@"Default Configuration" sessionRole:connectingSceneSession.role];
}

- (void)application:(UIApplication *)application didDiscardSceneSessions:(NSSet<UISceneSession *> *)sceneSessions API_AVAILABLE(ios(13.0)) {
    // 当用户丢弃场景时调用
}

@end
