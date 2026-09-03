#import <AVFoundation/AVFoundation.h>
#import <AppKit/AppKit.h>
#import <IOKit/hidsystem/IOHIDLib.h>
#include <Security/Authorization.h>
#include <Security/AuthorizationTags.h>

#include <CoreGraphics/CoreGraphics.h>
#include <ColorSync/ColorSync.h>
#include <dlfcn.h>
#include <vector>
#include <map>
#include <set>
#include <mutex>
#include <atomic>
#include <string>

extern "C" bool CanUseNewApiForScreenCaptureCheck() {
    #ifdef NO_InputMonitoringAuthStatus
    return false;
    #else
    NSOperatingSystemVersion version = [[NSProcessInfo processInfo] operatingSystemVersion];
    return version.majorVersion >= 11;
    #endif
}

extern "C" uint32_t majorVersion() {
    NSOperatingSystemVersion version = [[NSProcessInfo processInfo] operatingSystemVersion];
    return version.majorVersion;
}

extern "C" bool IsCanScreenRecording(bool prompt) {
    #ifdef NO_InputMonitoringAuthStatus
    return false;
    #else
    bool res = CGPreflightScreenCaptureAccess();
    if (!res && prompt) {
        CGRequestScreenCaptureAccess();
    }
    return res;
    #endif
}


// https://github.com/codebytere/node-mac-permissions/blob/main/permissions.mm

extern "C" bool InputMonitoringAuthStatus(bool prompt) {
    #ifdef NO_InputMonitoringAuthStatus
    return true;
    #else
    if (floor(NSAppKitVersionNumber) >= NSAppKitVersionNumber10_15) {
        IOHIDAccessType theType = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent);
        NSLog(@"IOHIDCheckAccess = %d, kIOHIDAccessTypeGranted = %d", theType, kIOHIDAccessTypeGranted);
        switch (theType) {
            case kIOHIDAccessTypeGranted:
                return true;
                break;
            case kIOHIDAccessTypeDenied: {
                if (prompt) {
                    NSString *urlString = @"x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent";
                    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:urlString]];
                }
                break;
            }
            case kIOHIDAccessTypeUnknown: {
                if (prompt) {
                    bool result = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent);
                    NSLog(@"IOHIDRequestAccess result = %d", result);
                }
                break;
            }
            default:
                break;
        }
    } else {
        return true;
    }
    return false;
    #endif
}

extern "C" bool Elevate(char* process, char** args) {
    AuthorizationRef authRef;
    OSStatus status;

    status = AuthorizationCreate(NULL, kAuthorizationEmptyEnvironment,
                                kAuthorizationFlagDefaults, &authRef);
    if (status != errAuthorizationSuccess) {
        printf("Failed to create AuthorizationRef\n");
        return false;
    }

    AuthorizationItem authItem = {kAuthorizationRightExecute, 0, NULL, 0};
    AuthorizationRights authRights = {1, &authItem};
    AuthorizationFlags flags = kAuthorizationFlagDefaults |
                                kAuthorizationFlagInteractionAllowed |
                                kAuthorizationFlagPreAuthorize |
                                kAuthorizationFlagExtendRights;
    status = AuthorizationCopyRights(authRef, &authRights, kAuthorizationEmptyEnvironment, flags, NULL);
    if (status != errAuthorizationSuccess) {
        printf("Failed to authorize\n");
        return false;
    }

    if (process != NULL) {
        FILE *pipe = NULL;
        status = AuthorizationExecuteWithPrivileges(authRef, process, kAuthorizationFlagDefaults, args, &pipe);
        if (status != errAuthorizationSuccess) {
            printf("Failed to run as root\n");
            AuthorizationFree(authRef, kAuthorizationFlagDefaults);
            return false;
        }
    }

    AuthorizationFree(authRef, kAuthorizationFlagDefaults);
    return true;
}

extern "C" bool MacCheckAdminAuthorization() {
    return Elevate(NULL, NULL);
}

// https://gist.github.com/briankc/025415e25900750f402235dbf1b74e42
extern "C" float BackingScaleFactor(uint32_t display) {
    NSArray<NSScreen *> *screens = [NSScreen screens];
    for (NSScreen *screen in screens) {
        NSDictionary *deviceDescription = [screen deviceDescription];
        NSNumber *screenNumber = [deviceDescription objectForKey:@"NSScreenNumber"];
        CGDirectDisplayID screenDisplayID = [screenNumber unsignedIntValue];
        if (screenDisplayID == display) {
            return [screen backingScaleFactor];
        }
    }
    return 1;
}

// https://github.com/jhford/screenresolution/blob/master/cg_utils.c
// https://github.com/jdoupe/screenres/blob/master/setgetscreen.m

size_t bitDepth(CGDisplayModeRef mode) {
    size_t depth = 0;
    // Deprecated, same display same bpp? 
    // https://stackoverflow.com/questions/8210824/how-to-avoid-cgdisplaymodecopypixelencoding-to-get-bpp
    // https://github.com/libsdl-org/SDL/pull/6628
	CFStringRef pixelEncoding = CGDisplayModeCopyPixelEncoding(mode);	
    // my numerical representation for kIO16BitFloatPixels and kIO32bitFloatPixels	
    // are made up and possibly non-sensical	
    if (kCFCompareEqualTo == CFStringCompare(pixelEncoding, CFSTR(kIO32BitFloatPixels), kCFCompareCaseInsensitive)) {	
        depth = 96;	
    } else if (kCFCompareEqualTo == CFStringCompare(pixelEncoding, CFSTR(kIO64BitDirectPixels), kCFCompareCaseInsensitive)) {	
        depth = 64;	
    } else if (kCFCompareEqualTo == CFStringCompare(pixelEncoding, CFSTR(kIO16BitFloatPixels), kCFCompareCaseInsensitive)) {	
        depth = 48;	
    } else if (kCFCompareEqualTo == CFStringCompare(pixelEncoding, CFSTR(IO32BitDirectPixels), kCFCompareCaseInsensitive)) {	
        depth = 32;	
    } else if (kCFCompareEqualTo == CFStringCompare(pixelEncoding, CFSTR(kIO30BitDirectPixels), kCFCompareCaseInsensitive)) {	
        depth = 30;	
    } else if (kCFCompareEqualTo == CFStringCompare(pixelEncoding, CFSTR(IO16BitDirectPixels), kCFCompareCaseInsensitive)) {	
        depth = 16;	
    } else if (kCFCompareEqualTo == CFStringCompare(pixelEncoding, CFSTR(IO8BitIndexedPixels), kCFCompareCaseInsensitive)) {	
        depth = 8;	
    }	
    CFRelease(pixelEncoding);	
    return depth;	
}

static bool isHiDPIMode(CGDisplayModeRef mode) {
    // Check if the mode is HiDPI by comparing pixel width to width
    // If pixel width is greater than width, it's a HiDPI mode
    return CGDisplayModeGetPixelWidth(mode) > CGDisplayModeGetWidth(mode);
}

CFArrayRef getAllModes(CGDirectDisplayID display) {
    // Create options dictionary to include HiDPI modes
    CFMutableDictionaryRef options = CFDictionaryCreateMutable(
        kCFAllocatorDefault,
        0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    // Include HiDPI modes
    CFDictionarySetValue(options, kCGDisplayShowDuplicateLowResolutionModes, kCFBooleanTrue);
    CFArrayRef allModes = CGDisplayCopyAllDisplayModes(display, options);
    CFRelease(options);
    return allModes;
}

extern "C" bool MacGetModeNum(CGDirectDisplayID display, uint32_t *numModes) {
    CFArrayRef allModes = getAllModes(display);
    if (allModes == NULL) {
        return false;
    }
    *numModes = CFArrayGetCount(allModes);
    CFRelease(allModes);
    return true;
}

extern "C" bool MacGetModes(CGDirectDisplayID display, uint32_t *widths, uint32_t *heights, bool *hidpis, uint32_t max, uint32_t *numModes) {
    CGDisplayModeRef currentMode = CGDisplayCopyDisplayMode(display);
    if (currentMode == NULL) {
        return false;
    }
    CFArrayRef allModes = getAllModes(display);
    if (allModes == NULL) {
        CGDisplayModeRelease(currentMode);
        return false;
    }
    uint32_t allModeCount = CFArrayGetCount(allModes);
    uint32_t realNum = 0;
    for (uint32_t i = 0; i < allModeCount && realNum < max; i++) {
        CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(allModes, i);
        if (CGDisplayModeGetRefreshRate(currentMode) == CGDisplayModeGetRefreshRate(mode) &&
            bitDepth(currentMode) == bitDepth(mode)) {
            widths[realNum] = (uint32_t)CGDisplayModeGetWidth(mode);
            heights[realNum] = (uint32_t)CGDisplayModeGetHeight(mode);
            hidpis[realNum] = isHiDPIMode(mode);
            realNum++;
        }
    }
    *numModes = realNum;
    CGDisplayModeRelease(currentMode);
    CFRelease(allModes);
    return true;
}

extern "C" bool MacGetMode(CGDirectDisplayID display, uint32_t *width, uint32_t *height) {
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(display);
    if (mode == NULL) {
        return false;
    }
    *width = (uint32_t)CGDisplayModeGetWidth(mode);
    *height = (uint32_t)CGDisplayModeGetHeight(mode);
    CGDisplayModeRelease(mode);
    return true;
}

static bool setDisplayToMode(CGDirectDisplayID display, CGDisplayModeRef mode) {
    CGError rc;
    CGDisplayConfigRef config;
    rc = CGBeginDisplayConfiguration(&config);
    if (rc != kCGErrorSuccess) {
        return false;
    }
    rc = CGConfigureDisplayWithDisplayMode(config, display, mode, NULL);
    if (rc != kCGErrorSuccess) {
        return false;
    }
    rc = CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
    if (rc != kCGErrorSuccess) {
        return false;
    }
    return true;
}

// Set the display to a specific mode based on width and height.
// Returns true if the display mode was successfully changed, false otherwise.
// If no such mode is available, it will not change the display mode.
//
// If `tryHiDPI` is true, it will try to set the display to a HiDPI mode if available.
// If no HiDPI mode is available, it will fall back to a non-HiDPI mode with the same resolution.
// If `tryHiDPI` is false, it sets the display to the first mode with the same resolution, no matter if it's HiDPI or not.
extern "C" bool MacSetMode(CGDirectDisplayID display, uint32_t width, uint32_t height, bool tryHiDPI)
{
    bool ret = false;
    CGDisplayModeRef currentMode = CGDisplayCopyDisplayMode(display);
    if (currentMode == NULL) {
        return ret;
    }
    CFArrayRef allModes = getAllModes(display);

    if (allModes == NULL) {
        CGDisplayModeRelease(currentMode);
        return ret;
    }
    int numModes = CFArrayGetCount(allModes);
    CGDisplayModeRef preferredHiDPIMode = NULL;
    CGDisplayModeRef fallbackMode = NULL;
    for (int i = 0; i < numModes; i++) {
        CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(allModes, i);
        if (width == CGDisplayModeGetWidth(mode) &&
            height == CGDisplayModeGetHeight(mode) && 
            CGDisplayModeGetRefreshRate(currentMode) == CGDisplayModeGetRefreshRate(mode) &&
            bitDepth(currentMode) == bitDepth(mode)) {

            if (isHiDPIMode(mode)) {
                preferredHiDPIMode = mode;
                break;
            } else {
                fallbackMode = mode;
                if (!tryHiDPI) {
                    break;
                }
            }
        }
    }

    if (preferredHiDPIMode) {
        ret = setDisplayToMode(display, preferredHiDPIMode);
    } else if (fallbackMode) {
        ret = setDisplayToMode(display, fallbackMode);
    }

    CGDisplayModeRelease(currentMode);
    CFRelease(allModes);
    return ret;
}

static CFMachPortRef g_eventTap = NULL;
static CFRunLoopSourceRef g_runLoopSource = NULL;
static std::mutex g_privacyModeMutex;
static bool g_privacyModeActive = false;

// Flag to request asynchronous shutdown of privacy mode.
// This is set by DisplayReconfigurationCallback when an error occurs, instead of calling
// TurnOffPrivacyModeInternal() directly from within the callback. This avoids potential
// issues with unregistering a callback from within itself, which is not explicitly
// guaranteed to be safe by Apple documentation.
static bool g_privacyModeShutdownRequested = false;

// Timestamp of the last display reconfiguration event (in milliseconds).
// Used for debouncing rapid successive changes (e.g., multiple resolution changes).
static uint64_t g_lastReconfigTimestamp = 0;

// Flag indicating whether a delayed blackout reapplication is already scheduled.
// Prevents multiple concurrent delayed tasks from being created.
static bool g_blackoutReapplicationScheduled = false;

// Use CFStringRef (UUID) as key instead of CGDirectDisplayID for stability across reconnections
// CGDirectDisplayID can change when displays are reconnected, but UUID remains stable
static std::map<std::string, std::vector<CGGammaValue>> g_originalGammas;

// The event source user data value used by enigo library for injected events.
// This allows us to distinguish remote input (which should be allowed) from local physical input.
// See: libs/enigo/src/macos/macos_impl.rs - ENIGO_INPUT_EXTRA_VALUE
static const int64_t ENIGO_INPUT_EXTRA_VALUE = 100;

// Duration in milliseconds to monitor and enforce blackout after display reconfiguration.
// macOS may restore default gamma (via ColorSync) at unpredictable times after display changes,
// so we need to actively monitor and reapply blackout during this period.
static const int64_t DISPLAY_RECONFIG_MONITOR_DURATION_MS = 5000;

// Interval in milliseconds between gamma checks during the monitoring period.
static const int64_t GAMMA_CHECK_INTERVAL_MS = 200;

// Helper function to get UUID string from DisplayID
static std::string GetDisplayUUID(CGDirectDisplayID displayId) {
    CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(displayId);
    if (uuid == NULL) {
        return "";
    }
    CFStringRef uuidStr = CFUUIDCreateString(kCFAllocatorDefault, uuid);
    CFRelease(uuid);
    if (uuidStr == NULL) {
        return "";
    }
    char buffer[128];
    if (CFStringGetCString(uuidStr, buffer, sizeof(buffer), kCFStringEncodingUTF8)) {
        CFRelease(uuidStr);
        return std::string(buffer);
    }
    CFRelease(uuidStr);
    return "";
}

// Helper function to find DisplayID by UUID from current online displays
static CGDirectDisplayID FindDisplayIdByUUID(const std::string& targetUuid) {
    uint32_t count = 0;
    CGGetOnlineDisplayList(0, NULL, &count);
    if (count == 0) return kCGNullDirectDisplay;
    
    std::vector<CGDirectDisplayID> displays(count);
    CGGetOnlineDisplayList(count, displays.data(), &count);
    
    for (uint32_t i = 0; i < count; i++) {
        std::string uuid = GetDisplayUUID(displays[i]);
        if (uuid == targetUuid) {
            return displays[i];
        }
    }
    return kCGNullDirectDisplay;
}

// Helper function to restore gamma values for all displays in g_originalGammas.
// Returns true if all displays were restored successfully, false if any failed.
// Note: This function does NOT clear g_originalGammas - caller should do that if needed.
static bool RestoreAllGammas() {
    bool allSuccess = true;
    for (auto const& [uuid, gamma] : g_originalGammas) {
        CGDirectDisplayID d = FindDisplayIdByUUID(uuid);
        if (d == kCGNullDirectDisplay) {
            NSLog(@"Display with UUID %s no longer online, skipping gamma restore", uuid.c_str());
            continue;
        }
        
        uint32_t sampleCount = gamma.size() / 3;
        if (sampleCount > 0) {
            const CGGammaValue* red = gamma.data();
            const CGGammaValue* green = red + sampleCount;
            const CGGammaValue* blue = green + sampleCount;
            CGError error = CGSetDisplayTransferByTable(d, sampleCount, red, green, blue);
            if (error != kCGErrorSuccess) {
                NSLog(@"Failed to restore gamma for display (ID: %u, UUID: %s, error: %d)", (unsigned)d, uuid.c_str(), error);
                allSuccess = false;
            }
        }
    }
    return allSuccess;
}

// Helper function to apply blackout to a single display
static bool ApplyBlackoutToDisplay(CGDirectDisplayID display) {
    uint32_t capacity = CGDisplayGammaTableCapacity(display);
    if (capacity > 0) {
        std::vector<CGGammaValue> zeros(capacity, 0.0f);
        CGError error = CGSetDisplayTransferByTable(display, capacity, zeros.data(), zeros.data(), zeros.data());
        if (error != kCGErrorSuccess) {
            NSLog(@"ApplyBlackoutToDisplay: Failed to set gamma for display %u (error %d)", (unsigned)display, error);
            return false;
        }
        return true;
    }
    NSLog(@"ApplyBlackoutToDisplay: Display %u has zero gamma table capacity, blackout not supported", (unsigned)display);
    return false;
}

// Forward declaration - defined later in the file
// Must be called while holding g_privacyModeMutex
static bool TurnOffPrivacyModeInternal();

// Helper function to schedule asynchronous shutdown of privacy mode.
// This is called from DisplayReconfigurationCallback when an error occurs,
// instead of calling TurnOffPrivacyModeInternal() directly. This avoids
// potential issues with unregistering a callback from within itself.
// Note: This function should be called while holding g_privacyModeMutex.
static void ScheduleAsyncPrivacyModeShutdown(const char* reason) {
    if (g_privacyModeShutdownRequested) {
        // Already requested, no need to schedule again
        return;
    }
    g_privacyModeShutdownRequested = true;
    NSLog(@"Privacy mode shutdown requested: %s", reason);
    
    // Schedule the actual shutdown on the main queue asynchronously
    // This ensures we're outside the callback when we unregister it
    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_privacyModeMutex);
        if (g_privacyModeShutdownRequested && g_privacyModeActive) {
            NSLog(@"Executing deferred privacy mode shutdown");
            TurnOffPrivacyModeInternal();
        }
        g_privacyModeShutdownRequested = false;
    });
}

