#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <substrate.h>

// Spoof mainBundle bundleIdentifier to "com.burbn.instagram" so that Meta's
// internal Direct Messaging engine (igd.mdcore.orchestrator), Keychain access,
// and Swift String bridging routines receive the official identifier even when
// the IPA is packaged with a secondary Bundle ID (com.scinsta.app) and resigned
// via AltServer-Linux (which lacks Sideloadly's proprietary bundle spoofer).
%hook NSBundle
- (NSString *)bundleIdentifier {
    if (self == [NSBundle mainBundle]) {
        return @"com.burbn.instagram";
    }
    return %orig;
}
%end

// Keychain access group sanitization for free 7-day developer certificates.
// Meta's MDCore queries shared keychain access groups (kSecAttrAccessGroup)
// that do not exist under free provisioning profiles, which can return kCFNull
// or invalid references and crash String._unconditionallyBridgeFromObjectiveC
// in igd.mdcore.orchestrator (~45s after launch).
static CFDictionaryRef createSanitizedKeychainDict(CFDictionaryRef dict) {
    if (!dict || !CFDictionaryContainsKey(dict, kSecAttrAccessGroup)) {
        return NULL;
    }
    CFMutableDictionaryRef mutableCopy = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, dict);
    if (mutableCopy) {
        CFDictionaryRemoveValue(mutableCopy, kSecAttrAccessGroup);
    }
    return mutableCopy;
}

static OSStatus (*orig_SecItemCopyMatching)(CFDictionaryRef query, CFTypeRef *result);
static OSStatus hook_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    CFDictionaryRef sanitizedQuery = createSanitizedKeychainDict(query);
    OSStatus status = orig_SecItemCopyMatching(sanitizedQuery ? sanitizedQuery : query, result);
    if (sanitizedQuery) {
        CFRelease(sanitizedQuery);
    }

    if (status == errSecSuccess && result != NULL) {
        if (*result == NULL || *result == (CFTypeRef)kCFNull) {
            if (*result == (CFTypeRef)kCFNull) {
                CFRelease(*result);
            }
            *result = NULL;
            return errSecItemNotFound;
        }
    }

    return status;
}

static OSStatus (*orig_SecItemAdd)(CFDictionaryRef attributes, CFTypeRef *result);
static OSStatus hook_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    CFDictionaryRef sanitizedAttrs = createSanitizedKeychainDict(attributes);
    OSStatus status = orig_SecItemAdd(sanitizedAttrs ? sanitizedAttrs : attributes, result);
    if (sanitizedAttrs) {
        CFRelease(sanitizedAttrs);
    }
    return status;
}

static OSStatus (*orig_SecItemUpdate)(CFDictionaryRef query, CFDictionaryRef attributesToUpdate);
static OSStatus hook_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
    CFDictionaryRef sanitizedQuery = createSanitizedKeychainDict(query);
    CFDictionaryRef sanitizedAttrs = createSanitizedKeychainDict(attributesToUpdate);
    OSStatus status = orig_SecItemUpdate(
        sanitizedQuery ? sanitizedQuery : query,
        sanitizedAttrs ? sanitizedAttrs : attributesToUpdate
    );
    if (sanitizedQuery) {
        CFRelease(sanitizedQuery);
    }
    if (sanitizedAttrs) {
        CFRelease(sanitizedAttrs);
    }
    return status;
}

static OSStatus (*orig_SecItemDelete)(CFDictionaryRef query);
static OSStatus hook_SecItemDelete(CFDictionaryRef query) {
    CFDictionaryRef sanitizedQuery = createSanitizedKeychainDict(query);
    OSStatus status = orig_SecItemDelete(sanitizedQuery ? sanitizedQuery : query);
    if (sanitizedQuery) {
        CFRelease(sanitizedQuery);
    }
    return status;
}

%ctor {
    %init;
    MSHookFunction((void *)&SecItemCopyMatching, (void *)&hook_SecItemCopyMatching, (void **)&orig_SecItemCopyMatching);
    MSHookFunction((void *)&SecItemAdd, (void *)&hook_SecItemAdd, (void **)&orig_SecItemAdd);
    MSHookFunction((void *)&SecItemUpdate, (void *)&hook_SecItemUpdate, (void **)&orig_SecItemUpdate);
    MSHookFunction((void *)&SecItemDelete, (void *)&hook_SecItemDelete, (void **)&orig_SecItemDelete);
}
