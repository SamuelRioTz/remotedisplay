#!/usr/bin/env python3
"""Sends one Remote Display discovery ping (RendezvousMessage.peer_discovery, cmd=ping) to a
host and prints the reply's fields, including `misc` (the advertised extra addresses).
usage: discover-probe.py <host> [port=21119]"""
import socket, sys

def varint(n):
    out = b""
    while True:
        b = n & 0x7F; n >>= 7
        if n: out += bytes([b | 0x80])
        else: return out + bytes([b])

def field(num, data: bytes):
    return varint((num << 3) | 2) + varint(len(data)) + data

def read_varint(buf, i):
    n = 0; shift = 0
    while True:
        b = buf[i]; i += 1; n |= (b & 0x7F) << shift; shift += 7
        if not b & 0x80: return n, i

def parse(buf):
    out = {}; i = 0
    while i < len(buf):
        tag, i = read_varint(buf, i); num, wt = tag >> 3, tag & 7
        if wt == 2:
            ln, i = read_varint(buf, i); out[num] = buf[i:i+ln]; i += ln
        elif wt == 0:
            v, i = read_varint(buf, i); out[num] = v
        else:
            raise ValueError(f"wire type {wt}")
    return out

host = sys.argv[1]; port = int(sys.argv[2]) if len(sys.argv) > 2 else 21119
ping = field(22, field(1, b"ping") + field(3, b"probe"))
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(3)
s.sendto(ping, (host, port))
data, addr = s.recvfrom(4096)
pd = parse(parse(data)[22])
names = {1: "cmd", 2: "mac", 3: "id", 4: "username", 5: "hostname", 6: "platform", 7: "misc"}
print(f"reply from {addr[0]}:")
for k in sorted(pd):
    print(f"  {names.get(k, k)} = {pd[k].decode(errors='replace')}")