// Helper function to apply blackout to all online displays.
// Must be called while holding g_privacyModeMutex.
static void ApplyBlackoutToAllDisplays() {
    uint32_t onlineCount = 0;
    CGGetOnlineDisplayList(0, NULL, &onlineCount);
    std::vector<CGDirectDisplayID> onlineDisplays(onlineCount);
    CGGetOnlineDisplayList(onlineCount, onlineDisplays.data(), &onlineCount);
    
    for (uint32_t i = 0; i < onlineCount; i++) {
        ApplyBlackoutToDisplay(onlineDisplays[i]);
    }
}

// Helper function to get current timestamp in milliseconds
static uint64_t GetCurrentTimestampMs() {
    return (uint64_t)(CFAbsoluteTimeGetCurrent() * 1000.0);
}

// Helper function to check if a display's gamma is currently blacked out (all zeros).
// Returns true if gamma appears to be blacked out, false otherwise.
static bool IsDisplayBlackedOut(CGDirectDisplayID display) {
    uint32_t capacity = CGDisplayGammaTableCapacity(display);
    if (capacity == 0) {
        return true; // Can't check, assume it's fine
    }
    
    std::vector<CGGammaValue> red(capacity), green(capacity), blue(capacity);
    uint32_t sampleCount = 0;
    if (CGGetDisplayTransferByTable(display, capacity, red.data(), green.data(), blue.data(), &sampleCount) != kCGErrorSuccess) {
        return true; // Can't read, assume it's fine
    }
    
    // Check if all values are zero (or very close to zero)
    for (uint32_t i = 0; i < sampleCount; i++) {
        if (red[i] > 0.01f || green[i] > 0.01f || blue[i] > 0.01f) {
            return false; // Not blacked out
        }
    }
    return true;
}

// Internal function that monitors and enforces blackout for a period after display reconfiguration.
// This function checks gamma values periodically and reapplies blackout if needed.
// Must NOT be called while holding g_privacyModeMutex (it acquires the lock internally).
static void RunBlackoutMonitor() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(GAMMA_CHECK_INTERVAL_MS * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_privacyModeMutex);
        
        if (!g_privacyModeActive) {
            g_blackoutReapplicationScheduled = false;
            return;
        }
        
        uint64_t now = GetCurrentTimestampMs();
        
        // Calculate effective end time based on the last reconfig event
        uint64_t effectiveEndTime = g_lastReconfigTimestamp + DISPLAY_RECONFIG_MONITOR_DURATION_MS;
        
        // Check all displays and reapply blackout if any has been restored
        uint32_t onlineCount = 0;
        CGGetOnlineDisplayList(0, NULL, &onlineCount);
        std::vector<CGDirectDisplayID> onlineDisplays(onlineCount);
        CGGetOnlineDisplayList(onlineCount, onlineDisplays.data(), &onlineCount);
        
        bool needsReapply = false;
        for (uint32_t i = 0; i < onlineCount; i++) {
            if (!IsDisplayBlackedOut(onlineDisplays[i])) {
                needsReapply = true;
                break;
            }
        }
        
        if (needsReapply) {
            NSLog(@"Gamma was restored by system, reapplying blackout");
            ApplyBlackoutToAllDisplays();
        }
        
        // Continue monitoring if we haven't reached the end time
        if (now < effectiveEndTime) {
            RunBlackoutMonitor();
        } else {
            NSLog(@"Blackout monitoring period ended");
            g_blackoutReapplicationScheduled = false;
        }
    });
}

// Helper function to start monitoring and enforcing blackout after display reconfiguration.
// This is used after display reconfiguration events because macOS may restore
// default gamma (via ColorSync) at unpredictable times after display changes.
// Note: This function should be called while holding g_privacyModeMutex.
static void ScheduleDelayedBlackoutReapplication(const char* reason) {
    // Update timestamp to current time
    g_lastReconfigTimestamp = GetCurrentTimestampMs();
    
    NSLog(@"Starting blackout monitor: %s", reason);
    
    // Only schedule if not already scheduled
    if (!g_blackoutReapplicationScheduled) {
        g_blackoutReapplicationScheduled = true;
        RunBlackoutMonitor();
    }
    // If already scheduled, the running monitor will see the updated timestamp
    // and extend its monitoring period
}

// Display reconfiguration callback to handle display connect/disconnect events
//
// IMPORTANT: When errors occur in this callback, we use ScheduleAsyncPrivacyModeShutdown()
// instead of calling TurnOffPrivacyModeInternal() directly. This is because:
// 1. TurnOffPrivacyModeInternal() calls CGDisplayRemoveReconfigurationCallback to unregister
//    this callback, and unregistering a callback from within itself is not explicitly
//    guaranteed to be safe by Apple documentation.
// 2. Using async dispatch ensures we're completely outside the callback context when
//    performing the cleanup, avoiding any potential undefined behavior.
static void DisplayReconfigurationCallback(CGDirectDisplayID display, CGDisplayChangeSummaryFlags flags, void *userInfo) {
    (void)userInfo;
    
    // Note: We need to handle the callback carefully because:
    // 1. macOS may call this callback multiple times during display reconfiguration
    // 2. The system may restore ColorSync settings after our gamma change
    // 3. We should not hold the lock for too long in the callback
    
    // Skip begin configuration flag - wait for the actual change
    if (flags & kCGDisplayBeginConfigurationFlag) {
        return;
    }
    
    std::lock_guard<std::mutex> lock(g_privacyModeMutex);
    
    if (!g_privacyModeActive) {
        return;
    }
    
    if (flags & kCGDisplayAddFlag) {
        // A display was added - apply blackout to it
        NSLog(@"Display %u added during privacy mode, applying blackout", (unsigned)display);
        std::string uuid = GetDisplayUUID(display);
        if (uuid.empty()) {
            NSLog(@"Failed to get UUID for newly added display %u, exiting privacy mode", (unsigned)display);
            ScheduleAsyncPrivacyModeShutdown("Failed to get UUID for newly added display");
            return;
        }
        
        // Save original gamma if not already saved for this UUID
        if (g_originalGammas.find(uuid) == g_originalGammas.end()) {
            uint32_t capacity = CGDisplayGammaTableCapacity(display);
            if (capacity > 0) {
                std::vector<CGGammaValue> red(capacity), green(capacity), blue(capacity);
                uint32_t sampleCount = 0;
                if (CGGetDisplayTransferByTable(display, capacity, red.data(), green.data(), blue.data(), &sampleCount) == kCGErrorSuccess) {
                    std::vector<CGGammaValue> all;
                    all.insert(all.end(), red.begin(), red.begin() + sampleCount);
                    all.insert(all.end(), green.begin(), green.begin() + sampleCount);
                    all.insert(all.end(), blue.begin(), blue.begin() + sampleCount);
                    g_originalGammas[uuid] = all;
                } else {
                    NSLog(@"DisplayReconfigurationCallback: Failed to get gamma table for display %u (UUID: %s), exiting privacy mode", (unsigned)display, uuid.c_str());
                    ScheduleAsyncPrivacyModeShutdown("Failed to get gamma table for newly added display");
                    return;
                }
            } else {
                NSLog(@"DisplayReconfigurationCallback: Display %u (UUID: %s) has zero gamma table capacity, exiting privacy mode", (unsigned)display, uuid.c_str());
                ScheduleAsyncPrivacyModeShutdown("Newly added display has zero gamma table capacity");
                return;
            }
        }
        
        // Apply blackout to the new display immediately
        if (!ApplyBlackoutToDisplay(display)) {
            NSLog(@"DisplayReconfigurationCallback: Failed to blackout display %u (UUID: %s), exiting privacy mode", (unsigned)display, uuid.c_str());
            ScheduleAsyncPrivacyModeShutdown("Failed to blackout newly added display");
            return;
        }
        
        // Schedule a delayed re-application to handle ColorSync restoration
        // macOS may restore default gamma for ALL displays after a new display is added,
        // so we need to reapply blackout to all online displays, not just the new one
        ScheduleDelayedBlackoutReapplication("after new display added");
    } else if (flags & kCGDisplayRemoveFlag) {
        // A display was removed - update our mapping and reapply blackout to remaining displays
        NSLog(@"Display %u removed during privacy mode", (unsigned)display);
        std::string uuid = GetDisplayUUID(display);
        (void)uuid; // UUID retrieved for potential future use or logging
        
        // When a display is removed, macOS may reconfigure other displays and restore their gamma.
        // Schedule a delayed re-application of blackout to all remaining online displays.
        ScheduleDelayedBlackoutReapplication("after display removal");
    } else if (flags & kCGDisplaySetModeFlag) {
        // Display mode changed (resolution change, ColorSync/Night Shift interference, etc.)
        // macOS resets gamma to default when display mode changes, so we need to reapply blackout.
        // Schedule a delayed re-application because ColorSync restoration happens asynchronously.
        NSLog(@"Display %u mode changed during privacy mode, reapplying blackout", (unsigned)display);
        ScheduleDelayedBlackoutReapplication("after display mode change");
    }
}

