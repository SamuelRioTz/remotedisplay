import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart' show Size, debugPrint;
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart' show bind;

/// Escalas disponibles para un monitor virtual (como Windows: 100/125/150/200).
/// 200 % = modo HiDPI real de macOS (Retina). 125/150 se emulan como hace
/// Apple ("looks like"): HiDPI con puntos = pixeles/escala, framebuffer 2x puntos.
const kMonitorScales = [100, 125, 150, 200];

/// Redondea un devicePixelRatio a la escala "de Windows" más cercana.
int snapScale(double dpr) {
  final pct = (dpr * 100).round();
  var best = kMonitorScales.first;
  for (final s in kMonitorScales) {
    if ((s - pct).abs() < (best - pct).abs()) best = s;
  }
  return best;
}

/// Un monitor virtual en el perfil: tamaño en PIXELES equivalentes a 100 %
/// (= pixeles de la ventana del viewer) y su escala.
class VirtualSpec {
  final int w;
  final int h;
  final int scale;
  const VirtualSpec(this.w, this.h, this.scale);

  /// Puntos que se piden al server para este spec.
  int get pointsW => (w * 100 / scale).round();
  int get pointsH => (h * 100 / scale).round();
  bool get hidpi => scale > 100;

  Map<String, dynamic> toJson() => {'w': w, 'h': h, 'scale': scale};
  static VirtualSpec fromJson(Map m) => VirtualSpec((m['w'] as num).round(),
      (m['h'] as num).round(), (m['scale'] as num?)?.round() ?? 100);
}

/// Perfil de monitores de un peer macOS, guardado EN ESTE CLIENTE (por peer).
///
/// La idea: cada cliente (la PC, el iPad…) tiene su propia disposición de
/// monitores virtuales para la misma Mac. Al conectar, el cliente **aplica** su
/// perfil sobre el server (crea, borra, redimensiona y escala virtuales hasta
/// que coincidan); si otro cliente entra después, aplica el suyo y pisa al
/// anterior. El server mantiene los virtuales vivos entre conexiones, así que
/// reconectar desde el mismo cliente no toca nada.
///
/// Se guarda como opción de peer (`mac_monitor_profile`, JSON) y se toma una
/// foto del estado real del server (PeerInfo) un momento después de cada acción
/// de la toolbar.
class MonitorProfile {
  static const optionKey = 'mac_monitor_profile';

  /// Virtuales "normales" (no el del main dinámico), en orden.
  final List<VirtualSpec> virtuals;

  /// Main dinámico activo (físico espejado sobre un virtual principal).
  final bool dynamicMain;

  /// Spec del virtual principal dinámico (si `dynamicMain`).
  final VirtualSpec? dynamicMainSpec;

  const MonitorProfile({
    required this.virtuals,
    required this.dynamicMain,
    this.dynamicMainSpec,
  });

  Map<String, dynamic> toJson() => {
        'v': 2,
        'virtuals': [for (final s in virtuals) s.toJson()],
        'dynamicMain': dynamicMain,
        if (dynamicMainSpec != null) 'dynamicMainSpec': dynamicMainSpec!.toJson(),
      };

  static MonitorProfile fromJson(Map<String, dynamic> j) {
    // v1 guardaba tamaños de display sin escala: equivalen a 100 %.
    final dynLegacy = j['dynamicMainSize'];
    return MonitorProfile(
      virtuals: [
        for (final m in (j['virtuals'] as List? ?? [])) VirtualSpec.fromJson(m as Map)
      ],
      dynamicMain: j['dynamicMain'] == true,
      dynamicMainSpec: j['dynamicMainSpec'] is Map
          ? VirtualSpec.fromJson(j['dynamicMainSpec'] as Map)
          : (dynLegacy is Map ? VirtualSpec.fromJson(dynLegacy) : null),
    );
  }

  // ------------------------------------------------ escala por display (runtime)

  // La escala elegida no es derivable solo del server (125 y 150 son ambos
  // HiDPI): se recuerda acá por (peer, CGDirectDisplayID) y se persiste en el
  // perfil. Sin dato: HiDPI => 200, si no 100.
  static final Map<String, Map<int, int>> _scales = {};

