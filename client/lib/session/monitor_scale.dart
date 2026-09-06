import 'package:flutter/widgets.dart' show Size;
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart' show bind;

/// Scales for a virtual monitor (like Windows: 100/125/150/200). 200 % is macOS's
/// real HiDPI (Retina) mode; 125/150 are emulated the way Apple does ("looks
/// like"): HiDPI with points = pixels / scale.
const kMonitorScales = [100, 125, 150, 200];

/// Nearest "Windows-style" scale for a devicePixelRatio.
int snapScale(double dpr) {
  final pct = (dpr * 100).round();
  var best = kMonitorScales.first;
  for (final s in kMonitorScales) {
    if ((s - pct).abs() < (best - pct).abs()) best = s;
  }
  return best;
}

/// The scale chosen for each virtual monitor (by CGDirectDisplayID), for THIS
/// session only. The server knows HiDPI on/off but 125 and 150 are both HiDPI,
/// so the exact choice is remembered here. Nothing is saved anywhere: monitors
/// are configured on the Mac (menu-bar app) and reset when its service stops.
class MonitorScale {
  static final Map<String, Map<int, int>> _scales = {};

  static int of(String peerId, PeerInfo pi, int mid) =>
      _scales[peerId]?[mid] ?? (pi.macHiDPIDisplays.contains(mid) ? 200 : 100);

  static void remember(String peerId, int mid, int scale) =>
      (_scales[peerId] ??= {})[mid] = scale;

  /// Size in pixels equivalent to 100 % of display `i` (points × scale).
  static Size pixelSizeOf(PeerInfo pi, int i, int scale) {
    final d = pi.displays[i];
    final sc = d.scale <= 0 ? 1.0 : d.scale; // pixels / points
    final ptsW = d.width / sc;
    final ptsH = d.height / sc;
    return Size((ptsW * scale / 100).roundToDouble(),
        (ptsH * scale / 100).roundToDouble());
  }

  static Future<bool> waitFor(bool Function() cond, int ms) async {
    for (var t = 0; t < ms; t += 100) {
      if (cond()) return true;
      await Future.delayed(const Duration(milliseconds: 100));
    }
    return cond();
  }

  /// Sets virtual `mid` to `scale` while keeping its pixel size `px`: HiDPI on
  /// or off according to the scale, then the points (pixels / scale, rounded to
  /// even numbers because hardware encoders refuse odd frame sizes).
  static Future<void> apply(
      String peerId, FFI ffi, int mid, Size px, int scale) async {
    PeerInfo pi() => ffi.ffiModel.pi;
    final wantHiDPI = scale > 100;
    if (pi().macHiDPIDisplays.contains(mid) != wantHiDPI) {
      bind.sessionToggleVirtualDisplay(
          sessionId: ffi.sessionId,
          index: kMacHiDPIIndexBase + mid,
          on: wantHiDPI);
      // The flag changes right away; the mode takes time to settle (and on
      // windows narrower than ~1920px the server stays at 1x even with the
      // flag on): wait for the flag and give a fixed margin before the resize.
      await waitFor(() => pi().macHiDPIDisplays.contains(mid) == wantHiDPI, 6000);
      await Future.delayed(const Duration(milliseconds: 900));
    }
    remember(peerId, mid, scale);
    final idx = pi().macDisplayIds.indexOf(mid);
    if (idx < 0 || idx >= pi().displays.length) return;
    final w = (px.width * 100 / scale).round() & ~1;
    final h = (px.height * 100 / scale).round() & ~1;
    final d = pi().displays[idx];
    final sc = d.scale <= 0 ? 1.0 : d.scale;
    // 1 px of tolerance: the server rounds sizes down to even numbers.
    if (((d.width / sc).round() - w).abs() > 1 ||
        ((d.height / sc).round() - h).abs() > 1) {
      await ffi.ffiModel.changeResolutionOfDisplay(idx, w, h);
    }
  }
}