CGEventRef MyEventTapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon) {
    (void)proxy;
    (void)refcon;
    
    // Handle EventTap being disabled by system timeout
    if (type == kCGEventTapDisabledByTimeout) {
        NSLog(@"EventTap was disabled by timeout, re-enabling");
        if (g_eventTap) {
            CGEventTapEnable(g_eventTap, true);
        }
        return event;
    }
    
    // Handle EventTap being disabled by user input
    if (type == kCGEventTapDisabledByUserInput) {
        NSLog(@"EventTap was disabled by user input, re-enabling");
        if (g_eventTap) {
            CGEventTapEnable(g_eventTap, true);
        }
        return event;
    }
    
    // Allow events explicitly injected by enigo (remote input), identified via custom user data.
    int64_t userData = CGEventGetIntegerValueField(event, kCGEventSourceUserData);
    if (userData == ENIGO_INPUT_EXTRA_VALUE) {
        return event;
    }
    // Block local physical HID input.
    if (CGEventGetIntegerValueField(event, kCGEventSourceStateID) == kCGEventSourceStateHIDSystemState) {
        return NULL;
    }
    return event;
}

// Helper function to set up EventTap on the main thread
// Returns true if EventTap was successfully created and enabled
static bool SetupEventTapOnMainThread() {
    __block bool success = false;
    
    void (^setupBlock)(void) = ^{
        if (g_eventTap) {
            // Already set up
            success = true;
            return;
        }
        
        // Note: kCGEventTapDisabledByTimeout and kCGEventTapDisabledByUserInput are special
        // notification types (0xFFFFFFFE and 0xFFFFFFFF) that are delivered via the callback's
        // type parameter, not through the event mask. They should NOT be included in eventMask
        // as bit-shifting by these values causes undefined behavior.
        CGEventMask eventMask = (1 << kCGEventKeyDown) | (1 << kCGEventKeyUp) |
                                (1 << kCGEventLeftMouseDown) | (1 << kCGEventLeftMouseUp) |
                                (1 << kCGEventRightMouseDown) | (1 << kCGEventRightMouseUp) |
                                (1 << kCGEventOtherMouseDown) | (1 << kCGEventOtherMouseUp) |
                                (1 << kCGEventLeftMouseDragged) | (1 << kCGEventRightMouseDragged) |
                                (1 << kCGEventOtherMouseDragged) |
                                (1 << kCGEventMouseMoved) | (1 << kCGEventScrollWheel);
        
        g_eventTap = CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault,
                                      eventMask, MyEventTapCallback, NULL);
        if (g_eventTap) {
            g_runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, g_eventTap, 0);
            CFRunLoopAddSource(CFRunLoopGetMain(), g_runLoopSource, kCFRunLoopCommonModes);
            CGEventTapEnable(g_eventTap, true);
            success = true;
        } else {
            NSLog(@"MacSetPrivacyMode: Failed to create CGEventTap; input blocking not enabled.");
            success = false;
        }
    };
    
    // Execute on main thread to ensure CFRunLoop operations are safe.
    // Use dispatch_sync if not on main thread, otherwise execute directly to avoid deadlock.
    //
    // IMPORTANT: Potential deadlock consideration:
    // Using dispatch_sync while holding g_privacyModeMutex could deadlock if the main thread
    // tries to acquire g_privacyModeMutex. Currently this is safe because:
    // 1. MacSetPrivacyMode (which holds the mutex) is only called from background threads
    // 2. The main thread never directly calls MacSetPrivacyMode
    // If this assumption changes in the future, consider releasing the mutex before dispatch_sync
    // or restructuring the locking strategy.
    if ([NSThread isMainThread]) {
        setupBlock();
    } else {
        dispatch_sync(dispatch_get_main_queue(), setupBlock);
    }
    
    return success;
}

// Helper function to tear down EventTap on the main thread
static void TeardownEventTapOnMainThread() {
    void (^teardownBlock)(void) = ^{
        if (g_eventTap) {
            CGEventTapEnable(g_eventTap, false);
            CFRunLoopRemoveSource(CFRunLoopGetMain(), g_runLoopSource, kCFRunLoopCommonModes);
            CFRelease(g_runLoopSource);
            CFRelease(g_eventTap);
            g_eventTap = NULL;
            g_runLoopSource = NULL;
        }
    };
    
    // Execute on main thread to ensure CFRunLoop operations are safe.
    //
    // NOTE: We use dispatch_sync here instead of dispatch_async because:
    // 1. TurnOffPrivacyModeInternal() expects EventTap to be fully torn down before
    //    proceeding with gamma restoration - using async would cause race conditions.
    // 2. The caller (MacSetPrivacyMode) needs deterministic cleanup order.
    //
    // IMPORTANT: Potential deadlock consideration (same as SetupEventTapOnMainThread):
    // Using dispatch_sync while holding g_privacyModeMutex could deadlock if the main thread
    // tries to acquire g_privacyModeMutex. Currently this is safe because:
    // 1. MacSetPrivacyMode (which holds the mutex) is only called from background threads
    // 2. The main thread never directly calls MacSetPrivacyMode
    // If this assumption changes in the future, consider releasing the mutex before dispatch_sync
    // or restructuring the locking strategy.
    if ([NSThread isMainThread]) {
        teardownBlock();
    } else {
        dispatch_sync(dispatch_get_main_queue(), teardownBlock);
    }
}

// Internal function to turn off privacy mode without acquiring the mutex
// Must be called while holding g_privacyModeMutex
static bool TurnOffPrivacyModeInternal() {
    if (!g_privacyModeActive) {
        return true;
    }
    
    // 1. Unregister display reconfiguration callback
    CGDisplayRemoveReconfigurationCallback(DisplayReconfigurationCallback, NULL);
    
    // 2. Input - restore (tear down EventTap on main thread)
    TeardownEventTapOnMainThread();

    // 3. Gamma - restore using UUID to find current DisplayID
    bool restoreSuccess = RestoreAllGammas();
    
    // 4. Fallback: Always call CGDisplayRestoreColorSyncSettings as a safety net
    // This ensures displays return to normal even if our restoration failed or
    // if the system (ColorSync/Night Shift) modified gamma during privacy mode
    CGDisplayRestoreColorSyncSettings();
    
    // Clean up
    g_originalGammas.clear();
    g_privacyModeActive = false;
    g_privacyModeShutdownRequested = false;
    g_lastReconfigTimestamp = 0;
    g_blackoutReapplicationScheduled = false;
    
    return restoreSuccess;
}

extern "C" bool MacSetPrivacyMode(bool on) {
    std::lock_guard<std::mutex> lock(g_privacyModeMutex);
    if (on) {
        // Already in privacy mode
        if (g_privacyModeActive) {
            return true;
        }
        
        // 1. Input Blocking - set up EventTap on main thread
        if (!SetupEventTapOnMainThread()) {
            return false;
        }

        // 2. Register display reconfiguration callback to handle hot-plug events
        CGDisplayRegisterReconfigurationCallback(DisplayReconfigurationCallback, NULL);

        // 3. Gamma Blackout
        uint32_t count = 0;
        CGGetOnlineDisplayList(0, NULL, &count);
        std::vector<CGDirectDisplayID> displays(count);
        CGGetOnlineDisplayList(count, displays.data(), &count);

        uint32_t blackoutSuccessCount = 0;
        uint32_t blackoutAttemptCount = 0;

        for (uint32_t i = 0; i < count; i++) {
            CGDirectDisplayID d = displays[i];
            std::string uuid = GetDisplayUUID(d);
            
            if (uuid.empty()) {
                NSLog(@"MacSetPrivacyMode: Failed to get UUID for display %u, privacy mode requires all displays", (unsigned)d);
                // Privacy mode requires ALL connected displays to be successfully blacked out 
                // to ensure user privacy. If we can't identify a display (no UUID), 
                // we can't safely manage its state or restore it later.
                // Therefore, we must abort the entire operation and clean up any resources
                // already allocated (like event taps and reconfiguration callbacks).
                CGDisplayRemoveReconfigurationCallback(DisplayReconfigurationCallback, NULL);
                TeardownEventTapOnMainThread();
                // Restore gamma for displays that were already blacked out before this failure
                if (!RestoreAllGammas()) {
                    // If any display failed to restore, use system reset as fallback
                    CGDisplayRestoreColorSyncSettings();
                }
                g_originalGammas.clear();
                return false;
            }
            
            // Save original gamma using UUID as key (stable across reconnections)
            if (g_originalGammas.find(uuid) == g_originalGammas.end()) {
                uint32_t capacity = CGDisplayGammaTableCapacity(d);
                if (capacity > 0) {
                    std::vector<CGGammaValue> red(capacity), green(capacity), blue(capacity);
                    uint32_t sampleCount = 0;
                    if (CGGetDisplayTransferByTable(d, capacity, red.data(), green.data(), blue.data(), &sampleCount) == kCGErrorSuccess) {
                        std::vector<CGGammaValue> all;
                        all.insert(all.end(), red.begin(), red.begin() + sampleCount);
                        all.insert(all.end(), green.begin(), green.begin() + sampleCount);
                        all.insert(all.end(), blue.begin(), blue.begin() + sampleCount);
                        g_originalGammas[uuid] = all;
                    } else {
                        NSLog(@"MacSetPrivacyMode: Failed to get gamma table for display %u (UUID: %s)", (unsigned)d, uuid.c_str());
                    }
                } else {
                    NSLog(@"MacSetPrivacyMode: Display %u (UUID: %s) has zero gamma table capacity, not supported", (unsigned)d, uuid.c_str());
                }
            }

            // Set to black only if we have saved original gamma for this display
            if (g_originalGammas.find(uuid) != g_originalGammas.end()) {
                uint32_t capacity = CGDisplayGammaTableCapacity(d);
                if (capacity > 0) {
                    std::vector<CGGammaValue> zeros(capacity, 0.0f);
                    blackoutAttemptCount++;
                    CGError error = CGSetDisplayTransferByTable(d, capacity, zeros.data(), zeros.data(), zeros.data());
                    if (error != kCGErrorSuccess) {
                        NSLog(@"MacSetPrivacyMode: Failed to blackout display (ID: %u, UUID: %s, error: %d)", (unsigned)d, uuid.c_str(), error);
                    } else {
                        blackoutSuccessCount++;
                    }
                } else {
                    NSLog(@"MacSetPrivacyMode: Display %u (UUID: %s) has zero gamma table capacity for blackout", (unsigned)d, uuid.c_str());
                }
            }
        }
        
        // Return false if any display failed to blackout - privacy mode requires ALL displays to be blacked out
        if (blackoutAttemptCount > 0 && blackoutSuccessCount < blackoutAttemptCount) {
            NSLog(@"MacSetPrivacyMode: Failed to blackout all displays (%u/%u succeeded)", blackoutSuccessCount, blackoutAttemptCount);
            // Clean up: unregister callback and disable event tap since we're failing
            CGDisplayRemoveReconfigurationCallback(DisplayReconfigurationCallback, NULL);
            TeardownEventTapOnMainThread();
            // Restore gamma for displays that were successfully blacked out
            if (!RestoreAllGammas()) {
                // If any display failed to restore, use system reset as fallback
                NSLog(@"Some displays failed to restore gamma during cleanup, using CGDisplayRestoreColorSyncSettings as fallback");
                CGDisplayRestoreColorSyncSettings();
            }
            g_originalGammas.clear();
            return false;
        }
        
        g_privacyModeActive = true;
        return true;

    } else {
        return TurnOffPrivacyModeInternal();
    }
}

