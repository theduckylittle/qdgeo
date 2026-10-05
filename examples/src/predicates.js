// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
import { load, close, PATTERN } from 'qdgeo';
import { OPERANDS, rgba } from './style.js';

const canvas = document.getElementById('c');
const ctx = canvas.getContext('2d');
const table = document.getElementById('predicates');
const matrix = document.getElementById('matrix');
const matrixText = document.getElementById('matrix-text');
const kinds = [document.getElementById('kind-a'), document.getElementById('kind-b')];

// Positions snap to this grid, and every vertex below is a whole number, so
// two edges that look aligned really are, and the exact predicates agree.
const GRID = 10;

// One geometry of each kind per operand, around its own origin. The second
// polygon is smaller than the first so one can sit inside the other, and the
// second line starts with a straight run so it can lie along an edge.
const square = (half) => [
  close([
    [-half, -half],
    [half, -half],
    [half, half],
    [-half, half],
  ]),
];
const GEOMETRY = [
  {
    polygon: square(120),
    line: [
      [-80, -100],
      [-20, 60],
      [100, 40],
    ],
  },
  {
    polygon: square(80),
    line: [
      [-120, 0],
      [0, 0],
      [60, -80],
      [140, -80],
    ],
  },
];
const DIMENSION = { polygon: 2, line: 1, point: 0 };

// Each arrangement is the two kinds and where each one's origin sits.
const SCENES = {
  overlap: ['polygon', [380, 260], 'polygon', [500, 200]],
  edge: ['polygon', [380, 260], 'polygon', [580, 260]],
  inside: ['polygon', [380, 260], 'polygon', [400, 280]],
  apart: ['polygon', [300, 260], 'polygon', [660, 260]],
  across: ['polygon', [380, 260], 'line', [510, 260]],
  along: ['polygon', [380, 260], 'line', [380, 140]],
  boundary: ['polygon', [380, 260], 'point', [500, 300]],
  lines: ['line', [380, 260], 'line', [420, 260]],
};

// The order the table lists them: the general ones first, then the ones that
// depend on the operands' dimensions.
const NAMES = [
  'intersects',
  'disjoint',
  'contains',
  'within',
  'covers',
  'coveredBy',
  'equals',
  'touches',
  'crosses',
  'overlaps',
];

let geo,
  // Where each origin is, unsnapped, so a slow drag still moves.
  origins = [],
  dragging = -1,
  last = [0, 0];

const snap = (v) => Math.round(v / GRID) * GRID;
const kind = (i) => kinds[i].value;

/** Operand `i` in canvas coordinates, as the plain nested arrays it is drawn from. */
function placed(i) {
  const [ox, oy] = origins[i].map(snap);
  const move = ([x, y]) => [x + ox, y + oy];
  switch (kind(i)) {
    case 'polygon':
      return GEOMETRY[i].polygon.map((ring) => ring.map(move));
    case 'line':
      return GEOMETRY[i].line.map(move);
    case 'point':
      return [ox, oy];
  }
}

/**
 * The same geometry as a qdgeo operand. The longer form names each kind, so
 * nothing depends on telling a line from a polygon by how deep it nests.
 */
function operand(i) {
  const geometry = placed(i);
  switch (kind(i)) {
    case 'polygon':
      return { polygons: [geometry] };
    case 'line':
      return { lines: [geometry] };
    case 'point':
      return { points: [geometry] };
  }
}

// A canvas path for operand `i`, which both drawing and hit testing use.
function path(i) {
  const geometry = placed(i);
  ctx.beginPath();
  switch (kind(i)) {
    case 'polygon':
      for (const ring of geometry) {
        ring.forEach(([x, y], j) => (j ? ctx.lineTo(x, y) : ctx.moveTo(x, y)));
        ctx.closePath();
      }
      break;
    case 'line':
      geometry.forEach(([x, y], j) => (j ? ctx.lineTo(x, y) : ctx.moveTo(x, y)));
      break;
    case 'point':
      ctx.arc(geometry[0], geometry[1], 7, 0, 2 * Math.PI);
      break;
  }
}

function paint(i) {
  const { color, opacity } = OPERANDS[i];
  path(i);
  if (kind(i) === 'line') {
    ctx.strokeStyle = color;
    ctx.lineWidth = 4;
    ctx.lineJoin = 'round';
    ctx.stroke();
    return;
  }
  ctx.fillStyle = kind(i) === 'point' ? color : rgba(color, opacity * 2);
  ctx.fill('evenodd');
  ctx.strokeStyle = color;
  ctx.lineWidth = 2;
  ctx.stroke();
}

