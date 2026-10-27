// Native contract fixture: no audit-specific proxy configuration in this app.
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

@interface WebKitFixture : UIResponder <UIApplicationDelegate, UIWindowSceneDelegate, WKNavigationDelegate>
@property (strong, nonatomic) UIWindow *window;
@property (strong, nonatomic) NSMutableArray<WKWebView *> *webViews;
@end

@implementation WebKitFixture
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [UIViewController new];
    [self.window makeKeyAndVisible];
    self.webViews = [NSMutableArray new];
    NSString *base = NSProcessInfo.processInfo.environment[@"AUDIT_TEST_BASE"];
    NSString *ads = NSProcessInfo.processInfo.environment[@"AUDIT_TEST_ADS"];
    NSArray *kinds = ads && ![ads isEqualToString:@"multiple"] ? @[@"default"] : @[@"default", @"ephemeral", @"named", @"shared", @"decoded"];
    for (NSString *kind in kinds) {
        WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
        if ([kind isEqualToString:@"ephemeral"]) {
            configuration.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;
        } else if ([kind isEqualToString:@"named"]) {
            configuration.websiteDataStore = [WKWebsiteDataStore dataStoreForIdentifier:NSUUID.UUID];
        }
        [configuration.userContentController addUserScript:[[WKUserScript alloc]
            initWithSource:@"window.fixtureScript = 'kept'" injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES]];
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
        if (ads) {
            webView.navigationDelegate = self;
            url = [NSURL URLWithString:[ads isEqualToString:@"late"] ? [base stringByAppendingString:@"/first"] : @"about:blank"];
        }
        [webView loadRequest:[NSURLRequest requestWithURL:url]];
    }
    if (ads) {
        NSString *command = NSProcessInfo.processInfo.environment[@"AUDIT_TEST_COMMAND"];
        [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *timer) {
            NSString *action = [NSString stringWithContentsOfFile:command encoding:NSUTF8StringEncoding error:nil];
            if (!action) return;
            [timer invalidate];
            if ([action isEqualToString:@"close"]) {
                for (WKWebView *view in self.webViews) [view removeFromSuperview];
                [self.webViews removeAllObjects];
            } else {
                [self.webViews[0] loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:[base stringByAppendingString:@"/after-stop"]]]];
            }
        }];
    }
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    if ([webView.URL.absoluteString isEqualToString:@"about:blank"]) {
        [webView evaluateJavaScript:@"window.__networkAuditGateReady = true" completionHandler:nil];
    } else if ([webView.URL.path hasSuffix:@"/first"]) {
        [webView.configuration.userContentController addUserScript:[[WKUserScript alloc]
            initWithSource:@"window.addedDuringCapture = 'retained'" injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES]];
    }
}
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(WebKitFixture.class));
    }
}
