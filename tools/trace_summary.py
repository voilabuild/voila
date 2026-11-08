#!/usr/bin/env python3
"""Summarize a VOILA_TRACE file: where the time of one `voila run` went.

    VOILA_TRACE=/tmp/t.json voila run --rm img -- cmd
    python3 tools/trace_summary.py /tmp/t.json

Open the same file in https://ui.perfetto.dev for the timeline.
"""

import json
import statistics
import sys
from collections import defaultdict


def load(path: str) -> list[dict]:
    text = open(path, encoding="utf-8").read().rstrip().rstrip(",")
    if not text.endswith("]"):
        text += "]"
    return json.loads(text)


def ms(us: float) -> str:
    return f"{us / 1000:8.1f} ms"


def union(intervals: list[tuple[int, int]]) -> int:
    total, end = 0, -1
    for s, e in sorted(intervals):
        if s > end:
            total += e - s
            end = e
        elif e > end:
            total += e - end
            end = e
    return total


def main() -> None:
    events = load(sys.argv[1])
    spans = [e for e in events if e.get("ph") == "X"]
    if not spans:
        sys.exit("no spans in trace (was VOILA_TRACE set?)")
    names = {e["pid"]: e["args"]["name"] for e in events if e.get("ph") == "M" and e["name"] == "process_name"}
    t0 = min(e["ts"] for e in spans)
    t_end = max(e["ts"] + e["dur"] for e in spans)
    print(f"wall: {ms(t_end - t0)}  ({len(spans)} spans, {len(names)} processes)\n")

    print("phases (start offset, duration):")
    skip = ("fuse ", "http ", "fetch for read", "prefetch", "http GET chunk", "decompress and verify",
            "store chunk", "reload chunk from store", "wait for another fetch", "vfs lock wait", "warm connection")
    for e in sorted(spans, key=lambda e: e["ts"]):
        if e["name"].startswith(skip):
            continue
        who = names.get(e["pid"], str(e["pid"]))
        print(f"  +{ms(e['ts'] - t0)}  {ms(e['dur'])}  {e['name']:<28} [{who}]")

    http = [e for e in spans if e["name"] == "http GET chunk"]
    if http:
        lat = sorted(e["dur"] for e in http)
        wire = sum(e["args"].get("bytes", 0) for e in http)
        busy = union([(e["ts"], e["ts"] + e["dur"]) for e in http])
        first, last = min(e["ts"] for e in http), max(e["ts"] + e["dur"] for e in http)
        print(f"\nchunk fetches: {len(http)}, {wire / 1e6:.1f} MB on the wire")
        print(f"  http latency p50 {ms(statistics.median(lat))}, p90 {ms(lat[int(len(lat) * 0.9)])}, max {ms(lat[-1])}")
        print(f"  first fetch at +{ms(first - t0)}, last done at +{ms(last - t0)}")
        print(f"  time with >=1 fetch in flight: {ms(busy)}; throughput while busy {wire / max(busy, 1):.1f} MB/s")
        print(f"  average fetches in flight while busy: {sum(e['dur'] for e in http) / max(busy, 1):.1f}")
        for name in ("fetch for read", "prefetch"):
            xs = [e for e in spans if e["name"] == name]
            if xs:
                print(f"  {name}: {len(xs)} chunks, {ms(sum(e['dur'] for e in xs))} summed")
        for name in ("decompress and verify", "store chunk", "reload chunk from store", "wait for another fetch", "vfs lock wait", "warm connection"):
            xs = [e["dur"] for e in spans if e["name"] == name]
            if xs:
                print(f"  {name}: {len(xs)}x, {ms(sum(xs))} summed, max {ms(max(xs))}")

    reqs = [e for e in spans if e["name"].startswith("http ") and e["name"] != "http GET chunk"]
    if reqs:
        print("\nHTTP requests (process, method, host, count, new connections, summed, max):")
        groups: dict[tuple[str, str, str], list[dict]] = defaultdict(list)
        for e in reqs:
            url = e["args"].get("url", "")
            host = url.split("/")[2] if url.count("/") >= 2 else url
            who = names.get(e["pid"], str(e["pid"])).split(" (")[0]
            groups[(who, e["name"][5:], host)].append(e)
        for (who, method, host), xs in sorted(groups.items(), key=lambda kv: -sum(e["dur"] for e in kv[1])):
            fresh = sum(1 for e in xs if not e["args"].get("pooled_conn"))
            print(f"  {who:<28} {method:<4} {host:<24} {len(xs):4d} {fresh:4d}  {ms(sum(e['dur'] for e in xs))}  {ms(max(e['dur'] for e in xs))}")
        cdn: dict[tuple[str, str], list[int]] = defaultdict(list)
        for e in reqs:
            if e["args"].get("cdn_cache"):
                cdn[(e["args"]["cdn_cache"], e["args"].get("cdn_colo", "?"))].append(e["dur"])
        if cdn:
            print("\nCDN (cf-cache-status, edge, requests, median time):")
            for (status, colo), durs in sorted(cdn.items(), key=lambda kv: -len(kv[1])):
                print(f"  {status:<8} {colo:<5} {len(durs):5d}  {ms(statistics.median(durs))}")
        errors = [e for e in reqs if "error" in e["args"]]
        for e in errors[:10]:
            print(f"  error: {e['args']['error']} after {ms(e['dur'])}: {e['args'].get('url')}")

    ops = defaultdict(list)
    for e in spans:
        if e["name"].startswith("fuse "):
            ops[e["name"]].append(e)
    if ops:
        print("\nFUSE ops (count, summed time, max):")
        for name, xs in sorted(ops.items(), key=lambda kv: -sum(e["dur"] for e in kv[1])):
            print(f"  {name:<14} {len(xs):6d}  {ms(sum(e['dur'] for e in xs))}  {ms(max(e['dur'] for e in xs))}")
        reads = ops.get("fuse read", [])
        by_file: dict[str, list[int]] = defaultdict(list)
        for e in reads:
            by_file[e["args"].get("path", "?")].append(e["dur"])
        if by_file:
            print("\nslowest files to read (summed read time, reads, bytes):")
            top = sorted(by_file.items(), key=lambda kv: -sum(kv[1]))[:10]
            sizes = defaultdict(int)
            for e in reads:
                sizes[e["args"].get("path", "?")] += e["args"].get("got", 0)
            for path, durs in top:
                print(f"  {ms(sum(durs))}  {len(durs):4d}  {sizes[path] / 1e6:7.2f} MB  {path}")


if __name__ == "__main__":
    main()
