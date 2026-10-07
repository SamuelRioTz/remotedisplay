import 'package:flutter_test/flutter_test.dart';
import 'package:remotedisplay_client/first_frame.dart';

List<int> hex(String s) => [
      for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)
    ];

void main() {
  // The first frame of Remote Display Server 1.0.14 on a direct connection,
  // captured on 2026-10-07 (45 bytes: 1-byte header, Message.hash{salt, challenge}).
  const captured =
      'b04a2a0a20337279713775646d697a7279713962336d736e787769326e7433656b70773237120633747a7a7071';

  test('reads the salt out of the captured first frame', () {
    expect(firstFrameSalt(hex(captured)), '3ryq7udmizryq9b3msnxwi2nt3ekpw27');
  });

  test('tolerates trailing bytes after the frame', () {
    expect(firstFrameSalt([...hex(captured), 1, 2, 3]), '3ryq7udmizryq9b3msnxwi2nt3ekpw27');
  });

  test('a truncated frame gives null', () {
    final b = hex(captured);
    expect(firstFrameSalt(b.sublist(0, 30)), isNull);
    expect(firstFrameSalt(b.sublist(0, 1)), isNull);
    expect(firstFrameSalt(const []), isNull);
  });

  test('a frame without a Hash member gives null', () {
    // Header for 4 bytes of payload, then field 3 (signed_id) with 2 bytes.
    expect(firstFrameSalt([4 << 2, 0x1a, 0x02, 0x41, 0x42]), isNull);
  });

  test('a salt with odd characters gives null', () {
    // payload: hash(9){ salt(1) = "ab c" }
    final payload = [0x4a, 0x06, 0x0a, 0x04, 0x61, 0x62, 0x20, 0x63];
    expect(firstFrameSalt([payload.length << 2, ...payload]), isNull);
  });

  test('a two-byte header is decoded', () {
    // payload: hash(9){ salt(1) = "s" } = 5 bytes; header says 5 with a 2-byte header.
    final payload = [0x4a, 0x03, 0x0a, 0x01, 0x73];
    final n = (payload.length << 2) | 1; // low bits 01 → header length 2
    expect(firstFrameSalt([n & 0xff, n >> 8, ...payload]), 's');
  });
}
