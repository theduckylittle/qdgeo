// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
// Geometry generators for the demos. Nothing here belongs to the library — it
// exists so the examples have something interesting to operate on.
import { close } from 'qdgeo';

/** A regular polygon, as a shape: one ring, closed. */
export function regular(cx, cy, radius, sides, rotation = 0) {
  const ring = [];
  for (let i = 0; i < sides; i++) {
    const angle = rotation + (2 * Math.PI * i) / sides;
    ring.push([cx + radius * Math.cos(angle), cy + radius * Math.sin(angle)]);
  }
  return [close(ring)];
}

/** A star, which gives the boolean operations something concave to chew on. */
export function star(cx, cy, outer, inner, points = 5, rotation = -Math.PI / 2) {
  const ring = [];
  for (let i = 0; i < points * 2; i++) {
    const r = i % 2 ? inner : outer;
    const angle = rotation + (Math.PI * i) / points;
    ring.push([cx + r * Math.cos(angle), cy + r * Math.sin(angle)]);
  }
  return [close(ring)];
}
