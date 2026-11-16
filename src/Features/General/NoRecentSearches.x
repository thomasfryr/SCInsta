#import "../../Utils.h"
#import "../../InstagramHeaders.h"

// Disable logging of searches at server-side
%hook IGSearchEntityRouter
- (id)initWithUserSession:(id)arg1 analyticsModule:(id)arg2 shouldAddToRecents:(BOOL)shouldAddToRecents {
    if ([SCIUtils getBoolPref:@"no_recent_searches"]) {
        NSLog(@"[SCInsta] Disabling recent searches");

        shouldAddToRecents = false;
    }
    
    return %orig(arg1, arg2, shouldAddToRecents);
}
%end

%hook _TtC20IGSearchEntityRouter20IGSearchEntityRouter
- (id)initWithUserSession:(id)arg1 analyticsModule:(id)arg2 shouldAddToRecents:(BOOL)shouldAddToRecents {
    if ([SCIUtils getBoolPref:@"no_recent_searches"]) {
        NSLog(@"[SCInsta] Disabling recent searches");

        shouldAddToRecents = false;
    }

    return %orig(arg1, arg2, shouldAddToRecents);
}
- (id)initWithUserSession:(id)arg1 analyticsModule:(id)arg2 shouldAddToRecents:(BOOL)shouldAddToRecents mode:(NSInteger)mode {
    if ([SCIUtils getBoolPref:@"no_recent_searches"]) {
        NSLog(@"[SCInsta] Disabling recent searches");

        shouldAddToRecents = false;
    }

    return %orig(arg1, arg2, shouldAddToRecents, mode);
}
%end

// Most in-app search bars
%hook IGRecentSearchStore
- (id)initWithDiskManager:(id)arg1 recentSearchStoreConfiguration:(id)arg2 {
    if ([SCIUtils getBoolPref:@"no_recent_searches"]) {
        NSLog(@"[SCInsta] Disabling recent searches");

        return nil;
    }

    return %orig;
}
- (BOOL)addItem:(id)arg1 {
    if ([SCIUtils getBoolPref:@"no_recent_searches"]) {
        NSLog(@"[SCInsta] Disabling recent searches");

        return nil;
    }

    return %orig;
}
%end

%hook _TtC20IGRecentSearchStores26IGRecentSearchStoreService
- (id)initWithBlendedSearchRecentItemsOrderStore:(id)arg1 autocompleteUsersStore:(id)arg2 recentHashtagsStore:(id)arg3 recentPlacesStore:(id)arg4 recentKeywordsStore:(id)arg5 recentKeywordEchosStore:(id)arg6 recentDiscoveryMapSearchStore:(id)arg7 userMap:(id)arg8 sessionUserDefaults:(id)arg9 networker:(id)arg10 pandoGraphQLService:(id)arg11 launcherSet:(id)arg12 {
    if ([SCIUtils getBoolPref:@"no_recent_searches"]) {
        NSLog(@"[SCInsta] Disabling recent searches");

        return nil;
    }

    return %orig;
}
%end

// Recent dm message recipients search bar
%hook IGDirectRecipientRecentSearchStorage
- (id)initWithDiskManager:(id)arg1 directCache:(id)arg2 userStore:(id)arg3 currentUser:(id)arg4 featureSets:(id)arg5 {
    if ([SCIUtils getBoolPref:@"no_recent_searches"]) {
        NSLog(@"[SCInsta] Disabling recent searches");

        return nil;
    }

    return %orig;
}
- (id)initWithDiskManager:(id)arg1 directRepo:(id)arg2 launcherSet:(id)arg3 {
    if ([SCIUtils getBoolPref:@"no_recent_searches"]) {
        NSLog(@"[SCInsta] Disabling recent searches");

        return nil;
    }

    return %orig;
}
%end