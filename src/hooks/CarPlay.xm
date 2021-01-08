#include "../common.h"
#include "../crash_reporting/reporting.h"

/*
Injected into the CarPlay process
*/
%group CARPLAY

struct SBIconImageInfo {
    struct CGSize size;
    double scale;
    double continuousCornerRadius;
};

%hook CARApplication
/*
Given an FBSApplicationLibrary, force all apps within the library to show up on the CarPlay dashboard.
Exclude system apps (they are always glitchy for some reason) and enforce a blacklist.
If an app already supports CarPlay, leave it alone
*/
void addCarplayDeclarationsToAppLibrary(id appLibrary)
{
    // Load blacklisted identifiers from filesystem
    NSArray *blacklistedIdentifiers = nil;
    if ([[NSFileManager defaultManager] fileExistsAtPath:BLACKLIST_PLIST_PATH])
    {
        blacklistedIdentifiers = [NSArray arrayWithContentsOfFile:BLACKLIST_PLIST_PATH];
    }

    for (id appInfo in objcInvoke(appLibrary, @"allInstalledApplications"))
    {
        if (getIvar(appInfo, @"_carPlayDeclaration") == nil)
        {
            // Skip system apps
            if ([objcInvoke(appInfo, @"bundleType") isEqualToString:@"User"] == NO)
            {
                continue;
            }

            // Skip if blacklisted
            NSString *appBundleID = objcInvoke(appInfo, @"bundleIdentifier");
            if (blacklistedIdentifiers && [blacklistedIdentifiers containsObject:appBundleID])
            {
                continue;
            }

            // Create a fake declaration so this app appears to support carplay.
            id carplayDeclaration = [[objc_getClass("CRCarPlayAppDeclaration") alloc] init];
            // This is not template-driven -- important. Without specifying this, the process that hosts the Templates will continuously spin up
            // and crash, trying to find a non-existant template for this declaration
            if(!IS_IOS13) {
                // These dont exist on iOS 13
                objcInvoke_1(carplayDeclaration, @"setSupportsTemplates:", 0);
                objcInvoke_1(carplayDeclaration, @"setBundlePath:", objcInvoke(appInfo, @"bundleURL"));
            }
            
            objcInvoke_1(carplayDeclaration, @"setSupportsMaps:", 1);
            objcInvoke_1(carplayDeclaration, @"setBundleIdentifier:", appBundleID);
            
            setIvar(appInfo, @"_carPlayDeclaration", carplayDeclaration);

            // Add a tag to the app, to keep track of which apps have been "forced" into carplay
            NSArray *newTags = @[@"CarPlayEnable"];
            if (objcInvoke(appInfo, @"tags"))
            {
                newTags = [newTags arrayByAddingObjectsFromArray:objcInvoke(appInfo, @"tags")];
            }
            setIvar(appInfo, @"_tags", newTags);
        }
    }
}

