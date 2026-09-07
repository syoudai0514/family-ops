import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

const workflowPath = fileURLToPath(
  new URL('../../../../../.github/workflows/configure-production-cron.yml', import.meta.url),
);

describe('production recurrence materialization cron', () => {
  it('keeps the accepted 00:10 Asia/Tokyo recurring materializer registered', () => {
    const workflow = readFileSync(workflowPath, 'utf8');

    expect(workflow).toContain("family-ops-materialize-recurring-v1");
    expect(workflow).toContain("'10 15 * * *'");
    expect(workflow).toContain('/functions/v1/materialize-recurring');
  });
});
