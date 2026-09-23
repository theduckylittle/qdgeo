// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
import { load, close } from 'qdgeo';
import { regular, star } from './shapes.js';
import { OPERANDS, RESULT, rgba } from './style.js';

const canvas = document.getElementById('c');
const ctx = canvas.getContext('2d');
const out = document.getElementById('out');

// Two operands. Each is a list of rings; ring 0 is the shell, the rest holes.
const sets = {
  star: () => [
    star(330, 260, 150, 62),
    [
      close([
        [430, 170],
        [720, 170],
        [720, 360],
        [430, 360],
      ]),
    ],
  ],
  hex: () => [regular(360, 260, 150, 6), regular(560, 260, 150, 6, Math.PI / 6)],
  donut: () => [
    [regular(400, 260, 165, 40)[0], regular(400, 260, 85, 40)[0].slice().reverse()],
    [
      close([
        [300, 225],
        [760, 225],
        [760, 295],
        [300, 295],
      ]),
    ],
  ],
};

let geo,
  shapes = sets.star(),
  offsets = [
    [0, 0],
    [0, 0],
  ],
  dragging = -1,
  last = [0, 0];

const shifted = (i) =>
  shapes[i].map((ring) => ring.map(([x, y]) => [x + offsets[i][0], y + offsets[i][1]]));
const op = () => document.querySelector('input[name=op]:checked').value;

function ringPath(ring) {
  ctx.beginPath();
  ring.forEach(([x, y], i) => (i ? ctx.lineTo(x, y) : ctx.moveTo(x, y)));
  ctx.closePath();
}

// One path per polygon, so holes are cut by the even-odd fill rule.
function polygonPath(polygon) {
  ctx.beginPath();
  for (const ring of polygon) {
    ring.forEach(([x, y], i) => (i ? ctx.lineTo(x, y) : ctx.moveTo(x, y)));
    ctx.closePath();
  }
}

function draw() {
  const a = shifted(0),
    b = shifted(1);
  const buffering = op() === 'buffer';
  const distance = Number(document.getElementById('distance').value);
  ctx.clearRect(0, 0, canvas.width, canvas.height);

  let result = null,
    note = '';
  try {
    // Each operation has its own method; the switch is the whole of what the
    // op selector means.
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
  } catch (error) {
    note = `<span class="err">${error.message}</span>`;
  }

  const paint = (polygon, { color, width, opacity }) => {
    polygonPath(polygon);
    ctx.fillStyle = rgba(color, opacity);
    ctx.fill('evenodd');
    ctx.strokeStyle = color;
    ctx.lineWidth = width;
    ctx.stroke();
  };
  paint(a, OPERANDS[0]);
  if (!buffering) paint(b, OPERANDS[1]);
  // The operands are already nested, and `toArrays()` puts the result in the
  // same form — one polygon at a time, shell first — so both go through the
  // same painter.
  if (result) for (const polygon of result.toArrays()) paint(polygon, RESULT);

  out.innerHTML =
    note ||
    `<b>${result.length}</b> polygon${result.length === 1 ? '' : 's'}, ` +
      `<b>${result.ringEnds.length}</b> ring${result.ringEnds.length === 1 ? '' : 's'}, ` +
      `<b>${result.coordinates.length / 2}</b> coordinates.` +
      (distance === 0
        ? ''
        : buffering
          ? ` Distance <b>${distance}</b>${distance < 0 ? ' (shrinking)' : ''}.`
          : ` Then ${distance < 0 ? 'shrunk' : 'grown'} by <b>${Math.abs(distance)}</b>.`);
}

// Dragging: pick whichever shell contains the pointer, topmost first.
const at = (event) => {
  const box = canvas.getBoundingClientRect();
  return [
    (event.clientX - box.left) * (canvas.width / box.width),
    (event.clientY - box.top) * (canvas.height / box.height),
  ];
};
canvas.addEventListener('pointerdown', (event) => {
  const p = at(event);
  for (let i = shapes.length - 1; i >= 0; i--) {
    ringPath(shifted(i)[0]);
    if (ctx.isPointInPath(p[0], p[1])) {
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
  offsets[dragging][0] += p[0] - last[0];
  offsets[dragging][1] += p[1] - last[1];
  last = p;
  draw();
});
const stop = () => {
  dragging = -1;
};
canvas.addEventListener('pointerup', stop);
canvas.addEventListener('pointercancel', stop);

document.getElementById('shapes').addEventListener('change', (event) => {
  shapes = sets[event.target.value]();
  offsets = [
    [0, 0],
    [0, 0],
  ];
  draw();
});
document.getElementById('distance').addEventListener('input', (event) => {
  document.getElementById('distance-value').textContent = event.target.value;
  draw();
});
for (const radio of document.querySelectorAll('input[name=op]')) {
  radio.addEventListener('change', () => {
    draw();
  });
}

geo = await load();
draw();
