import { fireEvent, render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { LineConnectPrompt } from './LineConnectPrompt';

const setup = vi.hoisted(() => ({ linked: false }));
vi.mock('../../app/HouseholdContext', () => ({ useHousehold: () => ({ me: { user_id: 'mama' } }) }));
vi.mock('../settings/useFamilySetup', () => ({
  useFamilySetup: () => ({ data: { members: [{ user_id: 'mama', line_linked: setup.linked }, { user_id: 'papa', line_linked: true }] } }),
}));

describe('LineConnectPrompt', () => {
  beforeEach(() => {
    setup.linked = false;
    window.localStorage.clear();
  });

  it('offers one button to the LINE step to someone not linked yet', () => {
    render(<MemoryRouter><LineConnectPrompt /></MemoryRouter>);
    expect(screen.getByRole('link', { name: 'LINEとつなぐ' })).toHaveAttribute('href', '/notifications');
  });

  it('stays away once linked, or after あとで', () => {
    setup.linked = true;
    const { unmount } = render(<MemoryRouter><LineConnectPrompt /></MemoryRouter>);
    expect(screen.queryByText('LINEとつなぎましょう')).toBeNull();
    unmount();
    setup.linked = false;
    render(<MemoryRouter><LineConnectPrompt /></MemoryRouter>);
    fireEvent.click(screen.getByRole('button', { name: 'あとで' }));
    expect(screen.queryByText('LINEとつなぎましょう')).toBeNull();
  });
});
