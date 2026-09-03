import 'dart:convert' show json;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodCall, MethodChannel;
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/mobile/pages/remote_page.dart';
import 'package:flutter_hbb/models/platform_model.dart' show bind;
import 'package:get/get.dart';

import 'external_screen.dart';
import 'session_toolbar.dart';
import 'trackpad_screen.dart';

/// Sensitivity of GCMouse deltas → remote pixels (pointer capture).
const _kPointerCaptureSpeed = 2.0;

/// Session on Android/iOS — the equivalent of ClientRemoteScreen (desktop):
/// the engine's MOBILE RemotePage (render, touch gestures, virtual keyboard,
/// clipboard) with its bar hidden (fork patch 03: `showToolbar`) and OUR
/// SessionToolbar on top. It's a normal Navigator route: closing the
/// connection (toolbar or back button → clientClose) returns to the home.
class MobileSessionScreen extends StatefulWidget {
  const MobileSessionScreen({super.key, required this.id, this.password});

  final String id;
  final String? password;

  @override
  State<MobileSessionScreen> createState() => _MobileSessionScreenState();
}

class _MobileSessionScreenState extends State<MobileSessionScreen> {
  final _controller = MobileRemotePageController();
  // With trackpad/mouse (iPad, Android): hide the LOCAL pointer over the
  // remote canvas — the engine already draws the remote machine's cursor,
  // otherwise you'd see two. Persistent; toggle in Input → Cursor and keys.
  late final ValueNotifier<bool> _hideLocalPointer =
      ValueNotifier(bind.mainGetLocalOption(key: kOptHideLocalPointer) != 'N');

  // iPad: pointer capture (relative, crosses monitors). See
  // kOptPointerCapture. Effective capture is released while a menu or popup
  // is open (so they can be used with the trackpad) and on dispose.
  // NOTE: default OFF (opt-in). On a real iPad the lock engaged but GCMouse
  // didn't deliver deltas → invisible, dead pointer; until the cause is
  // tracked down (see the diagnostic row in Input), the absolute pointer is
  // always the default behavior.
  late final ValueNotifier<bool> _pointerCapture =
      ValueNotifier(bind.mainGetLocalOption(key: kOptPointerCapture) == 'Y');
  bool _captureToastShown = false;

  Future<dynamic> _onPointerChannelCall(MethodCall call) async {
    switch (call.method) {
      case 'lockState':
        // The system actually engaged/released the pointer lock (not just
        // that we requested it).
        final locked = (call.arguments as Map)['locked'] == true;
        if (locked) {
          // Recenter: if the cursor ended up outside the visible display (or
          // at the initial -10000 sentinel), a null move clamps it back in —
          // so the first drag is VISIBLE.
          gFFI.cursorModel.moveRelativeAcrossDisplays(0, 0);
        }
        if (locked && !_captureToastShown) {
          _captureToastShown = true;
          showToast('Trackpad captured — Input menu to release');
        }
        break;
      case 'relMove':
        final a = call.arguments as Map;
        gFFI.cursorModel.moveRelativeAcrossDisplays(
            (a['dx'] as num).toDouble() * _kPointerCaptureSpeed,
            (a['dy'] as num).toDouble() * _kPointerCaptureSpeed);
        break;
      case 'relButton':
        final a = call.arguments as Map;
        bind.sessionSendMouse(
            sessionId: gFFI.sessionId,
            msg: json.encode({
              'type': (a['down'] as bool) ? 'down' : 'up',
              'buttons': a['button'] as String,
            }));
        break;
      case 'relWheel':
        // WHOLE wheel steps arrive here (the px→steps conversion lives in
        // native code, which knows each gesture's limits — minimum notch ±1).
        final a = call.arguments as Map;
        final sx = (a['dx'] as num).toInt();
        final sy = (a['dy'] as num).toInt();
        if (sx != 0 || sy != 0) {
          bind.sessionSendMouse(
              sessionId: gFFI.sessionId,
              msg: json.encode({'type': 'wheel', 'x': '$sx', 'y': '$sy'}));
        }
        break;
    }
    return null;
  }

  // iOS: Flutter doesn't implement MouseRegion.cursor on iPadOS → the Runner
  // hides the pointer with UIPointerInteraction; we tell it whether to hide
  // and where NOT to (the pill, and while it's open, everywhere a menu is open).
  static const _pointerChannel = MethodChannel('remotedisplay/pointer');
  Rect? _pillRect;
  bool _menuOpen = false;

  // iPad + external monitor: the external view shows "the other" remote
  // display (second engine on the external UIScreen). iOS only: on Android,
  // desktop mode already splits screens via DeX/trackpad.
  ExternalScreenController? _extScreen;

