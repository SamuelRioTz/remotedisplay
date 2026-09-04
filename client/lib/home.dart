import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/peer_model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:uni_links/uni_links.dart' show getInitialLink, uriLinkStream;
import 'package:url_launcher/url_launcher.dart' show LaunchMode, launchUrl;
import 'package:window_manager/window_manager.dart';

import 'update_check.dart';

import 'session/mobile_session.dart';

/// Client home — discovered machines (cards, 1 per machine) + manual
/// connection. Discovery is done by the engine (UDP broadcast + direct port
/// scan on local subnets and Tailscale peers, see engine lan.rs); it arrives
/// via `load_lan_peers` into gFFI.lanPeersModel with id = IP. Here we group
/// the IPs (LAN/Tailscale) of the same machine via hostname +
/// `tailscale status`, to show ONE card per machine.
class ClientHome extends StatefulWidget {
  const ClientHome({super.key});

  @override
  State<ClientHome> createState() => _ClientHomeState();
}

class _Route {
  final String ip;
  final bool tailscale;
  _Route(this.ip, this.tailscale);
}

class _Machine {
  String name;
  String platform = '';
  String username = '';
  // One of its routes has a saved password → one tap connects.
  bool saved = false;
  final List<_Route> routes = [];
  _Machine({required this.name});

  /// LAN first; Tailscale as fallback.
  _Route get preferred =>
      routes.firstWhere((r) => !r.tailscale, orElse: () => routes.first);

  bool get identified => platform.isNotEmpty || username.isNotEmpty;
}

class _ClientHomeState extends State<ClientHome> {
  final _ip = TextEditingController();
  final _pw = TextEditingController();
  bool _connecting = false;
  bool _scanning = false;
  bool _manualOpen = false;
  Timer? _scanTimer;

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

