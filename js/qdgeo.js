// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
// The JavaScript binding for qdgeo.
//
// The library speaks one shape: a single block holding every coordinate, then
// the index arrays that cut it into rings, polygons and lines. That is the same
// layout OpenLayers keeps internally, so most hosts hand their arrays over with
// no conversion at all.
//
// A *shape* here is a polygon: a list of rings, each a list of [x, y], shell
// first and holes after. Every operation takes a list of them.

/** Operation codes, for `apply`. Each also has a named method. */
export const OP = {
  union: 0,
  intersection: 1,
  difference: 2,
  symmetricDifference: 3,
  buffer: 4,
};

/** What a nonzero status from the module means. */
export const STATUS = {
  0: 'ok',
  1: 'out of memory',
  2: 'unsupported geometry',
  3: 'limit exceeded',
  4: 'coordinate out of range',
  5: 'malformed geometry, or the arrangement could not be resolved',
  6: 'invalid options',
};

export async function load(url = '../vendor/qdgeo.wasm') {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`could not fetch ${url} (${response.status})`);
  const { instance } = await WebAssembly.instantiate(await response.arrayBuffer(), {});
  return new Geometry(instance.exports);
}

// A result is a collection of shapes, so it is accepted anywhere a collection
// is — which is what makes `buffer(union(shapes), 15)` work without the caller
// unpacking anything.
const isResult = (value) =>
  value != null && value.coordinates !== undefined && value.polygonEnds !== undefined;

// An operand may be a result, a bare list of shapes, or the full object when
// there are lines or points to buffer as well.
const asInput = (operand) => {
  if (operand == null) return {};
  if (isResult(operand)) return { polygons: operand };
  if (Array.isArray(operand)) return { polygons: operand };
  return operand;
};

// How many shapes an operand holds, which is the operand split the module wants.
const countShapes = (operand) => {
  const { polygons } = asInput(operand);
  if (polygons === undefined) return 0;
  return isResult(polygons) ? polygons.polygonEnds.length : polygons.length;
};

/**
 * A result, in the layout the library actually produced.
 *
 * `coordinates` is every x and y in one array, and the two index arrays cut it
 * into rings and the rings into polygons — the same shape OpenLayers keeps and
 * deck.gl wants. They are owned copies, so a result stays valid after the next
 * call, and copying them is one `memcpy` rather than a few million small array
 * allocations.
 *
 * `toArrays()` builds the nested form on demand, for a host that wants it.
 */
export class Result {
  constructor(coordinates, ringEnds, polygonEnds) {
    this.coordinates = coordinates;
    this.ringEnds = ringEnds;
    this.polygonEnds = polygonEnds;
  }

  /** How many polygons. */
  get length() {
    return this.polygonEnds.length;
  }

  /** `[[[x, y], ...], ...]` per polygon, shell first and holes after. */
  toArrays() {
    const out = [];
    let ring = 0;
    let point = 0;
    for (let s = 0; s < this.polygonEnds.length; s++) {
      const polygon = [];
      for (; ring < this.polygonEnds[s]; ring++) {
        const coords = [];
        for (; point < this.ringEnds[ring]; point++) {
          coords.push([this.coordinates[2 * point], this.coordinates[2 * point + 1]]);
        }
        polygon.push(coords);
      }
      out.push(polygon);
    }
    return out;
  }

  /** Ring start and end, in coordinates, for ring `i`. */
  ring(i) {
    return [i === 0 ? 0 : this.ringEnds[i - 1], this.ringEnds[i]];
  }
}

class Geometry {
  constructor(exports) {
    this.w = exports;
  }

  /** Everything covered by any of `shapes`. N-ary: overlapping input stacks. */
  union(shapes, options) {
    return this.apply(OP.union, shapes, [], options);
  }

  /** Where `a` and `b` overlap. */
  intersection(a, b, options) {
    return this.apply(OP.intersection, a, b, options);
  }

  /** In `a` and not in `b`. */
  difference(a, b, options) {
    return this.apply(OP.difference, a, b, options);
  }

  /** In one of `a` and `b` but not both. */
  symmetricDifference(a, b, options) {
    return this.apply(OP.symmetricDifference, a, b, options);
  }

