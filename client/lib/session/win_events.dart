import 'package:flutter_hbb/consts.dart';

/// The client's OWN multi-window events (complementing the engine's
/// kWindowEvent*). They travel over desktop_multi_window just like the
/// engine's; they carry the `remotedisplay_` prefix to avoid clashing with
/// future engine methods.

/// main → session window: "which display of <peer> are you showing?".
/// args: peerId. Response: jsonEncode({'window_id': int, 'display': int}),
/// or null if this window isn't a session for that peer.
const String kClientEventGetSessionDisplays = 'remotedisplay_get_session_displays';

/// session window → main: "which displays of <peer> are visible in other
/// live windows?". args: peerId. Response: jsonEncode([{window_id, display}]).
const String kClientEventQueryOpenDisplays = 'remotedisplay_query_open_displays';

/// session window → main: close session window <window_id> (int).
const String kClientEventCloseWindow = 'remotedisplay_close_window';

/// Session window title; includes the display when known (window-per-
/// monitor: knowing which window shows which screen).
String sessionWindowTitle(String peerId, [int? display]) => display == null
    ? '$peerId · Remote Display'
    : display == kAllDisplayValue
        ? '$peerId · All displays · Remote Display'
        : '$peerId · Display ${display + 1} · Remote Display';
