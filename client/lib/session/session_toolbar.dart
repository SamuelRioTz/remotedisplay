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

/// Our own session toolbar — minimalist floating bottom pill.
/// Replaces RustDesk's RemoteToolbar (suppressed via showToolbar: false),
/// reusing the engine's plumbing (toolbarImageQuality/Codec/Cursor/...)
/// without its UI. Same pill on desktop and mobile, organized by intent:
///
///   ‹ · peer · [minimize] · full screen · fit · Input · Screen · ✕
///
/// - **Input**: how I interact — touch/cursor mode and view-only (mobile),
///   virtual keyboard and key help bar (independent of each other, mobile),
///   cursor/key options and session options (audio, clipboard, lock).
/// - **Screen**: what I see — monitor, view, quality,
///   codec and image (true color, monitor quality, multi-monitor).
/// Local option: hide the trackpad/mouse pointer over the remote canvas
/// (mobile). Default: hidden.
const kOptHideLocalPointer = 'remotedisplay-hide-local-pointer';

/// Local option (iPad): capture the trackpad/mouse pointer during the
/// session (pointer lock + GCMouse deltas). iPadOS's absolute pointer gets
/// stuck at the screen edges and stops emitting events — captured, the
/// remote cursor moves RELATIVE, crosses to the external monitor and
/// doesn't stick to the corners. Default: enabled (only takes effect if
/// there's a trackpad/mouse). With capture active, the pill and menus are
/// used with the finger; opening a menu or popup releases the capture on
/// its own and it resumes when closed.
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

  /// Internal actions of the engine's mobile RemotePage (mobile only).
  final MobileRemotePageController? mobile;

  /// iPad's external monitor (iOS): which remote display it shows and how to change it.
  final ExternalScreenController? externalScreen;

  /// "Hide local pointer" state of the mobile session (applied by the screen).
  final ValueNotifier<bool>? hideLocalPointer;

  /// "Capture pointer" state (iPad: relative + crosses monitors; applied by
  /// the mobile session via native pointer lock).
  final ValueNotifier<bool>? pointerCapture;

  /// The pill's geometry and whether a menu is open (zones where the local
  /// pointer must stay visible even when hidden over the canvas; native iOS).
  final void Function(Rect? pill, bool menuOpen)? onPointerUi;

  @override
  State<SessionToolbar> createState() => _SessionToolbarState();
}

class _SessionToolbarState extends State<SessionToolbar> {
  bool _hover = false;
  bool _collapsed = false;
  // Mobile: full screen = no system status or navigation bar (the engine
  // starts the session this way). Persistent.
  bool _mobileFullscreen = true;

  // The client's own preferences (engine local options, global to the
  // device). Everything else — codec, quality, view, cursor and session
  // toggles — is already persisted by the engine per peer; touch mode is
  // persisted by the engine in kOptionTouchMode and read when opening a session.
  static const _optKeyHelpBar = 'remotedisplay-key-help-bar';
  static const _optMobileFullscreen = 'remotedisplay-mobile-fullscreen';

