import fs from 'node:fs';
import path from 'node:path';
import { assessEvidence, validateScenarioManifest } from '../tests/evidence/cf14/harness.mjs';
import { cf14Scenarios } from '../tests/evidence/cf14/scenarios.mjs';

function argumentValue(name) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : undefined;
}

validateScenarioManifest(cf14Scenarios);
const evidencePath = path.resolve(argumentValue('--evidence') ?? 'tests/evidence/cf14/evidence/current.json');
if (!fs.existsSync(evidencePath)) {
  console.error(`CF-14 F2 FAIL: evidence file not found: ${evidencePath}`);
  console.error('F1 authoring is not acceptance. Supply evidence captured against one exact converged final HEAD.');
  process.exitCode = 1;
} else {
  const payload = JSON.parse(fs.readFileSync(evidencePath, 'utf8'));
  if (!payload.exactHead || typeof payload.exactHead !== 'string') throw new Error('evidence payload requires exactHead');
  if (!Array.isArray(payload.records)) throw new Error('evidence payload requires records[]');
  const results = assessEvidence(cf14Scenarios, payload.records, { strict: true });
  const failed = results.filter((result) => result.result !== 'PASS');
  console.table(results.map((result) => ({
    scenario: result.scenarioId,
    result: result.result,
    missing: result.missingEvidenceClasses.join(','),
  })));
  if (failed.length > 0) {
    console.error(`CF-14 F2 FAIL at ${payload.exactHead}: ${failed.length}/${results.length} scenarios lack required evidence.`);
    process.exitCode = 1;
  } else {
    console.log(`CF-14 F2 evidence complete for exact HEAD ${payload.exactHead}.`);
  }
}
