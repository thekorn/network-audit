// Opt-in ad observer transport inside the already-scoped Simulator helper.
// WKWebView and all control/message handling stay on the main queue. The runner
// owns the final ledger; this private spool never becomes report input directly.
#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

static NSHashTable<WKWebView *> *auditViews;

@interface WKWebView (NetworkAuditAds)
- (instancetype)networkAudit_initWithFrame:(CGRect)frame configuration:(WKWebViewConfiguration *)configuration __attribute__((objc_method_family(init)));
- (instancetype)networkAudit_initWithCoder:(NSCoder *)coder __attribute__((objc_method_family(init)));
@end

@implementation WKWebView (NetworkAuditAds)
- (instancetype)networkAudit_initWithFrame:(CGRect)frame configuration:(WKWebViewConfiguration *)configuration {
    self = [self networkAudit_initWithFrame:frame configuration:configuration];
    if (self) [auditViews addObject:self];
    return self;
}
- (instancetype)networkAudit_initWithCoder:(NSCoder *)coder {
    self = [self networkAudit_initWithCoder:coder];
    if (self) [auditViews addObject:self];
    return self;
}
@end

@interface NetworkAuditAds : NSObject <WKScriptMessageHandlerWithReply>
@property (copy) NSString *directory;
@property (copy) NSString *lastRequest;
@property (copy) NSString *binding;
@property (strong) WKUserScript *script;
@property (strong) WKUserContentController *controller;
@property (weak) WKWebView *target;
@property (strong) NSFileHandle *spool;
@property (strong) NSError *writeError;
@property BOOL busy;
@property BOOL started;
@end

@implementation NetworkAuditAds
- (void)reply:(NSDictionary *)result request:(NSString *)identifier error:(NSString *)error {
    NSMutableDictionary *response = [NSMutableDictionary dictionaryWithDictionary:result ?: @{}];
    response[@"id"] = identifier;
    if (error) response[@"error"] = error;
    NSData *data = [NSJSONSerialization dataWithJSONObject:response options:0 error:nil];
    [data writeToFile:[self.directory stringByAppendingPathComponent:@"response.json"] atomically:YES];
    self.busy = NO;
}

- (void)removeScript {
    if (!self.script) return;
    // WebKit has no single-script removal API. Retain the CURRENT app scripts,
    // including any installed since capture started, in their original order.
    // Its NSArray wrapper is live and -copy returns itself; mutableCopy makes
    // an independent snapshot before removeAllUserScripts clears the backing array.
    NSArray *scripts = [self.controller.userScripts mutableCopy];
    [self.controller removeAllUserScripts];
    for (WKUserScript *script in scripts) {
        if (script != self.script) [self.controller addUserScript:script];
    }
    self.script = nil;
}

- (void)detach {
    [self removeScript];
    if (self.binding) [self.controller removeScriptMessageHandlerForName:self.binding contentWorld:WKContentWorld.pageWorld];
    [self.spool closeAndReturnError:nil];
    self.spool = nil;
    self.controller = nil;
    self.binding = nil;
}

- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message
                replyHandler:(void (^)(id, NSString *))reply {
    if (message.webView != self.target || !message.frameInfo.isMainFrame) {
        reply(nil, @"Ad messages must come from the selected top-level WKWebView");
        return;
    }
    // null is an ordered flush barrier. Its Promise resolves only after all
    // preceding messages were written, including documentStopped on teardown.
    if ([message.body isKindOfClass:NSString.class] && !self.writeError) {
        NSError *error;
        NSMutableData *line = [[NSJSONSerialization dataWithJSONObject:@{@"payload": message.body} options:0 error:&error] mutableCopy];
        [line appendBytes:"\n" length:1];
        if (line) [self.spool writeData:line error:&error];
        self.writeError = error;
    }
    reply(@YES, self.writeError.localizedDescription);
}

