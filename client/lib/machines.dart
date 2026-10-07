import 'dart:convert';

import 'package:flutter_hbb/models/peer_model.dart';

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

  /// TCP probe of the direct-access port: the last answer (true/false), or
  /// null when the address has never been probed. A re-check in flight keeps
  /// the previous answer here (see [probing]), so the list does not blink.
  bool? reachable;

  /// A probe of this address is running right now.
  bool probing = false;

  /// The engine has a password saved for this address (one tap connects).
  bool saved = false;

  /// What this address was tied to the machine by: the host's engine id (its
  /// own, or the one another address answering with the same salt carries), a
  /// salt-only identity (`fp:…`) when no engine id is known, or empty when the
  /// address joined the card by name alone. Two routes with the same non-empty
  /// identity were seen to be one computer.
  String identity = '';

  /// The engine id came from this very address (its discovery reply or a
  /// login through it), not from a fingerprint or a name. The salt a host
  /// sends is public, so a saved password is only ever borrowed by a route
  /// that proved itself this way (see [Machine.donorFor]).
  bool ownId = false;

  MachineRoute(this.ip, {required this.tailscale, this.manual = false});

  String get kind => tailscale ? 'Tailscale' : 'LAN';
}

class Machine {
  /// Grouping key: the machine's current hostname label when identified
  /// (aliases and selected networks are stored under it), else the address.
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