  static int scaleOf(String peerId, PeerInfo pi, int mid) =>
      _scales[peerId]?[mid] ?? (pi.macHiDPIDisplays.contains(mid) ? 200 : 100);

  static void rememberScale(String peerId, int mid, int scale) =>
      (_scales[peerId] ??= {})[mid] = scale;

  /// Tamaño en pixeles equivalentes a 100 % del display `i` (puntos × escala).
  static Size pixelSizeOf(PeerInfo pi, int i, int scale) {
    final d = pi.displays[i];
    final sc = d.scale <= 0 ? 1.0 : d.scale; // pixeles / puntos
    final ptsW = d.width / sc;
    final ptsH = d.height / sc;
    return Size((ptsW * scale / 100).roundToDouble(),
        (ptsH * scale / 100).roundToDouble());
  }

  /// Foto del estado REAL del server según el PeerInfo (fuente de verdad).
  static MonitorProfile fromPeer(String peerId, PeerInfo pi) {
    final ids = pi.macDisplayIds;
    final virt = pi.macVirtualDisplays.toSet();
    final dynId = pi.macDynamicMainId;
    final list = <VirtualSpec>[];
    VirtualSpec? dynSpec;
    for (var i = 0; i < pi.displays.length && i < ids.length; i++) {
      final mid = ids[i];
      if (!virt.contains(mid)) continue;
      final scale = scaleOf(peerId, pi, mid);
      final px = pixelSizeOf(pi, i, scale);
      final spec = VirtualSpec(px.width.round(), px.height.round(), scale);
      if (pi.macDynamicMainActive && mid == dynId) {
        dynSpec = spec;
      } else {
        list.add(spec);
      }
    }
    return MonitorProfile(
        virtuals: list, dynamicMain: pi.macDynamicMainActive, dynamicMainSpec: dynSpec);
  }

  // ---------------------------------------------------------------- storage

