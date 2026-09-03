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

/// Sensibilidad de los deltas GCMouse → píxeles remotos (captura de puntero).
const _kPointerCaptureSpeed = 2.0;

/// Sesión en Android/iOS — el equivalente de ClientRemoteScreen (desktop):
/// la RemotePage MÓVIL del engine (render, gestos táctiles, teclado virtual,
/// clipboard) con su barra oculta (parche 03 del fork: `showToolbar`) y
/// NUESTRA SessionToolbar encima. Es una ruta normal del Navigator: al cerrar
/// la conexión (toolbar o botón atrás → clientClose) vuelve a la home.
class MobileSessionScreen extends StatefulWidget {
  const MobileSessionScreen({super.key, required this.id, this.password});

  final String id;
  final String? password;

  @override
  State<MobileSessionScreen> createState() => _MobileSessionScreenState();
}

class _MobileSessionScreenState extends State<MobileSessionScreen> {
  final _controller = MobileRemotePageController();
  // Con trackpad/mouse (iPad, Android): ocultar el puntero LOCAL sobre el
  // canvas remoto — el engine ya dibuja el cursor del equipo remoto, si no
  // se ven dos. Persistente; toggle en Entrada → Cursor y teclas.
  late final ValueNotifier<bool> _hideLocalPointer =
      ValueNotifier(bind.mainGetLocalOption(key: kOptHideLocalPointer) != 'N');

  // iPad: captura del puntero (relativo, cruza monitores). Ver
  // kOptPointerCapture. La captura efectiva se suelta mientras haya un menú
  // o popup abierto (para poder usarlos con el trackpad) y en dispose.
  // OJO: default APAGADO (opt-in). En el iPad real el lock enganchaba pero
  // GCMouse no entregaba deltas → puntero invisible y muerto; hasta cazar la
  // causa (ver fila de diagnóstico en Entrada), el puntero absoluto de
  // siempre es el comportamiento por defecto.
  late final ValueNotifier<bool> _pointerCapture =
      ValueNotifier(bind.mainGetLocalOption(key: kOptPointerCapture) == 'Y');
  bool _captureToastShown = false;

  Future<dynamic> _onPointerChannelCall(MethodCall call) async {
    switch (call.method) {
      case 'lockState':
        // El sistema enganchó/soltó el pointer lock de verdad (no solo lo
        // pedimos).
        final locked = (call.arguments as Map)['locked'] == true;
        if (locked) {
          // Recentrar: si el cursor quedó fuera del display visible (o en el
          // sentinel inicial -10000), un movimiento nulo lo clampa adentro —
          // que el primer deslizamiento se VEA.
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
        // Llegan pasos ENTEROS de rueda (la conversión px→pasos vive en el
        // nativo, que conoce los límites de cada gesto — notch mínimo ±1).
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

  // iOS: Flutter no implementa MouseRegion.cursor en iPadOS → el Runner oculta
  // el puntero con UIPointerInteraction; le mandamos si ocultar y dónde NO
  // (la pill y, mientras está abierto, todo mientras haya un menú).
  static const _pointerChannel = MethodChannel('remotedisplay/pointer');
  Rect? _pillRect;
  bool _menuOpen = false;

  // iPad + monitor externo: la vista externa muestra "el otro" display remoto
  // (segundo engine sobre la UIScreen externa). Solo iOS: en Android el modo
  // escritorio ya reparte pantallas vía DeX/trackpad.
  ExternalScreenController? _extScreen;

  void _syncNativePointer() {
    if (!isIOS) return;
    // Con un popup abierto el puntero SIEMPRE visible (los diálogos se
    // renderizan sobre el canvas, donde normalmente lo ocultamos).
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
    // Captura del puntero: activa durante la sesión salvo con menú/popup
    // abierto (ahí el trackpad vuelve a controlar el puntero de iPadOS).
    final capture = _pointerCapture.value && !_menuOpen && !dialogOpen;
    // Con captura, el engine ignora los eventos de mouse físico: iPadOS
    // entrega los clicks del trackpad TAMBIÉN como touches aunque el puntero
    // esté bloqueado, y duplicaban el click que entra por GCMouse (parche 14).
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
      // Deltas/botones/rueda del trackpad capturado (GCMouse, vía Runner).
      _pointerChannel.setMethodCallHandler(_onPointerChannelCall);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncNativePointer());
    // iOS: re-sincronizar el puntero nativo cuando aparece/desaparece un popup.
    if (isIOS) {
      _dialogWorker = ever(gFFI.dialogManager.visibleDialogCount,
          (_) => _syncNativePointer());
    }
    // Publicar la sesión para la TrackpadActivity (teléfono = trackpad
    // mientras la sesión corre en el monitor externo; solo Android).
    if (isAndroid) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        bind.mainSetLocalOption(
            key: kOptTrackpadSession, value: gFFI.sessionId.toString());
      });
    }
    if (isIOS) {
      final ext = ExternalScreenController(peerId: widget.id);
      _extScreen = ext;
      // Aviso único cuando hay monitor + 2 displays remotos (el externo se
      // abre a mano desde el menú Pantalla, como en desktop).
      ext.onExternalAvailable = () =>
          showToast('External display detected — open the Display menu');
      // El swap y el aviso dependen del estado de la sesión: el ffiModel
      // notifica los cambios (peer info, switch de display) pero calla tras
      // el primer frame — el imageModel notifica por frame y cubre ese hueco
      // (onSessionUpdate corta en seco si no hay nada que hacer, así que el
      // costo por frame es un par de comparaciones).
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
      // El teclado virtual empuja el body: la pill queda visible sobre él.
      resizeToAvoidBottomInset: true,
      body: Stack(
        children: [
          ValueListenableBuilder<bool>(
            valueListenable: _hideLocalPointer,
            // Obx: si hay un popup del engine abierto, el puntero local se
            // muestra aunque esté oculto sobre el canvas (Android; en iOS lo
            // hace _syncNativePointer con el mismo observable).
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
            // OLED: negro TOTAL alrededor del canvas. El Scaffold del
            // RemotePage del engine no fija backgroundColor y hereda
            // scaffoldBackgroundColor del theme (blanco/grafito #18191E):
            // las franjas del SafeArea alrededor del video se veían grises.
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
            getFfi: () => gFFI, // en móvil el engine usa la sesión global
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
