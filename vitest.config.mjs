// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    // Only `tests/`. `examples/` has its own install, and `tests/compare/` is
    // the measurement suite, which is not pass/fail and is run by hand.
    include: ['tests/**/*.test.mjs'],
    // One process per file. The ABI keeps module-level state — an input block,
    // a result block — and one case deliberately exhausts the 512 MiB WASM
    // heap, so a file cannot leave the module broken for another file.
    pool: 'forks',
    // The JTS suite is ~170 assertions in one file and the heap-exhaustion case
    // asks for half a gigabyte. Neither is slow, but neither fits the 5 s
    // default on a cold or loaded machine.
    testTimeout: 30_000,
  },
});