/*
Include all User applications on the CarPlay dashboard
*/
+ (id)_newApplicationLibrary
{
    LOG_LIFECYCLE_EVENT;
    // %orig creates an app library that only contains Carplay-enabled stuff, so its not useful.
    // Create an app library that contains everything
    id allAppsConfiguration = [[objc_getClass("FBSApplicationLibraryConfiguration") alloc] init];
    objcInvoke_1(allAppsConfiguration, @"setApplicationInfoClass:", objc_getClass("CARApplicationInfo"));
    objcInvoke_1(allAppsConfiguration, @"setApplicationPlaceholderClass:", objc_getClass("FBSApplicationPlaceholder"));
    objcInvoke_1(allAppsConfiguration, @"setAllowConcurrentLoading:", 1);
    objcInvoke_1(allAppsConfiguration, @"setInstalledApplicationFilter:", ^BOOL(id appProxy, NSSet *arg2) {
        NSArray *appTags = objcInvoke(appProxy, @"appTags");
        // Skip apps with a Hidden tag
        if ([appTags containsObject:@"hidden"])
        {
            return 0;
        }
        return 1;
    });

    id allAppsLibrary = objcInvoke_1([objc_getClass("FBSApplicationLibrary") alloc], @"initWithConfiguration:", allAppsConfiguration);
    // Add a "carplay declaration" to each app so they appear on the dashboard
    addCarplayDeclarationsToAppLibrary(allAppsLibrary);

    NSArray *systemIdentifiers = @[@"com.apple.CarPlayTemplateUIHost", @"com.apple.MusicUIService", @"com.apple.springboard", @"com.apple.InCallService", @"com.apple.CarPlaySettings", @"com.apple.CarPlayApp"];
    for (NSString *systemIdent in systemIdentifiers)
    {
        id appProxy = objcInvoke_1(objc_getClass("LSApplicationProxy"), @"applicationProxyForIdentifier:", systemIdent);
        id appState = objcInvoke(appProxy, @"appState");
        if (objcInvokeT(appState, @"isValid", int) == 1)
        {
            objcInvoke_2(allAppsLibrary, @"addApplicationProxy:withOverrideURL:", appProxy, 0);
        }
    }

    return allAppsLibrary;
}

%end

/*
Carplay dashboard icon appearance
*/
%hook SBIconListGridLayoutConfiguration

/*
Make the CarPlay dashboard show 5 columns of apps instead of 4
*/
- (void)setNumberOfPortraitColumns:(int)arg1
{
    // TODO: changes depending on radio screen size
    int minColumns = MAX(5, arg1);
    %orig(minColumns);
}

/*
Make the Carplay dashboard icons a little smaller so 5 fit comfortably
*/
- (struct SBIconImageInfo)iconImageInfoForGridSizeClass:(unsigned long long)arg1
{
    struct SBIconImageInfo info = %orig;
    info.size = CGSizeMake(50, 50);

    return info;
}

%end

/*
When an app is launched via Carplay dashboard
*/
%hook CARApplicationLaunchInfo

+ (id)launchInfoForApplication:(id)arg1 withActivationSettings:(id)arg2
{
    // An app is being launched. Use the attached tags to determine if carplay support has been coerced onto it
    if ([objcInvoke(arg1, @"tags") containsObject:@"CarPlayEnable"])
    {
        LOG_LIFECYCLE_EVENT;
        // Notify SpringBoard of the launch. SpringBoard will host the application + UI
        [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotificationName:@"com.carplayenable" object:nil userInfo:@{@"identifier": objcInvoke(arg1, @"bundleIdentifier")}];

        // Add this item into the App History (so it shows up in the dock's "recents")
        id sharedApp = [UIApplication sharedApplication];
        id appHistory = objcInvoke(sharedApp, @"_currentAppHistory");

        NSString *previousBundleID = nil;
        NSArray *orderedAppHistory = objcInvoke(appHistory, @"orderedAppHistory");
        if ([orderedAppHistory count] > 0)
        {
            previousBundleID = objcInvoke([orderedAppHistory firstObject], @"bundleIdentifier");
        }

        ((void (*)(id, SEL, id, id))objc_msgSend)(appHistory, NSSelectorFromString(@"_bundleIdentifierDidBecomeVisible:previousBundleIdentifier:"), objcInvoke(arg1, @"bundleIdentifier"), previousBundleID);

        id dashboardRootController = objcInvoke(objcInvoke(sharedApp, @"_currentDashboard"), @"rootViewController");
        id dockController = objcInvoke(dashboardRootController, @"appDockViewController");
        objcInvoke(dockController, @"_refreshAppDock");

        // If there is already a native-Carplay app running, close it
        id dashboard = objcInvoke(sharedApp, @"_currentDashboard");
        assertGotExpectedObject(dashboard, @"CARDashboard");
        NSDictionary *foregroundScenes = objcInvoke(dashboard, @"identifierToForegroundAppScenesMap");
        if ([[foregroundScenes allKeys] count] > 0)
        {
            id homeButtonEvent = objcInvoke_2(objc_getClass("CAREvent"), @"eventWithType:context:", 1, @"Close carplay app");
            assertGotExpectedObject(homeButtonEvent, @"CAREvent");
            objcInvoke_1(dashboard, @"handleEvent:", homeButtonEvent);
        }

        return nil;
    }

    return %orig;
}

