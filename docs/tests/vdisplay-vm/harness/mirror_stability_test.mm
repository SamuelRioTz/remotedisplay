// Does creating a virtual (and resizing it) while the dynamic main is active break
// the physical's mirror? Measured with a NEW process (/tmp/dispinfo2) = ground truth.
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#include <CoreGraphics/CoreGraphics.h>
#include <unistd.h>
extern "C" uint32_t MacCreateVirtualDisplay(uint32_t, uint32_t, double, bool, const char *);
extern "C" bool MacDestroyVirtualDisplay(uint32_t);
extern "C" bool MacResizeVirtualDisplay(uint32_t, uint32_t, uint32_t);
extern "C" bool MacDynamicMainOn(uint32_t, uint32_t, bool);
extern "C" bool MacDynamicMainOff();
static void pump(double s) { NSEvent *e; NSDate *end=[NSDate dateWithTimeIntervalSinceNow:s]; while ([end timeIntervalSinceNow] > 0 && (e=[NSApp nextEventMatchingMask:NSEventMaskAny untilDate:end inMode:NSDefaultRunLoopMode dequeue:YES])) [NSApp sendEvent:e]; }
static void truth(const char *tag) { printf("--- %s\n", tag); fflush(stdout); system("/tmp/dispinfo2 | sed 's/^/    /'"); }
int main() { @autoreleasepool {
    [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited]; [NSApp finishLaunching];
    MacDynamicMainOn(1284, 702, false); pump(3); truth("dyn-main ON");
    uint32_t b = MacCreateVirtualDisplay(1920, 1080, 60, false, "RD B"); pump(2); truth("after creating B (+2s)");
    MacResizeVirtualDisplay(b, 1284, 702); pump(2); truth("after resizing B (+2s)");
    pump(5); truth("+5s more");
    MacDestroyVirtualDisplay(b); MacDynamicMainOff(); pump(3); truth("end");
    return 0;
} }
