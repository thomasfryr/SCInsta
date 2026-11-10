#import "../../Utils.h"
#import "../../InstagramHeaders.h"

// Disable story data source
%hook IGMainStoryTrayDataSource
- (id)initWithUserSession:(id)arg1 {
    if ([SCIUtils getBoolPref:@"hide_stories_tray"]) {
        NSLog(@"[SCInsta] Hiding story tray");

        return nil;
    }
    
    return %orig;
}
%end

// Instagram v454.1.0+ Swift-migrated IGMainStoryTrayDataSource
%hook _TtC25IGMainStoryTrayDataSource25IGMainStoryTrayDataSource
- (id)initWithUserSession:(id)arg1 {
    if ([SCIUtils getBoolPref:@"hide_stories_tray"]) {
        NSLog(@"[SCInsta] Hiding story tray");

        return nil;
    }
    
    return %orig;
}
%end