// ==================== remotedisplay: virtual displays (CGVirtualDisplay) ====================
//
// CGVirtualDisplay is a private CoreGraphics API (the same one used by Tart via
// Virtualization.framework on the host side, DeskPad, BetterDisplay and SimpleDisplay).
// It is instantiated via NSClassFromString to avoid referencing private symbols in the
// link, with a runtime check as a safety net in case Apple removes it.
//
// Dimension semantics: these functions receive POINTS (the resolution convention
// used by RustDesk on macOS: MacGetModes/MacSetMode speak in points).
// The mode is declared in pixels = points * 2 when hidpi is active.

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic, strong) NSArray *modes;
@property (nonatomic) NSUInteger hiDPI;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic) uint32_t vendorID;
@property (nonatomic) uint32_t productID;
@property (nonatomic) uint32_t serialNumber;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) NSUInteger maxPixelsWide;
@property (nonatomic) NSUInteger maxPixelsHigh;
@property (nonatomic, strong) dispatch_queue_t dispatchQueue;
@property (nonatomic, copy) void (^terminationHandler)(void);
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
@property (nonatomic, readonly) CGDirectDisplayID displayID;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

// Our own vendor/product so we can identify our displays if ever needed
#define RD_VDISPLAY_VENDOR_ID 0x7264   // "rd"
#define RD_VDISPLAY_PRODUCT_ID 0x0001

struct RDVDisplayEntry {
    CGVirtualDisplay *display; // retained (MRC)
    uint32_t width;            // points
    uint32_t height;
    bool hidpi;
    double refreshRate;
    std::string iccPath;       // the .icc macOS generated for this display
    uint32_t serial;           // stable slot (so macOS reuses its profile)
    bool hidpiRequested = false; // what the client requested; `hidpi` is the actual measured backing
};

static std::mutex g_rdVDisplayMutex;
static std::map<uint32_t, RDVDisplayEntry> g_rdVDisplays;

// Pool of stable serials: fixed vendor/product/serial makes macOS
// identify the display as the SAME one and REUSE its ICC profile instead of generating
// a new one on every create (which is what was driving colorsyncd's CPU up). Each "slot"
// (serial 1,2,3…) reuses its .icc; on destroy, the slot is freed for the next one.
static std::set<uint32_t> g_rdUsedSerials;
static uint32_t rdAllocSerialLocked() {
    for (uint32_t s = 1; s < 4096; s++) {
        if (g_rdUsedSerials.find(s) == g_rdUsedSerials.end()) {
            g_rdUsedSerials.insert(s);
            return s;
        }
    }
    return 1;
}
static void rdFreeSerialLocked(uint32_t serial) {
    g_rdUsedSerials.erase(serial);
}

static NSString *const kRDVDisplayName = @"Remote Display Virtual";
static NSString *const kRDColorSyncDir = @"/Library/ColorSync/Profiles/Displays";

// Snapshot of all .icc files present (for a before/after diff around create).
static NSSet<NSString *> *rdSnapshotICCs() {
    NSMutableSet *s = [NSMutableSet set];
    NSArray *files = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:kRDColorSyncDir error:nil];
    for (NSString *f in files) {
        if ([f hasSuffix:@".icc"]) [s addObject:f];
    }
    return s;
}

// The .icc that appeared relative to `before` (the one macOS generated for the new
// display). Polls, since generation is asynchronous after creating the display.
static std::string rdFindNewICC(NSSet<NSString *> *before) {
    for (int i = 0; i < 20; i++) {
        NSSet *now = rdSnapshotICCs();
        for (NSString *f in now) {
            if (![before containsObject:f]) {
                return std::string([[kRDColorSyncDir
                    stringByAppendingPathComponent:f] UTF8String]);
            }
        }
        usleep(150 * 1000);
    }
    return "";
}

// Deletes one specific .icc. The .icc files live under /Library/ColorSync/Profiles/Displays
// (root:wheel): if remotedisplayd runs without privileges the delete FAILS silently
// and the file is left behind (a platform limitation, same as SimpleDisplay — no
// CPU/memory impact thanks to the assigned sRGB profile; the heavy resource is
// still freed). If it runs with privileges (or the user is in wheel), it cleans up properly.
static void rdRemoveICC(const std::string &path) {
    if (path.empty()) return;
    [[NSFileManager defaultManager]
        removeItemAtPath:[NSString stringWithUTF8String:path.c_str()] error:nil];
}

// Backup sweep: deletes .icc files belonging to our displays (name prefix)
// that are NOT in use by a live display (`keep`). Covers the case where the
// 1:1 tracking gets out of sync (e.g. creating many at once). The VM's
// physical display is named "Apple Virtual-…" and does NOT match the prefix, so it's
// preserved. Call ONLY with the mutex held.
static void rdSweepOrphanICCsLocked() {
    NSMutableSet<NSString *> *keep = [NSMutableSet set];
    for (auto const &kv : g_rdVDisplays) {
        if (!kv.second.iccPath.empty()) {
            [keep addObject:[NSString stringWithUTF8String:kv.second.iccPath.c_str()]];
        }
    }
    NSArray *files = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:kRDColorSyncDir error:nil];
    for (NSString *f in files) {
        if (![f hasSuffix:@".icc"] || ![f hasPrefix:kRDVDisplayName]) continue;
        NSString *full = [kRDColorSyncDir stringByAppendingPathComponent:f];
        if (![keep containsObject:full]) {
            rdRemoveICC(std::string([full UTF8String]));
        }
    }
}

// State of the "dynamic main" (case 1): physical mirrored onto our virtual.
// The virtual is CACHED and recycled between ON/OFF: destroying a display that was
// the master of a mirror set leaves a ghost in WindowServer's active list
// (verified on macOS 26, no reconfiguration purges it). Off = the
// virtual becomes a slave of the physical (leaves the active list, invisible).
static uint32_t g_rdDynMainVirtual = 0;
static uint32_t g_rdDynMainPhysical = 0;
static bool g_rdDynMainActive = false;

// ==================== remotedisplay: mode of the mirrored physical display ====================
//
// When a physical display mirrors (in hardware) one of our virtuals, macOS re-picks the
// physical's mode on every mode change of the master. Measured on the Mac Studio
// (2026-09-02, J560T09 native 2560x1600 mirroring a 3440x1440 virtual): after
// resizing the virtual with the mirror active, the physical ended up at 800x500 @144,
// the panel frozen (the clock stopped advancing), and the cursor composited by
// software inside the framebuffer (double cursor on the client). Fix: remember
// the mode the physical had before mirroring it, re-set it when the mirror or
// a resize of the master changes it, and restore it when unmirroring.
// NOTE: re-setting the mode is a configuration transaction (see the nudge note
// in MacResizeVirtualDisplay). It only commits if the mode is wrong, and at
// that point there was already a mirror transaction with the same arrangement.
extern "C" bool MacIsOurVirtualDisplay(uint32_t displayID); // defined further below

static std::map<uint32_t, CGDisplayModeRef> g_rdMirrorModes; // physical -> previous mode (retained); guarded by g_rdVDisplayMutex

static bool rdSameMode(CGDisplayModeRef a, CGDisplayModeRef b) {
    if (!a || !b) return false;
    return CGDisplayModeGetPixelWidth(a) == CGDisplayModeGetPixelWidth(b)
        && CGDisplayModeGetPixelHeight(a) == CGDisplayModeGetPixelHeight(b)
        && CGDisplayModeGetWidth(a) == CGDisplayModeGetWidth(b)
        && CGDisplayModeGetHeight(a) == CGDisplayModeGetHeight(b);
}

// Native mode (flag) with the largest pixel area; without the flag, the largest area.
static CGDisplayModeRef rdCopyNativeMode(CGDirectDisplayID display) {
    CFArrayRef modes = getAllModes(display);
    if (!modes) return NULL;
    CGDisplayModeRef best = NULL, biggest = NULL;
    size_t bestArea = 0, biggestArea = 0;
    CFIndex n = CFArrayGetCount(modes);
    for (CFIndex i = 0; i < n; i++) {
        CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
        size_t area = CGDisplayModeGetPixelWidth(m) * CGDisplayModeGetPixelHeight(m);
        if (area > biggestArea) { biggestArea = area; biggest = m; }
        if ((CGDisplayModeGetIOFlags(m) & kDisplayModeNativeFlag) && area > bestArea) { bestArea = area; best = m; }
    }
    CGDisplayModeRef r = best ? best : biggest;
    if (r) CGDisplayModeRetain(r);
    CFRelease(modes);
    return r;
}

// Saves the physical's OWN mode before mirroring it. Only a standalone display
// (active, not mirroring anything) shows its own mode. When the dynamic main's
// cached virtual is re-enabled, macOS can re-mirror the physical onto it on its
// own, before we get here: the physical then reports the master's mode, and
// remembering that poisoned the restore (measured in the test VM, 2026-09-03:
// 1920x1080 "restored" to 1600x900 on the second connection). So: standalone ->
// refresh the memory with the current mode; already mirrored -> keep what we
// remembered in an earlier cycle, or fall back to the native mode if there is
// nothing. The memory survives the restore (see rdRestorePhysicalMode).
static void rdRememberPhysicalMode(CGDirectDisplayID display) {
    bool standalone = CGDisplayIsActive(display) &&
                      CGDisplayMirrorsDisplay(display) == kCGNullDirectDisplay;
    CGDisplayModeRef current = standalone ? CGDisplayCopyDisplayMode(display) : NULL;
    CGDisplayModeRef native = standalone ? NULL : rdCopyNativeMode(display);
    std::lock_guard<std::mutex> lock(g_rdVDisplayMutex);
    auto it = g_rdMirrorModes.find(display);
    if (standalone) {
        if (!current) { if (native) CGDisplayModeRelease(native); return; }
        if (it != g_rdMirrorModes.end()) {
            CGDisplayModeRelease(it->second);
            it->second = current;
        } else {
            g_rdMirrorModes[display] = current; // retained by the Copy
        }
        NSLog(@"remotedisplay vdisplay: physical %u at %zux%zu px before mirroring (remembered)",
              display, CGDisplayModeGetPixelWidth(current), CGDisplayModeGetPixelHeight(current));
        return;
    }
    if (it != g_rdMirrorModes.end()) {
        NSLog(@"remotedisplay vdisplay: physical %u is already mirroring %u: keeping the remembered %zux%zu px",
              display, CGDisplayMirrorsDisplay(display),
              CGDisplayModeGetPixelWidth(it->second), CGDisplayModeGetPixelHeight(it->second));
        if (native) CGDisplayModeRelease(native);
        return;
    }
    if (!native) return;
    g_rdMirrorModes[display] = native;
    NSLog(@"remotedisplay vdisplay: physical %u is already mirroring %u and nothing is remembered: assuming its native %zux%zu px",
          display, CGDisplayMirrorsDisplay(display),
          CGDisplayModeGetPixelWidth(native), CGDisplayModeGetPixelHeight(native));
}

// Desired mode for a mirrored physical display: the remembered one, or the native one.
static CGDisplayModeRef rdCopyWantedMode(CGDirectDisplayID display) {
    {
        std::lock_guard<std::mutex> lock(g_rdVDisplayMutex);
        auto it = g_rdMirrorModes.find(display);
        if (it != g_rdMirrorModes.end()) {
            CGDisplayModeRetain(it->second);
            return it->second;
        }
    }
    return rdCopyNativeMode(display);
}

