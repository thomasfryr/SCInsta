#import "../../Utils.h"

// Demangled name: IGFeedPlayback.IGFeedPlaybackStrategy
%hook _TtC14IGFeedPlayback22IGFeedPlaybackStrategy
- (id)initWithShouldDisableAutoplay:(_Bool)autoplay {
    if ([SCIUtils getBoolPref:@"disable_feed_autoplay"]) return %orig(true);

    return %orig(autoplay);
}
- (id)initWithShouldDisableAutoplay:(_Bool)autoplay shouldClearStaleReservation:(_Bool)arg2 {
    if ([SCIUtils getBoolPref:@"disable_feed_autoplay"]) return %orig(true, arg2);

    return %orig(autoplay, arg2);
}
- (id)initWithShouldDisableAutoplay:(_Bool)autoplay shouldClearStaleReservation:(_Bool)arg2 shouldBypassDisabledAutoplayForVoiceover:(_Bool)arg3 {
    if ([SCIUtils getBoolPref:@"disable_feed_autoplay"]) return %orig(true, arg2, arg3);

    return %orig(autoplay, arg2, arg3);
}
- (id)initWithShouldDisableAutoplay:(_Bool)autoplay shouldClearStaleReservation:(_Bool)arg2 shouldBypassDisabledAutoplayForVoiceover:(_Bool)arg3 shouldOverrideDefaultThresholds:(_Bool)arg4 mobileConfig:(id)arg5 {
    if ([SCIUtils getBoolPref:@"disable_feed_autoplay"]) return %orig(true, arg2, arg3, arg4, arg5);

    return %orig(autoplay, arg2, arg3, arg4, arg5);
}
%end