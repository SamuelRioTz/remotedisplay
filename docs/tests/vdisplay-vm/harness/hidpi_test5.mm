// "always via 1x" rule: create(hidpi) = 1x -> Retina; resize(hidpi) = new 1x -> Retina.
#import <Foundation/Foundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <unistd.h>
extern "C" uint32_t MacCreateVirtualDisplay(uint32_t, uint32_t, double, bool, const char *);
extern "C" bool MacDestroyVirtualDisplay(uint32_t);
extern "C" bool MacResizeVirtualDisplay(uint32_t, uint32_t, uint32_t);
extern "C" bool MacSetVirtualDisplayHiDPI(uint32_t, bool);
static void info(const char *tag, uint32_t id) {
    CGRect b = CGDisplayBounds(id); CGDisplayModeRef m = CGDisplayCopyDisplayMode(id);
    printf("%-30s id=%u pts=%dx%d mode(px)=%zux%zu %s\n", tag, id, (int)b.size.width, (int)b.size.height,
        m?CGDisplayModeGetPixelWidth(m):0, m?CGDisplayModeGetPixelHeight(m):0,
        (m && CGDisplayModeGetPixelWidth(m) > CGDisplayModeGetWidth(m)) ? "RETINA" : (m ? "1x" : "mode=NULL"));
    if (m) CGDisplayModeRelease(m);
}
static void active(const char *tag) { uint32_t n=0; CGDirectDisplayID ids[16]; CGGetActiveDisplayList(16, ids, &n); printf("%-30s active=%u:", tag, n); for (uint32_t i=0;i<n;i++) printf(" %u", ids[i]); printf("\n"); }
int main() { @autoreleasepool {
    active("start");
    uint32_t a = MacCreateVirtualDisplay(642, 351, 60, true, "RD retina"); sleep(2); info("created hidpi 642x351", a);
    MacResizeVirtualDisplay(a, 800, 450); sleep(2); info("resize 800x450 (hidpi)", a);
    MacResizeVirtualDisplay(a, 642, 351); sleep(2); info("resize 642x351 (hidpi)", a);
    MacSetVirtualDisplayHiDPI(a, false); sleep(2); info("toggle -> 1x", a);
    MacResizeVirtualDisplay(a, 1284, 701); sleep(2); info("resize 1284x701 (1x)", a);
    MacSetVirtualDisplayHiDPI(a, true); sleep(2); info("toggle -> retina 1284x701", a);
    MacDestroyVirtualDisplay(a); sleep(8); active("after destroying +8s");
    return 0;
} }