  void _syncNativePointer() {
    if (!isIOS) return;
    // With a popup open, the pointer is ALWAYS visible (dialogs render over
    // the canvas, where we normally hide it).
    final dialogOpen = gFFI.dialogManager.visibleDialogCount.value > 0;
    final hide = _hideLocalPointer.value && !_menuOpen && !dialogOpen;
    final r = _pillRect;
    _pointerChannel.invokeMethod('setHidden', {
      'hidden': hide,
      'visible': r == null
          ? []
          : [
              [r.left, r.top, r.width, r.height]
            ],
    }).catchError((_) {});
    // Pointer capture: active during the session except with a menu/popup
    // open (there, the trackpad goes back to controlling the iPadOS pointer).
    final capture = _pointerCapture.value && !_menuOpen && !dialogOpen;
    // With capture on, the engine ignores physical mouse events: iPadOS
    // delivers trackpad clicks ALSO as touches even while the pointer is
    // locked, which duplicated the click coming in via GCMouse (patch 14).
    gFFI.inputModel.ignorePhysicalMouse = capture;
    _pointerChannel.invokeMethod('capture', {'on': capture}).catchError((_) {});
  }

  Worker? _dialogWorker;

  @override
  void initState() {
    super.initState();
    _hideLocalPointer.addListener(_syncNativePointer);
    _pointerCapture.addListener(_syncNativePointer);
    if (isIOS) {
      // Deltas/buttons/wheel from the captured trackpad (GCMouse, via Runner).
      _pointerChannel.setMethodCallHandler(_onPointerChannelCall);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncNativePointer());
    // iOS: re-sync the native pointer when a popup appears/disappears.
    if (isIOS) {
      _dialogWorker = ever(gFFI.dialogManager.visibleDialogCount,
          (_) => _syncNativePointer());
    }
    // Publish the session for the TrackpadActivity (phone = trackpad while
    // the session runs on the external monitor; Android only).
    if (isAndroid) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        bind.mainSetLocalOption(
            key: kOptTrackpadSession, value: gFFI.sessionId.toString());
      });
    }
    if (isIOS) {
      final ext = ExternalScreenController(peerId: widget.id);
      _extScreen = ext;
      // One-time notice when there's a monitor + 2 remote displays (the
      // external one is opened by hand from the Display menu, like on desktop).
      ext.onExternalAvailable = () =>
          showToast('External display detected — open the Display menu');
      // The swap and the notice depend on the session's state: ffiModel
      // notifies changes (peer info, display switch) but goes quiet after
      // the first frame — imageModel notifies per frame and covers that gap
      // (onSessionUpdate bails out immediately if there's nothing to do, so
      // the per-frame cost is a couple of comparisons).
      gFFI.ffiModel.addListener(_onFfiModelChanged);
      gFFI.imageModel.addListener(_onFfiModelChanged);
      WidgetsBinding.instance.addPostFrameCallback((_) => ext.init());
    }
  }

  void _onFfiModelChanged() {
    _extScreen?.onSessionUpdate();
  }

  @override
  void dispose() {
    _dialogWorker?.dispose();
    _hideLocalPointer.removeListener(_syncNativePointer);
    _hideLocalPointer.dispose();
    if (isAndroid) {
      bind.mainSetLocalOption(key: kOptTrackpadSession, value: '');
    }
    if (isIOS) {
      _pointerChannel
          .invokeMethod('setHidden', {'hidden': false}).catchError((_) {});
      _pointerChannel.invokeMethod('capture', {'on': false}).catchError((_) {});
      _pointerChannel.setMethodCallHandler(null);
      gFFI.inputModel.ignorePhysicalMouse = false;
      gFFI.ffiModel.removeListener(_onFfiModelChanged);
      gFFI.imageModel.removeListener(_onFfiModelChanged);
      _extScreen?.dispose();
      _extScreen = null;
    }
    _pointerCapture.removeListener(_syncNativePointer);
    _pointerCapture.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kColorCanvas,
      // The virtual keyboard pushes the body up: the pill stays visible above it.
      resizeToAvoidBottomInset: true,
      body: Stack(
        children: [
          ValueListenableBuilder<bool>(
            valueListenable: _hideLocalPointer,
            // Obx: if an engine popup is open, the local pointer is shown
            // even while hidden over the canvas (Android; on iOS this is
            // done by _syncNativePointer with the same observable).
            builder: (_, hide, child) => Obx(() {
              final dialogOpen =
                  gFFI.dialogManager.visibleDialogCount.value > 0;
              return MouseRegion(
                cursor: hide && !dialogOpen
                    ? SystemMouseCursors.none
                    : MouseCursor.defer,
                child: child,
              );
            }),
            // OLED: TOTAL black around the canvas. The engine's RemotePage
            // Scaffold doesn't set backgroundColor and inherits
            // scaffoldBackgroundColor from the theme (white/graphite
            // #18191E): the SafeArea strips around the video looked gray.
            child: Theme(
              data: Theme.of(context)
                  .copyWith(scaffoldBackgroundColor: Colors.black),
              child: RemotePage(
                key: ValueKey(widget.id),
                id: widget.id,
                password: widget.password,
                showToolbar: false,
                keyHelpHorizontal: true,
                controller: _controller,
              ),
            ),
          ),
          SessionToolbar(
            peerId: widget.id,
            getFfi: () => gFFI, // on mobile the engine uses the global session
            mobile: _controller,
            externalScreen: _extScreen,
            pointerCapture: _pointerCapture,
            hideLocalPointer: _hideLocalPointer,
            onPointerUi: (pill, menuOpen) {
              _pillRect = pill;
              _menuOpen = menuOpen;
              _syncNativePointer();
            },
          ),
        ],
      ),
    );
  }
}