  /**
   * Grow `shapes` by `distance`, or shrink them when it is negative. The
   * distance may also arrive in the options — `buffer(shapes, { distance })` —
   * which reads better when the shapes are themselves a call.
   *
   * Accepts a result, a list of shapes, or `{ polygons, lines, points }`. Lines
   * and points only contribute when the distance is positive, since neither has
   * an interior to erode.
   */
  buffer(shapes, distance, options) {
    const settings = typeof distance === 'object' && distance !== null ? distance : options;
    const metres = typeof distance === 'number' ? distance : (settings?.distance ?? 0);
    return this.apply(OP.buffer, shapes, [], { ...settings, distance: metres });
  }

  /**
   * The generic form the named methods above are built on. Prefer them — this
   * exists for a host that already has an operation in a variable.
   *
   * @param op one of `OP`.
   * @param a the first operand; a list of shapes, or `{ polygons, lines, points }`.
   * @param b the second operand, for the binary operations. Ignored by union
   *   and buffer, which are n-ary over `a`.
   * @param options.distance buffer distance, which applies to every operation:
   *   on a boolean a nonzero distance buffers the result.
   * @param options.steps segments per quarter circle on a rounded corner.
   * @returns a `Result`: flat coordinates plus ring and polygon ends, with
   *   `toArrays()` for the nested form.
   */
  apply(op, a, b = [], { distance = 0, steps = 16 } = {}) {
    const { w } = this;
    const first = asInput(a);
    const second = asInput(b);
    // Only the first operand contributes non-areal geometry: buffer is the one
    // operation that takes any, and it is n-ary over `a`.
    const lines = first.lines ?? [];
    const points = first.points ?? [];

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
    // A whole result goes in as it is: one coordinate array appended once, and
    // both index arrays shifted. No shape is unpacked and no coordinate is
    // read, which is the point of a result having this shape in the first
    // place — `buffer(union(shapes), 15)` costs two index loops.
    const appendResult = (result) => {
      const base = coordinates.length / 2;
      const ringBase = ringEnds.length;
      for (const value of result.coordinates) coordinates.push(value);
      for (const end of result.ringEnds) ringEnds.push(base + end);
      for (const end of result.polygonEnds) polygonEnds.push(ringBase + end);
    };

    for (const group of [first.polygons, second.polygons]) {
      if (group === undefined) continue;
      if (isResult(group)) {
        appendResult(group);
        continue;
      }
      for (const shape of group) {
        // A shape is either rings of [x, y] pairs, or the flat form a host like
        // OpenLayers already holds. Taking both means such a host never has to
        // explode its coordinates into pairs just to have them flattened again.
        if (Array.isArray(shape)) {
          for (const ring of shape) {
            for (const [x, y] of ring) coordinates.push(x, y);
            ringEnds.push(coordinates.length / 2);
          }
        } else if (isResult(shape)) {
          appendResult(shape);
          continue;
        } else {
          const base = coordinates.length / 2;
          for (const value of shape.coordinates) coordinates.push(value);
          for (const end of shape.ringEnds) ringEnds.push(base + end);
        }
        polygonEnds.push(ringEnds.length);
      }
    }

    const total = coordinates.length / 2;
    const ptr = w.geom_input(
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

    // The module wants the split rather than two blocks, so the count of
    // shapes in `a` is what separates the operands.
    const status = w.geom_apply(op, countShapes(a), distance, steps);
    if (status) throw new Error(STATUS[status] ?? `status ${status}`);
    return this.#result();
  }

  #result() {
    const { w } = this;
    const out = w.geom_result_ptr();
    const total = w.geom_result_coordinates();
    const rings = w.geom_result_rings();
    const shapes = w.geom_result_polygons();
    if (!total) return new Result(new Float64Array(0), new Uint32Array(0), new Uint32Array(0));

    // Results are always areal, so the block is coordinates, ring ends and
    // polygon ends and nothing else. Three slices copy it out; the module is
    // free to reuse its block on the next call.
    const ends = new Uint32Array(w.memory.buffer, out + 16 * total, rings + shapes);
    return new Result(
      new Float64Array(w.memory.buffer, out, 2 * total).slice(),
      ends.slice(0, rings),
      ends.slice(rings),
    );
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
