// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
// Signed area of a flat result, which is how every suite here checks an answer.
//
// Area is the one property that is cheap to compute, independent of the
// library's own code, and wrong for every wrong answer — a dropped hole, a
// reversed ring and a missing polygon all move it. It works on anything with
// `coordinates` and `ringEnds`, which covers a `Result`, the raw ABI's output,
// and a hand-written fixture.

/** @param flat {{ coordinates: ArrayLike<number>, ringEnds: ArrayLike<number> }} */
export function area({ coordinates, ringEnds }) {
  let total = 0;
  let start = 0;
  for (const end of ringEnds) {
    // The shoelace over one ring. Holes wind the other way, so they subtract.
    for (let i = start; i < end - 1; i++) {
      total +=
        (coordinates[2 * i] * coordinates[2 * i + 3] -
          coordinates[2 * i + 2] * coordinates[2 * i + 1]) /
        2;
    }
    start = end;
  }
  return total;
}

/** The same sum over the nested form, for a check that starts from arrays. */
export const nestedArea = (shapes) =>
  shapes.reduce(
    (total, shape) =>
      total +
      shape.reduce((sum, ring) => {
        let a = 0;
        for (let i = 0; i < ring.length - 1; i++) {
          a += ring[i][0] * ring[i + 1][1] - ring[i][1] * ring[i + 1][0];
        }
        return sum + a / 2;
      }, 0),
    0,
  );
