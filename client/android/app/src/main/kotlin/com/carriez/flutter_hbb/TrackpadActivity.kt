package com.carriez.flutter_hbb

import io.flutter.embedding.android.FlutterActivity

/**
 * remotedisplay: phone screen as trackpad + keyboard while the session runs
 * on the external monitor (Android desktop mode). Second Flutter engine of
 * the same process; Dart branches on the "/trackpad" route (see
 * client/lib/main.dart) and sends input to the session via FFI.
 */
class TrackpadActivity : FlutterActivity() {
    override fun getInitialRoute(): String = "/trackpad"
}
