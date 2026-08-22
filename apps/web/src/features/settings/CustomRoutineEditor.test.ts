import { describe, expect, it } from 'vitest';
import { EVENING_ROUTINE_TASK_CODES } from '../../lib/types';
import { isCustomRoutineDefinition } from './CustomRoutineEditor';

describe('CustomRoutineEditor domain boundary', () => {
  it('never selects canonical built-in evening chores by title or task kind alone', () => {
    for (const code of EVENING_ROUTINE_TASK_CODES) {
      expect(isCustomRoutineDefinition('evening_chore', code)).toBe(false);
    }
    expect(isCustomRoutineDefinition('evening_chore', 'evening_chore_custom_1724300000000')).toBe(true);
    // Legacy custom records have the older, still durable prefix.
    expect(isCustomRoutineDefinition('morning_chore', 'morning_custom_final')).toBe(true);
  });
});