%end

/*
When an app is launched via the Carplay Dock
*/
%hook CARAppDockViewController

- (void)_dockButtonPressed:(id)arg1
{
    %orig;

    NSString *bundleID = objcInvoke(arg1, @"bundleIdentifier");
    id sharedApp = [UIApplication sharedApplication];
    id appLibrary = objcInvoke(sharedApp, @"sharedApplicationLibrary");
    id selectedAppInfo = objcInvoke_1(appLibrary, @"applicationInfoForBundleIdentifier:", bundleID);
    if ([objcInvoke(selectedAppInfo, @"tags") containsObject:@"CarPlayEnable"])
    {
        objcInvoke_1(self, @"setDockEnabled:", 1);
    }
}

%end


/*
Called when an app is installed or uninstalled.
Used for adding "carplay declaration" to newly installed apps so they appear on the dashboard
*/
%hook _CARDashboardHomeViewController

- (void)_handleAppLibraryRefresh
{
    id appLibrary = objcInvoke(self, @"library");
    addCarplayDeclarationsToAppLibrary(appLibrary);
    %orig;
}

%end


/*
App icons on the Carplay dashboard.
For apps that natively support Carplay, add a longpress gesture to launch it in "full mode". Tapping them
will launch their normal Carplay mode UI
*/
%hook CARIconView

%new
- (void)handleLaunchAppInNormalMode:(UILongPressGestureRecognizer *)gesture
{
    if ([gesture state] == UIGestureRecognizerStateBegan)
    {
        id icon = objcInvoke(self, @"icon");
        assertGotExpectedObject(icon, @"SBIcon");
        NSString *bundleID = objcInvoke(icon, @"applicationBundleID");

        [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotificationName:@"com.carplayenable" object:nil userInfo:@{@"identifier": bundleID}];

        id sharedApp = [UIApplication sharedApplication];
        id appHistory = objcInvoke(sharedApp, @"_currentAppHistory");

        NSString *previousBundleID = nil;
        NSArray *orderedAppHistory = objcInvoke(appHistory, @"orderedAppHistory");
        if ([orderedAppHistory count] > 0)
        {
            previousBundleID = objcInvoke([orderedAppHistory firstObject], @"bundleIdentifier");
        }
        ((void (*)(id, SEL, id, id))objc_msgSend)(appHistory, NSSelectorFromString(@"_bundleIdentifierDidBecomeVisible:previousBundleIdentifier:"), bundleID, previousBundleID);

        id dashboardRootController = objcInvoke(objcInvoke(sharedApp, @"_currentDashboard"), @"rootViewController");
        id dockController = objcInvoke(dashboardRootController, @"appDockViewController");
        objcInvoke(dockController, @"_refreshAppDock");
    }
}

- (id)initWithConfigurationOptions:(unsigned long long)arg1 listLayoutProvider:(id)arg2
{
    id iconView = %orig;

    // Add long press gesture to the dashboard's icons
    UILongPressGestureRecognizer *launchGesture = [[UILongPressGestureRecognizer alloc] initWithTarget:iconView action:NSSelectorFromString(@"handleLaunchAppInNormalMode:")];
    [launchGesture setMinimumPressDuration:1.5];
    [iconView addGestureRecognizer:launchGesture];

    return iconView;
}

%end

%end

%group CARPLAY13

%hook CRCarPlayAppDeclaration
%property (assign,nonatomic) BOOL CarPlayEnable; 

