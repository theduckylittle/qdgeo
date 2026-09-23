// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
import React, { useMemo, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { COORDINATE_SYSTEM } from '@deck.gl/core';
import { PathLayer, SolidPolygonLayer } from '@deck.gl/layers';
import { DeckGL } from '@deck.gl/react';
import { Map } from '@vis.gl/react-maplibre';
import { load } from 'qdgeo';
import { toBinary, toOutline } from 'qdgeo/deck';
import { regular, star } from './shapes.js';
import { OPERANDS, RESULT, osmStyle, rgb } from './style.js';

const geo = await load();

const ORIGIN = [4.895168, 52.370216]; // Amsterdam
const MAP_STYLE = osmStyle();
const INITIAL_VIEW_STATE = { longitude: ORIGIN[0], latitude: ORIGIN[1], zoom: 12 };

// The geometry is metres from `ORIGIN`, which is what `METER_OFFSETS` reads, so
// deck.gl does the placing and nothing here reads a coordinate. A buffer
// distance is then metres on the ground, the units the slider already claims.
const PROJ = {
  coordinateSystem: COORDINATE_SYSTEM.METER_OFFSETS,
  coordinateOrigin: ORIGIN,
};

// Two operands, either side of the origin.
const shapeA = star(-700, 0, 1500, 620);
const shapeB = regular(900, 200, 1200, 6);
const OPERAND_SHAPES = [shapeA, shapeB];

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
        <span className="value">{distance} m</span>
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
  const polygons = shape.length;
  const rings = shape.ringEnds.length;
  const points = shape.coordinates.length / 2;
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
    // Each operand keeps its own colour, so one accessor covers both.
    const shown = op === 'buffer' ? [OPERAND_SHAPES[0]] : OPERAND_SHAPES;
    const rings = shown.flatMap((outline, i) => outline.map((ring) => ({ ring, i })));
    // A new id per geometry, so deck.gl builds a layer rather than updating
    // one. Its tesselator's buffers are allocated at the high-water mark and
    // never shrink, so a layer kept across a change carries every vertex of
    // the widest shape it has held.
    const key = `${op}-${distance}`;
    const drawn = shape && shape.length;
    return [
      new SolidPolygonLayer({
        id: 'operand-fill',
        ...PROJ,
        data: shown.map((outline, i) => ({ outline, i })),
        getPolygon: (d) => d.outline,
        getFillColor: (d) => rgb(OPERANDS[d.i].color, OPERANDS[d.i].opacity),
        stroked: false,
      }),
      new PathLayer({
        id: 'operand-line',
        ...PROJ,
        data: rings,
        getPath: (d) => d.ring,
        getColor: (d) => rgb(OPERANDS[d.i].color),
        getWidth: OPERANDS[0].width,
        widthUnits: 'pixels',
      }),
      drawn &&
        new SolidPolygonLayer({
          id: `result-fill-${key}`,
          ...PROJ,
          // `_normalize: false` is what lets deck.gl skip its own reformatting,
          // which is the point of handing it binary.
          data: toBinary(shape),
          _normalize: false,
          getFillColor: rgb(RESULT.color, RESULT.opacity),
          filled: true,
          stroked: false,
        }),
      // `SolidPolygonLayer` only fills, so the outline every other demo draws
      // is a second layer over the same positions.
      drawn &&
        new PathLayer({
          id: `result-line-${key}`,
          ...PROJ,
          data: toOutline(shape),
          // `_pathType` is the `PathLayer` counterpart of `_normalize`: it
          // tells the layer the rings need no reformatting. They arrive
          // closed, so 'open' draws every segment including the last.
          _pathType: 'open',
          getColor: rgb(RESULT.color),
          getWidth: RESULT.width,
          widthUnits: 'pixels',
        }),
    ].filter(Boolean);
  }, [op, distance, shape]);

  return (
    <div className="panel">
      <div className="map">
        <DeckGL
          initialViewState={INITIAL_VIEW_STATE}
          controller={true}
          layers={layers}
          // DeckGL sizes itself 100% of its parent, which is what `.map` is
          // for. `style` is passed rather than `className`: DeckGL forwards
          // `style`, `width`, `height` and `id` only, and drops the rest. The
          // default position is `absolute`, which would take it out of flow.
          style={{ position: 'relative' }}
        >
          <Map reuseMaps mapStyle={MAP_STYLE} />
        </DeckGL>
      </div>
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
