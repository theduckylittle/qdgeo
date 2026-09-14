// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
// A small wrapper over the WASM flat-coordinate ABI.
//
// The library speaks one shape: a single block holding every coordinate, then
// the index arrays that cut it into rings, polygons and lines. That is the same
// layout OpenLayers keeps internally, so most hosts hand their arrays over with
// no conversion at all. This file exists to make the examples readable, not
// because the ABI needs a wrapper.

export const OP = {
  union: 0,
  intersection: 1,
  difference: 2,
  symmetricDifference: 3,
  buffer: 4,
};

const STATUS = {
  1: 'out of memory',
  2: 'unsupported geometry',
  3: 'limit exceeded',
  4: 'coordinate out of range',
  5: 'malformed geometry, or the overlay could not resolve it',
  6: 'invalid options',
};

export async function load(url = '../zig-out/bin/qdgeo.wasm') {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`could not fetch ${url} (${response.status})`);
  const { instance } = await WebAssembly.instantiate(await response.arrayBuffer(), {});
  return new Geometry(instance.exports);
}

class Geometry {
  constructor(exports) {
    this.w = exports;
  }

  /**
   * @param input {{polygons?: number[][][][], lines?: number[][][], points?: number[][]}}
   *   `polygons` is a list of polygons, each a list of rings, each a list of
   *   [x, y]. Ring 0 is the shell and the rest are holes. Every ring must be
   *   closed: its last coordinate equals its first.
   * @param op one of OP
   * @param options.subject for the boolean ops, how many leading polygons make
   *   up the first operand. The rest become the second.
   * @param options.distance for OP.buffer. Negative shrinks.
   * @param options.steps segments per quarter circle on a rounded corner.
   * @returns a list of polygons in the same nested shape.
   */
  run(input, op, { subject = 1, distance = 0, steps = 16 } = {}) {
    const { w } = this;
    const polygons = input.polygons ?? [];
    const lines = input.lines ?? [];
    const points = input.points ?? [];

    // Coordinates go in one fixed order: bare points, then line vertices, then
    // polygon ring vertices. Every index below is an exclusive end, counted in
    // coordinates rather than numbers, so it never depends on the stride.
    const coordinates = [];
    for (const [x, y] of points) coordinates.push(x, y);
    const lineEnds = [];
    for (const line of lines) {
      for (const [x, y] of line) coordinates.push(x, y);
      lineEnds.push(coordinates.length / 2);
    }
    const ringEnds = [];
    const polygonEnds = [];
    for (const polygon of polygons) {
      for (const ring of polygon) {
        for (const [x, y] of ring) coordinates.push(x, y);
        ringEnds.push(coordinates.length / 2);
      }
      polygonEnds.push(ringEnds.length);
    }

    const total = coordinates.length / 2;
    const ptr = w.geom_flat_input(
      total,
      ringEnds.length,
      polygonEnds.length,
      lineEnds.length,
      points.length,
    );
    if (!ptr) throw new Error('the library could not allocate an input block');

    // One bulk copy in. The block is reused between calls, so a map redrawing
    // a buffer on every slider tick pays no allocator traffic after the first.
    new Float64Array(w.memory.buffer, ptr, coordinates.length).set(coordinates);
    const indices = new Uint32Array(
      w.memory.buffer,
      ptr + 16 * total,
      ringEnds.length + polygonEnds.length + lineEnds.length,
    );
    indices.set(ringEnds, 0);
    indices.set(polygonEnds, ringEnds.length);
    indices.set(lineEnds, ringEnds.length + polygonEnds.length);

    const status = w.geom_flat_execute(op, subject, distance, steps);
    if (status) throw new Error(STATUS[status] ?? `status ${status}`);
    return this.#result();
  }

  #result() {
    const { w } = this;
    const out = w.geom_flat_result_ptr();
    const total = w.geom_flat_result_coordinates();
    const rings = w.geom_flat_result_rings();
    const shapes = w.geom_flat_result_polygons();
    if (!total) return [];

    // Results are always areal, so the block is coordinates, ring ends and
    // polygon ends and nothing else.
    const xy = new Float64Array(w.memory.buffer, out, 2 * total);
    const ends = new Uint32Array(w.memory.buffer, out + 16 * total, rings + shapes);
    const polygons = [];
    let ring = 0;
    let point = 0;
    for (let s = 0; s < shapes; s++) {
      const polygon = [];
      for (; ring < ends[rings + s]; ring++) {
        const coords = [];
        for (; point < ends[ring]; point++) coords.push([xy[2 * point], xy[2 * point + 1]]);
        polygon.push(coords);
      }
      polygons.push(polygon);
    }
    return polygons;
  }

  /** Release the last result. Each call already clears the one before it. */
  clear() {
    this.w.geom_clear();
  }
}

/** Close a ring if the caller left it open. */
export const close = (ring) => {
  const [fx, fy] = ring[0];
  const [lx, ly] = ring[ring.length - 1];
  return fx === lx && fy === ly ? ring : [...ring, [fx, fy]];
};

/** A regular polygon, handy for example geometry. */
export function regular(cx, cy, radius, sides, rotation = 0) {
  const ring = [];
  for (let i = 0; i < sides; i++) {
    const angle = rotation + (2 * Math.PI * i) / sides;
    ring.push([cx + radius * Math.cos(angle), cy + radius * Math.sin(angle)]);
  }
  return close(ring);
}

/** A star, which gives the boolean operations something concave to chew on. */
export function star(cx, cy, outer, inner, points = 5, rotation = -Math.PI / 2) {
  const ring = [];
  for (let i = 0; i < points * 2; i++) {
    const r = i % 2 ? inner : outer;
    const angle = rotation + (Math.PI * i) / points;
    ring.push([cx + r * Math.cos(angle), cy + r * Math.sin(angle)]);
  }
  return close(ring);
}
