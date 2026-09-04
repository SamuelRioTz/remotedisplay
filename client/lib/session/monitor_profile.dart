import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart' show Size, debugPrint;
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart' show bind;

/// Available scales for a virtual monitor (like Windows: 100/125/150/200).
/// 200% = macOS's real HiDPI mode (Retina). 125/150 are emulated the way
/// Apple does ("looks like"): HiDPI with points = pixels/scale, framebuffer
/// at 2x points.
const kMonitorScales = [100, 125, 150, 200];

/// Rounds a devicePixelRatio to the nearest "Windows-style" scale.
int snapScale(double dpr) {
  final pct = (dpr * 100).round();
  var best = kMonitorScales.first;
  for (final s in kMonitorScales) {
    if ((s - pct).abs() < (best - pct).abs()) best = s;
  }
  return best;
}

/// A virtual monitor in the profile: size in PIXELS equivalent to 100%
/// (= the viewer window's pixels) and its scale.
class VirtualSpec {
  final int w;
  final int h;
  final int scale;
  const VirtualSpec(this.w, this.h, this.scale);

  /// Points requested from the server for this spec. Even numbers: hardware
  /// encoders refuse odd frame sizes (the server rounds down too).
  int get pointsW => (w * 100 / scale).round() & ~1;
  int get pointsH => (h * 100 / scale).round() & ~1;
  bool get hidpi => scale > 100;

  Map<String, dynamic> toJson() => {'w': w, 'h': h, 'scale': scale};
  static VirtualSpec fromJson(Map m) => VirtualSpec((m['w'] as num).round(),
      (m['h'] as num).round(), (m['scale'] as num?)?.round() ?? 100);
}

/// Monitor profile for a macOS peer, saved ON THIS CLIENT (per peer).
///
/// The idea: each client (the PC, the iPad…) has its own layout of virtual
/// monitors for the same Mac. On connect, the client **applies** its profile
/// to the server (creates, deletes, resizes and scales virtuals until they
/// match); if another client connects afterward, it applies its own and
/// overrides the previous one. When the last client leaves (or its connection
/// drops) the server puts the Mac's displays back: virtuals destroyed, the
/// dynamic main undone, physicals turned back on. The next connection simply
/// re-applies its profile.
///
/// It's saved as a peer option (`mac_monitor_profile`, JSON), and a snapshot
/// of the server's real state (PeerInfo) is taken a moment after each
/// toolbar action.
class MonitorProfile {
  static const optionKey = 'mac_monitor_profile';

  /// "Normal" virtuals (not the dynamic main one), in order.
  final List<VirtualSpec> virtuals;

  /// Dynamic main active (physical display mirrored onto a main virtual).
  final bool dynamicMain;

  /// Spec of the dynamic main virtual (if `dynamicMain`).
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
    // v1 saved display sizes without a scale: they're equivalent to 100%.
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

  // ------------------------------------------------ per-display scale (runtime)

  // The chosen scale can't be derived from the server alone (125 and 150 are
  // both HiDPI): it's remembered here by (peer, CGDirectDisplayID) and
  // persisted in the profile. No data: HiDPI => 200, otherwise 100.
  static final Map<String, Map<int, int>> _scales = {};

  static int scaleOf(String peerId, PeerInfo pi, int mid) =>
      _scales[peerId]?[mid] ?? (pi.macHiDPIDisplays.contains(mid) ? 200 : 100);

  static void rememberScale(String peerId, int mid, int scale) =>
      (_scales[peerId] ??= {})[mid] = scale;

  /// Size in pixels equivalent to 100% of display `i` (points × scale).
  static Size pixelSizeOf(PeerInfo pi, int i, int scale) {
    final d = pi.displays[i];
    final sc = d.scale <= 0 ? 1.0 : d.scale; // pixels / points
    final ptsW = d.width / sc;
    final ptsH = d.height / sc;
    return Size((ptsW * scale / 100).roundToDouble(),
        (ptsH * scale / 100).roundToDouble());
  }