  static MonitorProfile? load(String peerId) {
    final raw = bind.mainGetPeerOptionSync(id: peerId, key: optionKey);
    if (raw.isEmpty) return null;
    try {
      return fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (e) {
      debugPrint('[monitor profile] perfil ilegible para $peerId: $e');
      return null;
    }
  }

  void save(String peerId) {
    bind.mainSetPeerOption(id: peerId, key: optionKey, value: jsonEncode(toJson()));
    debugPrint('[monitor profile] guardado $peerId: ${jsonEncode(toJson())}');
  }

  static final Map<String, Timer> _pendingSaves = {};

  /// Guardar una foto del server un momento después de una acción (el server
  /// tarda ~1 s en asentar y anunciar la nueva lista de displays).
  static void scheduleSave(String peerId, FFI ffi,
      {Duration delay = const Duration(milliseconds: 2500)}) {
    _pendingSaves[peerId]?.cancel();
    _pendingSaves[peerId] = Timer(delay, () {
      _pendingSaves.remove(peerId);
      final pi = ffi.ffiModel.pi;
      if (!pi.isMacVirtualDisplaySupported) return;
      fromPeer(peerId, pi).save(peerId);
    });
  }

  // ------------------------------------------------------------ primitivas

  static Future<bool> waitFor(bool Function() cond, int ms) async {
    for (var t = 0; t < ms; t += 100) {
      if (cond()) return true;
      await Future.delayed(const Duration(milliseconds: 100));
    }
    return cond();
  }

  /// Pone el display virtual `mid` (fila `idx`) en la escala `scale` con el
  /// tamaño de pixeles `px`: HiDPI on/off según la escala y luego los puntos.
  static Future<void> applySpec(
      String peerId, FFI ffi, int mid, VirtualSpec spec) async {
    PeerInfo pi() => ffi.ffiModel.pi;
    final wantHiDPI = spec.hidpi;
    if (pi().macHiDPIDisplays.contains(mid) != wantHiDPI) {
      bind.sessionToggleVirtualDisplay(
          sessionId: ffi.sessionId, index: kMacHiDPIIndexBase + mid, on: wantHiDPI);
      // El flag cambia enseguida; el modo tarda en asentar (y en ventanas de
      // menos de ~1920 px el server se queda en 1x aunque el flag este on):
      // esperar el flag y dar un margen fijo antes del resize.
      await waitFor(() => pi().macHiDPIDisplays.contains(mid) == wantHiDPI, 6000);
      await Future.delayed(const Duration(milliseconds: 900));
    }
    rememberScale(peerId, mid, spec.scale);
    final idx = pi().macDisplayIds.indexOf(mid);
    if (idx < 0 || idx >= pi().displays.length) return;
    final d = pi().displays[idx];
    final sc = d.scale <= 0 ? 1.0 : d.scale;
    if ((d.width / sc).round() != spec.pointsW ||
        (d.height / sc).round() != spec.pointsH) {
      await ffi.ffiModel.changeResolutionOfDisplay(idx, spec.pointsW, spec.pointsH);
      await Future.delayed(const Duration(milliseconds: 600));
    }
  }

  // ------------------------------------------------------------------ apply

  static final Set<String> _applying = {};

  /// Reconciliar el server con el perfil guardado de este cliente. Idempotente:
  /// si ya coincide no manda nada. Sin perfil guardado (primera vez desde este
  /// cliente) no toca nada.
  static Future<void> applySaved(String peerId, FFI ffi) async {
    final profile = load(peerId);
    if (profile == null) return;
    if (_applying.contains(peerId)) return;
    _applying.add(peerId);
    try {
      await profile._apply(peerId, ffi);
    } catch (e) {
      debugPrint('[monitor profile] aplicar falló: $e');
    } finally {
      _applying.remove(peerId);
    }
  }

  Future<void> _apply(String peerId, FFI ffi) async {
    PeerInfo pi() => ffi.ffiModel.pi;
    debugPrint('[monitor profile] aplicando a $peerId: ${jsonEncode(toJson())}');

    // 1) main dinámico
    if (dynamicMain && !pi().macDynamicMainActive) {
      bind.sessionToggleVirtualDisplay(
          sessionId: ffi.sessionId, index: kMacDynamicMainIndex, on: true);
      await waitFor(() => pi().macDynamicMainActive, 8000);
      await Future.delayed(const Duration(milliseconds: 400));
    } else if (!dynamicMain && pi().macDynamicMainActive) {
      bind.sessionToggleVirtualDisplay(
          sessionId: ffi.sessionId, index: kMacDynamicMainIndex, on: false);
      await waitFor(() => !pi().macDynamicMainActive, 8000);
      await Future.delayed(const Duration(milliseconds: 400));
    }
    if (dynamicMain && dynamicMainSpec != null && pi().macDynamicMainActive) {
      await applySpec(peerId, ffi, pi().macDynamicMainId, dynamicMainSpec!);
    }

    // 2) virtuales normales (sin el del main dinámico), en orden
    List<int> current() {
      final p = pi();
      final virt = p.macVirtualDisplays.toSet();
      return p.macDisplayIds
          .where((m) =>
              virt.contains(m) && !(p.macDynamicMainActive && m == p.macDynamicMainId))
          .toList();
    }

    // sobran → borrar (los últimos primero)
    var cur = current();
    while (cur.length > virtuals.length) {
      final mid = cur.last;
      bind.sessionToggleVirtualDisplay(
          sessionId: ffi.sessionId, index: kMacRawDisplayIdBase + mid, on: false);
      await waitFor(() => !pi().macVirtualDisplays.contains(mid), 8000);
      await Future.delayed(const Duration(milliseconds: 400));
      final next = current();
      if (next.length >= cur.length) break; // no bajó: no insistir
      cur = next;
    }
    // faltan → crear
    while (cur.length < virtuals.length) {
      final before = pi().macVirtualDisplays.toSet();
      bind.sessionToggleVirtualDisplay(sessionId: ffi.sessionId, index: 0, on: true);
      final ok = await waitFor(
          () => pi().macVirtualDisplays.any((m) => !before.contains(m)), 8000);
      if (!ok) break;
      await Future.delayed(const Duration(milliseconds: 400));
      cur = current();
    }
    // escala + tamaño de cada uno
    for (var i = 0; i < cur.length && i < virtuals.length; i++) {
      await applySpec(peerId, ffi, cur[i], virtuals[i]);
    }
    debugPrint('[monitor profile] aplicado a $peerId');
  }
}
