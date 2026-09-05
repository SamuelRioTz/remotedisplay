/// View model of the home screen: one [Machine] per computer, with every
/// address (route) we know for it and what we know about each address right
/// now (reachable from this network? password saved?). Built by the home from
/// the engine's discovered peers, the recent peers (connected before) and the
/// addresses the user added by hand; see `home.dart`.
class MachineRoute {
  final String ip;

  /// 100.64.0.0/10, the CGNAT range Tailscale uses.
  final bool tailscale;

  /// Added by the user in the machine's settings (kept until removed there).
  final bool manual;

  /// TCP probe of the direct-access port on the last refresh: true/false, or
  /// null while the probe is running.
  bool? reachable;

  /// The engine has a password saved for this address (one tap connects).
  bool saved = false;

  MachineRoute(this.ip, {required this.tailscale, this.manual = false});

  String get kind => tailscale ? 'Tailscale' : 'LAN';
}

class Machine {
  /// Grouping key: hostname label when identified, else the address.
  final String key;
  String name;
  String platform = '';
  String username = '';
  final List<MachineRoute> routes = [];

  /// Address the user connected through last time (remembered per machine).
  /// A plain tap uses it while it answers; when it is gone or silent the
  /// connect sheet asks to choose a network again.
  String? preferredIp;

  Machine({required this.key, required this.name});

  MachineRoute? get preferred =>
      preferredIp == null ? null : route(preferredIp!);

  bool get identified => platform.isNotEmpty || username.isNotEmpty;

  bool get saved => routes.any((r) => r.saved);

  MachineRoute? get savedRoute {
    for (final r in routes) {
      if (r.saved) return r;
    }
    return null;
  }

  /// First reachable route (LAN before Tailscale, the list is sorted so).
  MachineRoute? get live {
    for (final r in routes) {
      if (r.reachable == true) return r;
    }
    return null;
  }

  bool get probing => routes.any((r) => r.reachable == null);

  /// Route for a plain tap: the first reachable one, else the first (so an
  /// unreachable machine can still be attempted, e.g. right after a network change).
  MachineRoute get best => live ?? routes.first;

  MachineRoute? route(String ip) {
    for (final r in routes) {
      if (r.ip == ip) return r;
    }
    return null;
  }
}
