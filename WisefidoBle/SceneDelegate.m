//
//  SceneDelegate.m
//  WisefidoBle
//
//  Created by sady3721 on 3/24/25.
//

#import "SceneDelegate.h"
#import "MainViewController.h"

@interface SceneDelegate ()

@end

@implementation SceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions API_AVAILABLE(ios(13.0)) {
    // 只在 iOS 13 及以上版本中设置 window 和 rootViewController
    NSLog(@"SceneDelegate: scene:willConnectToSession:options");
    if ([scene isKindOfClass:[UIWindowScene class]]) {
        NSLog(@"Setting up window in SceneDelegate");
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        self.window = [[UIWindow alloc] initWithWindowScene:windowScene];
        self.window.backgroundColor = [UIColor systemBackgroundColor];
        
        MainViewController *mainVC = [[MainViewController alloc] init];
        UINavigationController *navController = [[UINavigationController alloc] initWithRootViewController:mainVC];
        
        self.window.rootViewController = navController;
        [self.window makeKeyAndVisible];
        // 设置 UILabel 的默认文本颜色为系统动态颜色
        [[UILabel appearance] setTextColor:[UIColor labelColor]];
    }
}

- (void)sceneDidDisconnect:(UIScene *)scene API_AVAILABLE(ios(13.0)) {
    // 场景被释放时调用
}

- (void)sceneDidBecomeActive:(UIScene *)scene API_AVAILABLE(ios(13.0)) {
    // 场景从非活动状态转为活动状态时调用
}

- (void)sceneWillResignActive:(UIScene *)scene API_AVAILABLE(ios(13.0)) {
    // 场景从活动状态转为非活动状态时调用
}

- (void)sceneWillEnterForeground:(UIScene *)scene API_AVAILABLE(ios(13.0)) {
    // 场景从后台进入前台时调用
}

- (void)sceneDidEnterBackground:(UIScene *)scene API_AVAILABLE(ios(13.0)) {
    // 场景从前台进入后台时调用
}

@end