// Sets `mode` on `display` (session transaction) and waits for the current mode to reflect it.
static bool rdApplyModeAndWait(CGDirectDisplayID display, CGDisplayModeRef mode, int timeoutMs) {
    CGDisplayConfigRef config;
    if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess) return false;
    if (CGConfigureDisplayWithDisplayMode(config, display, mode, NULL) != kCGErrorSuccess) {
        CGCancelDisplayConfiguration(config);
        return false;
    }
    if (CGCompleteDisplayConfiguration(config, kCGConfigureForSession) != kCGErrorSuccess) {
        CGCancelDisplayConfiguration(config);
        return false;
    }
    for (int waited = 0; waited <= timeoutMs; waited += 100) {
        CGDisplayModeRef cur = CGDisplayCopyDisplayMode(display);
        bool ok = rdSameMode(cur, mode);
        if (cur) CGDisplayModeRelease(cur);
        if (ok) return true;
        usleep(100 * 1000);
    }
    return false;
}

// If the mirrored physical ended up in a mode different from the desired one, re-set it. true if it's fine.
static bool rdEnsureMirroredPhysicalMode(CGDirectDisplayID display, const char *why) {
    CGDisplayModeRef want = rdCopyWantedMode(display);
    if (!want) return false;
    CGDisplayModeRef cur = CGDisplayCopyDisplayMode(display);
    bool ok = rdSameMode(cur, want);
    if (!ok) {
        NSLog(@"remotedisplay vdisplay: physical %u ended up at %zux%zu px after %s, re-setting to %zux%zu px",
              display, cur ? CGDisplayModeGetPixelWidth(cur) : 0, cur ? CGDisplayModeGetPixelHeight(cur) : 0,
              why, CGDisplayModeGetPixelWidth(want), CGDisplayModeGetPixelHeight(want));
        ok = rdApplyModeAndWait(display, want, 3000);
        NSLog(@"remotedisplay vdisplay: physical %u mode %s", display, ok ? "re-set" : "COULD NOT re-set");
    }
    if (cur) CGDisplayModeRelease(cur);
    CGDisplayModeRelease(want);
    return ok;
}

// After mirroring or changing `master`'s mode, watches for `settleMs` the
// physicals mirroring it and re-sets their mode if macOS changed it (the slave's
// mode re-selection is asynchronous: it can arrive a few hundred ms later).
// With no physicals mirroring `master` it returns immediately (a normal resize doesn't pay the wait).
static void rdRepairMirrorSlavesOf(CGDirectDisplayID master, const char *why, int settleMs) {
    for (int waited = 0; waited <= settleMs; waited += 250) {
        uint32_t count = 0, slaves = 0;
        CGDirectDisplayID online[16];
        CGGetOnlineDisplayList(16, online, &count);
        for (uint32_t i = 0; i < count; i++) {
            CGDirectDisplayID d = online[i];
            if (d == master || CGDisplayMirrorsDisplay(d) != master) continue;
            if (MacIsOurVirtualDisplay(d)) continue;
            slaves++;
            rdEnsureMirroredPhysicalMode(d, why);
        }
        if (slaves == 0 || waited >= settleMs) break;
        usleep(250 * 1000);
    }
}

// When unmirroring: if macOS didn't return the physical to its previous mode, restore it.
// The memory is KEPT: on the next cycle the physical may already be re-mirrored by the
// time we would remember it (recycled virtual), and this entry is then the only truth.
static void rdRestorePhysicalMode(CGDirectDisplayID display, const char *why) {
    CGDisplayModeRef want = NULL;
    {
        std::lock_guard<std::mutex> lock(g_rdVDisplayMutex);
        auto it = g_rdMirrorModes.find(display);
        if (it == g_rdMirrorModes.end()) return;
        want = it->second;
        CGDisplayModeRetain(want); // our own reference; the map keeps its own
    }
    CGDisplayModeRef cur = CGDisplayCopyDisplayMode(display);
    if (!rdSameMode(cur, want)) {
        NSLog(@"remotedisplay vdisplay: physical %u ended up at %zux%zu px after %s, restoring %zux%zu px",
              display, cur ? CGDisplayModeGetPixelWidth(cur) : 0, cur ? CGDisplayModeGetPixelHeight(cur) : 0,
              why, CGDisplayModeGetPixelWidth(want), CGDisplayModeGetPixelHeight(want));
        bool ok = rdApplyModeAndWait(display, want, 3000);
        NSLog(@"remotedisplay vdisplay: physical %u mode %s", display, ok ? "restored" : "COULD NOT restore");
    }
    if (cur) CGDisplayModeRelease(cur);
    // The unmirror settles asynchronously and macOS can re-pick the mode a moment
    // AFTER our restore went through (measured in the test VM, 2026-09-03: restored
    // to 1920x1080, then back at 1600x900 within a second). Watch for a while and
    // put it back, the same way the mirror-on path does with rdRepairMirrorSlavesOf.
    for (int waited = 0; waited < 2000; waited += 250) {
        usleep(250 * 1000);
        CGDisplayModeRef now = CGDisplayCopyDisplayMode(display);
        bool same = rdSameMode(now, want);
        if (!same) {
            NSLog(@"remotedisplay vdisplay: physical %u flipped to %zux%zu px after the restore (%s), re-restoring %zux%zu px",
                  display, now ? CGDisplayModeGetPixelWidth(now) : 0, now ? CGDisplayModeGetPixelHeight(now) : 0,
                  why, CGDisplayModeGetPixelWidth(want), CGDisplayModeGetPixelHeight(want));
            rdApplyModeAndWait(display, want, 3000);
        }
        if (now) CGDisplayModeRelease(now);
    }
    CGDisplayModeRelease(want);
}

static dispatch_queue_t rdVDisplayQueue() {
    static dispatch_queue_t q = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.remotedisplay.vdisplay", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

static void rdRemoveICC(const std::string &path);
static void rdPruneTerminatedVDisplaysLocked() {
    for (auto it = g_rdVDisplays.begin(); it != g_rdVDisplays.end();) {
        if ([it->second.display displayID] == 0) {
            rdRemoveICC(it->second.iccPath);
            rdFreeSerialLocked(it->second.serial);
            [it->second.display release];
            it = g_rdVDisplays.erase(it);
        } else {
            ++it;
        }
    }
}

// ColorSync: ported from SimpleDisplay. macOS generates a CUSTOM color profile
// for each virtual display and colorsyncd validates it in a loop (high CPU); it also
// leaves an orphaned .icc under /Library/ColorSync/Profiles/Displays for each
// display created. Assigning sRGB (the system profile) on create avoids BOTH: no
// custom profile is generated -> no CPU loop and no orphaned .icc.
static void rdAssignSRGBProfile(CGDirectDisplayID displayID) {
    CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(displayID);
    if (!uuid) return;
    CFStringRef path = CFSTR("/System/Library/ColorSync/Profiles/sRGB Profile.icc");
    CFURLRef url = CFURLCreateWithFileSystemPath(NULL, path, kCFURLPOSIXPathStyle, false);
    if (url) {
        const void *keys[] = { kColorSyncDeviceDefaultProfileID };
        const void *vals[] = { url };
        CFDictionaryRef info = CFDictionaryCreate(NULL, keys, vals, 1,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        if (info) {
            ColorSyncDeviceSetCustomProfiles(kColorSyncDisplayDeviceClass, uuid, info);
            CFRelease(info);
        }
        CFRelease(url);
    }
    CFRelease(uuid);
}

// Deletes in the background any orphaned .icc files for this display (in case
// they were generated anyway). Root-owned: can fail without privileges (a minor issue),
// but with sRGB assigned there's normally nothing to delete.

extern "C" bool MacVirtualDisplaySupported() {
    return NSClassFromString(@"CGVirtualDisplay") != nil &&
           NSClassFromString(@"CGVirtualDisplayDescriptor") != nil &&
           NSClassFromString(@"CGVirtualDisplaySettings") != nil &&
           NSClassFromString(@"CGVirtualDisplayMode") != nil;
}

// Applies a mode (in points) to an existing CGVirtualDisplay, without recreating it.
static bool rdApplyVDisplayMode(CGVirtualDisplay *display, uint32_t width, uint32_t height,
                                double refreshRate, bool hidpi) {
    // hiDPI on CGVirtualDisplay (macOS 26, measured with the hidpi_test* harnesses):
    // the mode is declared in POINTS. With hiDPI=1 WindowServer generates the Retina
    // variant (2x pixels) but ONLY keeps it as the current mode when those pixels
    // exceed ~1920 in width; below that it flattens to 1x with double the points, the
    // explicit mode selection (CGConfigureDisplayWithDisplayMode) fails, and
    // enumerating/configuring leaves ghost displays on destroy. That's why real Retina
    // only happens when 2*width >= 1920 (at exactly 1920 if it picks it: hidpi_test2); if
    // not, 1x with the requested points (the client already requests points = pixels/scale:
    // slightly bigger, somewhat smoother text).
    bool useHiDPI = hidpi && (2u * width >= 1920u);
    hidpi = useHiDPI;
    NSUInteger pxW = width;
    NSUInteger pxH = height;
    Class modeCls = NSClassFromString(@"CGVirtualDisplayMode");
    Class settingsCls = NSClassFromString(@"CGVirtualDisplaySettings");
    CGVirtualDisplayMode *mode = [[modeCls alloc] initWithWidth:pxW height:pxH refreshRate:refreshRate];
    CGVirtualDisplaySettings *settings = [[settingsCls alloc] init];
    settings.modes = @[ mode ];
    settings.hiDPI = hidpi ? 1 : 0;
    BOOL ok = NO;
    @try {
        ok = [display applySettings:settings];
    } @catch (NSException *e) {
        NSLog(@"remotedisplay vdisplay: applySettings failed: %@", e.reason);
        ok = NO;
    }
    [settings release];
    [mode release];
    return ok;
}

extern "C" uint32_t MacCreateVirtualDisplay(uint32_t width, uint32_t height, double refreshRate,
                                            bool hidpi, const char *name) {
    if (!MacVirtualDisplaySupported()) {
        NSLog(@"remotedisplay vdisplay: CGVirtualDisplay not available on this system");
        return 0;
    }
    Class descCls = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class displayCls = NSClassFromString(@"CGVirtualDisplay");

    CGVirtualDisplayDescriptor *desc = [[descCls alloc] init];
    desc.name = name ? [NSString stringWithUTF8String:name] : @"Remote Display Virtual";
    desc.vendorID = RD_VDISPLAY_VENDOR_ID;
    desc.productID = RD_VDISPLAY_PRODUCT_ID;
    // STABLE serial per slot: this way macOS reuses that slot's profile/ICC instead
    // of generating a new one each time (avoids colorsyncd's CPU churn).
    uint32_t serial;
    {
        std::lock_guard<std::mutex> lock(g_rdVDisplayMutex);
        serial = rdAllocSerialLocked();
    }
    desc.serialNumber = serial;
    // Physical size ~24" 16:9: defines the logical DPI the system reports.
    desc.sizeInMillimeters = CGSizeMake(527, 296);
    // Large maxPixels so we can reconfigure on the fly without recreating.
    desc.maxPixelsWide = 8192;
    desc.maxPixelsHigh = 8192;
    desc.dispatchQueue = rdVDisplayQueue();
    desc.terminationHandler = ^{
        std::lock_guard<std::mutex> lock(g_rdVDisplayMutex);
        rdPruneTerminatedVDisplaysLocked();
    };

    // Snapshot of .icc files BEFORE creating, to identify the one macOS will generate.
    NSSet<NSString *> *iccBefore = rdSnapshotICCs();

    CGVirtualDisplay *display = nil;
    @try {
        display = [[displayCls alloc] initWithDescriptor:desc];
    } @catch (NSException *e) {
        NSLog(@"remotedisplay vdisplay: creation failed: %@", e.reason);
        display = nil;
    }
    [desc release];

    if (!display || [display displayID] == 0) {
        [display release];
        std::lock_guard<std::mutex> lock(g_rdVDisplayMutex);
        rdFreeSerialLocked(serial);
        return 0;
    }
    if (!rdApplyVDisplayMode(display, width, height, refreshRate, hidpi)) {
        [display release];
        std::lock_guard<std::mutex> lock(g_rdVDisplayMutex);
        rdFreeSerialLocked(serial);
        return 0;
    }
    uint32_t displayID = [display displayID];
    // Wait for the display to appear active (creation is asynchronous in WindowServer).
    for (int i = 0; i < 50; i++) {
        if (CGDisplayIsActive(displayID)) break;
        usleep(100 * 1000);
    }
    // Assign sRGB to reduce colorsyncd's CPU churn.
    rdAssignSRGBProfile(displayID);
    {
        std::lock_guard<std::mutex> lock(g_rdVDisplayMutex);
        g_rdVDisplays[displayID] =
            RDVDisplayEntry{display, width, height, hidpi, refreshRate, "", serial};
        g_rdVDisplays[displayID].hidpiRequested = hidpi;
    }
    // Identify the .icc macOS generated for THIS display IN THE BACKGROUND: the
    // diff polls (generation is asynchronous) and must NOT block the create.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        std::string iccPath = rdFindNewICC(iccBefore);
        if (iccPath.empty()) return;
        std::lock_guard<std::mutex> lock(g_rdVDisplayMutex);
        auto it = g_rdVDisplays.find(displayID);
        if (it != g_rdVDisplays.end() && it->second.iccPath.empty()) {
            it->second.iccPath = iccPath;
        } else {
            // The display was already destroyed before its .icc was resolved: delete it now.
            rdRemoveICC(iccPath);
        }
    });
    NSLog(@"remotedisplay vdisplay: created ID %u (%ux%u points, hidpi=%d)",
          displayID, width, height, hidpi);
    return displayID;
}

