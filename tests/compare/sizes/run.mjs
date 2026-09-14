// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
//
// What a page actually downloads to do this work in a browser.
//
// Every JavaScript competitor is bundled with esbuild, minified, and gzipped,
// importing only the entry points the comparison suite uses. WASM competitors
// are measured as the artifact the page fetches. Raw bytes are reported too,
// because a WASM module is parsed from its raw form while minified JS is not.
//
//   node tests/compare/sizes/run.mjs
import { execFileSync } from 'node:child_process';
import { gzipSync } from 'node:zlib';
import { readFileSync, mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

// Entry points, written to match what tests/compare/js.mjs actually imports.
const BUNDLES = {
  turf: {
    ops: 'union, buffer',
    source: `import union from '@turf/union';\nimport buffer from '@turf/buffer';\nexport { union, buffer };`,
  },
  jsts: {
    ops: 'four booleans, buffer',
    source: `import 'jsts/org/locationtech/jts/monkey.js';
import GeoJSONReader from 'jsts/org/locationtech/jts/io/GeoJSONReader.js';
import GeoJSONWriter from 'jsts/org/locationtech/jts/io/GeoJSONWriter.js';
import UnaryUnionOp from 'jsts/org/locationtech/jts/operation/union/UnaryUnionOp.js';
export { GeoJSONReader, GeoJSONWriter, UnaryUnionOp };`,
  },
  'polyclip-ts': {
    ops: 'four booleans, no buffer',
    source: `import * as polyclip from 'polyclip-ts';\nexport { polyclip };`,
  },
};

// Prebuilt artifacts a page fetches as-is.
const ARTIFACTS = {
  qdgeo: { ops: 'four booleans, buffer', path: 'zig-out/bin/qdgeo.wasm' },
  'rust-geo': {
    ops: 'union, buffer',
    path: 'tests/compare/rust/target/wasm32-unknown-unknown/release/geo_comparison.wasm',
  },
};

// Decimal KB, the convention download sizes are usually quoted in.
const kb = (n) => `${(n / 1000).toFixed(1)} KB`;
const rows = [];

for (const [name, { ops, source }] of Object.entries(BUNDLES)) {
  // Bundle from inside the project so node_modules resolves.
  const dir = mkdtempSync(join(process.cwd(), '.sizes-'));
  try {
    const entry = join(dir, 'entry.mjs');
    const out = join(dir, 'out.js');
    writeFileSync(entry, source);
    execFileSync(
      'npx',
      [
        'esbuild',
        entry,
        '--bundle',
        '--minify',
        '--format=esm',
        '--platform=browser',
        `--outfile=${out}`,
      ],
      { stdio: ['ignore', 'ignore', 'ignore'] },
    );
    const bytes = readFileSync(out);
    rows.push({ name, ops, raw: bytes.length, gz: gzipSync(bytes, { level: 9 }).length });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

for (const [name, { ops, path }] of Object.entries(ARTIFACTS)) {
  try {
    const bytes = readFileSync(path);
    rows.push({ name, ops, raw: bytes.length, gz: gzipSync(bytes, { level: 9 }).length });
  } catch {
    console.error(`skipping ${name}: ${path} is missing`);
  }
}

rows.sort((a, b) => a.gz - b.gz);
const width = Math.max(...rows.map((r) => r.name.length));
console.log(
  `${'library'.padEnd(width)}  ${'gzipped'.padStart(10)}  ${'raw'.padStart(10)}   operations`,
);
for (const r of rows) {
  console.log(
    `${r.name.padEnd(width)}  ${kb(r.gz).padStart(10)}  ${kb(r.raw).padStart(10)}   ${r.ops}`,
  );
}
console.log(
  '\nGEOS has no official browser build. The community `geos-wasm` package is\n' +
    '2.58 MB raw / 778 KB gzipped, and carries all of GEOS rather than these operations.',
);
