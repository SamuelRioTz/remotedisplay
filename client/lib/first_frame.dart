/// The salt in the first frame a Remote Display host sends on its direct port.
///
/// On a direct connection the host speaks first: `Connection::on_open` in the
/// engine sends `Hash{salt, challenge}` before reading anything from the
/// client. The salt is generated once per host installation and does not
/// change with the host's address or hostname, so two addresses that answer
/// with the same salt belong to one computer. The home reads it during its
/// reachability probe and uses it as a fingerprint to group routes when no
/// engine id reached it for an address (no discovery reply arrives, or the
/// address was saved by an older server under another name). It is a hint for
/// grouping only; nothing is written to the engine's peer files from it.
///
/// Wire format (hbb_common `BytesCodec` + protobuf): a little-endian length
/// header of 1 to 4 bytes whose low two bits are the header length minus one
/// and whose remaining bits are the payload length, then a `Message` whose
/// `hash` member is field 9 and whose `Hash.salt` is field 1. Any other frame,
/// a truncated one or an odd salt gives `null`.
String? firstFrameSalt(List<int> bytes) {
  if (bytes.isEmpty) return null;
  final headLen = (bytes[0] & 0x3) + 1;
  if (bytes.length < headLen) return null;
  var n = 0;
  for (var i = 0; i < headLen; i++) {
    n |= bytes[i] << (8 * i);
  }
  final payloadLen = n >> 2;
  if (payloadLen <= 0 || bytes.length < headLen + payloadLen) return null;
  final message = _fields(bytes, headLen, headLen + payloadLen);
  final hash = message?[9];
  if (hash == null) return null;
  final salt = _fields(bytes, hash.start, hash.end)?[1];
  if (salt == null) return null;
  final len = salt.end - salt.start;
  if (len < 1 || len > 64) return null;
  for (var i = salt.start; i < salt.end; i++) {
    final c = bytes[i];
    if (c < 0x21 || c > 0x7e) return null; // printable ASCII, no spaces
  }
  return String.fromCharCodes(bytes, salt.start, salt.end);
}

class _Span {
  final int start, end;
  const _Span(this.start, this.end);
}

/// The length-delimited fields of one protobuf message (field number → span of
/// its bytes); varint and fixed-size fields are skipped. `null` when the bytes
/// are not a well-formed message.
Map<int, _Span>? _fields(List<int> b, int start, int end) {
  final out = <int, _Span>{};
  var i = start;
  int? varint() {
    var shift = 0, v = 0;
    while (i < end) {
      final c = b[i++];
      v |= (c & 0x7f) << shift;
      if (c & 0x80 == 0) return v;
      shift += 7;
      if (shift > 35) return null;
    }
    return null;
  }

  while (i < end) {
    final key = varint();
    if (key == null) return null;
    final field = key >> 3, wire = key & 7;
    switch (wire) {
      case 0:
        if (varint() == null) return null;
        break;
      case 1:
        i += 8;
        break;
      case 5:
        i += 4;
        break;
      case 2:
        final len = varint();
        if (len == null || len < 0 || i + len > end) return null;
        out[field] = _Span(i, i + len);
        i += len;
        break;
      default:
        return null;
    }
    if (i > end) return null;
  }
  return out;
}
