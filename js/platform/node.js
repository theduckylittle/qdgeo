// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
// The Node platform, chosen by the `node` condition on `#platform`. See
// `index.js` beside this file for why the two are split.

/**
 * Read a `file:` URL. Node's `fetch` rejects that scheme outright — "not
 * implemented... yet..." — so this is how a module is loaded off a disk.
 *
 * @param url {URL}
 * @returns {Promise<Uint8Array>}
 */
export const readFileURL = async (url) => {
  const { readFile } = await import('node:fs/promises');
  return readFile(url);
};

/**
 * What a relative path is measured from: the process, the way every other path
 * handed to a script is.
 *
 * @returns {Promise<URL>}
 */
export const base = async () => {
  const { pathToFileURL } = await import('node:url');
  return pathToFileURL(`${process.cwd()}/`);
};
