import { describe, expect, it } from 'vitest';
import { failedCandidateIds, needsDuplicateDecision } from './ConciergeConfirmPage';
import type { ConciergeCandidate } from './conciergeFlow';

function candidate(overrides: Partial<ConciergeCandidate> & Pick<ConciergeCandidate, 'candidateId' | 'title'>): ConciergeCandidate {
  return {
    operationId: `00000000-0000-4000-8000-${overrides.candidateId.padEnd(12, '0').slice(0, 12)}`,
    kind: 'task',
    sourceText: overrides.title,
    sourceSpan: null,
    confidence: null,
    ambiguousFields: [],
    missingFields: [],
    duplicateMatch: null,
    intent: null,
    ...overrides,
  };
}

describe('Concierge duplicate review', () => {
  it('requires a decision only when canonical DB matching supplied duplicate evidence', () => {
    expect(needsDuplicateDecision(candidate({
      candidateId: 'c1',
      title: '牛乳を買う',
      sourceText: '同じ牛乳のToDoがもうあるかも',
      duplicateMatch: {
        entityKind: 'task',
        entityId: '00000000-0000-4000-8000-000000000901',
        expectedRevision: 4,
        evidence: { strategy: 'canonical_exact', matchedTitle: '牛乳を買う', matchedDate: '2026-09-09' },
      },
    }))).toBe(true);
    expect(needsDuplicateDecision(candidate({
      candidateId: 'c2', title: '水着を準備', sourceText: '明日の水着を準備',
    }))).toBe(false);
  });

  it('retries only failed candidates while successful results stay preserved', () => {
    expect(failedCandidateIds([
      { candidateId: 'ok', operationId: '00000000-0000-4000-8000-000000000010', kind: 'task', title: '成功', ok: true, message: '登録しました' },
      { candidateId: 'ng', operationId: '00000000-0000-4000-8000-000000000011', kind: 'request', title: '失敗', ok: false, message: '一時エラー' },
    ])).toEqual(['ng']);
    expect(failedCandidateIds(null)).toEqual([]);
  });
});
