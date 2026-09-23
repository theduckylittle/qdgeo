// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
// One palette and one basemap, shared by every demo.
//
// The colours are defined once in `examples.css` as `--a`, `--b` and
// `--accent`, so they follow the light and dark themes and there is a single
// place to change them. This module reads them at load and hands them out in
// whichever form a host wants: CSS strings for the map libraries, `[r, g, b]`
// for deck.gl. Nothing here belongs to the library.

const token = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();

/** `#rrggbb` as `[r, g, b]`, or `[r, g, b, a]` when an opacity is given. */
export function rgb(hex, opacity) {
  const n = parseInt(hex.slice(1), 16);
  const channels = [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  return opacity === undefined ? channels : [...channels, Math.round(opacity * 255)];
}

/** The same colour as a CSS string, for hosts that take one. */
export const rgba = (hex, opacity) => `rgba(${rgb(hex).join(', ')}, ${opacity})`;

/** The two operands, in the order the demos build them. */
export const OPERANDS = [
  { color: token('--a'), width: 1.5, opacity: 0.13 },
  { color: token('--b'), width: 1.5, opacity: 0.13 },
];

/** The result, drawn over them. */
export const RESULT = { color: token('--accent'), width: 3, opacity: 0.28 };

/** OpenStreetMap raster tiles, at the opacity every map demo draws them. */
export const OSM = {
  url: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
  attribution: '&copy; OpenStreetMap contributors',
  opacity: 0.55,
  maxZoom: 19,
};

/**
 * The same basemap as a MapLibre style, which deck.gl's map wants too.
 *
 * Inline rather than a URL, so the map loads with no style server: the shapes
 * draw even when the tiles do not.
 */
export const osmStyle = () => ({
  version: 8,
  sources: {
    osm: {
      type: 'raster',
      tiles: [OSM.url],
      tileSize: 256,
      attribution: OSM.attribution,
    },
  },
  layers: [
    // The paper the tiles sit on, so a failed tile is still a map-coloured gap.
    { id: 'background', type: 'background', paint: { 'background-color': '#e8e4dc' } },
    { id: 'osm', type: 'raster', source: 'osm', paint: { 'raster-opacity': OSM.opacity } },
  ],
});
