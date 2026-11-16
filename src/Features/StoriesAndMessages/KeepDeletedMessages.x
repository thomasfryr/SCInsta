#import "../../Utils.h"
#import "../../InstagramHeaders.h"

%hook IGDirectRealtimeIrisThreadDelta
+ (id)removeItemWithMessageId:(id)arg1 {
    if ([SCIUtils getBoolPref:@"keep_deleted_message"]) {
        arg1 = NULL;
    }

    return %orig(arg1);
}
- (BOOL)matchBooleanAddItem:(id)arg1 removeItem:(id)arg2 replaceItem:(id)arg3 mutateItem:(id)arg4 mutateThreadMetadata:(id)arg5 markSeen:(id)arg6 replaceThreadMetadata:(id)arg7 removeThread:(id)arg8 markSeenDisappearingMessages:(id)arg9 refetchItem:(id)arg10 {
    if ([SCIUtils getBoolPref:@"keep_deleted_message"]) {
        if ([self valueForKey:@"_removeItem_messageId"] != nil) {
            return NO;
        }
    }
    return %orig;
}
%end

%hook IGDirectRealtimeIrisThreadDeltaMatcher
+ (void)match:(id)delta addItem:(id)arg2 removeItem:(id)arg3 replaceItem:(id)arg4 mutateItem:(id)arg5 mutateThreadMetadata:(id)arg6 markSeen:(id)arg7 replaceThreadMetadata:(id)arg8 removeThread:(id)arg9 markSeenDisappearingMessages:(id)arg10 refetchItem:(id)arg11 {
    if ([SCIUtils getBoolPref:@"keep_deleted_message"]) {
        if (delta && [delta valueForKey:@"_removeItem_messageId"] != nil) {
            return;
        }
    }
    %orig;
}
%end

%hook IGDirectMessageUpdate
+ (id)removeMessageWithMessageId:(id)arg1{
    if ([SCIUtils getBoolPref:@"keep_deleted_message"]) {
        arg1 = NULL;
    }
    
    return %orig(arg1);
}
%end