# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Dan "Ducky" Little
"""Combine several suite runs into one set of publishable figures.

A single 11-repeat run is not reproducible enough to publish from. Two clean
runs on an idle machine have measured geometric means 31% apart for Turf and
20% apart for polyclip-ts, while qdgeo, GEOS and Rust Geo stayed within 11%.
The JavaScript engines carry the variance; the WASM and native ones do not.

So: run the suite at least three times, and report the **median across runs** of
each per-case median, and the spread alongside it. The spread is the honest
error bar on every ratio this project publishes.

Usage:  aggregate.py report1.json report2.json report3.json [...]
"""
import json
import math
import statistics
import sys

ENGINES = ('zig-wasm', 'zig-native', 'geos', 'rust-geo', 'jsts', 'turf', 'polyclip-ts')


def load(paths):
    runs = []
    for p in paths:
        rep = json.load(open(p))
        runs.append({(x['id'], x['engine']): x for x in rep['results']})
    return runs


def main():
    if len(sys.argv) < 4:
        sys.exit('need at least three runs; a single run is not publishable')
    runs = load(sys.argv[1:])
    keys = set(runs[0])
    for r in runs[1:]:
        keys &= set(r)

    # Per case and engine: the median of the per-run medians, and the spread.
    med, spread = {}, {}
    for k in sorted(keys):
        times = [r[k]['median_ms'] for r in runs]
        med[k] = statistics.median(times)
        spread[k] = (max(times) - min(times)) / max(min(times), 1e-12)

    print(f'{len(runs)} runs; every figure below is the median across them.\n')
    print('## Per-case medians (ms), with run-to-run spread\n')
    print('| case | ' + ' | '.join(ENGINES) + ' |')
    print('| --- |' + ' ---: |' * len(ENGINES))
    cases = sorted({k[0] for k in keys})
    for cid in cases:
        cells = []
        for e in ENGINES:
            if (cid, e) not in med:
                cells.append('—')
                continue
            ok = runs[0][(cid, e)]['pass']
            cells.append(f'{med[(cid, e)]:.3g}{"" if ok else " †"}')
        print(f'| `{cid}` | ' + ' | '.join(cells) + ' |')

    print('\n## Geometric mean over each engine\'s correct workloads\n')
    base = {cid: med[(cid, 'zig-wasm')] for cid in cases if (cid, 'zig-wasm') in med}
    print('| engine | speed | runs min..max | workloads |')
    print('| --- | ---: | ---: | ---: |')
    for e in ENGINES:
        per_run = []
        for r in runs:
            rows = [(cid, r[(cid, e)]) for cid in cases
                    if (cid, e) in r and r[(cid, e)]['pass'] and r[(cid, 'zig-wasm')]['median_ms'] > 0]
            if not rows:
                continue
            per_run.append(math.exp(sum(
                math.log(x['median_ms'] / r[(cid, 'zig-wasm')]['median_ms']) for cid, x in rows) / len(rows)))
        if not per_run:
            continue
        n = len([cid for cid in cases if (cid, e) in runs[0] and runs[0][(cid, e)]['pass']])
        print(f'| {e} | **{statistics.median(per_run):.2f}x** | {min(per_run):.2f}..{max(per_run):.2f} | {n} |')

    worst = max(spread.values())
    print(f'\nWorst per-case spread across runs: **{100 * worst:.0f}%**.')
    print('Quote ratios to two significant figures at most; the third is noise.')


if __name__ == '__main__':
    main()
