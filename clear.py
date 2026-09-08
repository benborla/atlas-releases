#!/usr/bin/env python3
import argparse, os, struct, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from katpak import Pak, lz4_block, DATA

FIRST, LAST = 15711, 15938
DDS_HEADER = 128
JOURNAL_MAGIC = b'KATUNDO1'


# ---------------------------------------------------------------- lz4 encoding

def _varlen(n):
    """LZ4 extended length bytes for a value already known to be >= 15."""
    out = bytearray()
    n -= 15
    while n >= 255:
        out.append(255)
        n -= 255
    out.append(n)
    return bytes(out)


def _seq(literals, match_len, offset=1):
    """One LZ4 sequence: token, [ll ext], literals, [offset], [ml ext].

    match_len == 0 emits a literals-only (final) sequence.
    """
    ll = len(literals)
    tok_l = min(ll, 15)
    if match_len:
        ml = match_len - 4          # stored value is length-4
        tok_m = min(ml, 15)
    else:
        tok_m = 0
    out = bytearray([(tok_l << 4) | tok_m])
    if ll >= 15:
        out += _varlen(ll)
    out += literals
    if match_len:
        out += struct.pack('<H', offset)
        if ml >= 15:
            out += _varlen(ml)
    return bytes(out)


def encode_padded(head, total_raw, target):
    """LZ4 block of exactly `target` bytes decoding to head + zero padding.

    Layout: one sequence carrying `head` plus K literal zeros followed by a
    back-reference (offset 1) over the remaining zeros, then a literals-only
    tail of 12 zeros.  The 12-byte tail satisfies the LZ4 rule that a block
    must end with >= 5 literals and no match within 12 bytes of the end.
    """
    TAIL = 12
    zeros_total = total_raw - len(head)
    if zeros_total < TAIL + 4:
        raise ValueError("payload too small to encode")

    def build(k):
        lits = head + b'\0' * k
        m = zeros_total - k - TAIL
        return _seq(lits, m) + _seq(b'\0' * TAIL, 0)

    lo, hi = 0, zeros_total - TAIL - 4
    if len(build(hi)) < target:
        raise ValueError(f"cannot reach {target} bytes (max {len(build(hi))})")
    if len(build(lo)) > target:
        raise ValueError(f"cannot fit in {target} bytes (min {len(build(lo))})")

    # size is monotonic in k; binary search then walk the +/-1 jitter from
    # varint width changes.
    while lo < hi:
        mid = (lo + hi) // 2
        if len(build(mid)) < target:
            lo = mid + 1
        else:
            hi = mid
    for k in range(max(0, lo - 4), lo + 5):
        blk = build(k)
        if len(blk) == target:
            return blk
    raise ValueError(f"no exact fit for {target} bytes")


# ---------------------------------------------------------------------- helpers

def targets(pak):
    out = []
    for e in pak.ents:
        if not (FIRST <= e['i'] <= LAST):
            continue
        # max_out is a soft limit in katpak's decoder - it stops at a token
        # boundary, so trim to the exact DDS header length.
        head = pak.read(e, max_out=DDS_HEADER)[:DDS_HEADER]
        if head[:4] != b'DDS ' or head[84:88] != b'DXT2':
            raise SystemExit(f"entry {e['i']} is not a DXT2 DDS - aborting")
        if e['flags'] != 1:
            raise SystemExit(f"entry {e['i']} is stored, not LZ4 - aborting")
        out.append((e, head))
    return out


def payload_off(e):
    return DATA + e['off'] + 8


# ------------------------------------------------------------------------ main

def do_patch(path, journal, dry_run):
    pak = Pak(path)
    items = targets(pak)
    print(f"{len(items)} emblem textures found "
          f"({sum(1 for e, _ in items if e['raw'] == 5616)} backgrounds, "
          f"{sum(1 for e, _ in items if e['raw'] == 1520)} symbols)")

    patches = []
    for e, head in items:
        blank = head + b'\0' * (e['raw'] - DDS_HEADER)
        blk = encode_padded(head, e['raw'], e['comp'])
        got = lz4_block(blk)
        if got != blank:
            raise SystemExit(f"entry {e['i']}: round-trip mismatch "
                             f"({len(got)} vs {len(blank)} bytes)")
        patches.append((payload_off(e), e['comp'], blk))
    print(f"verified {len(patches)} replacement blocks "
          f"(all decode to header + zeroed pixels, exact original sizes)")

    if dry_run:
        tot = sum(n for _, n, _ in patches)
        print(f"dry run: would rewrite {tot} bytes across {len(patches)} records; "
              f"nothing outside those payloads changes")
        return

    if os.path.exists(journal):
        raise SystemExit(f"{journal} already exists - move it aside or --restore first")

    with open(path, 'r+b') as fh, open(journal, 'wb') as jn:
        jn.write(JOURNAL_MAGIC + struct.pack('<I', len(patches)))
        for off, n, _ in patches:
            fh.seek(off)
            jn.write(struct.pack('<QI', off, n) + fh.read(n))
        jn.flush()
        os.fsync(jn.fileno())
        for off, n, blk in patches:
            fh.seek(off)
            fh.write(blk)
        fh.flush()
        os.fsync(fh.fileno())
    print(f"patched {len(patches)} textures; undo journal -> {journal}")

    # re-read through the parser to confirm the archive still decodes
    chk = Pak(path)
    bad = 0
    for e in chk.ents:
        if FIRST <= e['i'] <= LAST:
            d = chk.read(e)
            if len(d) != e['raw'] or any(d[DDS_HEADER:]):
                bad += 1
    print("verify: all 228 re-read as blank" if not bad else f"verify: {bad} FAILED")


def do_restore(path, journal):
    with open(journal, 'rb') as jn:
        if jn.read(8) != JOURNAL_MAGIC:
            raise SystemExit("not a katpak undo journal")
        n = struct.unpack('<I', jn.read(4))[0]
        with open(path, 'r+b') as fh:
            for _ in range(n):
                off, ln = struct.unpack('<QI', jn.read(12))
                fh.seek(off)
                fh.write(jn.read(ln))
            fh.flush()
            os.fsync(fh.fileno())
    print(f"restored {n} original payloads from {journal}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('pak', nargs='?', default='data.pak')
    ap.add_argument('--journal', default=None, help='undo file (default: <pak>.emblem-undo)')
    ap.add_argument('--dry-run', action='store_true')
    ap.add_argument('--restore', action='store_true')
    a = ap.parse_args()
    journal = a.journal or a.pak + '.emblem-undo'
    if a.restore:
        do_restore(a.pak, journal)
    else:
        do_patch(a.pak, journal, a.dry_run)


if __name__ == '__main__':
    main()