  @override
  void initState() {
    super.initState();
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
    gFFI.lanPeersModel.addListener(_refreshSaved);
    gFFI.recentPeersModel.addListener(_refreshSaved);
    bind.mainLoadLanPeers(); // the cached ones, instantly
    UpdateCheck.run();
    bind.mainLoadRecentPeers(); // identity (real hostname) of already-connected IPs
    _discover();
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
    gFFI.lanPeersModel.removeListener(_refreshSaved);
    gFFI.recentPeersModel.removeListener(_refreshSaved);
    _linkSub?.cancel();
    _scanTimer?.cancel();
    _ip.dispose();
    _pw.dispose();
    super.dispose();
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
        }
        return;
      } catch (_) {}
    }
  }

  /// Which IPs have a saved password (async query to the engine); it is
  /// recalculated when peers change and when returning from a session.
  Future<void> _refreshSaved() async {
    final ids = <String>{
      ...gFFI.lanPeersModel.peers.map((p) => p.id),
      ...gFFI.recentPeersModel.peers.map((p) => p.id),
    };
    final saved = <String>{};
    for (final id in ids) {
      try {
        if (await bind.mainPeerHasPassword(id: id)) saved.add(id);
      } catch (_) {}
    }
    if (mounted && !setEquals(saved, _savedIps)) {
      setState(() => _savedIps = saved);
    }
  }

  Future<void> _connect(String id, {String? password}) async {
    if (id.isEmpty || _connecting) return;
    setState(() => _connecting = true);
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
    _refreshSaved(); // it may have checked "remember password"
  }

  // 100.64.0.0/10 — CGNAT range used by Tailscale.
  bool _isTailscale(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4 || parts[0] != '100') return false;
    final b = int.tryParse(parts[1]) ?? -1;
    return b >= 64 && b <= 127;
  }

  /// First label of the hostname, normalized ("Mac.lan" → "mac").
  String? _hostLabel(String hostname) {
    final label = hostname.split('.').first.trim().toLowerCase();
    return label.isEmpty ? null : label;
  }

  /// Groups the engine's entries (1 per IP) into machines (1 per computer).
  List<_Machine> _machines() {
    // The engine can save the same IP twice (entry identified by broadcast +
    // bare entry from the port scan): first dedupe by IP, preferring the
    // identified one.
    final byIp = <String, Peer>{};
    for (final p in gFFI.lanPeersModel.peers) {
      if (_tsSelf.contains(p.id)) continue; // this machine, don't list ourselves
      // CGNAT IP that no longer exists in the tailnet (left over in lan_peers
      // from a previous tailnet): ghost card, don't list it.
      if (_isTailscale(p.id) && _tsAll.isNotEmpty && !_tsAll.contains(p.id)) {
        continue;
      }
      final prev = byIp[p.id];
      if (prev == null || (prev.platform.isEmpty && p.platform.isNotEmpty)) {
        byIp[p.id] = p;
      }
    }

    // Then group by machine identity. Sources, in order: hostname from the
    // LAN broadcast, hostname saved from a previous connection to that IP
    // (recent peers — so the Mac's Tailscale IP groups with its LAN IP even
    // if the broadcast doesn't cross into Tailscale), and hostname reported
    // by `tailscale status`. No name → its own card per IP.
    final recentById = {
      for (final r in gFFI.recentPeersModel.peers)
        if (r.hostname.isNotEmpty) r.id: r
    };
    final byKey = <String, _Machine>{};
    for (final p in byIp.values) {
      final recent = recentById[p.id];
      final knownHost = p.platform.isNotEmpty
          ? p.hostname
          : (recent != null && recent.platform.isNotEmpty
              ? recent.hostname
              : null);
      final identifiedName = knownHost == null ? null : _hostLabel(knownHost);
      final tsName = _tsName[p.id];
      final key = identifiedName ?? tsName ?? 'ip:${p.id}';

      final m = byKey.putIfAbsent(
          key, () => _Machine(name: identifiedName ?? tsName ?? p.id));
      m.routes.add(_Route(p.id, _isTailscale(p.id)));
      if (_savedIps.contains(p.id)) m.saved = true;
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
      m.routes.sort((a, b) => (a.tailscale ? 1 : 0) - (b.tailscale ? 1 : 0));
    }
    // Identified ones on top, loose IPs below.
    return [
      ...machines.where((m) => m.identified),
      ...machines.where((m) => !m.identified),
    ];
  }

  /// Removes the machine from the discovered list (long press on the
  /// card; it reappears if it's still on the network on the next scan).
  Future<void> _forgetMachine(_Machine m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Forget "${m.name}"'),
        content: const Text(
            'Removed from the list. If it is still on your network it will show up again on the next scan.'),
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
      await bind.mainRemoveDiscovered(id: r.ip);
    }
    bind.mainLoadLanPeers();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final ui = _Ui(dark);

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
                        [gFFI.lanPeersModel, gFFI.recentPeersModel]),
                    builder: (context, _) {
                      final machines = _machines();
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _header(ui),
                          const SizedBox(height: 26),
                          _sectionTitle(ui, 'ON YOUR NETWORK',
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
                                Text('Local network · no servers',
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
          _Ui ui, IconData icon, String tooltip, VoidCallback onTap,
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

  Widget _header(_Ui ui) => Column(
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

  Widget _aboutLink(_Ui ui, String label, String url) => GestureDetector(
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

  Widget _sectionTitle(_Ui ui, String text, {Widget? trailing}) => Row(
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

  Widget _scanIndicator(_Ui ui) => _scanning
      ? SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(strokeWidth: 1.5, color: ui.muted))
      : InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: _discover,
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: Icon(Icons.refresh, size: 16, color: ui.muted),
          ),
        );

  Widget _machineCards(_Ui ui, List<_Machine> machines) {
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
                    : 'No computers found. Check that the server is running.',
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
              onConnect: (ip) => _connect(ip),
              onForget: () => _forgetMachine(m),
            ),
          ),
      ],
    );
  }

  /// "Manual connection" card, collapsed by default (opens on its own if no
  /// machine was found).
  Widget _manualCard(_Ui ui, {required bool forceOpen}) {
    final open = _manualOpen || forceOpen;

    InputDecoration deco(String hint, IconData icon) => InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(color: ui.muted, fontSize: 14),
          prefixIcon: Icon(icon, size: 18, color: ui.muted),
          filled: true,
          fillColor: ui.field,
          contentPadding:
              const EdgeInsets.symmetric(vertical: 15, horizontal: 8),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide.none),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide.none),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: ui.accent, width: 1.5)),
        );

    void go() =>
        _connect(_ip.text.trim(), password: _pw.text.isEmpty ? null : _pw.text);

    final body = Padding(
      padding: const EdgeInsets.fromLTRB(18, 2, 18, 18),
      child: Column(
        children: [
          TextField(
            controller: _ip,
            style: TextStyle(color: ui.fg, fontSize: 15),
            decoration:
                deco('IP  (e.g. 192.168.1.117)', Icons.computer_outlined),
            onSubmitted: (_) => go(),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _pw,
            obscureText: true,
            style: TextStyle(color: ui.fg, fontSize: 15),
            decoration: deco('Password', Icons.lock_outline),
            onSubmitted: (_) => go(),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 46,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: [ui.accent, ui.violet]),
                borderRadius: BorderRadius.circular(10),
              ),
              child: ElevatedButton(
                onPressed: _connecting ? null : go,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.transparent,
                  disabledBackgroundColor: Colors.transparent,
                  foregroundColor: Colors.white,
                  shadowColor: Colors.transparent,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                child: _connecting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Text('Connect',
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600)),
              ),
            ),
          ),
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

