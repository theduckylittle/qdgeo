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

/**
 * Instantiate the module.
 *
 * The default is the `qdgeo.wasm` sitting next to this file, resolved through
 * `import.meta.url`, so `await load()` is correct in a browser and every
 * bundler emits the module as an asset without being told where it is.
 *
 * `source` may also be a URL or path, a `Response` (or a promise of one, so
 * `load(fetch(url))` works), raw bytes, or an already-compiled
 * `WebAssembly.Module` — which is the one to reach for when a strict CSP rules
 * out compiling from a fetch, or when the same module is instantiated more
 * than once.
 *
 * @param source {URL | string | Response | Promise<Response> | ArrayBuffer |
 *   ArrayBufferView | WebAssembly.Module}
 * @returns {Promise<Geometry>}
 */
export async function load(source = new URL('./qdgeo.wasm', import.meta.url)) {
  return new Geometry(await instantiate(await source));
}

/** Whatever `load` was given, as the module's exports. */
async function instantiate(source) {
  // Compiled already: `instantiate` hands back the instance rather than a pair.
  if (source instanceof WebAssembly.Module) {
    return (await WebAssembly.instantiate(source, {})).exports;
  }
  if (source instanceof ArrayBuffer || ArrayBuffer.isView(source)) {
    return fromBytes(source);
  }
  if (typeof Response !== 'undefined' && source instanceof Response) {
    return fromResponse(source);
  }

  const url = await resolve(source);
  // Node's `fetch` rejects `file:` — "not implemented... yet..." — and that is
  // what the default resolves to off a disk, so those are read directly. The
  // same call then works in Node, a test runner and a browser alike.
  if (url.protocol === 'file:') {
    const { readFileURL } = await import('#platform');
    return fromBytes(await readFileURL(url));
  }
  return fromResponse(await fetch(url));
}

const fromBytes = async (buffer) => (await WebAssembly.instantiate(buffer, {})).instance.exports;

async function fromResponse(response) {
  if (!response.ok) {
    throw new Error(`could not fetch ${response.url} (${response.status})`);
  }
  // Streaming compiles while the module downloads, but it insists on
  // `application/wasm` and plenty of static hosts do not send it. So it is
  // tried, not assumed.
  try {
    return (await WebAssembly.instantiateStreaming(response.clone(), {})).instance.exports;
  } catch {
    return fromBytes(await response.arrayBuffer());
  }
}

/** A path against the right base: the page, the worker, or the process. */
async function resolve(source) {
  if (source instanceof URL) return source;
  const here = globalThis.document?.baseURI ?? globalThis.location?.href;
  if (here) return new URL(source, here);
  // Node, where a relative path means relative to the process — the way every
  // other path handed to a script does.
  const { base } = await import('#platform');
  return new URL(source, await base());
}

