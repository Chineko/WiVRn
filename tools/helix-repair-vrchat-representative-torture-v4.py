#!/usr/bin/env python3
from pathlib import Path
import argparse

ROOT = Path('.')
GEN = ROOT / 'tools/helix-vrchat-workload-model.py'

OLD = '''            rem = nbytes
            for sh in range(nshards):
                cap_shard = edge_payload if sh == 0 or sh == nshards - 1 else cal["shard_payload"]
                pb = min(cap_shard, rem)
                rem -= pb
                packets.append((int(t0 + sh * spacing), s, f, sh, nshards, pb))
            assert rem == 0
'''

NEW = '''            rem = nbytes
            for sh in range(nshards):
                cap_shard = edge_payload if sh == 0 or sh == nshards - 1 else cal["shard_payload"]
                remaining_shards = nshards - sh - 1
                pb = min(cap_shard, rem - remaining_shards)
                if pb < 1:
                    raise RuntimeError("packetizer produced an empty shard")
                rem -= pb
                packets.append((int(t0 + sh * spacing), s, f, sh, nshards, pb))
            assert rem == 0
'''


def fail(msg):
    raise SystemExit(f'FAIL: {msg}')


def model_packetize(nbytes, payload=1385, max_shards=44, edge=1200):
    nshards = -(-nbytes // payload)
    nshards = min(nshards, max_shards)

    def capacity(n):
        if n == 1:
            return edge
        return (n - 2) * payload + 2 * edge

    while nshards < max_shards and nbytes > capacity(nshards):
        nshards += 1
    nbytes = min(nbytes, capacity(nshards))
    rem = nbytes
    chunks = []
    for sh in range(nshards):
        cap_shard = edge if sh == 0 or sh == nshards - 1 else payload
        remaining_shards = nshards - sh - 1
        pb = min(cap_shard, rem - remaining_shards)
        if pb < 1:
            fail(f'model empty shard nbytes={nbytes} nshards={nshards} shard={sh}')
        rem -= pb
        chunks.append(pb)
    if rem != 0:
        fail(f'model remainder nbytes={nbytes} rem={rem}')
    if sum(chunks) != nbytes:
        fail(f'model byte mismatch nbytes={nbytes} sum={sum(chunks)}')
    if chunks[0] > edge or chunks[-1] > edge or any(x > payload for x in chunks):
        fail(f'model cap violation nbytes={nbytes}')
    return chunks


def exhaustive_model_check():
    # Covers every integer frame size the frozen generator can emit.
    for nbytes in range(4000, 60134 + 1):
        model_packetize(nbytes)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--check-only', action='store_true')
    args = ap.parse_args()

    if not GEN.is_file():
        fail(f'missing {GEN}')
    src = GEN.read_text()
    old_count = src.count(OLD)
    new_count = src.count(NEW)
    if old_count != 1 or new_count != 0:
        fail(f'packetizer anchor old_count={old_count} new_count={new_count}')

    out = src.replace(OLD, NEW, 1)
    if out.count(OLD) != 0 or out.count(NEW) != 1:
        fail('post-transform packetizer count mismatch')

    exhaustive_model_check()

    if args.check_only:
        print('PASS: representative trace repair v4 check-only')
        print('writes=0')
        print('packetizer_exhaustive=PASS frame_bytes_4000_to_60134 no-empty-shards edge<=1200 payload<=1385')
        print('contract=reserve-one-byte-per-remaining-declared-shard')
        return

    GEN.write_text(out)
    print('PASS: representative trace repair v4 applied')
    print('packetizer_exhaustive=PASS frame_bytes_4000_to_60134 no-empty-shards edge<=1200 payload<=1385')
    print('contract=reserve-one-byte-per-remaining-declared-shard')
    print('STATUS: source transformed only; artifact/runtime not executed')


if __name__ == '__main__':
    main()
