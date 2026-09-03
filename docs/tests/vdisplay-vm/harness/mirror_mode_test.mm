// mirror_mode_test — does the mirrored physical keep its mode when the virtual
// it mirrors gets resized? (Mac Studio 2026-09-02: J560T09 dropped to 800x500 and the
// panel froze.) Links against the engine's real macos.mm.
//
// Actually reconfigures the displays: the desktop moves to the virtual during the
// test and returns to the physical at the end. Run it with the Mac free, with no other
// of our virtuals already created.
//
// usage: mirror_mode_test [virtualWidth virtualHeight]   (default 3440 1440)
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#include <CoreGraphics/CoreGraphics.h>
#include <unistd.h>

extern "C" uint32_t MacCreateVirtualDisplay(uint32_t, uint32_t, double, bool, const char *);
extern "C" bool MacDestroyVirtualDisplay(uint32_t);
extern "C" bool MacResizeVirtualDisplay(uint32_t, uint32_t, uint32_t);
extern "C" bool MacSetPhysicalDisplayEnabled(uint32_t, bool);
extern "C" bool MacIsOurVirtualDisplay(uint32_t);
extern "C" uint64_t MacDisplayTopologyHash();

static int g_fail = 0;

static void pump(double s) {
    NSEvent *e;
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:s];
    while ([end timeIntervalSinceNow] > 0 &&
           (e = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:end inMode:NSDefaultRunLoopMode dequeue:YES])) {
        [NSApp sendEvent:e];
    }
}

static void pixelsOf(CGDirectDisplayID d, size_t *w, size_t *h) {
    CGDisplayModeRef m = CGDisplayCopyDisplayMode(d);
    *w = m ? CGDisplayModeGetPixelWidth(m) : 0;
    *h = m ? CGDisplayModeGetPixelHeight(m) : 0;
    if (m) CGDisplayModeRelease(m);
}

static void truth(const char *tag) {
    printf("--- %s (hash %016llx)\n", tag, (unsigned long long)MacDisplayTopologyHash());
    CGDirectDisplayID ids[16]; uint32_t n = 0;
    CGGetOnlineDisplayList(16, ids, &n);
    for (uint32_t i = 0; i < n; i++) {
        CGDirectDisplayID d = ids[i];
        CGRect b = CGDisplayBounds(d);
        size_t pw, ph; pixelsOf(d, &pw, &ph);
        printf("    id=%u %s main=%d active=%d mirrorsOf=%u bounds=%.0fx%.0f pt pixels=%zux%zu\n",
               d, MacIsOurVirtualDisplay(d) ? "virtual" : "physical", CGDisplayIsMain(d), CGDisplayIsActive(d),
               CGDisplayMirrorsDisplay(d), b.size.width, b.size.height, pw, ph);
    }
    fflush(stdout);
}

static void check(const char *what, CGDirectDisplayID phys, size_t wantW, size_t wantH) {
    size_t pw, ph; pixelsOf(phys, &pw, &ph);
    bool ok = pw == wantW && ph == wantH;
    if (!ok) g_fail++;
    printf("%s: physical %u at %zux%zu px (expected %zux%zu) -> %s\n", what, phys, pw, ph, wantW, wantH, ok ? "PASS" : "FAIL");
    fflush(stdout);
}

int main(int argc, char **argv) { @autoreleasepool {
    uint32_t W = argc > 2 ? (uint32_t)atoi(argv[1]) : 3440;
    uint32_t H = argc > 2 ? (uint32_t)atoi(argv[2]) : 1440;
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    [NSApp finishLaunching];

    CGDirectDisplayID phys = CGMainDisplayID();
    if (MacIsOurVirtualDisplay(phys)) { printf("the main display is already one of our virtuals: aborting\n"); return 2; }
    size_t pw0, ph0; pixelsOf(phys, &pw0, &ph0);
    truth("start");

    uint32_t v = MacCreateVirtualDisplay(W, H, 60, false, "RD mirror test");
    if (!v) { printf("could not create the virtual\n"); return 2; }
    pump(2); truth("virtual created");

    if (!MacSetPhysicalDisplayEnabled(phys, false)) { printf("could not turn off (mirror) the physical\n"); MacDestroyVirtualDisplay(v); return 2; }
    pump(3); truth("physical turned off (mirrors the virtual)");
    check("after mirroring", phys, pw0, ph0);

    MacResizeVirtualDisplay(v, W, H - 71); pump(3); truth("resize virtual -71");
    check("after resize 1", phys, pw0, ph0);

    MacResizeVirtualDisplay(v, W, H); pump(3); truth("resize virtual back");
    check("after resize 2", phys, pw0, ph0);

    MacSetPhysicalDisplayEnabled(phys, true); pump(3); truth("physical turned on");
    check("after turning on", phys, pw0, ph0);
    if (CGMainDisplayID() != phys || !CGDisplayIsActive(phys)) { g_fail++; printf("the physical did not return to main/active -> FAIL\n"); }

    MacDestroyVirtualDisplay(v); pump(2); truth("end");
    printf("%s (%d failures)\n", g_fail ? "RESULT: FAIL" : "RESULT: PASS", g_fail);
    return g_fail ? 1 : 0;
} }
