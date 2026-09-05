import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_hbb/consts.dart';

import 'home_ui.dart';
import 'machines.dart';

IconData platformIcon(String platform) {
  switch (platform) {
    case kPeerPlatformMacOS:
      return Icons.laptop_mac;
    case kPeerPlatformWindows:
      return Icons.desktop_windows_outlined;
    case kPeerPlatformLinux:
      return Icons.computer_outlined;
    case kPeerPlatformAndroid:
      return Icons.smartphone_outlined;
    default:
      return Icons.dns_outlined; // address only (no platform info)
  }
}

/// Header shared by the sheets: platform icon, name, user · platform.
Widget machineHeader(HomeUi ui, Machine m, {Widget? trailing}) {
  final subtitle = [
    if (m.username.isNotEmpty) m.username,
    if (m.platform.isNotEmpty) m.platform,
  ].join(' · ');
  return Row(
    children: [
      Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(11),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [ui.accent.withOpacity(0.22), ui.violet.withOpacity(0.22)],
          ),
        ),
        child: Icon(platformIcon(m.platform), size: 21, color: ui.accentSoft),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(m.name,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: ui.fg, fontSize: 16, fontWeight: FontWeight.w700)),
            if (subtitle.isNotEmpty)
              Text(subtitle,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: ui.muted, fontSize: 12.5)),
          ],
        ),
      ),
      if (trailing != null) trailing,
    ],
  );
}

/// Short status of a route for lists and chips.
String routeStatus(MachineRoute r) => r.reachable == null
    ? 'Checking…'
    : (r.reachable! ? 'Reachable' : 'Not reachable from this network');

Widget statusDot(HomeUi ui, MachineRoute r, {double size = 7}) {
  if (r.reachable == null) {
    return SizedBox(
        width: size,
        height: size,
        child: CircularProgressIndicator(strokeWidth: 1.2, color: ui.muted));
  }
  return Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: r.reachable! ? ui.ok : ui.muted.withOpacity(0.55)),
  );
}

/// "Connect to <machine>": choose the route (LAN / Tailscale), type the
/// password when none is saved for it, and whether to remember it.
class ConnectSheet extends StatefulWidget {
  final HomeUi ui;
  final Machine machine;
  final String initialIp;
  final Future<void> Function(String ip,
      {String? password, required bool remember}) onConnect;
  final VoidCallback onSettings;

  const ConnectSheet({
    super.key,
    required this.ui,
    required this.machine,
    required this.initialIp,
    required this.onConnect,
    required this.onSettings,
  });

  @override
  State<ConnectSheet> createState() => _ConnectSheetState();
}

class _ConnectSheetState extends State<ConnectSheet> {
  late String _ip = widget.initialIp;
  final _pw = TextEditingController();
  bool _remember = true;
  bool _busy = false;

  @override
  void dispose() {
    _pw.dispose();
    super.dispose();
  }

  MachineRoute get _route =>
      widget.machine.route(_ip) ?? widget.machine.routes.first;

  Future<void> _go() async {
    if (_busy) return;
    final r = _route;
    final pw = _pw.text;
    if (!r.saved && pw.isEmpty) return;
    setState(() => _busy = true);
    Navigator.of(context).pop();
    await widget.onConnect(r.ip,
        password: r.saved ? null : pw, remember: _remember);
  }

  @override
  Widget build(BuildContext context) {
    final ui = widget.ui;
    final m = widget.machine;
    final r = _route;
    final canGo = r.saved || _pw.text.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          machineHeader(ui, m,
              trailing: IconButton(
                tooltip: 'Settings',
                onPressed: () {
                  Navigator.of(context).pop();
                  widget.onSettings();
                },
                icon: Icon(Icons.tune_rounded, size: 20, color: ui.muted),
              )),
          const SizedBox(height: 18),
          Text('CONNECT THROUGH',
              style: TextStyle(
                  color: ui.muted,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.2)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final route in m.routes) _routeOption(ui, route),
            ],
          ),
          if (r.reachable == false) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(Icons.info_outline, size: 14, color: ui.muted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    m.live != null
                        ? 'This address does not answer from here; ${m.live!.kind} does.'
                        : 'No address answers from this network. Is the Mac on, and is Tailscale connected on both sides?',
                    style: TextStyle(color: ui.muted, fontSize: 12),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          if (r.saved)
            Row(
              children: [
                Icon(Icons.key_rounded, size: 15, color: ui.muted),
                const SizedBox(width: 8),
                Text('Password saved for this address',
                    style: TextStyle(color: ui.fgSoft, fontSize: 13)),
              ],
            )
          else ...[
            TextField(
              controller: _pw,
              autofocus: true,
              obscureText: true,
              style: TextStyle(color: ui.fg, fontSize: 15),
              decoration: ui.input('Password', Icons.lock_outline),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _go(),
            ),
            const SizedBox(height: 6),
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => setState(() => _remember = !_remember),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    SizedBox(
                      height: 24,
                      child: Switch.adaptive(
                        value: _remember,
                        activeColor: ui.accent,
                        onChanged: (v) => setState(() => _remember = v),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text('Remember password',
                        style: TextStyle(color: ui.fgSoft, fontSize: 13)),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 14),
          ui.primaryButton(
              label: 'Connect', onPressed: canGo ? _go : null, busy: _busy),
        ],
      ),
    );
  }

  Widget _routeOption(HomeUi ui, MachineRoute route) {
    final selected = route.ip == _ip;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => setState(() => _ip = route.ip),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? ui.accent.withOpacity(0.14) : ui.chip,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: selected ? ui.accent.withOpacity(0.7) : ui.border,
              width: selected ? 1.4 : 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            statusDot(ui, route),
            const SizedBox(width: 8),
            Icon(route.tailscale ? Icons.vpn_lock_outlined : Icons.lan_outlined,
                size: 13, color: ui.muted),
            const SizedBox(width: 5),
            Text('${route.kind} · ${route.ip}',
                style: TextStyle(
                    color: route.reachable == false ? ui.muted : ui.fgSoft,
                    fontSize: 12.5,
                    fontFeatures: const [FontFeature.tabularFigures()])),
            if (route.saved) ...[
              const SizedBox(width: 6),
              Icon(Icons.key_rounded, size: 12, color: ui.muted),
            ],
          ],
        ),
      ),
    );
  }
}

