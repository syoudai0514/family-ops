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
    targetRole?: 'papa' | 'mama' | null;
    sharedMessage?: string | null;
  } | null;
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

export async function proposeConciergeCandidates(text: string): Promise<ConciergeProposal> {
  return callEdgeFunction<ConciergeProposal>(EDGE_FUNCTIONS.proposeConciergeCandidates, { text });
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
