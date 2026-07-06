#!/usr/bin/env python3
"""Convert a ChessBench state_value .bag file to the fen,score_cp CSV format
expected by src/tune_data.jl, without downloading the whole (multi-GB) file.

ChessBench (Ruoss et al., 2024 / Google DeepMind) stores records in Google's
"bagz" format: a sequence of length-delimited records followed by an index of
cumulative byte offsets (8-byte little-endian ints), with the offset of the
index itself in the last 8 bytes of the file. Because records for the state-
value dataset are stored in the same order as the index, the first N records
live in a contiguous prefix of the file — so fetching N positions only
requires two HTTP range requests (the index slice, then the record bytes it
points to), not the full download.

Each record is a serialised (fen: str, win_prob: float) tuple using Apache
Beam's StrUtf8Coder + FloatCoder: a varint length prefix, the UTF-8 FEN
bytes, then an 8-byte big-endian double for win_prob (side-to-move's win
probability). This script decodes that wire format directly so it has no
dependency on apache_beam.

Usage:
    python3 tools/bag_to_csv.py --n 10000000 --out chessbench.csv

Source data (~38.6 GB total; only a fraction is actually downloaded):
    https://storage.googleapis.com/searchless_chess/data/train/state_value_data.bag
"""

import argparse
import csv
import math
import random
import struct
import sys
import urllib.request

DEFAULT_URL = (
    "https://storage.googleapis.com/searchless_chess/data/train/state_value_data.bag"
)


def _http_range(url: str, start: int, end_inclusive: int) -> bytes:
    req = urllib.request.Request(
        url, headers={"Range": f"bytes={start}-{end_inclusive}"}
    )
    with urllib.request.urlopen(req) as resp:
        return resp.read()


def _content_length(url: str) -> int:
    req = urllib.request.Request(url, method="HEAD")
    with urllib.request.urlopen(req) as resp:
        return int(resp.headers["Content-Length"])


def _read_varint(buf: bytes, pos: int) -> tuple[int, int]:
    result = 0
    shift = 0
    while True:
        b = buf[pos]
        pos += 1
        result |= (b & 0x7F) << shift
        if not (b & 0x80):
            break
        shift += 7
    return result, pos


def _decode_record(rec: bytes) -> tuple[str, float]:
    length, pos = _read_varint(rec, 0)
    fen = rec[pos : pos + length].decode("utf-8")
    pos += length
    (win_prob,) = struct.unpack(">d", rec[pos : pos + 8])
    return fen, win_prob


def _win_prob_to_cp(p: float, active_is_white: bool) -> int:
    p = max(1e-7, min(1 - 1e-7, p))
    cp = 400.0 * math.log(p / (1.0 - p))
    return round(cp if active_is_white else -cp)


def fetch_records(url: str, n: int) -> list[tuple[str, float]]:
    file_size = _content_length(url)
    tail = _http_range(url, file_size - 8, file_size - 1)
    (index_start,) = struct.unpack("<Q", tail)
    num_records = (file_size - index_start) // 8
    n = min(n, num_records)
    print(f"file has {num_records:,} records; fetching first {n:,}", file=sys.stderr)

    index_bytes = _http_range(url, index_start, index_start + n * 8 - 1)
    ends = struct.unpack(f"<{n}q", index_bytes)

    records_bytes = _http_range(url, 0, ends[-1] - 1)

    out = []
    start = 0
    for end in ends:
        out.append(_decode_record(records_bytes[start:end]))
        start = end
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--url", default=DEFAULT_URL, help="Bag file URL")
    ap.add_argument("--n", type=int, default=10_000_000, help="Number of records to fetch")
    ap.add_argument("--clip", type=int, default=1500, help="Centipawn clip; positions beyond are dropped")
    ap.add_argument("--out", default="chessbench.csv", help="Output CSV path")
    ap.add_argument("--seed", type=int, default=42, help="Shuffle seed (0 to skip shuffling)")
    args = ap.parse_args()

    records = fetch_records(args.url, args.n)

    rows = []
    n_skipped = 0
    for fen, win_prob in records:
        active_is_white = fen.split(" ")[1] == "w"
        cp = _win_prob_to_cp(win_prob, active_is_white)
        if abs(cp) > args.clip:
            n_skipped += 1
            continue
        rows.append((fen, cp))

    print(f"kept {len(rows):,}, skipped {n_skipped:,} (|cp| > {args.clip})", file=sys.stderr)

    if args.seed:
        random.seed(args.seed)
        random.shuffle(rows)

    with open(args.out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["fen", "score_cp"])
        w.writerows(rows)

    print(f"wrote {args.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
