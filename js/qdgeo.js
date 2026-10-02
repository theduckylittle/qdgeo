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

/**
 * The named predicates as DE-9IM patterns, with JTS's definitions. One
 * extension to JTS's language makes each a single pattern: `A` marks a group
 * of cells of which at least one must be non-empty. `touches`, `crosses` and
 * `overlaps` depend on the operands' dimensions, so those are functions of
 * them (2 polygons, 1 lines, 0 points, -1 empty), and return `null` where the
 * predicate is false for those dimensions outright.
 *
 * @type {Record<string, string | ((a: number, b: number) => string | null)>}
 */
export const PATTERN = {
  intersects: 'AA*AA****',
  disjoint: 'FF*FF****',
  contains: 'T*****FF*',
  within: 'T*F**F***',
  covers: 'AA*AA*FF*',
  coveredBy: 'AAFAAF***',
  equals: 'T*F**FFF*',
  touches: (a, b) => (a === 0 && b === 0 ? null : 'FA*AA****'),
  crosses: (a, b) => (a < b ? 'T*T******' : a > b ? 'T*****T**' : a === 1 ? '0********' : null),
  overlaps: (a, b) => (a !== b ? null : a === 1 ? '1*T***T**' : 'T*T***T**'),
};

/**
 * The code on a `QdgeoError` — a name, not a number, so a branch reads at the
 * call site and a typo fails the type check instead of silently matching.
 *
 * @typedef {'OUT_OF_MEMORY' | 'UNSUPPORTED_GEOMETRY' | 'LIMIT_EXCEEDED' |
 *   'COORDINATE_RANGE' | 'INVALID_GEOMETRY' | 'INVALID_OPTIONS' |
 *   'UNREPRESENTABLE'} Code
 */

/** The module's numeric statuses, as the codes a `QdgeoError` carries. */
export const STATUS = {
  0: 'OK',
  1: 'OUT_OF_MEMORY',
  2: 'UNSUPPORTED_GEOMETRY',
  3: 'LIMIT_EXCEEDED',
  4: 'COORDINATE_RANGE',
  5: 'INVALID_GEOMETRY',
  6: 'INVALID_OPTIONS',
  7: 'UNREPRESENTABLE',
};

/** What each code means, for the error message. */
const DESCRIPTION = {
  OUT_OF_MEMORY: 'the heap could not hold this call',
  UNSUPPORTED_GEOMETRY: 'unsupported geometry',
  LIMIT_EXCEEDED: 'limit exceeded',
  COORDINATE_RANGE: 'coordinate out of range',
  INVALID_GEOMETRY: 'malformed geometry, or the arrangement could not be resolved',
  INVALID_OPTIONS: 'invalid options',
  UNREPRESENTABLE: 'valid input, but the arrangement is not representable in f64',
};

/**
 * What an operation throws, carrying a `code` to branch on so nothing has to
 * match message text.
 *
 * The distinction that matters is `INVALID_GEOMETRY` against
 * `UNREPRESENTABLE`. The first means the input was bad — fix the geometry.
 * The second means the input was valid and the answer still could not be
 * built, because a crossing's exact intersection rounds onto or past a
 * segment endpoint; retrying is pointless, and the README's "When valid input
 * fails" section says what helps. `OUT_OF_MEMORY` is worth a branch too:
 * smaller (but not too small) batches usually fit.
 */
export class QdgeoError extends Error {
  /**
   * @param status {number} the module's nonzero status
   * @param [message] {string} overrides the code's description
   */
  constructor(status, message) {
    const code = STATUS[status] ?? `STATUS_${status}`;
    super(message ?? `${code}: ${DESCRIPTION[code] ?? 'unknown status'}`);
    this.name = 'QdgeoError';
    /** @type {Code} the reason, as a name a branch can read */
    this.code = /** @type {Code} */ (code);
  }
}

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
 * @typedef {Point[]} Line an open chain of points
 * @typedef {Point[]} Ring a closed list of points, first equal to last
 * @typedef {Ring[]} Shape a polygon: shell first, then holes
 * @typedef {Shape[] | Result} Collection a list of shapes, or a result
 * @typedef {(Point | Line | Shape | Result)[]} Mixed a list of geometries of
 *   any kind, each told apart by its nesting: `[x, y]` is a point,
 *   `[[x, y], …]` a line and `[[[x, y], …], …]` a polygon
 * @typedef {Collection | Mixed | { polygons?: Collection, lines?: Line[], points?: Point[] }} Operand
 *   a collection, a mixed list, or the longer form with each kind named
 * @typedef {{ distance?: number, steps?: number }} Options
 *   `distance` buffers the result — negative shrinks — and `steps` is how many
 *   segments make up a quarter circle at a rounded corner
 */

