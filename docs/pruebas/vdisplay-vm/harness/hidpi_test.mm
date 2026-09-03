// Semantica de hiDPI en CGVirtualDisplay (macOS 26): ¿hiDPI=1 al crear da
// backing 2x (puntos = modo, pixeles = 2x)? ¿Y al conmutarlo en caliente?
#import <Foundation/Foundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <unistd.h>
extern "C" uint32_t MacCreateVirtualDisplay(uint32_t, uint32_t, double, bool, const char *);
extern "C" bool MacDestroyVirtualDisplay(uint32_t);
extern "C" bool MacSetVirtualDisplayHiDPI(uint32_t, bool);
extern "C" bool MacResizeVirtualDisplay(uint32_t, uint32_t, uint32_t);
static void info(const char *tag, uint32_t id) {
    CGRect b = CGDisplayBounds(id); CGDisplayModeRef m = CGDisplayCopyDisplayMode(id);
    printf("%-28s id=%u pts=%dx%d px=%zux%zu mode(pts)=%zux%zu mode(px)=%zux%zu\n", tag, id,
        (int)b.size.width, (int)b.size.height, CGDisplayPixelsWide(id), CGDisplayPixelsHigh(id),
        m ? CGDisplayModeGetWidth(m) : 0, m ? CGDisplayModeGetHeight(m) : 0,
        m ? CGDisplayModeGetPixelWidth(m) : 0, m ? CGDisplayModeGetPixelHeight(m) : 0);
    if (m) CGDisplayModeRelease(m);
}
int main() { @autoreleasepool {
    uint32_t a = MacCreateVirtualDisplay(640, 360, 60, true, "RD hidpi-at-create");
    sleep(3); info("creado hidpi=1 640x360", a);
    MacResizeVirtualDisplay(a, 800, 450); sleep(3); info("resize hidpi 800x450", a);
    MacDestroyVirtualDisplay(a); sleep(2);
    uint32_t b = MacCreateVirtualDisplay(640, 360, 60, false, "RD hidpi-later");
    sleep(3); info("creado hidpi=0 640x360", b);
    MacSetVirtualDisplayHiDPI(b, true); sleep(4); info("toggle hidpi=1 (caliente)", b);
    MacResizeVirtualDisplay(b, 800, 450); sleep(3); info("resize tras toggle 800x450", b);
    MacDestroyVirtualDisplay(b); sleep(1);
    return 0;
} }