extern "C" bool MacIsOurVirtualDisplay(uint32_t displayID) {
    std::lock_guard<std::mutex> lock(g_rdVDisplayMutex);
    return g_rdVDisplays.find(displayID) != g_rdVDisplays.end();
}

extern "C" uint32_t MacListVirtualDisplays(uint32_t *ids, uint32_t max) {
    std::lock_guard<std::mutex> lock(g_rdVDisplayMutex);
    rdPruneTerminatedVDisplaysLocked();
    uint32_t n = 0;
    for (auto const &kv : g_rdVDisplays) {
        if (n >= max) break;
        // The hidden dynamic-main virtual (cached, OFF) is not reported.
        if (kv.first == g_rdDynMainVirtual && !g_rdDynMainActive) continue;
        ids[n++] = kv.first;
    }
    return n;
}

// Hot resize: applySettings on the existing display. The displayID
// stays stable (key for the remote session to keep capturing).
static bool rdRepairDynMainMirror(void); // defined next to rdSetMirror

// Waits for CGDisplayBounds (points) to reflect w x h.
static bool rdWaitBounds(uint32_t displayID, uint32_t w, uint32_t h, int timeoutMs) {
    for (int i = 0; i < timeoutMs / 100; i++) {
        CGRect b = CGDisplayBounds(displayID);
        if ((uint32_t)b.size.width == w && (uint32_t)b.size.height == h) return true;
        usleep(100 * 1000);
    }
    return false;
}

// Waits for the display's CURRENT mode to have the requested pixel size.
// Needed for HiDPI toggles with the same points: the bounds don't change
// (960x505 in both 1x and 2x), only the backing does.
// The size in POINTS is also required: the "flattened" variant (1x with double
// the points) has the same pixels as Retina and is not what was requested.
static bool rdWaitPixels(CGDirectDisplayID displayID, uint32_t pxW, uint32_t pxH, int timeoutMs) {
    for (int waited = 0; waited <= timeoutMs; waited += 100) {
        CGDisplayModeRef m = CGDisplayCopyDisplayMode(displayID);
        if (m) {
            bool ok = CGDisplayModeGetPixelWidth(m) == pxW && CGDisplayModeGetPixelHeight(m) == pxH
                   && CGDisplayModeGetWidth(m) * 2 == pxW && CGDisplayModeGetHeight(m) * 2 == pxH;
            CGDisplayModeRelease(m);
            if (ok) return true;
        }
        if (waited >= timeoutMs) break;
        usleep(100 * 1000);
    }
    return false;
}

// Main or mirror master: applySettings doesn't switch without a transaction.
static bool rdNeedsNudge(uint32_t displayID) {
    if (CGMainDisplayID() == displayID) return true;
    uint32_t count = 0;
    CGDirectDisplayID online[16];
    CGGetOnlineDisplayList(16, online, &count);
    for (uint32_t i = 0; i < count; i++) {
        if (online[i] != displayID && CGDisplayMirrorsDisplay(online[i]) == displayID) return true;
    }
    return false;
}

// Trivial commit (origin set to its own value) that switches over the already-declared mode.
static void rdNudge(uint32_t displayID) {
    CGDisplayConfigRef config;
    if (CGBeginDisplayConfiguration(&config) == kCGErrorSuccess) {
        CGRect b = CGDisplayBounds(displayID);
        CGConfigureDisplayOrigin(config, displayID, (int32_t)b.origin.x, (int32_t)b.origin.y);
        if (CGCompleteDisplayConfiguration(config, kCGConfigureForSession) != kCGErrorSuccess) {
            CGCancelDisplayConfiguration(config);
        }
    }
}

extern "C" bool MacResizeVirtualDisplay(uint32_t displayID, uint32_t width, uint32_t height) {
    CGVirtualDisplay *display = nil;
    double refreshRate = 60;
    bool hidpi = false;
    {
        std::lock_guard<std::mutex> lock(g_rdVDisplayMutex);
        auto it = g_rdVDisplays.find(displayID);
        if (it == g_rdVDisplays.end()) return false;
        display = it->second.display;
        refreshRate = it->second.refreshRate;
        hidpi = it->second.hidpiRequested;
    }
    // Same heuristic as rdApplyVDisplayMode: below ~1920 px wide
    // WindowServer doesn't offer the Retina variant; don't wait for it.
    if (hidpi && 2 * width < 1920) {
        NSLog(@"remotedisplay vdisplay: ID %u %ux%u points is too small for Retina, staying 1x", displayID, width, height);
        hidpi = false;
        std::lock_guard<std::mutex> lock(g_rdVDisplayMutex);
        auto it = g_rdVDisplays.find(displayID);
        if (it != g_rdVDisplays.end()) it->second.hidpiRequested = false;
    }
    if (!rdApplyVDisplayMode(display, width, height, refreshRate, hidpi)) {
        return false;
    }
    bool needsNudge = rdNeedsNudge(displayID);
    // An applySettings call while the display is still switching from its previous mode
    // (e.g. just switched to HiDPI) is silently dropped (macOS 26):
    // wait for the bounds to reflect the mode and, if not, re-apply ONCE.
    // No configuration transactions here (those turn into ghosts on destroy).
    // (With a nudge pending, the bounds don't change until the commit: this is skipped.)
    if (!needsNudge) {
        bool settled = false;
        for (int attempt = 0; attempt < 2 && !settled; attempt++) {
            for (int i = 0; i < 25; i++) {
                CGRect b = CGDisplayBounds(displayID);
                if ((uint32_t)b.size.width == width && (uint32_t)b.size.height == height) {
                    settled = true;
                    break;
                }
                usleep(100 * 1000);
            }
            if (!settled && attempt == 0) {
                NSLog(@"remotedisplay vdisplay: ID %u did not settle at %ux%u, re-applying", displayID, width, height);
                (void)rdApplyVDisplayMode(display, width, height, refreshRate, hidpi);
            }
        }
        if (!settled) NSLog(@"remotedisplay vdisplay: ID %u still hasn't settled at %ux%u", displayID, width, height);
    }
    // applySettings auto-commits on a secondary display without a mirror, but
    // NOT when the display is main or the master of a mirror set (macOS 26): there the
    // mode stays declared without switching until the next configuration
    // transaction. In that case a trivial "nudge" is committed (origin set to its
    // own value). NOTE: the nudge is only done WHEN NEEDED — any
    // commit snapshots the arrangement into the session config, and a virtual
    // present in that snapshot turns into a ghost when destroyed. The only display
    // that needs a nudge is the dynamic main's, which is never destroyed
    // (it's cached disabled).
    if (needsNudge) {
        CGDisplayConfigRef config;
        if (CGBeginDisplayConfiguration(&config) == kCGErrorSuccess) {
            CGRect b = CGDisplayBounds(displayID);
            CGConfigureDisplayOrigin(config, displayID, (int32_t)b.origin.x, (int32_t)b.origin.y);
            if (CGCompleteDisplayConfiguration(config, kCGConfigureForSession) != kCGErrorSuccess) {
                CGCancelDisplayConfiguration(config);
            }
        }
        // Escalation: sometimes the no-op nudge gets dropped (seen with
        // re-enabled displays). The new mode is already declared by applySettings:
        // switch explicitly via CGConfigureDisplayWithDisplayMode.
        bool applied = false;
        for (int i = 0; i < 15; i++) {
            CGRect b = CGDisplayBounds(displayID);
            if ((uint32_t)b.size.width == width && (uint32_t)b.size.height == height) {
                applied = true;
                break;
            }
            usleep(100 * 1000);
        }
        if (!applied) {
            if (!MacSetMode(displayID, width, height, hidpi)) {
                NSLog(@"remotedisplay vdisplay: escalation MacSetMode %ux%u failed", width, height);
            }
        }
    }
    // Final verification. If HiDPI was requested and the mode didn't settle (e.g. the
    // dynamic main's primary display doesn't accept the Retina variant), fall back
    // to 1x with the SAME points: the scale is honored even without 2x backing.
    if (hidpi && !rdWaitPixels(displayID, 2 * width, 2 * height, 5000)) {
        NSLog(@"remotedisplay vdisplay: ID %u did not accept %ux%u in HiDPI, falling back to 1x", displayID, width, height);
        hidpi = false;
        (void)rdApplyVDisplayMode(display, width, height, refreshRate, false);
        if (needsNudge) {
            usleep(200 * 1000);
            rdNudge(displayID);
        }
        if (!rdWaitBounds(displayID, width, height, 4000)) {
            NSLog(@"remotedisplay vdisplay: ID %u did not settle at %ux%u in 1x either", displayID, width, height);
        }
    }
    // Final flag based on the REAL backing of the current mode (if it's already at the
    // requested size in points): 2x => HiDPI, 1x => not.
    {
        CGDisplayModeRef m = CGDisplayCopyDisplayMode(displayID);
        if (m) {
            uint32_t pw = (uint32_t)CGDisplayModeGetPixelWidth(m), w = (uint32_t)CGDisplayModeGetWidth(m);
            CGDisplayModeRelease(m);
            if (w == width) {
                bool live = pw == 2 * width;
                if (pw == width || live) {
                    if (live != hidpi) NSLog(@"remotedisplay vdisplay: ID %u actual backing hidpi=%d (expected %d)", displayID, live, hidpi);
                    hidpi = live;
                }
            }
        }
    }
    {
        std::lock_guard<std::mutex> lock(g_rdVDisplayMutex);
        auto it = g_rdVDisplays.find(displayID);
        if (it != g_rdVDisplays.end()) {
            it->second.width = width;
            it->second.height = height;
            it->second.hidpi = hidpi;
        }
    }
    NSLog(@"remotedisplay vdisplay: resize ID %u -> %ux%u (hidpi=%d)", displayID, width, height, hidpi);
    // A physical mirroring this virtual may have changed mode with the
    // resize (macOS re-picks the slave's mode): re-set it.
    rdRepairMirrorSlavesOf(displayID, "master resize", 1500);
    // Changing another display's mode dissolves the dynamic main's mirror (macOS 26).
    {
        uint32_t vid = 0;
        { std::lock_guard<std::mutex> lock(g_rdVDisplayMutex); vid = g_rdDynMainActive ? g_rdDynMainVirtual : 0; }
        if (vid != 0 && vid != displayID) {
            usleep(300 * 1000);
            (void)rdRepairDynMainMirror();
        }
    }
    return true;
}

// Hot scale (HiDPI / "Retina") toggle: changes the flag and re-applies the
// current mode in POINTS; the framebuffer switches to 2x points (or back to 1x). The client
// decides points = its window's pixels / scale (100/125/150/200 %).
extern "C" bool MacSetVirtualDisplayHiDPI(uint32_t displayID, bool hidpi) {
    CGVirtualDisplay *display = nil;
    uint32_t w = 0, h = 0;
    double refreshRate = 60;
    {
        std::lock_guard<std::mutex> lock(g_rdVDisplayMutex);
        auto it = g_rdVDisplays.find(displayID);
        if (it == g_rdVDisplays.end()) return false;
        if (it->second.hidpiRequested == hidpi) return true;
        it->second.hidpiRequested = hidpi;
        display = it->second.display;
        w = it->second.width;
        h = it->second.height;
        refreshRate = it->second.refreshRate;
    }
    // The mode is only DECLARED with the requested backing, without waiting: the
    // current size may not support Retina (e.g. 1920x1080 points = 3840x2160 px in
    // a VM) and the client resizes to the final size right afterward; that
    // resize applies and verifies the backing (MacResizeVirtualDisplay).
    NSLog(@"remotedisplay vdisplay: ID %u hidpi requested=%d (declaring %ux%u points)", displayID, hidpi, w, h);
    (void)rdApplyVDisplayMode(display, w, h, refreshRate, hidpi && 2 * w >= 1920);
    return true;
}