// A result is a collection of shapes, so it is accepted anywhere a collection
// is — which is what makes `buffer(union(shapes), 15)` work without the caller
// unpacking anything.
const isResult = (value) =>
  value != null && value.coordinates !== undefined && value.polygonEnds !== undefined;

// An operand may be a result, a list of geometries, or the full object with
// each kind named. A list of shapes is the common case and is passed through
// untouched; a list that holds anything else is sorted by nesting depth. A
// shape is a list of rings, or a flat one — coordinates plus ring ends,
// which is a result without the polygon ends.
const isShape = (item) =>
  item != null &&
  (item.ringEnds !== undefined ||
    (Array.isArray(item) && Array.isArray(item[0]) && Array.isArray(item[0][0])));

const asInput = (operand) => {
  if (operand == null) return {};
  if (isResult(operand)) return { polygons: operand };
  if (!Array.isArray(operand)) return operand;
  if (operand.every(isShape)) return { polygons: operand };
  const points = [];
  const lines = [];
  const polygons = [];
  for (const item of operand) {
    if (isShape(item)) polygons.push(item);
    else if (typeof item[0] === 'number') points.push(item);
    else lines.push(item);
  }
  return { points, lines, polygons };
};

// How many shapes an operand holds, which is the operand split the module wants.
const countShapes = ({ polygons }) => {
  if (polygons === undefined) return 0;
  return isResult(polygons) ? polygons.polygonEnds.length : polygons.length;
};

/** The DE-9IM matrix as nine characters, from the module's two bits per cell. */
const unpack = (bits) => {
  let out = '';
  for (let i = 0; i < 9; i++) out += 'F012'[(bits >> (2 * i)) & 3];
  return out;
};

/**
 * Copy `[x, y]` pairs into the block from coordinate `at`, returning where the
 * next one goes. Indexed rather than destructured: V8 runs an iterator per
 * pair for `for (const [x, y] of ...)`, and on a small call that was most of
 * the marshalling.
 */
const writeCoordinates = (xy, offset, at, pairs) => {
  let k = offset + 2 * at;
  for (let i = 0; i < pairs.length; i++) {
    const p = pairs[i];
    xy[k++] = p[0];
    xy[k++] = p[1];
  }
  return at + pairs.length;
};

// The named patterns are few and fixed, so each is encoded once.
const ENCODED = new Map();
const encoded = (text) => {
  let bits = ENCODED.get(text);
  if (bits === undefined) ENCODED.set(text, (bits = encode(text)));
  return bits;
};

// The module's three-bit code for each pattern character.
const CODES = { '*': 0, T: 1, F: 2, 0: 3, 1: 4, 2: 5, A: 6 };

/**
 * A pattern as the module takes it: three bits per cell, first cell lowest,
 * so `*********` is zero — which is also the request for the matrix itself.
 */
