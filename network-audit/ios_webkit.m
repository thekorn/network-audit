// Loaded only into the audited Simulator app for this launch. The public
// WKWebsiteDataStore proxy API routes its WebKit helpers without intercepting
// any other app, Simulator or host process. No app bundle is modified.
#import <Foundation/Foundation.h>
#import <Network/Network.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#include <TargetConditionals.h>

#if !TARGET_OS_SIMULATOR
#error This helper is for iOS Simulator only.
#endif

static NSArray *auditProxies;
static char configuredStore;

void installAuditAds(NSString *directory);

@interface WKWebViewConfiguration (NetworkAudit)
- (WKWebsiteDataStore *)networkAudit_websiteDataStore;
@end

@implementation WKWebViewConfiguration (NetworkAudit)
- (WKWebsiteDataStore *)networkAudit_websiteDataStore {
    WKWebsiteDataStore *store = [self networkAudit_websiteDataStore];
    // WebKit reads this public getter when constructing both programmatic and
    // decoded WebViews. Configure each persistent/ephemeral store once, before
    // page loads; reapplying a proxy can interrupt existing network operations.
    if (store && !objc_getAssociatedObject(store, &configuredStore)) {
        store.proxyConfigurations = auditProxies;
        objc_setAssociatedObject(store, &configuredStore, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return store;
}
@end

__attribute__((constructor)) static void installAuditProxy(void) {
    @autoreleasepool {
        NSDictionary *environment = NSProcessInfo.processInfo.environment;
        NSString *port = environment[@"NETWORK_AUDIT_PROXY_PORT"];
        NSString *device = environment[@"NETWORK_AUDIT_DEVICE"];
        NSString *bundle = environment[@"NETWORK_AUDIT_BUNDLE"];
        NSString *ready = environment[@"NETWORK_AUDIT_WEBKIT_READY"];
        // Do nothing if a child process inherits DYLD_INSERT_LIBRARIES. Both
        // ownership checks must match, not just a shared executable name.
        if (!device.length || ![device isEqualToString:environment[@"SIMULATOR_UDID"]] ||
            !bundle.length || ![bundle isEqualToString:NSBundle.mainBundle.bundleIdentifier]) {
            return;
        }
        if (!ready.length || port.intValue < 1 || port.intValue > 65535) return;
        Method original = class_getInstanceMethod(WKWebViewConfiguration.class, @selector(websiteDataStore));
        Method replacement = class_getInstanceMethod(WKWebViewConfiguration.class, @selector(networkAudit_websiteDataStore));
        if (!original || !replacement) return;
        nw_endpoint_t endpoint = nw_endpoint_create_host("127.0.0.1", port.UTF8String);
        nw_proxy_config_t proxy = nw_proxy_config_create_http_connect(endpoint, NULL);
        // Never silently go direct when the audit proxy is unavailable.
        nw_proxy_config_set_failover_allowed(proxy, false);
        auditProxies = @[proxy];
        method_exchangeImplementations(original, replacement);
        installAuditAds(environment[@"NETWORK_AUDIT_IOS_AD_CHANNEL"]);
        [@"ready\n" writeToFile:ready atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}