  /// Another route whose saved password [r] may borrow: one with the same
  /// engine id, which [r] must carry on its own (a route tied in by a
  /// fingerprint or a name alone asks for the password once; after that
  /// login the engine has saved its identity and it borrows like any other).
  MachineRoute? donorFor(MachineRoute r) {
    if (r.identity.isEmpty || !r.ownId) return null;
    for (final x in routes) {
      if (x != r && x.saved && x.identity == r.identity) return x;
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

  /// Some address is being probed, or has never been (no verdict yet).
  bool get probing => routes.any((r) => r.probing || r.reachable == null);

  /// No first verdict yet for some address. The home holds its judgement
  /// (empty-state text, the "do not answer" note, a card's dimmed look) only
  /// in this state; a re-check in flight keeps the last verdict in place.
  bool get unknown => routes.any((r) => r.reachable == null);

  /// Answers from the current network on at least one address. The home lists
  /// only these; the others wait behind a one-line "not reachable" note.
  bool get available => live != null;

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

// ── grouping ────────────────────────────────────────────────────────────────

/// 100.64.0.0/10 — the CGNAT range Tailscale uses (an id may carry a port).
bool isTailscaleAddress(String id) {
  final parts = splitAddress(id, 0).host.split('.');
  if (parts.length != 4 || parts[0] != '100') return false;
  final b = int.tryParse(parts[1]) ?? -1;
  return b >= 64 && b <= 127;
}

/// An id may carry a port ("host:port") when the server is not on the default
/// direct-access port; the engine accepts such ids as they are.
({String host, int port}) splitAddress(String id, int defaultPort) {
  final i = id.lastIndexOf(':');
  if (i > 0 && !id.contains(']')) {
    final p = int.tryParse(id.substring(i + 1));
    if (p != null && p > 0) return (host: id.substring(0, i), port: p);
  }
  return (host: id, port: defaultPort);
}

/// First label of a hostname, normalized ("Mac.lan" → "mac").
String? hostLabel(String hostname) {
  final label = hostname.split('.').first.trim().toLowerCase();
  return label.isEmpty ? null : label;
}

/// Everything the home knows, handed to [groupMachines].
class GroupingInput {
  /// The engine's discovered peers (id = address), newest first.
  final List<Peer> discovered;

  /// The engine's recent peers: identity saved per address at the last
  /// connection (hostname, platform, user, engine id).
  final List<Peer> recent;

  /// Addresses added by hand: ip → the key of the machine they were added to.
  final Map<String, String> manual;

  /// Fingerprint per address: the salt its host sent first (first_frame.dart).
  final Map<String, String> fingerprints;

  /// From `tailscale status`: Tailscale ip → hostname label / platform, this
  /// machine's own Tailscale ips, and every ip of the current tailnet.
  final Map<String, String> tsName;
  final Map<String, String> tsPlatform;
  final Set<String> tsSelf;
  final Set<String> tsAll;

  /// Probe verdict per address (null = never probed), probes in flight,
  /// addresses with a saved password.
  final Map<String, bool?> reach;
  final Set<String> probing;
  final Set<String> saved;

  /// What the user stored per machine key.
  final Map<String, String> aliases;
  final Map<String, String> preferred;

  const GroupingInput({
    required this.discovered,
    required this.recent,
    this.manual = const {},
    this.fingerprints = const {},
    this.tsName = const {},
    this.tsPlatform = const {},
    this.tsSelf = const {},
    this.tsAll = const {},
    this.reach = const {},
    this.probing = const {},
    this.saved = const {},
    this.aliases = const {},
    this.preferred = const {},
  });
}

/// Groups every known address (1 entry per IP) into machines (1 per computer).
///
/// Identity, in order: the engine id the host announces (discovery reply,
/// login response — also for the other addresses it names there); the salt
/// the host sends first on every direct TCP connection, which ties an address
/// without an id to the machine whose other address answered with the same
/// salt (or stands for the machine when no id is known at all); the hostname.
List<Machine> groupMachines(GroupingInput g) {
  // The engine can save the same IP twice (entry identified by broadcast +
  // bare entry from the port scan): first dedupe by IP, preferring the
  // identified one. Recent peers and manual addresses join as bare entries.
  final byIp = <String, Peer>{};
  void add(Peer p) {
    if (p.id.isEmpty || g.tsSelf.contains(p.id)) return; // never ourselves
    // CGNAT IP that no longer exists in the tailnet (left over from a
    // previous tailnet): ghost card, don't list it.
    if (isTailscaleAddress(p.id) &&
        g.tsAll.isNotEmpty &&
        !g.tsAll.contains(splitAddress(p.id, 0).host)) {
      return;
    }
    final prev = byIp[p.id];
    if (prev == null ||
        (prev.platform.isEmpty && p.platform.isNotEmpty) ||
        (prev.machineId.isEmpty && p.machineId.isNotEmpty)) {
      byIp[p.id] = p;
    }
  }

  for (final p in g.discovered) {
    add(p);
  }
  for (final p in g.recent) {
    add(p);
  }
  for (final ip in g.manual.keys) {
    if (!byIp.containsKey(ip)) add(Peer.fromJson({'id': ip}));
  }

  // Then group by machine identity. First choice: the engine id the host
  // announces (in its discovery reply and, since 1.0.13, in the login
  // response, saved with the recent peer), which survives a new lease and
  // a hostname change. A Mac with no fixed HostName takes its kernel
  // hostname from the router's reverse DNS, so one Mac showed up as
  // "mac.lan" on one address and "samuels-mac-studio.local" on the next,
  // and grouping by name alone made two computers of it. Names remain the
  // fallback, in order: hostname from the LAN broadcast, hostname saved
  // from a previous connection to that IP (recent peers — so the Mac's
  // Tailscale IP groups with its LAN IP even if the broadcast doesn't cross
  // into Tailscale), hostname reported by `tailscale status`, the machine
  // an address was added to by hand. No id and no name → its own card per IP.
  //
  // An address with no engine id of its own is still tied to its machine by
  // its fingerprint: the salt the host sends in the first frame of every
  // direct TCP connection (first_frame.dart), which the probes collect. Two
  // addresses answering with one salt are one computer, so the address takes
  // the engine id the other one carries; with no engine id anywhere the salt
  // itself stands for the machine (`fp:…`). This needs no discovery reply and
  // works against any server version — what rescues a client whose firewall
  // drops the replies, and the stale recent peer a 1.0.12 server left under
  // the router's name. Guards: an empty salt links nothing, and a salt seen
  // with two different engine ids (a cloned configuration) links nothing.
  final recentById = {
    for (final r in g.recent)
      if (r.hostname.isNotEmpty || r.machineId.isNotEmpty) r.id: r
  };
  String? labelOf(Peer p, Peer? recent) {
    final knownHost = p.platform.isNotEmpty && p.hostname.isNotEmpty
        ? p.hostname
        : (recent != null && recent.platform.isNotEmpty
            ? recent.hostname
            : null);
    return knownHost == null ? null : hostLabel(knownHost);
  }
  String idOf(Peer p, Peer? recent) =>
      p.machineId.isNotEmpty ? p.machineId : (recent?.machineId ?? '');

  // The engine id behind each salt ('' when two ids claimed one salt).
  final idOfFp = <String, String>{};
  for (final p in byIp.values) {
    final fp = g.fingerprints[p.id];
    if (fp == null || fp.isEmpty) continue;
    final mid = idOf(p, recentById[p.id]);
    if (mid.isEmpty) continue;
    final prev = idOfFp[fp];
    if (prev == null) {
      idOfFp[fp] = mid;
    } else if (prev != mid) {
      idOfFp[fp] = '';
    }
  }
  String identityOf(Peer p, Peer? recent) {
    final mid = idOf(p, recent);
    if (mid.isNotEmpty) return mid;
    final fp = g.fingerprints[p.id];
    if (fp == null || fp.isEmpty) return '';
    return idOfFp[fp] ?? 'fp:$fp';
  }

  // Pass 1: the name that stands for each machine id (first seen wins:
  // discovered entries come first, then the recent peers newest first, so
  // it is the host's current name) and the machine id behind each name (so
  // an address that only has a name joins the machine that announced that
  // name together with its id). The addresses tied in by fingerprint only
  // come second and only add a name where there is none, and never map
  // their name to an id: the name a stale entry was saved under ("mac")
  // must not pull other addresses of that name into this machine.
  final labelOfId = <String, String>{};
  final idOfLabel = <String, String>{};
  for (final p in byIp.values) {
    final recent = recentById[p.id];
    final mid = idOf(p, recent);
    final label = labelOf(p, recent);
    if (mid.isEmpty || label == null) continue;
    labelOfId.putIfAbsent(mid, () => label);
    idOfLabel.putIfAbsent(label, () => mid);
  }
  for (final p in byIp.values) {
    final recent = recentById[p.id];
    if (idOf(p, recent).isNotEmpty) continue;
    final mid = identityOf(p, recent);
    final label = labelOf(p, recent);
    if (mid.isEmpty || label == null) continue;
    labelOfId.putIfAbsent(mid, () => label);
  }

  // Pass 2: the cards. The key stays a hostname label (aliases, selected
  // networks and manual addresses are stored under it), resolved through
  // the machine id when there is one; a machine known by its salt alone is
  // keyed by it.
  final byKey = <String, Machine>{};
  for (final p in byIp.values) {
    final recent = recentById[p.id];
    final identifiedName = labelOf(p, recent);
    var mid = identityOf(p, recent);
    if ((mid.isEmpty || mid.startsWith('fp:')) && identifiedName != null) {
      // By name, as before. idOfLabel holds only names announced together
      // with an engine id, so the stale-name guard above is unaffected; a
      // salt-only identity yields to the name too (the other address may
      // simply not have been probed yet) — unless that id is already known
      // to answer with another salt: two installations, not one.
      final byName = idOfLabel[identifiedName];
      if (byName != null && !idOfFp.containsValue(byName)) mid = byName;
    }
    final currentName = mid.isEmpty ? null : labelOfId[mid];
    final tsName = g.tsName[p.id];
    final key = currentName ??
        identifiedName ??
        tsName ??
        g.manual[p.id] ??
        (mid.startsWith('fp:') ? mid : 'ip:${p.id}');

    final m = byKey.putIfAbsent(
        key,
        () => Machine(
            key: key, name: currentName ?? identifiedName ?? tsName ?? p.id));
    final route = MachineRoute(p.id,
        tailscale: isTailscaleAddress(p.id), manual: g.manual.containsKey(p.id));
    route.identity = mid;
    route.ownId = idOf(p, recent).isNotEmpty;
    route.reachable = g.reach.containsKey(p.id) ? g.reach[p.id] : null;
    route.probing = g.probing.contains(p.id);
    route.saved = g.saved.contains(p.id);
    m.routes.add(route);
    if (m.platform.isEmpty) {
      m.platform = p.platform.isNotEmpty
          ? p.platform
          : (recent?.platform ?? '').isNotEmpty
              ? recent!.platform
              : (g.tsPlatform[p.id] ?? '');
    }
    if (m.username.isEmpty) {
      m.username =
          p.username.isNotEmpty ? p.username : (recent?.username ?? '');
    }
    // The host's current name, never the one an old address was saved under.
    final name = currentName ?? identifiedName;
    if (name != null) m.name = name;
  }

  // Addresses known only from the past — not found by this scan, not added
  // by hand — that do not answer while the machine answers elsewhere are its
  // old leases: keep them out of the card. They come back if they answer
  // again, and a machine that is off still shows every address it has.
  final found = {
    for (final p in g.discovered)
      if (p.online) p.id
  };
  final machines = byKey.values.toList();
  for (final m in machines) {
    if (m.routes.any((r) => r.reachable == true)) {
      m.routes.removeWhere(
          (r) => r.reachable == false && !r.manual && !found.contains(r.ip));
    }
    final alias = g.aliases[m.key];
    if (alias != null && alias.isNotEmpty) m.name = alias;
    final pref = g.preferred[m.key];
    if (pref != null && m.route(pref) != null) m.preferredIp = pref;
    // LAN before Tailscale; within a kind, reachable first.
    m.routes.sort((a, b) {
      final k = (a.tailscale ? 1 : 0) - (b.tailscale ? 1 : 0);
      if (k != 0) return k;
      return (a.reachable == true ? 0 : 1) - (b.reachable == true ? 0 : 1);
    });
  }
  // Reachable machines on top, then identified ones, then loose IPs.
  int rank(Machine m) => (m.live != null ? 0 : 2) + (m.identified ? 0 : 1);
  machines.sort((a, b) {
    final r = rank(a) - rank(b);
    return r != 0 ? r : a.name.compareTo(b.name);
  });
  return machines;
}

// ── what the home stores per key, following the addresses ──────────────────

/// ip → the key of the card it sits on.
Map<String, String> keyOfRoutes(List<Machine> machines) => {
      for (final m in machines)
        for (final r in m.routes) r.ip: m.key
    };

/// Which machine keys vanished and where their addresses sit now, for the
/// home's key migration (aliases, remembered route, manual addresses are
/// stored per key). A key is moved when no card still carries it — manual
/// addresses alone do not keep a key alive — and an address filed under it
/// last time ([lastKeys]), or named as its remembered route ([preferred]),
/// now sits under another key while still answering as the same host
/// ([sameHost]: a re-leased address that now answers as another computer
/// moves nothing). The first address decides when they disagree.
Map<String, String> movedKeys({
  required Map<String, String> lastKeys,
  required Map<String, String> preferred,
  required List<Machine> machines,
  required bool Function(String ip) sameHost,
}) {
  final keyOf = keyOfRoutes(machines);
  final live = {
    for (final m in machines)
      if (m.routes.any((r) => !r.manual)) m.key
  };
  final moved = <String, String>{};
  void consider(String ip, String old) {
    final now = keyOf[ip];
    if (now == null || now == old || live.contains(old)) return;
    if (!sameHost(ip)) return;
    moved.putIfAbsent(old, () => now);
  }

  lastKeys.forEach(consider);
  preferred.forEach((old, ip) => consider(ip, old));
  return moved;
}

// ── the engine's discovery tally ────────────────────────────────────────────

/// How one discovery run went, as the engine reports it in the `discovery`
/// key of its `load_lan_peers` event: replies to its UDP pings against hosts
/// the port scan found. A finished run with hosts on the port and no reply
/// means the replies do not reach this client.
class DiscoveryTally {
  final int run, replies, portHits;
  final bool done;
  const DiscoveryTally(
      {required this.run,
      required this.replies,
      required this.portHits,
      required this.done});

  /// The event value: a JSON string (or an already decoded map).
  static DiscoveryTally? parse(Object? raw) {
    try {
      final d = raw is String ? (raw.isEmpty ? null : jsonDecode(raw)) : raw;
      if (d is! Map) return null;
      int n(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
      return DiscoveryTally(
          run: n(d['run']),
          replies: n(d['replies']),
          portHits: n(d['port_hits']),
          done: d['done'] == true || d['done'] == 'true');
    } catch (_) {
      return null;
    }
  }

  bool get silent => portHits > 0 && replies == 0;
}

/// Folds a tally into the count of finished runs in a row that stayed silent.
/// A run is counted once ([lastRun]); an unfinished run changes nothing.
({int silentScans, int lastRun}) foldDiscoveryTally(DiscoveryTally? t,
    {required int silentScans, required int lastRun}) {
  if (t == null || !t.done || t.run == lastRun) {
    return (silentScans: silentScans, lastRun: lastRun);
  }
  return (silentScans: t.silent ? silentScans + 1 : 0, lastRun: t.run);
}
