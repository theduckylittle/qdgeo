// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
// A parcel-like fabric of any size, with its answers known in advance.
//
// The stress test needs input it can grow past anything a dataset holds, and
// an oracle that is still exact when the input is millions of coordinates.
// This is an n-by-n grid of cells that share every interior edge vertex for
// vertex, the way parcels do, with the nodes and the edge vertices jittered so
// nothing is axis-aligned or evenly spaced. The outside stays a straight
// square, which is what makes the answers closed-form:
//
// - the union of the cells is the square, so its area is `width²`;
// - a positive buffer is the square grown by `d` with four rounded corners,
//   and an arc of `steps` segments per quarter has an exact fan area;
// - a negative buffer is the square shrunk by `|d|`;
// - the overlap with a shifted copy is a rectangle.
//
// Every vertex comes from a hash of its grid position and the seed, so the
// fabric is the same on every run and every machine, both cells of a shared
// edge compute bit-identical coordinates without storing the edge, and the
// generator streams straight into the flat layout the binding copies in with
// one memcpy. A million cells is fine.
import { Result } from '../../js/qdgeo.js';

/**
 * A pseudo-random number in [0, 1) from four integers. Deterministic, which
 * is the point: a shared edge is generated twice and must come out identical.
 */
function hash(seed, kind, i, j, m) {
  let h = (seed ^ 0x9e3779b9) >>> 0;
  h = Math.imul(h ^ kind, 0x85ebca6b);
  h ^= h >>> 13;
  h = Math.imul(h ^ i, 0xc2b2ae35);
  h ^= h >>> 16;
  h = Math.imul(h ^ j, 0x85ebca6b);
  h ^= h >>> 13;
  h = Math.imul(h ^ m, 0xc2b2ae35);
  h ^= h >>> 16;
  return (h >>> 0) / 4294967296;
}

/**
 * Build the fabric.
 *
 * @param options {{ n: number, size?: number, pieces?: number, jitter?: number,
 *   origin?: [number, number], seed?: number }}
 *   `n` cells per side; `size` the nominal cell side; `pieces` the most
 *   segments one shared edge is cut into; `jitter` how far, as a fraction of
 *   `size`, a vertex may stray; `origin` the lower-left corner, for running
 *   at projected magnitudes; `seed` picks the fabric.
 * @returns {{ polygons: Result, width: number, cells: number, origin: [number, number] }}
 */
