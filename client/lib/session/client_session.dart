import 'dart:async';
import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/shared_state.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/desktop/pages/remote_page.dart';
import 'package:flutter_hbb/desktop/widgets/remote_toolbar.dart'
    show ToolbarState;
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:flutter_hbb/utils/multi_window_manager.dart';
import 'package:provider/provider.dart';

import 'monitor_profile.dart';
import 'session_toolbar.dart';
import 'win_events.dart';

/// Our own session window: ONE connection per window, without RustDesk tabs
/// and with the client's minimalist toolbar. Replaces DesktopRemoteScreen +
/// ConnectionTabPage; the plumbing (RemotePage: render, input, clipboard) is
/// reused intact from flutter_hbb.
class ClientRemoteScreen extends StatelessWidget {
  ClientRemoteScreen({super.key, required this.params}) {
    bind.mainInitInputSource();
    stateGlobal.getInputSource(force: true);
  }

  final Map<String, dynamic> params;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: gFFI.ffiModel),
        ChangeNotifierProvider.value(value: gFFI.imageModel),
        ChangeNotifierProvider.value(value: gFFI.cursorModel),
        ChangeNotifierProvider.value(value: gFFI.canvasModel),
      ],
      child: ClientSessionPage(params: params),
    );
  }
}

class ClientSessionPage extends StatefulWidget {
  const ClientSessionPage({super.key, required this.params});

  final Map<String, dynamic> params;

  @override
  State<ClientSessionPage> createState() => _ClientSessionPageState();
}

class _ClientSessionPageState extends State<ClientSessionPage> {
  late final String _peerId;
  late final RemotePage _remotePage;

  @override
  void initState() {
    super.initState();
    final params = widget.params;
    _peerId = params['id'] as String;
    RemoteCountState.init();
    ConnectionTypeState.init(_peerId);

    final sessionId = params['session_id'];
    _remotePage = RemotePage(
      key: ValueKey(_peerId),
      id: _peerId,
      sessionId: sessionId == null ? null : SessionID(sessionId),
      tabWindowId: params['tab_window_id'],
      display: params['display'] as int?,
      displays: (params['displays'] as List?)?.cast<int>(),
      password: params['password'] as String?,
      toolbarState: ToolbarState(),
      showToolbar: false,
      switchUuid: params['switch_uuid'] as String?,
      forceRelay: params['forceRelay'] as bool?,
      isSharedPassword: params['isSharedPassword'] as bool?,
    );

    final windowId = params['windowId'];
    if (windowId != null) {
      WindowController.fromWindowId(windowId)
          .setTitle(sessionWindowTitle(_peerId, params['display'] as int?));
    }
    rustDeskWinManager.setMethodHandler(_methodHandler);
    // PER-CLIENT monitor profile: only the peer's main window (per-monitor
    // windows carry `display`) applies the saved profile every time the
    // server announces a PeerInfo (initial connection and reconnections,
    // e.g. after a server restart that lost the virtual displays).
    if (params['display'] == null) {
      _watch = Timer.periodic(const Duration(milliseconds: 500), (_) => _tick());
    } else {
      // Per-monitor window: when the display it shows no longer exists (the
      // virtual was deleted, the physical turned off), the engine falls back
      // to display 0, which would duplicate the main window, and the server
      // kept retrying the capture. Close this window instead.
      // Indices shift when a lower display is removed, so on macOS hosts the
      // window is tied to the display's own id (macDisplayIds); the index is
      // the fallback for other hosts.
      final shown = params['display'] as int;
      final windowId = params['windowId'];
      int? shownMid;
      _watch = Timer.periodic(const Duration(seconds: 1), (_) {
        final pi = _remotePage.ffi.ffiModel.pi;
        if (pi.displays.isEmpty) return;
        final mids = pi.macDisplayIds;
        bool gone;
        if (mids.isNotEmpty) {
          shownMid ??= shown < mids.length ? mids[shown] : null;
          if (shownMid == null) return;
          gone = !mids.contains(shownMid);
        } else {
          gone = pi.displays.length <= shown;
        }
        if (!gone) return;
        _watch?.cancel();
        if (windowId == null) return;
        final wc = WindowController.fromWindowId(windowId);
        wc.setPreventClose(false).then((_) => wc.close());
      });
    }
  }

