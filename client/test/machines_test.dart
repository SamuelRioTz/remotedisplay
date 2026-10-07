import 'package:flutter_hbb/models/peer_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remotedisplay_client/machines.dart';

/// A discovered entry as the engine's port scan stores it: address only.
Peer bare(String ip, {bool online = true}) => Peer.fromJson({
      'id': ip,
      'hostname': ip,
      'online': online ? 'true' : 'false',
    });

/// A discovered entry identified by a discovery reply, or a recent peer.
Peer identified(String ip,
        {required String hostname,
        String platform = 'Mac OS',
        String username = 'sam',
        String machineId = '',
        bool? online}) =>
    Peer.fromJson({
      'id': ip,
      'hostname': hostname,
      'platform': platform,
      'username': username,
      'machine_id': machineId,
      if (online != null) 'online': online ? 'true' : 'false',
    });

const lan = '192.168.1.115';
const ts = '100.64.0.2';
const studio = '526326377';
const salt = '3ryq7udmizryq9b3msnxwi2nt3ekpw27';

void main() {
  group('the reported case: one Mac, two addresses, no discovery reply', () {
    // What the Windows client held on 2026-10-07: the port scan found both
    // addresses; the LAN recent peer was refreshed by a 1.0.13+ server (new
    // name, engine id); the Tailscale recent peer dates from the 1.0.12 server
    // (router name "mac", no engine id).
    final discovered = [bare(ts), bare(lan)];
    final recent = [
      identified(lan, hostname: 'samuels-mac-studio', machineId: studio),
      identified(ts, hostname: 'mac'),
    ];
    final reach = <String, bool?>{lan: true, ts: true};

    test('without fingerprints it is still two cards (the old behaviour)', () {
      final ms = groupMachines(GroupingInput(
          discovered: discovered, recent: recent, reach: reach));
      expect(ms.map((m) => m.key).toSet(), {'samuels-mac-studio', 'mac'});
    });

    test('the same salt on both addresses makes one card, under the current name',
        () {
      final ms = groupMachines(GroupingInput(
          discovered: discovered,
          recent: recent,
          reach: reach,
          fingerprints: {lan: salt, ts: salt}));
      expect(ms, hasLength(1));
      final m = ms.single;
      expect(m.key, 'samuels-mac-studio');
      expect(m.name, 'samuels-mac-studio');
      expect(m.routes.map((r) => r.ip), [lan, ts]); // LAN first
      expect(m.routes.every((r) => r.identity == studio), isTrue);
      expect(m.username, 'sam');
      expect(m.platform, 'Mac OS');
    });

    test('a route tied in by the salt alone does not borrow the saved password',
        () {
      // The salt is public: the Tailscale route asks for the password once.
      final m = groupMachines(GroupingInput(
          discovered: discovered,
          recent: recent,
          reach: reach,
          saved: {lan},
          fingerprints: {lan: salt, ts: salt})).single;
      expect(m.route(ts)!.ownId, isFalse);
      expect(m.donorFor(m.route(ts)!), isNull);
      expect(m.donorFor(m.route(lan)!), isNull); // itself does not count
    });

    test('once the engine saved its identity, the route borrows the password',
        () {
      // After one login through either route (the host names its Tailscale
      // address in the login response), the Tailscale peer file carries the id.
      final m = groupMachines(GroupingInput(
          discovered: discovered,
          recent: [
            identified(lan, hostname: 'samuels-mac-studio', machineId: studio),
            identified(ts, hostname: 'samuels-mac-studio', machineId: studio),
          ],
          reach: reach,
          saved: {lan},
          fingerprints: {lan: salt, ts: salt})).single;
      expect(m.route(ts)!.ownId, isTrue);
      expect(m.donorFor(m.route(ts)!)?.ip, lan);
    });

    test('a salt seen on one address only still groups by the shared name', () {
      // The LAN probe has not finished yet: only the Tailscale address has a
      // salt. Its saved name matches the name announced with the id, so the
      // old name rule applies and the route carries the engine id.
      final ms = groupMachines(GroupingInput(
        discovered: discovered,
        recent: [
          identified(lan, hostname: 'samuels-mac-studio', machineId: studio),
          identified(ts, hostname: 'samuels-mac-studio'),
        ],
        reach: reach,
        fingerprints: {ts: salt},
      ));
      expect(ms, hasLength(1));
      expect(ms.single.routes.map((r) => r.identity).toSet(), {studio});
      // With the stale name the two stay apart until the LAN probe answers.
      final apart = groupMachines(GroupingInput(
          discovered: discovered,
          recent: recent,
          reach: reach,
          fingerprints: {ts: salt}));
      expect(apart.map((m) => m.key).toSet(), {'samuels-mac-studio', 'mac'});
    });

    test('a different salt keeps the identities apart under a shared name',
        () {
      // The card key is the hostname label, so two installations with one
      // name share a card (as before); the salt evidence keeps their
      // identities apart, so no password crosses between them.
      final ms = groupMachines(GroupingInput(
        discovered: discovered,
        recent: [
          identified(lan, hostname: 'samuels-mac-studio', machineId: studio),
          identified(ts, hostname: 'samuels-mac-studio'),
        ],
        reach: reach,
        saved: {lan},
        fingerprints: {lan: salt, ts: 'another-installation'},
      ));
      expect(ms, hasLength(1));
      final m = ms.single;
      expect(m.route(lan)!.identity, studio);
      expect(m.route(ts)!.identity, 'fp:another-installation');
      expect(m.donorFor(m.route(ts)!), isNull);
    });

    test('the preferred route stored under the new key is applied', () {
      final m = groupMachines(GroupingInput(
          discovered: discovered,
          recent: recent,
          reach: reach,
          fingerprints: {lan: salt, ts: salt},
          preferred: {'samuels-mac-studio': ts})).single;
      expect(m.preferredIp, ts);
    });
  });

  test('the mirror case: the id arrived over Tailscale, the LAN entry is stale',
      () {
    final ms = groupMachines(GroupingInput(
      discovered: [bare(ts), bare(lan)],
      recent: [
        identified(ts, hostname: 'samuels-mac-studio', machineId: studio),
        identified(lan, hostname: 'mac'),
      ],
      reach: {lan: true, ts: true},
      fingerprints: {lan: salt, ts: salt},
    ));
    expect(ms, hasLength(1));
    expect(ms.single.key, 'samuels-mac-studio');
    expect(ms.single.routes.map((r) => r.ip), [lan, ts]);
  });

  test('one salt claimed by two engine ids links nothing', () {
    final ms = groupMachines(GroupingInput(
      discovered: [bare('10.0.0.1'), bare('10.0.0.2'), bare('10.0.0.3')],
      recent: [
        identified('10.0.0.1', hostname: 'alpha', machineId: '111'),
        identified('10.0.0.2', hostname: 'beta', machineId: '222'),
        identified('10.0.0.3', hostname: 'old-name'),
      ],
      reach: {'10.0.0.1': true, '10.0.0.2': true, '10.0.0.3': true},
      fingerprints: {'10.0.0.1': 'S', '10.0.0.2': 'S', '10.0.0.3': 'S'},
    ));
    expect(ms.map((m) => m.key).toSet(), {'alpha', 'beta', 'old-name'});
    expect(ms.firstWhere((m) => m.key == 'old-name').routes.single.identity, '');
  });

  test('an empty salt links nothing', () {
    final ms = groupMachines(GroupingInput(
      discovered: [bare(ts), bare(lan)],
      recent: [
        identified(lan, hostname: 'samuels-mac-studio', machineId: studio),
        identified(ts, hostname: 'mac'),
      ],
      reach: {lan: true, ts: true},
      fingerprints: {lan: '', ts: ''},
    ));
    expect(ms, hasLength(2));
  });

  test('two bare addresses with one salt and no id are one computer', () {
    // A 1.0.12 server never connected to, discovery replies blocked.
    final ms = groupMachines(GroupingInput(
      discovered: [bare(ts), bare(lan)],
      recent: const [],
      reach: {lan: true, ts: true},
      fingerprints: {lan: salt, ts: salt},
    ));
    expect(ms, hasLength(1));
    expect(ms.single.key, 'fp:$salt');
    expect(ms.single.routes, hasLength(2));
    expect(ms.single.identified, isFalse);
    // A name saved under one of the addresses names and keys the card (the
    // key stays a hostname label whenever there is one).
    final named = groupMachines(GroupingInput(
      discovered: [bare(ts), bare(lan)],
      recent: [identified(ts, hostname: 'mac')],
      reach: {lan: true, ts: true},
      fingerprints: {lan: salt, ts: salt},
    )).single;
    expect(named.key, 'mac');
    expect(named.name, 'mac');
    expect(named.routes.map((r) => r.ip), [lan, ts]);
    expect(named.routes.every((r) => r.identity == 'fp:$salt'), isTrue);
  });

  test('the stale name of a fingerprinted address pulls nobody else in', () {
    // Another computer that happens to be called "mac" (no id, no salt) must
    // not join the Studio because the Studio's Tailscale entry was once saved
    // under "mac".
    final ms = groupMachines(GroupingInput(
      discovered: [bare(ts), bare(lan), bare('192.168.1.50')],
      recent: [
        identified(lan, hostname: 'samuels-mac-studio', machineId: studio),
        identified(ts, hostname: 'mac'),
        identified('192.168.1.50', hostname: 'mac', username: 'luz'),
      ],
      reach: {lan: true, ts: true, '192.168.1.50': true},
      fingerprints: {lan: salt, ts: salt},
    ));
    expect(ms.map((m) => m.key).toSet(), {'samuels-mac-studio', 'mac'});
    expect(ms.firstWhere((m) => m.key == 'mac').routes.single.ip, '192.168.1.50');
  });

  test('a name still joins the machine that announced it with its id', () {
    // Pre-existing rule: an address with a name only (a recent peer saved by a
    // 1.0.12 server, no salt yet) joins the machine whose id came with that
    // very name.
    final ms = groupMachines(GroupingInput(
      discovered: [
        identified(lan,
            hostname: 'samuels-mac-studio', machineId: studio, online: true),
        bare(ts),
      ],
      recent: [identified(ts, hostname: 'samuels-mac-studio')],
      reach: {lan: true, ts: true},
    ));
    expect(ms, hasLength(1));
    expect(ms.single.routes.map((r) => r.identity).toSet(), {studio});
  });

  test('a fingerprint keeps a machine together while it is off', () {
    final ms = groupMachines(GroupingInput(
      discovered: const [],
      recent: [
        identified(lan, hostname: 'samuels-mac-studio', machineId: studio),
        identified(ts, hostname: 'mac'),
      ],
      reach: {lan: false, ts: false},
      fingerprints: {lan: salt, ts: salt},
    ));
    expect(ms, hasLength(1));
    expect(ms.single.available, isFalse);
    expect(ms.single.routes, hasLength(2));
  });

  test('our own Tailscale address and other tailnets are left out', () {
    final ms = groupMachines(GroupingInput(
      discovered: [bare('100.64.0.4'), bare('100.99.0.9'), bare(lan)],
      recent: const [],
      tsSelf: {'100.64.0.4'},
      tsAll: {'100.64.0.4', '100.64.0.2'},
      reach: {lan: true},
    ));
    expect(ms.map((m) => m.routes.single.ip), [lan]);
  });

  test('a rogue port echoing the salt joins the card but is lent nothing', () {
    final m = groupMachines(GroupingInput(
      discovered: [bare(lan), bare('192.168.1.66')],
      recent: [identified(lan, hostname: 'samuels-mac-studio', machineId: studio)],
      reach: {lan: true, '192.168.1.66': true},
      saved: {lan},
      fingerprints: {lan: salt, '192.168.1.66': salt},
    )).single;
    final rogue = m.route('192.168.1.66')!;
    expect(rogue.identity, studio);
    expect(rogue.ownId, isFalse);
    expect(m.donorFor(rogue), isNull);
  });

  group('movedKeys: what the user stored follows the addresses', () {
    List<Machine> oneCard() => groupMachines(GroupingInput(
          discovered: [bare(ts), bare(lan)],
          recent: [
            identified(lan, hostname: 'samuels-mac-studio', machineId: studio),
            identified(ts, hostname: 'mac'),
          ],
          reach: {lan: true, ts: true},
          fingerprints: {lan: salt, ts: salt},
        ));

    test('the upgrade: the remembered route names the vanished key', () {
      final moved = movedKeys(
          lastKeys: const {},
          preferred: {'mac': ts},
          machines: oneCard(),
          sameHost: (_) => true);
      expect(moved, {'mac': 'samuels-mac-studio'});
    });

    test('by the key each address had last time', () {
      final moved = movedKeys(
          lastKeys: {ts: 'mac', lan: 'samuels-mac-studio'},
          preferred: const {},
          machines: oneCard(),
          sameHost: (_) => true);
      expect(moved, {'mac': 'samuels-mac-studio'});
    });

    test('an address that now answers as another host moves nothing', () {
      final moved = movedKeys(
          lastKeys: {ts: 'mac'},
          preferred: {'mac': ts},
          machines: oneCard(),
          sameHost: (ip) => ip != ts);
      expect(moved, isEmpty);
    });

    test('a key still carried by a card is not moved', () {
      final moved = movedKeys(
          lastKeys: {ts: 'samuels-mac-studio'},
          preferred: const {},
          machines: oneCard(),
          sameHost: (_) => true);
      expect(moved, isEmpty);
    });

    test('a manual address alone does not keep the old key alive', () {
      final machines = groupMachines(GroupingInput(
        discovered: [bare(ts), bare(lan)],
        recent: [
          identified(lan, hostname: 'samuels-mac-studio', machineId: studio),
          identified(ts, hostname: 'mac'),
        ],
        manual: {'10.9.9.9': 'mac'},
        reach: {lan: true, ts: true, '10.9.9.9': false},
        fingerprints: {lan: salt, ts: salt},
      ));
      expect(machines.map((m) => m.key).toSet(), {'samuels-mac-studio', 'mac'});
      final moved = movedKeys(
          lastKeys: {ts: 'mac'},
          preferred: const {},
          machines: machines,
          sameHost: (_) => true);
      expect(moved, {'mac': 'samuels-mac-studio'});
    });
  });

  group('the discovery tally', () {
    test('parses the event value', () {
      final t = DiscoveryTally.parse(
          '{"run":3,"replies":0,"port_hits":2,"done":true}')!;
      expect((t.run, t.replies, t.portHits, t.done), (3, 0, 2, true));
      expect(t.silent, isTrue);
      expect(DiscoveryTally.parse(''), isNull);
      expect(DiscoveryTally.parse('garbage'), isNull);
      expect(DiscoveryTally.parse(null), isNull);
    });

    test('counts silent finished runs once each and resets on a reply', () {
      var s = (silentScans: 0, lastRun: -1);
      DiscoveryTally t(int run, int replies, int hits, {bool done = true}) =>
          DiscoveryTally(run: run, replies: replies, portHits: hits, done: done);
      s = foldDiscoveryTally(t(1, 0, 2, done: false),
          silentScans: s.silentScans, lastRun: s.lastRun);
      expect(s.silentScans, 0); // not finished
      s = foldDiscoveryTally(t(1, 0, 2),
          silentScans: s.silentScans, lastRun: s.lastRun);
      s = foldDiscoveryTally(t(1, 0, 2),
          silentScans: s.silentScans, lastRun: s.lastRun);
      expect(s.silentScans, 1); // the same run pushed twice
      s = foldDiscoveryTally(t(2, 0, 1),
          silentScans: s.silentScans, lastRun: s.lastRun);
      expect(s.silentScans, 2);
      s = foldDiscoveryTally(t(3, 0, 0),
          silentScans: s.silentScans, lastRun: s.lastRun);
      expect(s.silentScans, 0); // nothing on the port either: not evidence
      s = foldDiscoveryTally(t(4, 1, 3),
          silentScans: s.silentScans, lastRun: s.lastRun);
      expect(s.silentScans, 0);
    });
  });

  test('address helpers', () {
    expect(isTailscaleAddress('100.64.0.2'), isTrue);
    expect(isTailscaleAddress('100.127.255.1:21120'), isTrue);
    expect(isTailscaleAddress('100.128.0.1'), isFalse);
    expect(isTailscaleAddress('192.168.1.5'), isFalse);
    expect(splitAddress('1.2.3.4:21120', 21118), (host: '1.2.3.4', port: 21120));
    expect(splitAddress('1.2.3.4', 21118), (host: '1.2.3.4', port: 21118));
    expect(hostLabel('Samuels-Mac-Studio.local'), 'samuels-mac-studio');
    expect(hostLabel(''), isNull);
  });
}