// Reports what was REQUESTED (what the client decided and uses for its scale); the
// actual backing is left in `hidpi` for diagnostics (resize log).
extern "C" bool MacIsVirtualDisplayHiDPI(uint32_t displayID) {
    std::lock_guard<std::mutex> lock(g_rdVDisplayMutex);
    auto it = g_rdVDisplays.find(displayID);
    return it != g_rdVDisplays.end() && it->second.hidpiRequested;
}

// Main loop of the headless server: NSApplication with no UI (Prohibited) so that
// AppKit pumps CGS events. Without this, after CGCompleteDisplayConfiguration
// (dynamic main mirroring) the process's CGGetOnlineDisplayList stops seeing
// new displays (verified with harness/mirror_enum_test2.mm: only NSApp's event
// loop refreshes them; CFRunLoopRunInMode does not). [NSApp run] also drains
// the GCD main queue, which input injection uses.
// Shutdown of the headless server: launchd (`bootout`, `kickstart -k`, the app's
// service toggle) sends SIGTERM, a terminal sends SIGINT. Put the displays back
// before exiting, like SimpleDisplay did when it was quit: undo the dynamic main,
// turn the physicals back on, destroy the virtuals. The work happens on a GCD
// queue (a dispatch signal source, not a signal handler), so the display APIs
// are safe to call and the main thread keeps pumping AppKit meanwhile.
// launchd waits 20 s by default before SIGKILL; a reset takes a few seconds.
extern "C" void remotedisplay_reset_displays(void) __attribute__((weak_import)); // Rust, virtual_display_manager.rs
static void rdInstallShutdownHandlers() {
    static dispatch_source_t sources[2];
    static std::atomic<bool> done{false};
    const int sigs[2] = {SIGTERM, SIGINT};
    for (int i = 0; i < 2; i++) {
        signal(sigs[i], SIG_IGN); // required for a dispatch signal source to see it
        sources[i] = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, (uintptr_t)sigs[i], 0,
                                            dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
        const int sig = sigs[i];
        dispatch_source_set_event_handler(sources[i], ^{
            if (done.exchange(true)) return;
            NSLog(@"remotedisplay vdisplay: signal %d: restoring the displays before exiting", sig);
            if (remotedisplay_reset_displays) remotedisplay_reset_displays();
            NSLog(@"remotedisplay vdisplay: displays restored, exiting");
            exit(0);
        });
        dispatch_resume(sources[i]);
    }
}

// The headless NSApplication shares the bundle (and bundle id) with the menu bar
// app, so a "quit" Apple event addressed to "Remote Display Server" (osascript,
// logout, the system's background-items UI) can land HERE. AppKit would answer it
// with a plain exit(): put the displays back first, like on SIGTERM.
@interface RDHeadlessAppDelegate : NSObject <NSApplicationDelegate>
@end
@implementation RDHeadlessAppDelegate
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    static std::atomic<bool> done{false};
    if (!done.exchange(true)) {
        NSLog(@"remotedisplay vdisplay: quit Apple event: restoring the displays before exiting");
        if (remotedisplay_reset_displays) remotedisplay_reset_displays();
        NSLog(@"remotedisplay vdisplay: displays restored, exiting");
    }
    return NSTerminateNow;
}
@end

extern "C" void MacRunHeadlessAppLoop() {
    rdInstallShutdownHandlers();
    static RDHeadlessAppDelegate *delegate = [RDHeadlessAppDelegate new];
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyProhibited];
        [app setDelegate:delegate];
        [app finishLaunching];
    }
    [NSApp run];
}

extern "C" bool MacDynamicMainOff(); // definido mas abajo

extern "C" bool MacDestroyVirtualDisplay(uint32_t displayID) {
    // The dynamic main's virtual is NOT destroyed (it's the master of a mirror:
    // destroying it leaves a ghost display on macOS 26). "Removing" it from the
    // UI = turning off the dynamic main: unmirror the physical, give it back the
    // main role, and hide the virtual so it can be recycled.
    bool isDynMain = false;
    {
        std::lock_guard<std::mutex> lock(g_rdVDisplayMutex);
        isDynMain = displayID != 0 && displayID == g_rdDynMainVirtual;
    }
    if (isDynMain) {
        NSLog(@"remotedisplay vdisplay: destroy of %u = turning off dynamic main", displayID);
        return MacDynamicMainOff(); // takes the lock on its own
    }
    std::lock_guard<std::mutex> lock(g_rdVDisplayMutex);
    auto it = g_rdVDisplays.find(displayID);
    if (it == g_rdVDisplays.end()) return false;
    rdRemoveICC(it->second.iccPath);   // delete this display's exact .icc
    rdFreeSerialLocked(it->second.serial); // free the slot for reuse
    [it->second.display release];      // releasing the last reference destroys it
    g_rdVDisplays.erase(it);
    NSLog(@"remotedisplay vdisplay: destroyed ID %u", displayID);
    return true;
}

extern "C" void MacDestroyAllVirtualDisplays() {
    std::lock_guard<std::mutex> lock(g_rdVDisplayMutex);
    for (auto it = g_rdVDisplays.begin(); it != g_rdVDisplays.end();) {
        // The dynamic main's cached virtual is NOT destroyed here: it stays
        // hidden as a mirror slave and gets recycled; it dies with the process.
        if (it->first == g_rdDynMainVirtual) {
            ++it;
            continue;
        }
        rdRemoveICC(it->second.iccPath);
        rdFreeSerialLocked(it->second.serial);
        [it->second.display release];
        it = g_rdVDisplays.erase(it);
    }
    rdSweepOrphanICCsLocked();
}

// ==================== remotedisplay: dynamic main (case 1, SimpleDisplay-style mirroring) ====================

// Relocates origins so newMain ends up at (0,0) — the setMainDisplay "dance"
// from SimpleDisplay, ported over. kCGConfigureForSession: auto-reverts on
// logout/reboot if the process dies with the mirror in place.
static bool rdSetMainDisplay(CGDirectDisplayID newMain) {
    if (CGMainDisplayID() == newMain) return true;
    CGRect targetBounds = CGDisplayBounds(newMain);
    int32_t offsetX = (int32_t)targetBounds.origin.x;
    int32_t offsetY = (int32_t)targetBounds.origin.y;

    uint32_t count = 0;
    CGGetActiveDisplayList(0, NULL, &count);
    std::vector<CGDirectDisplayID> ids(count);
    CGGetActiveDisplayList(count, ids.data(), &count);

    CGDisplayConfigRef config;
    if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess) return false;
    for (uint32_t i = 0; i < count; i++) {
        CGRect b = CGDisplayBounds(ids[i]);
        CGConfigureDisplayOrigin(config, ids[i], (int32_t)b.origin.x - offsetX,
                                 (int32_t)b.origin.y - offsetY);
    }
    if (CGCompleteDisplayConfiguration(config, kCGConfigureForSession) != kCGErrorSuccess) {
        CGCancelDisplayConfiguration(config);
        return false;
    }
    return true;
}

static bool rdSetMirror(CGDirectDisplayID display, CGDirectDisplayID master) {
    CGDisplayConfigRef config;
    if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess) return false;
    if (CGConfigureDisplayMirrorOfDisplay(config, display, master) != kCGErrorSuccess) {
        CGCancelDisplayConfiguration(config);
        return false;
    }
    if (CGCompleteDisplayConfiguration(config, kCGConfigureForSession) != kCGErrorSuccess) {
        CGCancelDisplayConfiguration(config);
        return false;
    }
    return true;
}

// macOS 26 dissolves the dynamic main's mirror when the mode of ANY other
// display changes (measured: harness/mirror_stability_test.mm). If the
// dynamic main is still "active" but the physical no longer mirrors the virtual, it's
// re-mirrored (same steps as when turning it on). true if it ended up mirrored.
static bool rdRepairDynMainMirror(void) {
    uint32_t vid = 0, physical = 0;
    {
        std::lock_guard<std::mutex> lock(g_rdVDisplayMutex);
        if (!g_rdDynMainActive) return true;
        vid = g_rdDynMainVirtual;
        physical = g_rdDynMainPhysical;
    }
    if (vid == 0 || physical == 0) return true;
    if (CGDisplayMirrorsDisplay(physical) == vid) return true;
    NSLog(@"remotedisplay vdisplay: dynamic main's mirror broke (physical %u no longer mirrors %u): repairing", physical, vid);
    if (CGMainDisplayID() != vid && !rdSetMainDisplay(vid)) return false;
    if (!rdSetMirror(physical, vid)) return false;
    for (int t = 0; t < 30; t++) {
        if (CGDisplayMirrorsDisplay(physical) == vid) {
            NSLog(@"remotedisplay vdisplay: dynamic main's mirror repaired");
            rdEnsureMirroredPhysicalMode(physical, "mirror repair");
            return true;
        }
        usleep(100 * 1000);
    }
    return CGDisplayMirrorsDisplay(physical) == vid;
}

static bool rdSetDisplayEnabled(CGDirectDisplayID display, bool enabled); // defined further below

extern "C" bool MacDynamicMainActive() {
    uint32_t vid = 0, physical = 0;
    bool active = false;
    {
        std::lock_guard<std::mutex> lock(g_rdVDisplayMutex);
        active = g_rdDynMainActive;
        vid = g_rdDynMainVirtual;
        physical = g_rdDynMainPhysical;
    }
    if (!active) return false;
    // Self-correction: if the mirror broke from outside (e.g. the physical changed
    // mode or someone unmirrored it), the dynamic main no longer effectively exists.
    // Mark it off and hide its virtual so it doesn't stay around as a stray monitor
    // (same path as MacDynamicMainOff: it's recycled, not destroyed).
    if (physical != 0 && CGDisplayMirrorsDisplay(physical) != vid) {
        if (rdRepairDynMainMirror()) return true;
        NSLog(@"remotedisplay vdisplay: dynamic main broke from outside (physical %u no longer mirrors %u) and could not be repaired: turning off", physical, vid);
        {
            std::lock_guard<std::mutex> lock(g_rdVDisplayMutex);
            g_rdDynMainActive = false;
        }
        if (CGMainDisplayID() == vid) rdSetMainDisplay(physical);
        rdSetDisplayEnabled(vid, false);
        return false;
    }
    return true;
}

extern "C" uint32_t MacDynamicMainVirtualID() {
    std::lock_guard<std::mutex> lock(g_rdVDisplayMutex);
    return g_rdDynMainVirtual;
}

// The physical display currently mirrored by the dynamic main (0 if it's off).
extern "C" uint32_t MacDynamicMainPhysicalID() {
    std::lock_guard<std::mutex> lock(g_rdVDisplayMutex);
    return g_rdDynMainActive ? g_rdDynMainPhysical : 0;
}

// Turns on the dynamic main: creates a virtual display of width x height (points),
// promotes it to main, and mirrors the main physical monitor onto it.
// The desktop ends up living on the virtual (arbitrary resolutions on the fly)
// and the physical just reflects it.
// Waits for CGDisplayBounds(id) to report w x h (mode change is asynchronous).
static bool rdWaitForBounds(CGDirectDisplayID id, uint32_t w, uint32_t h, int timeoutMs) {
    for (int i = 0; i < timeoutMs / 100; i++) {
        CGRect b = CGDisplayBounds(id);
        if ((uint32_t)b.size.width == w && (uint32_t)b.size.height == h) return true;
        usleep(100 * 1000);
    }
    return false;
}

// Waits for a display to appear/disappear from the active list.
static bool rdIsInActiveList(CGDirectDisplayID id) {
    uint32_t count = 0;
    CGDirectDisplayID ids[16];
    CGGetActiveDisplayList(16, ids, &count);
    for (uint32_t i = 0; i < count; i++) {
        if (ids[i] == id) return true;
    }
    return false;
}

static bool rdWaitActiveState(CGDirectDisplayID id, bool wantActive, int timeoutMs) {
    for (int i = 0; i < timeoutMs / 100; i++) {
        if (rdIsInActiveList(id) == wantActive) return true;
        usleep(100 * 1000);
    }
    return false;
}

// CGSConfigureDisplayEnabled (SkyLight, private): truly disables/re-enables a
// display (leaves/enters the active list instantly, without touching the
// rest). Resolved via dlsym to avoid referencing private symbols in the link.
typedef CGError (*RDConfigureDisplayEnabledFn)(CGDisplayConfigRef, CGDirectDisplayID, bool);
static RDConfigureDisplayEnabledFn rdConfigureDisplayEnabledFn() {
    static RDConfigureDisplayEnabledFn fn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = (RDConfigureDisplayEnabledFn)dlsym(RTLD_DEFAULT, "CGSConfigureDisplayEnabled");
    });
    return fn;
}

