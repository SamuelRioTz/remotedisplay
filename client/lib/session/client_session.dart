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

/// Ventana de sesión propia: UNA conexión por ventana, sin tabs de RustDesk y
/// con la toolbar minimalista del client. Reemplaza a DesktopRemoteScreen +
/// ConnectionTabPage; la plomería (RemotePage: render, input, clipboard) se
/// reusa intacta de flutter_hbb.
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
    // Perfil de monitores POR CLIENTE: solo la ventana principal del peer (las
    // ventanas por-monitor traen `display`) aplica el perfil guardado cada vez
    // que el server anuncia un PeerInfo (conexión inicial y reconexiones, p.ej.
    // tras un reinicio del server que perdió los virtuales).
    if (params['display'] == null) {
      _watch = Timer.periodic(const Duration(milliseconds: 500), (_) => _tick());
    }
  }

  Timer? _watch;
  int _seenEpoch = 0;
  int? _titledDisplay;

  Future<void> _tick() async {
    if (!mounted) return;
    final ffi = _remotePage.ffi;
    final pi = ffi.ffiModel.pi;
    // Título de la ventana siempre acorde al display que se muestra (el
    // engine puede cambiarlo solo: p.ej. desaparece el virtual que se veía).
    if (isDesktop &&
        pi.displays.isNotEmpty &&
        _titledDisplay != pi.currentDisplay) {
      _titledDisplay = pi.currentDisplay;
      WindowController.fromWindowId(stateGlobal.windowId)
          .setTitle(sessionWindowTitle(_peerId, pi.currentDisplay));
      // El radio del menú lee CurrentDisplayState; tras una reconexión el
      // engine vuelve al display 0 sin actualizarlo: sincronizarlo acá.
      final cur = CurrentDisplayState.find(_peerId);
      if (cur.value != pi.currentDisplay) cur.value = pi.currentDisplay;
    }
    final epoch = ffi.ffiModel.peerInfoEpoch;
    if (epoch == _seenEpoch) return;
    if (!pi.isMacVirtualDisplaySupported || pi.displays.isEmpty) return;
    _seenEpoch = epoch;
    // dejar que llegue el primer frame antes de mover displays
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

  /// Subconjunto mínimo del handler multiventana del tab page del engine:
  /// esta ventana es single-sesión, así que solo responde por SU peer.
  Future<dynamic> _methodHandler(dynamic call, int fromWindowId) async {
    debugPrint('[client session] ${call.method} from window $fromWindowId');
    if (call.method == kWindowEventActiveSession) {
      if (call.arguments == _peerId) {
        windowOnTop(stateGlobal.windowId);
        return true;
      }
      return false;
    } else if (call.method == kWindowEventActiveDisplaySession) {
      // Dedup de openMonitorSession: si ESTA ventana ya muestra ese
      // (peer, display), al frente y true — el main no crea otra ventana.
      final args = jsonDecode(call.arguments);
      if (args['id'] == _peerId &&
          args['display'] == _remotePage.ffi.ffiModel.pi.currentDisplay) {
        windowOnTop(stateGlobal.windowId);
        return true;
      }
      return false;
    } else if (call.method == kClientEventGetSessionDisplays) {
      // La toolbar de otra ventana (vía main) pregunta qué display mostramos.
      if (call.arguments != _peerId) return null;
      return jsonEncode({
        'window_id': stateGlobal.windowId,
        'display': _remotePage.ffi.ffiModel.pi.currentDisplay,
      });
    } else if (call.method == kWindowEventGetSessionIdList) {
      return '$_peerId,${_remotePage.ffi.sessionId}';
    } else if (call.method == kWindowEventGetCachedSessionData) {
      // Ventana nueva del MISMO peer (ventana-por-monitor): FFI.start le pide
      // a esta ventana los datos cacheados (peer info, permisos) para armar
      // su sesión multi-UI. Sin esto la ventana nueva queda negra y sin pi.
      final args = jsonDecode(call.arguments);
      if (args['id'] != _peerId) return null;
      try {
        return _remotePage.ffi.ffiModel.cachedPeerData.toString();
      } catch (e) {
        debugPrint('Failed to get cached session data: $e');
        return null;
      }
      // Nota: args['close'] solo aplica al MOVER un tab a otra ventana
      // (kWindowEventMoveTabToNewWindow), flujo que este cliente no usa.
    } else if (call.method == 'onDestroy') {
      // Cierre nativo de la ventana (botón X o kClientEventCloseWindow):
      // cerrar la conexión con gracia — sin esto la sesión rust queda viva
      // hasta que el peer note el TCP muerto.
      await _remotePage.ffi.close();
    }
    return null;
  }
}
