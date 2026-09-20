import { describe, expect, it } from 'vitest';
import type { HouseholdMemberWithProfile } from '../../app/HouseholdContext';
import { buildCodmonCompletionPrerequisite, type CodmonReadiness } from './codmonReadiness';

const members = [
  { household_id: 'h', user_id: 'p', member_role: 'adult', family_role: 'papa', joined_at: '', profile: { user_id: 'p', display_name: 'パパ' } },
  { household_id: 'h', user_id: 'm', member_role: 'adult', family_role: 'mama', joined_at: '', profile: { user_id: 'm', display_name: 'ママ' } },
] as HouseholdMemberWithProfile[];

function readiness(state: CodmonReadiness['state']): CodmonReadiness {
  return {
    local_date: '2026-09-21',
    deadline_at: '2026-09-21T00:15:00Z',
    submit_task_id: 'submit',
    state,
    input_completed_count: state === 'ready_to_submit' ? 4 : 2,
    required_input_count: 4,
    submit_assignee_user_id: 'p',
    inputs: [
      { code: 'a', task_id: '1', title: '朝食', assignee_user_id: 'p', status: 'completed', resolution: 'present' },
      { code: 'b', task_id: '2', title: '昨日の様子', assignee_user_id: 'm', status: 'todo', resolution: 'present' },
      { code: 'c', task_id: '3', title: '迎え', assignee_user_id: 'p', status: 'todo', resolution: 'present' },
      { code: 'd', task_id: '4', title: '将生迎え', assignee_user_id: 'm', status: 'completed', resolution: 'present' },
    ],
  };
}

describe('Codmon completion prerequisite', () => {
  it('shows remaining input and assignee while blocking final acknowledgement', () => {
    const result = buildCodmonCompletionPrerequisite(readiness('waiting_inputs'), members);
    expect(result).toMatchObject({ blocking: true, state: 'waiting_inputs' });
    expect(result?.detailLabels).toEqual(['昨日の様子（ママ）', '迎え（パパ）']);
  });

  it('only enables the existing complete command after all four inputs are ready', () => {
    const result = buildCodmonCompletionPrerequisite(readiness('ready_to_submit'), members);
    expect(result).toMatchObject({ blocking: false, actionLabel: 'コドモンで送信した' });
  });

  it('fails closed when the readiness projection is incomplete', () => {
    const result = buildCodmonCompletionPrerequisite(readiness('data_incomplete'), members);
    expect(result).toMatchObject({ blocking: true, state: 'data_incomplete' });
  });
});