const encode = (pattern) => {
  if (typeof pattern !== 'string' || pattern.length !== 9)
    throw new QdgeoError(6, 'a relate pattern is nine characters of T, F, 0, 1, 2, A or *');
  let bits = 0;
  for (let i = 0; i < 9; i++) {
    const code = CODES[pattern[i].toUpperCase()];
    if (code === undefined)
      throw new QdgeoError(6, 'a relate pattern is nine characters of T, F, 0, 1, 2, A or *');
    bits |= code << (3 * i);
  }
  return bits;
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

/**
 * The instantiated module: one method per operation, plus the generic `apply`.
 * `load()` is the only way to construct one.
 */
export class Geometry {
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
    const { polygons } = this.#marshal(a, b);
    // The module wants the split rather than two blocks, so the count of
    // shapes in `a` is what separates the operands.
    const status = this.w.geom_apply(op, polygons, distance, steps);
    if (status) throw new QdgeoError(status);
    return this.#result();
  }

  /**
   * The DE-9IM matrix for `a` against `b`, as the nine characters JTS prints
   * — `'212101212'` for two overlapping polygons — or, given a `pattern`,
   * whether the matrix matches it. A pattern is nine of `T` (any
   * intersection), `F` (none), `0`, `1`, `2` (that dimension), `*`, or `A`
   * for a group of cells of which at least one must be non-empty.
   *
   * With a pattern the answer is lazy: the module walks the arrangement only
   * until the pattern is decided, so `relate(a, b, 'T*****FF*')` stops at the
   * first point of `b` outside `a`. Every named method below is one of these.
   *
   * Both operands are read as one geometry each: `[a, b, c]` is the union of
   * the three, so a point on an edge two of them share is inside the operand.
   *
   * @param a {Operand}
   * @param b {Operand}
   * @param [pattern] {string}
   * @returns {string | boolean}
   */
  relate(a, b, pattern) {
    if (pattern === undefined) return unpack(this.#test(0, a, b));
    const bits = encode(pattern);
    // Nine stars constrain nothing, and would ask for the matrix.
    return bits === 0 || this.#test(bits, a, b) === 1;
  }

  /**
   * Whether `a` and `b` share any point. The predicate with the earliest
   * exit: disjoint extents answer before a coordinate is read, and the first
   * contact between the operands answers before anything is located.
   *
   * @param a {Operand}
   * @param b {Operand}
   * @returns {boolean}
   */
  intersects(a, b) {
    return this.#named('intersects', a, b);
  }

  /** No point in common. @param a {Operand} @param b {Operand} @returns {boolean} */
  disjoint(a, b) {
    return !this.intersects(a, b);
  }

  /**
   * Every point of `b` is in `a`, and some point of `b` is in `a`'s interior.
   * A line along `a`'s boundary is covered but not contained.
   *
   * @param a {Operand}
   * @param b {Operand}
   * @returns {boolean}
   */
  contains(a, b) {
    return this.#named('contains', a, b);
  }

  /** `contains` with the operands swapped. @param a {Operand} @param b {Operand} @returns {boolean} */
  within(a, b) {
    return this.#named('within', a, b);
  }

  /** Every point of `b` is in `a`. @param a {Operand} @param b {Operand} @returns {boolean} */
  covers(a, b) {
    return this.#named('covers', a, b);
  }

  /** `covers` with the operands swapped. @param a {Operand} @param b {Operand} @returns {boolean} */
  coveredBy(a, b) {
    return this.#named('coveredBy', a, b);
  }

  /**
   * They meet only on their boundaries: no interior point in common.
   *
   * @param a {Operand}
   * @param b {Operand}
   * @returns {boolean}
   */
  touches(a, b) {
    return this.#named('touches', a, b);
  }

  /**
   * Their interiors meet in something of lower dimension than one of them,
   * and each has interior outside the other: a line across a polygon, two
   * lines crossing at a point.
   *
   * @param a {Operand}
   * @param b {Operand}
   * @returns {boolean}
   */
  crosses(a, b) {
    return this.#named('crosses', a, b);
  }

  /**
   * Same dimension, interiors meet in that dimension, and each has interior
   * outside the other.
   *
   * @param a {Operand}
   * @param b {Operand}
   * @returns {boolean}
   */
  overlaps(a, b) {
    return this.#named('overlaps', a, b);
  }

  /**
   * Topologically equal: the same set of points, whatever the vertices.
   *
   * @param a {Operand}
   * @param b {Operand}
   * @returns {boolean}
   */
  equals(a, b) {
    return this.#named('equals', a, b);
  }

  /** @type {ArrayBufferLike | null} */
  #memory = null;
  /** @type {Float64Array} */
  #f64 = new Float64Array(0);
  /** @type {Uint32Array} */
  #u32 = new Uint32Array(0);

  /** Views over the whole of linear memory, current as of this call. */
  #views() {
    const { buffer } = this.w.memory;
    if (buffer !== this.#memory) {
      this.#memory = buffer;
      this.#f64 = new Float64Array(buffer);
      this.#u32 = new Uint32Array(buffer);
    }
    return { f64: this.#f64, u32: this.#u32 };
  }

  /** A named predicate: its pattern for the operands' dimensions, lazily. */
  #named(name, a, b) {
    const operands = this.#marshal(a, b);
    const pattern = PATTERN[name];
    const text =
      typeof pattern === 'function' ? pattern(operands.dims[0], operands.dims[1]) : pattern;
    return text !== null && this.#relate(encoded(text), operands) === 1;
  }

  /** Marshal both operands and ask the module one pattern — or, with 0, the matrix. */
  #test(bits, a, b) {
    return this.#relate(bits, this.#marshal(a, b));
  }

  /** `geom_relate` over operands already in the block, failures thrown. */
  #relate(bits, { points, lines, polygons }) {
    const answer = this.w.geom_relate(bits, points, lines, polygons);
    if (answer < 0) throw new QdgeoError(-answer);
    return answer;
  }

  /**
   * Write both operands into the module's block, each kind in a fixed order
   * — `a`'s then `b`'s — and hand back how many of each `a` contributed,
   * which is the split the module wants, plus each operand's dimension for
   * the predicates that depend on it.
   */
  #marshal(a, b) {
    const { w } = this;
    const first = asInput(a);
    const second = asInput(b);
    const points = [first.points ?? [], second.points ?? []];
    const lines = [first.lines ?? [], second.lines ?? []];
    // Indexed by operand, so a missing one keeps its slot.
    const groups = [first.polygons, second.polygons];

    // Measure first, then write straight into the module's block.
    //
    // Building a plain Array of numbers and copying it in afterwards measured
    // 6x to 17x slower than this, because every coordinate goes through a boxed
    // push. Counting is cheap — lengths and ring counts, no coordinates — and
    // it buys a path where a flat operand is one `set()`, which is a memcpy.
    let total = points[0].length + points[1].length;
    let lineCount = 0;
    let shapes = 0;
    // Rings per operand: a shape with none is `POLYGON EMPTY`, which the
    // module drops, so it must not make its operand areal here either.
    const ringsOf = [0, 0];
    for (const list of lines) {
      lineCount += list.length;
      for (const line of list) total += line.length;
    }
    for (let i = 0; i < 2; i++) {
      const group = groups[i];
      if (group === undefined) continue;
      if (isResult(group)) {
        total += group.coordinates.length / 2;
        ringsOf[i] += group.ringEnds.length;
        shapes += group.polygonEnds.length;
        continue;
      }
      for (const shape of group) {
        if (Array.isArray(shape)) {
          for (const ring of shape) total += ring.length;
          ringsOf[i] += shape.length;
        } else {
          total += shape.coordinates.length / 2;
          ringsOf[i] += shape.ringEnds.length;
        }
        shapes += 1;
      }
    }
    const rings = ringsOf[0] + ringsOf[1];

    const ptr = w.geom_input(total, rings, shapes, lineCount, points[0].length + points[1].length);
    if (!ptr && total !== 0)
      throw new QdgeoError(1, 'the library could not allocate an input block');
    // One view of linear memory each, rebuilt only when memory grows, and
    // written at an offset. Two fresh views per call were most of the
    // marshalling cost of a small predicate.
    const { f64: xy, u32: index } = this.#views();
    const xo = ptr / 8;
    const io = (ptr + 16 * total) / 4;

    // Coordinates go in one fixed order: bare points, then line vertices, then
    // polygon ring vertices. Every index is an exclusive end, counted in
    // coordinates rather than numbers, so it never depends on the stride.
    let at = 0;
    let ring = 0;
    let shape = 0;
    let line = 0;
    const lineBase = rings + shapes;
    for (const list of points) {
      at = writeCoordinates(xy, xo, at, list);
    }
    for (const list of lines) {
      for (const path of list) {
        at = writeCoordinates(xy, xo, at, path);
        index[io + lineBase + line++] = at;
      }
    }
    // A flat operand is copied in one move and its index arrays are shifted.
    // Nothing reads a coordinate, which is what makes chaining cheap.
    const writeFlat = (coordinates, ringEnds) => {
      const base = at;
      xy.set(coordinates, xo + 2 * at);
      at += coordinates.length / 2;
      for (const end of ringEnds) index[io + ring++] = base + end;
    };
    for (const group of groups) {
      if (group === undefined) continue;
      if (isResult(group)) {
        const ringBase = ring;
        writeFlat(group.coordinates, group.ringEnds);
        for (const end of group.polygonEnds) index[io + rings + shape++] = ringBase + end;
        continue;
      }
      for (const item of group) {
        if (Array.isArray(item)) {
          for (const path of item) {
            at = writeCoordinates(xy, xo, at, path);
            index[io + ring++] = at;
          }
        } else {
          writeFlat(item.coordinates, item.ringEnds);
        }
        index[io + rings + shape++] = ring;
      }
    }
    // The module's rule, from the same counts: the highest dimension an
    // operand holds, -1 when it holds nothing.
    const dimension = (i) =>
      ringsOf[i] > 0 ? 2 : lines[i].length > 0 ? 1 : points[i].length > 0 ? 0 : -1;
    return {
      points: points[0].length,
      lines: lines[0].length,
      polygons: countShapes(first),
      dims: [dimension(0), dimension(1)],
    };
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
