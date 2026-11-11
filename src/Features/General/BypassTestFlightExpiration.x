#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

// Dynamic build date cache to make the build always appear brand new
static NSString *getFreshBuildDate(void) {
    static NSString *cachedDate = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
        formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss";
        cachedDate = [formatter stringFromDate:[NSDate date]];
    });
    return cachedDate;
}

// 1. Spoof App Store Receipt & CFBuildDate so Instagram believes it's a freshly compiled App Store release
%hook NSBundle
- (NSURL *)appStoreReceiptURL {
    NSURL *url = %orig;
    if (url && [[url lastPathComponent] isEqualToString:@"sandboxReceipt"]) {
        return [[url URLByDeletingLastPathComponent] URLByAppendingPathComponent:@"receipt"];
    }
    return url;
}

- (id)objectForInfoDictionaryKey:(NSString *)key {
    if ([key isEqualToString:@"CFBuildDate"]) {
        return getFreshBuildDate();
    }
    return %orig;
}

- (NSDictionary *)infoDictionary {
    NSDictionary *dict = %orig;
    if (dict && dict[@"CFBuildDate"]) {
        NSMutableDictionary *mDict = [dict mutableCopy];
        mDict[@"CFBuildDate"] = getFreshBuildDate();
        return mDict;
    }
    return dict;
}
%end

// 2. Disable TestFlight metric reporting
%hook _TtC16METAAppleMetrics21METAAppleMetricReport
- (BOOL)isTestFlightApp {
    return NO;
}
%end

// 3. Disable TestFlight Update Nag Controller
%hook IGTestFlightUpdateNagController
- (id)initWithAnalyticsLogger:(id)arg1 initWithLauncherSet:(id)arg2 userDefaults:(id)arg3 {
    return nil;
}
%end

// 4. Auto-dismiss TestFlight Nudge View Controller if ever initialized
%hook _TtC29IGCoreRootTestFlightNagPlugin35TestFlightUpdateNudgeViewController
- (void)viewDidLoad {
    %orig;
    [self dismissViewControllerAnimated:NO completion:nil];
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    [self dismissViewControllerAnimated:NO completion:nil];
}
%end

// 5. Bypass Dogfooding expiration coordinator & production lockout
%hook _TtC17IGDogfoodingFirst26DogfoodingFirstCoordinator
- (void)didBeginSessionWithMainAppViewController:(id)arg1 pandoGraphQLService:(id)arg2 dogfooder:(id)arg3 {
    return;
}
- (BOOL)didPassWarningExpirationForUser:(id)arg1 {
    return NO;
}
%end

%hook _TtC17IGDogfoodingFirst41DogfoodingProductionLockoutViewController
- (void)viewDidLoad {
    %orig;
    [self dismissViewControllerAnimated:NO completion:nil];
}
%end

// 6. Silence Dogfooder Prod update checks
%hook IGDogfooderProd
- (void)checkAvailableAppUpdatesWithCompletion:(id)completion {
    return;
}
- (void)checkBuildStatusForBuild:(id)build useCacheResultIfAvailable:(BOOL)cache completion:(id)completion {
    return;
}
- (void)triggerUpdateWithMode:(long long)mode completion:(id)completion {
    return;
}
%end
