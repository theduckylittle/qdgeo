// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
import { Deck, OrthographicView } from '@deck.gl/core';
import { SolidPolygonLayer, PathLayer } from '@deck.gl/layers';
import { load } from 'qdgeo';
import { regular, star } from '../lib/shapes.js';
import { toBinary } from './deck-binary.js';

const geo = await load('./qdgeo.wasm');

const shapes = {
  star: () => [star(-90, 0, 130, 54), regular(90, 0, 110, 6)],
  gears: () => [regular(-70, 0, 120, 12), regular(70, 0, 120, 12)],
  blocks: () => [regular(-60, 0, 110, 4, 0.4), regular(60, 20, 110, 4, -0.2)],
};

const el = (id) => document.getElementById(id);
const op = () => el('op').value;
const preset = () => el('preset').value;
const distance = () => Number(el('distance').value);

const deck = new Deck({
  parent: el('map'),
  views: new OrthographicView(),
  initialViewState: { target: [0, 0, 0], zoom: 1 },
  controller: true,
  layers: [],
});

function draw() {
  const [a, b] = shapes[preset()]();
  const d = distance();
  el('distance-out').textContent = `${d} units`;

  let result;
  let note = '';
  try {
    switch (op()) {
      case 'buffer':
        result = geo.buffer([a], d);
        break;
      case 'union':
        result = geo.union([a, b], { distance: d });
        break;
      case 'intersection':
        result = geo.intersection([a], [b], { distance: d });
        break;
      case 'difference':
        result = geo.difference([a], [b], { distance: d });
        break;
      case 'symmetricDifference':
        result = geo.symmetricDifference([a], [b], { distance: d });
        break;
    }
  } catch (error) {
    note = `<span class="err">${error.message}</span>`;
  }

  const outlines = (op() === 'buffer' ? [a] : [a, b]).flatMap((shape) =>
    shape.map((ring) => ({ path: ring })),
  );

  deck.setProps({
    layers: [
      new PathLayer({
        id: 'inputs',
        data: outlines,
        getPath: (d) => d.path,
        getColor: [120, 130, 150],
        getWidth: 1.5,
        widthUnits: 'pixels',
      }),
      result &&
        result.length &&
        new SolidPolygonLayer({
          id: 'result',
          // The result goes across as binary, with no per-coordinate work on
          // this side. `_normalize: false` is what lets it skip deck.gl's own
          // reformatting, which is the whole point of handing it binary.
          data: toBinary(result),
          _normalize: false,
          getFillColor: [86, 160, 255, 140],
          getLineColor: [86, 160, 255],
          filled: true,
          stroked: false,
        }),
    ].filter(Boolean),
  });

  const rings = result ? result.ringEnds.length : 0;
  const points = result ? result.coordinates.length / 2 : 0;
  el('out').innerHTML =
    note ||
    `<b>${result.length}</b> polygon${result.length === 1 ? '' : 's'}, ` +
      `<b>${rings}</b> ring${rings === 1 ? '' : 's'}, <b>${points}</b> coordinates — ` +
      `handed to deck.gl as binary, no coordinate touched in JavaScript.`;
}

for (const id of ['op', 'preset', 'distance']) el(id).addEventListener('input', draw);
draw();
