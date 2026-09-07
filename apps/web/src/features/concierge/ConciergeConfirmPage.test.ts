import { describe, expect, it } from 'vitest';
import { failedCandidateIds, needsDuplicateDecision } from './ConciergeConfirmPage';

describe('Concierge duplicate review', () => {
  it('requires an explicit human decision for generic duplicate-looking candidates', () => {
    expect(needsDuplicateDecision({
      candidateId: 'c1', kind: 'task', title: '牛乳を買う', sourceText: '同じ牛乳のToDoがもうあるかも', missingFields: [], intent: null,
    })).toBe(true);
    expect(needsDuplicateDecision({
      candidateId: 'c2', kind: 'task', title: '水着を準備', sourceText: '明日の水着を準備', missingFields: [], intent: null,
    })).toBe(false);
  });

  it('retries only failed candidates while successful results stay preserved', () => {
    expect(failedCandidateIds([
      { candidateId: 'ok', kind: 'task', title: '成功', ok: true, message: '登録しました' },
      { candidateId: 'ng', kind: 'request', title: '失敗', ok: false, message: '一時エラー' },
    ])).toEqual(['ng']);
    expect(failedCandidateIds(null)).toEqual([]);
  });
});
