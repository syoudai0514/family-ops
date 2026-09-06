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

type RawLineIntent = {
  scheduledDate?: string;
  dueLocalTime?: string | null;
  targetRole?: string | null;
  sharedMessage?: string | null;
};

type RawConciergeCandidate = {
  candidateId: string;
  kind: ConciergeCandidateKind;
  title: string;
  intent: RawLineIntent | null;
  sourceText: string;
  missingFields: string[];
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
      candidateId: candidate.candidateId,
      kind: candidate.kind,
      title: candidate.title,
      sourceText: candidate.sourceText?.trim() || sourceText,
      missingFields: candidate.missingFields ?? [],
      intent: candidate.intent ? {
        scheduledDate: candidate.intent.scheduledDate,
        dueLocalTime: candidate.intent.dueLocalTime ?? null,
        desiredDueAt: null,
        priority: null,
        targetUserId: null,
        targetRole: candidate.intent.targetRole ?? null,
        sharedMessage: candidate.intent.sharedMessage ?? null,
      } : null,
    })),
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
