import 'dart:async';
import 'dart:math' show min;
import 'dart:typed_data';
import 'dart:ui' as ui show Image;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/widgets/overlay.dart'
    show BlockableOverlay, BlockableOverlayState;
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/model.dart' show FFI, ImageModel;
import 'package:flutter_hbb/models/platform_model.dart' show bind;
import 'package:get/get.dart';
import 'package:provider/provider.dart';

/// iPad external monitor (classic iPadOS, no scenes): the Runner creates a
/// second FlutterEngine on the external UIScreen with route `/extscreen`;
/// that engine (ANOTHER isolate, SAME rust runtime) hooks into the already
/// open connection as a second UI-session and shows ANOTHER remote display.
/// This way the iPad screen and the external monitor show two monitors of
/// the Mac at the same time.
///
/// Like on desktop: by default ONLY the main view — the external monitor is
/// opened from the Screen menu (button per display), and closed the same way.
///
/// Handoff from main-isolate to ext-isolate via local options (same pattern
/// as the Android trackpad): peer, display, and the serialized CachedPeerData.
const String kOptExtScreenPeer = 'remotedisplay-extscreen-peer';
const String kOptExtScreenDisplay = 'remotedisplay-extscreen-display';
const String kOptExtScreenCache = 'remotedisplay-extscreen-cache';

/// Channel from the MAIN isolate to the Runner: attach/detach/setDisplay
/// toward native; connected/disconnected from native (plugging/unplugging the monitor).
const kExtDisplayChannel = MethodChannel('remotedisplay/extdisplay');

/// Channel from the external monitor's isolate to the Runner: receives
/// setDisplay (forwarded from the main one) and dispose (before destroying the engine).
const kExtViewChannel = MethodChannel('remotedisplay/extview');

/// Lives in the mobile session (main isolate). The user decides from the
/// toolbar which remote display to send to the external monitor
/// (attach/detach); if the iPad view is then switched to the display that's
/// out there, they swap so both remote monitors stay visible.
class ExternalScreenController {
  ExternalScreenController({required this.peerId});

  final String peerId;

  /// Remote display on the external monitor; -1 = external view closed.
  final RxInt extDisplay = (-1).obs;

  /// A monitor is connected to the iPad (whether or not the external view is open).
  final RxBool screenConnected = false.obs;

  /// Once-per-session notice: monitor present and 2+ remote displays — the
  /// session uses this for the "open the Screen menu" toast.
  VoidCallback? onExternalAvailable;

  bool _attaching = false;
  bool _hintShown = false;
  int _lastMainDisplay = -1;

  // Cursor forwarding to the external monitor (throttled ~60Hz). The host
  // suppresses the CursorPosition echo for 300ms for the connection that
  // injects input (run_pos, input_service.rs), so the external view can't
  // rely on the server's events: the authoritative position is the main
  // isolate's cursorModel.
  DateTime _lastCursorFwd = DateTime.fromMillisecondsSinceEpoch(0);
  Offset _lastCursorPos = Offset.zero;

