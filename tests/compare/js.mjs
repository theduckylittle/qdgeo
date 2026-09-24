// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { performance } from 'node:perf_hooks';
import * as polyclip from 'polyclip-ts';
import turfUnion from '@turf/union';
import turfBuffer from '@turf/buffer';
// JSTS is the JavaScript port of JTS, which is what GEOS itself is a port of.
// It is the closest thing in this suite to a second reference implementation.
// The side-effect import is how JSTS attaches the overlay methods to Geometry.
import 'jsts/org/locationtech/jts/monkey.js';
import GeoJSONReader from 'jsts/org/locationtech/jts/io/GeoJSONReader.js';
import GeoJSONWriter from 'jsts/org/locationtech/jts/io/GeoJSONWriter.js';
import UnaryUnionOp from 'jsts/org/locationtech/jts/operation/union/UnaryUnionOp.js';

const [fixturePath, outputPath, repeatsArg = '5'] = process.argv.slice(2);
const fixture = JSON.parse(readFileSync(fixturePath));
const repeats = Number(repeatsArg);
const wasmModule = new WebAssembly.Module(readFileSync('zig-out/bin/qdgeo.wasm'));
if (WebAssembly.Module.imports(wasmModule).length)
  throw new Error('WASM module gained host imports');
const w = new WebAssembly.Instance(wasmModule, {}).exports;
// rust-geo behind the same flat ABI, in this same host, so the comparison is
// WASM against WASM with one interchange format and one timing boundary.
//
// Rust is the one toolchain this suite needs that nothing else in the project
// does, and it only builds this comparison shim. So it is optional: without
// `cargo build` having been run, rust-geo drops out of the run and every other
// engine is still measured. The report records which engines were present, so
// a missing column is visible rather than silently absent.
const rustPath = 'tests/compare/rust/target/wasm32-unknown-unknown/release/geo_comparison.wasm';
let rust;
if (existsSync(rustPath)) {
  const rustModule = new WebAssembly.Module(readFileSync(rustPath));
  if (WebAssembly.Module.imports(rustModule).length)
    throw new Error('rust-geo WASM gained host imports');
  rust = new WebAssembly.Instance(rustModule, {}).exports;
} else {
  console.error(`rust-geo skipped: ${rustPath} is missing (see tests/compare/README.md)`);
}
function rustGeo(flat, c) {
  const n = flat.coordinates.length / 2;
  const ptr = rust.rg_input(n, flat.ringEnds.length, flat.polygonEnds.length);
  new Float64Array(rust.memory.buffer, ptr, flat.coordinates.length).set(flat.coordinates);
  new Uint32Array(rust.memory.buffer, rust.rg_ring_ends_ptr(), flat.ringEnds.length).set(
    flat.ringEnds,
  );
  new Uint32Array(rust.memory.buffer, rust.rg_polygon_ends_ptr(), flat.polygonEnds.length).set(
    flat.polygonEnds,
  );
  const status = rust.rg_execute(c.operation === 'union' ? 0 : 4, 0, c.distance, c.steps);
  if (status) throw new Error(`rust-geo status ${status}`);
  const nc = rust.rg_result_coordinates(),
    nr = rust.rg_result_rings(),
    np = rust.rg_result_polygons();
  return {
    coordinates: new Float64Array(rust.memory.buffer, rust.rg_result_ptr(), 2 * nc).slice(),
    ringEnds: Array.from(new Uint32Array(rust.memory.buffer, rust.rg_result_ring_ends_ptr(), nr)),
    polygonEnds: Array.from(
      new Uint32Array(rust.memory.buffer, rust.rg_result_polygon_ends_ptr(), np),
    ),
  };
}
const empty = () => ({ type: 'MultiPolygon', coordinates: [] });
const polygons = (gs) =>
  gs.flatMap((g) => (g.type === 'Polygon' ? [g.coordinates] : g.coordinates));

// The flat block, which is the only ABI the browser artifact carries: one
// coordinate array plus ring and polygon ends, counted in coordinates.
function encode(gs) {
  const coordinates = [],
    ringEnds = [],
    polygonEnds = [];
  let n = 0;
  for (const p of polygons(gs)) {
    for (const r of p) {
      for (const [x, y] of r) {
        coordinates.push(x, y);
        n++;
      }
      ringEnds.push(n);
    }
    polygonEnds.push(ringEnds.length);
  }
  return { coordinates: Float64Array.from(coordinates), ringEnds, polygonEnds };
}
function decode({ coordinates, ringEnds, polygonEnds }) {
  const out = [];
  let ring = 0,
    point = 0;
  for (const end of polygonEnds) {
    const polygon = [];
    for (; ring < end; ring++) {
      const r = [];
      for (; point < ringEnds[ring]; point++)
        r.push([coordinates[2 * point], coordinates[2 * point + 1]]);
      polygon.push(r);
    }
    out.push(polygon);
  }
  return { type: 'MultiPolygon', coordinates: out };
}
function wasm(flat, c) {
  const n = flat.coordinates.length / 2;
  const ptr = w.geom_input(n, flat.ringEnds.length, flat.polygonEnds.length, 0, 0);
  if (!ptr) throw new Error('WASM input allocation failed');
  new Float64Array(w.memory.buffer, ptr, flat.coordinates.length).set(flat.coordinates);
  const indices = new Uint32Array(
    w.memory.buffer,
    ptr + 16 * n,
    flat.ringEnds.length + flat.polygonEnds.length,
  );
  indices.set(flat.ringEnds);
  indices.set(flat.polygonEnds, flat.ringEnds.length);
  const status =
    c.operation === 'union' ? w.geom_apply(0, 0, 0, 0) : w.geom_apply(4, 0, c.distance, c.steps);
  if (status) throw new Error(`WASM status ${status}`);
  const out = w.geom_result_ptr();
  const nc = w.geom_result_coordinates();
  const nr = w.geom_result_rings();
  const np = w.geom_result_polygons();
  const ends = new Uint32Array(w.memory.buffer, out + 16 * nc, nr + np);
  return {
    coordinates: new Float64Array(w.memory.buffer, out, 2 * nc).slice(),
    ringEnds: Array.from(ends.slice(0, nr)),
    polygonEnds: Array.from(ends.slice(nr)),
  };
}
const jstsReader = new GeoJSONReader();
const jstsWriter = new GeoJSONWriter();
// Same shape as the GEOS reference in run.py: union everything, then buffer the
// union, so a multi-geometry buffer means buffer-of-the-union for both.
function jsts(geometries, c) {
  const collection = jstsReader.read({ type: 'GeometryCollection', geometries });
  let g = UnaryUnionOp.union(collection);
  if (c.operation === 'buffer') g = g.buffer(c.distance, c.steps);
  if (g.isEmpty()) return empty();
  const out = jstsWriter.write(g);
  return out.type === 'Polygon' ? { type: 'MultiPolygon', coordinates: [out.coordinates] } : out;
}

