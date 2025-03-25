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

// SceneDelegate.m
// Adding detailed logs to the scene:willConnectToSession:options: method

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions API_AVAILABLE(ios(13.0)) {
    // Starting logs
    NSLog(@"[SceneDelegate] Beginning execution of scene:willConnectToSession:options: method");
    
    // Only set window and rootViewController in iOS 13 and above
    NSLog(@"[SceneDelegate] scene:willConnectToSession:options");
    if ([scene isKindOfClass:[UIWindowScene class]]) {
        NSLog(@"[SceneDelegate] Scene is UIWindowScene type");
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        NSLog(@"[SceneDelegate] Successfully converted to windowScene");
        
        self.window = [[UIWindow alloc] initWithWindowScene:windowScene];
        NSLog(@"[SceneDelegate] Window created successfully: %@", self.window);
        
        self.window.backgroundColor = [UIColor systemBackgroundColor];
        NSLog(@"[SceneDelegate] Window background color set");
        
        MainViewController *mainVC = [[MainViewController alloc] init];
        NSLog(@"[SceneDelegate] MainViewController created successfully: %@", mainVC);
        
        UINavigationController *navController = [[UINavigationController alloc] initWithRootViewController:mainVC];
        NSLog(@"[SceneDelegate] NavigationController created successfully: %@", navController);
        
        self.window.rootViewController = navController;
        NSLog(@"[SceneDelegate] rootViewController set successfully");
        
        [self.window makeKeyAndVisible];
        NSLog(@"[SceneDelegate] makeKeyAndVisible completed");
        
        // Set default text color for UILabel to system dynamic color
        [[UILabel appearance] setTextColor:[UIColor labelColor]];
        NSLog(@"[SceneDelegate] Default UILabel color set");
    } else {
        NSLog(@"[SceneDelegate] Error: Scene is not UIWindowScene type");
    }
    NSLog(@"[SceneDelegate] Completed execution of scene:willConnectToSession:options: method");
}

// Adding logs to other lifecycle methods
- (void)sceneDidDisconnect:(UIScene *)scene API_AVAILABLE(ios(13.0)) {
    NSLog(@"[SceneDelegate] sceneDidDisconnect called");
}

- (void)sceneDidBecomeActive:(UIScene *)scene API_AVAILABLE(ios(13.0)) {
    NSLog(@"[SceneDelegate] sceneDidBecomeActive called");
}

- (void)sceneWillResignActive:(UIScene *)scene API_AVAILABLE(ios(13.0)) {
    NSLog(@"[SceneDelegate] sceneWillResignActive called");
}

- (void)sceneWillEnterForeground:(UIScene *)scene API_AVAILABLE(ios(13.0)) {
    NSLog(@"[SceneDelegate] sceneWillEnterForeground called");
}

- (void)sceneDidEnterBackground:(UIScene *)scene API_AVAILABLE(ios(13.0)) {
    NSLog(@"[SceneDelegate] sceneDidEnterBackground called");
}

@end