static bool rdSetDisplayEnabled(CGDirectDisplayID display, bool enabled) {
    RDConfigureDisplayEnabledFn fn = rdConfigureDisplayEnabledFn();
    if (!fn) return false;
    CGDisplayConfigRef config;
    if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess) return false;
    if (fn(config, display, enabled) != kCGErrorSuccess) {
        CGCancelDisplayConfiguration(config);
        return false;
    }
    if (CGCompleteDisplayConfiguration(config, kCGConfigureForSession) != kCGErrorSuccess) {
        CGCancelDisplayConfiguration(config);
        return false;
    }
    return true;
}

// Unmirrors `display` and waits for the change to SETTLE (no mirror relation
// and back in the active list). Chaining mirror configs without waiting for
// settling creates mirror cycles and leaves 0 active displays (macOS 26).
static bool rdUnmirrorAndSettle(CGDirectDisplayID display, int timeoutMs) {
    if (CGDisplayMirrorsDisplay(display) == kCGNullDirectDisplay &&
        rdIsInActiveList(display)) {
        return true;
    }
    if (!rdSetMirror(display, kCGNullDirectDisplay)) return false;
    for (int i = 0; i < timeoutMs / 100; i++) {
        if (CGDisplayMirrorsDisplay(display) == kCGNullDirectDisplay &&
            rdIsInActiveList(display)) {
            return true;
        }
        usleep(100 * 1000);
    }
    return false;
}

extern "C" bool MacDynamicMainOn(uint32_t width, uint32_t height, bool hidpi) {
    if (MacDynamicMainActive()) {
        // Already active: resize the existing virtual. WindowServer does NOT apply
        // mode changes to a display that is the master of a mirror set
        // (verified on macOS 26): unmirror -> resize -> re-mirror.
        uint32_t vid = MacDynamicMainVirtualID();
        uint32_t physical = 0;
        {
            std::lock_guard<std::mutex> lock(g_rdVDisplayMutex);
            physical = g_rdDynMainPhysical;
        }
        // The resize works with the mirror active thanks to the commit-nudge in
        // MacResizeVirtualDisplay; the physical's mirror rescales on its own.
        (void)physical;
        bool ok = MacResizeVirtualDisplay(vid, width, height);
        if (ok) {
            rdWaitForBounds(vid, width, height, 3000);
        }
        return ok;
    }

    CGDirectDisplayID physical = CGMainDisplayID();
    // Remember the physical's own mode NOW, while it is still standalone: in the test
    // VM it was already mirroring the virtual right after the virtual appeared, and the
    // later call below could only fall back to the native mode.
    rdRememberPhysicalMode(physical);
    uint32_t vid = 0;
    {
        std::lock_guard<std::mutex> lock(g_rdVDisplayMutex);
        vid = g_rdDynMainVirtual; // recycle the cached virtual if it exists
    }
    if (vid != 0) {
        // Was disabled (hidden): re-enable it and wait for it to come back.
        if (!rdSetDisplayEnabled(vid, true) || !rdWaitActiveState(vid, true, 5000)) {
            NSLog(@"remotedisplay vdisplay: cached virtual %u did not become active again", vid);
            return false;
        }
        MacResizeVirtualDisplay(vid, width, height);
        rdWaitForBounds(vid, width, height, 3000);
    } else {
        vid = MacCreateVirtualDisplay(width, height, 60, hidpi, "Remote Display Dynamic");
        if (vid == 0) return false;
    }

    if (!rdSetMainDisplay(vid)) {
        NSLog(@"remotedisplay vdisplay: could not promote the virtual to main");
        rdSetDisplayEnabled(vid, false); // hide it again
        return false;
    }
    rdRememberPhysicalMode(physical);
    if (!rdSetMirror(physical, vid)) {
        NSLog(@"remotedisplay vdisplay: could not mirror physical %u onto virtual %u", physical, vid);
        rdSetMainDisplay(physical);
        rdSetDisplayEnabled(vid, false);
        return false;
    }
    {
        std::lock_guard<std::mutex> lock(g_rdVDisplayMutex);
        g_rdDynMainVirtual = vid;
        g_rdDynMainPhysical = physical;
        g_rdDynMainActive = true;
    }
    rdRepairMirrorSlavesOf(vid, "dynamic main ON", 1500);
    NSLog(@"remotedisplay vdisplay: dynamic main ON (virtual %u, physical %u mirrored)", vid, physical);
    return true;
}

// Turns off the dynamic main: unmirrors the physical, repromotes it, and hides the
// virtual by DISABLING it (CGSConfigureDisplayEnabled). It is not destroyed: former
// mirror-set masters end up as ghosts in WindowServer (macOS 26); the
// cached virtual is recycled on the next ON and dies with the process.
extern "C" bool MacDynamicMainOff() {
    uint32_t vid = 0, physical = 0;
    {
        std::lock_guard<std::mutex> lock(g_rdVDisplayMutex);
        if (!g_rdDynMainActive) return true;
        vid = g_rdDynMainVirtual;
        physical = g_rdDynMainPhysical;
        g_rdDynMainActive = false;
    }
    if (vid == 0) return true;
    // 1. Unmirror the physical and WAIT for it to settle (active and without a mirror).
    bool ok = rdUnmirrorAndSettle(physical, 5000);
    if (!ok) {
        NSLog(@"remotedisplay vdisplay: unmirroring physical %u did not settle", physical);
    }
    rdRestorePhysicalMode(physical, "dynamic main OFF");
    // 2. Repromote the physical and wait for it to become main.
    if (!rdSetMainDisplay(physical)) {
        NSLog(@"remotedisplay vdisplay: could not repromote physical %u to main", physical);
    }
    for (int i = 0; i < 30; i++) {
        if (CGMainDisplayID() == physical) break;
        usleep(100 * 1000);
    }
    // 3. Hide the virtual by disabling it (CGSConfigureDisplayEnabled):
    //    leaves the active list instantly, without the mirror cycles that
    //    trying to re-mirror it as a slave would produce (ex-master, macOS 26).
    if (!rdSetDisplayEnabled(vid, false)) {
        NSLog(@"remotedisplay vdisplay: could not disable virtual %u", vid);
    }
    rdWaitActiveState(vid, false, 3000);
    NSLog(@"remotedisplay vdisplay: dynamic main OFF (physical %u main, virtual %u hidden)", physical, vid);
    return ok;
}

// Actual destruction of the dynamic main's virtual (only when the process shuts down or
// on an explicit reset): can leave a temporary ghost if it was a mirror master.
extern "C" void MacDynamicMainDestroy() {
    MacDynamicMainOff();
    uint32_t vid = 0;
    {
        std::lock_guard<std::mutex> lock(g_rdVDisplayMutex);
        vid = g_rdDynMainVirtual;
        g_rdDynMainVirtual = 0;
        g_rdDynMainPhysical = 0;
    }
    if (vid != 0) {
        MacDestroyVirtualDisplay(vid);
    }
}

// Fingerprint of the display topology (ids, active/main, mirror, bounds and
// pixel mode). The video service compares it every second and recreates the
// capturer if it changes: a CGDisplayStream can go silent after a
// reconfiguration that does NOT move the captured display's bounds (e.g. the
// mode change of a physical mirroring it), and scrap never notices.
extern "C" uint64_t MacDisplayTopologyHash() {
    uint64_t h = 1469598103934665603ULL; // FNV-1a
    auto mix = [&h](uint64_t v) { h ^= v; h *= 1099511628211ULL; };
    uint32_t count = 0;
    CGDirectDisplayID online[16];
    CGGetOnlineDisplayList(16, online, &count);
    mix(count);
    for (uint32_t i = 0; i < count; i++) {
        CGDirectDisplayID d = online[i];
        CGRect b = CGDisplayBounds(d);
        mix(d);
        mix(CGDisplayIsActive(d));
        mix(CGDisplayIsMain(d));
        mix(CGDisplayMirrorsDisplay(d));
        mix((uint64_t)(int64_t)b.origin.x);
        mix((uint64_t)(int64_t)b.origin.y);
        mix((uint64_t)(int64_t)b.size.width);
        mix((uint64_t)(int64_t)b.size.height);
        CGDisplayModeRef m = CGDisplayCopyDisplayMode(d);
        if (m) {
            mix(CGDisplayModeGetPixelWidth(m));
            mix(CGDisplayModeGetPixelHeight(m));
            mix((uint64_t)(CGDisplayModeGetRefreshRate(m) * 100));
            CGDisplayModeRelease(m);
        }
    }
    return h;
}

// ==================== remotedisplay: turning physical monitors off/on ====================
//
// "Turning off" a physical monitor = mirroring it onto the remaining main display
// (SimpleDisplay's disable, ported over): the screen reflects the main and stops
// being an independent desktop (leaves the active list). "Turning on" = removing
// the mirror. kCGConfigureForSession: auto-reverts on logout/reboot.

extern "C" uint32_t MacListActiveDisplays(uint32_t *ids, uint32_t max) {
    uint32_t count = 0;
    CGGetActiveDisplayList(max, ids, &count);
    return count;
}

// Online displays that are neither active nor one of our virtuals = physicals
// turned off (mirrored) that the client should be able to turn back on.
extern "C" uint32_t MacListInactivePhysicalDisplays(uint32_t *ids, uint32_t max) {
    uint32_t online[16], active[16];
    uint32_t nOnline = 0, nActive = 0;
    CGGetOnlineDisplayList(16, online, &nOnline);
    CGGetActiveDisplayList(16, active, &nActive);
    uint32_t n = 0;
    std::lock_guard<std::mutex> lock(g_rdVDisplayMutex);
    for (uint32_t i = 0; i < nOnline && n < max; i++) {
        bool isActive = false;
        for (uint32_t j = 0; j < nActive; j++) {
            if (active[j] == online[i]) { isActive = true; break; }
        }
        if (isActive) continue;
        if (g_rdVDisplays.find(online[i]) != g_rdVDisplays.end()) continue;
        ids[n++] = online[i];
    }
    return n;
}

extern "C" bool MacSetPhysicalDisplayEnabled(uint32_t displayID, bool enabled) {
    if (MacIsOurVirtualDisplay(displayID)) return false;
    if (enabled) {
        // If this physical is mirrored by the dynamic main, "turning it on" means
        // turning off the dynamic main (it becomes main again, the virtual is hidden).
        {
            bool isDynMainPhysical = false;
            {
                std::lock_guard<std::mutex> lock(g_rdVDisplayMutex);
                isDynMainPhysical = g_rdDynMainActive && displayID == g_rdDynMainPhysical;
            }
            if (isDynMainPhysical) {
                NSLog(@"remotedisplay vdisplay: turning on physical %u = turning off dynamic main", displayID);
                return MacDynamicMainOff();
            }
        }
        if (rdIsInActiveList(displayID) &&
            CGDisplayMirrorsDisplay(displayID) == kCGNullDirectDisplay) {
            return true; // already on
        }
        bool ok = rdUnmirrorAndSettle(displayID, 5000);
        rdRestorePhysicalMode(displayID, "turn physical on");
        NSLog(@"remotedisplay vdisplay: physical %u turned on (%d)", displayID, ok);
        return ok;
    }
    // Turning off: needs ANOTHER active display to become main.
    uint32_t active[16];
    uint32_t nActive = 0;
    CGGetActiveDisplayList(16, active, &nActive);
    if (!rdIsInActiveList(displayID)) return true; // already off
    if (nActive < 2) {
        NSLog(@"remotedisplay vdisplay: not turning off physical %u — it's the only active display", displayID);
        return false;
    }
    // If it's the main display, promote another one first (SimpleDisplay's dance).
    if (CGMainDisplayID() == displayID) {
        uint32_t other = 0;
        for (uint32_t i = 0; i < nActive; i++) {
            if (active[i] != displayID) { other = active[i]; break; }
        }
        if (!rdSetMainDisplay(other)) {
            NSLog(@"remotedisplay vdisplay: could not transfer main to %u", other);
            return false;
        }
        for (int i = 0; i < 30; i++) {
            if (CGMainDisplayID() == other) break;
            usleep(100 * 1000);
        }
    }
    rdRememberPhysicalMode(displayID);
    bool ok = rdSetMirror(displayID, CGMainDisplayID());
    if (ok) {
        rdWaitActiveState(displayID, false, 3000);
        rdRepairMirrorSlavesOf(CGMainDisplayID(), "turn physical off", 1500);
    }
    NSLog(@"remotedisplay vdisplay: physical %u turned off -> mirrors %u (%d)", displayID, CGMainDisplayID(), ok);
    return ok;
}
