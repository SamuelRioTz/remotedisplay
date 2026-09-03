// Verifies turning physical monitors on/off (mirror) + guards.
#import <Foundation/Foundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <unistd.h>
extern "C" uint32_t MacCreateVirtualDisplay(uint32_t, uint32_t, double, bool, const char *);
extern "C" bool MacDestroyVirtualDisplay(uint32_t);
extern "C" bool MacSetPhysicalDisplayEnabled(uint32_t, bool);
extern "C" uint32_t MacListInactivePhysicalDisplays(uint32_t *, uint32_t);
extern "C" uint32_t MacListActiveDisplays(uint32_t *, uint32_t);
static int fails = 0;
static void check(bool c, const char *w) { printf("%s %s\n", c ? "PASS" : "FAIL", w); if (!c) fails++; }
static bool inActive(uint32_t id) {
    uint32_t ids[16]; uint32_t n = MacListActiveDisplays(ids, 16);
    for (uint32_t i = 0; i < n; i++) if (ids[i] == id) return true;
    return false;
}
static bool waitActive(uint32_t id, bool want, int ms) {
    for (int i = 0; i < ms / 100; i++) { if (inActive(id) == want) return true; usleep(100 * 1000); }
    return false;
}
int main() { @autoreleasepool {
    uint32_t phys = CGMainDisplayID();
    // guard: the only active display cannot be turned off
    check(!MacSetPhysicalDisplayEnabled(phys, false), "turn off the ONLY display -> rejected");
    // create a virtual as a companion
    uint32_t v = MacCreateVirtualDisplay(1600, 1000, 60, false, "phys-test");
    sleep(1);
    check(v != 0 && inActive(v), "virtual created and active");
    // turn off the physical (it's main -> promotes the virtual and mirrors)
    check(MacSetPhysicalDisplayEnabled(phys, false), "turn off physical (with a virtual present)");
    check(waitActive(phys, false, 5000), "physical out of the active list");
    check(CGDisplayMirrorsDisplay(phys) != kCGNullDirectDisplay, "physical mirroring");
    check(CGMainDisplayID() == v, "the virtual became main");
    uint32_t off[8]; uint32_t nOff = MacListInactivePhysicalDisplays(off, 8);
    check(nOff == 1 && off[0] == phys, "physical listed as off");
    // turn back on
    check(MacSetPhysicalDisplayEnabled(phys, true), "turn on physical");
    check(waitActive(phys, true, 5000), "physical active again");
    check(MacListInactivePhysicalDisplays(off, 8) == 0, "no physicals off");
    // repeat the cycle (robustness)
    check(MacSetPhysicalDisplayEnabled(phys, false), "2nd cycle: turn off");
    check(waitActive(phys, false, 5000), "2nd cycle: out of active");
    check(MacSetPhysicalDisplayEnabled(phys, true), "2nd cycle: turn on");
    check(waitActive(phys, true, 5000), "2nd cycle: active");
    MacDestroyVirtualDisplay(v);
    printf("=== %s (%d failures) ===\n", fails == 0 ? "ALL OK" : "THERE WERE FAILURES", fails);
    return fails ? 1 : 0;
} }
