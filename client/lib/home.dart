import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart' hide Dialog;
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/peer_model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:uni_links/uni_links.dart' show getInitialLink, uriLinkStream;
import 'package:url_launcher/url_launcher.dart' show LaunchMode, launchUrl;
import 'package:window_manager/window_manager.dart';

import 'connect_sheet.dart';
import 'home_ui.dart';
import 'machines.dart';
import 'update_check.dart';

import 'session/mobile_session.dart';

/// Client home — your computers (cards, 1 per machine) + manual connection.
///
/// Sources, merged per machine (see `machines.dart`):
///  - discovered by the engine (UDP broadcast + direct-port scan of the local
///    subnets, of the Tailscale peers, and of the Tailscale addresses it already
///    knows — see engine lan.rs), arriving via `load_lan_peers` with id = IP;
///  - recent peers (the engine's per-address config of everything we connected
///    to: hostname, platform, user, saved password);
///  - addresses added by hand in a machine's settings (local option
///    `rd-manual-routes`).
/// IPs (LAN/Tailscale) of the same machine are grouped via hostname (+
/// `tailscale status` on desktop). Every refresh also probes each address with
/// a TCP connect to the direct-access port, so a route that does not answer
/// from the current network shows as such and a tap uses the one that does.
class ClientHome extends StatefulWidget {
  const ClientHome({super.key});

  @override
  State<ClientHome> createState() => _ClientHomeState();
}

class _ClientHomeState extends State<ClientHome> with WidgetsBindingObserver {
  static const _manualKey = 'rd-manual-routes';
  static const _probeTimeout = Duration(milliseconds: 1500);
  static const _probeEvery = Duration(seconds: 20);

  final _ip = TextEditingController();
  final _pw = TextEditingController();
  bool _connecting = false;
  bool _scanning = false;
  bool _manualOpen = false;
  Timer? _scanTimer;
  Timer? _probeTimer;

