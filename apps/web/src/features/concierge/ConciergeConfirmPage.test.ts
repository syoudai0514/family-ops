import { describe, expect, it } from 'vitest';
import { needsDuplicateDecision } from './ConciergeConfirmPage';

describe('Concierge duplicate review', () => {
  it('requires an explicit human decision for generic duplicate-looking candidates', () => {
    expect(needsDuplicateDecision({
      candidateId: 'c1', kind: 'task', title: '牛乳を買う', sourceText: '同じ牛乳のToDoがもうあるかも', missingFields: [], intent: null,
    })).toBe(true);
    expect(needsDuplicateDecision({
      candidateId: 'c2', kind: 'task', title: '水着を準備', sourceText: '明日の水着を準備', missingFields: [], intent: null,
    })).toBe(false);
  });
});
