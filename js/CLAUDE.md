# js/CLAUDE.md

The JavaScript side of the package: the binding, the host adapters, and what
gets generated from them. The root `CLAUDE.md` covers the project;
`src/CLAUDE.md` covers the ABI these files call.

## The binding is the library, not an example

**`js/qdgeo.js` is part of the published package.** Its named methods —
`union`, `intersection`, `difference`, `symmetricDifference`, `buffer`, and
the predicates `intersects`, `disjoint`, `contains`, `within`, `covers`,
`coveredBy`, `touches`, `crosses`, `overlaps`, `equals` and `relate` — are
what a caller should reach for; `apply` is the generic escape hatch. The binary
methods take two operand lists and compute the module's operand split
themselves, so the split never reaches a caller. One marshaller, `#marshal`,
writes both operands' points, lines and polygons in the block's fixed order and
hands back the first operand's three counts; `apply` uses the polygon count and
`geom_relate` all three.

An operand list may mix kinds, told apart by nesting depth — `[x, y]` a point,
`[[x, y], …]` a line, `[[[x, y], …], …]` or a flat `{ coordinates, ringEnds }`
a polygon. A list of shapes is passed through untouched, so `union([...])` is
the same call it always was; only a list holding something else is sorted by
kind.

The named predicates are DE-9IM patterns, in `PATTERN`, with JTS's definitions
and one extension (`A`: one of the marked cells is non-empty). The pattern is
what crosses the ABI — `encode` packs it three bits a cell — and the module
evaluates it lazily, so a named method is one `geom_relate` call, not a matrix
plus a match in JavaScript. `src/relate.zig` holds the same table as
`Predicate.pattern`; keep the two identical. `OP` and `STATUS` are exported
from here, not redefined per example. `Geometry` (what `load()` resolves to)
and `Result` are exported so TypeScript consumers and the API reference can
name them; `load()` stays the only way to construct a `Geometry`.

Failures throw `QdgeoError`, which carries a **named** `code` —
`'INVALID_GEOMETRY'`, `'UNREPRESENTABLE'`, `'OUT_OF_MEMORY'`, … — never a bare
number, so a branch reads at the call site and a typo fails the type check
(`Code` is a union type in the generated declarations). `STATUS` maps the
ABI's numeric statuses to those names for hosts driving the raw exports. The
codes — and especially `INVALID_GEOMETRY` ("your input is bad") against
`UNREPRESENTABLE` ("valid input, but the arrangement is not representable in
f64", ABI status 7 against 5) — are a compatibility promise shared with the
ABI; `src/CLAUDE.md` has the list, and a native test pins the mapping.

A result is an operand: `Result` carries `coordinates`, `ringEnds` and
`polygonEnds`, and feeding one back appends one array and shifts two index
arrays — no coordinate is read on the way in or out. Keep chaining that cheap.

Input marshalling counts first, then writes straight into the module's block.
Building a plain Array of numbers and copying it in afterwards measured 6x to
17x slower; do not reintroduce it.

`load()` takes a URL or path, a `Response` (or a promise of one), raw bytes, or
a compiled `WebAssembly.Module`, and defaults to the `qdgeo.wasm` beside the
binding via `import.meta.url`. The `#platform` import map (`js/platform/`)
exists because Node's `fetch` rejects `file:` URLs; the browser build never
loads it.

## Adapters load nothing

`js/deck.js` and `js/leaflet.js` are separate entry points that load no WASM
and import neither deck.gl nor Leaflet — projections are passed in. Each exists
because its host's conversion fails *silently* when wrong (deck.gl ignores a
misnamed attribute; Leaflet wants open rings where qdgeo's are closed), and
each is tested against the real host library in `tests/deck.test.mjs` and
`tests/leaflet.test.mjs`. Nothing else gets an adapter: OpenLayers already
speaks the flat layout, and MapLibre needs only `toArrays()`.

## Generated from the JSDoc — keep the comments true

Two build products come straight from the doc comments in these files, and CI
regenerates both, so a comment that disagrees with the code is a build failure,
not a footnote:

- **`types/*.d.ts`** — `npm run types` (tsc over the JSDoc, config in
  `tsconfig.json`). Declarations only; the library stays plain JavaScript.
- **`docs/api/`** — `npm run docs` (TypeDoc over the same entry points, config
  in `typedoc.json`). Published to GitHub Pages at `/api/` beside the examples
  by `pages.yml`.

Everything the package exports must carry JSDoc good enough to stand in the
API reference — types on the public surface, prose that says what a thing is
for. Private helpers need neither.

## The package (`package.json`)

ESM only, `sideEffects: false`. Four entry points — `qdgeo`, `qdgeo/deck`,
`qdgeo/leaflet` and `qdgeo/qdgeo.wasm` — plus `./package.json`. The `files`
list is `js/`, `types/`, README and LICENSE; CI's "Package manifest" step
asserts every `exports` and `imports` target is in the tarball, so a new entry
point is not done until that step knows about its file. `prepack` rebuilds the
WASM and the types, so a publish never ships a stale artifact.

JavaScript and HTML are Prettier-formatted (`npm run format`); `js/qdgeo.wasm`
is build output and gitignored, not source.
