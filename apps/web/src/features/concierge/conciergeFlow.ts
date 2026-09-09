import { callEdgeFunction } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';

export type ConciergeCandidateKind = 'task' | 'request' | 'shopping' | 'share' | 'actual';

export type ConciergeDuplicateMatch = {
  entityKind: 'task' | 'shopping' | 'request';
  entityId: string;
  expectedRevision: number;
  evidence: {
    strategy: 'canonical_exact';
    matchedTitle: string;
    matchedDate: string | null;
  };
};

export type ConciergeCandidate = {
  candidateId: string;
  operationId: string;
  kind: ConciergeCandidateKind;
  title: string;
  sourceText: string;
  sourceSpan: { start: number; end: number } | null;
  confidence: number | null;
  ambiguousFields: string[];
  missingFields: string[];
  duplicateMatch: ConciergeDuplicateMatch | null;
  intent: {
    scheduledDate?: string;
    dueLocalTime?: string | null;
    desiredDueAt?: string | null;
    priority?: 'low' | 'normal' | 'high' | null;
    targetUserId?: string | null;
    targetRole?: string | null;
    sharedMessage?: string | null;
  } | null;
};

type RawLineIntent = {
  scheduledDate?: string;
  dueLocalTime?: string | null;
  targetRole?: string | null;
  sharedMessage?: string | null;
};

type RawConciergeCandidate = {
  candidateId: string;
  operationId: string;
  kind: ConciergeCandidateKind;
  title: string;
  intent: RawLineIntent | null;
  sourceText: string;
  sourceSpan?: { start: number; end: number } | null;
  confidence?: number | null;
  ambiguousFields?: string[];
  missingFields: string[];
  duplicateMatch?: ConciergeDuplicateMatch | null;
};

type RawConciergeProposal = {
  read_only_intent: ConciergeProposal['read_only_intent'];
  candidates: RawConciergeCandidate[];
  clarification: string | null;
};

export type ConciergeProposal = {
  read_only_intent: 'today' | 'tomorrow' | 'week' | 'menu' | 'input' | 'add' | 'share' | 'other' | null;
  candidates: ConciergeCandidate[];
  clarification: string | null;
};

export type ConciergeRouteState = {
  originPath?: string;
  originScrollY?: number;
  draft?: string;
  candidates?: ConciergeCandidate[];
  readOnlyIntent?: ConciergeProposal['read_only_intent'];
  clarification?: string | null;
  actualOnly?: boolean;
};

const STORAGE_KEY = 'family-ops:concierge-draft';

export function saveConciergeDraft(value: string) {
  try { sessionStorage.setItem(STORAGE_KEY, value); } catch { /* storage unavailable */ }
}

export function loadConciergeDraft(): string {
  try { return sessionStorage.getItem(STORAGE_KEY) ?? ''; } catch { return ''; }
}

export function clearConciergeDraft() {
  try { sessionStorage.removeItem(STORAGE_KEY); } catch { /* storage unavailable */ }
}

export function normalizeConciergeProposal(raw: RawConciergeProposal, sourceText: string): ConciergeProposal {
  return {
    read_only_intent: raw.read_only_intent,
    clarification: raw.clarification,
    candidates: (raw.candidates ?? []).flatMap((candidate) => {
      // Candidates without a pre-issued operation identity cannot be retried
      // safely, so reject them before they can reach the confirmation screen.
      if (!candidate.operationId) return [];
      return [{
        candidateId: candidate.candidateId,
        operationId: candidate.operationId,
        kind: candidate.kind,
        title: candidate.title,
        sourceText: candidate.sourceText?.trim() || sourceText,
        sourceSpan: candidate.sourceSpan ?? null,
        confidence: candidate.confidence ?? null,
        ambiguousFields: candidate.ambiguousFields ?? [],
        missingFields: candidate.missingFields ?? [],
        duplicateMatch: candidate.duplicateMatch ?? null,
        intent: candidate.intent ? {
          scheduledDate: candidate.intent.scheduledDate,
          dueLocalTime: candidate.intent.dueLocalTime ?? null,
          desiredDueAt: null,
          priority: null,
          targetUserId: null,
          targetRole: candidate.intent.targetRole ?? null,
          sharedMessage: candidate.intent.sharedMessage ?? null,
        } : null,
      } satisfies ConciergeCandidate];
    }),
  };
}

export function withActualScheduledDate(candidates: ConciergeCandidate[], scheduledDate: string): ConciergeCandidate[] {
  return candidates.map((candidate) => candidate.kind !== 'actual' ? candidate : {
    ...candidate,
    intent: { ...(candidate.intent ?? {}), scheduledDate },
  });
}

export async function proposeConciergeCandidates(text: string): Promise<ConciergeProposal> {
  const raw = await callEdgeFunction<RawConciergeProposal>(EDGE_FUNCTIONS.proposeConciergeCandidates, { text });
  return normalizeConciergeProposal(raw, text);
}

export function readOnlyDestination(intent: NonNullable<ConciergeProposal['read_only_intent']>): string {
  if (intent === 'today') return '/today';
  if (intent === 'tomorrow') return '/week';
  if (intent === 'week') return '/week';
  if (intent === 'input') return '/today?entry=checkin';
  if (intent === 'share') return '/handovers';
  if (intent === 'other') return '/settings';
  return '/today';
}