  /// Snapshot of the server's REAL state according to the PeerInfo (source of truth).
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
      debugPrint('[monitor profile] unreadable profile for $peerId: $e');
      return null;
    }
  }

  void save(String peerId) {
    bind.mainSetPeerOption(id: peerId, key: optionKey, value: jsonEncode(toJson()));
    debugPrint('[monitor profile] saved $peerId: ${jsonEncode(toJson())}');
  }

  static final Map<String, Timer> _pendingSaves = {};

  /// Save a snapshot of the server a moment after an action (the server
  /// takes ~1s to settle and announce the new display list).
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

  // ------------------------------------------------------------ primitives

  static Future<bool> waitFor(bool Function() cond, int ms) async {
    for (var t = 0; t < ms; t += 100) {
      if (cond()) return true;
      await Future.delayed(const Duration(milliseconds: 100));
    }
    return cond();
  }

  /// Sets virtual display `mid` (row `idx`) to scale `scale` with pixel size
  /// `px`: HiDPI on/off according to the scale and then the points.
  static Future<void> applySpec(
      String peerId, FFI ffi, int mid, VirtualSpec spec) async {
    PeerInfo pi() => ffi.ffiModel.pi;
    final wantHiDPI = spec.hidpi;
    if (pi().macHiDPIDisplays.contains(mid) != wantHiDPI) {
      bind.sessionToggleVirtualDisplay(
          sessionId: ffi.sessionId, index: kMacHiDPIIndexBase + mid, on: wantHiDPI);
      // The flag changes right away; the mode takes time to settle (and on
      // windows narrower than ~1920px the server stays at 1x even with the
      // flag on): wait for the flag and give a fixed margin before the resize.
      await waitFor(() => pi().macHiDPIDisplays.contains(mid) == wantHiDPI, 6000);
      await Future.delayed(const Duration(milliseconds: 900));
    }
    rememberScale(peerId, mid, spec.scale);
    final idx = pi().macDisplayIds.indexOf(mid);
    if (idx < 0 || idx >= pi().displays.length) return;
    final d = pi().displays[idx];
    final sc = d.scale <= 0 ? 1.0 : d.scale;
    // 1 px of tolerance: the server rounds sizes down to even numbers.
    if (((d.width / sc).round() - spec.pointsW).abs() > 1 ||
        ((d.height / sc).round() - spec.pointsH).abs() > 1) {
      await ffi.ffiModel.changeResolutionOfDisplay(idx, spec.pointsW, spec.pointsH);
      await Future.delayed(const Duration(milliseconds: 600));
    }
  }

  // ------------------------------------------------------------------ apply

  static final Set<String> _applying = {};

  /// Reconciles the server with this client's saved profile. Idempotent: if
  /// it already matches, sends nothing. With no saved profile (first time
  /// from this client), touches nothing.
  static Future<void> applySaved(String peerId, FFI ffi) async {
    final profile = load(peerId);
    if (profile == null) return;
    if (_applying.contains(peerId)) return;
    _applying.add(peerId);
    try {
      await profile._apply(peerId, ffi);
    } catch (e) {
      debugPrint('[monitor profile] apply failed: $e');
    } finally {
      _applying.remove(peerId);
    }
  }

  Future<void> _apply(String peerId, FFI ffi) async {
    PeerInfo pi() => ffi.ffiModel.pi;
    debugPrint('[monitor profile] applying to $peerId: ${jsonEncode(toJson())}');

    // 1) dynamic main
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

    // 2) normal virtuals (excluding the dynamic main one), in order
    List<int> current() {
      final p = pi();
      final virt = p.macVirtualDisplays.toSet();
      return p.macDisplayIds
          .where((m) =>
              virt.contains(m) && !(p.macDynamicMainActive && m == p.macDynamicMainId))
          .toList();
    }

    // extra ones → delete (last ones first)
    var cur = current();
    while (cur.length > virtuals.length) {
      final mid = cur.last;
      bind.sessionToggleVirtualDisplay(
          sessionId: ffi.sessionId, index: kMacRawDisplayIdBase + mid, on: false);
      await waitFor(() => !pi().macVirtualDisplays.contains(mid), 8000);
      await Future.delayed(const Duration(milliseconds: 400));
      final next = current();
      if (next.length >= cur.length) break; // didn't go down: don't retry
      cur = next;
    }
    // missing ones → create
    while (cur.length < virtuals.length) {
      final before = pi().macVirtualDisplays.toSet();
      bind.sessionToggleVirtualDisplay(sessionId: ffi.sessionId, index: 0, on: true);
      final ok = await waitFor(
          () => pi().macVirtualDisplays.any((m) => !before.contains(m)), 8000);
      if (!ok) break;
      await Future.delayed(const Duration(milliseconds: 400));
      cur = current();
    }
    // scale + size for each one
    for (var i = 0; i < cur.length && i < virtuals.length; i++) {
      await applySpec(peerId, ffi, cur[i], virtuals[i]);
    }
    debugPrint('[monitor profile] applied to $peerId');
  }
}
