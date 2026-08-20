#!/usr/bin/env node
// Sol review fix P2-1: a simple release check that fails if CONTINUATION.md's
// declared HEAD commit hash goes stale relative to actual code changes. Run
// this before packaging a review ZIP (or in CI) so a stale CONTINUATION.md is
// caught mechanically instead of relying on someone remembering to update it
// by hand.
//
// Compares against the most recent commit that touches any file OTHER than
// CONTINUATION.md itself, rather than literal `git rev-parse HEAD` — a
// commit cannot know its own hash while being authored (the hash is a
// function of the commit's own content), so CONTINUATION.md can only ever
// declare a hash that already exists at write time. The commit that adds/
// updates CONTINUATION.md itself is expected to sit on top of that declared
// hash with no other file changes; if any other file changes afterward
// without CONTINUATION.md being regenerated, this check correctly fails.
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, '..');
const continuationPath = path.join(repoRoot, 'CONTINUATION.md');

const actualHead = execFileSync(
  'git',
  ['log', '-1', '--format=%H', '--', '.', ':!CONTINUATION.md'],
  { cwd: repoRoot, encoding: 'utf8' },
).trim();

const continuation = readFileSync(continuationPath, 'utf8');
// Matches the fenced code block immediately after the
// "## 1. Current HEAD commit hash" heading, e.g.:
//   ## 1. Current HEAD commit hash
//
//   ```
//   abcdef0123...
//   ```
const match = continuation.match(/## 1\. Current HEAD commit hash\s*\n+```\s*\n([0-9a-f]{40})\s*\n```/);

if (!match) {
  console.error(
    'FAIL: could not find a 40-character HEAD hash in a fenced code block ' +
      'under "## 1. Current HEAD commit hash" in CONTINUATION.md.',
  );
  process.exit(1);
}

const declaredHead = match[1];

if (declaredHead !== actualHead) {
  console.error(
    `FAIL: CONTINUATION.md declares HEAD ${declaredHead}, but the most recent commit touching ` +
      `any other file is ${actualHead}.\n` +
      'Regenerate CONTINUATION.md (or commit/push whatever code changes are pending) before packaging a review ZIP.',
  );
  process.exit(1);
}

console.log(`OK: CONTINUATION.md's declared HEAD (${actualHead}) matches the most recent code-touching commit.`);