  Future<void> init() async {
    kExtDisplayChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'connected':
          screenConnected.value = true;
          _maybeHint();
          break;
        case 'disconnected':
          screenConnected.value = false;
          extDisplay.value = -1;
          break;
      }
      return null;
    });
    try {
      screenConnected.value =
          await kExtDisplayChannel.invokeMethod('isConnected') == true;
    } catch (_) {
      screenConnected.value = false; // channel not implemented (Android): off
    }
    _lastMainDisplay = gFFI.ffiModel.pi.currentDisplay;
    gFFI.cursorModel.addListener(_onCursorMoved);
    // The cursor crossing rect ALWAYS follows the active external display.
    _extWorker = ever(extDisplay, (_) => _updateCursorRect());
  }

  Worker? _extWorker;

  /// The external display as a remote global rect → CursorModel.extraCursorRect
  /// (fork patch 13): the cursor can cross the edge toward the monitor.
  void _updateCursorRect() {
    final d = extDisplay.value;
    Rect? r;
    final displays = gFFI.ffiModel.pi.displays;
    if (d >= 0 && d < displays.length) {
      final disp = displays[d];
      r = Rect.fromLTWH(disp.x.toDouble(), disp.y.toDouble(),
          disp.width.toDouble(), disp.height.toDouble());
    }
    gFFI.cursorModel.extraCursorRect = r;
  }

  void _onCursorMoved() {
    if (extDisplay.value < 0) return;
    final pos = gFFI.cursorModel.offset;
    if ((pos - _lastCursorPos).distanceSquared < 1) return;
    final now = DateTime.now();
    if (now.difference(_lastCursorFwd).inMilliseconds < 16) return;
    _lastCursorFwd = now;
    _lastCursorPos = pos;
    kExtDisplayChannel.invokeMethod(
        'cursorPos', {'x': pos.dx, 'y': pos.dy}).catchError((_) {});
  }

  /// Call on every ffiModel/imageModel change of the main session: resolves
  /// the swap when switching displays on the iPad and the initial hint.
  Future<void> onSessionUpdate() async {
    _maybeHint();
    final current = gFFI.ffiModel.pi.currentDisplay;
    if (current == _lastMainDisplay || current == kAllDisplayValue) return;
    final prev = _lastMainDisplay;
    _lastMainDisplay = current;
    if (extDisplay.value >= 0) {
      if (current == extDisplay.value && prev >= 0) {
        // The iPad switches to showing the external monitor's display → swap.
        await setExternalDisplay(prev);
      }
      // The iPad's display may be left without frames if it was already
      // captured and the content is static: request a keyframe.
      await bind.sessionRefresh(sessionId: gFFI.sessionId, display: current);
    }
  }

  void _maybeHint() {
    if (_hintShown ||
        !screenConnected.value ||
        extDisplay.value >= 0 ||
        gFFI.ffiModel.pi.displays.length < 2 ||
        gFFI.ffiModel.waitForFirstImage.value) return;
    _hintShown = true;
    onExternalAvailable?.call();
  }

  /// Opens the external view with [display] (toolbar button); if it's
  /// already open, only changes the display it shows.
  Future<void> attachDisplay(int display) async {
    if (!screenConnected.value || _attaching) return;
    if (extDisplay.value >= 0) {
      await setExternalDisplay(display);
      return;
    }
    final pi = gFFI.ffiModel.pi;
    if (display < 0 || display >= pi.displays.length) return;
    if (gFFI.ffiModel.waitForFirstImage.value) return; // session not ready yet
    _attaching = true;
    try {
      _lastMainDisplay = pi.currentDisplay;
      await bind.mainSetLocalOption(key: kOptExtScreenPeer, value: peerId);
      await bind.mainSetLocalOption(
          key: kOptExtScreenDisplay, value: '$display');
      await bind.mainSetLocalOption(
          key: kOptExtScreenCache,
          value: gFFI.ffiModel.cachedPeerData.toString());
      await kExtDisplayChannel.invokeMethod('attach');
      extDisplay.value = display;
    } catch (e) {
      debugPrint('[extscreen] attach failed: $e');
    } finally {
      _attaching = false;
    }
  }

  /// Changes which remote display the external monitor shows (already open).
  Future<void> setExternalDisplay(int display) async {
    if (extDisplay.value < 0 || extDisplay.value == display) return;
    extDisplay.value = display;
    await bind.mainSetLocalOption(
        key: kOptExtScreenDisplay, value: '$display');
    try {
      await kExtDisplayChannel
          .invokeMethod('setDisplay', {'display': display});
    } catch (e) {
      debugPrint('[extscreen] setDisplay failed: $e');
    }
  }

  /// Closes the external monitor's view (✕ button in the toolbar). The
  /// monitor goes back to system mirroring.
  Future<void> detach() async {
    if (extDisplay.value < 0) return;
    extDisplay.value = -1;
    try {
      await kExtDisplayChannel.invokeMethod('detach');
    } catch (e) {
      debugPrint('[extscreen] detach failed: $e');
    }
  }

  Future<void> dispose() async {
    kExtDisplayChannel.setMethodCallHandler(null);
    gFFI.cursorModel.removeListener(_onCursorMoved);
    gFFI.cursorModel.extraCursorRect = null;
    _extWorker?.dispose();
    try {
      await kExtDisplayChannel.invokeMethod('detach');
    } catch (_) {}
    extDisplay.value = -1;
    await bind.mainSetLocalOption(key: kOptExtScreenPeer, value: '');
    await bind.mainSetLocalOption(key: kOptExtScreenCache, value: '');
  }
}

