// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
import { resolve } from 'node:path';
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// The demos import `qdgeo` by name, the way a consumer would after installing
// it, rather than by a relative path into a sibling directory. These aliases
// are the only thing standing in for a published package, and they mirror the
// `exports` map in the root `package.json`: the binding itself, and the
// optional host adapters under it.
//
// Two entries rather than one, because a bare `qdgeo` alias also captures
// `qdgeo/deck` and would rewrite it to `.../qdgeo.js/deck`.
const js = (name) => resolve(import.meta.dirname, `../js/${name}`);

export default defineConfig({
  plugins: [react()],
  base: './',
  resolve: {
    alias: [
      { find: /^qdgeo$/, replacement: js('qdgeo.js') },
      { find: /^qdgeo\/(.+)$/, replacement: js('$1.js') },
    ],
  },
  optimizeDeps: {
    exclude: ['maplibre-gl'],
  },
  server: {
    // The demos sit inside the library they consume, so `js/qdgeo.wasm` is a
    // directory above Vite's root and the dev server refuses to serve it —
    // `examples/package-lock.json` is what makes it pick this directory. A
    // consumer has none of this: for them qdgeo is under their own root, in
    // node_modules. This line is the cost of the demos living in the repo.
    fs: { allow: ['..'] },
  },
  build: {
    outDir: 'dist',
    rollupOptions: {
      input: {
        index: resolve(import.meta.dirname, 'index.html'),
        canvas: resolve(import.meta.dirname, 'canvas.html'),
        openlayers: resolve(import.meta.dirname, 'openlayers.html'),
        maplibre: resolve(import.meta.dirname, 'maplibre.html'),
        leaflet: resolve(import.meta.dirname, 'leaflet.html'),
        deckgl: resolve(import.meta.dirname, 'deckgl.html'),
      },
    },
  },
});