function drawGrid() {
  ctx.fillStyle = rgba(OPERANDS[0].color, 0.18);
  for (let x = GRID * 4; x < canvas.width; x += GRID * 4)
    for (let y = GRID * 4; y < canvas.height; y += GRID * 4) ctx.fillRect(x - 1, y - 1, 2, 2);
}

// The pattern a named predicate is asked as, for these two kinds. Three of
// them depend on the dimensions, and for some pairs are false outright.
function patternFor(name) {
  const pattern = PATTERN[name];
  return typeof pattern === 'function' ? pattern(DIMENSION[kind(0)], DIMENSION[kind(1)]) : pattern;
}

function report() {
  const a = operand(0),
    b = operand(1);
  let rows, de9im;
  try {
    // Each named method is one lazy pattern test; `relate` with no pattern
    // computes the whole matrix.
    rows = NAMES.map((name) => [name, patternFor(name), geo[name](a, b)]);
    de9im = geo.relate(a, b);
  } catch (error) {
    table.innerHTML = `<tr><td class="err">${error.message}</td></tr>`;
    matrix.innerHTML = '';
    matrixText.textContent = '';
    return;
  }

  table.innerHTML =
    '<tr><th>Predicate</th><th>Pattern</th><th>a, b</th></tr>' +
    rows
      .map(
        ([name, pattern, answer]) =>
          `<tr class="${answer ? 'yes' : 'no'}"><td><code>${name}</code></td>` +
          `<td><code>${pattern ?? 'false for these dimensions'}</code></td>` +
          `<td>${answer}</td></tr>`,
      )
      .join('');

  // Rows are a's interior, boundary and exterior; columns are b's. A cell is
  // the dimension of where those two meet: F for nothing at all.
  const parts = ['Interior', 'Boundary', 'Exterior'];
  matrix.innerHTML =
    '<tr><th></th>' +
    parts.map((p) => `<th>${p} of b</th>`).join('') +
    '</tr>' +
    parts
      .map(
        (p, row) =>
          `<tr><th>${p} of a</th>` +
          [0, 1, 2]
            .map((col) => {
              const cell = de9im[row * 3 + col];
              return `<td class="${cell === 'F' ? 'no' : 'yes'}">${cell}</td>`;
            })
            .join('') +
          '</tr>',
      )
      .join('');
  matrixText.innerHTML = `<code>relate(a, b)</code> is <code>'${de9im}'</code>.`;
}

function draw() {
  ctx.clearRect(0, 0, canvas.width, canvas.height);
  drawGrid();
  paint(0);
  paint(1);
  report();
}

function scene(name) {
  const [kindA, originA, kindB, originB] = SCENES[name];
  kinds[0].value = kindA;
  kinds[1].value = kindB;
  origins = [originA.slice(), originB.slice()];
  draw();
}

// Dragging: pick whichever geometry is under the pointer, the second first
// since it is drawn on top. Lines and points get a generous margin.
const at = (event) => {
  const box = canvas.getBoundingClientRect();
  return [
    (event.clientX - box.left) * (canvas.width / box.width),
    (event.clientY - box.top) * (canvas.height / box.height),
  ];
};
const hit = (i, [x, y]) => {
  path(i);
  if (kind(i) === 'polygon') return ctx.isPointInPath(x, y, 'evenodd');
  ctx.lineWidth = 16;
  return ctx.isPointInStroke(x, y) || ctx.isPointInPath(x, y);
};
canvas.addEventListener('pointerdown', (event) => {
  const p = at(event);
  for (const i of [1, 0]) {
    if (hit(i, p)) {
      dragging = i;
      last = p;
      canvas.setPointerCapture(event.pointerId);
      return;
    }
  }
});
canvas.addEventListener('pointermove', (event) => {
  if (dragging < 0) return;
  const p = at(event);
  origins[dragging][0] += p[0] - last[0];
  origins[dragging][1] += p[1] - last[1];
  last = p;
  draw();
});
const stop = () => {
  if (dragging >= 0) origins[dragging] = origins[dragging].map(snap);
  dragging = -1;
};
canvas.addEventListener('pointerup', stop);
canvas.addEventListener('pointercancel', stop);

document.getElementById('scene').addEventListener('change', (event) => scene(event.target.value));
for (const select of kinds) select.addEventListener('change', draw);

geo = await load();
scene('overlap');
