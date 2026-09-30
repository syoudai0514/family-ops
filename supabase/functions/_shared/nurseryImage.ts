export type NurseryTriage = 'ordinary_photo' | 'nursery_notice' | 'needs_clarification';
export type ConfidenceBand = 'high' | 'medium' | 'low';

export interface NurseryAnalysis {
  triage: NurseryTriage;
  same_document_as_previous: boolean;
  child_school_context_id: string | null;
  context_confidence: ConfidenceBand;
  ambiguous_fields: string[];
  source_facts: unknown[];
  ai_candidates: unknown[];
}

const SAFE_SCHEMES = new Set(['http:', 'https:']);
const FORBIDDEN_KEYS = new Set([
  'full_transcript', 'transcript', 'raw_text', 'class_roster', 'other_child',
  'other_children', 'third_party_contact', 'contact', 'contacts', 'people',
  'person_profile', 'phone', 'email', 'members',
]);

export function isSafeExternalUrl(value: string): boolean {
  try {
    const url = new URL(value);
    return SAFE_SCHEMES.has(url.protocol) && Boolean(url.hostname);
  } catch {
    return false;
  }
}

export function normalizeSourcePage(page: unknown): number {
  const parsed = typeof page === 'number' ? page : Number(page);
  if (!Number.isInteger(parsed) || parsed < 1 || parsed > 32) throw new Error('NURSERY_SOURCE_PAGE_INVALID');
  return parsed;
}

export function assertPrivacySafeStructuredValue(value: unknown): void {
  const walk = (node: unknown): void => {
    if (Array.isArray(node)) {
      if (node.length > 64) throw new Error('NURSERY_STRUCTURED_VALUE_TOO_LARGE');
      node.forEach(walk);
      return;
    }
    if (node === null || typeof node !== 'object') return;
    for (const [key, child] of Object.entries(node as Record<string, unknown>)) {
      if (FORBIDDEN_KEYS.has(key.toLowerCase())) throw new Error('NURSERY_THIRD_PARTY_DATA_FORBIDDEN');
      walk(child);
    }
  };
  walk(value);
}

export function requiredClarificationFields(analysis: NurseryAnalysis): string[] {
  if (analysis.triage !== 'needs_clarification' && analysis.context_confidence === 'high') return [];
  return [...new Set(analysis.ambiguous_fields.filter((field) => ['nursery', 'child', 'class', 'date', 'document_group'].includes(field)))];
}

export function mayGroupNurseryPages(input: {
  sameDocumentAsPrevious: boolean;
  sameHousehold: boolean;
  sameLineUser: boolean;
  elapsedSeconds: number;
  currentPageCount: number;
}): boolean {
  return input.sameDocumentAsPrevious && input.sameHousehold && input.sameLineUser &&
    input.elapsedSeconds >= 0 && input.elapsedSeconds <= 600 && input.currentPageCount >= 1 && input.currentPageCount < 12;
}

export function classifyTimetableItem(recommended: boolean): 'recommended' | 'other' {
  return recommended ? 'recommended' : 'other';
}

export function validateBoundedRecurrence(input: { effective_from: string; effective_to: string }): boolean {
  const start = Date.parse(`${input.effective_from}T00:00:00Z`);
  const end = Date.parse(`${input.effective_to}T00:00:00Z`);
  if (!Number.isFinite(start) || !Number.isFinite(end) || end < start) return false;
  return end - start <= 366 * 86_400_000;
}

export type NurseryResultKind = 'failed' | 'review_ready' | 'needs_clarification';

/**
 * What the sender is told after a photo was processed. Before this, nothing was
 * sent on success or failure (2026-09-29 review §2-7): the worker never sends to
 * LINE, so a photo that failed twice in production looked like it had been
 * ignored. Family photos (ordinary_photo) get no message on purpose.
 */
export function buildNurseryResultMessage(input: {
  kind: NurseryResultKind;
  itemCount: number;
  hasContexts: boolean;
  link: string;
}): string {
  if (input.kind === 'failed') {
    return '📷 写真をうまく読み取れませんでした。\nもう一度撮り直して送るか、内容を文字で送ってください。';
  }
  const lines = [
    input.itemCount > 0
      ? `📷 保育園のお知らせを読み取りました（候補${input.itemCount}件）。`
      : '📷 写真を読み取りましたが、予定や持ち物の候補は見つかりませんでした。',
  ];
  if (!input.hasContexts) {
    lines.push('子ども・園・クラスがまだ登録されていないため、登録が済むまで確認できません。');
  } else if (input.kind === 'needs_clarification') {
    lines.push('どの子・どのクラスのものか、確認が必要です。');
  } else if (input.itemCount > 0) {
    lines.push('内容を確認して登録してください。');
  }
  if (input.link) lines.push(input.link);
  return lines.join('\n');
}

/**
 * Validates review items one by one and keeps the good ones. One malformed item
 * used to fail the whole photo (a single bad field in a 20-item notice threw
 * away the other 19). `validateOne` throws to reject an item; the reasons are
 * returned so they can be logged without the notice text.
 */
export function keepValidReviewItems<T>(
  items: T[],
  validateOne: (item: T, index: number) => void,
): { kept: T[]; dropped: string[] } {
  const kept: T[] = [];
  const dropped: string[] = [];
  items.forEach((item, index) => {
    try {
      validateOne(item, index);
      kept.push(item);
    } catch (err) {
      dropped.push(err instanceof Error && /^[A-Z0-9_]+$/.test(err.message) ? err.message : 'NURSERY_REVIEW_ITEM_INVALID');
    }
  });
  return { kept, dropped };
}
