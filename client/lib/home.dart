import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show mapEquals, setEquals;
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart' hide Dialog;
import 'package:get/get.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/utils/multi_window_manager.dart';
import 'package:flutter_hbb/utils/platform_channel.dart';
import 'package:uni_links/uni_links.dart' show getInitialLink, uriLinkStream;
import 'package:url_launcher/url_launcher.dart' show LaunchMode, launchUrl;
import 'package:window_manager/window_manager.dart';

import 'app_version.dart';
import 'connect_sheet.dart';
import 'first_frame.dart';
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
/// IPs (LAN/Tailscale) of the same machine are grouped by the engine id the
/// host announces (in its discovery reply, in the login response, and since
/// 1.0.15 also for the other addresses it names there), else by the salt the
/// host sends first on every direct TCP connection — the probes below read it,
/// so two addresses answering with one salt are one computer even when no
/// discovery reply ever reaches this client (see `first_frame.dart`) —, else
/// via hostname (+ `tailscale status` on desktop). Every refresh also probes
/// each address with a TCP connect to the direct-access port. Only the
/// computers that answer on some address from the current network are listed
/// (a route that does not answer shows as such and a tap uses the one that
/// does); the others — old leases, machines that are off, another network —
/// stay behind a one-line note the user can expand.
class ClientHome extends StatefulWidget {
  const ClientHome({super.key});

  @override
  State<ClientHome> createState() => _ClientHomeState();
}

