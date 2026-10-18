// The private API boundary for cold Simulator checkpoints. The selectors and
// framework discovery follow facebook/idb's SimulatorServiceContext/SimulatorSet.
// Compile with the selected Xcode, not Nix's compiler or an iPhoneSimulator SDK.
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

@protocol AuditContext <NSObject>
+ (id)sharedServiceContextForDeveloperDir:(NSString *)path error:(NSError **)error;
- (id)defaultDeviceSetWithError:(NSError **)error;
- (id)deviceSetWithPath:(NSString *)path error:(NSError **)error;
@end

@protocol AuditDevice <NSObject>
- (NSUUID *)UDID;
- (NSString *)stateString;
@end

@protocol AuditDeviceSet <NSObject>
- (NSDictionary *)devicesByUDID;
- (id)cloneDevice:(id)device name:(NSString *)name toSet:(id)set error:(NSError **)error;
@end

static int fail(NSString *message, NSError *error) {
    fprintf(stderr, "iOS checkpoint clone: %s%s%s\n", message.UTF8String,
            error ? ": " : "", error ? error.localizedDescription.UTF8String : "");
    return 1;
}

static id<AuditDeviceSet> deviceSet(id<AuditContext> context, NSString *path, NSError **error) {
    if ([path isEqualToString:@"-"]) {
        return [context defaultDeviceSetWithError:error];
    }
    // The Python caller creates and realpaths custom sets. Do not create paths
    // here: a typo must not silently select an empty source set.
    BOOL directory = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&directory] || !directory) {
        return nil;
    }
    return [context deviceSetWithPath:path error:error];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 6 || geteuid() == 0) {
            return fail(@"expected developer-dir source-set destination-set UUID name (not as root)", nil);
        }
        NSString *developer = @(argv[1]);
        NSUUID *identifier = [[NSUUID alloc] initWithUUIDString:@(argv[4])];
        if (!developer.length || !identifier || !strlen(argv[5])) {
            return fail(@"invalid developer directory, UUID or name", nil);
        }
        NSError *error = nil;
        NSBundle *framework = [NSBundle bundleWithPath:
            @"/Library/Developer/PrivateFrameworks/CoreSimulator.framework"];
        if (!framework || ![framework loadAndReturnError:&error]) {
            return fail(@"cannot load CoreSimulator", error);
        }
        Class<AuditContext> contextClass = (Class<AuditContext>)NSClassFromString(@"SimServiceContext");
        if (!contextClass || ![contextClass respondsToSelector:
                @selector(sharedServiceContextForDeveloperDir:error:)]) {
            return fail(@"this Xcode does not expose the required service context API", nil);
        }
        id<AuditContext> context = [contextClass sharedServiceContextForDeveloperDir:developer error:&error];
        if (!context || ![context respondsToSelector:@selector(defaultDeviceSetWithError:)] ||
            ![context respondsToSelector:@selector(deviceSetWithPath:error:)]) {
            return fail(@"cannot access Simulator device sets", error);
        }
        id<AuditDeviceSet> source = deviceSet(context, @(argv[2]), &error);
        id<AuditDeviceSet> destination = deviceSet(context, @(argv[3]), &error);
        if (!source || !destination || ![source respondsToSelector:@selector(devicesByUDID)] ||
            ![source respondsToSelector:@selector(cloneDevice:name:toSet:error:)]) {
            return fail(@"this Xcode does not expose cross-device-set cloning", error);
        }
        id<AuditDevice> device = [source devicesByUDID][identifier];
        if (!device || ![device respondsToSelector:@selector(stateString)] ||
            ![[device stateString] isEqualToString:@"Shutdown"]) {
            return fail(@"source Simulator must exist and be shut down", nil);
        }
        id<AuditDevice> clone = [source cloneDevice:device name:@(argv[5]) toSet:destination error:&error];
        if (!clone || ![clone respondsToSelector:@selector(UDID)]) {
            return fail(@"cloning failed", error);
        }
        puts([clone UDID].UUIDString.UTF8String);
        return 0;
    }
}