const rad = Math.PI / 180,
  R = 6371008.8;
const [lon0, lat0] = fixture.metadata.center.map((x) => x * rad);
// Spherical AEQD forward/inverse, the same global CRS used by prepare.py.
function forward([lon, lat]) {
  const phi = lat * rad,
    lam = lon * rad - lon0;
  const cosc = Math.sin(lat0) * Math.sin(phi) + Math.cos(lat0) * Math.cos(phi) * Math.cos(lam);
  const c = Math.acos(Math.max(-1, Math.min(1, cosc))),
    k = c < 1e-12 ? 1 : c / Math.sin(c);
  return [
    R * k * Math.cos(phi) * Math.sin(lam),
    R * k * (Math.cos(lat0) * Math.sin(phi) - Math.sin(lat0) * Math.cos(phi) * Math.cos(lam)),
  ];
}
function inverse([x, y]) {
  const rho = Math.hypot(x, y),
    c = rho / R;
  if (rho < 1e-12) return [lon0 / rad, lat0 / rad];
  return [
    (lon0 +
      Math.atan2(
        x * Math.sin(c),
        rho * Math.cos(lat0) * Math.cos(c) - y * Math.sin(lat0) * Math.sin(c),
      )) /
      rad,
    Math.asin(Math.cos(c) * Math.sin(lat0) + (y * Math.sin(c) * Math.cos(lat0)) / rho) / rad,
  ];
}
const mapCoords = (a, fn) => (typeof a[0] === 'number' ? fn(a) : a.map((x) => mapCoords(x, fn)));
function turf(gs, c) {
  let geometry =
    gs.length === 0
      ? empty()
      : gs.length === 1
        ? gs[0]
        : (turfUnion({
            type: 'FeatureCollection',
            features: gs.map((g) => ({ type: 'Feature', properties: {}, geometry: g })),
          })?.geometry ?? empty());
  if (c.operation === 'union' || geometry.coordinates.length === 0) return geometry;
  const geographic = { type: geometry.type, coordinates: mapCoords(geometry.coordinates, inverse) };
  const buffered = turfBuffer(geographic, c.distance, { units: 'meters', steps: c.steps });
  return buffered
    ? {
        type: buffered.geometry.type,
        coordinates: mapCoords(buffered.geometry.coordinates, forward),
      }
    : empty();
}
const results = [];
for (const c of fixture.cases) {
  const flat = encode(c.geometries);
  for (const engine of ['zig-wasm', 'rust-geo', 'jsts', 'polyclip-ts', 'turf']) {
    if (engine === 'polyclip-ts' && c.operation !== 'union') continue;
    if (engine === 'rust-geo' && !rust) continue;
    const isWasm = engine === 'zig-wasm' || engine === 'rust-geo';
    // A lone geometry still goes through the union engine in all union tests.
    const fn =
      engine === 'rust-geo'
        ? () => rustGeo(flat, c)
        : engine === 'zig-wasm'
          ? () => wasm(flat, c)
          : engine === 'jsts'
            ? () => jsts(c.geometries, c)
            : engine === 'polyclip-ts'
              ? () => ({
                  type: 'MultiPolygon',
                  coordinates: polyclip.union(...c.geometries.map((g) => g.coordinates)),
                })
              : () =>
                  c.operation === 'union' && c.geometries.length === 1
                    ? (turfUnion({
                        type: 'FeatureCollection',
                        features: [c.geometries[0], c.geometries[0]].map((g) => ({
                          type: 'Feature',
                          properties: {},
                          geometry: g,
                        })),
                      })?.geometry ?? empty())
                    : turf(c.geometries, c);
    try {
      fn(); // warmup, module loading/projection setup excluded
      const times = [];
      let output;
      for (let i = 0; i < repeats; i++) {
        const t = performance.now();
        output = fn();
        times.push(performance.now() - t);
      }
      results.push({
        id: c.id,
        engine,
        times_ms: times,
        timing: isWasm
          ? 'flat-in/out + host copy'
          : 'geometry-in/out (Turf buffers include reprojection)',
        geometry: isWasm ? decode(output) : output,
        wasm_memory_bytes: isWasm ? w.memory.buffer.byteLength : undefined,
      });
    } catch (error) {
      results.push({ id: c.id, engine, error: String(error) });
    }
    console.error(`${engine}: ${c.id}`);
    // Preserve partial results if a later workload fails/times out.
    writeFileSync(outputPath, JSON.stringify(results));
  }
}
