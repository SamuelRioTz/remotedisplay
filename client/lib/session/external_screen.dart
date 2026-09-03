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

/// Monitor externo del iPad (iPadOS clásico, sin escenas): el Runner crea un
/// segundo FlutterEngine sobre la UIScreen externa con ruta `/extscreen`; ese
/// engine (OTRO isolate, MISMO runtime rust) se engancha a la conexión ya
/// abierta como segunda UI-session y muestra OTRO display remoto. Así la
/// pantalla del iPad y el monitor externo ven a la vez dos monitores del Mac.
///
/// Como en desktop: por defecto SOLO la vista principal — el monitor externo
/// se abre desde el menú Pantalla (botón por display), y se cierra igual.
///
/// Traspaso main-isolate → ext-isolate por local options (mismo patrón que el
/// trackpad de Android): peer, display y el CachedPeerData serializado.
const String kOptExtScreenPeer = 'remotedisplay-extscreen-peer';
const String kOptExtScreenDisplay = 'remotedisplay-extscreen-display';
const String kOptExtScreenCache = 'remotedisplay-extscreen-cache';

/// Canal del isolate PRINCIPAL con el Runner: attach/detach/setDisplay hacia
/// nativo; connected/disconnected desde nativo (conectar/quitar el monitor).
const kExtDisplayChannel = MethodChannel('remotedisplay/extdisplay');

/// Canal del isolate del monitor externo con el Runner: recibe setDisplay
/// (reenviado del principal) y dispose (antes de destruir el engine).
const kExtViewChannel = MethodChannel('remotedisplay/extview');

/// Vive en la sesión móvil (isolate principal). El usuario decide desde la
/// toolbar qué display remoto mandar al monitor externo (attach/detach); si
/// luego cambia la vista del iPad al display que está fuera, se intercambian
/// (swap) para que los dos monitores remotos sigan visibles.
class ExternalScreenController {
  ExternalScreenController({required this.peerId});

  final String peerId;

  /// Display remoto en el monitor externo; -1 = vista externa cerrada.
  final RxInt extDisplay = (-1).obs;

  /// Hay un monitor conectado al iPad (haya o no vista externa abierta).
  final RxBool screenConnected = false.obs;

  /// Aviso único por sesión: monitor presente y 2+ displays remotos — la
  /// sesión lo usa para el toast "abre el menú Pantalla".
  VoidCallback? onExternalAvailable;

  bool _attaching = false;
  bool _hintShown = false;
  int _lastMainDisplay = -1;

  // Reenvío del cursor al monitor externo (throttle ~60Hz). El host suprime
  // el eco de CursorPosition 300ms para la conexión que inyecta input
  // (run_pos, input_service.rs), así que la vista externa no puede fiarse de
  // los eventos del server: la posición autoritativa es la del cursorModel
  // del isolate principal.
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
      screenConnected.value = false; // canal no implementado (Android): off
    }
    _lastMainDisplay = gFFI.ffiModel.pi.currentDisplay;
    gFFI.cursorModel.addListener(_onCursorMoved);
    // El rect de cruce del cursor sigue SIEMPRE al display externo activo.
    _extWorker = ever(extDisplay, (_) => _updateCursorRect());
  }

  Worker? _extWorker;

  /// El display externo como rect global remoto → CursorModel.extraCursorRect
  /// (parche 13 del fork): el cursor puede cruzar el borde hacia el monitor.
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

  /// Llamar en cada cambio del ffiModel/imageModel de la sesión principal:
  /// resuelve el swap al cambiar de display en el iPad y el aviso inicial.
  Future<void> onSessionUpdate() async {
    _maybeHint();
    final current = gFFI.ffiModel.pi.currentDisplay;
    if (current == _lastMainDisplay || current == kAllDisplayValue) return;
    final prev = _lastMainDisplay;
    _lastMainDisplay = current;
    if (extDisplay.value >= 0) {
      if (current == extDisplay.value && prev >= 0) {
        // El iPad pasa a mostrar el display del monitor externo → swap.
        await setExternalDisplay(prev);
      }
      // El display del iPad pudo quedarse sin frames si ya estaba capturado
      // y el contenido es estático: pedir un keyframe.
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

  /// Abre la vista externa con [display] (botón de la toolbar); si ya está
  /// abierta, solo cambia el display que muestra.
  Future<void> attachDisplay(int display) async {
    if (!screenConnected.value || _attaching) return;
    if (extDisplay.value >= 0) {
      await setExternalDisplay(display);
      return;
    }
    final pi = gFFI.ffiModel.pi;
    if (display < 0 || display >= pi.displays.length) return;
    if (gFFI.ffiModel.waitForFirstImage.value) return; // sesión aún no lista
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

  /// Cambia qué display remoto muestra el monitor externo (ya abierto).
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

  /// Cierra la vista del monitor externo (botón ✕ de la toolbar). El monitor
  /// vuelve al espejo del sistema.
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

/// Raíz del isolate del monitor externo: segunda UI-session (view-only) de la
/// conexión existente mostrando el display publicado en las local options.
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

  // Cursor remoto sobre este display (posición global remota, reenviada por
  // el isolate principal vía nativo — ver ExternalScreenController).
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
    // gFFI de ESTE isolate (sessionId propio, distinto del de la sesión del
    // iPad). tabWindowId=-1: camino "sesión existente" de FFI.start
    // (sessionAddExistedSync + sessionStartWithDisplays) sin ventana origen —
    // los datos cacheados llegan por getCachedSessionData (parche del fork).
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
    // isDesktop=false → rama móvil parcheada del engine: une los displays de
    // las otras ui-sessions en vez del set exclusivo (no corta al iPad).
    bind.sessionSwitchDisplay(
      isDesktop: false,
      sessionId: ffi.sessionId,
      value: Int32List.fromList([display]),
    );
    ffi.ffiModel.switchToNewDisplay(display, ffi.sessionId, ffi.id);
    // Contenido estático: sin esto no llega ni un frame hasta que algo cambie.
    bind.sessionRefresh(sessionId: ffi.sessionId, display: display);
    setState(() => _display = display);
  }

  /// Pill de sesión del monitor externo — mismos códigos visuales que la
  /// SessionToolbar (grafito, borde tenue, radios suaves). Informativa: en
  /// esta pantalla no hay input (el control sigue en el iPad).
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
          // Cursor remoto cuando está sobre ESTE display (cruzó el borde
          // desde el iPad, o lo movieron en el host).
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
      // BlockableOverlay: overlay real para el dialogManager de esta sesión
      // (waiting-for-image, msgbox del engine) — mismo patrón que RemotePage.
      body: BlockableOverlay(
        underlying: Container(color: Colors.black, child: body),
        state: _overlayState,
      ),
    );
  }
}

/// Dibuja el cursor remoto sobre el vídeo del monitor externo, replicando la
/// transformación del FittedBox (contain + centrado). [pos] viene en coords
/// globales remotas; solo se pinta si cae dentro de [displayRect].
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
      // Sin shape aún: flecha simple blanca con borde negro.
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
