import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';

const HEAD_A = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const HEAD_B = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

function run(payload, head = HEAD_A) {
  const dir = mkdtempSync(join(tmpdir(), 'cf14-f2-'));
  const evidence = join(dir, 'evidence.json');
  writeFileSync(evidence, JSON.stringify(payload), 'utf8');
  try {
    return spawnSync(
      process.execPath,
      ['scripts/run_cf14_f2.mjs', '--evidence', evidence, '--head', head],
      { cwd: process.cwd(), encoding: 'utf8' },
    );
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

test('F2 rejects evidence captured against a different exact HEAD', () => {
  const result = run({ exactHead: HEAD_A, records: [] }, HEAD_B);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /does not match runtime HEAD/);
});

test('F2 rejects PASS records that are not individually bound to the payload exact HEAD', () => {
  const result = run({
    exactHead: HEAD_A,
    records: [{
      scenarioId: 'CF14-TODAY-DAY-FLOW',
      evidenceClass: 'unit-domain',
      status: 'PASS',
      exactHead: HEAD_B,
      source: 'artifact://stale',
      capturedAt: '2026-09-09T14:55:00+09:00',
      details: { entryBoundary: 'domain', assertions: ['fixture invariant'] },
    }],
  });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /PASS evidence must be bound to the payload exactHead/);
});

test('F2 rejects anonymous PASS records without an artifact/source reference', () => {
  const result = run({
    exactHead: HEAD_A,
    records: [{
      scenarioId: 'CF14-TODAY-DAY-FLOW',
      evidenceClass: 'unit-domain',
      status: 'PASS',
      exactHead: HEAD_A,
      source: '',
      capturedAt: '2026-09-09T14:55:00+09:00',
      details: { entryBoundary: 'domain', assertions: ['fixture invariant'] },
    }],
  });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /source\/artifact reference/);
});

test('F2 rejects browser PASS that supplies only a source string without interaction proof', () => {
  const result = run({
    exactHead: HEAD_A,
    records: [{
      scenarioId: 'CF14-NAVIGATION-RETURN',
      evidenceClass: 'browser',
      status: 'PASS',
      exactHead: HEAD_A,
      source: 'artifact://browser/something',
      capturedAt: '2026-09-09T14:55:00+09:00',
      details: { entryBoundary: 'PWA route' },
    }],
  });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /interactionArtifact/);
});

test('F2 matching-head payload remains unacceptable while evidence or Requirement/UX blockers remain', () => {
  const result = run({ exactHead: HEAD_A, records: [] });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /scenarios are not acceptable/);
  assert.match(result.stderr, /known Requirement\/UX blockers/);
  assert.match(result.stdout, /acceptanceBlocker/);
});
