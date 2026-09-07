import { describe, expect, it } from 'vitest';
import { completedNextTokyoMorning, historyEntryMatchesDate } from './HistoryPage';
import type { HistoryEntry } from './useHistoryData';

function entryFor(date: string): HistoryEntry {
  return { task: { scheduled_date: date }, events: [] } as unknown as HistoryEntry;
}

describe('history occurrence truth', () => {
  it('uses the original occurrence date for yesterday correction filtering', () => {
    expect(historyEntryMatchesDate(entryFor('2026-09-06'), '2026-09-06')).toBe(true);
    expect(historyEntryMatchesDate(entryFor('2026-09-07'), '2026-09-06')).toBe(false);
    expect(historyEntryMatchesDate(entryFor('2026-09-07'), null)).toBe(true);
  });

  it('keeps late registration as audit timing rather than changing the occurrence date', () => {
    expect(completedNextTokyoMorning('2026-09-06', '2026-09-06T14:59:59.000Z')).toBe(false);
    expect(completedNextTokyoMorning('2026-09-06', '2026-09-06T15:00:00.000Z')).toBe(true);
  });
});
