// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
import 'ol/ol.css';
import Collection from 'ol/Collection.js';
import Feature from 'ol/Feature.js';
import Map from 'ol/Map.js';
import View from 'ol/View.js';
import MultiPolygon from 'ol/geom/MultiPolygon.js';
import Polygon from 'ol/geom/Polygon.js';
import Translate from 'ol/interaction/Translate.js';
import TileLayer from 'ol/layer/Tile.js';
import VectorLayer from 'ol/layer/Vector.js';
import { fromLonLat } from 'ol/proj.js';
import OSM from 'ol/source/OSM.js';
import VectorSource from 'ol/source/Vector.js';
import Fill from 'ol/style/Fill.js';
import Stroke from 'ol/style/Stroke.js';
import Style from 'ol/style/Style.js';
import { load } from 'qdgeo';
import { regular, star } from '../lib/shapes.js';

const geo = await load('./qdgeo.wasm');
const out = document.getElementById('out');

// This is the whole reason the library speaks flat coordinates.
//
// OpenLayers keeps `flatCoordinates` and `ends` on every Polygon, which is the
// same layout qdgeo takes and returns. `ends` counts *numbers*, so dividing by
// the stride turns them into the coordinate counts the ABI wants — and that is
// the entire conversion. No coordinate is read, copied or boxed into a pair.
const fromOpenLayers = (polygon) => {
  const stride = polygon.getStride();
  return {
    coordinates: polygon.getFlatCoordinates(),
    ringEnds: polygon.getEnds().map((end) => end / stride),
  };
};

// And back. OpenLayers' MultiPolygon constructor takes flat coordinates with
// per-polygon ring ends, counted in numbers, so the result's index arrays are
// scaled rather than walked.
function toOpenLayers(result) {
  const endss = [];
  let ring = 0;
  for (let p = 0; p < result.length; p++) {
    const ends = [];
    for (; ring < result.polygonEnds[p]; ring++) ends.push(result.ringEnds[ring] * 2);
    endss.push(ends);
  }
  return new MultiPolygon(Array.from(result.coordinates), 'XY', endss);
}

// Two operands, in EPSG:3857 metres, over a stretch of Amsterdam.
const centre = fromLonLat([4.895168, 52.370216]);
const shapeA = new Feature(new Polygon(star(centre[0] - 700, centre[1], 1500, 620)));
const shapeB = new Feature(new Polygon(regular(centre[0] + 900, centre[1] + 200, 1200, 6)));

const style = (colour, width) =>
  new Style({
    fill: new Fill({ color: colour + '22' }),
    stroke: new Stroke({ color: colour, width }),
  });
const operands = new VectorSource({ features: [shapeA, shapeB] });
const results = new VectorSource();

const map = new Map({
  target: 'map',
  layers: [
    new TileLayer({ source: new OSM(), opacity: 0.55 }),
    new VectorLayer({ source: operands, style: style('#3b6ea5', 1.5) }),
    new VectorLayer({ source: results, style: style('#2f6f4f', 3) }),
  ],
  view: new View({ center: centre, zoom: 12 }),
});
map.addInteraction(new Translate({ features: new Collection([shapeA, shapeB]) }));

const op = () => document.querySelector('input[name=op]:checked').value;

function update() {
  const distance = Number(document.getElementById('distance').value);
  const buffering = op() === 'buffer';
  const a = fromOpenLayers(shapeA.getGeometry());
  const b = fromOpenLayers(shapeB.getGeometry());
  results.clear();
  try {
    let result;
    switch (op()) {
      case 'buffer':
        result = geo.buffer([a], distance);
        break;
      case 'union':
        result = geo.union([a, b], { distance });
        break;
      case 'intersection':
        result = geo.intersection([a], [b], { distance });
        break;
      case 'difference':
        result = geo.difference([a], [b], { distance });
        break;
      case 'symmetricDifference':
        result = geo.symmetricDifference([a], [b], { distance });
        break;
    }
    if (result.length) results.addFeature(new Feature(toOpenLayers(result)));
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
    out.innerHTML = `<span class="err">${error.message}</span>`;
  }
}

shapeA.getGeometry().on('change', update);
shapeB.getGeometry().on('change', update);
document.getElementById('distance').addEventListener('input', (event) => {
  document.getElementById('distance-value').textContent = `${event.target.value} m`;
  update();
});
for (const radio of document.querySelectorAll('input[name=op]')) {
  radio.addEventListener('change', update);
}
update();
