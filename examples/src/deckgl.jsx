// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
import React, { useMemo, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { DeckGL } from '@deck.gl/react';
import { PathLayer, SolidPolygonLayer } from '@deck.gl/layers';
import { Map } from '@vis.gl/react-maplibre';
import { MercatorCoordinate } from 'maplibre-gl';
import { load } from 'qdgeo';
import { regular, star } from '../lib/shapes.js';
import { toBinary } from './deck-binary.js';

const geo = await load('./qdgeo.wasm');

// Geometry runs in EPSG:3857 metres, the same as the OpenLayers demo, so a
// buffer distance is a distance and not a number of degrees. Web Mercator
// metres are inflated by 1/cos(latitude) — about 1.6x at Amsterdam — so they are
// metres in the sense that matters here and not in the surveying sense.
const EQUATOR = 2 * Math.PI * 6378137;
const toMercator = (lngLat) => {
  const { x, y } = MercatorCoordinate.fromLngLat(lngLat);
  return [(x - 0.5) * EQUATOR, (0.5 - y) * EQUATOR];
};
const toLngLat = ([x, y]) =>
  new MercatorCoordinate(x / EQUATOR + 0.5, 0.5 - y / EQUATOR).toLngLat().toArray();

const ORIGIN = [4.895168, 52.370216]; // Amsterdam, as in the OpenLayers demo
const CENTRE = toMercator(ORIGIN);
const MAP_STYLE = 'https://basemaps.cartocdn.com/gl/dark-matter-gl-style/style.json';
const INITIAL_VIEW_STATE = { longitude: ORIGIN[0], latitude: ORIGIN[1], zoom: 12 };

// Two operands, in metres either side of the centre.
const shapeA = star(CENTRE[0] - 700, CENTRE[1], 1500, 620);
const shapeB = regular(CENTRE[0] + 900, CENTRE[1] + 200, 1200, 6);

/**
 * Project a result for the basemap, into a new array.
 *
 * Never over the result's own: projecting in place works once and destroys the
 * coordinates on any second pass, and nothing here guarantees it runs once.
 */
function projected(result) {
  const source = result.coordinates;
  const coordinates = new Float64Array(source.length);
  for (let i = 0; i < source.length; i += 2) {
    const [lng, lat] = toLngLat([source[i], source[i + 1]]);
    coordinates[i] = lng;
    coordinates[i + 1] = lat;
  }
  return { coordinates, ringEnds: result.ringEnds, polygonEnds: result.polygonEnds };
}
const projectShape = (shape) => shape.map((ring) => ring.map(toLngLat));

/** The boolean operation. `buffer` has none of its own, so it takes shape A. */
function combine(op) {
  switch (op) {
    case 'buffer':
      return geo.union([shapeA]);
    case 'union':
      return geo.union([shapeA, shapeB]);
    case 'intersection':
      return geo.intersection([shapeA], [shapeB]);
    case 'difference':
      return geo.difference([shapeA], [shapeB]);
    case 'symmetricDifference':
      return geo.symmetricDifference([shapeA], [shapeB]);
    default:
      throw new Error(`unknown operation ${op}`);
  }
}

/**
 * Combine, then buffer what came out. A result is an operand, so the second
 * step takes the first's output directly and the geometry keeps the library's
 * own layout in between.
 *
 * `cache` holds the combined shape so dragging the slider does not redo it.
 */
function pipeline(op, distance, cache) {
  try {
    if (cache.op !== op) cache = { op, result: combine(op) };
    const shape = distance === 0 ? cache.result : geo.buffer(cache.result, distance);
    return [{ op, distance, shape, error: null }, cache];
  } catch (failure) {
    return [{ op, distance, shape: null, error: failure.message }, cache];
  }
}

const OPERATIONS = [
  ['union', 'Union'],
  ['intersection', 'Intersection'],
  ['difference', 'Difference'],
  ['symmetricDifference', 'Symmetric difference'],
  ['buffer', 'Buffer'],
];

function Controls({ op, distance, onChange }) {
  return (
    <div className="panel controls">
      <fieldset>
        <legend>Operation</legend>
        {OPERATIONS.map(([value, label]) => (
          <label className="op" key={value}>
            <input
              type="radio"
              name="op"
              value={value}
              checked={op === value}
              onChange={() => onChange(value, distance)}
            />{' '}
            {label}
          </label>
        ))}
      </fieldset>
      <fieldset>
        <legend>Buffer</legend>
        <input
          type="range"
          min={-400}
          max={900}
          step={10}
          value={distance}
          onChange={(event) => onChange(op, Number(event.target.value))}
        />
        <span style={{ minWidth: '6ch' }}>{distance} m</span>
      </fieldset>
    </div>
  );
}

function Summary({ op, distance, shape, error }) {
  if (error) {
    return (
      <div className="panel out">
        <span className="err">{error}</span>
      </div>
    );
  }
  const polygons = shape ? shape.length : 0;
  const rings = shape ? shape.ringEnds.length : 0;
  const points = shape ? shape.coordinates.length / 2 : 0;
  return (
    <div className="panel out">
      <b>{polygons}</b> polygon{polygons === 1 ? '' : 's'}, <b>{rings}</b> ring
      {rings === 1 ? '' : 's'}, <b>{points}</b> coordinates.
      {distance !== 0 &&
        (op === 'buffer' ? (
          <>
            {' '}
            Distance <b>{distance} m</b>
            {distance < 0 ? ' (shrinking)' : ''}.
          </>
        ) : (
          <>
            {' '}
            Then {distance < 0 ? 'shrunk' : 'grown'} by <b>{Math.abs(distance)} m</b>.
          </>
        ))}
    </div>
  );
}

function Result({ op, distance, shape }) {
  const layers = useMemo(() => {
    const operands = (op === 'buffer' ? [shapeA] : [shapeA, shapeB]).flatMap((outline) =>
      projectShape(outline).map((ring) => ({ path: ring })),
    );
    return [
      new PathLayer({
        id: 'operands',
        data: operands,
        getPath: (d) => d.path,
        getColor: [140, 170, 210],
        getWidth: 1.5,
        widthUnits: 'pixels',
      }),
      shape &&
        shape.length &&
        new SolidPolygonLayer({
          // A new id per geometry, so deck.gl builds a layer rather than
          // updating one. Its tesselator's buffers are allocated at the
          // high-water mark and never shrink, so a layer kept across a change
          // carries every vertex of the widest shape it has held.
          id: `result-${op}-${distance}`,
          // `_normalize: false` is what lets deck.gl skip its own reformatting,
          // which is the point of handing it binary.
          data: toBinary(projected(shape)),
          _normalize: false,
          getFillColor: [86, 160, 255, 140],
          filled: true,
          stroked: false,
        }),
    ].filter(Boolean);
  }, [op, distance, shape]);

  return (
    <div className="panel">
      <DeckGL
        initialViewState={INITIAL_VIEW_STATE}
        controller={true}
        layers={layers}
        // DeckGL forwards `style`, `width`, `height` and `id` only — a
        // `className` here is dropped and the map collapses to nothing.
        style={{ position: 'relative', height: 520, borderRadius: 10, overflow: 'hidden' }}
      >
        <Map reuseMaps mapStyle={MAP_STYLE} />
      </DeckGL>
    </div>
  );
}

function App() {
  // The combined shape, kept so dragging the slider does not redo stage one.
  const cache = useRef({ op: null, result: null });
  const [state, setState] = useState(() => {
    const [first, filled] = pipeline('union', 300, cache.current);
    cache.current = filled;
    return first;
  });

  // The work happens here, in the change handler. Not in an effect, which runs
  // after the commit and would leave a drag painting the previous shape every
  // frame; not in render, because the library is one module with one result
  // block and a render React discards would still have moved it along.
  const change = (op, distance) => {
    if (op === state.op && distance === state.distance) return;
    const [next, filled] = pipeline(op, distance, cache.current);
    cache.current = filled;
    setState(next);
  };

  return (
    <>
      <Controls op={state.op} distance={state.distance} onChange={change} />
      <Result op={state.op} distance={state.distance} shape={state.shape} />
      <Summary {...state} />
    </>
  );
}

createRoot(document.getElementById('root')).render(<App />);
