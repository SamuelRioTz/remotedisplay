// remotedisplay: remote control of SimpleDisplay (virtual displays) on the Mac.
// The Windows client runs commands over SSH against the host (same IP as the peer),
// using the `simpledisplay://` URL scheme exposed by the SimpleDisplay app.
// Requires no changes to the RustDesk host (screen permissions are preserved).
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:url_launcher/url_launcher.dart';

class _Preset {
  final String name;
  final int width;
  final int height;
  final bool hidpi;
  const _Preset(this.name, this.width, this.height, {this.hidpi = true});
  String get label => '$name  ($width×$height)';
}

const List<_Preset> _presets = [
  _Preset('1080p', 1920, 1080, hidpi: false),
  _Preset('1440p', 2560, 1440, hidpi: false),
  _Preset('4K', 3840, 2160, hidpi: false),
  _Preset('iPad Pro', 2732, 2048, hidpi: true),
  _Preset('iPhone', 1179, 2556, hidpi: true),
];

const _kSshUserOption = 'simpledisplay-ssh-user';
const _kStatusPath = '/tmp/simpledisplay-status.json';
const _kDownloadUrl =
    'https://github.com/SamuelRioTz/SimpleDisplay/releases/latest';

// A display reported by `simpledisplay://status` (JSON in _kStatusPath).
class _RemoteDisplay {
  final int id;
  final String name;
  final bool virtual;
  final bool on;
  final bool main;
  final bool builtin;
  final int width;
  final int height;
  _RemoteDisplay.fromJson(Map<String, dynamic> j)
      : id = j['id'] as int,
        name = j['name'] as String,
        virtual = j['virtual'] as bool,
        on = j['on'] as bool,
        main = j['main'] as bool,
        builtin = j['builtin'] as bool,
        width = j['width'] as int,
        height = j['height'] as int;
}

Future<ProcessResult?> _ssh(String user, String host, String remoteCmd) async {
  try {
    return await Process.run('ssh', [
      '-o', 'StrictHostKeyChecking=accept-new',
      '-o', 'BatchMode=yes',
      '-o', 'ConnectTimeout=8',
      '$user@$host',
      remoteCmd,
    ]);
  } catch (e) {
    return null;
  }
}

String _url(String action, Map<String, String> params) {
  final q = params.entries
      .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
      .join('&');
  return q.isEmpty ? 'simpledisplay://$action' : 'simpledisplay://$action?$q';
}

void showSimpleDisplayDialog(BuildContext context, String host) {
  showDialog(
    context: context,
    builder: (ctx) => _SimpleDisplayDialog(host: host),
  );
}

class _SimpleDisplayDialog extends StatefulWidget {
  final String host;
  const _SimpleDisplayDialog({required this.host});
  @override
  State<_SimpleDisplayDialog> createState() => _SimpleDisplayDialogState();
}

class _SimpleDisplayDialogState extends State<_SimpleDisplayDialog> {
  late TextEditingController _userCtrl;
  String _status = 'Detecting…';
  bool _installed = false;
  bool _running = false;
  bool _busy = false;
  String _log = '';
  List<_RemoteDisplay> _displays = [];

  @override
  void initState() {
    super.initState();
    final saved = bind.mainGetLocalOption(key: _kSshUserOption);
    _userCtrl = TextEditingController(text: saved.isEmpty ? 'sam' : saved);
    _detect();
  }

  @override
  void dispose() {
    _userCtrl.dispose();
    super.dispose();
  }

  String get _user =>
      _userCtrl.text.trim().isEmpty ? 'sam' : _userCtrl.text.trim();

  Future<void> _detect() async {
    setState(() {
      _status = 'Detecting…';
      _installed = false;
      _running = false;
    });
    final r = await _ssh(
        _user,
        widget.host,
        'test -d /Applications/SimpleDisplay.app && echo INSTALLED || echo MISSING; '
        'pgrep -x SimpleDisplay >/dev/null && echo RUNNING || echo STOPPED');
    if (!mounted) return;
    if (r == null) {
      setState(() => _status = 'Could not run SSH');
      return;
    }
    final out = r.stdout as String;
    if (out.contains('INSTALLED')) {
      final running = out.contains('RUNNING');
      setState(() {
        _installed = true;
        _running = running;
        _status = running
            ? 'SimpleDisplay running ✓'
            : 'SimpleDisplay installed (closed)';
      });
      if (running) await _refreshDisplays();
    } else if (out.contains('MISSING')) {
      setState(
          () => _status = 'SimpleDisplay is not installed on ${widget.host}');
    } else {
      final err = (r.stderr as String).trim();
      setState(() => _status = err.isNotEmpty ? 'SSH: $err' : 'No response');
    }
  }

  Future<void> _openApp() async {
    setState(() => _busy = true);
    await _ssh(_user, widget.host, 'open -a SimpleDisplay && sleep 3');
    if (!mounted) return;
    setState(() => _busy = false);
    await _detect();
  }

