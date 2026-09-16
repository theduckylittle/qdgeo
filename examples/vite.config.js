// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
import { resolve } from 'node:path';
import { defineConfig } from 'vite';

// The demos import `qdgeo` by name, the way a consumer would after installing
// it, rather than by a relative path into a sibling directory. The alias is the
// only thing standing in for a published package.
export default defineConfig({
  base: './',
  resolve: {
    alias: { qdgeo: resolve(import.meta.dirname, '../js/qdgeo.js') },
  },
  build: {
    outDir: 'dist',
    rollupOptions: {
      input: {
        index: resolve(import.meta.dirname, 'index.html'),
        canvas: resolve(import.meta.dirname, 'canvas.html'),
        openlayers: resolve(import.meta.dirname, 'openlayers.html'),
        maplibre: resolve(import.meta.dirname, 'maplibre.html'),
        deckgl: resolve(import.meta.dirname, 'deckgl.html'),
      },
    },
  },
});
