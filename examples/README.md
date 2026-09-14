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

## The shared helper

`lib/geometry.js` wraps the flat ABI in about a hundred lines. It exists to keep
the examples readable — the ABI is eight functions and a host can call them
directly.

```js
import { load, OP } from './lib/geometry.js';

const geo = await load('./vendor/qdgeo.wasm');

// Ring 0 is the shell, the rest are holes, and every ring must be closed.
const square = [[0, 0], [10, 0], [10, 10], [0, 10], [0, 0]];
const other  = [[5, 5], [15, 5], [15, 15], [5, 15], [5, 5]];

geo.run({ polygons: [[square], [other]] }, OP.union, { subject: 1 });
geo.run({ polygons: [[square]] }, OP.buffer, { distance: 2, steps: 16 });
```

`subject` is how many leading polygons form the first operand of a boolean
operation; everything after them is the second. `distance` may be negative,
which shrinks. `steps` is how many segments make up a quarter circle at a
rounded corner.

Points and open lines can be buffered too:

```js
geo.run({ points: [[7, -3]] }, OP.buffer, { distance: 10 });          // a disc
geo.run({ lines: [[[0, 0], [100, 0]]] }, OP.buffer, { distance: 10 }); // a stadium
```

## Coordinates are planar

The library reads no coordinate system and does no projection. A `distance` is
in whatever units the coordinates are in, so buffering in metres means
projecting first. `maplibre.html` shows the usual shape of that: convert to Web
Mercator, do the geometry, convert back for display.
