// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
import L from 'leaflet';
import 'leaflet/dist/leaflet.css';
import { load } from 'qdgeo';
import { fromLeaflet, openRings, toLeaflet } from 'qdgeo/leaflet';
import { regular, star } from './shapes.js';
import { OPERANDS, OSM, RESULT } from './style.js';

const geo = await load();
const out = document.getElementById('out');

// Leaflet already carries the projection this needs, so the geometry runs in
// Web Mercator metres without the page writing any projection maths.
const CRS = L.CRS.EPSG3857;
const project = (latLng) => {
  const { x, y } = CRS.project(latLng);
  return [x, y];
};
const unproject = ([x, y]) => CRS.unproject(L.point(x, y));

// Leaflet's rings are open where qdgeo's are closed, and `[lat, lng]` where
// qdgeo is `[x, y]`. `qdgeo/leaflet` is that conversion, in both directions; it
// imports Leaflet no more than it imports the WASM, so the projection above is
// what it is given.

const centre = project(L.latLng(52.370216, 4.895168)); // Amsterdam
const map = L.map('map', { center: unproject(centre), zoom: 12 });
L.tileLayer(OSM.url, {
  maxZoom: OSM.maxZoom,
  opacity: OSM.opacity,
  attribution: OSM.attribution,
}).addTo(map);

// The shared palette, under the names Leaflet gives those two.
const style = ({ color, width, opacity }) => ({ color, weight: width, fillOpacity: opacity });

// Two operands, in metres either side of the centre. They live in the map
// layers, and `fromLeaflet` reads them back out for each operation.
const shapeA = L.polygon(
  openRings(star(centre[0] - 700, centre[1], 1500, 620), unproject),
  style(OPERANDS[0]),
).addTo(map);
const shapeB = L.polygon(
  openRings(regular(centre[0] + 900, centre[1] + 200, 1200, 6), unproject),
  style(OPERANDS[1]),
).addTo(map);
const results = L.polygon([], style(RESULT)).addTo(map);

const op = () => document.querySelector('input[name=op]:checked').value;

function update() {
  const distance = Number(document.getElementById('distance').value);
  const buffering = op() === 'buffer';
  const a = fromLeaflet(shapeA.getLatLngs(), project);
  const b = fromLeaflet(shapeB.getLatLngs(), project);
  shapeB.setStyle({ opacity: buffering ? 0 : 1, fillOpacity: buffering ? 0 : OPERANDS[1].opacity });
  try {
    let result;
    switch (op()) {
      case 'buffer':
        result = geo.buffer(a, distance);
        break;
      case 'union':
        result = geo.union([...a, ...b], { distance });
        break;
      case 'intersection':
        result = geo.intersection(a, b, { distance });
        break;
      case 'difference':
        result = geo.difference(a, b, { distance });
        break;
      case 'symmetricDifference':
        result = geo.symmetricDifference(a, b, { distance });
        break;
    }
    results.setLatLngs(toLeaflet(result, unproject));
    const rings = result.ringEnds.length;
    const points = result.coordinates.length / 2;
    out.innerHTML =
      `<b>${result.length}</b> polygon${result.length === 1 ? '' : 's'}, ` +
      `<b>${rings}</b> ring${rings === 1 ? '' : 's'}, <b>${points}</b> coordinates.` +
      (distance === 0
        ? ''
        : buffering
          ? ` Distance <b>${distance} m</b>${distance < 0 ? ' (shrinking)' : ''}.`
          : ` Then ${distance < 0 ? 'shrunk' : 'grown'} by <b>${Math.abs(distance)} m</b>.`);
  } catch (error) {
    results.setLatLngs([]);
    out.innerHTML = `<span class="err">${error.message}</span>`;
  }
}

document.getElementById('distance').addEventListener('input', (event) => {
  document.getElementById('distance-value').textContent = `${event.target.value} m`;
  update();
});
for (const radio of document.querySelectorAll('input[name=op]')) {
  radio.addEventListener('change', update);
}
update();
