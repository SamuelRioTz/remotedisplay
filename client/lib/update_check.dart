import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Tells the home screen when a newer release is published on GitHub. One
/// request per launch (the GitHub API allows 60/h unauthenticated), no data
/// about this device is sent beyond the User-Agent. The update itself stays
/// manual: the link opens the releases page.
class UpdateCheck {
  static const releasesApi =
      'https://api.github.com/repos/SamuelRioTz/remotedisplay/releases/latest';
  static const releasesPage =
      'https://github.com/SamuelRioTz/remotedisplay/releases/latest';

  /// Newer version available (e.g. "1.0.3"), or null.
  static final ValueNotifier<String?> available = ValueNotifier(null);
  static bool _ran = false;

  static Future<void> run() async {
    if (_ran) return;
    _ran = true;
    try {
      final info = await PackageInfo.fromPlatform();
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 8);
      final req = await client.getUrl(Uri.parse(releasesApi));
      req.headers.set('Accept', 'application/vnd.github+json');
      req.headers.set('User-Agent', 'RemoteDisplay/${info.version}');
      final res = await req.close().timeout(const Duration(seconds: 12));
      if (res.statusCode == 200) {
        final body = await res.transform(utf8.decoder).join();
        var tag = ((jsonDecode(body) as Map)['tag_name'] ?? '').toString();
        if (tag.startsWith('v')) tag = tag.substring(1);
        if (isNewer(tag, info.version)) available.value = tag;
      }
      client.close();
    } catch (e) {
      debugPrint('[update check] $e');
    }
  }

  /// "1.0.3" is newer than "1.0.2"; non-numeric parts count as 0.
  static bool isNewer(String candidate, String current) {
    List<int> parts(String v) => v
        .split('+')
        .first
        .split('.')
        .map((p) => int.tryParse(p.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
        .toList();
    final a = parts(candidate), b = parts(current);
    for (var i = 0; i < 3; i++) {
      final x = i < a.length ? a[i] : 0, y = i < b.length ? b[i] : 0;
      if (x != y) return x > y;
    }
    return false;
  }
}
