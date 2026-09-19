import type { HouseholdMemberWithProfile } from '../../app/HouseholdContext';

export type CodmonReadinessState =
  | 'not_applicable'
  | 'data_incomplete'
  | 'waiting_inputs'
  | 'ready_to_submit'
  | 'acknowledged';

export type CodmonReadinessInput = {
  code: string;
  task_id: string | null;
  title: string;
  assignee_user_id: string | null;
  assignee_label?: string | null;
  status: string | null;
  resolution: 'present' | 'missing' | 'duplicate';
};

export type CodmonReadiness = {
  local_date: string;
  deadline_at: string | null;
  submit_task_id: string | null;
  state: CodmonReadinessState;
  input_completed_count: number;
  required_input_count: 4;
  inputs: CodmonReadinessInput[];
  submit_assignee_user_id: string | null;
};

export type TaskCompletionPrerequisite = {
  state: CodmonReadinessState;
  message: string;
  detailLabels: string[];
  blocking: boolean;
  actionLabel?: string;
};

function memberLabel(
  userId: string | null,
  fallback: string | null | undefined,
  members: HouseholdMemberWithProfile[],
): string {
  if (!userId) return '担当未定';
  const member = members.find((item) => item.user_id === userId);
  if (member?.family_role === 'papa') return 'パパ';
  if (member?.family_role === 'mama') return 'ママ';
  return member?.profile?.display_name ?? fallback ?? '担当あり';
}

export function buildCodmonCompletionPrerequisite(
  readiness: CodmonReadiness | null | undefined,
  members: HouseholdMemberWithProfile[],
): TaskCompletionPrerequisite | null {
  if (!readiness || readiness.state === 'not_applicable') return null;

  if (readiness.state === 'waiting_inputs') {
    const remaining = readiness.inputs
      .filter((input) => input.resolution !== 'present' || input.status !== 'completed')
      .map((input) => {
        if (input.resolution === 'missing') return `${input.title}（状況未確認）`;
        if (input.resolution === 'duplicate') return `${input.title}（重複・要確認）`;
        return `${input.title}（${memberLabel(input.assignee_user_id, input.assignee_label, members)}）`;
      });
    return {
      state: readiness.state,
      message: '9:15まで。残っている入力を確認してからコドモンを送信します。',
      detailLabels: remaining,
      blocking: true,
    };
  }

  if (readiness.state === 'ready_to_submit') {
    return {
      state: readiness.state,
      message: '入力4件がそろっています。コドモンで送信した後に、ここで送信済みを記録してください。',
      detailLabels: [],
      blocking: false,
      actionLabel: 'コドモンで送信した',
    };
  }

  if (readiness.state === 'data_incomplete') {
    return {
      state: readiness.state,
      message: '入力状況を確認できません。更新してからコドモン送信を確認してください。',
      detailLabels: [],
      blocking: true,
    };
  }

  return {
    state: readiness.state,
    message: 'コドモンで送信したと記録済みです。',
    detailLabels: [],
    blocking: true,
  };
}
