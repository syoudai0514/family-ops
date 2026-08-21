import { render, screen } from '@testing-library/react';
import { describe, expect, it } from 'vitest';
import { TodaySchedule } from './TodaySchedule';
import type { HouseholdMemberWithProfile } from '../../app/HouseholdContext';
import type { TodaySchedule as TodayScheduleData } from '../../lib/types';

const MEMBERS: HouseholdMemberWithProfile[] = [
  {
    household_id: 'hh-1',
    user_id: 'user-mama',
    member_role: 'primary',
    joined_at: '2026-01-01',
    profile: { user_id: 'user-mama', display_name: 'ママ' },
  },
  {
    household_id: 'hh-1',
    user_id: 'user-papa',
    member_role: 'partner',
    joined_at: '2026-01-01',
    profile: { user_id: 'user-papa', display_name: 'パパ' },
  },
];

function makeSchedule(overrides: Partial<TodayScheduleData>): TodayScheduleData {
  return {
    household_id: 'hh-1',
    local_date: '2026-08-20',
    calendar_connected: true,
    calendar_stale: false,
    occurrences: [],
    assignments: [],
    ...overrides,
  };
}

describe('TodaySchedule', () => {
  it('renders a chronological line for an assignment and marks a conflict', () => {
    const schedule = makeSchedule({
      assignments: [
        {
          task_instance_id: 'task-1',
          title: 'お迎え',
          category: 'pickup',
          due_at: '2026-08-20T08:30:00Z',
          planned_assignee_id: 'user-mama',
          has_conflict: true,
        },
      ],
    });
    render(<TodaySchedule loading={false} error={null} schedule={schedule} members={MEMBERS} />);
    expect(screen.getByText(/お迎え（担当: ママ）/)).toBeInTheDocument();
    expect(screen.getByText('⚠ 予定と重複')).toBeInTheDocument();
  });

  it('renders a calendar occurrence line without a conflict marker when has_conflict is not set on it', () => {
    const schedule = makeSchedule({
      occurrences: [
        {
          occurrence_key: 'evt-1',
          title: '歯医者',
          starts_at: '2026-08-20T09:00:00Z',
          ends_at: '2026-08-20T09:30:00Z',
          busy_user_ids: ['user-papa'],
        },
      ],
    });
    render(<TodaySchedule loading={false} error={null} schedule={schedule} members={MEMBERS} />);
    expect(screen.getByText(/パパ予定あり/)).toBeInTheDocument();
    expect(screen.queryByText('⚠ 予定と重複')).not.toBeInTheDocument();
  });

  it('does not render a large empty card when there is nothing scheduled today', () => {
    const { container } = render(
      <TodaySchedule loading={false} error={null} schedule={makeSchedule({})} members={MEMBERS} />,
    );
    expect(container).toBeEmptyDOMElement();
  });

  it('degrades gracefully with a hint (not an error) when Calendar is disconnected', () => {
    const schedule = makeSchedule({
      calendar_connected: false,
      assignments: [
        {
          task_instance_id: 'task-2',
          title: '送り',
          category: 'dropoff',
          due_at: '2026-08-20T07:30:00Z',
          planned_assignee_id: 'user-papa',
          has_conflict: false,
        },
      ],
    });
    render(<TodaySchedule loading={false} error={null} schedule={schedule} members={MEMBERS} />);
    expect(screen.getByText(/Googleカレンダーは未接続です/)).toBeInTheDocument();
    // Household tasks remain usable even while disconnected.
    expect(screen.getByText(/送り（担当: パパ）/)).toBeInTheDocument();
  });

  it('shows the stale-calendar warning when calendar_stale is true', () => {
    const schedule = makeSchedule({ calendar_stale: true });
    render(<TodaySchedule loading={false} error={null} schedule={schedule} members={MEMBERS} />);
    expect(screen.getByText('⚠ Google予定を最新化できていません')).toBeInTheDocument();
  });
});
