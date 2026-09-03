import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show SystemChrome, SystemUiMode, SystemUiOverlay;
import 'package:flutter_hbb/common.dart'
    show
        closeConnection,
        isAndroid,
        isDesktop,
        isIOS,
        openMonitorInNewTabOrWindow,
        openMonitorInTheSameTab,
        translate;
import 'package:flutter_hbb/common/shared_state.dart';
import 'package:flutter_hbb/common/widgets/toolbar.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/mobile/pages/remote_page.dart'
    show MobileRemotePageController;
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart' show bind;
import 'package:flutter_hbb/models/state_model.dart';
import 'package:get/get.dart';

import 'external_screen.dart';
import 'monitor_profile.dart';
import 'trackpad_screen.dart';
import 'win_events.dart';

/// Toolbar de sesión propia — pill flotante inferior, minimalista.
/// Reemplaza a la RemoteToolbar de RustDesk (suprimida vía showToolbar: false)
/// reusando la plomería del engine (toolbarImageQuality/Codec/Cursor/...) sin
/// su UI. Misma pill en desktop y móvil, organizada por intención:
///
///   ‹ · peer · [minimizar] · pantalla completa · ajustar · Entrada · Pantalla · ✕
///
/// - **Entrada**: cómo interactúo — modo táctil/cursor y solo-ver (móvil),
///   teclado virtual y barra de teclas (independientes entre sí, móvil),
///   opciones de cursor/teclas y de sesión (audio, portapapeles, bloqueo).
/// - **Pantalla**: qué veo — monitor, vista, calidad,
///   códec e imagen (true color, monitor de calidad, multi-monitor).
/// Opción local: ocultar el puntero del trackpad/mouse sobre el canvas remoto
/// (móvil). Default: oculto.
const kOptHideLocalPointer = 'remotedisplay-hide-local-pointer';

/// Opción local (iPad): capturar el puntero del trackpad/mouse durante la
/// sesión (pointer lock + deltas GCMouse). El puntero absoluto de iPadOS se
/// clava en los bordes de la pantalla y deja de emitir eventos — capturado,
/// el cursor remoto se mueve RELATIVO, cruza al monitor externo y no se pega
/// en las esquinas. Default: activado (solo actúa si hay trackpad/mouse).
/// Con la captura activa la pill y los menús se usan con el dedo; al abrir
/// un menú o popup la captura se suelta sola y vuelve al cerrarlo.
const kOptPointerCapture = 'remotedisplay-pointer-capture';

class SessionToolbar extends StatefulWidget {
  const SessionToolbar(
      {super.key,
      required this.peerId,
      required this.getFfi,
      this.mobile,
      this.externalScreen,
      this.hideLocalPointer,
      this.pointerCapture,
      this.onPointerUi});

  final String peerId;
  final FFI Function() getFfi;

  /// Acciones internas de la RemotePage móvil del engine (solo en móvil).
  final MobileRemotePageController? mobile;

  /// Monitor externo del iPad (iOS): qué display remoto muestra y cambiarlo.
  final ExternalScreenController? externalScreen;

  /// Estado "ocultar puntero local" de la sesión móvil (lo aplica la pantalla).
  final ValueNotifier<bool>? hideLocalPointer;

  /// Estado "capturar puntero" (iPad: relativo + cruce de monitores; lo
  /// aplica la sesión móvil vía pointer lock nativo).
  final ValueNotifier<bool>? pointerCapture;

  /// Geometría de la pill y si hay un menú abierto (zonas donde el puntero
  /// local debe verse aunque esté oculto sobre el canvas; iOS nativo).
  final void Function(Rect? pill, bool menuOpen)? onPointerUi;

  @override
  State<SessionToolbar> createState() => _SessionToolbarState();
}

class _SessionToolbarState extends State<SessionToolbar> {
  bool _hover = false;
  bool _collapsed = false;
  // Móvil: pantalla completa = sin barra de estado ni de navegación del
  // sistema (el engine arranca la sesión así). Persistente.
  bool _mobileFullscreen = true;

  // Preferencias propias del cliente (opciones locales del engine, globales
  // al dispositivo). Lo demás — códec, calidad, vista, toggles de cursor y de
  // sesión — ya lo persiste el engine por peer; el modo táctil lo persiste el
  // engine en kOptionTouchMode y lo lee al abrir sesión.
  static const _optKeyHelpBar = 'remotedisplay-key-help-bar';
  static const _optMobileFullscreen = 'remotedisplay-mobile-fullscreen';