+(id)declarationForAppProxy:(id)arg1
{
    // arg1 LSApplicationProxy

	id orig = %orig;
    if (orig == nil) {
        orig = [[objc_getClass("CRCarPlayAppDeclaration") alloc] init];
        objcInvoke_1(orig, @"setBundleIdentifier:", objcInvoke(arg1, @"applicationIdentifier"));
        objcInvoke_1(orig, @"setSupportsMaps:", 1);

        // keep track of force enabled apps
        objcInvoke_1(orig, @"setCarPlayEnable:", 1);
    }

	return orig;
}
%end

%hook CRCarPlayAppPolicyEvaluator

-(id)effectivePolicyForAppDeclaration:(id)arg1
{
    id orig = %orig;
    if (objcInvokeT(arg1, @"CarPlayEnable", BOOL)) {
        // dont launch as template
        objcInvoke_1(orig, @"setLaunchUsingMapsTemplateUI:", 0);
    }
    return orig;
}

%end


%hook SBHIconManager

// handle portal icon open
-(void)iconTapped:(id)arg1
{
    id bundleIdentifier = objcInvoke(objcInvoke(arg1, @"icon"), @"applicationBundleID");
    id proxy = objcInvoke_1(objc_getClass("LSApplicationProxy"), @"applicationProxyForIdentifier:", bundleIdentifier);
    id declaration = objcInvoke_1(objc_getClass("CRCarPlayAppDeclaration"), @"declarationForAppProxy:", proxy);

    if (objcInvokeT(declaration, @"CarPlayEnable", BOOL))
    {
        LOG_LIFECYCLE_EVENT;
        // Notify SpringBoard of the launch. SpringBoard will host the application + UI
        [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotificationName:@"com.carplayenable" object:nil userInfo:@{@"identifier": bundleIdentifier}];

        // Add this item into the App History (so it shows up in the dock's "recents")
        id sharedApp = [UIApplication sharedApplication];
        id appHistory = objcInvoke(sharedApp, @"_currentAppHistory");

        NSString *previousBundleID = nil;
        NSArray *orderedAppHistory = objcInvoke(appHistory, @"orderedAppHistory");
        if ([orderedAppHistory count] > 0)
        {
            previousBundleID = objcInvoke([orderedAppHistory firstObject], @"bundleIdentifier");
        }

        ((void (*)(id, SEL, id, id))objc_msgSend)(appHistory, NSSelectorFromString(@"_bundleIdentifierDidBecomeVisible:previousBundleIdentifier:"), bundleIdentifier, previousBundleID);

        id dashboardRootController = objcInvoke(objcInvoke(sharedApp, @"_currentDashboard"), @"rootViewController");
        id dockController = objcInvoke(dashboardRootController, @"appDockViewController");
        objcInvoke(dockController, @"_refreshAppDock");

        // If there is already a native-Carplay app running, close it
        id dashboard = objcInvoke(sharedApp, @"_currentDashboard");
        assertGotExpectedObject(dashboard, @"CARDashboard");
        NSDictionary *foregroundScenes = objcInvoke(dashboard, @"identifierToForegroundAppScenesMap");
        if ([[foregroundScenes allKeys] count] > 0)
        {
            id homeButtonEvent = objcInvoke_2(objc_getClass("CAREvent"), @"eventWithType:context:", 1, @"Close carplay app");
            assertGotExpectedObject(homeButtonEvent, @"CAREvent");
            objcInvoke_1(dashboard, @"handleEvent:", homeButtonEvent);
        }
        return;
    }
    %orig;
}

%end

%end


%ctor
{
    if ([[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.CarPlayApp"])
    {
        if(IS_IOS13) {
            %init(CARPLAY13);
        }
        %init(CARPLAY);
        // Upload any relevant crashlogs
        symbolicateAndUploadCrashlogs();
    }
}