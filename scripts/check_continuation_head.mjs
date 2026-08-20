#!/usr/bin/env node
// Sol review fix P2-1: a simple release check that fails if CONTINUATION.md's
// declared HEAD commit hash goes stale relative to actual code changes. Run
// this before packaging a review ZIP (or in CI) so a stale CONTINUATION.md is
// caught mechanically instead of relying on someone remembering to update it
// by hand.
//
// Walks history backwards from HEAD, skipping any leading commits whose
// entire changed-file set is a subset of the "meta" set below (this file and
// CONTINUATION.md itself), and treats the first commit that touches anything
// else as the actual head. This is deliberately NOT a plain pathspec
// exclusion (`git log -1 -- . ':!CONTINUATION.md'`) because that breaks the
// moment this script itself is a new/changed file in the same commit as a
// CONTINUATION.md regeneration: that commit would then "touch another file"
// (itself) and the check would fail on its own introducing commit. Skipping
// whole commits whose diff is entirely within the meta set avoids that,
// while still correctly flagging any commit that changes real product code.
//
// A commit fundamentally cannot know its own hash while being authored (the
// hash is a function of the commit's own content), so CONTINUATION.md can
// only ever declare a hash that already existed at write time — the commit
// that regenerates CONTINUATION.md (optionally alongside this script) is
// expected to sit on top of that declared hash with no other file changes.
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, '..');
const continuationPath = path.join(repoRoot, 'CONTINUATION.md');

const META_FILES = new Set(['CONTINUATION.md', 'scripts/check_continuation_head.mjs']);

function git(args) {
  return execFileSync('git', args, { cwd: repoRoot, encoding: 'utf8' }).trim();
}

function findActualHead() {
  const commits = git(['log', '--format=%H']).split('\n').filter(Boolean);
  for (const commit of commits) {
    const files = git(['show', '--name-only', '--format=', commit])
      .split('\n')
      .filter(Boolean);
    const isMetaOnly = files.length > 0 && files.every((f) => META_FILES.has(f));
    if (!isMetaOnly) {
      return commit;
    }
  }
  // Entire history is meta-only commits (e.g. a brand-new repo) — HEAD itself.
  return commits[0];
}

const actualHead = findActualHead();

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
    `FAIL: CONTINUATION.md declares HEAD ${declaredHead}, but the most recent non-meta ` +
      `(code-touching) commit is ${actualHead}.\n` +
      'Regenerate CONTINUATION.md (or commit/push whatever code changes are pending) before packaging a review ZIP.',
  );
  process.exit(1);
}

console.log(`OK: CONTINUATION.md's declared HEAD (${actualHead}) matches the most recent code-touching commit.`);
