# Bundle sizes

What a browser downloads to do buffer and boolean geometry with each library.

```sh
npm run sizes
```

JavaScript libraries are bundled with esbuild, minified, and gzipped, importing
only the entry points `tests/compare/js.mjs` actually uses. WASM libraries are
measured as the artifact the page fetches. Raw bytes are reported alongside
gzipped, because a WASM module is parsed from its raw form while minified
JavaScript is not.

Sizes are not like-for-like on features, so the table prints what each bundle
contains. polyclip-ts has no buffer, which is most of why it is the smallest.
Rust Geo's artifact includes qdgeo's own flat ABI shim, which is a few hundred
bytes.

GEOS is absent because it has no official browser build. The community
`geos-wasm` package is 2.58 MB raw / 778 KB gzipped and carries the whole of
GEOS, so it is quoted in the README rather than measured here.
