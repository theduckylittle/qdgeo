// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
// The JTS test-case XML, read into plain objects.
//
// JTS's format is four element names deep — `<run><case><desc/><a/><b/>
// <test><op/></test></case></run>` — and the committed files contain no
// entities, no CDATA and no namespaces (`cases/NOTICE.md` records that they
// are copied verbatim and never edited). That is small enough to read here,
// and reading it here is what keeps the suite down to Node plus Zig: the
// alternative was a Python process for an XML parser.
import { readdirSync, readFileSync } from 'node:fs';

const CASES = new URL('./cases/', import.meta.url);

const collapse = (text) => text.trim().split(/\s+/).join(' ');

/** Every `<case>` in one file, with its operands and its `<test><op>` rows. */
export function parseCases(xml) {
  const cases = [];
  for (const [, body] of xml.matchAll(/<case>([\s\S]*?)<\/case>/g)) {
    const element = (tag) => {
      const found = body.match(new RegExp(`<${tag}>([\\s\\S]*?)</${tag}>`));
      return found ? found[1].trim() : undefined;
    };
    const tests = [];
    for (const [, rawAttributes, expected] of body.matchAll(/<op\s+([^>]*?)>([\s\S]*?)<\/op>/g)) {
      const attributes = {};
      for (const [, key, value] of rawAttributes.matchAll(
        /([a-zA-Z0-9_]+)\s*=\s*['"]([^'"]*)['"]/g,
      ))
        attributes[key] = value;
      tests.push({ attributes, expected: expected.trim() });
    }
    cases.push({ desc: collapse(element('desc') ?? ''), a: element('a'), b: element('b'), tests });
  }
  return cases;
}

/**
 * Every case file under `cases/` whose name `keep` accepts, in a stable
 * order. The overlay and buffer files and the predicate files are run by
 * different suites, since one compares geometry and the other booleans.
 */
export const caseFiles = (keep = () => true) =>
  readdirSync(CASES)
    .filter((name) => name.endsWith('.xml') && keep(name))
    .sort()
    .map((name) => ({ name, cases: parseCases(readFileSync(new URL(name, CASES), 'utf8')) }));

/** The predicate suites: JTS's relate cases and its prepared-geometry cases. */
export const isPredicateFile = (name) => /Relate|Predicate/.test(name);
