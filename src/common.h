#include <Foundation/Foundation.h>
#include <UIKit/UIKit.h>
#include <objc/message.h>
#include <dlfcn.h>

#define BAIL_IF_UNSUPPORTED_IOS { \
    if ([[[UIDevice currentDevice] systemVersion] compare:@"14.0" options:NSNumericSearch] == NSOrderedAscending) \
    { \
        return; \
    } \
}

#define IS_IOS13 (kCFCoreFoundationVersionNumber < 1751.108)

#define LOG_LIFECYCLE_EVENT { \
    NSString *func = [NSString stringWithFormat:@"%s", __func__]; \
    if ([func containsString:@"_method$"]) \
    { \
        NSArray *components = [func componentsSeparatedByString:@"$"]; \
        func = [NSString stringWithFormat:@"[%@ %@]", components[2], components[3]]; \
    } \
    NSLog(@"LOG_LIFECYCLE_EVENT %@", func); \
}

#define BLACKLIST_PLIST_PATH @"/var/mobile/Library/Preferences/com.carplayenable.blacklisted-apps.plist"

#define getIvar(object, ivar) [object valueForKey:ivar]
#define setIvar(object, ivar, value) [object setValue:value forKey:ivar]

#define objcInvokeT(a, b, t) ((t (*)(id, SEL))objc_msgSend)(a, NSSelectorFromString(b))
#define objcInvoke(a, b) objcInvokeT(a, b, id)
#define objcInvoke_1(a, b, c) ((id (*)(id, SEL, typeof(c)))objc_msgSend)(a, NSSelectorFromString(b), c)
#define objcInvoke_2(a, b, c, d) ((id (*)(id, SEL, typeof(c), typeof(d)))objc_msgSend)(a, NSSelectorFromString(b), c, d)
#define objcInvoke_3(a, b, c, d, e) ((id (*)(id, SEL, typeof(c), typeof(d), typeof(e)))objc_msgSend)(a, NSSelectorFromString(b), c, d, e)

#define assertGotExpectedObject(obj, type) if (!obj || ![obj isKindOfClass:NSClassFromString(type)]) [NSException raise:@"UnexpectedObjectException" format:@"Expected %@ but got %@", type, obj]

#define kPropertyKey_liveCarplayWindow *NSSelectorFromString(@"liveCarplayWindow")
#define kPropertyKey_lockAssertionIdentifiers *NSSelectorFromString(@"lockAssertions")
static char *kPropertyKey_didDrawPlaceholder;

#define CARPLAY_DOCK_WIDTH 40

extern int (*orig_BKSDisplayServicesSetScreenBlanked)(int);