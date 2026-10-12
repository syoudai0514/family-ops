import { fireEvent, render, screen } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { TaskFormModal } from './TaskFormModal';
import { readTaskFormDraft } from './taskFormDraft';

const context = vi.hoisted(() => ({ userId: 'user-1', householdId: 'household-1' }));
vi.mock('../../app/HouseholdContext', () => ({
  useHousehold: () => ({
    members: [],
    household: { id: context.householdId },
    me: { user_id: context.userId },
  }),
}));
vi.mock('../../lib/useCommandAttempt', () => ({ useCommandAttempt: () => vi.fn() }));
vi.mock('./useTaskCategories', () => ({
  useTaskCategories: () => ({ categories: [{ code: 'other', label: 'その他' }] }),
}));

describe('live task draft privacy', () => {
  beforeEach(() => {
    sessionStorage.clear();
    context.userId = 'user-1';
    context.householdId = 'household-1';
    vi.spyOn(window, 'scrollTo').mockImplementation(() => undefined);
  });

  it.each(['userId', 'householdId'] as const)(
    'resets an open form when its %s changes without copying the previous owner’s draft',
    (field) => {
      const props = { mode: 'create' as const, onClose: vi.fn(), onSaved: vi.fn() };
      const { rerender } = render(<TaskFormModal {...props} />);
      fireEvent.change(screen.getByLabelText('何をする？'), {
        target: { value: '共有する前の個人メモ' },
      });
      fireEvent.change(screen.getByLabelText('メモ'), {
        target: { value: 'このアカウントだけの下書き' },
      });
      context[field] = field === 'userId' ? 'user-2' : 'household-2';
      rerender(<TaskFormModal {...props} />);
      expect(screen.getByLabelText('何をする？')).toHaveValue('');
      expect(screen.getByLabelText('メモ')).toHaveValue('');
      expect(readTaskFormDraft({ userId: 'user-1', householdId: 'household-1' })).toMatchObject({
        title: '共有する前の個人メモ',
        schedulerDetails: { notes: 'このアカウントだけの下書き' },
      });
      expect(
        readTaskFormDraft({ userId: context.userId, householdId: context.householdId }),
      ).toMatchObject({ title: '', schedulerDetails: { notes: '' } });
    },
  );
});