  // Requests a snapshot (simpledisplay://status writes JSON to _kStatusPath),
  // waits for the file to appear, and reads it.
  Future<void> _refreshDisplays() async {
    setState(() => _busy = true);
    final r = await _ssh(
        _user,
        widget.host,
        'rm -f $_kStatusPath; '
        'open "${_url('status', {})}"; '
        'for i in 1 2 3 4 5 6 7 8; do sleep 1; test -f $_kStatusPath && break; done; '
        'cat $_kStatusPath 2>/dev/null');
    if (!mounted) return;
    var parsed = <_RemoteDisplay>[];
    var err = '';
    if (r == null) {
      err = 'Could not run SSH';
    } else {
      try {
        final list = jsonDecode((r.stdout as String).trim()) as List<dynamic>;
        parsed = list
            .map((e) => _RemoteDisplay.fromJson(e as Map<String, dynamic>))
            .toList()
          ..sort((a, b) {
            if (a.virtual != b.virtual) return a.virtual ? 1 : -1;
            return a.name.compareTo(b.name);
          });
      } catch (e) {
        err = 'Could not read status (SimpleDisplay outdated?)';
      }
    }
    setState(() {
      _busy = false;
      _displays = parsed;
      if (err.isNotEmpty) _log = err;
    });
  }

  // Runs a command and refreshes the list after giving macOS time to
  // reconfigure the displays (create/turn on/turn off takes a few seconds).
  Future<void> _runAndRefresh(String remoteCmd, String okMsg,
      {int settleSecs = 4}) async {
    bind.mainSetLocalOption(key: _kSshUserOption, value: _user);
    setState(() {
      _busy = true;
      _log = '';
    });
    final r = await _ssh(_user, widget.host, '$remoteCmd && sleep $settleSecs');
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (r == null) {
        _log = 'Error: could not run SSH';
      } else if (r.exitCode == 0) {
        _log = okMsg;
      } else {
        _log = 'Error: ${(r.stderr as String).trim()}';
      }
    });
    await _refreshDisplays();
  }

  void _toggle(_RemoteDisplay d) {
    final action = d.on ? 'disable' : 'enable';
    _runAndRefresh('open "${_url(action, {'id': '${d.id}'})}"',
        d.on ? '"${d.name}" turned off' : '"${d.name}" turned on');
  }

  void _removeById(_RemoteDisplay d) {
    _runAndRefresh('open "${_url('remove', {'id': '${d.id}'})}"',
        'Display "${d.name}" removed');
  }

  Widget _displayRow(_RemoteDisplay d) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(
            d.virtual
                ? Icons.desktop_windows_outlined
                : (d.builtin ? Icons.laptop_mac : Icons.monitor),
            size: 18,
            color: d.on ? null : Colors.grey,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${d.name}${d.main ? ' ★' : ''}\n${d.width}×${d.height}'
              '${d.virtual ? ' · virtual' : ''}'
              // macOS cannot turn off displays via software: "off" = mirrored
              // onto the main one (it still exists and RustDesk still lists it).
              '${d.on ? '' : ' · off (mirrored)'}',
              style: TextStyle(
                fontSize: 12,
                color: d.on ? null : Colors.grey,
              ),
            ),
          ),
          Switch(
            value: d.on,
            onChanged: (!_installed || _busy) ? null : (_) => _toggle(d),
          ),
          if (d.virtual)
            IconButton(
              tooltip: 'Remove display',
              icon: const Icon(Icons.delete_outline, size: 18),
              onPressed: (!_installed || _busy) ? null : () => _removeById(d),
            )
          else
            const SizedBox(width: 40),
        ],
      ),
    );
  }

  Widget _presetRow(_Preset p) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(p.label)),
          TextButton(
            onPressed: (!_installed || _busy)
                ? null
                : () => _runAndRefresh(
                    'open "${_url('create', {
                      'width': '${p.width}',
                      'height': '${p.height}',
                      'name': p.name,
                      if (p.hidpi) 'hidpi': 'true',
                    })}"',
                    'Display "${p.name}" created',
                    settleSecs: 7),
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('SimpleDisplay · ${widget.host}'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: Text(_status)),
                  if (_busy)
                    const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text('SSH user: '),
                  Expanded(
                    child: TextField(
                      controller: _userCtrl,
                      decoration: const InputDecoration(isDense: true),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Re-detect',
                    icon: const Icon(Icons.refresh),
                    onPressed: _busy ? null : _detect,
                  ),
                ],
              ),
              const Divider(),
              // State 1: not installed → download link
              if (!_installed)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(Icons.download),
                    label: const Text('Download SimpleDisplay (GitHub)'),
                    onPressed: _busy
                        ? null
                        : () => launchUrl(Uri.parse(_kDownloadUrl)),
                  ),
                ),
              // State 2: installed but closed → open it
              if (_installed && !_running)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Open SimpleDisplay on the Mac'),
                    onPressed: _busy ? null : _openApp,
                  ),
                ),
              // State 3: running → full config
              if (_installed && _running) ...[
                Row(
                  children: [
                    const Text('Displays:',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Refresh list',
                      icon: const Icon(Icons.sync, size: 18),
                      onPressed: _busy ? null : _refreshDisplays,
                    ),
                  ],
                ),
                if (_displays.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 4),
                    child: Text('(no data — refresh the list)',
                        style: TextStyle(fontSize: 12, color: Colors.grey)),
                  )
                else
                  ..._displays.map(_displayRow),
                const Divider(),
                const Text('Create virtual display:',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                ..._presets.map(_presetRow),
              ],
              if (_log.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(_log,
                      style:
                          const TextStyle(fontSize: 12, color: Colors.grey)),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(translate('Close')),
        ),
      ],
    );
  }
}
