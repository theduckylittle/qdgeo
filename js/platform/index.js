// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
// The default platform: a browser, a worker, anything without a filesystem.
//
// `node.js` beside this file is the other half. The root package.json's
// `imports` map picks between them at `#platform`, under the `node` condition,
// and this is what everything else resolves to. That indirection is the point:
// a bare `import('node:fs')` in the binding is a static specifier every browser
// bundler tries to resolve, and it ends up externalized with a warning in each
// consumer's build even though the branch can never run there.

/**
 * Read a `file:` URL, which there is no way to do here.
 *
 * @param url {URL}
 * @returns {Promise<Uint8Array>}
 */
export const readFileURL = async (url) => {
  throw new Error(`a file: URL needs a filesystem, and this runtime has none (${url})`);
};

/**
 * What a relative path is measured from. A page or worker answers this before
 * anything asks the platform, so reaching here means nothing can.
 *
 * @returns {Promise<string | URL>}
 */
export const base = async () => {
  throw new Error('no page, worker or process to resolve a relative path against');
};
