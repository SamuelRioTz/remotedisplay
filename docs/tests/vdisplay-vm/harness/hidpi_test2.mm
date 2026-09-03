// Does the CGVirtualDisplay created with hiDPI=1 expose a Retina mode (px=2x pts)?
// Does MacSetMode select it? Does it survive a resize? Does it leave a ghost on destroy?
#import <Foundation/Foundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <unistd.h>
extern "C" uint32_t MacCreateVirtualDisplay(uint32_t, uint32_t, double, bool, const char *);
extern "C" bool MacDestroyVirtualDisplay(uint32_t);
extern "C" bool MacResizeVirtualDisplay(uint32_t, uint32_t, uint32_t);
extern "C" bool MacSetVirtualDisplayHiDPI(uint32_t, bool);
static void info(const char *tag, uint32_t id) {
    CGRect b = CGDisplayBounds(id); CGDisplayModeRef m = CGDisplayCopyDisplayMode(id);
    printf("%-30s id=%u pts=%dx%d mode(px)=%zux%zu %s\n", tag, id, (int)b.size.width, (int)b.size.height, m?CGDisplayModeGetPixelWidth(m):0, m?CGDisplayModeGetPixelHeight(m):0, (m && CGDisplayModeGetPixelWidth(m) > CGDisplayModeGetWidth(m)) ? "RETINA" : "1x");
    if (m) CGDisplayModeRelease(m);
}
static void modes(uint32_t id) {
    CFDictionaryRef o = (__bridge CFDictionaryRef)@{ (__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES };
    CFArrayRef all = CGDisplayCopyAllDisplayModes(id, o);
    printf("  modes (%ld):", all ? CFArrayGetCount(all) : 0);
    for (CFIndex i = 0; all && i < CFArrayGetCount(all); i++) { CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(all, i);
        printf(" %zux%zu/%zux%zupx", CGDisplayModeGetWidth(m), CGDisplayModeGetHeight(m), CGDisplayModeGetPixelWidth(m), CGDisplayModeGetPixelHeight(m)); }
    printf("\n"); if (all) CFRelease(all);
}
static void active(const char *tag) { uint32_t n=0; CGDirectDisplayID ids[16]; CGGetActiveDisplayList(16, ids, &n); printf("%-30s active=%u:", tag, n); for (uint32_t i=0;i<n;i++) printf(" %u", ids[i]); printf("\n"); }
int main() { @autoreleasepool {
    active("start");
    uint32_t a = MacCreateVirtualDisplay(640, 360, 60, true, "RD hidpi");
    sleep(3); info("created hidpi=1 640x360", a); modes(a);
    MacResizeVirtualDisplay(a, 800, 450); sleep(3); info("resize 800x450", a);
    MacResizeVirtualDisplay(a, 1284, 702); sleep(3); info("resize 1284x702", a);
    MacDestroyVirtualDisplay(a); sleep(4); active("after destroying A");
    uint32_t b = MacCreateVirtualDisplay(1284, 701, 60, false, "RD 1x");
    sleep(3); info("created hidpi=0 1284x701", b);
    MacSetVirtualDisplayHiDPI(b, true); sleep(4); info("toggle hidpi=1 (hot)", b);
    MacResizeVirtualDisplay(b, 642, 351); sleep(3); info("resize 642x351 hidpi", b);
    MacSetVirtualDisplayHiDPI(b, false); sleep(4); info("toggle hidpi=0", b);
    MacResizeVirtualDisplay(b, 1284, 701); sleep(3); info("resize 1284x701 1x", b);
    MacDestroyVirtualDisplay(b); sleep(4); active("after destroying B (ghost?)");
    return 0;
} }