/// Per-machine settings: its addresses (status, saved password, remove),
/// add an address by hand, forget passwords, forget the machine.
class MachineSettingsSheet extends StatefulWidget {
  final HomeUi ui;

  /// Re-resolved on every rebuild (the home keeps the model fresh); null once
  /// the machine is gone.
  final Machine? Function() lookup;
  final ValueListenable<int> revision;
  final Future<void> Function(String address) onAddAddress;
  final Future<void> Function(MachineRoute r) onRemoveAddress;
  final Future<void> Function(MachineRoute r) onForgetPassword;
  final Future<void> Function() onForgetMachine;
  final void Function(String ip) onConnect;

  const MachineSettingsSheet({
    super.key,
    required this.ui,
    required this.lookup,
    required this.revision,
    required this.onAddAddress,
    required this.onRemoveAddress,
    required this.onForgetPassword,
    required this.onForgetMachine,
    required this.onConnect,
  });

  @override
  State<MachineSettingsSheet> createState() => _MachineSettingsSheetState();
}

class _MachineSettingsSheetState extends State<MachineSettingsSheet> {
  final _addr = TextEditingController();
  bool _adding = false;

  @override
  void dispose() {
    _addr.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final a = _addr.text.trim();
    if (a.isEmpty || _adding) return;
    setState(() => _adding = true);
    await widget.onAddAddress(a);
    _addr.clear();
    if (mounted) setState(() => _adding = false);
  }

  Future<void> _confirmForget(Machine m) async {
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
    await widget.onForgetMachine();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final ui = widget.ui;
    return ValueListenableBuilder<int>(
      valueListenable: widget.revision,
      builder: (context, _, __) {
        final m = widget.lookup();
        if (m == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) Navigator.of(context).maybePop();
          });
          return const SizedBox(height: 80);
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              machineHeader(ui, m),
              const SizedBox(height: 18),
              Text('ADDRESSES',
                  style: TextStyle(
                      color: ui.muted,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1.2)),
              const SizedBox(height: 6),
              for (final r in m.routes) _routeRow(ui, r),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _addr,
                      style: TextStyle(color: ui.fg, fontSize: 14),
                      decoration: ui.input(
                          'Add address (IP or Tailscale IP)',
                          Icons.add_link_rounded),
                      onSubmitted: (_) => _add(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    height: 46,
                    child: OutlinedButton(
                      onPressed: _adding ? null : _add,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: ui.accentSoft,
                        side: BorderSide(color: ui.accent.withOpacity(0.5)),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                      child: const Text('Add'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'The Mac\'s Tailscale address is on the server\'s window ("Tailscale · 100.x.y.z:21118"); add it here to reach the Mac from other networks.',
                style: TextStyle(color: ui.muted, fontSize: 11.5),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  TextButton.icon(
                    onPressed: () => _confirmForget(m),
                    style: TextButton.styleFrom(foregroundColor: ui.danger),
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('Forget this computer'),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: TextButton.styleFrom(foregroundColor: ui.fgSoft),
                    child: const Text('Done'),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _routeRow(HomeUi ui, MachineRoute r) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: ui.chip,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ui.border),
      ),
      child: Row(
        children: [
          statusDot(ui, r, size: 8),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${r.kind} · ${r.ip}',
                    style: TextStyle(
                        color: ui.fg,
                        fontSize: 13.5,
                        fontFeatures: const [FontFeature.tabularFigures()])),
                Text(
                  [
                    routeStatus(r),
                    if (r.saved) 'password saved',
                    if (r.manual) 'added by you',
                  ].join(' · '),
                  style: TextStyle(color: ui.muted, fontSize: 11.5),
                ),
              ],
            ),
          ),
          if (r.saved)
            IconButton(
              tooltip: 'Forget the saved password',
              onPressed: () => widget.onForgetPassword(r),
              icon: Icon(Icons.key_off_outlined, size: 18, color: ui.muted),
            ),
          IconButton(
            tooltip: 'Connect through this address',
            onPressed: () {
              Navigator.of(context).pop();
              widget.onConnect(r.ip);
            },
            icon: Icon(Icons.arrow_forward_rounded,
                size: 18, color: ui.accentSoft),
          ),
          IconButton(
            tooltip: 'Remove this address',
            onPressed: () => widget.onRemoveAddress(r),
            icon: Icon(Icons.close_rounded, size: 18, color: ui.muted),
          ),
        ],
      ),
    );
  }
}
