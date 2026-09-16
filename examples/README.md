# Examples

Published from `main` at
**[theduckylittle.github.io/qdgeo](https://theduckylittle.github.io/qdgeo/)** by
`.github/workflows/pages.yml`, which rebuilds the WASM module first so the live
site is never running a stale one.

Three standalone pages, each one file plus the shared helper. They all do the
same four boolean operations and the same buffer, so the interesting part is how
each host hands geometry over.

| Page | Host | What it shows |
| --- | --- | --- |
| `canvas.html` | none | The smallest possible integration: two shapes, `<canvas>`, no dependencies at all |
| `openlayers.html` | OpenLayers 10 | Reading `flatCoordinates` and `getEnds()` straight across, with **no format conversion** |
| `maplibre.html` | MapLibre GL JS 4 | Converting to GeoJSON on the way out, which is what MapLibre wants |

## Running them

The pages fetch the WASM module, so they need a server — opening the file
directly with `file://` will not work.

```sh
zig build wasm                       # writes zig-out/bin/qdgeo.wasm
cp zig-out/bin/qdgeo.wasm examples/vendor/
cp js/qdgeo.js examples/lib/          # the binding lives in js/, not here
python3 -m http.server -d examples 8000
```

Then open <http://localhost:8000/canvas.html>.

`examples/vendor/qdgeo.wasm` is a copy so the pages work as a self-contained
directory. Re-copy it after rebuilding.

OpenLayers and MapLibre load from a CDN, and the two map pages draw basemap
tiles, so those two want a network connection. The geometry never does:
`canvas.html` works entirely offline, and on the map pages the shapes still
compute and draw if the tiles fail.

## Shared files

`lib/examples.css` holds the chrome every page uses: the colour tokens for both
themes, the page frame, and the control and readout styles. A page adds only
what is specific to it — the canvas demo styles its canvas and legend, the
landing page styles its cards, and the two map demos add no CSS at all.

## The binding

The binding is `js/qdgeo.js`, copied into `lib/` by the command above so the
example doc root can reach it. It wraps the ABI in about two hundred lines; the
ABI is seven functions and a host can call them directly.

```js
import { load } from './lib/qdgeo.js';

const geo = await load('./vendor/qdgeo.wasm');

// A shape is a list of rings. Ring 0 is the shell, the rest are holes, and
// every ring must be closed.
const a = [[[0, 0], [10, 0], [10, 10], [0, 10], [0, 0]]];
const b = [[[5, 5], [15, 5], [15, 15], [5, 15], [5, 5]]];

geo.union([a, b]);
geo.intersection([a], [b]);
geo.difference([a], [b]);
geo.symmetricDifference([a], [b]);
geo.buffer([a], 2);
```

`union` and `buffer` are n-ary over one list. The other three take two operand
lists, either of which may hold several shapes. A buffer `distance` may be
negative, which shrinks, and `{ steps }` is how many segments make up a quarter
circle at a rounded corner. `distance` works on the boolean operations too —
`geo.union([a, b], { distance: 5 })` grows the union without a second call.

Points and open lines can be buffered as well, which is the one case that needs
the longer input form:

```js
geo.buffer({ points: [[7, -3]] }, 10); // a disc
geo.buffer({ lines: [[[0, 0], [100, 0]]] }, 10); // a stadium
```

`apply(op, a, b, options)` is the generic form the named methods are built on,
with `OP` and `STATUS` exported alongside it for a host that needs the codes.

## Coordinates are planar

The library reads no coordinate system and does no projection. A `distance` is
in whatever units the coordinates are in, so buffering in metres means
projecting first. `maplibre.html` shows the usual shape of that: convert to Web
Mercator, do the geometry, convert back for display.
