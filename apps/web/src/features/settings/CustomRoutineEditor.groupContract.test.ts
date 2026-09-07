import { describe, expect, it } from 'vitest';
import { isCustomRoutineDefinition } from './CustomRoutineEditor';

describe('routine group contract', () => {
  it('keeps household-created groups separate from built-in automatic chores by durable code', () => {
    expect(isCustomRoutineDefinition('morning_chore', 'morning_chore_custom_123')).toBe(true);
    expect(isCustomRoutineDefinition('morning_chore', 'morning_custom_123')).toBe(true);
    expect(isCustomRoutineDefinition('evening_chore', 'evening_chore_custom_123')).toBe(true);
    expect(isCustomRoutineDefinition('evening_chore', 'evening_custom_123')).toBe(true);

    expect(isCustomRoutineDefinition('evening_chore', 'dinner')).toBe(false);
    expect(isCustomRoutineDefinition('evening_chore', 'bath')).toBe(false);
    expect(isCustomRoutineDefinition('morning_chore', 'dropoff_checklist')).toBe(false);
  });
});
