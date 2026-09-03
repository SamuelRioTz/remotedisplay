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

// ==================== remotedisplay: displays virtuales (CGVirtualDisplay) ====================
//
// CGVirtualDisplay es API privada de CoreGraphics (la misma que usan Tart via
// Virtualization.framework del lado host, DeskPad, BetterDisplay y SimpleDisplay).
// Se instancia via NSClassFromString para no referenciar simbolos privados en el
// link, con chequeo en runtime como red de seguridad si Apple la quita.
//
// Semantica de dimensiones: estas funciones reciben PUNTOS (la convencion de
// resoluciones de RustDesk en macOS: MacGetModes/MacSetMode hablan en puntos).
// El modo se declara en pixeles = puntos * 2 cuando hidpi esta activo.

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

// vendor/product propios para poder identificar nuestros displays si hiciera falta
#define RD_VDISPLAY_VENDOR_ID 0x7264   // "rd"
#define RD_VDISPLAY_PRODUCT_ID 0x0001

struct RDVDisplayEntry {
    CGVirtualDisplay *display; // retained (MRC)
    uint32_t width;            // puntos
    uint32_t height;
    bool hidpi;
    double refreshRate;
    std::string iccPath;       // el .icc que macOS generó para este display
    uint32_t serial;           // slot estable (para que macOS reuse su perfil)
    bool hidpiRequested = false; // lo pedido por el cliente; `hidpi` es el backing real medido
};

static std::mutex g_rdVDisplayMutex;
static std::map<uint32_t, RDVDisplayEntry> g_rdVDisplays;

// Pool de seriales estables: vendor/product/serial fijos hacen que macOS
// identifique al display como el MISMO y REUSE su perfil ICC en vez de generar
// uno nuevo por cada create (que es lo que disparaba a colorsyncd). Cada "slot"
// (serial 1,2,3…) reusa su .icc; al destruir se libera el slot para el próximo.
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

// Snapshot de todos los .icc presentes (para diff antes/después de crear).
static NSSet<NSString *> *rdSnapshotICCs() {
    NSMutableSet *s = [NSMutableSet set];
    NSArray *files = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:kRDColorSyncDir error:nil];
    for (NSString *f in files) {
        if ([f hasSuffix:@".icc"]) [s addObject:f];
    }
    return s;
}

// El .icc que apareció respecto a `before` (el que macOS generó para el nuevo
// display). Poll: la generación es asíncrona tras crear el display.
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

// Borra un .icc concreto. Los .icc viven en /Library/ColorSync/Profiles/Displays
// (root:wheel): si remotedisplayd corre sin privilegios el borrado FALLA silencioso
// y el archivo queda (límite de plataforma, igual que SimpleDisplay — sin
// impacto de CPU/memoria gracias al sRGB asignado; el recurso pesado sí se
// libera). Si corre con privilegios (o el user está en wheel), limpia bien.
static void rdRemoveICC(const std::string &path) {
    if (path.empty()) return;
    [[NSFileManager defaultManager]
        removeItemAtPath:[NSString stringWithUTF8String:path.c_str()] error:nil];
}

// Barrido de respaldo: borra los .icc de nuestros displays (prefijo del nombre)
// que NO estén en uso por un display vivo (`keep`). Cubre el caso en que el
// tracking 1:1 se desincroniza (p.ej. creación de muchos a la vez). El físico
// de la VM se llama "Apple Virtual-…" y NO matchea el prefijo, así que se
// preserva. Llamar SOLO con el mutex tomado.
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

// Estado del "main dinamico" (caso 1): fisico espejado sobre nuestro virtual.
// El virtual se CACHEA y se recicla entre ON/OFF: destruir un display que fue
// master de un mirror set deja un fantasma en la lista activa de WindowServer
// (verificado en macOS 26, ninguna reconfiguracion lo purga). Apagado = el
// virtual pasa a esclavo del fisico (sale de la lista activa, invisible).
static uint32_t g_rdDynMainVirtual = 0;
static uint32_t g_rdDynMainPhysical = 0;
static bool g_rdDynMainActive = false;

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

// ColorSync: portado de SimpleDisplay. macOS genera un perfil de color CUSTOM
// para cada display virtual y colorsyncd lo valida en loop (CPU alta); ademas
// deja un .icc huerfano en /Library/ColorSync/Profiles/Displays por cada
// display creado. Asignar sRGB (perfil del sistema) al crear evita AMBOS: no
// se genera perfil custom -> sin loop de CPU y sin .icc huerfano.
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

