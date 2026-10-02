// Physical iPhone, 2026-09-30 and again 2026-10-02: the Today list stopped mid-card with
// a blank page below and no header. `overflow-x: hidden` on html/body/#root/.app-root
// made each of them a scroll container (overflow-y computes to auto); the sticky header
// stuck to a box that never scrolls, and Safari painted the tall page as one scrolling
// layer. The page shell must clip horizontally without becoming a scroll container.
/// <reference types="node" />
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

// Read from disk: Vitest does not load CSS contents (a ?raw import comes back empty).
const here = dirname(fileURLToPath(import.meta.url));
const read = (name: string) => readFileSync(join(here, name), 'utf8');

/** The last overflow-x declared in each rule whose selector list names `selector`. */
function overflowX(css: string, selector: string): string[] {
  const out: string[] = [];
  const plain = css.replace(/\/\*[\s\S]*?\*\//g, '');
  for (const match of plain.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
    const selectors = match[1].split(',').map((s) => s.trim());
    if (!selectors.includes(selector)) continue;
    const values = [...match[2].matchAll(/overflow-x:\s*([a-z]+)/g)].map((m) => m[1]);
    if (values.length) out.push(values[values.length - 1]);
  }
  return out;
}

describe('page shell never becomes a scroll container', () => {
  it.each([
    ['index.css', 'html'],
    ['index.css', 'body'],
    ['index.css', '#root'],
    ['App.css', 'body'],
    ['mobileHotfix.css', '.app-root'],
  ])('%s %s clips instead of hiding', (file, selector) => {
    const values = overflowX(read(file), selector);
    expect(values.length).toBeGreaterThan(0);
    for (const value of values) expect(value).toBe('clip');
  });
});