class _ClientHomeState extends State<ClientHome>
    with WidgetsBindingObserver, WindowListener {
  static const _manualKey = 'rd-manual-routes';
  static const _preferredKey = 'rd-preferred-routes';
  static const _aliasKey = 'rd-aliases';
  static const _fingerprintKey = 'rd-fingerprints';
  static const _lastKeysKey = 'rd-last-keys';
  static const _lastFpsKey = 'rd-last-fingerprints';
  static const _discoveryHandler = 'rd-home-discovery';
  // The engine's event with the discovered peers (LoadEvent.lan in flutter_hbb).
  static const _lanPeersEvent = 'load_lan_peers';
  static const _probeTimeout = Duration(milliseconds: 1500);
  // How long a probe waits for the host's first frame once connected.
  static const _frameTimeout = Duration(milliseconds: 1000);
  static const _probeEvery = Duration(seconds: 20);

  final _ip = TextEditingController();
  final _pw = TextEditingController();
  bool _connecting = false;
  bool _scanning = false;
  bool _manualOpen = false;
  bool _showPw = false;
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
  // Address used last per machine (machine key → ip): what a plain tap uses.
  Map<String, String> _preferred = {};
  // Names given by the user (machine key → alias).
  Map<String, String> _aliases = {};
  // Fingerprint per address (ip → the salt its host sent first, see
  // first_frame.dart), from the probes; persisted so a machine that is off
  // keeps its routes together. Grouping only: never written to a peer file.
  Map<String, String> _fp = {};
  // The card each address was filed under last time (ip → machine key), and
  // the salt it answered with then, so what the user stored under a key
  // follows the addresses when the key changes — and only while an address
  // still answers as the same host (see _migrateKeys).
  Map<String, String> _lastKeys = {};
  Map<String, String> _lastFps = {};
  // Last TCP probe verdict per known address (null = never probed). A
  // re-check keeps the previous verdict until the new one arrives.
  final Map<String, bool?> _reach = {};
  // Addresses whose probe is in flight right now.
  final Set<String> _probing = {};
  // Discovery runs in a row that found hosts on the port but got no reply
  // to the UDP pings (see _onDiscoveryStats); two of them show the note.
  int _silentScans = 0;
  int _lastDiscoveryRun = -1;
  bool _discoveryBlocked = false;
  bool _migrationQueued = false;
  // The user asked to see the computers that do not answer from this network
  // (hidden by default; not persisted, every launch starts clean).
  bool _showUnreachable = false;
  // Bumped on every change the sheets should redraw for.
  final _rev = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (isDesktop) windowManager.addListener(this);
    if (isDesktop) {
      // Follow a system light/dark switch while the window is open, as the
      // engine's own App does (this client runs its own root widget, which
      // evaluated the theme once). On Windows the runner switches the native
      // title bar on the same setting, so bar and content stay in step.
      WidgetsBinding.instance.platformDispatcher.onPlatformBrightnessChanged =
          () {
        WidgetsBinding.instance.handlePlatformBrightnessChanged();
        if (MyTheme.getThemeModePreference() != ThemeMode.system) return;
        final dark =
            WidgetsBinding.instance.platformDispatcher.platformBrightness ==
                Brightness.dark;
        Get.changeThemeMode(dark ? ThemeMode.dark : ThemeMode.light);
      };
    }
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
    // The same event the lan peers model consumes also carries the engine's
    // tally of the discovery run; a second handler reads that part.
    platformFFI.registerEventHandler(
        _lanPeersEvent, _discoveryHandler, _onDiscoveryStats,
        replace: true);
    _manual = _loadMap(_manualKey);
    _preferred = _loadMap(_preferredKey);
    _aliases = _loadMap(_aliasKey);
    _fp = _loadMap(_fingerprintKey);
    _lastKeys = _loadMap(_lastKeysKey);
    _lastFps = _loadMap(_lastFpsKey);
    bind.mainLoadLanPeers(); // the cached ones, instantly
    UpdateCheck.run();
    AppVersion.load();
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
    if (isDesktop) windowManager.removeListener(this);
    gFFI.lanPeersModel.removeListener(_onPeersChanged);
    gFFI.recentPeersModel.removeListener(_onPeersChanged);
    platformFFI.unregisterEventHandler(_lanPeersEvent, _discoveryHandler);
    _linkSub?.cancel();
    _scanTimer?.cancel();
    _probeTimer?.cancel();
    _rev.dispose();
    _ip.dispose();
    _pw.dispose();
    super.dispose();
  }

  /// The native close button quits the app (main.dart keeps preventClose on
  /// so the window is not torn down under the sessions): save the window
  /// position, close the session windows gracefully, then let the window go.
  /// macOS keeps the process alive after its last window, so it is
  /// terminated explicitly there.
  @override
  void onWindowClose() async {
    if (!await windowManager.isPreventClose()) return;
    try {
      await saveWindowPosition(WindowType.Main);
      await rustDeskWinManager.closeAllSubWindows();
    } catch (e) {
      debugPrint('[client home] closing the session windows failed: $e');
    }
    await windowManager.setPreventClose(false);
    await windowManager.close();
    if (isMacOS) RdPlatformChannel.instance.terminate();
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
    if (!mounted) return;
    _rev.value++;
    // Cards may have been re-keyed by what just changed: let what the user
    // stored under the old keys follow (once per burst of changes).
    if (_migrationQueued) return;
    _migrationQueued = true;
    scheduleMicrotask(() {
      _migrationQueued = false;
      _migrateKeys();
    });
  }

  /// The engine's tally of the discovery run, pushed with every
  /// `load_lan_peers`: replies to its UDP pings against hosts the port scan
  /// found. Two finished runs in a row with hosts on the port and no reply at
  /// all mean the replies do not reach this client — a firewall rule on this
  /// computer, typically; computers are then found by their open port only
  /// and identified once connected to. The home says so under the cards.
  Future<void> _onDiscoveryStats(Map<String, dynamic> evt) async {
    final r = foldDiscoveryTally(DiscoveryTally.parse(evt['discovery']),
        silentScans: _silentScans, lastRun: _lastDiscoveryRun);
    _silentScans = r.silentScans;
    _lastDiscoveryRun = r.lastRun;
    final blocked = _silentScans >= 2;
    if (blocked != _discoveryBlocked && mounted) {
      setState(() => _discoveryBlocked = blocked);
    }
  }

  /// Aliases, remembered routes and manual addresses are stored under a
  /// machine's key. When an address moves to another card — its host got an
  /// engine id, a fingerprint tied it to the machine it belongs to, the host
  /// was renamed — what the user stored under the vanished key follows it:
  /// by the key each address was filed under last time (`rd-last-keys`) and,
  /// for a remembered route, by the address itself (so it works the first
  /// time too, before any key was recorded).
  Future<void> _migrateKeys() async {
    if (!mounted || _migrating) return;
    _migrating = true;
    try {
      await _migrateKeysNow();
    } finally {
      _migrating = false;
    }
  }

  bool _migrating = false;

  Future<void> _migrateKeysNow() async {
    final machines = _machines();
    final keyOf = keyOfRoutes(machines);
    // The address still answers as the host it was filed under: a probe that
    // finished this session, with the salt recorded when its key was (an
    // address re-leased to another computer moves nothing of the old one).
    bool sameHost(String ip) {
      if (_reach[ip] != true || _probing.contains(ip)) return false;
      final was = _lastFps[ip], now = _fp[ip];
      return was == null || was.isEmpty || now == null || was == now;
    }

    // vanished key → the key its addresses sit under now
    final moved = movedKeys(
        lastKeys: _lastKeys,
        preferred: _preferred,
        machines: machines,
        sameHost: sameHost);
    var aliases = false, preferred = false, manual = false;
    moved.forEach((old, now) {
      final a = _aliases.remove(old);
      if (a != null) {
        aliases = true;
        _aliases.putIfAbsent(now, () => a);
      }
      final p = _preferred.remove(old);
      if (p != null) {
        preferred = true;
        if (!_preferred.containsKey(now) && keyOf[p] == now) _preferred[now] = p;
      }
      _manual.updateAll((ip, k) {
        if (k != old) return k;
        manual = true;
        return now;
      });
    });
    if (!mapEquals(keyOf, _lastKeys)) {
      _lastKeys = keyOf;
      await bind.mainSetLocalOption(
          key: _lastKeysKey, value: jsonEncode(_lastKeys));
    }
    final fps = {
      for (final ip in keyOf.keys)
        if (_fp[ip] != null) ip: _fp[ip]!
    };
    if (!mapEquals(fps, _lastFps)) {
      _lastFps = fps;
      await bind.mainSetLocalOption(
          key: _lastFpsKey, value: jsonEncode(_lastFps));
    }
    if (aliases) {
      await bind.mainSetLocalOption(
          key: _aliasKey, value: jsonEncode(_aliases));
    }
    if (preferred) {
      await bind.mainSetLocalOption(
          key: _preferredKey, value: jsonEncode(_preferred));
    }
    if (manual) await _saveManual();
    if ((aliases || preferred || manual) && mounted) {
      setState(() {});
      _rev.value++;
    }
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

  /// Addresses that have never been probed (new discoveries), plus the ones
  /// the engine just saw online while our last verdict said no: a machine
  /// that came back, or a first hop slower than our timeout. A hidden
  /// machine would otherwise wait for the next 20-second round to reappear.
  Future<void> _probeNew() => _probe({
        for (final ip in _knownIps())
          if (!_reach.containsKey(ip)) ip,
        for (final p in gFFI.lanPeersModel.peers)
          if (p.online &&
              _reach[p.id] == false &&
              !_probing.contains(p.id) &&
              !_tsSelf.contains(p.id))
            p.id,
      });

  /// Addresses may carry a port ("host:port") when the server is not on the
  /// default direct-access port; the engine accepts them as ids.
  ({String host, int port}) _split(String id) => splitAddress(id, _port);

  Future<void> _probe(Set<String> ips) async {
    if (ips.isEmpty) return;
    if (mounted) {
      setState(() {
        for (final ip in ips) {
          // Keep the last verdict while re-checking: the home lists only the
          // computers that answer, so resetting to "unknown" every 20 s would
          // make every card blink out of the list during each probe.
          _probing.add(ip);
          _reach.putIfAbsent(ip, () => null);
        }
      });
    }
    _bump();
    var fingerprints = false;
    await Future.wait(ips.map((ip) async {
      var ok = false;
      String? salt;
      try {
        final a = _split(ip);
        // The connect timeout only starts once the name is resolved; the
        // outer one caps a slow resolver for a hostname typed by hand.
        final s = await Socket.connect(a.host, a.port, timeout: _probeTimeout)
            .timeout(_probeTimeout * 2);
        ok = true;
        // The host speaks first on a direct connection: the salt in its first
        // frame fingerprints the machine (first_frame.dart). Bounded, so a
        // host that sends nothing costs the verdict a second at most.
        try {
          salt = firstFrameSalt(await s.first.timeout(_frameTimeout));
        } catch (_) {}
        s.destroy();
      } catch (_) {}
      // An address forgotten while its probe ran is gone from _probing:
      // drop that verdict instead of resurrecting the entry.
      if (mounted && _probing.contains(ip)) {
        setState(() {
          _reach[ip] = ok;
          _probing.remove(ip);
          if (salt != null && _fp[ip] != salt) {
            _fp[ip] = salt;
            fingerprints = true;
          }
        });
      }
    }));
    if (fingerprints) {
      await bind.mainSetLocalOption(
          key: _fingerprintKey, value: jsonEncode(_fp));
    }
    _bump();
  }

  // ── manual addresses ────────────────────────────────────────────────────

  /// String→string map stored as JSON in one of the engine's local options.
  Map<String, String> _loadMap(String key) {
    try {
      final raw = bind.mainGetLocalOption(key: key);
      if (raw.isEmpty) return {};
      final data = jsonDecode(raw);
      if (data is Map) {
        return {
          for (final e in data.entries)
            if (e.key is String && e.value is String) e.key: e.value
        };
      }
    } catch (_) {}
    return {};
  }

  Future<void> _saveManual() async {
    await bind.mainSetLocalOption(key: _manualKey, value: jsonEncode(_manual));
  }

  /// Remembers the address used for a machine (shown as its selected network).
  Future<void> _rememberRoute(String machineKey, String ip) async {
    if (_preferred[machineKey] == ip) return;
    _preferred[machineKey] = ip;
    if (mounted) setState(() {});
    _bump();
    await bind.mainSetLocalOption(
        key: _preferredKey, value: jsonEncode(_preferred));
  }

  /// Name chosen by the user for a machine; empty removes it.
  Future<void> _rename(String machineKey, String alias) async {
    final a = alias.trim();
    if (a.isEmpty) {
      _aliases.remove(machineKey);
    } else {
      _aliases[machineKey] = a;
    }
    if (mounted) setState(() {});
    _bump();
    await bind.mainSetLocalOption(key: _aliasKey, value: jsonEncode(_aliases));
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

  /// Connects to [m] through [ip], remembering that choice. Without a typed
  /// password, an address that has none saved borrows the one saved for
  /// another address seen to be the same computer (same engine id or salt,
  /// so the hash is valid) — not from one grouped here by name alone.
  Future<void> _connectVia(Machine m, String ip,
      {String? password, bool remember = true}) async {
    await _rememberRoute(m.key, ip);
    final route = m.route(ip);
    if (password == null && route != null && !route.saved) {
      final donor = m.donorFor(route);
      if (donor != null) {
        try {
          await bind.mainSetPeerOption(
              id: ip, key: 'rd-copy-password-from', value: donor.ip);
        } catch (_) {}
        await _refreshSaved();
      }
    }
    return _connect(ip, password: password, remember: remember);
  }

  /// Tap on a machine, or on one of its route chips ([ip]).
  ///
  /// The network used last time is remembered per machine: while it answers,
  /// a tap connects through it (one tap when a password is known). When it is
  /// gone or does not answer from this network, or when the machine has several
  /// networks and none was ever chosen, the connect sheet asks which one to
  /// use (and for the password if none is known).
  Future<void> _openConnect(Machine m, {String? ip}) async {
    if (_connecting) return;
    final ui = HomeUi(Theme.of(context).brightness == Brightness.dark);
    final explicit = ip == null ? null : m.route(ip);
    MachineRoute? target = explicit;
    String? note;
    if (explicit == null) {
      final rememberedIp = _preferred[m.key];
      final remembered = m.preferred;
      if (rememberedIp != null && remembered == null) {
        note = 'The address you used last ($rememberedIp) is no longer listed. '
            'Choose a network.';
      } else if (remembered != null && remembered.reachable == false) {
        note = '${remembered.kind} · ${remembered.ip}, used last time, does not '
            'answer from this network. Choose another one.';
      } else if (remembered != null) {
        target = remembered;
      } else if (m.routes.length == 1) {
        target = m.routes.first;
      }
      // several networks and none chosen yet → ask
    }
    if (target != null && (target.saved || m.donorFor(target) != null)) {
      return _connectVia(m, target.ip);
    }
    if (!mounted) return;
    await _showSheet((ctx) => ConnectSheet(
          ui: ui,
          machine: m,
          initialIp: (target ?? m.live ?? m.best).ip,
          note: note,
          onConnect: (ip, {password, required remember}) =>
              _connectVia(m, ip, password: password, remember: remember),
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
          onRename: (a) => _rename(key, a),
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
    // Centered and capped: on an iPad a full-width sheet puts the buttons a
    // long way from the text.
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 560),
      backgroundColor: ui.card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: SingleChildScrollView(child: builder(ctx)),
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
    if (_preferred.values.contains(r.ip)) {
      _preferred.removeWhere((_, v) => v == r.ip);
      await bind.mainSetLocalOption(
          key: _preferredKey, value: jsonEncode(_preferred));
    }
    try {
      await bind.mainRemoveDiscovered(id: r.ip);
      await bind.mainRemovePeer(id: r.ip);
    } catch (_) {}
    _reach.remove(r.ip);
    _probing.remove(r.ip);
    if (_fp.remove(r.ip) != null) {
      await bind.mainSetLocalOption(
          key: _fingerprintKey, value: jsonEncode(_fp));
    }
    if (_lastKeys.remove(r.ip) != null) {
      await bind.mainSetLocalOption(
          key: _lastKeysKey, value: jsonEncode(_lastKeys));
    }
    if (_lastFps.remove(r.ip) != null) {
      await bind.mainSetLocalOption(
          key: _lastFpsKey, value: jsonEncode(_lastFps));
    }
    bind.mainLoadLanPeers();
    bind.mainLoadRecentPeers();
    if (mounted) setState(() {});
    _bump();
  }

  // 100.64.0.0/10 — CGNAT range used by Tailscale.
  bool _isTailscale(String ip) => isTailscaleAddress(ip);

  /// First label of the hostname, normalized ("Mac.lan" → "mac").
  String? _hostLabel(String hostname) => hostLabel(hostname);

  /// Groups every known address into machines (1 card per computer); the
  /// rules live in `machines.dart` (`groupMachines`) so they can be tested.
  List<Machine> _machines() => groupMachines(GroupingInput(
        discovered: gFFI.lanPeersModel.peers,
        recent: gFFI.recentPeersModel.peers,
        manual: _manual,
        fingerprints: _fp,
        tsName: _tsName,
        tsPlatform: _tsPlatform,
        tsSelf: _tsSelf,
        tsAll: _tsAll,
        reach: _reach,
        probing: _probing,
        saved: _savedIps,
        aliases: _aliases,
        preferred: _preferred,
      ));

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
            // Content scrolls; the footer (version, links, credits) stays at
            // the bottom of the window, out of the way of the computers.
            Column(
              children: [
                Expanded(
                  child: Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(28, 34, 28, 16),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 600),
                        child: ListenableBuilder(
                          listenable: Listenable.merge([
                            gFFI.lanPeersModel,
                            gFFI.recentPeersModel,
                            _rev
                          ]),
                          builder: (context, _) {
                            final machines = _machines();
                            // Only the computers that answer from this
                            // network are listed; the rest stay behind a
                            // one-line note the user can expand.
                            final available =
                                machines.where((m) => m.available).toList();
                            final unreachable =
                                machines.where((m) => !m.available).toList();
                            return Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _header(ui),
                                const SizedBox(height: 28),
                                _sectionTitle(ui, 'YOUR COMPUTERS',
                                    trailing: _scanIndicator(ui)),
                                const SizedBox(height: 10),
                                _machineCards(ui, available, unreachable),
                                const SizedBox(height: 16),
                                _manualCard(ui, forceOpen: machines.isEmpty),
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
                _footer(ui),
              ],
            ),
            if (isMacOS)
              // The window keeps the native controls only: on macOS the
              // traffic lights sit over a hidden title bar, so this strip is
              // where the bar would be and lets the window be dragged; on
              // Windows the regular title bar does all of that (main.dart).
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: 44,
                child: DragToMoveArea(
                    child: Container(color: Colors.transparent)),
              ),
          ],
        ),
      ),
    );
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

  Widget _header(HomeUi ui) => Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Brand mark: gradient tile + monitor (the same glyph as the app
          // icon, see tools/branding/make-icons.ps1).
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [ui.accent, ui.violet],
              ),
            ),
            child: const Icon(Icons.desktop_windows_rounded,
                size: 24, color: Colors.white),
          ),
          const SizedBox(width: 14),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ShaderMask(
                shaderCallback: (b) =>
                    LinearGradient(colors: [ui.accent, ui.violet])
                        .createShader(b),
                child: const Text('Remote Display',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.8,
                        height: 1.1)),
              ),
              const SizedBox(height: 2),
              Text('Connect to your Mac',
                  style: TextStyle(color: ui.muted, fontSize: 13.5)),
            ],
          ),
        ],
      );

  /// Bottom strip: version (so a screenshot always tells which build), the
  /// links (website, source — AGPL §13: users interacting over the network
  /// must be offered the source —, contact), attribution and the
  /// direct-connection note. A newer release shows up here as a link.
  Widget _footer(HomeUi ui) => Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: ui.border)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 14,
              runSpacing: 4,
              children: [
                ValueListenableBuilder<String>(
                  valueListenable: AppVersion.label,
                  builder: (_, v, __) => Text(
                      v.isEmpty ? 'Remote Display' : 'Remote Display $v',
                      style: TextStyle(
                          color: ui.fgSoft,
                          fontSize: 12,
                          fontWeight: FontWeight.w600)),
                ),
                ValueListenableBuilder<String?>(
                  valueListenable: UpdateCheck.available,
                  builder: (_, v, __) => v == null
                      ? const SizedBox.shrink()
                      : _aboutLink(ui, 'Version $v available',
                          UpdateCheck.releasesPage,
                          color: ui.accentSoft),
                ),
                Text('Built on RustDesk · AGPL-3.0',
                    style: TextStyle(color: ui.muted, fontSize: 12)),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 14,
              runSpacing: 4,
              children: [
                _aboutLink(ui, 'remotedisplay.app', 'https://remotedisplay.app'),
                _aboutLink(ui, 'GitHub',
                    'https://github.com/SamuelRioTz/remotedisplay'),
                _aboutLink(ui, 'info@remotedisplay.app',
                    'mailto:info@remotedisplay.app'),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.lock_outline, size: 12, color: ui.muted),
                    const SizedBox(width: 5),
                    Text('Direct connection · no relay servers',
                        style: TextStyle(color: ui.muted, fontSize: 12)),
                  ],
                ),
              ],
            ),
          ],
        ),
      );

  Widget _aboutLink(HomeUi ui, String label, String url, {Color? color}) =>
      GestureDetector(
        onTap: () =>
            launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Text(label,
              style: TextStyle(
                  color: color ?? ui.muted,
                  fontSize: 12,
                  decoration: TextDecoration.underline,
                  decorationColor: color ?? ui.muted)),
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

  /// The cards: [available] computers always, [unreachable] ones only when
  /// the user expands the note under the list (so an old lease or a machine
  /// that is off does not sit on the home, yet can still be forgotten or
  /// given a Tailscale address from its settings).
  Widget _machineCards(
      HomeUi ui, List<Machine> available, List<Machine> unreachable) {
    // Once nothing is left to show, fold the toggle again so the next machine
    // that goes off does not come straight back as a dimmed card.
    if (_showUnreachable && unreachable.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _showUnreachable = false);
      });
    }
    final shown = [
      ...available,
      if (_showUnreachable) ...unreachable,
    ];
    // Judge only on first verdicts: a re-check in flight keeps the last one,
    // so the note and the texts below do not blink on every 20-second round.
    final unknown = unreachable.any((m) => m.unknown);
    // Nothing answers yet: while a scan runs or an address has no verdict the
    // list is simply filling up; afterwards say which situation it is.
    final settling = _scanning || unknown;
    final empty = shown.isEmpty
        ? Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 20),
            decoration: ui.cardDeco,
            child: Row(
              children: [
                Icon(Icons.radar, size: 18, color: ui.muted),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    settling
                        ? 'Looking for computers on your network…'
                        : unreachable.isNotEmpty
                            ? 'No computers answer from this network right now.'
                            : 'No computers yet. Start Remote Display Server on the Mac (same network, or Tailscale on both) or enter its address below.',
                    style: TextStyle(color: ui.muted, fontSize: 13),
                  ),
                ),
              ],
            ),
          )
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (empty != null)
          Padding(padding: const EdgeInsets.only(bottom: 10), child: empty),
        for (final m in shown)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _MachineCard(
              machine: m,
              ui: ui,
              enabled: !_connecting,
              onSelect: (ip) => _rememberRoute(m.key, ip),
              onTap: () => _openConnect(m),
              onSettings: () => _openSettings(m),
              onForget: () => _forgetMachine(m),
            ),
          ),
        if (unreachable.isNotEmpty && !unknown)
          _unreachableNote(ui, unreachable.length),
        if (_discoveryBlocked) _discoveryNote(ui),
      ],
    );
  }

  /// One muted line: the engine's discovery pings get no reply although
  /// computers answer on their port (two runs in a row), so new computers are
  /// found by the port scan only and identified once connected to. On a PC
  /// this is what a firewall rule dropping the app's inbound UDP looks like.
  Widget _discoveryNote(HomeUi ui) => Padding(
        padding:
            EdgeInsets.symmetric(horizontal: 6, vertical: isDesktop ? 6 : 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(Icons.wifi_tethering_off_rounded,
                  size: 14, color: ui.muted.withOpacity(0.8)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'No reply to network discovery: computers are found by their '
                'open port only. A firewall on this computer may be blocking '
                'the UDP replies to Remote Display (allow the app for inbound '
                'UDP).',
                style: TextStyle(color: ui.muted, fontSize: 12),
              ),
            ),
          ],
        ),
      );

  /// One muted line under the cards: how many known computers do not answer
  /// from this network. The whole line toggles their cards (Show/Hide), so
  /// it is a comfortable target on touch and the only way back to a machine
  /// that has to be forgotten or given another address.
  Widget _unreachableNote(HomeUi ui, int count) => InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => setState(() => _showUnreachable = !_showUnreachable),
        child: Padding(
          padding:
              EdgeInsets.symmetric(horizontal: 6, vertical: isDesktop ? 6 : 14),
          child: Row(
            children: [
              Icon(Icons.visibility_off_outlined,
                  size: 14, color: ui.muted.withOpacity(0.8)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  count == 1
                      ? '1 computer does not answer from this network'
                      : '$count computers do not answer from this network',
                  style: TextStyle(color: ui.muted, fontSize: 12),
                ),
              ),
              const SizedBox(width: 8),
              Text(_showUnreachable ? 'Hide' : 'Show',
                  style: TextStyle(
                      color: ui.accentSoft,
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      );

  /// "Manual connection" card, collapsed by default (opens on its own if no
  /// machine is known). A machine connected this way joins the list above.
  Widget _manualCard(HomeUi ui, {required bool forceOpen}) {
    final open = _manualOpen || forceOpen;

    Future<void> go() async {
      final ip = _ip.text.trim();
      if (ip.isEmpty) return;
      await _connect(ip, password: _pw.text.isEmpty ? null : _pw.text);
      // Never leave the password on screen; the machine now has its own card.
      _pw.clear();
      _ip.clear();
      if (mounted) setState(() => _manualOpen = false);
    }

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
            obscureText: !_showPw,
            style: TextStyle(color: ui.fg, fontSize: 15),
            decoration: ui.input('Password', Icons.lock_outline,
                suffix: eyeButton(
                    ui, _showPw, () => setState(() => _showPw = !_showPw))),
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

  /// A route chip was tapped: make it the selected network (no connection).
  final void Function(String ip) onSelect;
  final VoidCallback onTap;
  final VoidCallback onSettings;
  final VoidCallback onForget;

  const _MachineCard({
    required this.machine,
    required this.ui,
    required this.enabled,
    required this.onSelect,
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
    // Dimmed only once every address has a verdict and none answers; a
    // re-check in flight keeps the last verdict, so the look does not flip.
    final offline = !m.unknown && m.live == null;
    final pref = m.preferred;
    final prefLost = pref != null && pref.reachable == false;

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
                    // The name gets the whole line; user · platform below it.
                    Text(m.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: offline ? ui.fgSoft : ui.fg,
                            fontSize: 14.5,
                            fontWeight: FontWeight.w600)),
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: ui.muted, fontSize: 12)),
                    ],
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
                    ] else if (prefLost) ...[
                      const SizedBox(height: 6),
                      Text(
                        '${pref.kind} does not answer here · pick another network or tap to choose',
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
                icon: Icon(Icons.settings_outlined, size: 18, color: ui.muted),
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
    final selected = widget.machine.preferredIp == r.ip;
    return Tooltip(
      message: [
        routeStatus(r),
        selected ? 'selected network' : 'tap to select this network',
      ].join(' · '),
      waitDuration: const Duration(milliseconds: 500),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: enabled && !selected ? () => widget.onSelect(r.ip) : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            color: selected ? ui.accent.withOpacity(0.12) : ui.chip,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
                color: selected ? ui.accent.withOpacity(0.6) : ui.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (selected) ...[
                Icon(Icons.check_rounded, size: 12, color: ui.accentSoft),
                const SizedBox(width: 4),
              ],
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
