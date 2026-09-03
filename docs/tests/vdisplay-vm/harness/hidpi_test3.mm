// EXPLICIT selection of the Retina mode (pts WxH, px 2Wx2H) after applySettings,
// using CGConfigureDisplayWithDisplayMode + kCGConfigureForAppOnly. Does it persist through
// a resize? Does it leave a ghost on destroy?
#import <Foundation/Foundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <unistd.h>
extern "C" uint32_t MacCreateVirtualDisplay(uint32_t, uint32_t, double, bool, const char *);
extern "C" bool MacDestroyVirtualDisplay(uint32_t);
extern "C" bool MacResizeVirtualDisplay(uint32_t, uint32_t, uint32_t);
static void info(const char *tag, uint32_t id) {
    CGRect b = CGDisplayBounds(id); CGDisplayModeRef m = CGDisplayCopyDisplayMode(id);
    printf("%-34s id=%u pts=%dx%d mode(px)=%zux%zu %s\n", tag, id, (int)b.size.width, (int)b.size.height,
        m?CGDisplayModeGetPixelWidth(m):0, m?CGDisplayModeGetPixelHeight(m):0,
        (m && CGDisplayModeGetPixelWidth(m) > CGDisplayModeGetWidth(m)) ? "RETINA" : "1x");
    if (m) CGDisplayModeRelease(m);
}
static bool selectRetina(uint32_t id, uint32_t w, uint32_t h, CGConfigureOption opt) {
    CFDictionaryRef o = (__bridge CFDictionaryRef)@{ (__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES };
    CFArrayRef all = CGDisplayCopyAllDisplayModes(id, o); if (!all) return false;
    CGDisplayModeRef want = NULL;
    for (CFIndex i = 0; i < CFArrayGetCount(all); i++) { CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(all, i);
        if (CGDisplayModeGetWidth(m) == w && CGDisplayModeGetHeight(m) == h && CGDisplayModeGetPixelWidth(m) == 2*w) { want = m; break; } }
    bool ok = false;
    if (want) { CGDisplayConfigRef c; if (CGBeginDisplayConfiguration(&c) == kCGErrorSuccess) {
        CGConfigureDisplayWithDisplayMode(c, id, want, NULL);
        ok = CGCompleteDisplayConfiguration(c, opt) == kCGErrorSuccess; if (!ok) CGCancelDisplayConfiguration(c); } }
    else printf("  (no retina variant %ux%u)\n", w, h);
    CFRelease(all); return ok;
}
static void active(const char *tag) { uint32_t n=0; CGDirectDisplayID ids[16]; CGGetActiveDisplayList(16, ids, &n); printf("%-34s active=%u:", tag, n); for (uint32_t i=0;i<n;i++) printf(" %u", ids[i]); printf("\n"); }
int main() { @autoreleasepool {
    active("start");
    uint32_t a = MacCreateVirtualDisplay(642, 351, 60, true, "RD retina");
    sleep(3); info("created hidpi=1 642x351", a);
    printf("selectRetina(642x351, AppOnly) -> %d\n", selectRetina(a, 642, 351, kCGConfigureForAppOnly)); sleep(3); info("after selecting retina", a);
    MacResizeVirtualDisplay(a, 800, 450); sleep(3); info("resize 800x450 (applySettings)", a);
    printf("selectRetina(800x450, AppOnly) -> %d\n", selectRetina(a, 800, 450, kCGConfigureForAppOnly)); sleep(3); info("after selecting retina 2", a);
    MacDestroyVirtualDisplay(a); sleep(10); active("after destroying A +10s (ghost?)");
    return 0;
} }