export function fabric({ n, size = 30, pieces = 6, jitter = 0.15, origin = [0, 0], seed = 1 }) {
  // Segments a grid edge is cut into: `kind` 3 for horizontal, 4 for vertical.
  const cuts = (kind, i, j) => 1 + Math.floor(hash(seed, kind, i, j, 0) * pieces);

  // Node (i, j). Boundary nodes keep the coordinate that puts them on the
  // square's side, so the outline stays straight.
  const node = (i, j, out) => {
    const dx = i > 0 && i < n ? (hash(seed, 1, i, j, 0) * 2 - 1) * jitter : 0;
    const dy = j > 0 && j < n ? (hash(seed, 2, i, j, 0) * 2 - 1) * jitter : 0;
    out[0] = (i + dx) * size;
    out[1] = (j + dy) * size;
  };

  // The vertices of one grid edge, start node included, end node excluded.
  // Interior vertices sit on the chord between the nodes and move off it by
  // an amount that tapers to nothing at either end, so a cell can never fold
  // over itself no matter how its corners were jittered. An edge on the
  // square's boundary stays on the chord, which is the boundary.
  const a = [0, 0];
  const b = [0, 0];
  const edge = (kind, i, j, out) => {
    const horizontal = kind === 3;
    node(i, j, a);
    node(horizontal ? i + 1 : i, horizontal ? j : j + 1, b);
    const boundary = horizontal ? j === 0 || j === n : i === 0 || i === n;
    const k = cuts(kind, i, j);
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const len = Math.hypot(dx, dy);
    out.length = 0;
    out.push(a[0], a[1]);
    for (let m = 1; m < k; m++) {
      const t = m / k;
      const away = boundary
        ? 0
        : (hash(seed, 5, i, j, m) * 2 - 1) * jitter * size * 2 * Math.min(t, 1 - t);
      out.push(a[0] + t * dx - (away * dy) / len, a[1] + t * dy + (away * dx) / len);
    }
    return k;
  };

  // Count first, so the arrays are allocated once at their final size.
  let total = 0;
  for (let j = 0; j < n; j++) {
    for (let i = 0; i < n; i++) {
      total += cuts(3, i, j) + cuts(4, i + 1, j) + cuts(3, i, j + 1) + cuts(4, i, j) + 1;
    }
  }
  const coordinates = new Float64Array(2 * total);
  const ringEnds = new Uint32Array(n * n);
  const polygonEnds = new Uint32Array(n * n);

  const scratch = [];
  let at = 0;
  let cell = 0;
  const forward = () => {
    for (let p = 0; p < scratch.length; p += 2) {
      coordinates[2 * at] = scratch[p] + origin[0];
      coordinates[2 * at + 1] = scratch[p + 1] + origin[1];
      at++;
    }
  };
  // The edge was generated from its own start node; walked the other way
  // round the cell, its vertices come out in reverse and its end node is the
  // one the ring needs, which is the next edge's start.
  const backward = () => {
    for (let p = scratch.length - 2; p >= 2; p -= 2) {
      coordinates[2 * at] = scratch[p] + origin[0];
      coordinates[2 * at + 1] = scratch[p + 1] + origin[1];
      at++;
    }
  };
  for (let j = 0; j < n; j++) {
    for (let i = 0; i < n; i++) {
      const start = at;
      // Counter-clockwise: along the bottom, up the right side, back along
      // the top, down the left side.
      edge(3, i, j, scratch);
      forward();
      edge(4, i + 1, j, scratch);
      forward();
      edge(3, i, j + 1, scratch);
      node(i + 1, j + 1, a);
      coordinates[2 * at] = a[0] + origin[0];
      coordinates[2 * at + 1] = a[1] + origin[1];
      at++;
      backward();
      edge(4, i, j, scratch);
      node(i, j + 1, a);
      coordinates[2 * at] = a[0] + origin[0];
      coordinates[2 * at + 1] = a[1] + origin[1];
      at++;
      backward();
      coordinates[2 * at] = coordinates[2 * start];
      coordinates[2 * at + 1] = coordinates[2 * start + 1];
      at++;
      ringEnds[cell] = at;
      polygonEnds[cell] = cell + 1;
      cell++;
    }
  }
  if (at !== total) throw new Error(`fabric counted ${total} coordinates and wrote ${at}`);
  return {
    polygons: new Result(coordinates, ringEnds, polygonEnds),
    width: n * size,
    cells: n * n,
    origin,
  };
}

/** The same fabric moved by `[dx, dy]`, for an operand that crosses the first. */
export function translate(result, [dx, dy]) {
  const coordinates = new Float64Array(result.coordinates.length);
  for (let p = 0; p < coordinates.length; p += 2) {
    coordinates[p] = result.coordinates[p] + dx;
    coordinates[p + 1] = result.coordinates[p + 1] + dy;
  }
  return new Result(coordinates, result.ringEnds, result.polygonEnds);
}

/** Area of the square the cells tile. */
export const squareArea = ({ width }) => width * width;

/**
 * Area of the square buffered by `distance`. Grown, it gains a band along
 * each side and a fan of `steps` triangles at each corner, whose vertices sit
 * on the circle of radius `distance`. Shrunk, the corners stay sharp.
 */
export function bufferedArea({ width }, distance, steps) {
  if (distance < 0) {
    const side = width + 2 * distance;
    return side > 0 ? side * side : 0;
  }
  const fans = 2 * steps * distance * distance * Math.sin(Math.PI / (2 * steps));
  return width * width + 4 * width * distance + fans;
}

/** Area shared by the square and a copy of it moved by `[dx, dy]`. */
export const overlapArea = ({ width }, [dx, dy]) =>
  Math.max(0, width - Math.abs(dx)) * Math.max(0, width - Math.abs(dy));

/**
 * Signed area of a result, summed about `origin` rather than about zero, so
 * the check stays exact at projected magnitudes where the plain shoelace
 * loses digits to cancellation.
 */
export function areaAbout({ coordinates, ringEnds }, [ox, oy]) {
  let total = 0;
  let start = 0;
  for (const end of ringEnds) {
    let sum = 0;
    for (let i = start; i < end - 1; i++) {
      const x0 = coordinates[2 * i] - ox;
      const y0 = coordinates[2 * i + 1] - oy;
      const x1 = coordinates[2 * i + 2] - ox;
      const y1 = coordinates[2 * i + 3] - oy;
      sum += x0 * y1 - x1 * y0;
    }
    total += sum / 2;
    start = end;
  }
  return total;
}