/// Root of the external monitor's isolate: second UI-session (view-only) of
/// the existing connection, showing the display published in the local options.
class ExternalScreenView extends StatefulWidget {
  const ExternalScreenView({super.key});

  @override
  State<ExternalScreenView> createState() => _ExternalScreenViewState();
}

class _ExternalScreenViewState extends State<ExternalScreenView> {
  FFI? _ffi;
  String? _error;
  String _peer = '';
  int _display = -1;
  final _overlayState = BlockableOverlayState();

  // Remote cursor over this display (remote global position, forwarded by
  // the main isolate via native — see ExternalScreenController).
  final ValueNotifier<Offset?> _cursorPos = ValueNotifier(null);

  @override
  void initState() {
    super.initState();
    kExtViewChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'setDisplay':
          final d = (call.arguments as Map)['display'] as int;
          _switchDisplay(d);
          break;
        case 'cursorPos':
          final args = call.arguments as Map;
          _cursorPos.value =
              Offset((args['x'] as num).toDouble(), (args['y'] as num).toDouble());
          break;
        case 'dispose':
          await _ffi?.close();
          _ffi = null;
          break;
      }
      return null;
    });
    _start();
  }

  void _start() {
    final peer = bind.mainGetLocalOption(key: kOptExtScreenPeer);
    final display =
        int.tryParse(bind.mainGetLocalOption(key: kOptExtScreenDisplay)) ?? -1;
    if (peer.isEmpty || display < 0) {
      setState(() => _error = 'No active session');
      return;
    }
    // gFFI for THIS isolate (its own sessionId, different from the iPad
    // session's). tabWindowId=-1: FFI.start's "existing session" path
    // (sessionAddExistedSync + sessionStartWithDisplays) with no origin
    // window — the cached data arrives via getCachedSessionData (fork patch).
    final ffi = gFFI;
    _overlayState.applyFfi(ffi);
    ffi.start(
      peer,
      tabWindowId: -1,
      display: display,
      displays: [display],
      getCachedSessionData: () async =>
          bind.mainGetLocalOption(key: kOptExtScreenCache),
    );
    setState(() {
      _ffi = ffi;
      _peer = peer;
      _display = display;
    });
  }

  void _switchDisplay(int display) {
    final ffi = _ffi;
    if (ffi == null) return;
    ffi.imageModel.clearImage();
    // isDesktop=false → the engine's patched mobile branch: unions the
    // displays of the other ui-sessions instead of the exclusive set (doesn't cut off the iPad).
    bind.sessionSwitchDisplay(
      isDesktop: false,
      sessionId: ffi.sessionId,
      value: Int32List.fromList([display]),
    );
    ffi.ffiModel.switchToNewDisplay(display, ffi.sessionId, ffi.id);
    // Static content: without this, not a single frame arrives until something changes.
    bind.sessionRefresh(sessionId: ffi.sessionId, display: display);
    setState(() => _display = display);
  }

  /// External monitor's session pill — same visual codes as the
  /// SessionToolbar (graphite, faint border, soft radii). Informational: on
  /// this screen there is no input (control stays on the iPad).
  Widget _pill() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xE61A1D24),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0x14FFFFFF)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.desktop_windows_rounded,
              size: 16, color: Color(0xFF3B82F6)),
          const SizedBox(width: 10),
          Text(
            _peer,
            style: const TextStyle(color: Color(0xFFB8BDC7), fontSize: 14),
          ),
          const SizedBox(width: 10),
          Container(width: 1, height: 14, color: const Color(0x22FFFFFF)),
          const SizedBox(width: 10),
          Text(
            'Display ${_display + 1}',
            style: const TextStyle(
                color: Color(0xFFEDEDEF),
                fontSize: 14,
                fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _cursorPos.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ffi = _ffi;
    final Widget body;
    if (ffi == null) {
      body = Center(
        child: Text(
          _error ?? '',
          style: const TextStyle(color: Color(0xFF6A7280), fontSize: 16),
        ),
      );
    } else {
      body = Stack(
        children: [
          ChangeNotifierProvider.value(
            value: ffi.imageModel,
            child: Consumer<ImageModel>(
              builder: (context, im, _) {
                final img = im.image;
                if (img == null) {
                  return const Center(
                    child:
                        CircularProgressIndicator(color: Color(0xFF3B82F6)),
                  );
                }
                return Center(
                  child: FittedBox(
                    fit: BoxFit.contain,
                    child: SizedBox(
                      width: img.width.toDouble(),
                      height: img.height.toDouble(),
                      child: RawImage(image: img),
                    ),
                  ),
                );
              },
            ),
          ),
          // Remote cursor when it's over THIS display (it crossed the edge
          // from the iPad, or it was moved on the host).
          Positioned.fill(
            child: AnimatedBuilder(
              animation: Listenable.merge(
                  [_cursorPos, ffi.cursorModel, ffi.imageModel]),
              builder: (context, _) => LayoutBuilder(
                builder: (context, constraints) => CustomPaint(
                  painter: _RemoteCursorPainter(
                    pos: _cursorPos.value,
                    displayRect: ffi.ffiModel.rect,
                    imageSize: ffi.imageModel.image == null
                        ? null
                        : Size(ffi.imageModel.image!.width.toDouble(),
                            ffi.imageModel.image!.height.toDouble()),
                    viewSize:
                        Size(constraints.maxWidth, constraints.maxHeight),
                    cursorImage: ffi.cursorModel.image,
                    hotx: ffi.cursorModel.hotx,
                    hoty: ffi.cursorModel.hoty,
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 20,
            child: Center(child: _pill()),
          ),
        ],
      );
    }
    return Scaffold(
      backgroundColor: Colors.black,
      // BlockableOverlay: real overlay for this session's dialogManager
      // (waiting-for-image, engine msgbox) — same pattern as RemotePage.
      body: BlockableOverlay(
        underlying: Container(color: Colors.black, child: body),
        state: _overlayState,
      ),
    );
  }
}

/// Draws the remote cursor over the external monitor's video, replicating
/// the FittedBox transform (contain + centered). [pos] comes in remote
/// global coords; it's only painted if it falls within [displayRect].
class _RemoteCursorPainter extends CustomPainter {
  _RemoteCursorPainter({
    required this.pos,
    required this.displayRect,
    required this.imageSize,
    required this.viewSize,
    required this.cursorImage,
    required this.hotx,
    required this.hoty,
  });

  final Offset? pos;
  final Rect? displayRect;
  final Size? imageSize;
  final Size viewSize;
  final ui.Image? cursorImage;
  final double hotx;
  final double hoty;

  @override
  void paint(Canvas canvas, Size size) {
    final p = pos;
    final rect = displayRect;
    final img = imageSize;
    if (p == null || rect == null || img == null) return;
    if (!rect.contains(p)) return;
    final s = min(viewSize.width / img.width, viewSize.height / img.height);
    final dx0 = (viewSize.width - img.width * s) / 2;
    final dy0 = (viewSize.height - img.height * s) / 2;
    final local = Offset(
        (p.dx - rect.left) * s + dx0, (p.dy - rect.top) * s + dy0);
    final cur = cursorImage;
    if (cur != null) {
      final w = cur.width * s;
      final h = cur.height * s;
      canvas.drawImageRect(
        cur,
        Rect.fromLTWH(0, 0, cur.width.toDouble(), cur.height.toDouble()),
        Rect.fromLTWH(local.dx - hotx * s, local.dy - hoty * s, w, h),
        Paint()..filterQuality = FilterQuality.medium,
      );
    } else {
      // No shape yet: a simple white arrow with a black outline.
      final path = Path()
        ..moveTo(local.dx, local.dy)
        ..lineTo(local.dx, local.dy + 17)
        ..lineTo(local.dx + 4.5, local.dy + 13)
        ..lineTo(local.dx + 8, local.dy + 20)
        ..lineTo(local.dx + 11, local.dy + 18.5)
        ..lineTo(local.dx + 7.5, local.dy + 12)
        ..lineTo(local.dx + 12.5, local.dy + 12)
        ..close();
      canvas.drawPath(
          path,
          Paint()
            ..color = const Color(0xFF000000)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2);
      canvas.drawPath(path, Paint()..color = const Color(0xFFFFFFFF));
    }
  }

  @override
  bool shouldRepaint(covariant _RemoteCursorPainter old) =>
      old.pos != pos ||
      old.cursorImage != cursorImage ||
      old.displayRect != displayRect ||
      old.imageSize != imageSize ||
      old.viewSize != viewSize;
}
