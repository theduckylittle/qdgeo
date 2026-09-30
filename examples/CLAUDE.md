# examples/CLAUDE.md

Context for the demo pages. `README.md` in this directory explains what each
page shows and how to run them; this file is the rules that keep them honest.

- **The demos are consumers, not copies.** They import the binding as `qdgeo`
  (aliased into `../js/` by `vite.config.js`, the only stand-in for a published
  package) and the adapters as `qdgeo/deck` and `qdgeo/leaflet`. Never copy
  binding or adapter code into a page — the point is that the pages run exactly
  the code the tests cover.
- **One file per demo**, JavaScript in `src/`, all styling in
  `lib/examples.css`. No `<style>` blocks and no inline styles, with the one
  documented exception in `src/deckgl.jsx` (`DeckGL` forwards `style` and drops
  `className`).
- **`src/style.js` is the shared look.** Colour tokens, both themes, and the
  OpenStreetMap basemap live there once; a new page reads them rather than
  picking its own colours.
- **No page copies `qdgeo.wasm` into place.** Every demo calls `load()` with no
  argument; Vite follows the binding's own `new URL(...)` and emits the module
  as a hashed asset. If a page needs the module somewhere else, that is a
  binding question, not a build-step question.
- **The site ships from CI.** `pages.yml` builds this directory into the
  GitHub Pages site (with the API reference at `/api/`), and `ci.yml` builds it
  on every push and checks each page exists. A new page needs: an entry in
  `vite.config.js`, a card on `index.html`, and its name in both workflows'
  page lists.
- The landing page's `api/` links resolve only on the published site — the Vite
  dev server does not serve the TypeDoc output. `npm run docs` writes it to
  `docs/api/` for a local look.
- Prettier formats the JavaScript and HTML here like everything else; the
  `examples/package-lock.json` is separate from the root one on purpose, so the
  demos' dependencies stay out of the library's tree.
