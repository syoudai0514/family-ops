// Seeds private.jp_holidays from the checked-in Cabinet Office fixture
// (docs/design/v6/fixtures/JP_HOLIDAYS_2026_2027.json), which is the
// bootstrap/fallback source per docs/design/v6/03_DOMAIN_AND_DATA_MODEL.md
// #20. The live sync-jp-holidays worker (WP6+) will upsert from the real
// Cabinet Office CSV; this script exists so local/CI DB tests have holiday
// rows to test non-workday logic against without network access.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, '..');
const fixturePath = path.join(
  repoRoot,
  'docs/design/v6/fixtures/JP_HOLIDAYS_2026_2027.json',
);

const dbName = process.argv[2];
if (!dbName) {
  console.error('usage: seed_jp_holidays.mjs <database>');
  process.exit(1);
}

const fixture = JSON.parse(readFileSync(fixturePath, 'utf8'));

function sqlQuote(value) {
  return `'${value.replace(/'/g, "''")}'`;
}

const values = fixture.holidays
  .map((h) => `(${sqlQuote(h.date)}, ${sqlQuote(h.name)}, 'cao_csv', now())`)
  .join(',\n');

const sql = `
insert into private.jp_holidays (local_date, name, source, source_fetched_at)
values
${values}
on conflict (local_date) do update set name = excluded.name, updated_at = now();
`;

const result = spawnSync('psql', ['-v', 'ON_ERROR_STOP=1', '-d', dbName, '-c', sql], {
  stdio: 'inherit',
});

if (result.status !== 0) {
  process.exit(result.status ?? 1);
}
console.log(`seeded ${fixture.holidays.length} jp_holidays rows`);
