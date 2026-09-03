// Does the SAME process see the new displays after turning on the dynamic main (mirror)?
// Reproduces the server's sequence: dyn-main ON -> create 2 virtuals -> enumerate.
#import <Foundation/Foundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <unistd.h>
extern "C" uint32_t MacCreateVirtualDisplay(uint32_t, uint32_t, double, bool, const char *);
extern "C" bool MacDestroyVirtualDisplay(uint32_t);
extern "C" bool MacDynamicMainOn(uint32_t, uint32_t, bool);
extern "C" bool MacDynamicMainOff();
static void enumerate(const char *tag) {
    uint32_t n=0; CGDirectDisplayID ids[16]; CGGetOnlineDisplayList(16, ids, &n);
    printf("%-28s online=%u:", tag, n);
    for (uint32_t i=0;i<n;i++) printf(" %u(act=%d,mir=%u)", ids[i], CGDisplayIsActive(ids[i]), CGDisplayMirrorsDisplay(ids[i]));
    uint32_t na=0; CGDirectDisplayID act[16]; CGGetActiveDisplayList(16, act, &na); printf(" | active=%u\n", na);
}
int main() { @autoreleasepool {
    enumerate("start");
    MacDynamicMainOn(1284, 702, false); sleep(3); enumerate("dyn-main ON");
    uint32_t a = MacCreateVirtualDisplay(1920, 1080, 60, false, "RD A"); sleep(2); enumerate("after creating A");
    uint32_t b = MacCreateVirtualDisplay(1920, 1080, 60, false, "RD B"); sleep(2); enumerate("after creating B");
    // does a brief run loop refresh the cache?
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.5, false); enumerate("after CFRunLoopRunInMode");
    system("/tmp/dispinfo2 | head -6 | sed 's/^/    (new process) /'");
    MacDestroyVirtualDisplay(a); MacDestroyVirtualDisplay(b); MacDynamicMainOff(); sleep(3); enumerate("end");
    return 0;
} }