  @override
  void initState() {
    super.initState();
    if (!isDesktop) {
      _mobileFullscreen =
          bind.mainGetLocalOption(key: _optMobileFullscreen) != 'N';
      final barOn = bind.mainGetLocalOption(key: _optKeyHelpBar) == 'Y';
      // Apply after the first frame: the engine's RemotePage has already
      // mounted and registered its callbacks on the controller.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // The key help bar ONLY obeys its own toggle (never the keyboard).
        widget.mobile?.setKeyHelpOverride?.call(barOn);
        if (!_mobileFullscreen) {
          SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual,
              overlays: SystemUiOverlay.values);
        }
      });
    }
  }

  static const _bg = Color(0xE61A1D24); // translucent graphite
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
    // Touch: no hover → the pill always stays visible (somewhat dimmed).
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

  /// Collapsed pill: just the button to re-expand.
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

  /// Pill button. [onTap] receives the BUTTON's BuildContext so menus can
  /// anchor to it (the toolbar's context is an Align that occupies the
  /// whole window → the menu would pop up at the very top).
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

  // ── menus ────────────────────────────────────────────────────────────────

  /// Displays [items] as a popup right ABOVE the [anchor] button, with the
  /// pill's aesthetic. If it doesn't fit, the PopupMenu scrolls on its own.
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
      // 420: the MONITORS row (radio+icon+name+badge+resolution+open+
      // switch/trash) needs ~400px to not wrap the resolution.
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

  /// Section title inside a menu.
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

  /// Standard row: indicator (radio/check) + text (+ detail on the right).
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

  /// Display row: radio (changes THIS window's monitor) + contextual button
  /// on the right (open that display in a new window, or close the window
  /// that already shows it).
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
                // the ITEM's context: to close the menu before acting.
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

  /// Asks main which displays of this peer are visible in OTHER windows
  /// (display → windowId). On any failure: empty — the open buttons simply
  /// show up and openMonitorSession's dedup resolves it.
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

  /// After deleting the virtual monitor being viewed, the engine switches on
  /// its own to the remaining one but the window title doesn't find out:
  /// wait for that display to leave the list and reflect the current one.
  Future<void> _retitleWhenDisplayGone(int mid) async {
    for (var attempt = 0; attempt < 40; attempt++) {
      await Future.delayed(const Duration(milliseconds: 100));
      if (!mounted) return;
      if (!_ffi.ffiModel.pi.macDisplayIds.contains(mid)) break;
    }
    if (!mounted) return;
    _setWindowTitleForDisplay(CurrentDisplayState.find(widget.peerId).value);
  }

  /// Reflects in the window title which display it shows.
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

  /// Unified monitor row (macOS): combines selection (which one is shown),
  /// physical/virtual indicator, resolution, open/close in another window,
  /// and on/off switch or trash — so there isn't a "Displays" list and a
  /// separate "Monitors" one for the same set. Tap on the row = view that
  /// monitor here; the switch turns off a physical one (mirroring); the
  /// trash destroys a virtual one.
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
        // Fixed-width columns so all rows align (symmetrical).
        child: Row(
          children: [
            // "Viewing this monitor" indicator (filled if it's the current one).
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
            // Name — fixed width.
            SizedBox(
              width: 74,
              child: Text(label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: isOn ? Colors.white : _fg, fontSize: 13)),
            ),
            // Physical/virtual badge — fixed width, left-aligned.
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
            // Resolution — right-aligned. On virtuals it's clickable: opens
            // the scale selector (100/125/150/200%).
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
            // Open in new window / close that window. Fixed column so rows
            // with no action (the one currently being viewed) align the same.
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
            // Virtual: trash (create/delete). Physical: on/off switch (the
            // physical one isn't deleted, it's turned off by mirroring it onto the main one).
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

  /// Text of an engine item (they're all `Text(translate(...))`).
  String _label(TToggleMenu t) {
    final c = t.child;
    return c is Text ? (c.data ?? '') : '';
  }

  /// Engine toggles that are about the IMAGE (go to the Screen menu); the
  /// rest of toolbarDisplayToggle are session ones (Input).
  bool _isImageToggle(TToggleMenu t) => {
        translate('True color (4:4:4)'),
        translate('Show quality monitor'),
        translate('Show displays as individual windows'),
        translate('Use all my displays for the remote session'),
      }.contains(_label(t));

  bool _isViewOnly(TToggleMenu t) => _label(t) == translate('View Mode');

  /// **Input** menu: touch/cursor mode, keyboard and key help bar (mobile),
  /// cursor/key options and session options.
  Future<void> _showInputMenu(BuildContext anchor) async {
    final ffi = _ffi;
    final id = widget.peerId;
    final cursor = await toolbarCursor(context, id, ffi);
    final keys = toolbarKeyboardToggles(ffi);
    final all = await toolbarDisplayToggle(context, id, ffi);
    // The engine repeats the key toggles at the end of toolbarDisplayToggle
    // (mobile): don't show them twice.
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
        // toggleTouchMode() doesn't persist; the engine reads this option on open.
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
      // Independent of the keyboard: state = ITS OWN toggle (override), not
      // what the engine would show automatically.
      final barOn = widget.mobile?.keyHelpOverride?.call() ?? false;
      items.add(
          _check(barOn, const Text('Key bar (Ctrl, Alt, Esc, arrows…)'), () {
        widget.mobile?.setKeyHelpOverride?.call(!barOn);
        bind.mainSetLocalOption(key: _optKeyHelpBar, value: barOn ? 'N' : 'Y');
      }));
      if (isAndroid) {
        // Desktop mode (external monitor): opens the TrackpadActivity on
        // the phone screen — trackpad + keyboard for this session.
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
        // Trackpad capture: relative cursor, crosses to the external
        // monitor and doesn't get stuck at the edges (menus open with the finger).
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

  /// **Screen** menu: fit, monitors, view, quality, codec and image.
  Future<void> _showDisplayMenu(BuildContext anchor) async {
    final ffi = _ffi;
    final id = widget.peerId;
    final styles = await toolbarViewStyle(context, id, ffi);
    final quality = await toolbarImageQuality(context, id, ffi);
    final codec = await toolbarCodec(context, id, ffi);
    final image =
        (await toolbarDisplayToggle(context, id, ffi)).where(_isImageToggle);
    // Which displays of this peer are already shown in OTHER windows (display → win).
    final others = isDesktop ? await _queryOtherOpenDisplays() : <int, int>{};
    if (!mounted) return;

    final items = <PopupMenuEntry<void>>[];

    final pi = ffi.ffiModel.pi;
    final macMonitors =
        pi.platform == kPeerPlatformMacOS && pi.isMacVirtualDisplaySupported;
    final current = CurrentDisplayState.find(id).value;
    // iPad external monitor (mobile only): which remote display is out there.
    final ext = widget.externalScreen;
    final extConnected = ext?.screenConnected.value ?? false;
    final extDisplay = ext?.extDisplay.value ?? -1;
    if (macMonitors) {
      // remotedisplay: A SINGLE section for macOS — "monitor" and "display"
      // are the same thing, so each row combines selection (which one is
      // shown), physical/virtual badge, resolution and on/off switch. No
      // duplicate lists.
      final dispIds = pi.macDisplayIds; // aligned with pi.displays
      final virtuals = pi.macVirtualDisplays.toSet();
      final physicalOff = pi.macPhysicalOff;
      void toggle(int mid, bool on) {
        bind.sessionToggleVirtualDisplay(
            sessionId: ffi.sessionId, index: kMacRawDisplayIdBase + mid, on: on);
        MonitorProfile.scheduleSave(id, ffi); // per-client profile
      }
      items.add(_header('MONITORS'));
      for (var i = 0; i < pi.displays.length && i < dispIds.length; i++) {
        final mid = dispIds[i];
        final d = pi.displays[i];
        final isVirtual = virtuals.contains(mid);
        final isCurrent = current == i;
        final otherWin = others[i];
        final isExt = extDisplay == i;
        // Virtual: show pixels equivalent to 100% (= window size) and its
        // scale; tapping the detail opens the scale selector.
        final scale = isVirtual ? MonitorProfile.scaleOf(id, pi, mid) : 100;
        final px = isVirtual
            ? MonitorProfile.pixelSizeOf(pi, i, scale)
            : Size(d.width.toDouble(), d.height.toDouble());
        items.add(_monitorRow(
          // Sequential numbering by position: macOS's internal display ID
          // (mid) isn't consecutive and is confusing ("Monitor 8").
          label: 'Monitor ${i + 1}',
          isVirtual: isVirtual,
          isOn: true,
          isCurrent: isCurrent,
          detail: '${px.width.toInt()}×${px.height.toInt()}'
              '${isVirtual ? ' · $scale%' : ''}'
              '${otherWin != null && !isVirtual ? ' · open' : ''}'
              '${isExt ? ' · external' : ''}',
          onDetailTap: isVirtual ? () => _showScaleMenu(anchor, i, mid) : null,
          // Tap: view it here; if it's already in another window, bring
          // that window forward (the ⧉ icon is there to open it in a new window).
          onSelect: otherWin != null
              ? () => openMonitorInNewTabOrWindow(i, id, pi)
              : isCurrent
                  ? null
                  : () {
                      openMonitorInTheSameTab(i, ffi, pi);
                      _setWindowTitleForDisplay(i);
                    },
          // Desktop: open this monitor in a new window (or close the one
          // already showing it). iPad with an external monitor: show it out
          // there (or stop showing it) — the same feature the DISPLAYS
          // section of Windows/Linux peers has had; it was missing here.
          // Fixed column: the current row leaves it empty.
          openSlot: isDesktop || extConnected,
          openIcon: isDesktop
              ? (isCurrent
                  ? null
                  : (otherWin != null
                      ? Icons.close_rounded
                      : Icons.open_in_new_rounded))
              : (extConnected
                  ? (isExt
                      ? Icons.close_rounded
                      : (!isCurrent ? Icons.open_in_new_rounded : null))
                  : null),
          openTooltip: isDesktop
              ? (otherWin != null ? 'Close its window' : 'Open in new window')
              : (isExt ? 'Stop external display' : 'Show on external display'),
          onOpen: isDesktop
              ? (otherWin != null
                  ? () => DesktopMultiWindow.invokeMethod(
                      kMainWindowId, kClientEventCloseWindow, otherWin)
                  : () => openMonitorInNewTabOrWindow(i, id, pi))
              : (isExt ? () => ext?.detach() : () => _showOnExternal(i)),
          // Virtual → trash (delete); physical → switch (off = mirroring).
          onToggle: isVirtual ? null : (v) => toggle(mid, v),
          onDelete: isVirtual
              ? () async {
                  // If another window shows it, close it before destroying it.
                  if (otherWin != null) {
                    DesktopMultiWindow.invokeMethod(
                        kMainWindowId, kClientEventCloseWindow, otherWin);
                  }
                  // Same for the iPad's external monitor.
                  if (isExt) await ext?.detach();
                  toggle(mid, false);
                  if (isCurrent) _retitleWhenDisplayGone(mid);
                }
              : null,
        ));
      }
      // Physical monitors turned off (mirrored): the switch turns them back
      // on. They continue the numbering after the active ones.
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
      // Create a virtual with the window's CURRENT size as the default.
      items.add(_radio(false, const Text('Create virtual monitor'),
          () => _createVirtualMonitorAtWindowSize(),
          onIcon: Icons.add_circle_rounded,
          offIcon: Icons.add_circle_outline_rounded));
    } else if (pi.displays.length > 1) {
      // Other peers (Windows/Linux/etc.): the classic DISPLAYS section, just
      // to choose which monitor is shown.
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
                      : (!isCurrent ? Icons.open_in_new_rounded : null))
                  : null),
          trailingTooltip: isDesktop
              ? (otherWin != null ? 'Close its window' : 'Open in new window')
              : (isExt ? 'Stop external display' : 'Show on external display'),
          onTrailing: isDesktop
              ? (otherWin != null
                  ? () => DesktopMultiWindow.invokeMethod(
                      kMainWindowId, kClientEventCloseWindow, otherWin)
                  : () => openMonitorInNewTabOrWindow(i, id, pi))
              : (isExt ? () => ext?.detach() : () => _showOnExternal(i)),
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

  /// Creates a virtual monitor and sets this window's CURRENT size as its
  /// initial resolution. The server creates it with a default; as soon as
  /// the new display appears in the list, it's selected and the window's
  /// size (captured before creating it) is applied to it.
  Future<void> _createVirtualMonitorAtWindowSize() async {
    final ffi = _ffi;
    final size = ffi.ffiModel.viewportSize;
    final dpr = _dpr;
    final scale = _defaultScale;
    final before = ffi.ffiModel.pi.macDisplayIds.toSet();
    bind.sessionToggleVirtualDisplay(
        sessionId: ffi.sessionId, index: 0, on: true);
    if (size == null) return;
    // window's PHYSICAL pixels; the spec derives points and HiDPI from the scale
    final w = (size.width * dpr).round();
    final h = (size.height * dpr).round();
    if (w < 400 || h < 300) return;
    // Wait (up to ~4s) for the server to announce the new display.
    for (var attempt = 0; attempt < 40; attempt++) {
      await Future.delayed(const Duration(milliseconds: 100));
      final pi = ffi.ffiModel.pi;
      final ids = pi.macDisplayIds;
      final newMid = ids.firstWhere((m) => !before.contains(m), orElse: () => -1);
      if (newMid == -1) continue;
      final idx = ids.indexOf(newMid);
      if (idx < 0 || idx >= pi.displays.length) continue;
      // View it and fit it to the window's size at the client's scale.
      openMonitorInTheSameTab(idx, ffi, pi);
      _setWindowTitleForDisplay(idx);
      await Future.delayed(const Duration(milliseconds: 200));
      await MonitorProfile.applySpec(
          widget.peerId, ffi, newMid, VirtualSpec(w, h, scale));
      break;
    }
    MonitorProfile.scheduleSave(widget.peerId, ffi);
  }

  /// Goes back to viewing the full remote screen: "adaptive" style (fits
  /// the window) and canvas reset (undoes the pinch zoom/pan on mobile or
  /// the scroll on desktop).
  ///
  /// remotedisplay: this is also THE trigger for dynamic resolution — if the
  /// current display is virtual (macOS/IDD), its resolution is fit to this
  /// window's size. It's not automatic on every resize: the user decides
  /// when via this button. On "All displays" nothing is touched (the guard
  /// lives in applyDynamicResolution).
  Future<void> _fitScreen() async {
    final ffi = _ffi;
    await bind.sessionSetViewStyle(
        sessionId: ffi.sessionId, value: kRemoteViewStyleAdaptive);
    await ffi.canvasModel.updateViewStyle();
    ffi.canvasModel.reset();
    // give it a frame so the canvas measures the new size before applying
    await Future.delayed(const Duration(milliseconds: 120));
    if (!mounted) return;
    final pi = ffi.ffiModel.pi;
    final macMonitors =
        pi.platform == kPeerPlatformMacOS && pi.isMacVirtualDisplaySupported;
    final current = CurrentDisplayState.find(widget.peerId).value;
    if (macMonitors &&
        current != kAllDisplayValue &&
        !ffi.ffiModel.isVirtualDisplayResolution) {
      // Case 1: the monitor being viewed is PHYSICAL and can't be freely
      // resized. "Fit" = make it dynamic: the server mirrors it onto a
      // virtual that becomes the main one and does follow the window.
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
    // The monitor plugged into the iPad is a screen too.
    await _fitExternal();
  }

  /// iPad: show remote display [i] on the external monitor and, if it is one
  /// of the Mac's virtual displays, size it to the monitor (1:1, sharp) —
  /// the monitor is a fixed screen, so "fit" there means the virtual follows it.
  Future<void> _showOnExternal(int i) async {
    final ext = widget.externalScreen;
    if (ext == null) return;
    await ext.attachDisplay(i);
    await _fitExternal();
  }

  /// "Fit to screen" for the external monitor: the virtual shown out there
  /// takes the monitor's pixel size (at that virtual's scale). Physicals
  /// can't be resized freely: they are only scaled to fill the monitor.
  Future<void> _fitExternal() async {
    final ext = widget.externalScreen;
    final ffi = _ffi;
    if (ext == null || ext.extDisplay.value < 0) return;
    final display = ext.extDisplay.value;
    final pi = ffi.ffiModel.pi;
    if (display >= pi.macDisplayIds.length) return;
    final mid = pi.macDisplayIds[display];
    if (!pi.macVirtualDisplays.contains(mid)) return;
    final px = await ext.externalPixelSize();
    if (px == null) return;
    final scale = MonitorProfile.scaleOf(widget.peerId, pi, mid);
    final w = (px.width * 100 / scale).round() & ~1; // even: hardware encoders
    final h = (px.height * 100 / scale).round() & ~1;
    final d = pi.displays[display];
    final sc = d.scale <= 0 ? 1.0 : d.scale;
    if (((d.width / sc).round() - w).abs() <= 1 &&
        ((d.height / sc).round() - h).abs() <= 1) return;
    await ffi.ffiModel.changeResolutionOfDisplay(display, w, h);
    MonitorProfile.scheduleSave(widget.peerId, ffi);
  }

  /// devicePixelRatio of THIS window (physical pixels per logical pixel).
  double get _dpr =>
      mounted ? MediaQuery.of(context).devicePixelRatio : 1.0;

  /// Default scale for new virtuals: the client's own (like Windows).
  int get _defaultScale => snapScale(_dpr);

  /// Dynamic main (engine index -2): the current physical display gets
  /// mirrored onto a main virtual. When the display being viewed becomes
  /// virtual, the window's size is applied to it. It's undone with the
  /// physical one's switch (becomes main again) or the virtual's trash.
  Future<void> _makePhysicalDynamicAndFit() async {
    final ffi = _ffi;
    bind.sessionToggleVirtualDisplay(
        sessionId: ffi.sessionId, index: kMacDynamicMainIndex, on: true);
    // Wait (up to ~6s) for the server to replace the physical display with
    // the virtual one in the display list and for this window to show it.
    for (var attempt = 0; attempt < 60; attempt++) {
      await Future.delayed(const Duration(milliseconds: 100));
      if (!mounted) return;
      if (ffi.ffiModel.isVirtualDisplayResolution) break;
    }
    if (!mounted || !ffi.ffiModel.isVirtualDisplayResolution) return;
    await Future.delayed(const Duration(milliseconds: 300));
    // Client's default scale for the dynamic main virtual.
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

  /// Scale selector for a virtual monitor (tap on its dimension).
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

  /// Changes the scale while keeping the pixel size (the window): points =
  /// pixels / scale, HiDPI if scale > 100.
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
      // No confirmation: pops the session route (the engine's RemotePage
      // dispose closes the connection) and we return to the home.
      closeConnection();
    }
  }
}