/// Card for a discovered machine: icon, name, and its routes (LAN /
/// Tailscale) as chips — tapping the card connects via the best route,
/// tapping a chip connects via that IP.
class _MachineCard extends StatefulWidget {
  final _Machine machine;
  final _Ui ui;
  final bool enabled;
  final void Function(String ip) onConnect;
  final VoidCallback onForget;

  const _MachineCard({
    required this.machine,
    required this.ui,
    required this.enabled,
    required this.onConnect,
    required this.onForget,
  });

  @override
  State<_MachineCard> createState() => _MachineCardState();
}

class _MachineCardState extends State<_MachineCard> {
  bool _hover = false;

  IconData get _icon {
    switch (widget.machine.platform) {
      case kPeerPlatformMacOS:
        return Icons.laptop_mac;
      case kPeerPlatformWindows:
        return Icons.desktop_windows_outlined;
      case kPeerPlatformLinux:
        return Icons.computer_outlined;
      case kPeerPlatformAndroid:
        return Icons.smartphone_outlined;
      default:
        return Icons.dns_outlined; // IP only (no platform info)
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.machine;
    final ui = widget.ui;
    final subtitle = [
      if (m.username.isNotEmpty) m.username,
      if (m.platform.isNotEmpty) m.platform,
    ].join(' · ');

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: widget.enabled ? SystemMouseCursors.click : MouseCursor.defer,
      child: GestureDetector(
        onTap: widget.enabled ? () => widget.onConnect(m.preferred.ip) : null,
        onLongPress: widget.onForget,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: ui.card,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
                color: _hover ? ui.accent.withOpacity(0.55) : ui.border),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
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
                child: Icon(_icon,
                    size: 21, color: m.identified ? ui.accentSoft : ui.muted),
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
                                  color: ui.fg,
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
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (m.saved) _savedBadge(ui),
              const SizedBox(width: 6),
              Icon(Icons.arrow_forward_rounded,
                  size: 18,
                  color: _hover || !isDesktop
                      ? ui.accentSoft
                      : ui.accentSoft.withOpacity(0.55)),
            ],
          ),
        ),
      ),
    );
  }

  /// Indicator for saved access (password remembered, one tap connects):
  /// a small, dim key next to the arrow, with no background or text.
  Widget _savedBadge(_Ui ui) => Tooltip(
        message: 'Password saved: one tap connects',
        child: Padding(
          padding: const EdgeInsets.only(right: 4),
          child: Icon(Icons.key_rounded,
              size: 14, color: ui.muted.withOpacity(0.7)),
        ),
      );

  Widget _routeChip(_Ui ui, _Route r, {required bool enabled}) {
    return InkWell(
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
            Icon(r.tailscale ? Icons.vpn_lock_outlined : Icons.lan_outlined,
                size: 12, color: ui.muted),
            const SizedBox(width: 5),
            Text('${r.tailscale ? 'Tailscale' : 'LAN'} · ${r.ip}',
                style: TextStyle(
                    color: ui.fgSoft,
                    fontSize: 11.5,
                    fontFeatures: const [FontFeature.tabularFigures()])),
          ],
        ),
      ),
    );
  }
}

/// Dark-first palette (with a light variant).
class _Ui {
  final bool dark;
  _Ui(this.dark);

  Color get accent => const Color(0xFF3B82F6);
  Color get violet => const Color(0xFF8B5CF6);
  Color get accentSoft =>
      dark ? const Color(0xFF93B8FA) : const Color(0xFF2563EB);
  // Dark = OLED: PURE black background (pixel off) and barely elevated
  // surfaces, to take advantage of OLED screens (tablet/phone).
  Color get bg => dark ? Colors.black : const Color(0xFFF4F5F8);
  Color get card => dark ? const Color(0xFF101114) : Colors.white;
  Color get field => dark ? const Color(0xFF1B1D22) : const Color(0xFFF0F1F3);
  Color get chip => dark ? const Color(0xFF17191D) : const Color(0xFFF0F1F3);
  Color get fg => dark ? const Color(0xFFEDEDEF) : const Color(0xFF15171A);
  Color get fgSoft => dark ? const Color(0xFFC6C9CE) : const Color(0xFF474D57);
  Color get muted => dark ? const Color(0xFF8A8F98) : const Color(0xFF6B7280);
  Color get border =>
      dark ? Colors.white.withOpacity(0.06) : Colors.black.withOpacity(0.06);

  BoxDecoration get cardDeco => BoxDecoration(
        color: card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: border),
      );
}
