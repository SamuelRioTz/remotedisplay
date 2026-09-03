import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart' show SessionID;
import 'package:flutter_hbb/models/platform_model.dart' show bind;

/// Local option where the mobile session publishes its sessionId so the
/// TrackpadActivity (second Flutter engine of the SAME process, on the
/// phone screen) can send it input via FFI while the session is shown on
/// the external monitor (Android desktop mode).
const String kOptTrackpadSession = 'remotedisplay-trackpad-session';

/// Native channel that launches the TrackpadActivity on the phone screen.
const kTrackpadChannel = MethodChannel('remotedisplay/trackpad');

/// Trackpad + keyboard screen: turns the phone screen into a touch panel
/// for the session running on the external monitor.
///
///   - 1 finger: moves the pointer (engine's relative mouse, `move_relative`)
///   - tap: left click · double tap: double click · long-press: right click
///   - 2 fingers vertical: mouse wheel
///   - bottom bar: keyboard (text via sessionInputString + VK_BACK/RETURN)
class TrackpadScreen extends StatefulWidget {
  const TrackpadScreen({super.key});

  @override
  State<TrackpadScreen> createState() => _TrackpadScreenState();
}

class _TrackpadScreenState extends State<TrackpadScreen> {
  SessionID? _sessionId;

  // Fraction accumulators (like the engine's sendMobileRelativeMouseMove:
  // without this, slow/fine movements get lost when truncating).
  double _remX = 0, _remY = 0;
  double _wheelRem = 0;
  static const _speed = 1.6; // trackpad sensitivity
  int _pointers = 0;

  // Keyboard: hidden TextField; sends the diff (new text via
  // sessionInputString, deletions as VK_BACK) same as the mobile engine.
  final _kbController = TextEditingController();
  final _kbFocus = FocusNode();
  String _kbLast = '';

  static const _bg = Colors.black; // OLED: trackpad surface off
  static const _fg = Color(0xFFB8BDC7);
  static const _fgDim = Color(0xFF6A7280);

  @override
  void initState() {
    super.initState();
    final sid = bind.mainGetLocalOption(key: kOptTrackpadSession);
    if (sid.isNotEmpty) {
      try {
        _sessionId = SessionID(sid);
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    _kbController.dispose();
    _kbFocus.dispose();
    super.dispose();
  }

  void _sendMouse(Map<String, dynamic> msg) {
    final sid = _sessionId;
    if (sid == null) return;
    bind.sessionSendMouse(sessionId: sid, msg: json.encode(msg));
  }

  void _move(Offset delta) {
    _remX += delta.dx * _speed;
    _remY += delta.dy * _speed;
    final x = _remX.truncate();
    final y = _remY.truncate();
    _remX -= x;
    _remY -= y;
    if (x == 0 && y == 0) return;
    _sendMouse({'type': 'move_relative', 'x': '$x', 'y': '$y'});
  }

  void _click(String button) {
    _sendMouse({'type': 'down', 'buttons': button});
    _sendMouse({'type': 'up', 'buttons': button});
  }

  void _wheel(double dy) {
    _wheelRem += dy / 40; // ~40px of gesture = 1 wheel step
    final steps = _wheelRem.truncate();
    _wheelRem -= steps;
    if (steps == 0) return;
    _sendMouse({'type': 'wheel', 'x': '0', 'y': '$steps'});
  }

  void _key(String name) {
    final sid = _sessionId;
    if (sid == null) return;
    bind.sessionInputKey(
        sessionId: sid,
        name: name,
        down: false,
        press: true,
        alt: false,
        ctrl: false,
        shift: false,
        command: false);
  }

  /// Diff of the hidden TextField → session (same scheme as the mobile engine).
  void _onKbChanged(String value) {
    final sid = _sessionId;
    if (sid == null) return;
    final old = _kbLast;
    var common = 0;
    while (common < old.length &&
        common < value.length &&
        old[common] == value[common]) {
      common++;
    }
    for (var i = 0; i < old.length - common; i++) {
      _key('VK_BACK');
    }
    final added = value.substring(common);
    if (added.isNotEmpty) {
      bind.sessionInputString(sessionId: sid, value: added);
    }
    _kbLast = value;
  }

  @override
  Widget build(BuildContext context) {
    if (_sessionId == null) {
      return Scaffold(
        backgroundColor: _bg,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              'No active session.\nConnect from Remote Display first, then open the trackpad.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: _fgDim, fontSize: 15),
            ),
          ),
        ),
      );
    }
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Listener(
                onPointerDown: (_) => _pointers++,
                onPointerUp: (_) => _pointers = (_pointers - 1).clamp(0, 8),
                onPointerCancel: (_) =>
                    _pointers = (_pointers - 1).clamp(0, 8),
                // onScaleUpdate subsumes pan and also gives focalPointDelta
                // with 2 fingers (scroll); the real finger count is tracked by Listener.
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _click('left'),
                  onDoubleTap: () {
                    _click('left');
                    _click('left');
                  },
                  onLongPress: () => _click('right'),
                  onScaleUpdate: (d) {
                    if (_pointers >= 2) {
                      _wheel(-d.focalPointDelta.dy);
                    } else {
                      _move(d.focalPointDelta);
                    }
                  },
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        Icon(Icons.swipe_rounded, size: 42, color: _fgDim),
                        SizedBox(height: 12),
                        Text('Trackpad',
                            style: TextStyle(color: _fg, fontSize: 16)),
                        SizedBox(height: 6),
                        Text(
                          'drag: move · tap: click · hold: right click\n2 fingers: scroll',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: _fgDim, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // Hidden TextField: receives the IME and sends the diff to the session.
            SizedBox(
              height: 1,
              width: 1,
              child: TextField(
                controller: _kbController,
                focusNode: _kbFocus,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.visiblePassword,
                textInputAction: TextInputAction.none,
                style: const TextStyle(color: Colors.transparent, fontSize: 1),
                decoration: const InputDecoration(border: InputBorder.none),
                cursorColor: Colors.transparent,
                onChanged: _onKbChanged,
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: const BoxDecoration(
                color: Color(0xFF1A1D24),
                border:
                    Border(top: BorderSide(color: Color(0x14FFFFFF))),
              ),
              child: Row(
                children: [
                  _btn(Icons.keyboard_alt_outlined, 'Keyboard', () {
                    // Reset the diff and bring up the IME on the phone.
                    _kbController.clear();
                    _kbLast = '';
                    _kbFocus.requestFocus();
                    SystemChannels.textInput.invokeMethod('TextInput.show');
                  }),
                  _btn(Icons.keyboard_return_rounded, 'Enter',
                      () => _key('VK_RETURN')),
                  _btn(Icons.backspace_outlined, 'Backspace',
                      () => _key('VK_BACK')),
                  const Spacer(),
                  _btn(Icons.close_rounded, 'Close',
                      () => SystemNavigator.pop()),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _btn(IconData icon, String tooltip, VoidCallback onTap) => Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Icon(icon, size: 22, color: _fg),
          ),
        ),
      );
}