// Borra en background los .icc huerfanos de este display (si por algun motivo
// se generaron igual). Root-owned: puede fallar sin privilegios (mal menor),
// pero con sRGB asignado normalmente no hay nada que borrar.

extern "C" bool MacVirtualDisplaySupported() {
    return NSClassFromString(@"CGVirtualDisplay") != nil &&
           NSClassFromString(@"CGVirtualDisplayDescriptor") != nil &&
           NSClassFromString(@"CGVirtualDisplaySettings") != nil &&
           NSClassFromString(@"CGVirtualDisplayMode") != nil;
}

// Aplica un modo (en puntos) a un CGVirtualDisplay existente, sin recrearlo.
static bool rdApplyVDisplayMode(CGVirtualDisplay *display, uint32_t width, uint32_t height,
                                double refreshRate, bool hidpi) {
    // hiDPI en CGVirtualDisplay (macOS 26, medido con los harness hidpi_test*):
    // el modo se declara en PUNTOS. Con hiDPI=1 WindowServer genera la variante
    // Retina (2x pixeles) pero SOLO la deja como modo actual cuando esos pixeles
    // superan ~1920 de ancho; por debajo aplana a 1x con el doble de puntos, la
    // seleccion explicita del modo (CGConfigureDisplayWithDisplayMode) falla y
    // enumerar/configurar deja displays fantasma al destruir. Por eso Retina real
    // solo cuando 2*width >= 1920 (a 1920 exactos si la elige: hidpi_test2); si
    // no, 1x con los puntos pedidos (el cliente ya pide puntos = pixeles/escala:
    // texto mas grande, algo mas suave).
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
        NSLog(@"remotedisplay vdisplay: applySettings fallo: %@", e.reason);
        ok = NO;
    }
    [settings release];
    [mode release];
    return ok;
}

extern "C" uint32_t MacCreateVirtualDisplay(uint32_t width, uint32_t height, double refreshRate,
                                            bool hidpi, const char *name) {
    if (!MacVirtualDisplaySupported()) {
        NSLog(@"remotedisplay vdisplay: CGVirtualDisplay no disponible en este sistema");
        return 0;
    }
    Class descCls = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class displayCls = NSClassFromString(@"CGVirtualDisplay");

    CGVirtualDisplayDescriptor *desc = [[descCls alloc] init];
    desc.name = name ? [NSString stringWithUTF8String:name] : @"Remote Display Virtual";
    desc.vendorID = RD_VDISPLAY_VENDOR_ID;
    desc.productID = RD_VDISPLAY_PRODUCT_ID;
    // Serial ESTABLE por slot: así macOS reusa el perfil/ICC de ese slot en vez
    // de generar uno nuevo cada vez (evita el churn de CPU de colorsyncd).
    uint32_t serial;
    {
        std::lock_guard<std::mutex> lock(g_rdVDisplayMutex);
        serial = rdAllocSerialLocked();
    }
    desc.serialNumber = serial;
    // Tamano fisico ~24" 16:9: define el DPI logico que reporta el sistema.
    desc.sizeInMillimeters = CGSizeMake(527, 296);
    // maxPixels grandes para poder reconfigurar en caliente sin recrear.
    desc.maxPixelsWide = 8192;
    desc.maxPixelsHigh = 8192;
    desc.dispatchQueue = rdVDisplayQueue();
    desc.terminationHandler = ^{
        std::lock_guard<std::mutex> lock(g_rdVDisplayMutex);
        rdPruneTerminatedVDisplaysLocked();
    };

    // Snapshot de .icc ANTES de crear, para identificar el que macOS generará.
    NSSet<NSString *> *iccBefore = rdSnapshotICCs();

    CGVirtualDisplay *display = nil;
    @try {
        display = [[displayCls alloc] initWithDescriptor:desc];
    } @catch (NSException *e) {
        NSLog(@"remotedisplay vdisplay: creacion fallo: %@", e.reason);
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
    // Esperar a que el display aparezca activo (la creacion es asincrona en WindowServer).
    for (int i = 0; i < 50; i++) {
        if (CGDisplayIsActive(displayID)) break;
        usleep(100 * 1000);
    }
    // Asignar sRGB para reducir el churn de CPU de colorsyncd.
    rdAssignSRGBProfile(displayID);
    {
        std::lock_guard<std::mutex> lock(g_rdVDisplayMutex);
        g_rdVDisplays[displayID] =
            RDVDisplayEntry{display, width, height, hidpi, refreshRate, "", serial};
        g_rdVDisplays[displayID].hidpiRequested = hidpi;
    }
    // Identificar el .icc que macOS generó para ESTE display EN BACKGROUND: el
    // diff hace poll (la generación es asíncrona) y NO debe bloquear el create.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        std::string iccPath = rdFindNewICC(iccBefore);
        if (iccPath.empty()) return;
        std::lock_guard<std::mutex> lock(g_rdVDisplayMutex);
        auto it = g_rdVDisplays.find(displayID);
        if (it != g_rdVDisplays.end() && it->second.iccPath.empty()) {
            it->second.iccPath = iccPath;
        } else {
            // El display ya se destruyó antes de resolver su .icc: borrarlo ya.
            rdRemoveICC(iccPath);
        }
    });
    NSLog(@"remotedisplay vdisplay: creado ID %u (%ux%u puntos, hidpi=%d)",
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
        // El virtual del main dinamico oculto (cacheado, OFF) no se reporta.
        if (kv.first == g_rdDynMainVirtual && !g_rdDynMainActive) continue;
        ids[n++] = kv.first;
    }
    return n;
}

