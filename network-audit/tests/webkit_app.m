// Native contract fixture: no audit-specific proxy configuration in this app.
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

@interface WebKitFixture : UIResponder <UIApplicationDelegate, UIWindowSceneDelegate>
@property (strong, nonatomic) UIWindow *window;
@property (strong, nonatomic) NSMutableArray *webViews;
@end

@implementation WebKitFixture
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [UIViewController new];
    [self.window makeKeyAndVisible];
    self.webViews = [NSMutableArray new];
    NSString *base = NSProcessInfo.processInfo.environment[@"AUDIT_TEST_BASE"];
    for (NSString *kind in @[@"default", @"ephemeral", @"named", @"shared", @"decoded"]) {
        WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
        if ([kind isEqualToString:@"ephemeral"]) {
            configuration.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;
        } else if ([kind isEqualToString:@"named"]) {
            configuration.websiteDataStore = [WKWebsiteDataStore dataStoreForIdentifier:NSUUID.UUID];
        }
        WKWebView *webView = [[WKWebView alloc] initWithFrame:self.window.bounds configuration:configuration];
        if ([kind isEqualToString:@"decoded"]) {
            NSError *error;
            NSData *data = [NSKeyedArchiver archivedDataWithRootObject:webView requiringSecureCoding:NO error:&error];
            NSKeyedUnarchiver *decoder = [[NSKeyedUnarchiver alloc] initForReadingFromData:data error:&error];
            decoder.requiresSecureCoding = NO;
            webView = [decoder decodeObjectForKey:NSKeyedArchiveRootObjectKey];
            [decoder finishDecoding];
            if (!webView) {
                NSLog(@"Cannot decode fixture WebView: %@", error);
                abort();
            }
        }
        [self.webViews addObject:webView];
        [self.window.rootViewController.view addSubview:webView];
        NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/%@/main", base, kind]];
        [webView loadRequest:[NSURLRequest requestWithURL:url]];
    }
}
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(WebKitFixture.class));
    }
}
