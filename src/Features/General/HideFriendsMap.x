#import "../../Utils.h"

static NSArray * filterFriendsMap(NSArray *originalObjs) {
    if (![SCIUtils getBoolPref:@"hide_friends_map"]) return originalObjs;

    NSMutableArray *filteredObjs = [NSMutableArray arrayWithCapacity:[originalObjs count]];

    for (id obj in originalObjs) {
        BOOL shouldHide = NO;

        if ([obj isKindOfClass:%c(IGDirectNotesTrayUserViewModel)]
            || [NSStringFromClass([obj class]) containsString:@"IGDirectNotesTrayUserViewModel"]) {

            @try {
                if ([[obj valueForKey:@"notePk"] isEqualToString:@"friends_map"]) {
                    NSLog(@"[SCInsta] Hiding friends map");

                    shouldHide = YES;
                }
            } @catch (NSException *e) {}

        }

        if (!shouldHide) {
            [filteredObjs addObject:obj];
        }
    }

    return [filteredObjs copy];
}

%hook IGDirectNotesTrayRowCell
- (id)listAdapterObjects {
    return filterFriendsMap(%orig());
}
%end

%hook _TtC24IGDirectNotesTrayUISwift24IGDirectNotesTrayRowCell
- (id)listAdapterObjects {
    return filterFriendsMap(%orig());
}
%end