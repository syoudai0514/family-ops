import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { assessEvidence, validateScenarioManifest } from '../tests/evidence/cf14/harness.mjs';
import { cf14Scenarios } from '../tests/evidence/cf14/scenarios.mjs';

function argumentValue(name) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : undefined;
}

function fail(message) {
  console.error(`CF-14 F2 FAIL: ${message}`);
  process.exitCode = 1;
}

function runtimeExactHead() {
  const explicit = argumentValue('--head') ?? process.env.CF14_EXACT_HEAD;
  if (explicit) return explicit.trim();
  try {
    return execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();
  } catch {
    return '';
  }
}

validateScenarioManifest(cf14Scenarios);
const evidencePath = path.resolve(argumentValue('--evidence') ?? 'tests/evidence/cf14/evidence/current.json');
if (!fs.existsSync(evidencePath)) {
  fail(`evidence file not found: ${evidencePath}`);
  console.error('F1 authoring is not acceptance. Supply evidence captured against one exact converged final HEAD.');
} else {
  const payload = JSON.parse(fs.readFileSync(evidencePath, 'utf8'));
  if (!/^[0-9a-f]{40}$/.test(payload.exactHead ?? '')) throw new Error('evidence payload requires a 40-character git exactHead');
  if (!Array.isArray(payload.records)) throw new Error('evidence payload requires records[]');

  const runtimeHead = runtimeExactHead();
  if (!/^[0-9a-f]{40}$/.test(runtimeHead)) {
    fail('runtime exact HEAD could not be resolved; pass --head or CF14_EXACT_HEAD explicitly');
  } else if (runtimeHead !== payload.exactHead) {
    fail(`evidence HEAD ${payload.exactHead} does not match runtime HEAD ${runtimeHead}`);
  }

  for (const [index, record] of payload.records.entries()) {
    if (record.status !== 'PASS') continue;
    if (record.exactHead !== payload.exactHead) {
      fail(`records[${index}] PASS evidence is not bound to payload exactHead ${payload.exactHead}`);
    }
    if (typeof record.source !== 'string' || record.source.trim().length === 0) {
      fail(`records[${index}] PASS evidence requires a non-empty source/artifact reference`);
    }
  }

  if (!process.exitCode) {
    const results = assessEvidence(cf14Scenarios, payload.records, { strict: true });
    const failed = results.filter((result) => result.result !== 'PASS');
    console.table(results.map((result) => ({
      scenario: result.scenarioId,
      result: result.result,
      missing: result.missingEvidenceClasses.join(','),
    })));
    if (failed.length > 0) {
      fail(`${failed.length}/${results.length} scenarios lack required evidence at ${payload.exactHead}`);
    } else {
      console.log(`CF-14 F2 evidence complete for exact HEAD ${payload.exactHead}.`);
    }
  }
}
