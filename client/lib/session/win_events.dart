import 'package:flutter_hbb/consts.dart';

/// Eventos multiventana PROPIOS del client (complementan los kWindowEvent* del
/// engine). Viajan por desktop_multi_window igual que los del engine; llevan
/// prefijo `remotedisplay_` para no chocar con métodos futuros del engine.

/// main → ventana de sesión: "¿qué display de <peer> muestras?".
/// args: peerId. Respuesta: jsonEncode({'window_id': int, 'display': int}),
/// o null si esta ventana no es una sesión de ese peer.
const String kClientEventGetSessionDisplays = 'remotedisplay_get_session_displays';

/// ventana de sesión → main: "¿qué displays de <peer> están visibles en otras
/// ventanas vivas?". args: peerId. Respuesta: jsonEncode([{window_id, display}]).
const String kClientEventQueryOpenDisplays = 'remotedisplay_query_open_displays';

/// ventana de sesión → main: cerrar la ventana de sesión <window_id> (int).
const String kClientEventCloseWindow = 'remotedisplay_close_window';

/// Título de la ventana de sesión; incluye el display cuando se conoce
/// (ventana-por-monitor: saber qué ventana muestra qué pantalla).
String sessionWindowTitle(String peerId, [int? display]) => display == null
    ? '$peerId · Remote Display'
    : display == kAllDisplayValue
        ? '$peerId · All displays · Remote Display'
        : '$peerId · Display ${display + 1} · Remote Display';
