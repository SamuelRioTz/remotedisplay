// Verification harness for remotedisplay's virtual display primitives.
// Linked alongside src/platform/macos.mm and exercises: create, hot resize
// (stable ID), dynamic main (mirror), and cleanup.
#import <Foundation/Foundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <unistd.h>

extern "C" bool MacVirtualDisplaySupported();
extern "C" uint32_t MacCreateVirtualDisplay(uint32_t, uint32_t, double, bool, const char *);
extern "C" bool MacResizeVirtualDisplay(uint32_t, uint32_t, uint32_t);
extern "C" bool MacDestroyVirtualDisplay(uint32_t);
extern "C" void MacDestroyAllVirtualDisplays();
extern "C" bool MacDynamicMainOn(uint32_t, uint32_t, bool);
extern "C" bool MacDynamicMainOff();
extern "C" bool MacDynamicMainActive();
extern "C" uint32_t MacDynamicMainVirtualID();

static int g_failures = 0;

static void check(bool cond, const char *what) {
    printf("%s %s\n", cond ? "PASS" : "FAIL", what);
    if (!cond) g_failures++;
}

static void dumpDisplays(const char *label) {
    uint32_t count = 0;
    CGDirectDisplayID ids[16];
    CGGetActiveDisplayList(16, ids, &count);
    printf("-- %s: %u active display(s):", label, count);
    for (uint32_t i = 0; i < count; i++) {
        CGRect b = CGDisplayBounds(ids[i]);
        printf(" [%u: %dx%d%s%s]", ids[i], (int)b.size.width, (int)b.size.height,
               CGMainDisplayID() == ids[i] ? " MAIN" : "",
               CGDisplayMirrorsDisplay(ids[i]) != kCGNullDirectDisplay ? " MIRROR" : "");
    }
    printf("\n");
}

static bool waitForSize(CGDirectDisplayID id, int w, int h, int timeoutMs) {
    for (int i = 0; i < timeoutMs / 100; i++) {
        CGRect b = CGDisplayBounds(id);
        if ((int)b.size.width == w && (int)b.size.height == h) return true;
        usleep(100 * 1000);
    }
    return false;
}

// Actual presence in the active displays list (CGDisplayIsActive lies
// about stale IDs of destroyed displays).
static bool isInActiveList(CGDirectDisplayID id) {
    uint32_t count = 0;
    CGDirectDisplayID ids[16];
    CGGetActiveDisplayList(16, ids, &count);
    for (uint32_t i = 0; i < count; i++) if (ids[i] == id) return true;
    return false;
}

static bool waitGoneFromActiveList(CGDirectDisplayID id, int timeoutMs) {
    for (int i = 0; i < timeoutMs / 100; i++) {
        if (!isInActiveList(id)) return true;
        usleep(100 * 1000);
    }
    return false;
}

int main() {
    @autoreleasepool {
        printf("=== remotedisplay vdisplay harness ===\n");
        CGDirectDisplayID physical = CGMainDisplayID();
        dumpDisplays("initial state");

        // 1. support
        check(MacVirtualDisplaySupported(), "CGVirtualDisplay available (private API present)");
        if (!MacVirtualDisplaySupported()) return 1;

        // 2. create
        uint32_t vid = MacCreateVirtualDisplay(1600, 1000, 60, false, "RD Test Display");
        check(vid != 0, "create virtual display 1600x1000");
        if (vid == 0) return 1;
        sleep(1);
        dumpDisplays("after creating");
        check(CGDisplayIsActive(vid), "the virtual is active");
        CGRect b = CGDisplayBounds(vid);
        check((int)b.size.width == 1600 && (int)b.size.height == 1000, "initial size 1600x1000");

        // 3. hot resize, stable ID
        check(MacResizeVirtualDisplay(vid, 1280, 800), "resize to 1280x800 (applySettings)");
        check(waitForSize(vid, 1280, 800, 5000), "the mode changed to 1280x800 with the SAME displayID");
        check(MacResizeVirtualDisplay(vid, 2560, 1400), "resize to 2560x1400");
        check(waitForSize(vid, 2560, 1400, 5000), "the mode changed to 2560x1400");
        dumpDisplays("after resizes");

        // 4. destroy
        check(MacDestroyVirtualDisplay(vid), "destroy the virtual");
        check(waitGoneFromActiveList(vid, 5000), "the virtual disappeared from the active list");
        dumpDisplays("after destroying");

        // 5. dynamic main (case 1): main virtual + mirrored physical
        check(MacDynamicMainOn(1440, 900, false), "dynamic main ON (1440x900)");
        sleep(2);
        uint32_t dynVid = MacDynamicMainVirtualID();
        check(dynVid != 0, "there is a dynamic-main virtual");
        dumpDisplays("dynamic main ON");
        check(CGMainDisplayID() == dynVid, "the virtual is the main display");
        check(CGDisplayMirrorsDisplay(physical) == dynVid, "the physical mirrors the virtual");
        check(waitForSize(dynVid, 1440, 900, 5000), "virtual at 1440x900");

        // 6. dynamic resize with the mirror active (the window-drag flow)
        check(MacDynamicMainOn(1680, 1050, false), "resize via dynamic-main to 1680x1050");
        check(waitForSize(dynVid, 1680, 1050, 5000), "the mode followed the resize (stable ID)");
        dumpDisplays("after dynamic resize");

        // 7. dynamic main OFF: unmirror + destroy; the physical comes back
        check(MacDynamicMainOff(), "dynamic main OFF");
        sleep(2);
        dumpDisplays("dynamic main OFF");
        check(CGDisplayMirrorsDisplay(physical) == kCGNullDirectDisplay, "the physical no longer mirrors");
        check(waitGoneFromActiveList(dynVid, 15000), "the virtual left the active list (disabled)");
        check(CGMainDisplayID() == physical, "the physical became main again");

        // 8. repeatability: second ON/resize/OFF cycle
        check(MacDynamicMainOn(1280, 720, false), "2nd cycle: dynamic main ON (1280x720)");
        sleep(2);
        uint32_t dynVid2 = MacDynamicMainVirtualID();
        check(dynVid2 == dynVid, "2nd cycle: recycles the SAME cached virtual");
        check(dynVid2 != 0 && CGMainDisplayID() == dynVid2, "2nd cycle: virtual is main");
        check(MacDynamicMainOn(1920, 1080, false), "2nd cycle: resize to 1920x1080");
        check(waitForSize(dynVid2, 1920, 1080, 8000), "2nd cycle: mode followed the resize");
        check(MacDynamicMainOff(), "2nd cycle: OFF");
        check(waitGoneFromActiveList(dynVid2, 15000), "2nd cycle: virtual hidden again");
        check(CGMainDisplayID() == physical, "2nd cycle: physical main again");
        dumpDisplays("end");

        MacDestroyAllVirtualDisplays();
        printf("=== %s (%d failures) ===\n", g_failures == 0 ? "ALL OK" : "THERE WERE FAILURES", g_failures);
        return g_failures == 0 ? 0 : 1;
    }
}