  Timer? _watch;
  int _seenEpoch = 0;
  int? _titledDisplay;

  Future<void> _tick() async {
    if (!mounted) return;
    final ffi = _remotePage.ffi;
    final pi = ffi.ffiModel.pi;
    // Window title always matches the display being shown (the engine can
    // change it on its own: e.g. the virtual display being viewed disappears).
    if (isDesktop &&
        pi.displays.isNotEmpty &&
        _titledDisplay != pi.currentDisplay) {
      _titledDisplay = pi.currentDisplay;
      WindowController.fromWindowId(stateGlobal.windowId)
          .setTitle(sessionWindowTitle(_peerId, pi.currentDisplay));
      // The menu's radio reads CurrentDisplayState; after a reconnection the
      // engine goes back to display 0 without updating it: sync it here.
      final cur = CurrentDisplayState.find(_peerId);
      if (cur.value != pi.currentDisplay) cur.value = pi.currentDisplay;
    }
    final epoch = ffi.ffiModel.peerInfoEpoch;
    if (epoch == _seenEpoch) return;
    if (!pi.isMacVirtualDisplaySupported || pi.displays.isEmpty) return;
    _seenEpoch = epoch;
    // let the first frame arrive before moving displays
    await Future.delayed(const Duration(milliseconds: 1500));
    if (!mounted || ffi.ffiModel.peerInfoEpoch != epoch) return;
    await MonitorProfile.applySaved(_peerId, ffi);
  }

  @override
  void dispose() {
    _watch?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.background,
      body: Stack(
        children: [
          _remotePage,
          SessionToolbar(peerId: _peerId, getFfi: () => _remotePage.ffi),
        ],
      ),
    );
  }

  /// Minimal subset of the engine's tab page multi-window handler: this
  /// window is single-session, so it only responds for ITS peer.
  Future<dynamic> _methodHandler(dynamic call, int fromWindowId) async {
    debugPrint('[client session] ${call.method} from window $fromWindowId');
    if (call.method == kWindowEventActiveSession) {
      if (call.arguments == _peerId) {
        windowOnTop(stateGlobal.windowId);
        return true;
      }
      return false;
    } else if (call.method == kWindowEventActiveDisplaySession) {
      // Dedup for openMonitorSession: if THIS window already shows that
      // (peer, display), bring it to front and return true — main won't create another window.
      final args = jsonDecode(call.arguments);
      if (args['id'] == _peerId &&
          args['display'] == _remotePage.ffi.ffiModel.pi.currentDisplay) {
        windowOnTop(stateGlobal.windowId);
        return true;
      }
      return false;
    } else if (call.method == kClientEventGetSessionDisplays) {
      // Another window's toolbar (via main) asks which display we're showing.
      if (call.arguments != _peerId) return null;
      return jsonEncode({
        'window_id': stateGlobal.windowId,
        'display': _remotePage.ffi.ffiModel.pi.currentDisplay,
      });
    } else if (call.method == kWindowEventGetSessionIdList) {
      return '$_peerId,${_remotePage.ffi.sessionId}';
    } else if (call.method == kWindowEventGetCachedSessionData) {
      // New window for the SAME peer (window-per-monitor): FFI.start asks
      // this window for the cached data (peer info, permissions) to build
      // its multi-UI session. Without this the new window stays black and without pi.
      final args = jsonDecode(call.arguments);
      if (args['id'] != _peerId) return null;
      try {
        return _remotePage.ffi.ffiModel.cachedPeerData.toString();
      } catch (e) {
        debugPrint('Failed to get cached session data: $e');
        return null;
      }
      // Note: args['close'] only applies when MOVING a tab to another window
      // (kWindowEventMoveTabToNewWindow), a flow this client doesn't use.
    } else if (call.method == 'onDestroy') {
      // Native window close (X button or kClientEventCloseWindow): close
      // the connection gracefully — without this the rust session stays
      // alive until the peer notices the dead TCP.
      await _remotePage.ffi.close();
    }
    return null;
  }
}