  // Tailscale IP → (real hostname, platform), via `tailscale status --json`.
  // The HostName from the JSON is the hostname the machine reports (not the
  // device name in the tailnet), so it matches the hostname from the LAN
  // broadcast and we can group both IPs into a single card.
  Map<String, String> _tsName = {};
  Map<String, String> _tsPlatform = {};
  Set<String> _tsSelf = {}; // IPs of THIS machine (don't show ourselves)
  // ALL IPs in the current tailnet (self + peers). If the CLI responded and a
  // saved CGNAT IP isn't in here, it belongs to an old tailnet: don't show it.
  Set<String> _tsAll = {};
  // IPs with a saved password in the engine's peer config.
  Set<String> _savedIps = {};
  // Addresses added by hand: ip → machine key they were attached to.
  Map<String, String> _manual = {};
  // TCP probe of each known address on the last refresh (null = probing).
  final Map<String, bool?> _reach = {};
  // Bumped on every change the sheets should redraw for.
  final _rev = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Reinforce showing the main window once the first frame is mounted
    // (see note in main.dart / RESULT of the handoff about standalone visibility).
    if (isDesktop) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        try {
          await windowManager.show();
          await windowManager.focus();
          await windowManager.setOpacity(1);
        } catch (_) {}
      });
    }
    gFFI.lanPeersModel.addListener(_onPeersChanged);
    gFFI.recentPeersModel.addListener(_onPeersChanged);
    _loadManual();
    bind.mainLoadLanPeers(); // the cached ones, instantly
    UpdateCheck.run();
    bind.mainLoadRecentPeers(); // identity (real hostname) of already-connected IPs
    _refresh();
    _probeTimer = Timer.periodic(_probeEvery, (_) {
      if (!_connecting) _probeAll();
    });
    // Deep links on mobile (remotedisplay://connection/new/<host>?password=…):
    // they connect with OUR mobile session. On desktop the engine resolves
    // them (handleUriLink in main.dart), here only the mobile flow.
    if (!isDesktop) _initDeepLinks();
  }

  StreamSubscription? _linkSub;

  Future<void> _initDeepLinks() async {
    try {
      final initial = await getInitialLink();
      if (initial != null && initial.isNotEmpty) _handleDeepLink(initial);
    } catch (_) {}
    try {
      _linkSub = uriLinkStream.listen((uri) {
        if (uri != null) _handleDeepLink(uri.toString());
      }, onError: (_) {});
    } catch (_) {}
  }

  void _handleDeepLink(String link) {
    final uri = Uri.tryParse(link);
    if (uri == null) return;
    // Same format as the engine: remotedisplay://connection/new/<id>?password=…
    final segs = uri.pathSegments;
    String? id;
    if (uri.host == 'connection' &&
        segs.length >= 2 &&
        segs.first == 'new') {
      id = segs[1];
    }
    if (id == null || id.isEmpty) return;
    final pw = uri.queryParameters['password'];
    _connect(id, password: (pw?.isEmpty ?? true) ? null : pw);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    gFFI.lanPeersModel.removeListener(_onPeersChanged);
    gFFI.recentPeersModel.removeListener(_onPeersChanged);
    _linkSub?.cancel();
    _scanTimer?.cancel();
    _probeTimer?.cancel();
    _rev.dispose();
    _ip.dispose();
    _pw.dispose();
    super.dispose();
  }

  /// Back from another app / the network may have changed (iPad leaving home):
  /// refresh everything, so stale routes are marked and new ones found.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_connecting) _refresh();
  }

  void _onPeersChanged() {
    _refreshSaved();
    _probeNew();
    _bump();
  }

  void _bump() {
    if (mounted) _rev.value++;
  }

  /// Everything: engine discovery, Tailscale identities, saved passwords and
  /// the reachability of every known address.
  void _refresh() {
    _discover();
    _probeAll();
    _refreshSaved();
  }

  void _discover() {
    if (_scanning) return;
    setState(() => _scanning = true);
    bind.mainDiscover();
    bind.mainLoadRecentPeers();
    _loadTailscale();
    // The engine keeps pushing load_lan_peers as responses arrive;
    // the spinner only covers the typical scan window (~5s).
    _scanTimer?.cancel();
    _scanTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _scanning = false);
    });
  }

  // ── reachability ────────────────────────────────────────────────────────

  int get _port {
    try {
      final v = int.tryParse(bind.mainGetOptionSync(key: 'direct-access-port'));
      if (v != null && v > 0) return v;
    } catch (_) {}
    return 21118;
  }

  Set<String> _knownIps() => {
        ...gFFI.lanPeersModel.peers.map((p) => p.id),
        ...gFFI.recentPeersModel.peers.map((p) => p.id),
        ..._manual.keys,
      }..removeWhere((ip) => ip.isEmpty || _tsSelf.contains(ip));

  Future<void> _probeAll() => _probe(_knownIps());

  /// Only the addresses that have never been probed (new discoveries).
  Future<void> _probeNew() =>
      _probe(_knownIps().where((ip) => !_reach.containsKey(ip)).toSet());

  /// Addresses may carry a port ("host:port") when the server is not on the
  /// default direct-access port; the engine accepts them as ids.
  ({String host, int port}) _split(String id) {
    final i = id.lastIndexOf(':');
    if (i > 0 && !id.contains(']')) {
      final p = int.tryParse(id.substring(i + 1));
      if (p != null && p > 0) return (host: id.substring(0, i), port: p);
    }
    return (host: id, port: _port);
  }

  Future<void> _probe(Set<String> ips) async {
    if (ips.isEmpty) return;
    if (mounted) {
      setState(() {
        for (final ip in ips) {
          _reach[ip] = null;
        }
      });
    }
    _bump();
    await Future.wait(ips.map((ip) async {
      var ok = false;
      try {
        final a = _split(ip);
        final s = await Socket.connect(a.host, a.port, timeout: _probeTimeout);
        s.destroy();
        ok = true;
      } catch (_) {}
      if (mounted) setState(() => _reach[ip] = ok);
    }));
    _bump();
  }

  // ── manual addresses ────────────────────────────────────────────────────

  void _loadManual() {
    try {
      final raw = bind.mainGetLocalOption(key: _manualKey);
      if (raw.isEmpty) return;
      final data = jsonDecode(raw);
      if (data is Map) {
        _manual = {
          for (final e in data.entries)
            if (e.key is String && e.value is String) e.key: e.value
        };
      }
    } catch (_) {}
  }

  Future<void> _saveManual() async {
    await bind.mainSetLocalOption(key: _manualKey, value: jsonEncode(_manual));
  }

  /// Real hostname and OS of each Tailscale peer (same CLI the engine uses
  /// to pick scan targets). If there's no CLI, it stays empty and Tailscale
  /// IPs are shown ungrouped.
  Future<void> _loadTailscale() async {
    // On Android/iOS, Tailscale is a separate app with no CLI: 100.x IPs are
    // shown ungrouped (or grouped by hostname from previous connections).
    if (!isDesktop) return;
    final candidates = Platform.isWindows
        ? ['tailscale', r'C:\Program Files\Tailscale\tailscale.exe']
        : [
            'tailscale',
            '/Applications/Tailscale.app/Contents/MacOS/Tailscale',
            '/usr/local/bin/tailscale',
            '/opt/homebrew/bin/tailscale',
          ];
    const osMap = {
      'macos': kPeerPlatformMacOS,
      'windows': kPeerPlatformWindows,
      'linux': kPeerPlatformLinux,
      'android': kPeerPlatformAndroid,
    };
    for (final bin in candidates) {
      try {
        final r = await Process.run(bin, ['status', '--json']);
        if (r.exitCode != 0) continue;
        final data = jsonDecode(r.stdout as String) as Map<String, dynamic>;
        final name = <String, String>{};
        final plat = <String, String>{};
        final self = <String>{};
        final all = <String>{};

        void take(Map<String, dynamic> node, {bool isSelf = false}) {
          final ips =
              ((node['TailscaleIPs'] as List?) ?? const []).whereType<String>();
          final v4 = ips.where(_isTailscale).toList();
          if (v4.isEmpty) return;
          all.addAll(v4);
          if (isSelf) {
            self.addAll(v4);
            return;
          }
          final host = _hostLabel((node['HostName'] as String?) ?? '');
          final os = osMap[((node['OS'] as String?) ?? '').toLowerCase()];
          for (final ip in v4) {
            if (host != null) name[ip] = host;
            if (os != null) plat[ip] = os;
          }
        }

        final selfNode = data['Self'];
        if (selfNode is Map<String, dynamic>) take(selfNode, isSelf: true);
        final peers = data['Peer'];
        if (peers is Map<String, dynamic>) {
          for (final v in peers.values) {
            if (v is Map<String, dynamic>) take(v);
          }
        }
        if (mounted) {
          setState(() {
            _tsName = name;
            _tsPlatform = plat;
            _tsSelf = self;
            _tsAll = all;
          });
          _bump();
        }
        return;
      } catch (_) {}
    }
  }

  /// Which IPs have a saved password (async query to the engine); it is
  /// recalculated when peers change and when returning from a session.
  Future<void> _refreshSaved() async {
    final saved = <String>{};
    for (final id in _knownIps()) {
      try {
        if (await bind.mainPeerHasPassword(id: id)) saved.add(id);
      } catch (_) {}
    }
    if (mounted && !setEquals(saved, _savedIps)) {
      setState(() => _savedIps = saved);
      _bump();
    }
  }

  // ── connecting ──────────────────────────────────────────────────────────

  Future<void> _connect(String id,
      {String? password, bool remember = true}) async {
    if (id.isEmpty || _connecting) return;
    setState(() => _connecting = true);
    try {
      // A password typed here is remembered (or not) as chosen: the engine
      // reads this per-peer flag when the session is created (session_add).
      await bind.mainSetPeerOption(
          id: id,
          key: 'rd-remember',
          value: password == null ? '' : (remember ? 'Y' : 'N'));
    } catch (_) {}
    try {
      if (isDesktop) {
        // Opens our session window via the engine's multi-window plumbing.
        await connect(context, id, password: password);
      } else {
        // A single Activity: the session is a route; we come back here when it closes.
        await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => MobileSessionScreen(id: id, password: password)));
      }
    } catch (_) {}
    await Future.delayed(const Duration(milliseconds: 700));
    if (mounted) setState(() => _connecting = false);
    bind.mainLoadRecentPeers(); // a first connection adds identity + address
    _refreshSaved(); // it may have checked "remember password"
    _probeAll();
  }

  /// Tap on a machine (or on one of its routes): one tap when a password is
  /// saved, otherwise the connect sheet (route + password + remember).
  Future<void> _openConnect(Machine m, {String? ip}) async {
    if (_connecting) return;
    final ui = HomeUi(Theme.of(context).brightness == Brightness.dark);
    final route = (ip == null ? null : m.route(ip)) ?? m.best;
    if (route.saved) return _connect(route.ip);
    final donor = m.savedRoute;
    if (donor != null) {
      // Another address of the same machine has the password: reuse it.
      try {
        await bind.mainSetPeerOption(
            id: route.ip, key: 'rd-copy-password-from', value: donor.ip);
      } catch (_) {}
      await _refreshSaved();
      return _connect(route.ip);
    }
    if (!mounted) return;
    await _showSheet((ctx) => ConnectSheet(
          ui: ui,
          machine: m,
          initialIp: route.ip,
          onConnect: (ip, {password, required remember}) =>
              _connect(ip, password: password, remember: remember),
          onSettings: () => _openSettings(m),
        ));
  }

  Future<void> _openSettings(Machine m) async {
    final ui = HomeUi(Theme.of(context).brightness == Brightness.dark);
    final key = m.key;
    await _showSheet((ctx) => MachineSettingsSheet(
          ui: ui,
          revision: _rev,
          lookup: () {
            for (final x in _machines()) {
              if (x.key == key) return x;
            }
            return null;
          },
          onAddAddress: (a) => _addAddress(key, a),
          onRemoveAddress: _removeAddress,
          onForgetPassword: (r) async {
            await bind.mainForgetPassword(id: r.ip);
            await _refreshSaved();
          },
          onForgetMachine: () async {
            final x = _machines().where((x) => x.key == key);
            for (final r in x.isEmpty ? <MachineRoute>[] : x.first.routes) {
              await _removeAddress(r);
            }
          },
          onConnect: (ip) => _openConnect(m, ip: ip),
        ));
  }

  /// Sheets: bottom sheet on mobile, centered dialog on desktop.
  Future<T?> _showSheet<T>(WidgetBuilder builder) {
    final ui = HomeUi(Theme.of(context).brightness == Brightness.dark);
    if (isDesktop) {
      return showDialog<T>(
        context: context,
        builder: (ctx) => Dialog(
          backgroundColor: ui.card,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
              side: BorderSide(color: ui.border)),
          child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: builder(ctx)),
        ),
      );
    }
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      backgroundColor: ui.card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: SafeArea(
            child: SingleChildScrollView(
                child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: builder(ctx)))),
      ),
    );
  }

  Future<void> _addAddress(String machineKey, String address) async {
    final a = address.trim();
    if (a.isEmpty) return;
    _manual[a] = machineKey;
    await _saveManual();
    _bump();
    await _probe({a});
    await _refreshSaved();
  }

  /// Drops an address from every source: the discovered cache, the recent
  /// peers (this also drops its saved password) and the manual list.
  Future<void> _removeAddress(MachineRoute r) async {
    _manual.remove(r.ip);
    await _saveManual();
    try {
      await bind.mainRemoveDiscovered(id: r.ip);
      await bind.mainRemovePeer(id: r.ip);
    } catch (_) {}
    _reach.remove(r.ip);
    bind.mainLoadLanPeers();
    bind.mainLoadRecentPeers();
    if (mounted) setState(() {});
    _bump();
  }

  // 100.64.0.0/10 — CGNAT range used by Tailscale.
  bool _isTailscale(String ip) {
    final parts = _split(ip).host.split('.');
    if (parts.length != 4 || parts[0] != '100') return false;
    final b = int.tryParse(parts[1]) ?? -1;
    return b >= 64 && b <= 127;
  }

  /// First label of the hostname, normalized ("Mac.lan" → "mac").
  String? _hostLabel(String hostname) {
    final label = hostname.split('.').first.trim().toLowerCase();
    return label.isEmpty ? null : label;
  }

  /// Groups every known address (1 entry per IP) into machines (1 per computer).
  List<Machine> _machines() {
    // The engine can save the same IP twice (entry identified by broadcast +
    // bare entry from the port scan): first dedupe by IP, preferring the
    // identified one. Recent peers and manual addresses join as bare entries.
    final byIp = <String, Peer>{};
    void add(Peer p) {
      if (p.id.isEmpty || _tsSelf.contains(p.id)) return; // never ourselves
      // CGNAT IP that no longer exists in the tailnet (left over from a
      // previous tailnet): ghost card, don't list it.
      if (_isTailscale(p.id) && _tsAll.isNotEmpty && !_tsAll.contains(p.id)) {
        return;
      }
      final prev = byIp[p.id];
      if (prev == null || (prev.platform.isEmpty && p.platform.isNotEmpty)) {
        byIp[p.id] = p;
      }
    }

    for (final p in gFFI.lanPeersModel.peers) {
      add(p);
    }
    for (final p in gFFI.recentPeersModel.peers) {
      add(p);
    }
    for (final ip in _manual.keys) {
      if (!byIp.containsKey(ip)) add(Peer.fromJson({'id': ip}));
    }

    // Then group by machine identity. Sources, in order: hostname from the
    // LAN broadcast, hostname saved from a previous connection to that IP
    // (recent peers — so the Mac's Tailscale IP groups with its LAN IP even
    // if the broadcast doesn't cross into Tailscale), hostname reported by
    // `tailscale status`, the machine an address was added to by hand. No
    // name → its own card per IP.
    final recentById = {
      for (final r in gFFI.recentPeersModel.peers)
        if (r.hostname.isNotEmpty) r.id: r
    };
    final byKey = <String, Machine>{};
    for (final p in byIp.values) {
      final recent = recentById[p.id];
      final knownHost = p.platform.isNotEmpty && p.hostname.isNotEmpty
          ? p.hostname
          : (recent != null && recent.platform.isNotEmpty
              ? recent.hostname
              : null);
      final identifiedName = knownHost == null ? null : _hostLabel(knownHost);
      final tsName = _tsName[p.id];
      final key = identifiedName ?? tsName ?? _manual[p.id] ?? 'ip:${p.id}';

      final m = byKey.putIfAbsent(
          key, () => Machine(key: key, name: identifiedName ?? tsName ?? p.id));
      final route = MachineRoute(p.id,
          tailscale: _isTailscale(p.id), manual: _manual.containsKey(p.id));
      route.reachable = _reach.containsKey(p.id) ? _reach[p.id] : null;
      route.saved = _savedIps.contains(p.id);
      m.routes.add(route);
      if (m.platform.isEmpty) {
        m.platform = p.platform.isNotEmpty
            ? p.platform
            : (recent?.platform ?? '').isNotEmpty
                ? recent!.platform
                : (_tsPlatform[p.id] ?? '');
      }
      if (m.username.isEmpty) {
        m.username =
            p.username.isNotEmpty ? p.username : (recent?.username ?? '');
      }
      if (identifiedName != null) m.name = identifiedName;
    }

    final machines = byKey.values.toList();
    for (final m in machines) {
      // LAN before Tailscale; within a kind, reachable first.
      m.routes.sort((a, b) {
        final k = (a.tailscale ? 1 : 0) - (b.tailscale ? 1 : 0);
        if (k != 0) return k;
        return (a.reachable == true ? 0 : 1) - (b.reachable == true ? 0 : 1);
      });
    }
    // Reachable machines on top, then identified ones, then loose IPs.
    int rank(Machine m) =>
        (m.live != null ? 0 : 2) + (m.identified ? 0 : 1);
    machines.sort((a, b) {
      final r = rank(a) - rank(b);
      return r != 0 ? r : a.name.compareTo(b.name);
    });
    return machines;
  }

  /// Removes the machine (long press on the card): every address from every
  /// source; it reappears if it is still on the network on the next scan.
  Future<void> _forgetMachine(Machine m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Forget "${m.name}"'),
        content: const Text(
            'Its addresses and saved passwords are removed. If it is still on your network it shows up again on the next scan.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Forget')),
        ],
      ),
    );
    if (ok != true) return;
    for (final r in m.routes) {
      await _removeAddress(r);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final ui = HomeUi(dark);

    return Scaffold(
      backgroundColor: ui.bg,
      body: SafeArea(
        child: Stack(
          children: [
            // Soft background glows
            Positioned(
                top: -140, right: -100, child: _glow(ui.accent, 380, dark)),
            Positioned(
                bottom: -160, left: -120, child: _glow(ui.violet, 420, dark)),
            Center(
              child: SingleChildScrollView(
                padding:
                    const EdgeInsets.symmetric(vertical: 30, horizontal: 24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: ListenableBuilder(
                    listenable: Listenable.merge(
                        [gFFI.lanPeersModel, gFFI.recentPeersModel, _rev]),
                    builder: (context, _) {
                      final machines = _machines();
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _header(ui),
                          const SizedBox(height: 26),
                          _sectionTitle(ui, 'YOUR COMPUTERS',
                              trailing: _scanIndicator(ui)),
                          const SizedBox(height: 10),
                          _machineCards(ui, machines),
                          const SizedBox(height: 16),
                          _manualCard(ui, forceOpen: machines.isEmpty),
                          const SizedBox(height: 18),
                          Center(
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.lock_outline,
                                    size: 12, color: ui.muted),
                                const SizedBox(width: 6),
                                Text('Direct connection · no relay servers',
                                    style: TextStyle(
                                        color: ui.muted, fontSize: 12)),
                              ],
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
            if (isDesktop) ...[
              // The window has no native title bar: a draggable top strip
              // + our own window controls.
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: 44,
                child: DragToMoveArea(
                    child: Container(color: Colors.transparent)),
              ),
              Positioned(
                top: 10,
                right: 10,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _winBtn(ui, Icons.minimize_rounded, 'Minimize',
                        () => windowManager.minimize()),
                    const SizedBox(width: 4),
                    _winBtn(ui, Icons.close_rounded, 'Close', _closeApp,
                        danger: true),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _winBtn(
          HomeUi ui, IconData icon, String tooltip, VoidCallback onTap,
          {bool danger = false}) =>
      Tooltip(
        message: tooltip,
        waitDuration: const Duration(milliseconds: 400),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          hoverColor:
              danger ? const Color(0x33E5484D) : ui.border,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Icon(icon, size: 16, color: ui.muted),
          ),
        ),
      );

  Future<void> _closeApp() async {
    await windowManager.setPreventClose(false);
    await windowManager.close();
  }

  Widget _glow(Color color, double size, bool dark) => IgnorePointer(
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(colors: [
              color.withOpacity(dark ? 0.10 : 0.12),
              color.withOpacity(0),
            ]),
          ),
        ),
      );

  Widget _header(HomeUi ui) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Brand mark: gradient tile + monitor (the same glyph as the app
              // icon, see tools/branding/make-icons.ps1).
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [ui.accent, ui.violet],
                  ),
                ),
                child: const Icon(Icons.desktop_windows_rounded,
                    size: 21, color: Colors.white),
              ),
              const SizedBox(width: 12),
              ShaderMask(
                shaderCallback: (b) =>
                    LinearGradient(colors: [ui.accent, ui.violet])
                        .createShader(b),
                child: const Text('Remote Display',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 30,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.8)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text('Connect to your computer',
              style: TextStyle(color: ui.muted, fontSize: 14)),
          const SizedBox(height: 8),
          // About row: website, source (AGPL §13: users interacting over the
          // network must be offered the source), contact, and attribution.
          Wrap(
            spacing: 14,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _aboutLink(ui, 'remotedisplay.app', 'https://remotedisplay.app'),
              _aboutLink(ui, 'GitHub',
                  'https://github.com/SamuelRioTz/remotedisplay'),
              _aboutLink(ui, 'info@remotedisplay.app',
                  'mailto:info@remotedisplay.app'),
              Text('Built on RustDesk · AGPL-3.0',
                  style: TextStyle(color: ui.muted, fontSize: 12)),
              // Newer release on GitHub (checked once per launch).
              ValueListenableBuilder<String?>(
                valueListenable: UpdateCheck.available,
                builder: (_, v, __) => v == null
                    ? const SizedBox.shrink()
                    : _aboutLink(ui, 'Version $v available',
                        UpdateCheck.releasesPage),
              ),
            ],
          ),
        ],
      );

  Widget _aboutLink(HomeUi ui, String label, String url) => GestureDetector(
        onTap: () =>
            launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Text(label,
              style: TextStyle(
                  color: ui.muted,
                  fontSize: 12,
                  decoration: TextDecoration.underline)),
        ),
      );

  Widget _sectionTitle(HomeUi ui, String text, {Widget? trailing}) => Row(
        children: [
          Text(text,
              style: TextStyle(
                  color: ui.muted,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.2)),
          const Spacer(),
          if (trailing != null) trailing,
        ],
      );

  Widget _scanIndicator(HomeUi ui) => _scanning
      ? SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(strokeWidth: 1.5, color: ui.muted))
      : Tooltip(
          message: 'Refresh: scan the network and re-check every address',
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: _refresh,
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Icon(Icons.refresh, size: 16, color: ui.muted),
            ),
          ),
        );

  Widget _machineCards(HomeUi ui, List<Machine> machines) {
    if (machines.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 20),
        decoration: ui.cardDeco,
        child: Row(
          children: [
            Icon(Icons.radar, size: 18, color: ui.muted),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _scanning
                    ? 'Looking for computers on your network…'
                    : 'No computers yet. Start Remote Display Server on the Mac (same network, or Tailscale on both) or enter its address below.',
                style: TextStyle(color: ui.muted, fontSize: 13),
              ),
            ),
          ],
        ),
      );
    }
    return Column(
      children: [
        for (final m in machines)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _MachineCard(
              machine: m,
              ui: ui,
              enabled: !_connecting,
              onConnect: (ip) => _openConnect(m, ip: ip),
              onTap: () => _openConnect(m),
              onSettings: () => _openSettings(m),
              onForget: () => _forgetMachine(m),
            ),
          ),
      ],
    );
  }

  /// "Manual connection" card, collapsed by default (opens on its own if no
  /// machine is known). A machine connected this way joins the list above.
  Widget _manualCard(HomeUi ui, {required bool forceOpen}) {
    final open = _manualOpen || forceOpen;

    void go() =>
        _connect(_ip.text.trim(), password: _pw.text.isEmpty ? null : _pw.text);

    final body = Padding(
      padding: const EdgeInsets.fromLTRB(18, 2, 18, 18),
      child: Column(
        children: [
          TextField(
            controller: _ip,
            style: TextStyle(color: ui.fg, fontSize: 15),
            decoration: ui.input(
                'IP or Tailscale IP  (e.g. 192.168.1.117)',
                Icons.computer_outlined),
            onSubmitted: (_) => go(),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _pw,
            obscureText: true,
            style: TextStyle(color: ui.fg, fontSize: 15),
            decoration: ui.input('Password', Icons.lock_outline),
            onSubmitted: (_) => go(),
          ),
          const SizedBox(height: 16),
          ui.primaryButton(
              label: 'Connect',
              onPressed: _connecting ? null : go,
              busy: _connecting),
        ],
      ),
    );

    return Container(
      decoration: ui.cardDeco,
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: forceOpen
                ? null
                : () => setState(() => _manualOpen = !_manualOpen),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
              child: Row(
                children: [
                  Icon(Icons.keyboard_alt_outlined, size: 17, color: ui.muted),
                  const SizedBox(width: 10),
                  Text('Manual connection',
                      style: TextStyle(
                          color: ui.fgSoft,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w500)),
                  const Spacer(),
                  AnimatedRotation(
                    turns: open ? 0.5 : 0,
                    duration: const Duration(milliseconds: 150),
                    child: Icon(Icons.expand_more, size: 18, color: ui.muted),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: open ? body : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}

/// Card for a known machine: icon, name, its routes (LAN / Tailscale) as
/// chips with their reachability, a settings button. Tapping the card connects
/// through the best route, tapping a chip through that address.
class _MachineCard extends StatefulWidget {
  final Machine machine;
  final HomeUi ui;
  final bool enabled;
  final void Function(String ip) onConnect;
  final VoidCallback onTap;
  final VoidCallback onSettings;
  final VoidCallback onForget;

  const _MachineCard({
    required this.machine,
    required this.ui,
    required this.enabled,
    required this.onConnect,
    required this.onTap,
    required this.onSettings,
    required this.onForget,
  });

  @override
  State<_MachineCard> createState() => _MachineCardState();
}

class _MachineCardState extends State<_MachineCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final m = widget.machine;
    final ui = widget.ui;
    final subtitle = [
      if (m.username.isNotEmpty) m.username,
      if (m.platform.isNotEmpty) m.platform,
    ].join(' · ');
    final offline = !m.probing && m.live == null;

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: widget.enabled ? SystemMouseCursors.click : MouseCursor.defer,
      child: GestureDetector(
        onTap: widget.enabled ? widget.onTap : null,
        onLongPress: widget.onForget,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.fromLTRB(14, 14, 8, 14),
          decoration: BoxDecoration(
            color: ui.card,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
                color: _hover ? ui.accent.withOpacity(0.55) : ui.border),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Opacity(
                opacity: offline ? 0.55 : 1,
                child: Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(11),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        ui.accent.withOpacity(m.identified ? 0.22 : 0.10),
                        ui.violet.withOpacity(m.identified ? 0.22 : 0.10),
                      ],
                    ),
                  ),
                  child: Icon(platformIcon(m.platform),
                      size: 21,
                      color: m.identified ? ui.accentSoft : ui.muted),
                ),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(m.name,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: offline ? ui.fgSoft : ui.fg,
                                  fontSize: 14.5,
                                  fontWeight: FontWeight.w600)),
                        ),
                        if (subtitle.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(subtitle,
                                overflow: TextOverflow.ellipsis,
                                style:
                                    TextStyle(color: ui.muted, fontSize: 12)),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 7),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final r in m.routes)
                          _routeChip(ui, r, enabled: widget.enabled),
                      ],
                    ),
                    if (offline) ...[
                      const SizedBox(height: 6),
                      Text(
                        m.routes.any((r) => r.tailscale)
                            ? 'Not reachable from this network right now'
                            : 'Not reachable from this network · add its Tailscale address in settings to reach it from anywhere',
                        style: TextStyle(color: ui.muted, fontSize: 11.5),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 4),
              if (m.saved) _savedBadge(ui),
              IconButton(
                tooltip: 'Settings',
                visualDensity: VisualDensity.compact,
                onPressed: widget.onSettings,
                icon: Icon(Icons.tune_rounded, size: 18, color: ui.muted),
              ),
              Icon(Icons.arrow_forward_rounded,
                  size: 18,
                  color: _hover || !isDesktop
                      ? ui.accentSoft
                      : ui.accentSoft.withOpacity(0.55)),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    );
  }

  /// Indicator for saved access (password remembered, one tap connects):
  /// a small, dim key next to the arrow, with no background or text.
  Widget _savedBadge(HomeUi ui) => Tooltip(
        message: 'Password saved: one tap connects',
        child: Padding(
          padding: const EdgeInsets.only(right: 2),
          child: Icon(Icons.key_rounded,
              size: 14, color: ui.muted.withOpacity(0.7)),
        ),
      );

  Widget _routeChip(HomeUi ui, MachineRoute r, {required bool enabled}) {
    final dim = r.reachable == false;
    return Tooltip(
      message: '${routeStatus(r)} · tap to connect through this address',
      waitDuration: const Duration(milliseconds: 500),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: enabled ? () => widget.onConnect(r.ip) : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: ui.chip,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: ui.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              statusDot(ui, r, size: 6),
              const SizedBox(width: 6),
              Icon(r.tailscale ? Icons.vpn_lock_outlined : Icons.lan_outlined,
                  size: 12, color: ui.muted.withOpacity(dim ? 0.6 : 1)),
              const SizedBox(width: 5),
              Text('${r.kind} · ${r.ip}',
                  style: TextStyle(
                      color: dim ? ui.muted.withOpacity(0.8) : ui.fgSoft,
                      fontSize: 11.5,
                      decoration: dim ? TextDecoration.lineThrough : null,
                      decorationColor: ui.muted.withOpacity(0.6),
                      fontFeatures: const [FontFeature.tabularFigures()])),
            ],
          ),
        ),
      ),
    );
  }
}
