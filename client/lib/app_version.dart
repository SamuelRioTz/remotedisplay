import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// The client's own version, "1.0.9 (10)", read once from the bundle. Shown on
/// the home screen's footer and at the end of the session's display menu, so a
/// screenshot always tells which build it is.
class AppVersion {
  static final ValueNotifier<String> label = ValueNotifier('');

  static Future<void> load() async {
    if (label.value.isNotEmpty) return;
    try {
      final info = await PackageInfo.fromPlatform();
      label.value = info.buildNumber.isEmpty
          ? info.version
          : '${info.version} (${info.buildNumber})';
    } catch (e) {
      debugPrint('[version] $e');
    }
  }
}
