import { callEdgeFunction } from '../../lib/apiClient';
import type { EdgeFunctionName } from '../../lib/edgeFunctions';
import type { HouseholdMemberWithProfile } from '../../app/HouseholdContext';
import type { ConciergeCandidate } from './conciergeFlow';
import { buildConfirmedCommand, type ConfirmedCommandContext } from './confirmedCommand';

export type DuplicateDecision = 'existing' | 'update' | 'separate';
type EdgeInvoker = (name: EdgeFunctionName, body: object) => Promise<unknown>;

export type ConciergeCommitResult = {
  candidateId: string;
  operationId: string;
  kind: ConciergeCandidate['kind'];
  title: string;
  ok: boolean;
  message: string;
  canonicalResult?: unknown;
};

type CommitContext = ConfirmedCommandContext & {
  members: HouseholdMemberWithProfile[];
  invoke?: EdgeInvoker;
};

function result(
  candidate: ConciergeCandidate,
  ok: boolean,
  message: string,
  canonicalResult?: unknown,
): ConciergeCommitResult {
  return {
    candidateId: candidate.candidateId,
    operationId: candidate.operationId,
    kind: candidate.kind,
    title: candidate.title,
    ok,
    message,
    canonicalResult,
  };
}

export async function commitConciergeCandidate(
  candidate: ConciergeCandidate,
  context: CommitContext,
  duplicateDecision?: DuplicateDecision,
): Promise<ConciergeCommitResult> {
  if (candidate.duplicateMatch && !duplicateDecision) return result(candidate, false, '重複候補の扱いが未確定です。');
  if (candidate.duplicateMatch && duplicateDecision === 'existing') {
    return result(candidate, true, '既存を使うため変更しません');
  }

  const invoke = context.invoke ?? ((name, body) => callEdgeFunction(name, body));
  try {
    const command = buildConfirmedCommand(candidate, context, duplicateDecision);
    const canonicalResult = await invoke(command.endpoint, command.payload);
    return result(candidate, true, '登録しました', canonicalResult);
  } catch (error) {
    return result(candidate, false, error instanceof Error ? error.message : '登録に失敗しました。');
  }
}

export async function commitConciergeCandidates(
  candidates: ConciergeCandidate[],
  context: CommitContext,
  duplicateDecisions: Record<string, DuplicateDecision> = {},
): Promise<ConciergeCommitResult[]> {
  const results: ConciergeCommitResult[] = [];
  for (const candidate of candidates) {
    results.push(await commitConciergeCandidate(candidate, context, duplicateDecisions[candidate.candidateId]));
  }
  return results;
}
