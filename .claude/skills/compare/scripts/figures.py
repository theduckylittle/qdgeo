# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Dan "Ducky" Little
"""Turn a comparison run into the tables the README publishes.

Reads `tests/compare/generated/report.json` and prints ready-to-paste markdown.
Refuses to read a report older than the artifacts it supposedly measured, which
is the failure this script exists to prevent: a crashed run leaves the previous
report in place, and reading it silently republishes stale numbers.

    .venv/bin/python .claude/skills/compare/scripts/figures.py
"""
import argparse
import gzip
import json
import math
import re
import statistics
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
GENERATED = ROOT / 'tests/compare/generated'
ARTIFACTS = [ROOT / 'zig-out/bin/qdgeo.wasm', ROOT / 'zig-out/lib/libqdgeo_native.so']
ENGINES = ['zig-wasm', 'zig-native', 'geos', 'rust-geo', 'jsts', 'turf', 'polyclip-ts']
LABEL = {'zig-wasm': 'qdgeo wasm', 'zig-native': 'qdgeo native', 'geos': 'GEOS',
         'rust-geo': 'Rust Geo', 'jsts': 'JSTS', 'turf': 'Turf', 'polyclip-ts': 'polyclip-ts'}


def load():
    report, table = GENERATED / 'report.json', GENERATED / 'report.md'
    if not report.exists():
        sys.exit(f'{report} is missing — run `npm run compare` first')
    age = report.stat().st_mtime
    stale = [a for a in ARTIFACTS if a.exists() and a.stat().st_mtime > age]
    if stale:
        sys.exit('REPORT IS STALE: ' + ', '.join(a.name for a in stale)
                 + ' is newer than report.json.\nThe last run either crashed or predates the '
                   'current build. Re-run `npm run compare` and check its exit code.')
    data = json.loads(report.read_text())
    # A failing engine/workload pair is listed under "Failed checks" in report.md.
    failed = set((m.group(1), m.group(2))
                 for m in re.finditer(r'^- ([\w-]+) / ([\w+\-.]+):', table.read_text(), re.M))
    medians = {}
    for row in data['results']:
        if row.get('times_ms'):
            medians.setdefault(row['id'], {})[row['engine']] = statistics.median(row['times_ms'])
    return data, failed, medians


def cell(value, wrong):
    if value is None:
        return '—'
    shown = f'{value:.2f}' if value < 10 else (f'{value:.1f}' if value < 100 else f'{value:.0f}')
    return shown + (' †' if wrong else '')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sizes', action='store_true', help='include the artifact size line')
    args = parser.parse_args()
    data, failed, medians = load()
    totals = Counter(x['engine'] for x in data['results'])
    fails = Counter(e for e, _ in failed)
    repeats = data.get('metadata', {}).get('repeats') or data.get('environment', {}).get('repeats')

    print(f'# Comparison figures (medians of {repeats} runs)\n')
    if repeats and repeats < 9:
        print(f'> WARNING: only {repeats} repeats. Use 11 for anything published.\n')

    if args.sizes:
        for path in ARTIFACTS[:1]:
            raw = path.read_bytes()
            print(f'Artifact: {len(raw)/1000:.1f} KB raw, {len(gzip.compress(raw, 9))/1000:.1f} KB gzipped')
            print('(the README quotes `npm run sizes`, whose gzip differs by ~0.2 KB — use that one)\n')

    print('## Correctness\n')
    worst, reference = {}, 0.0
    for row in data['results']:
        if not row['id'].startswith('parcels-union'):
            continue
        if row.get('exact_error') is not None:
            worst[row['engine']] = max(worst.get(row['engine'], 0), row['exact_error'])
        if row.get('reference_exact_error') is not None:
            reference = max(reference, row['reference_exact_error'])
    print('| | workloads passed | worst vertex error |')
    print('| --- | ---: | ---: |')
    for engine in ENGINES:
        if engine == 'zig-native':
            continue
        error = f'{reference:.1g} m' if engine == 'geos' else (
            f'{worst[engine]:.1f} m' if worst.get(engine, 0) > 1 else
            f'{worst.get(engine, 0):.1g} m' if worst.get(engine) else '0 m')
        print(f'| {LABEL[engine]} | {totals[engine] - fails.get(engine, 0)} / {totals[engine]} | {error} |')
    print('\nRing counts are NOT in the report — measure them from the geometry with')
    print('`shapely`, never derive them from the hole count.\n')

    print('## Union\n')
    print('| parcels | ' + ' | '.join(LABEL[e] for e in ENGINES) + ' |')
    print('| ---: |' + ' ---: |' * len(ENGINES))
    for key, count in [('parcels-union-10', 10), ('parcels-union-100', 100),
                       ('parcels-union-1000', '1,000'), ('parcels-union-4040', '4,040')]:
        cells = [cell(medians[key].get(e), (e, key) in failed) for e in ENGINES]
        print(f'| {count} | ' + ' | '.join(cells) + ' |')

    print('\n## Buffer\n')
    areal = [e for e in ENGINES if e != 'polyclip-ts']
    print('| case | ' + ' | '.join(LABEL[e] for e in areal) + ' |')
    print('| --- |' + ' ---: |' * len(areal))
    for key in ['parcels-buffer-1-+2', 'parcels-buffer-100-+2', 'parcels-buffer-100--10',
                'complex-parcel-buffer-+2', 'complex-parcel-buffer--2']:
        cells = [cell(medians[key].get(e), (e, key) in failed) for e in areal]
        print(f'| `{key}` | ' + ' | '.join(cells) + ' |')

    print('\n## Overall — correct workloads only\n')
    print('| | speed | workloads averaged | excluded as wrong |')
    print('| --- | ---: | ---: | --- |')
    rows = []
    for engine in ENGINES:
        if engine == 'zig-wasm':
            continue
        passing = [k for k in medians if engine in medians[k] and (engine, k) not in failed]
        if not passing:
            continue
        mean = math.exp(sum(math.log(medians[k][engine] / medians[k]['zig-wasm']) for k in passing) / len(passing))
        dropped = sorted(k for k in medians if engine in medians[k] and (engine, k) in failed)
        rows.append((mean, engine, len(passing), dropped))
    rows.append((1.0, 'zig-wasm', totals['zig-wasm'], []))
    for mean, engine, n, dropped in sorted(rows):
        name = f'**{LABEL[engine]}**' if engine == 'zig-wasm' else LABEL[engine]
        speed = f'**{mean:.2f}x**' if engine == 'zig-wasm' else f'{mean:.2f}x'
        print(f'| {name} | {speed} | {n} | {", ".join(dropped) if dropped else "none"} |')
    print('\nSpeed is a geometric mean over each engine\'s CORRECT workloads. A wrong')
    print('answer is not a fast answer — never average one in.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
