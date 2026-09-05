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
