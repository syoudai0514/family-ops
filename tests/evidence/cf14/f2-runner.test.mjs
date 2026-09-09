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
    }],
  });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /PASS evidence is not bound/);
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
    }],
  });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /requires a non-empty source/);
});

test('F2 matching-head payload still fails while required evidence classes are missing', () => {
  const result = run({ exactHead: HEAD_A, records: [] });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /scenarios lack required evidence/);
});