  @override
  void initState() {
    super.initState();
    if (!isDesktop) {
      _mobileFullscreen =
          bind.mainGetLocalOption(key: _optMobileFullscreen) != 'N';
      final barOn = bind.mainGetLocalOption(key: _optKeyHelpBar) == 'Y';
      // Aplicar tras el primer frame: la RemotePage del engine ya montó y
      // registró sus callbacks en el controller.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // La barra de teclas SOLO obedece a su toggle (nunca al teclado).
        widget.mobile?.setKeyHelpOverride?.call(barOn);
        if (!_mobileFullscreen) {
          SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual,
              overlays: SystemUiOverlay.values);
        }
      });
    }
  }

  static const _bg = Color(0xE61A1D24); // grafito translúcido
  static const _fg = Color(0xFFB8BDC7);
  static const _fgDim = Color(0xFF6A7280);
  static const _danger = Color(0xFFE5484D);

  FFI get _ffi => widget.getFfi();

  final _pillKey = GlobalKey();
  Rect? _lastPill;
  bool _menuOpen = false;

  void _reportPointerUi() {
    if (widget.onPointerUi == null) return;
    final box = _pillKey.currentContext?.findRenderObject() as RenderBox?;
    Rect? rect;
    if (box != null && box.hasSize) {
      final o = box.localToGlobal(Offset.zero);
      rect = Rect.fromLTWH(o.dx, o.dy, box.size.width, box.size.height);
    }
    if (rect != _lastPill) {
      _lastPill = rect;
      widget.onPointerUi!(rect, _menuOpen);
    }
  }

  void _setMenuOpen(bool v) {
    _menuOpen = v;
    widget.onPointerUi?.call(_lastPill, v);
  }

  @override
  Widget build(BuildContext context) {
    // Táctil: no hay hover → la pill queda siempre visible (algo atenuada).
    final opacity = isDesktop ? (_hover ? 1.0 : 0.35) : 0.9;
    WidgetsBinding.instance.addPostFrameCallback((_) => _reportPointerUi());
    return SafeArea(
      child: Align(
        alignment: Alignment.bottomLeft,
        child: Padding(
          padding: const EdgeInsets.only(left: 16, bottom: 16),
          child: MouseRegion(
            onEnter: (_) => setState(() => _hover = true),
            onExit: (_) => setState(() => _hover = false),
            child: AnimatedOpacity(
              opacity: opacity,
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              child: Container(
                key: _pillKey,
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                decoration: BoxDecoration(
                  color: _bg,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0x14FFFFFF)),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x66000000),
                      blurRadius: 24,
                      offset: Offset(0, 8),
                    ),
                  ],
                ),
                child: AnimatedSize(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.centerLeft,
                  child: _collapsed ? _collapsedContent() : _expandedContent(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Pill colapsado: solo el botón para re-expandir.
  Widget _collapsedContent() => _iconBtn(Icons.chevron_right_rounded,
      'Show toolbar', (_) => setState(() => _collapsed = false));

  Widget _expandedContent() => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _iconBtn(Icons.chevron_left_rounded, 'Hide toolbar',
              (_) => setState(() => _collapsed = true),
              color: _fgDim),
          _peerChip(),
          _divider(),
          if (isDesktop) ...[
            _iconBtn(
                Icons.minimize_rounded,
                'Minimize',
                (_) => WindowController.fromWindowId(stateGlobal.windowId)
                    .minimize()),
            Obx(() => _iconBtn(
                  stateGlobal.fullscreen.isTrue
                      ? Icons.fullscreen_exit_rounded
                      : Icons.fullscreen_rounded,
                  stateGlobal.fullscreen.isTrue
                      ? 'Exit full screen'
                      : 'Full screen',
                  (_) =>
                      stateGlobal.setFullscreen(!stateGlobal.fullscreen.value),
                )),
          ] else
            _iconBtn(
              _mobileFullscreen
                  ? Icons.fullscreen_exit_rounded
                  : Icons.fullscreen_rounded,
              _mobileFullscreen ? 'Exit full screen' : 'Full screen',
              (_) {
                _mobileFullscreen = !_mobileFullscreen;
                SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual,
                    overlays: _mobileFullscreen ? [] : SystemUiOverlay.values);
                bind.mainSetLocalOption(
                    key: _optMobileFullscreen,
                    value: _mobileFullscreen ? 'Y' : 'N');
                setState(() {});
              },
            ),
          _iconBtn(
              Icons.fit_screen_rounded, 'Fit to screen', (_) => _fitScreen()),
          _iconBtn(Icons.keyboard_alt_outlined, 'Input', _showInputMenu),
          _iconBtn(Icons.desktop_windows_outlined, 'Display', _showDisplayMenu),
          _divider(),
          _iconBtn(Icons.close_rounded, 'Disconnect', (_) => _disconnect(),
              color: _danger),
        ],
      );

  Widget _peerChip() => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Text(
          widget.peerId,
          style: const TextStyle(
            color: _fgDim,
            fontSize: 12,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.2,
          ),
        ),
      );

  Widget _divider() => Container(
        width: 1,
        height: 18,
        margin: const EdgeInsets.symmetric(horizontal: 4),
        color: const Color(0x14FFFFFF),
      );

  /// Botón del pill. [onTap] recibe el BuildContext DEL BOTÓN para que los
  /// menús puedan anclarse a él (el context del toolbar es un Align que
  /// ocupa toda la ventana → el menú saldría arriba de todo).
  Widget _iconBtn(
          IconData icon, String tooltip, void Function(BuildContext) onTap,
          {Color color = _fg}) =>
      Builder(
        builder: (btnContext) => Tooltip(
          message: tooltip,
          waitDuration: const Duration(milliseconds: 400),
          child: InkWell(
            onTap: () => onTap(btnContext),
            borderRadius: BorderRadius.circular(10),
            hoverColor: const Color(0x14FFFFFF),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Icon(icon, size: 18, color: color),
            ),
          ),
        ),
      );

  // ── menús ────────────────────────────────────────────────────────────────

  /// Despliega [items] como popup justo ENCIMA del botón [anchor], con la
  /// estética del pill. Si no entra, el PopupMenu hace scroll solo.
  Future<void> _showItemsMenu(
      BuildContext anchor, List<PopupMenuEntry<void>> items) async {
    if (!mounted || !anchor.mounted || items.isEmpty) return;
    final box = anchor.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(anchor).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;
    final origin = box.localToGlobal(Offset.zero, ancestor: overlay);
    final estHeight = items.fold<double>(16, (h, e) => h + e.height);
    final top = (origin.dy - estHeight - 6).clamp(0.0, overlay.size.height);
    _setMenuOpen(true);
    await showMenu<void>(
      context: anchor,
      color: _bg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0x14FFFFFF)),
      ),
      // 420: la fila de MONITORS (radio+icono+nombre+badge+resolución+abrir+
      // switch/basurero) necesita ~400 px para no partir la resolución.
      constraints: const BoxConstraints(minWidth: 260, maxWidth: 440),
      position: RelativeRect.fromLTRB(
        origin.dx,
        top,
        overlay.size.width - origin.dx - box.size.width,
        overlay.size.height - origin.dy + 6,
      ),
      items: items,
    );
    _setMenuOpen(false);
  }

  /// Título de sección dentro de un menú.
  PopupMenuEntry<void> _header(String text) => PopupMenuItem<void>(
        enabled: false,
        height: 26,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Text(text,
            style: const TextStyle(
                color: _fgDim,
                fontSize: 10,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.2)),
      );

  PopupMenuEntry<void> _sep() => const PopupMenuDivider(height: 8);

  /// Fila estándar: indicador (radio/check) + texto (+ detalle a la derecha).
  Widget _menuRow(bool selected, Widget label,
      {String? detail, IconData? onIcon, IconData? offIcon}) {
    return Row(
      children: [
        Icon(
          selected
              ? (onIcon ?? Icons.radio_button_checked_rounded)
              : (offIcon ?? Icons.radio_button_off_rounded),
          size: 16,
          color: selected ? Colors.white : _fgDim,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: DefaultTextStyle(
            style: TextStyle(
              color: selected ? Colors.white : _fg,
              fontSize: 13,
            ),
            child: label,
          ),
        ),
        if (detail != null) ...[
          const SizedBox(width: 16),
          Text(detail, style: const TextStyle(color: _fgDim, fontSize: 11)),
        ],
      ],
    );
  }

  PopupMenuEntry<void> _radio(bool selected, Widget label, VoidCallback onTap,
          {String? detail, IconData? onIcon, IconData? offIcon}) =>
      PopupMenuItem<void>(
        height: 40,
        onTap: onTap,
        child: _menuRow(selected, label,
            detail: detail, onIcon: onIcon, offIcon: offIcon),
      );

  /// Fila de display: radio (cambia el monitor de ESTA ventana) + botón
  /// contextual a la derecha (abrir ese display en ventana nueva, o cerrar
  /// la ventana que ya lo muestra).
  PopupMenuEntry<void> _displayRow(
    bool selected,
    String label,
    VoidCallback onTap, {
    String? detail,
    IconData? trailingIcon,
    String? trailingTooltip,
    VoidCallback? onTrailing,
  }) =>
      PopupMenuItem<void>(
        height: 40,
        onTap: onTap,
        child: Row(
          children: [
            Expanded(
              child: _menuRow(selected, Text(label),
                  detail: detail,
                  onIcon: Icons.desktop_windows_rounded,
                  offIcon: Icons.desktop_windows_outlined),
            ),
            if (trailingIcon != null)
              Builder(
                // context DEL ítem: para cerrar el menú antes de actuar.
                builder: (itemCtx) => Tooltip(
                  message: trailingTooltip ?? '',
                  waitDuration: const Duration(milliseconds: 400),
                  child: InkWell(
                    onTap: () {
                      Navigator.pop(itemCtx);
                      onTrailing?.call();
                    },
                    borderRadius: BorderRadius.circular(8),
                    hoverColor: const Color(0x14FFFFFF),
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Icon(trailingIcon, size: 16, color: _fg),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );

  /// Pide al main qué displays de este peer están visibles en OTRAS ventanas
  /// (display → windowId). Ante cualquier fallo: vacío — los botones de abrir
  /// simplemente aparecen y el dedup de openMonitorSession resuelve.
  Future<Map<int, int>> _queryOtherOpenDisplays() async {
    try {
      final res = await DesktopMultiWindow.invokeMethod(
              kMainWindowId, kClientEventQueryOpenDisplays, widget.peerId)
          .timeout(const Duration(seconds: 2));
      if (res is String && res.isNotEmpty) {
        return {
          for (final e in jsonDecode(res) as List)
            if (e['window_id'] != stateGlobal.windowId)
              (e['display'] as int): (e['window_id'] as int)
        };
      }
    } catch (e) {
      debugPrint('[toolbar] query open displays failed: $e');
    }
    return {};
  }

  /// Tras eliminar el monitor virtual que se estaba viendo, el engine cambia
  /// solo al que queda pero el título de la ventana no se entera: esperar a
  /// que ese display salga de la lista y reflejar el actual.
  Future<void> _retitleWhenDisplayGone(int mid) async {
    for (var attempt = 0; attempt < 40; attempt++) {
      await Future.delayed(const Duration(milliseconds: 100));
      if (!mounted) return;
      if (!_ffi.ffiModel.pi.macDisplayIds.contains(mid)) break;
    }
    if (!mounted) return;
    _setWindowTitleForDisplay(CurrentDisplayState.find(widget.peerId).value);
  }

  /// Refleja en el título de la ventana qué display muestra.
  void _setWindowTitleForDisplay(int display) {
    if (!isDesktop) return;
    WindowController.fromWindowId(stateGlobal.windowId)
        .setTitle(sessionWindowTitle(widget.peerId, display));
  }

  PopupMenuEntry<void> _check(bool value, Widget label, VoidCallback onTap,
          {String? detail}) =>
      PopupMenuItem<void>(
        height: 40,
        onTap: onTap,
        child: _menuRow(value, label,
            detail: detail,
            onIcon: Icons.check_box_rounded,
            offIcon: Icons.check_box_outline_blank_rounded),
      );

  /// Fila unificada de monitor (macOS): combina selección (cuál se ve),
  /// indicador físico/virtual, resolución, abrir/cerrar en otra ventana y
  /// switch on/off o basurero — así no hay una lista "Displays" y otra
  /// "Monitors" para el mismo conjunto. Tap en la fila = ver ese monitor acá;
  /// el switch apaga un físico (espejo); el basurero destruye un virtual.
  PopupMenuEntry<void> _monitorRow({
    required String label,
    required bool isVirtual,
    required bool isOn,
    String? detail,
    bool isCurrent = false,
    VoidCallback? onSelect,
    ValueChanged<bool>? onToggle,
    VoidCallback? onDelete,
    bool openSlot = false,
    IconData? openIcon,
    String? openTooltip,
    VoidCallback? onOpen,
    VoidCallback? onDetailTap,
  }) =>
      PopupMenuItem<void>(
        height: 44,
        onTap: onSelect,
        // Columnas de ancho fijo para que todas las filas alineen (simétricas).
        child: Row(
          children: [
            // Indicador de "viendo este monitor" (relleno si es el actual).
            Icon(
              isCurrent
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_off_rounded,
              size: 16,
              color: isCurrent ? const Color(0xFF6FC0FF) : _fgDim,
            ),
            const SizedBox(width: 10),
            Icon(
              isVirtual
                  ? Icons.cast_connected_rounded
                  : Icons.desktop_windows_rounded,
              size: 16,
              color: isOn ? Colors.white : _fgDim,
            ),
            const SizedBox(width: 8),
            // Nombre — ancho fijo.
            SizedBox(
              width: 74,
              child: Text(label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: isOn ? Colors.white : _fg, fontSize: 13)),
            ),
            // Badge físico/virtual — ancho fijo, alineado a la izquierda.
            SizedBox(
              width: 62,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: isVirtual
                        ? const Color(0x2233AAFF)
                        : const Color(0x22FFFFFF),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(isVirtual ? 'virtual' : 'physical',
                      style: TextStyle(
                          color:
                              isVirtual ? const Color(0xFF6FC0FF) : _fgDim,
                          fontSize: 10,
                          fontWeight: FontWeight.w600)),
                ),
              ),
            ),
            // Resolución — alineada a la derecha. En los virtuales es clickeable:
            // abre el selector de escala (100/125/150/200 %).
            Expanded(
              child: onDetailTap == null
                  ? Text(detail ?? '',
                      textAlign: TextAlign.right,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: _fgDim, fontSize: 11))
                  : Align(
                      alignment: Alignment.centerRight,
                      child: Builder(
                        builder: (itemCtx) => Tooltip(
                          message: 'Scale',
                          waitDuration: const Duration(milliseconds: 400),
                          child: InkWell(
                            onTap: () {
                              Navigator.pop(itemCtx);
                              onDetailTap();
                            },
                            borderRadius: BorderRadius.circular(6),
                            hoverColor: const Color(0x14FFFFFF),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 4),
                              child: Text('${detail ?? ''} ▾',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      color: Color(0xFF6FC0FF), fontSize: 11)),
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
            const SizedBox(width: 8),
            // Abrir en ventana nueva / cerrar esa ventana. Columna fija para
            // que las filas sin acción (la que se está viendo) alineen igual.
            if (openSlot)
              SizedBox(
                width: 40,
                child: openIcon == null
                    ? null
                    : Builder(
                        builder: (itemCtx) => Tooltip(
                          message: openTooltip ?? '',
                          waitDuration: const Duration(milliseconds: 400),
                          child: InkWell(
                            onTap: onOpen == null
                                ? null
                                : () {
                                    Navigator.pop(itemCtx);
                                    onOpen();
                                  },
                            borderRadius: BorderRadius.circular(8),
                            hoverColor: const Color(0x14FFFFFF),
                            child: Padding(
                              padding: const EdgeInsets.all(8),
                              child: Icon(openIcon, size: 18, color: _fg),
                            ),
                          ),
                        ),
                      ),
              ),
            // Virtual: basurero (crear/eliminar). Físico: switch on/off (el
            // físico no se elimina, se apaga espejándolo sobre el principal).
            SizedBox(
              width: 40,
              child: isVirtual
                  ? Builder(
                      builder: (itemCtx) => Tooltip(
                        message: 'Remove virtual monitor',
                        waitDuration: const Duration(milliseconds: 400),
                        child: InkWell(
                          onTap: onDelete == null
                              ? null
                              : () {
                                  Navigator.pop(itemCtx);
                                  onDelete();
                                },
                          borderRadius: BorderRadius.circular(8),
                          hoverColor: const Color(0x22FF5555),
                          child: const Padding(
                            padding: EdgeInsets.all(8),
                            child: Icon(Icons.delete_outline_rounded,
                                size: 18, color: _danger),
                          ),
                        ),
                      ),
                    )
                  : Builder(
                      builder: (itemCtx) => Transform.scale(
                        scale: 0.7,
                        child: Switch(
                          value: isOn,
                          activeColor: const Color(0xFF6FC0FF),
                          onChanged: onToggle == null
                              ? null
                              : (v) {
                                  Navigator.pop(itemCtx);
                                  onToggle(v);
                                },
                        ),
                      ),
                    ),
            ),
          ],
        ),
      );

  Iterable<PopupMenuEntry<void>> _radios(List<TRadioMenu<String>> items) =>
      items.map((e) => _radio(
          e.value == e.groupValue, e.child, () => e.onChanged?.call(e.value)));

  Iterable<PopupMenuEntry<void>> _checks(List<TToggleMenu> items) => items
      .map((t) => _check(t.value, t.child, () => t.onChanged?.call(!t.value)));

  /// Texto de un ítem del engine (todos son `Text(translate(...))`).
  String _label(TToggleMenu t) {
    final c = t.child;
    return c is Text ? (c.data ?? '') : '';
  }

  /// Toggles del engine que hablan de la IMAGEN (van al menú Pantalla); el
  /// resto de toolbarDisplayToggle son de sesión (Entrada).
  bool _isImageToggle(TToggleMenu t) => {
        translate('True color (4:4:4)'),
        translate('Show quality monitor'),
        translate('Show displays as individual windows'),
        translate('Use all my displays for the remote session'),
      }.contains(_label(t));

  bool _isViewOnly(TToggleMenu t) => _label(t) == translate('View Mode');

  /// Menú **Entrada**: modo táctil/cursor, teclado y barra de teclas (móvil),
  /// opciones de cursor/teclas y de sesión.
  Future<void> _showInputMenu(BuildContext anchor) async {
    final ffi = _ffi;
    final id = widget.peerId;
    final cursor = await toolbarCursor(context, id, ffi);
    final keys = toolbarKeyboardToggles(ffi);
    final all = await toolbarDisplayToggle(context, id, ffi);
    // El engine repite los toggles de teclas al final de toolbarDisplayToggle
    // (móvil): no mostrarlos dos veces.
    final seen = {...cursor.map(_label), ...keys.map(_label)};
    final session = all
        .where((t) =>
            !_isImageToggle(t) && !_isViewOnly(t) && !seen.contains(_label(t)))
        .toList();
    final viewOnly = all.where(_isViewOnly).toList();
    final privacy =
        toolbarPrivacyMode(PrivacyModeState.find(id), context, id, ffi);
    if (!mounted) return;

    final items = <PopupMenuEntry<void>>[];
    if (!isDesktop) {
      final touch = ffi.ffiModel.touchMode;
      items.add(_header('MODE'));
      void setTouch(bool v) {
        if (ffi.ffiModel.touchMode != v) ffi.ffiModel.toggleTouchMode();
        // toggleTouchMode() no persiste; el engine lee esta opción al abrir.
        bind.mainSetLocalOption(key: kOptionTouchMode, value: v ? 'Y' : 'N');
      }

      items.add(_radio(
        touch,
        const Text('Touch — tap to click'),
        () => setTouch(true),
        onIcon: Icons.touch_app_rounded,
        offIcon: Icons.touch_app_outlined,
      ));
      items.add(_radio(
        !touch,
        const Text('Cursor — drag to move the pointer'),
        () => setTouch(false),
        onIcon: Icons.mouse_rounded,
        offIcon: Icons.mouse_outlined,
      ));
      items.addAll(_checks(viewOnly));

      items.add(_sep());
      items.add(_header('KEYBOARD'));
      final kbShown = (widget.mobile?.isKeyboardShown?.call() ?? false) ||
          MediaQuery.of(context).viewInsets.bottom > 0;
      items.add(_check(kbShown, const Text('Virtual keyboard'), () {
        if (kbShown) {
          widget.mobile?.hideKeyboard?.call();
        } else {
          widget.mobile?.openKeyboard?.call();
        }
      }));
      // Independiente del teclado: estado = SU toggle (override), no lo que
      // el engine mostraría automáticamente.
      final barOn = widget.mobile?.keyHelpOverride?.call() ?? false;
      items.add(
          _check(barOn, const Text('Key bar (Ctrl, Alt, Esc, arrows…)'), () {
        widget.mobile?.setKeyHelpOverride?.call(!barOn);
        bind.mainSetLocalOption(key: _optKeyHelpBar, value: barOn ? 'N' : 'Y');
      }));
      if (isAndroid) {
        // Modo escritorio (monitor externo): abre la TrackpadActivity en la
        // pantalla del teléfono — trackpad + teclado de esta sesión.
        items.add(_radio(
          false,
          const Text('Phone as trackpad & keyboard'),
          () => kTrackpadChannel.invokeMethod('open').catchError((_) {}),
          onIcon: Icons.touch_app_rounded,
          offIcon: Icons.mouse_outlined,
        ));
      }
    }
    final hidePtr = widget.hideLocalPointer;
    final capPtr = widget.pointerCapture;
    if (cursor.isNotEmpty || keys.isNotEmpty || hidePtr != null) {
      if (items.isNotEmpty) items.add(_sep());
      items.add(_header('CURSOR & KEYS'));
      if (isIOS && capPtr != null) {
        // Captura del trackpad: cursor relativo, cruza al monitor externo y
        // no se clava en los bordes (los menús se abren con el dedo).
        items.add(_check(
            capPtr.value, const Text('Capture trackpad (relative pointer)'),
            () {
          capPtr.value = !capPtr.value;
          bind.mainSetLocalOption(
              key: kOptPointerCapture, value: capPtr.value ? 'Y' : 'N');
        }));
      }
      if (hidePtr != null) {
        items.add(_check(hidePtr.value, const Text('Hide local pointer'), () {
          hidePtr.value = !hidePtr.value;
          bind.mainSetLocalOption(
              key: kOptHideLocalPointer, value: hidePtr.value ? 'Y' : 'N');
        }));
      }
      items.addAll(_checks(cursor));
      items.addAll(_checks(keys));
    }
    if (session.isNotEmpty || privacy.isNotEmpty) {
      if (items.isNotEmpty) items.add(_sep());
      items.add(_header('SESSION'));
      items.addAll(_checks(session));
      items.addAll(_checks(privacy));
    }
    await _showItemsMenu(anchor, items);
  }

  /// Menú **Pantalla**: ajustar, monitores, vista, calidad, códec e imagen.
  Future<void> _showDisplayMenu(BuildContext anchor) async {
    final ffi = _ffi;
    final id = widget.peerId;
    final styles = await toolbarViewStyle(context, id, ffi);
    final quality = await toolbarImageQuality(context, id, ffi);
    final codec = await toolbarCodec(context, id, ffi);
    final image =
        (await toolbarDisplayToggle(context, id, ffi)).where(_isImageToggle);
    // Qué displays de este peer ya se ven en OTRAS ventanas (display → win).
    final others = isDesktop ? await _queryOtherOpenDisplays() : <int, int>{};
    if (!mounted) return;

    final items = <PopupMenuEntry<void>>[];

    final pi = ffi.ffiModel.pi;
    final macMonitors =
        pi.platform == kPeerPlatformMacOS && pi.isMacVirtualDisplaySupported;
    final current = CurrentDisplayState.find(id).value;
    if (macMonitors) {
      // remotedisplay: UNA sola sección para macOS — "monitor" y "display" son lo
      // mismo, así que cada fila combina selección (cuál se ve), badge
      // físico/virtual, resolución y switch on/off. Sin listas duplicadas.
      final dispIds = pi.macDisplayIds; // alineado con pi.displays
      final virtuals = pi.macVirtualDisplays.toSet();
      final physicalOff = pi.macPhysicalOff;
      void toggle(int mid, bool on) {
        bind.sessionToggleVirtualDisplay(
            sessionId: ffi.sessionId, index: kMacRawDisplayIdBase + mid, on: on);
        MonitorProfile.scheduleSave(id, ffi); // perfil por cliente
      }
      items.add(_header('MONITORS'));
      for (var i = 0; i < pi.displays.length && i < dispIds.length; i++) {
        final mid = dispIds[i];
        final d = pi.displays[i];
        final isVirtual = virtuals.contains(mid);
        final isCurrent = current == i;
        final otherWin = others[i];
        // Virtual: mostrar pixeles equivalentes a 100 % (= tamaño de ventana) y
        // su escala; el tap en el detalle abre el selector de escala.
        final scale = isVirtual ? MonitorProfile.scaleOf(id, pi, mid) : 100;
        final px = isVirtual
            ? MonitorProfile.pixelSizeOf(pi, i, scale)
            : Size(d.width.toDouble(), d.height.toDouble());
        items.add(_monitorRow(
          // Numeración secuencial por posición: el ID interno de display de
          // macOS (mid) no es consecutivo y desconcierta ("Monitor 8").
          label: 'Monitor ${i + 1}',
          isVirtual: isVirtual,
          isOn: true,
          isCurrent: isCurrent,
          detail: '${px.width.toInt()}×${px.height.toInt()}'
              '${isVirtual ? ' · $scale%' : ''}'
              '${otherWin != null && !isVirtual ? ' · open' : ''}',
          onDetailTap: isVirtual ? () => _showScaleMenu(anchor, i, mid) : null,
          // Tap: verlo acá; si ya está en otra ventana, traer esa ventana
          // (para abrirlo en una ventana nueva está el icono ⧉).
          onSelect: otherWin != null
              ? () => openMonitorInNewTabOrWindow(i, id, pi)
              : isCurrent
                  ? null
                  : () {
                      openMonitorInTheSameTab(i, ffi, pi);
                      _setWindowTitleForDisplay(i);
                    },
          // Abrir este monitor en una ventana nueva (o cerrar la que ya lo
          // muestra). Columna fija: la fila actual la deja vacía.
          openSlot: isDesktop,
          openIcon: !isDesktop || isCurrent
              ? null
              : (otherWin != null
                  ? Icons.close_rounded
                  : Icons.open_in_new_rounded),
          openTooltip:
              otherWin != null ? 'Close its window' : 'Open in new window',
          onOpen: otherWin != null
              ? () => DesktopMultiWindow.invokeMethod(
                  kMainWindowId, kClientEventCloseWindow, otherWin)
              : () => openMonitorInNewTabOrWindow(i, id, pi),
          // Virtual → basurero (eliminar); físico → switch (apagar = espejo).
          onToggle: isVirtual ? null : (v) => toggle(mid, v),
          onDelete: isVirtual
              ? () {
                  // Si otra ventana lo muestra, cerrarla antes de destruirlo.
                  if (otherWin != null) {
                    DesktopMultiWindow.invokeMethod(
                        kMainWindowId, kClientEventCloseWindow, otherWin);
                  }
                  toggle(mid, false);
                  if (isCurrent) _retitleWhenDisplayGone(mid);
                }
              : null,
        ));
      }
      // Monitores físicos apagados (espejados): el switch los vuelve a prender.
      // Siguen la numeración después de los activos.
      var offN = pi.displays.length;
      for (final mid in physicalOff) {
        offN++;
        items.add(_monitorRow(
          label: 'Monitor $offN',
          isVirtual: false,
          isOn: false,
          detail: 'off',
          openSlot: isDesktop,
          onToggle: (v) => toggle(mid, v),
        ));
      }
      if (pi.isSupportMultiDisplay && pi.displays.length > 1) {
        items.add(_radio(
          current == kAllDisplayValue,
          const Text('All monitors'),
          () {
            openMonitorInTheSameTab(kAllDisplayValue, ffi, pi);
            _setWindowTitleForDisplay(kAllDisplayValue);
          },
          onIcon: Icons.grid_view_rounded,
          offIcon: Icons.grid_view_outlined,
        ));
      }
      // Crear un virtual con el tamaño ACTUAL de la ventana como default.
      items.add(_radio(false, const Text('Create virtual monitor'),
          () => _createVirtualMonitorAtWindowSize(),
          onIcon: Icons.add_circle_rounded,
          offIcon: Icons.add_circle_outline_rounded));
    } else if (pi.displays.length > 1) {
      // Otros peers (Windows/Linux/etc.): la sección DISPLAYS clásica, solo
      // para elegir qué monitor se ve.
      final ext = widget.externalScreen;
      final extConnected = ext?.screenConnected.value ?? false;
      final extDisplay = ext?.extDisplay.value ?? -1;
      items.add(_header('DISPLAYS'));
      for (var i = 0; i < pi.displays.length; i++) {
        final d = pi.displays[i];
        final otherWin = others[i];
        final isCurrent = current == i;
        final isExt = extDisplay == i;
        items.add(_displayRow(
          isCurrent,
          'Display ${i + 1}',
          () {
            if (otherWin != null) {
              openMonitorInNewTabOrWindow(i, id, pi);
            } else if (!isCurrent) {
              openMonitorInTheSameTab(i, ffi, pi);
              _setWindowTitleForDisplay(i);
            }
          },
          detail: '${d.width.toInt()}×${d.height.toInt()}'
              '${otherWin != null ? ' · open' : ''}'
              '${isExt ? ' · external' : ''}',
          trailingIcon: isDesktop
              ? (!isCurrent
                  ? (otherWin != null
                      ? Icons.close_rounded
                      : Icons.open_in_new_rounded)
                  : null)
              : (extConnected
                  ? (isExt
                      ? Icons.close_rounded
                      : (!isCurrent ? Icons.tv_rounded : null))
                  : null),
          trailingTooltip: isDesktop
              ? (otherWin != null ? 'Close its window' : 'Open in new window')
              : (isExt ? 'Stop external display' : 'Show on external display'),
          onTrailing: isDesktop
              ? (otherWin != null
                  ? () => DesktopMultiWindow.invokeMethod(
                      kMainWindowId, kClientEventCloseWindow, otherWin)
                  : () => openMonitorInNewTabOrWindow(i, id, pi))
              : (isExt ? () => ext?.detach() : () => ext?.attachDisplay(i)),
        ));
      }
      if (pi.isSupportMultiDisplay) {
        items.add(_radio(
          current == kAllDisplayValue,
          const Text('All displays'),
          () {
            openMonitorInTheSameTab(kAllDisplayValue, ffi, pi);
            _setWindowTitleForDisplay(kAllDisplayValue);
          },
          onIcon: Icons.grid_view_rounded,
          offIcon: Icons.grid_view_outlined,
        ));
      }
    }
    if (styles.isNotEmpty) {
      if (items.isNotEmpty) items.add(_sep());
      items.add(_header('VIEW'));
      items.addAll(_radios(styles));
    }
    if (quality.isNotEmpty) {
      items.add(_sep());
      items.add(_header('QUALITY'));
      items.addAll(_radios(quality));
    }
    if (codec.isNotEmpty) {
      items.add(_sep());
      items.add(_header('CODEC'));
      items.addAll(_radios(codec));
    }
    if (image.isNotEmpty) {
      items.add(_sep());
      items.add(_header('IMAGE'));
      items.addAll(_checks(image.toList()));
    }
    await _showItemsMenu(anchor, items);
  }

  /// Crea un monitor virtual y le pone como resolución inicial el tamaño ACTUAL
  /// de esta ventana. El server lo crea con un default; en cuanto el nuevo
  /// display aparece en la lista, se selecciona y se le aplica el tamaño de la
  /// ventana (que se capturó antes de crear).
  Future<void> _createVirtualMonitorAtWindowSize() async {
    final ffi = _ffi;
    final size = ffi.ffiModel.viewportSize;
    final dpr = _dpr;
    final scale = _defaultScale;
    final before = ffi.ffiModel.pi.macDisplayIds.toSet();
    bind.sessionToggleVirtualDisplay(
        sessionId: ffi.sessionId, index: 0, on: true);
    if (size == null) return;
    // pixeles FÍSICOS de la ventana; el spec deriva puntos y HiDPI de la escala
    final w = (size.width * dpr).round();
    final h = (size.height * dpr).round();
    if (w < 400 || h < 300) return;
    // Esperar (hasta ~4 s) a que el server anuncie el nuevo display.
    for (var attempt = 0; attempt < 40; attempt++) {
      await Future.delayed(const Duration(milliseconds: 100));
      final pi = ffi.ffiModel.pi;
      final ids = pi.macDisplayIds;
      final newMid = ids.firstWhere((m) => !before.contains(m), orElse: () => -1);
      if (newMid == -1) continue;
      final idx = ids.indexOf(newMid);
      if (idx < 0 || idx >= pi.displays.length) continue;
      // Verlo y ajustarlo al tamaño de la ventana con la escala del cliente.
      openMonitorInTheSameTab(idx, ffi, pi);
      _setWindowTitleForDisplay(idx);
      await Future.delayed(const Duration(milliseconds: 200));
      await MonitorProfile.applySpec(
          widget.peerId, ffi, newMid, VirtualSpec(w, h, scale));
      break;
    }
    MonitorProfile.scheduleSave(widget.peerId, ffi);
  }

  /// Vuelve a ver la pantalla remota completa: estilo "adaptive" (encaja en
  /// la ventana) y reset del canvas (deshace el zoom/pan del pinch en móvil
  /// o del scroll en desktop).
  ///
  /// remotedisplay: además es EL trigger de la resolución dinámica — si el
  /// display actual es virtual (macOS/IDD), su resolución se ajusta al tamaño
  /// de esta ventana. No es automático por cada resize: el usuario decide
  /// cuándo con este botón. En "All displays" no se toca nada (la guarda vive
  /// en applyDynamicResolution).
  Future<void> _fitScreen() async {
    final ffi = _ffi;
    await bind.sessionSetViewStyle(
        sessionId: ffi.sessionId, value: kRemoteViewStyleAdaptive);
    await ffi.canvasModel.updateViewStyle();
    ffi.canvasModel.reset();
    // dar un frame para que el canvas mida el nuevo tamaño antes de aplicar
    await Future.delayed(const Duration(milliseconds: 120));
    if (!mounted) return;
    final pi = ffi.ffiModel.pi;
    final macMonitors =
        pi.platform == kPeerPlatformMacOS && pi.isMacVirtualDisplaySupported;
    final current = CurrentDisplayState.find(widget.peerId).value;
    if (macMonitors &&
        current != kAllDisplayValue &&
        !ffi.ffiModel.isVirtualDisplayResolution) {
      // Caso 1: el monitor que se ve es FÍSICO y no se puede redimensionar a
      // gusto. "Ajustar" = volverlo dinámico: el server lo espeja sobre un
      // virtual que pasa a ser el principal y que sí sigue a la ventana.
      await _makePhysicalDynamicAndFit();
      MonitorProfile.scheduleSave(widget.peerId, ffi);
      return;
    }
    final mid = (current >= 0 && current < pi.macDisplayIds.length)
        ? pi.macDisplayIds[current]
        : -1;
    await ffi.ffiModel.applyDynamicResolution(
        scalePercent: mid >= 0 ? MonitorProfile.scaleOf(widget.peerId, pi, mid) : 100,
        devicePixelRatio: _dpr);
    MonitorProfile.scheduleSave(widget.peerId, ffi);
  }

  /// devicePixelRatio de ESTA ventana (pixeles físicos por pixel lógico).
  double get _dpr =>
      mounted ? MediaQuery.of(context).devicePixelRatio : 1.0;

  /// Escala por defecto para virtuales nuevos: la del cliente (como Windows).
  int get _defaultScale => snapScale(_dpr);

  /// Main dinámico (índice -2 del engine): el físico actual queda espejado
  /// sobre un virtual principal. Cuando el display que se ve pasa a ser
  /// virtual, se le aplica el tamaño de la ventana. Se deshace con el switch
  /// del físico (vuelve a ser principal) o con el basurero del virtual.
  Future<void> _makePhysicalDynamicAndFit() async {
    final ffi = _ffi;
    bind.sessionToggleVirtualDisplay(
        sessionId: ffi.sessionId, index: kMacDynamicMainIndex, on: true);
    // Esperar (hasta ~6 s) a que el server reemplace el físico por el virtual
    // en la lista de displays y esta ventana lo esté mostrando.
    for (var attempt = 0; attempt < 60; attempt++) {
      await Future.delayed(const Duration(milliseconds: 100));
      if (!mounted) return;
      if (ffi.ffiModel.isVirtualDisplayResolution) break;
    }
    if (!mounted || !ffi.ffiModel.isVirtualDisplayResolution) return;
    await Future.delayed(const Duration(milliseconds: 300));
    // Escala por defecto del cliente para el virtual principal dinámico.
    final pi = ffi.ffiModel.pi;
    final mid = pi.macDynamicMainId;
    final scale = _defaultScale;
    if (mid != 0 && scale > 100 && !pi.macHiDPIDisplays.contains(mid)) {
      bind.sessionToggleVirtualDisplay(
          sessionId: ffi.sessionId, index: kMacHiDPIIndexBase + mid, on: true);
      await MonitorProfile.waitFor(
          () => ffi.ffiModel.pi.macHiDPIDisplays.contains(mid), 6000);
      await Future.delayed(const Duration(milliseconds: 300));
    }
    if (mid != 0) MonitorProfile.rememberScale(widget.peerId, mid, scale);
    if (!mounted) return;
    await ffi.ffiModel
        .applyDynamicResolution(scalePercent: scale, devicePixelRatio: _dpr);
  }

  /// Selector de escala de un monitor virtual (tap en su dimensión).
  Future<void> _showScaleMenu(BuildContext anchor, int i, int mid) async {
    final ffi = _ffi;
    final pi = ffi.ffiModel.pi;
    final current = MonitorProfile.scaleOf(widget.peerId, pi, mid);
    final items = <PopupMenuEntry<void>>[
      _header('SCALE · MONITOR ${i + 1}'),
      for (final s in kMonitorScales)
        _radio(
          s == current,
          Text(s == 200 ? '$s%  (Retina · HiDPI)' : '$s%'),
          () => _setScale(mid, s),
        ),
    ];
    if (!mounted) return;
    await _showItemsMenu(anchor, items);
  }

  /// Cambia la escala manteniendo el tamaño en pixeles (la ventana): puntos =
  /// pixeles / escala, HiDPI si escala > 100.
  Future<void> _setScale(int mid, int scale) async {
    final ffi = _ffi;
    final pi = ffi.ffiModel.pi;
    final idx = pi.macDisplayIds.indexOf(mid);
    if (idx < 0 || idx >= pi.displays.length) return;
    final cur = MonitorProfile.scaleOf(widget.peerId, pi, mid);
    final px = MonitorProfile.pixelSizeOf(pi, idx, cur);
    await MonitorProfile.applySpec(widget.peerId, ffi, mid,
        VirtualSpec(px.width.round(), px.height.round(), scale));
    MonitorProfile.scheduleSave(widget.peerId, ffi);
  }

  Future<void> _disconnect() async {
    if (isDesktop) {
      await WindowController.fromWindowId(stateGlobal.windowId).close();
    } else {
      // Sin confirmación: desapila la ruta de sesión (el dispose de la
      // RemotePage del engine cierra la conexión) y volvemos a la home.
      closeConnection();
    }
  }
}
