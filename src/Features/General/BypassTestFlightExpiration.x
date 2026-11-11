#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

// Local UI-only hooks to prevent TestFlight / Dogfooding nag modals from appearing on screen.
// Does NOT modify NSBundle, Info.plist, receipts, or any network/telemetry data sent to Meta.

// 1. Prevent TestFlight Update Nag Controller from initializing its local alert
%hook IGTestFlightUpdateNagController
- (id)initWithAnalyticsLogger:(id)arg1 initWithLauncherSet:(id)arg2 userDefaults:(id)arg3 {
    return nil;
}
%end

// 2. Auto-dismiss TestFlight Nudge View Controller if ever presented locally
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

// 3. Prevent local Dogfooding expiration modal coordinator from triggering lockout UI
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

// 4. Disable local in-app update prompt checks
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
