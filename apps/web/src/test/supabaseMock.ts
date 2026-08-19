import { vi } from 'vitest';

type Row = Record<string, unknown>;

// Minimal chainable stand-in for the subset of the supabase-js query builder
// this app actually uses (select/eq/in/order/gte/maybeSingle, and awaiting
// the builder itself). Every chain method just returns `this`; the terminal
// resolution always yields the fixture rows for whichever table `.from()`
// was called with — good enough for smoke tests, not a behavioral fake.
function createQueryBuilder(rows: Row[]) {
  const builder = {
    select: vi.fn(() => builder),
    eq: vi.fn(() => builder),
    in: vi.fn(() => builder),
    order: vi.fn(() => builder),
    gte: vi.fn(() => builder),
    limit: vi.fn(() => builder),
    maybeSingle: vi.fn(() => Promise.resolve({ data: rows[0] ?? null, error: null })),
    then: (
      resolve: (value: { data: Row[]; error: null }) => unknown,
      reject?: (reason: unknown) => unknown,
    ) => Promise.resolve({ data: rows, error: null }).then(resolve, reject),
  };
  return builder;
}

export function createSupabaseFromMock(fixtures: Record<string, Row[]>) {
  return vi.fn((table: string) => createQueryBuilder(fixtures[table] ?? []));
}
