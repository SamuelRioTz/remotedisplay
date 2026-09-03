// What refreshes the process's display cache after the mirror transaction?
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#include <CoreGraphics/CoreGraphics.h>
#include <unistd.h>
extern "C" uint32_t MacCreateVirtualDisplay(uint32_t, uint32_t, double, bool, const char *);
extern "C" bool MacDestroyVirtualDisplay(uint32_t);
extern "C" bool MacDynamicMainOn(uint32_t, uint32_t, bool);
extern "C" bool MacDynamicMainOff();
static int cbCount = 0;
static void reconfCb(CGDirectDisplayID d, CGDisplayChangeSummaryFlags f, void *u) { cbCount++; }
static void enumerate(const char *tag) {
    uint32_t n=0; CGDirectDisplayID ids[16]; CGGetOnlineDisplayList(16, ids, &n);
    uint32_t na=0; CGDirectDisplayID act[16]; CGGetActiveDisplayList(16, act, &na);
    printf("%-40s online=%u active=%u nsscreens=%lu cb=%d\n", tag, n, na, (unsigned long)[NSScreen screens].count, cbCount);
}
int main() { @autoreleasepool {
    CGDisplayRegisterReconfigurationCallback(reconfCb, NULL);
    enumerate("start");
    MacDynamicMainOn(1284, 702, false); sleep(3); enumerate("dyn-main ON");
    uint32_t a = MacCreateVirtualDisplay(1920, 1080, 60, false, "RD A"); sleep(2); enumerate("after creating A (expected online=3)");
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.0, false); enumerate("  + CFRunLoop 1s");
    { CGDisplayConfigRef c; if (CGBeginDisplayConfiguration(&c) == kCGErrorSuccess) CGCancelDisplayConfiguration(c); } enumerate("  + Begin/Cancel config");
    { CGDirectDisplayID r[16]; uint32_t m=0; CGGetDisplaysWithRect(CGRectMake(-100000,-100000,200000,200000), 16, r, &m); printf("  CGGetDisplaysWithRect -> %u\n", m); }
    { CGDirectDisplayID r[16]; uint32_t m=0; CGGetDisplaysWithPoint(CGPointMake(2000, 100), 16, r, &m); printf("  CGGetDisplaysWithPoint(2000,100) -> %u\n", m); }
    [[NSApplication sharedApplication] finishLaunching]; NSEvent *e; while ((e = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate dateWithTimeIntervalSinceNow:0.5] inMode:NSDefaultRunLoopMode dequeue:YES])) [NSApp sendEvent:e];
    enumerate("  + NSApp event loop 0.5s");
    MacDestroyVirtualDisplay(a); MacDynamicMainOff(); sleep(3); enumerate("end");
    return 0;
} }
