// Verifica prender/apagar monitores fisicos (espejo) + guardas.
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
    // guarda: no se puede apagar el unico display activo
    check(!MacSetPhysicalDisplayEnabled(phys, false), "apagar el UNICO display -> rechazado");
    // crear virtual como companiero
    uint32_t v = MacCreateVirtualDisplay(1600, 1000, 60, false, "phys-test");
    sleep(1);
    check(v != 0 && inActive(v), "virtual creado y activo");
    // apagar el fisico (es main -> promueve el virtual y espeja)
    check(MacSetPhysicalDisplayEnabled(phys, false), "apagar fisico (con virtual presente)");
    check(waitActive(phys, false, 5000), "fisico fuera de la lista activa");
    check(CGDisplayMirrorsDisplay(phys) != kCGNullDirectDisplay, "fisico espejando");
    check(CGMainDisplayID() == v, "el virtual quedo de principal");
    uint32_t off[8]; uint32_t nOff = MacListInactivePhysicalDisplays(off, 8);
    check(nOff == 1 && off[0] == phys, "fisico listado como apagado");
    // prender de vuelta
    check(MacSetPhysicalDisplayEnabled(phys, true), "prender fisico");
    check(waitActive(phys, true, 5000), "fisico activo de nuevo");
    check(MacListInactivePhysicalDisplays(off, 8) == 0, "sin fisicos apagados");
    // repetir el ciclo (robustez)
    check(MacSetPhysicalDisplayEnabled(phys, false), "2do ciclo: apagar");
    check(waitActive(phys, false, 5000), "2do ciclo: fuera de activos");
    check(MacSetPhysicalDisplayEnabled(phys, true), "2do ciclo: prender");
    check(waitActive(phys, true, 5000), "2do ciclo: activo");
    MacDestroyVirtualDisplay(v);
    printf("=== %s (%d fallos) ===\n", fails == 0 ? "TODO OK" : "HUBO FALLOS", fails);
    return fails ? 1 : 0;
} }
