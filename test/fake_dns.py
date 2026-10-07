#!/usr/bin/env python3
"""
A tiny single-zone DNS responder for the SSHFP end-to-end test.

It answers A queries for one name with 127.0.0.1, SSHFP queries for
that name with the given records, and everything else with NXDOMAIN.
The AD (authenticated data) bit is set on answers if --ad is given,
simulating a DNSSEC-validating resolver.

Usage: fake_dns.py --name host.example --sshfp "4 2 <hex>" [--ad]
"""

import argparse
import socket
import struct


def parse_qname(msg, pos):
    labels = []
    while True:
        n = msg[pos]
        pos += 1
        if n == 0:
            return ".".join(labels).lower(), pos
        labels.append(msg[pos:pos + n].decode("ascii"))
        pos += n


def encode_name(name):
    out = b""
    for label in name.rstrip(".").split("."):
        out += bytes([len(label)]) + label.encode("ascii")
    return out + b"\0"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", required=True)
    ap.add_argument("--sshfp", action="append", default=[])
    ap.add_argument("--ad", action="store_true")
    ap.add_argument("--addr", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=53)
    args = ap.parse_args()

    name = args.name.rstrip(".").lower()
    records = []
    for r in args.sshfp:
        alg, fptype, hexfp = r.split()
        records.append(bytes([int(alg), int(fptype)]) + bytes.fromhex(hexfp))

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((args.addr, args.port))
    while True:
        msg, peer = sock.recvfrom(4096)
        try:
            qid, flags, qd = struct.unpack(">HHH", msg[:6])
            qname, pos = parse_qname(msg, 12)
            qtype, qclass = struct.unpack(">HH", msg[pos:pos + 4])
            question = msg[12:pos + 4]
        except Exception:
            continue

        answers = []
        rcode = 0
        if qname != name:
            rcode = 3
        elif qtype == 1:
            answers.append((1, socket.inet_aton("127.0.0.1")))
        elif qtype == 44:
            answers.extend((44, r) for r in records)

        rflags = 0x8000 | (flags & 0x0100) | 0x0080 | rcode
        if args.ad and rcode == 0:
            rflags |= 0x0020
        resp = struct.pack(">HHHHHH", qid, rflags, 1, len(answers), 0, 0)
        resp += question
        for rtype, rdata in answers:
            resp += b"\xc0\x0c" + struct.pack(">HHIH", rtype, 1, 60,
                                              len(rdata)) + rdata
        sock.sendto(resp, peer)


if __name__ == "__main__":
    main()