- (void)poll {
    if (self.busy) return;
    NSData *data = [NSData dataWithContentsOfFile:[self.directory stringByAppendingPathComponent:@"request.json"]];
    if (!data) return;
    NSDictionary *request = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![request isKindOfClass:NSDictionary.class] || ![request[@"id"] isKindOfClass:NSString.class]) return;
    NSString *identifier = request[@"id"];
    if ([identifier isEqualToString:self.lastRequest]) return;
    self.lastRequest = identifier;
    self.busy = YES;
    NSString *operation = request[@"operation"];
    if ([operation isEqualToString:@"stop"]) {
        [self removeScript];
        WKWebView *view = self.target;
        if (!view || !self.binding) {
            [self detach];
            [self reply:@{@"flushed": @NO, @"disconnected": @((BOOL)(self.started && !view))} request:identifier error:nil];
            return;
        }
        NSString *source = @"const observed = !!window.__networkAuditAds;"
            "if (observed) window.__networkAuditAds.stop();"
            "await window.webkit.messageHandlers[binding].postMessage(null);"
            "delete window[binding]; delete window.__networkAuditAds; return observed;";
        [view callAsyncJavaScript:source arguments:@{@"binding": self.binding} inFrame:nil inContentWorld:WKContentWorld.pageWorld
               completionHandler:^(id result, NSError *error) {
            [self detach];
            [self reply:@{@"flushed": @((BOOL)(!error && [result boolValue])), @"disconnected": @NO}
                request:identifier error:(error ?: self.writeError).localizedDescription];
        }];
        return;
    }
    NSArray<WKWebView *> *views = auditViews.allObjects;
    if ([operation isEqualToString:@"inspect"]) {
        if (views.count != 1) {
            [self reply:@{@"count": @(views.count)} request:identifier error:nil];
            return;
        }
        [views[0] evaluateJavaScript:@"({url:location.href, gateReady:window.__networkAuditGateReady === true})"
                  completionHandler:^(id result, NSError *error) {
            NSMutableDictionary *target = [NSMutableDictionary dictionaryWithDictionary:result ?: @{}];
            target[@"count"] = @1;
            [self reply:target request:identifier error:error.localizedDescription];
        }];
        return;
    }
    if (![operation isEqualToString:@"start"] || self.started || views.count != 1) {
        [self reply:nil request:identifier error:@"Expected one app WKWebView and a single capture start"];
        return;
    }
    self.started = YES;
    self.target = views[0];
    self.binding = request[@"binding"];
    NSString *path = [self.directory stringByAppendingPathComponent:@"events.jsonl"];
    if (![NSFileManager.defaultManager createFileAtPath:path contents:nil attributes:@{NSFilePosixPermissions: @0600}]) {
        [self reply:nil request:identifier error:@"Cannot create iOS ad message spool"];
        return;
    }
    NSError *error;
    self.spool = [NSFileHandle fileHandleForWritingToURL:[NSURL fileURLWithPath:path] error:&error];
    if (!self.spool) {
        [self reply:nil request:identifier error:error.localizedDescription];
        return;
    }
    self.controller = self.target.configuration.userContentController;
    [self.controller addScriptMessageHandlerWithReply:self contentWorld:WKContentWorld.pageWorld name:self.binding];
    self.script = [[WKUserScript alloc] initWithSource:request[@"source"] injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                    forMainFrameOnly:YES inContentWorld:WKContentWorld.pageWorld];
    [self.controller addUserScript:self.script];
    [self.target callAsyncJavaScript:request[@"initialSource"] arguments:nil inFrame:nil inContentWorld:WKContentWorld.pageWorld
                  completionHandler:^(id result, NSError *error) {
        // Installation and the blank document's messages are acknowledged
        // before navigating, so page JavaScript cannot win the first-auction race.
        NSString *failure = error.localizedDescription;
        if (!failure && request[@"navigateTo"]) {
            NSURL *url = [NSURL URLWithString:request[@"navigateTo"]];
            if (![self.target loadRequest:[NSURLRequest requestWithURL:url]]) failure = @"WKWebView navigation failed";
        }
        [self reply:@{} request:identifier error:failure];
    }];
}
@end

void installAuditAds(NSString *directory) {
    if (!directory.length) return;
    auditViews = NSHashTable.weakObjectsHashTable;
    method_exchangeImplementations(
        class_getInstanceMethod(WKWebView.class, @selector(initWithFrame:configuration:)),
        class_getInstanceMethod(WKWebView.class, @selector(networkAudit_initWithFrame:configuration:)));
    method_exchangeImplementations(
        class_getInstanceMethod(WKWebView.class, @selector(initWithCoder:)),
        class_getInstanceMethod(WKWebView.class, @selector(networkAudit_initWithCoder:)));
    NetworkAuditAds *bridge = [NetworkAuditAds new];
    bridge.directory = directory;
    static dispatch_source_t timer;
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC, 10 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{ [bridge poll]; });
    dispatch_resume(timer);
}
