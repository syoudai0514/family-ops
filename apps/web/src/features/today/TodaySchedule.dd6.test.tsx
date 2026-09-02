import { render, screen } from '@testing-library/react';
import { describe, expect, it } from 'vitest';
import { TodaySchedule } from './TodaySchedule';
import type { TodaySchedule as TodayScheduleData } from '../../lib/types';

const members = [
  {
    household_id: 'household-1',
    user_id: 'user-1',
    member_role: 'adult',
    family_role: 'papa' as const,
    joined_at: '2026-01-01T00:00:00Z',
    profile: { user_id: 'user-1', display_name: 'パパ' },
  },
];

describe('TodaySchedule DD6 all-day contract', () => {
  it('renders Google all-day entries as 終日 and never manufactures 00:00', () => {
    const schedule: TodayScheduleData = {
      household_id: 'household-1',
      local_date: '2026-09-03',
      calendar_connected: true,
      calendar_stale: false,
      assignments: [],
      occurrences: [
        {
          occurrence_key: 'all-day-school',
          title: '保育園休園日',
          starts_at: null,
          ends_at: null,
          is_all_day: true,
          all_day_start: '2026-09-03',
          all_day_end_exclusive: '2026-09-04',
          busy_user_ids: [],
        },
      ],
    };

    render(
      <TodaySchedule loading={false} error={null} schedule={schedule} members={members} />,
    );

    expect(screen.getByText('終日 保育園休園日')).toBeInTheDocument();
    expect(screen.queryByText(/00:00/)).not.toBeInTheDocument();
    expect(screen.queryByText(/予定と重複/)).not.toBeInTheDocument();
  });
});