/**
 * The shapes these operations speak, named once so the signatures can use them.
 *
 * @typedef {[number, number]} Point a single x and y
 * @typedef {Point[]} Ring a closed list of points, first equal to last
 * @typedef {Ring[]} Shape a polygon: shell first, then holes
 * @typedef {Shape[] | Result} Collection a list of shapes, or a result
 * @typedef {Collection | { polygons?: Collection, lines?: Ring[], points?: Point[] }} Operand
 *   a collection, or the longer form when there are lines or points to buffer
 * @typedef {{ distance?: number, steps?: number }} Options
 *   `distance` buffers the result — negative shrinks — and `steps` is how many
 *   segments make up a quarter circle at a rounded corner
 */

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
  /**
   * @param coordinates {Float64Array} every x and y, in one block
   * @param ringEnds {Uint32Array} exclusive end of each ring, in coordinates
   * @param polygonEnds {Uint32Array} exclusive end of each polygon, in rings
   */
  constructor(coordinates, ringEnds, polygonEnds) {
    this.coordinates = coordinates;
    this.ringEnds = ringEnds;
    this.polygonEnds = polygonEnds;
  }

  /** How many polygons. @returns {number} */
  get length() {
    return this.polygonEnds.length;
  }

  /**
   * `[[[x, y], ...], ...]` per polygon, shell first and holes after.
   *
   * @returns {Shape[]}
   */
  toArrays() {
    /** @type {Shape[]} */
    const out = [];
    let ring = 0;
    let point = 0;
    for (let s = 0; s < this.polygonEnds.length; s++) {
      /** @type {Shape} */
      const polygon = [];
      for (; ring < this.polygonEnds[s]; ring++) {
        /** @type {Ring} */
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

  /**
   * Ring start and end, in coordinates, for ring `i`.
   *
   * @param i {number}
   * @returns {[number, number]}
   */
  ring(i) {
    return [i === 0 ? 0 : this.ringEnds[i - 1], this.ringEnds[i]];
  }
}

class Geometry {
  constructor(exports) {
    this.w = exports;
  }

  /**
   * Everything covered by any of `shapes`. N-ary: overlapping input stacks.
   *
   * @param shapes {Operand}
   * @param [options] {Options}
   * @returns {Result}
   */
  union(shapes, options) {
    return this.apply(OP.union, shapes, [], options);
  }

  /**
   * Where `a` and `b` overlap.
   *
   * @param a {Operand}
   * @param b {Operand}
   * @param [options] {Options}
   * @returns {Result}
   */
  intersection(a, b, options) {
    return this.apply(OP.intersection, a, b, options);
  }

  /**
   * In `a` and not in `b`.
   *
   * @param a {Operand}
   * @param b {Operand}
   * @param [options] {Options}
   * @returns {Result}
   */
  difference(a, b, options) {
    return this.apply(OP.difference, a, b, options);
  }

  /**
   * In one of `a` and `b` but not both.
   *
   * @param a {Operand}
   * @param b {Operand}
   * @param [options] {Options}
   * @returns {Result}
   */
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
   *
   * @param shapes {Operand}
   * @param distance {number | Options}
   * @param [options] {Options}
   * @returns {Result}
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
   * @param op {number} one of `OP`.
   * @param a {Operand} the first operand.
   * @param b {Operand} the second, for the binary operations. Ignored by union
   *   and buffer, which are n-ary over `a`.
   * @param options {Options} `distance` applies to every operation: on a
   *   boolean, a nonzero distance buffers the result.
   * @returns {Result} flat coordinates plus ring and polygon ends, with
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
    const groups = [first.polygons, second.polygons].filter((g) => g !== undefined);

    // Measure first, then write straight into the module's block.
    //
    // Building a plain Array of numbers and copying it in afterwards measured
    // 6x to 17x slower than this, because every coordinate goes through a boxed
    // push. Counting is cheap — lengths and ring counts, no coordinates — and
    // it buys a path where a flat operand is one `set()`, which is a memcpy.
    let total = 0;
    let rings = 0;
    let shapes = 0;
    total = points.length;
    for (const line of lines) total += line.length;
    for (const group of groups) {
      if (isResult(group)) {
        total += group.coordinates.length / 2;
        rings += group.ringEnds.length;
        shapes += group.polygonEnds.length;
        continue;
      }
      for (const shape of group) {
        if (Array.isArray(shape)) {
          for (const ring of shape) total += ring.length;
          rings += shape.length;
        } else if (isResult(shape)) {
          total += shape.coordinates.length / 2;
          rings += shape.ringEnds.length;
        } else {
          total += shape.coordinates.length / 2;
          rings += shape.ringEnds.length;
        }
        shapes += 1;
      }
    }

    const ptr = w.geom_input(total, rings, shapes, lines.length, points.length);
    if (!ptr && total !== 0) throw new Error('the library could not allocate an input block');
    const xy = new Float64Array(w.memory.buffer, ptr, 2 * total);
    const index = new Uint32Array(w.memory.buffer, ptr + 16 * total, rings + shapes + lines.length);

    // Coordinates go in one fixed order: bare points, then line vertices, then
    // polygon ring vertices. Every index is an exclusive end, counted in
    // coordinates rather than numbers, so it never depends on the stride.
    let at = 0;
    let ring = 0;
    let shape = 0;
    let line = 0;
    const lineBase = rings + shapes;
    for (const [x, y] of points) {
      xy[2 * at] = x;
      xy[2 * at + 1] = y;
      at += 1;
    }
    for (const path of lines) {
      for (const [x, y] of path) {
        xy[2 * at] = x;
        xy[2 * at + 1] = y;
        at += 1;
      }
      index[lineBase + line++] = at;
    }
    // A flat operand is copied in one move and its index arrays are shifted.
    // Nothing reads a coordinate, which is what makes chaining cheap.
    const writeFlat = (coordinates, ringEnds) => {
      const base = at;
      xy.set(coordinates, 2 * at);
      at += coordinates.length / 2;
      for (const end of ringEnds) index[ring++] = base + end;
    };
    for (const group of groups) {
      if (isResult(group)) {
        const ringBase = ring;
        writeFlat(group.coordinates, group.ringEnds);
        for (const end of group.polygonEnds) index[rings + shape++] = ringBase + end;
        continue;
      }
      for (const item of group) {
        if (Array.isArray(item)) {
          for (const path of item) {
            for (const [x, y] of path) {
              xy[2 * at] = x;
              xy[2 * at + 1] = y;
              at += 1;
            }
            index[ring++] = at;
          }
        } else {
          writeFlat(item.coordinates, item.ringEnds);
        }
        index[rings + shape++] = ring;
      }
    }

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
/**
 * A ring with its first point repeated at the end, if it is not already there.
 * Every ring handed to an operation has to be closed.
 *
 * @param ring {Ring}
 * @returns {Ring}
 */
export const close = (ring) => {
  const [fx, fy] = ring[0];
  const [lx, ly] = ring[ring.length - 1];
  return fx === lx && fy === ly ? ring : [...ring, [fx, fy]];
};
