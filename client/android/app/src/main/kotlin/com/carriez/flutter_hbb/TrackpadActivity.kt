package com.carriez.flutter_hbb

import io.flutter.embedding.android.FlutterActivity

/**
 * remotedisplay: pantalla del telefono como trackpad + teclado mientras la
 * sesion corre en el monitor externo (modo escritorio de Android). Segundo
 * engine Flutter del mismo proceso; el dart bifurca por la ruta "/trackpad"
 * (ver client/lib/main.dart) y manda el input a la sesion por FFI.
 */
class TrackpadActivity : FlutterActivity() {
    override fun getInitialRoute(): String = "/trackpad"
}
