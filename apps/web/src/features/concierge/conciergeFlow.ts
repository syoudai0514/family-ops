import { callEdgeFunction } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';

export type ConciergeCandidateKind = 'task' | 'request' | 'shopping' | 'share' | 'actual';

export type ConciergeCandidate = {
  candidateId: string;
  kind: ConciergeCandidateKind;
  title: string;
  sourceText: string;
  missingFields: string[];
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

type RawConciergeCandidate = {
  id: string;
  kind: ConciergeCandidateKind;
  title: string;
  detail?: string;
  targetUserId?: string;
  targetRole?: string;
  scheduledDate?: string;
  dueLocalTime?: string;
  desiredDueAt?: string;
  priority?: 'low' | 'normal' | 'high';
  missingFields?: string[];
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
    candidates: (raw.candidates ?? []).map((candidate) => ({
      candidateId: candidate.id,
      kind: candidate.kind,
      title: candidate.title,
      sourceText: candidate.detail?.trim() || sourceText,
      missingFields: candidate.missingFields ?? [],
      intent: {
        scheduledDate: candidate.scheduledDate,
        dueLocalTime: candidate.dueLocalTime ?? null,
        desiredDueAt: candidate.desiredDueAt ?? null,
        priority: candidate.priority ?? null,
        targetUserId: candidate.targetUserId ?? null,
        targetRole: candidate.targetRole ?? null,
        sharedMessage: candidate.detail ?? null,
      },
    })),
  };
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
