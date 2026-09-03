// Harness de verificacion de las primitivas de display virtual de remotedisplay.
// Se linkea junto a src/platform/macos.mm y ejercita: crear, resize en caliente
// (ID estable), main dinamico (espejo), y limpieza.
#import <Foundation/Foundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <unistd.h>

extern "C" bool MacVirtualDisplaySupported();
extern "C" uint32_t MacCreateVirtualDisplay(uint32_t, uint32_t, double, bool, const char *);
extern "C" bool MacResizeVirtualDisplay(uint32_t, uint32_t, uint32_t);
extern "C" bool MacDestroyVirtualDisplay(uint32_t);
extern "C" void MacDestroyAllVirtualDisplays();
extern "C" bool MacDynamicMainOn(uint32_t, uint32_t, bool);
extern "C" bool MacDynamicMainOff();
extern "C" bool MacDynamicMainActive();
extern "C" uint32_t MacDynamicMainVirtualID();

static int g_failures = 0;

static void check(bool cond, const char *what) {
    printf("%s %s\n", cond ? "PASS" : "FAIL", what);
    if (!cond) g_failures++;
}

static void dumpDisplays(const char *label) {
    uint32_t count = 0;
    CGDirectDisplayID ids[16];
    CGGetActiveDisplayList(16, ids, &count);
    printf("-- %s: %u display(s) activos:", label, count);
    for (uint32_t i = 0; i < count; i++) {
        CGRect b = CGDisplayBounds(ids[i]);
        printf(" [%u: %dx%d%s%s]", ids[i], (int)b.size.width, (int)b.size.height,
               CGMainDisplayID() == ids[i] ? " MAIN" : "",
               CGDisplayMirrorsDisplay(ids[i]) != kCGNullDirectDisplay ? " MIRROR" : "");
    }
    printf("\n");
}

static bool waitForSize(CGDirectDisplayID id, int w, int h, int timeoutMs) {
    for (int i = 0; i < timeoutMs / 100; i++) {
        CGRect b = CGDisplayBounds(id);
        if ((int)b.size.width == w && (int)b.size.height == h) return true;
        usleep(100 * 1000);
    }
    return false;
}

// Presencia real en la lista de displays activos (CGDisplayIsActive miente
// sobre IDs stale de displays destruidos).
static bool isInActiveList(CGDirectDisplayID id) {
    uint32_t count = 0;
    CGDirectDisplayID ids[16];
    CGGetActiveDisplayList(16, ids, &count);
    for (uint32_t i = 0; i < count; i++) if (ids[i] == id) return true;
    return false;
}

static bool waitGoneFromActiveList(CGDirectDisplayID id, int timeoutMs) {
    for (int i = 0; i < timeoutMs / 100; i++) {
        if (!isInActiveList(id)) return true;
        usleep(100 * 1000);
    }
    return false;
}

int main() {
    @autoreleasepool {
        printf("=== remotedisplay vdisplay harness ===\n");
        CGDirectDisplayID physical = CGMainDisplayID();
        dumpDisplays("estado inicial");

        // 1. soporte
        check(MacVirtualDisplaySupported(), "CGVirtualDisplay disponible (API privada presente)");
        if (!MacVirtualDisplaySupported()) return 1;

        // 2. crear
        uint32_t vid = MacCreateVirtualDisplay(1600, 1000, 60, false, "RD Test Display");
        check(vid != 0, "crear display virtual 1600x1000");
        if (vid == 0) return 1;
        sleep(1);
        dumpDisplays("tras crear");
        check(CGDisplayIsActive(vid), "el virtual esta activo");
        CGRect b = CGDisplayBounds(vid);
        check((int)b.size.width == 1600 && (int)b.size.height == 1000, "tamano inicial 1600x1000");

        // 3. resize en caliente, ID estable
        check(MacResizeVirtualDisplay(vid, 1280, 800), "resize a 1280x800 (applySettings)");
        check(waitForSize(vid, 1280, 800, 5000), "el modo cambio a 1280x800 con el MISMO displayID");
        check(MacResizeVirtualDisplay(vid, 2560, 1400), "resize a 2560x1400");
        check(waitForSize(vid, 2560, 1400, 5000), "el modo cambio a 2560x1400");
        dumpDisplays("tras resizes");

        // 4. destruir
        check(MacDestroyVirtualDisplay(vid), "destruir el virtual");
        check(waitGoneFromActiveList(vid, 5000), "el virtual desaparecio de la lista activa");
        dumpDisplays("tras destruir");

        // 5. main dinamico (caso 1): virtual principal + fisico espejado
        check(MacDynamicMainOn(1440, 900, false), "main dinamico ON (1440x900)");
        sleep(2);
        uint32_t dynVid = MacDynamicMainVirtualID();
        check(dynVid != 0, "hay virtual del main dinamico");
        dumpDisplays("main dinamico ON");
        check(CGMainDisplayID() == dynVid, "el virtual es el display principal");
        check(CGDisplayMirrorsDisplay(physical) == dynVid, "el fisico espeja al virtual");
        check(waitForSize(dynVid, 1440, 900, 5000), "virtual en 1440x900");

        // 6. resize dinamico con espejo activo (el flujo del drag de ventana)
        check(MacDynamicMainOn(1680, 1050, false), "resize via dynamic-main a 1680x1050");
        check(waitForSize(dynVid, 1680, 1050, 5000), "el modo siguio al resize (ID estable)");
        dumpDisplays("tras resize dinamico");

        // 7. main dinamico OFF: desespejar + destruir; el fisico vuelve
        check(MacDynamicMainOff(), "main dinamico OFF");
        sleep(2);
        dumpDisplays("main dinamico OFF");
        check(CGDisplayMirrorsDisplay(physical) == kCGNullDirectDisplay, "el fisico ya no espeja");
        check(waitGoneFromActiveList(dynVid, 15000), "el virtual salio de la lista activa (deshabilitado)");
        check(CGMainDisplayID() == physical, "el fisico volvio a ser principal");

        // 8. repetibilidad: segundo ciclo ON/resize/OFF
        check(MacDynamicMainOn(1280, 720, false), "2do ciclo: main dinamico ON (1280x720)");
        sleep(2);
        uint32_t dynVid2 = MacDynamicMainVirtualID();
        check(dynVid2 == dynVid, "2do ciclo: recicla el MISMO virtual cacheado");
        check(dynVid2 != 0 && CGMainDisplayID() == dynVid2, "2do ciclo: virtual es principal");
        check(MacDynamicMainOn(1920, 1080, false), "2do ciclo: resize a 1920x1080");
        check(waitForSize(dynVid2, 1920, 1080, 8000), "2do ciclo: modo siguio al resize");
        check(MacDynamicMainOff(), "2do ciclo: OFF");
        check(waitGoneFromActiveList(dynVid2, 15000), "2do ciclo: virtual oculto de nuevo");
        check(CGMainDisplayID() == physical, "2do ciclo: fisico principal de nuevo");
        dumpDisplays("fin");

        MacDestroyAllVirtualDisplays();
        printf("=== %s (%d fallos) ===\n", g_failures == 0 ? "TODO OK" : "HUBO FALLOS", g_failures);
        return g_failures == 0 ? 0 : 1;
    }
}
