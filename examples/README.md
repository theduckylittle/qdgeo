# Examples

Published from `main` at
**[theduckylittle.github.io/qdgeo](https://theduckylittle.github.io/qdgeo/)** by
`.github/workflows/pages.yml`, which rebuilds the WASM module first so the live
site is never running a stale one.

Five pages, built with Vite and importing their dependencies from npm, so they
look like code someone would actually write. They all do the same four boolean
operations and the same buffer, in the same colours and over the same basemap;
the interesting part is what each host wants geometry to look like, and how much
work that costs.

| Page | Host | What it shows |
| --- | --- | --- |
| `canvas.html` | none | The smallest integration: two shapes, `<canvas>`, no dependencies, no basemap |
| `openlayers.html` | OpenLayers 10 | `flatCoordinates` and `getEnds()` straight across, **both directions**, no coordinate touched |
| `deckgl.html` | deck.gl 9 | The result as **binary**, straight into `SolidPolygonLayer` |
| `maplibre.html` | MapLibre GL JS 6 | GeoJSON, one of the hosts that genuinely needs the nested form |
| `leaflet.html` | Leaflet 1.9 | Rings the other way round: **open**, and `[lat, lng]` |

That spread is the point. qdgeo returns one coordinate array plus ring and
polygon ends. OpenLayers keeps exactly that layout and deck.gl is two index
loops from it, so neither demo reads a coordinate. The other three draw ring by
ring and want coordinates in pairs, which is what `toArrays()` is for.

Each demo is **one file**, and where a host needs a conversion the demo imports
it rather than carrying a copy:

```js
import { toBinary, toOutline } from 'qdgeo/deck';
import { fromLeaflet, openRings, toLeaflet } from 'qdgeo/leaflet';
```

Those are the two conversions with invariants a browser will not complain about
— a wrong deck.gl attribute name renders nothing, and Leaflet's rings must not
repeat their first point — so they ship with the library and are covered by
`tests/deck-binary.mjs` and `tests/leaflet.mjs`, against deck.gl's own
tesselator and a full Leaflet round trip. The demos run exactly the code those
tests check. OpenLayers and MapLibre need no adapter, so those two pages do
their conversion inline, in a handful of lines each.

## Running them

The pages fetch the WASM module, so they need a server — opening the file
directly with `file://` will not work.

```sh
zig build wasm              # also writes js/qdgeo.wasm, beside the binding
npm --prefix examples install
npm --prefix examples run dev
```

Vite prints a URL. From the repository root, `npm run examples` is the same
thing. The demos import the binding as `qdgeo`, the way a consumer would after
installing it; `vite.config.js` aliases that name into `../js/` and is the only
thing standing in for a published package.

No page copies the module into place. Every demo calls `load()` with no
argument, the binding resolves `new URL('./qdgeo.wasm', import.meta.url)`, and
Vite follows that to emit one hashed asset — which is exactly what a consumer
gets, and the reason the demos need no configuration for it.

The four map pages draw OpenStreetMap tiles, so they want a network connection.
The geometry never does: `canvas.html` works entirely offline, and on the map
pages the shapes still compute and draw if the tiles fail.

## Shared files

Every piece of JavaScript is in `src/`, and `lib/` holds the one stylesheet.

`lib/examples.css` carries all of it: colour tokens for both themes, the page
frame, the map box, the controls and readout, the canvas demo's legend, and the
landing page's cards. No page has a `<style>` block or an inline style, with one
exception noted in `src/deckgl.jsx` — `DeckGL` forwards `style` and drops
`className`, so its one positioning rule has to be inline.

`src/style.js` reads those colour tokens back out and hands them to the hosts in
whatever form each wants — CSS strings for the map libraries, `[r, g, b]` for
deck.gl — along with the shared OpenStreetMap basemap. It is why the five pages
look like one project and follow the light and dark themes together.

`src/shapes.js` generates the two operands.

## The binding

The binding is `js/qdgeo.js`, which the pages import as `qdgeo` through the
alias in `vite.config.js`. It wraps the ABI in about two hundred lines; the ABI
is seven functions and a host can call them directly.

```js
import { load } from 'qdgeo';

const geo = await load();

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
lists, either of which may hold several shapes. A result is itself a collection
of shapes, so operations chain:

```js
geo.buffer(geo.union(shapes), { distance: 15 });
```

A buffer `distance` may be negative, which shrinks, and `{ steps }` is how many
segments make up a quarter circle at a rounded corner. `distance` works on the boolean operations too —
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
projecting first, and each demo shows a different way to arrange that:
`maplibre.html` converts to Web Mercator and back by hand, `openlayers.html` and
`leaflet.html` use the projection their host already carries, and `deckgl.html`
keeps the geometry in metre offsets and lets `COORDINATE_SYSTEM.METER_OFFSETS`
place it.