// Resize en caliente: applySettings sobre el display existente. El displayID
// se mantiene estable (clave para que la sesion remota siga capturando).
static bool rdRepairDynMainMirror(void); // definido junto a rdSetMirror

// Espera a que CGDisplayBounds (puntos) refleje w x h.
static bool rdWaitBounds(uint32_t displayID, uint32_t w, uint32_t h, int timeoutMs) {
    for (int i = 0; i < timeoutMs / 100; i++) {
        CGRect b = CGDisplayBounds(displayID);
        if ((uint32_t)b.size.width == w && (uint32_t)b.size.height == h) return true;
        usleep(100 * 1000);
    }
    return false;
}

// Espera a que el modo ACTUAL del display tenga el tamano en pixeles pedido.
// Necesario para los toggles HiDPI con los mismos puntos: los bounds no cambian
// (960x505 en 1x y en 2x), solo el backing.
// Se exige ademas el tamano en PUNTOS: la variante "aplanada" (1x con el doble
// de puntos) tiene los mismos pixeles que la Retina y no es lo pedido.
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

// Main o master de espejo: applySettings no conmuta sin una transaccion.
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

// Commit trivial (origen a su mismo valor) que conmuta el modo ya declarado.
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
    // Misma heuristica que rdApplyVDisplayMode: por debajo de ~1920 px de ancho
    // WindowServer no ofrece la variante Retina; no esperar por ella.
    if (hidpi && 2 * width < 1920) {
        NSLog(@"remotedisplay vdisplay: ID %u %ux%u puntos es chico para Retina, queda 1x", displayID, width, height);
        hidpi = false;
        std::lock_guard<std::mutex> lock(g_rdVDisplayMutex);
        auto it = g_rdVDisplays.find(displayID);
        if (it != g_rdVDisplays.end()) it->second.hidpiRequested = false;
    }
    if (!rdApplyVDisplayMode(display, width, height, refreshRate, hidpi)) {
        return false;
    }
    bool needsNudge = rdNeedsNudge(displayID);
    // Un applySettings mientras el display todavia conmuta el modo anterior
    // (p.ej. recien cambiado a HiDPI) se descarta en silencio (macOS 26):
    // esperar a que los bounds reflejen el modo y, si no, re-aplicar UNA vez.
    // Sin transacciones de configuracion (esas vuelven fantasma al destruir).
    // (Con nudge pendiente los bounds no cambian hasta el commit: se salta.)
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
                NSLog(@"remotedisplay vdisplay: ID %u no asento %ux%u, re-aplicando", displayID, width, height);
                (void)rdApplyVDisplayMode(display, width, height, refreshRate, hidpi);
            }
        }
        if (!settled) NSLog(@"remotedisplay vdisplay: ID %u sigue sin asentar %ux%u", displayID, width, height);
    }
    // applySettings se auto-commitea en un display secundario sin espejo, pero
    // NO cuando el display es main o master de un mirror set (macOS 26): ahi el
    // modo queda declarado sin conmutar hasta la proxima transaccion de
    // configuracion. En ese caso se commitea un "nudge" trivial (origen a su
    // mismo valor). OJO: el nudge se hace SOLO cuando hace falta — cualquier
    // commit snapshotea el arrangement en la config de sesion y un virtual
    // presente en ese snapshot queda fantasma al destruirlo. El unico display
    // que necesita nudge es el del main dinamico, que nunca se destruye
    // (se cachea deshabilitado).
    if (needsNudge) {
        CGDisplayConfigRef config;
        if (CGBeginDisplayConfiguration(&config) == kCGErrorSuccess) {
            CGRect b = CGDisplayBounds(displayID);
            CGConfigureDisplayOrigin(config, displayID, (int32_t)b.origin.x, (int32_t)b.origin.y);
            if (CGCompleteDisplayConfiguration(config, kCGConfigureForSession) != kCGErrorSuccess) {
                CGCancelDisplayConfiguration(config);
            }
        }
        // Escalada: a veces el nudge no-op se descarta (visto con displays
        // re-habilitados). El modo nuevo ya esta declarado por applySettings:
        // conmutar explicitamente via CGConfigureDisplayWithDisplayMode.
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
                NSLog(@"remotedisplay vdisplay: escalada MacSetMode %ux%u fallo", width, height);
            }
        }
    }
    // Verificacion final. Si se pidio HiDPI y el modo no asento (p.ej. el
    // display principal del main dinamico no acepta la variante Retina), caer
    // a 1x con los MISMOS puntos: la escala se respeta aunque sin backing 2x.
    if (hidpi && !rdWaitPixels(displayID, 2 * width, 2 * height, 5000)) {
        NSLog(@"remotedisplay vdisplay: ID %u no acepto %ux%u en HiDPI, cayendo a 1x", displayID, width, height);
        hidpi = false;
        (void)rdApplyVDisplayMode(display, width, height, refreshRate, false);
        if (needsNudge) {
            usleep(200 * 1000);
            rdNudge(displayID);
        }
        if (!rdWaitBounds(displayID, width, height, 4000)) {
            NSLog(@"remotedisplay vdisplay: ID %u tampoco asento %ux%u en 1x", displayID, width, height);
        }
    }
    // Bandera final segun el backing REAL del modo actual (si ya esta en el
    // tamano pedido en puntos): 2x => HiDPI, 1x => no.
    {
        CGDisplayModeRef m = CGDisplayCopyDisplayMode(displayID);
        if (m) {
            uint32_t pw = (uint32_t)CGDisplayModeGetPixelWidth(m), w = (uint32_t)CGDisplayModeGetWidth(m);
            CGDisplayModeRelease(m);
            if (w == width) {
                bool live = pw == 2 * width;
                if (pw == width || live) {
                    if (live != hidpi) NSLog(@"remotedisplay vdisplay: ID %u backing real hidpi=%d (esperado %d)", displayID, live, hidpi);
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
    // Cambiar el modo de otro display disuelve el espejo del main dinamico (macOS 26).
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

// Escala (HiDPI / "Retina") en caliente: cambia el flag y re-aplica el modo
// actual en PUNTOS; el framebuffer pasa a 2x puntos (o vuelve a 1x). El cliente
// decide puntos = pixeles de su ventana / escala (100/125/150/200 %).
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
    // Solo se DECLARA el modo con el backing pedido, sin esperar: el tamano
    // actual puede no admitir Retina (p.ej. 1920x1080 puntos = 3840x2160 px en
    // una VM) y el cliente redimensiona al tamano final justo despues; ese
    // resize aplica y verifica el backing (MacResizeVirtualDisplay).
    NSLog(@"remotedisplay vdisplay: ID %u hidpi pedido=%d (declarando %ux%u puntos)", displayID, hidpi, w, h);
    (void)rdApplyVDisplayMode(display, w, h, refreshRate, hidpi && 2 * w >= 1920);
    return true;
}

// Reporta lo PEDIDO (lo que el cliente decidio y usa para su escala); el
// backing real queda en `hidpi` para diagnostico (log del resize).
extern "C" bool MacIsVirtualDisplayHiDPI(uint32_t displayID) {
    std::lock_guard<std::mutex> lock(g_rdVDisplayMutex);
    auto it = g_rdVDisplays.find(displayID);
    return it != g_rdVDisplays.end() && it->second.hidpiRequested;
}

// Loop principal del server headless: NSApplication sin UI (Prohibited) para que
// AppKit bombee los eventos CGS. Sin esto, tras CGCompleteDisplayConfiguration
// (espejo del main dinamico) CGGetOnlineDisplayList del proceso deja de ver los
// displays nuevos (verificado con harness/mirror_enum_test2.mm: solo el event
// loop de NSApp los refresca; CFRunLoopRunInMode no). [NSApp run] tambien drena
// la cola principal de GCD, que usa la inyeccion de input.
extern "C" void MacRunHeadlessAppLoop() {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyProhibited];
        [app finishLaunching];
    }
    [NSApp run];
}

extern "C" bool MacDynamicMainOff(); // definido mas abajo

extern "C" bool MacDestroyVirtualDisplay(uint32_t displayID) {
    // El virtual del main dinamico NO se destruye (es master de un espejo:
    // destruirlo deja un display fantasma en macOS 26). "Eliminarlo" desde la
    // UI = apagar el main dinamico: desespejar el fisico, devolverle el rol de
    // principal y ocultar el virtual para reciclarlo.
    bool isDynMain = false;
    {
        std::lock_guard<std::mutex> lock(g_rdVDisplayMutex);
        isDynMain = displayID != 0 && displayID == g_rdDynMainVirtual;
    }
    if (isDynMain) {
        NSLog(@"remotedisplay vdisplay: destroy de %u = apagar main dinamico", displayID);
        return MacDynamicMainOff(); // toma el lock por su cuenta
    }
    std::lock_guard<std::mutex> lock(g_rdVDisplayMutex);
    auto it = g_rdVDisplays.find(displayID);
    if (it == g_rdVDisplays.end()) return false;
    rdRemoveICC(it->second.iccPath);   // borrar el .icc exacto de este display
    rdFreeSerialLocked(it->second.serial); // liberar el slot para reuso
    [it->second.display release];      // soltar la ultima referencia lo destruye
    g_rdVDisplays.erase(it);
    NSLog(@"remotedisplay vdisplay: destruido ID %u", displayID);
    return true;
}

extern "C" void MacDestroyAllVirtualDisplays() {
    std::lock_guard<std::mutex> lock(g_rdVDisplayMutex);
    for (auto it = g_rdVDisplays.begin(); it != g_rdVDisplays.end();) {
        // El virtual cacheado del main dinamico NO se destruye aca: queda
        // oculto como esclavo de espejo y se recicla; muere con el proceso.
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

// ==================== remotedisplay: main dinamico (caso 1, espejo estilo SimpleDisplay) ====================

// Reubica origenes para que newMain quede en (0,0) — el "baile" de setMainDisplay
// de SimpleDisplay, portado. kCGConfigureForSession: se auto-revierte en
// logout/reboot si el proceso muere con el espejo puesto.
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

// macOS 26 disuelve el espejo del main dinamico cuando cambia el modo de
// CUALQUIER otro display (medido: harness/mirror_stability_test.mm). Si el
// main dinamico sigue "activo" pero el fisico ya no espeja al virtual, se
// re-espeja (mismos pasos que al encenderlo). true si quedo espejado.
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
    NSLog(@"remotedisplay vdisplay: espejo del main dinamico roto (fisico %u no espeja a %u): reparando", physical, vid);
    if (CGMainDisplayID() != vid && !rdSetMainDisplay(vid)) return false;
    if (!rdSetMirror(physical, vid)) return false;
    for (int t = 0; t < 30; t++) {
        if (CGDisplayMirrorsDisplay(physical) == vid) {
            NSLog(@"remotedisplay vdisplay: espejo del main dinamico reparado");
            return true;
        }
        usleep(100 * 1000);
    }
    return CGDisplayMirrorsDisplay(physical) == vid;
}

static bool rdSetDisplayEnabled(CGDirectDisplayID display, bool enabled); // definida mas abajo

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
    // Autocorreccion: si el espejo se rompio por fuera (p.ej. el fisico cambio
    // de modo o alguien lo desespejo), el main dinamico ya no existe de hecho.
    // Marcarlo apagado y ocultar su virtual para que no quede como un monitor
    // suelto (mismo camino que MacDynamicMainOff: se recicla, no se destruye).
    if (physical != 0 && CGDisplayMirrorsDisplay(physical) != vid) {
        if (rdRepairDynMainMirror()) return true;
        NSLog(@"remotedisplay vdisplay: main dinamico roto por fuera (fisico %u ya no espeja a %u) y no se pudo reparar: apagando", physical, vid);
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

// Enciende el main dinamico: crea un display virtual de width x height (puntos),
// lo promueve a principal y espeja el monitor fisico principal sobre el.
// El escritorio queda viviendo en el virtual (resoluciones arbitrarias en caliente)
// y el fisico solo lo refleja.
// Espera a que CGDisplayBounds(id) reporte w x h (el cambio de modo es asincrono).
static bool rdWaitForBounds(CGDirectDisplayID id, uint32_t w, uint32_t h, int timeoutMs) {
    for (int i = 0; i < timeoutMs / 100; i++) {
        CGRect b = CGDisplayBounds(id);
        if ((uint32_t)b.size.width == w && (uint32_t)b.size.height == h) return true;
        usleep(100 * 1000);
    }
    return false;
}

// Espera a que un display aparezca/desaparezca de la lista activa.
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

// CGSConfigureDisplayEnabled (SkyLight, privada): deshabilita/rehabilita un
// display de verdad (sale/entra de la lista activa al instante, sin tocar el
// resto). Resuelta por dlsym para no referenciar simbolos privados en el link.
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

// Desespeja `display` y espera a que el cambio ASIENTE (sin relacion de espejo
// y de vuelta en la lista activa). Encadenar configs de espejo sin esperar el
// asentamiento crea ciclos de espejo y deja 0 displays activos (macOS 26).
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
        // Ya activo: resize del virtual existente. WindowServer NO aplica
        // cambios de modo a un display que es master de un mirror set
        // (verificado en macOS 26): desespejar -> resize -> reespejar.
        uint32_t vid = MacDynamicMainVirtualID();
        uint32_t physical = 0;
        {
            std::lock_guard<std::mutex> lock(g_rdVDisplayMutex);
            physical = g_rdDynMainPhysical;
        }
        // El resize funciona con el espejo activo gracias al commit-nudge de
        // MacResizeVirtualDisplay; el espejo del fisico se reescala solo.
        (void)physical;
        bool ok = MacResizeVirtualDisplay(vid, width, height);
        if (ok) {
            rdWaitForBounds(vid, width, height, 3000);
        }
        return ok;
    }

    CGDirectDisplayID physical = CGMainDisplayID();
    uint32_t vid = 0;
    {
        std::lock_guard<std::mutex> lock(g_rdVDisplayMutex);
        vid = g_rdDynMainVirtual; // reciclar el virtual cacheado si existe
    }
    if (vid != 0) {
        // Estaba deshabilitado (oculto): rehabilitarlo y esperar a que vuelva.
        if (!rdSetDisplayEnabled(vid, true) || !rdWaitActiveState(vid, true, 5000)) {
            NSLog(@"remotedisplay vdisplay: el virtual cacheado %u no volvio a activo", vid);
            return false;
        }
        MacResizeVirtualDisplay(vid, width, height);
        rdWaitForBounds(vid, width, height, 3000);
    } else {
        vid = MacCreateVirtualDisplay(width, height, 60, hidpi, "Remote Display Dynamic");
        if (vid == 0) return false;
    }

    if (!rdSetMainDisplay(vid)) {
        NSLog(@"remotedisplay vdisplay: no se pudo promover el virtual a principal");
        rdSetDisplayEnabled(vid, false); // volver a esconderlo
        return false;
    }
    if (!rdSetMirror(physical, vid)) {
        NSLog(@"remotedisplay vdisplay: no se pudo espejar el fisico %u sobre el virtual %u", physical, vid);
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
    NSLog(@"remotedisplay vdisplay: main dinamico ON (virtual %u, fisico %u espejado)", vid, physical);
    return true;
}

// Apaga el main dinamico: desespeja el fisico, lo repromueve, y esconde el
// virtual DESHABILITANDOLO (CGSConfigureDisplayEnabled). No se destruye: los
// ex-masters de mirror set quedan fantasma en WindowServer (macOS 26); el
// virtual cacheado se recicla en el proximo ON y muere con el proceso.
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
    // 1. Desespejar el fisico y ESPERAR a que asiente (activo y sin espejo).
    bool ok = rdUnmirrorAndSettle(physical, 5000);
    if (!ok) {
        NSLog(@"remotedisplay vdisplay: el desespejo del fisico %u no asento", physical);
    }
    // 2. Repromover el fisico y esperar a que sea el principal.
    if (!rdSetMainDisplay(physical)) {
        NSLog(@"remotedisplay vdisplay: no se pudo repromover el fisico %u a principal", physical);
    }
    for (int i = 0; i < 30; i++) {
        if (CGMainDisplayID() == physical) break;
        usleep(100 * 1000);
    }
    // 3. Esconder el virtual deshabilitandolo (CGSConfigureDisplayEnabled):
    //    sale de la lista activa al instante, sin los ciclos de espejo que
    //    produce intentar re-espejarlo como esclavo (ex-master, macOS 26).
    if (!rdSetDisplayEnabled(vid, false)) {
        NSLog(@"remotedisplay vdisplay: no se pudo deshabilitar el virtual %u", vid);
    }
    rdWaitActiveState(vid, false, 3000);
    NSLog(@"remotedisplay vdisplay: main dinamico OFF (fisico %u principal, virtual %u oculto)", physical, vid);
    return ok;
}

// Destruccion real del virtual del main dinamico (solo al bajar el proceso o
// en reset explicito): puede dejar fantasma temporal si fue master de espejo.
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

// ==================== remotedisplay: apagar/prender monitores fisicos ====================
//
// "Apagar" un monitor fisico = espejarlo sobre el display principal restante
// (el disable de SimpleDisplay portado): la pantalla refleja el main y deja de
// ser un desktop independiente (sale de la lista activa). "Prender" = quitar
// el espejo. kCGConfigureForSession: se auto-revierte en logout/reboot.

extern "C" uint32_t MacListActiveDisplays(uint32_t *ids, uint32_t max) {
    uint32_t count = 0;
    CGGetActiveDisplayList(max, ids, &count);
    return count;
}

// Displays online que no estan activos ni son virtuales nuestros = fisicos
// apagados (espejados) que el cliente debe poder volver a prender.
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
        // Si este fisico esta espejado por el main dinamico, "prenderlo" es
        // apagar el main dinamico (vuelve a ser principal, el virtual se oculta).
        {
            bool isDynMainPhysical = false;
            {
                std::lock_guard<std::mutex> lock(g_rdVDisplayMutex);
                isDynMainPhysical = g_rdDynMainActive && displayID == g_rdDynMainPhysical;
            }
            if (isDynMainPhysical) {
                NSLog(@"remotedisplay vdisplay: prender fisico %u = apagar main dinamico", displayID);
                return MacDynamicMainOff();
            }
        }
        if (rdIsInActiveList(displayID) &&
            CGDisplayMirrorsDisplay(displayID) == kCGNullDirectDisplay) {
            return true; // ya prendido
        }
        bool ok = rdUnmirrorAndSettle(displayID, 5000);
        NSLog(@"remotedisplay vdisplay: fisico %u prendido (%d)", displayID, ok);
        return ok;
    }
    // Apagar: necesita OTRO display activo que quede como principal.
    uint32_t active[16];
    uint32_t nActive = 0;
    CGGetActiveDisplayList(16, active, &nActive);
    if (!rdIsInActiveList(displayID)) return true; // ya apagado
    if (nActive < 2) {
        NSLog(@"remotedisplay vdisplay: no se apaga el fisico %u — es el unico display activo", displayID);
        return false;
    }
    // Si es el principal, promover otro primero (el baile de SimpleDisplay).
    if (CGMainDisplayID() == displayID) {
        uint32_t other = 0;
        for (uint32_t i = 0; i < nActive; i++) {
            if (active[i] != displayID) { other = active[i]; break; }
        }
        if (!rdSetMainDisplay(other)) {
            NSLog(@"remotedisplay vdisplay: no se pudo transferir el principal a %u", other);
            return false;
        }
        for (int i = 0; i < 30; i++) {
            if (CGMainDisplayID() == other) break;
            usleep(100 * 1000);
        }
    }
    bool ok = rdSetMirror(displayID, CGMainDisplayID());
    if (ok) {
        rdWaitActiveState(displayID, false, 3000);
    }
    NSLog(@"remotedisplay vdisplay: fisico %u apagado -> espeja al %u (%d)", displayID, CGMainDisplayID(), ok);
    return ok;
}
