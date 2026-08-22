import { describe, expect, it } from 'vitest';
import { phaseForHousehold } from './HouseholdContext';
import type { Household } from '../lib/types';

const complete: Household = {
  id: 'household-1',
  name: '家族',
  timezone: 'Asia/Tokyo',
  dropoff_pickup_setup_completed_at: '2026-08-21T00:00:00Z',
  evening_routine_setup_completed_at: '2026-08-21T00:00:00Z',
  morning_preparation_setup_completed_at: '2026-08-21T00:00:00Z',
  connections_setup_completed_at: '2026-08-21T00:00:00Z',
  notification_preferences_setup_completed_at: '2026-08-21T00:00:00Z',
  onboarding_preview_completed_at: '2026-08-21T00:00:00Z',
};

describe('onboarding phase order', () => {
  it('lets a one-person household start setup before inviting a partner', () => {
    expect(phaseForHousehold({ ...complete, dropoff_pickup_setup_completed_at: null }, 1)).toBe(
      'dropoff-pickup-wizard',
    );
  });

  it('walks the persisted eight-step tail in order', () => {
    expect(
      phaseForHousehold({ ...complete, morning_preparation_setup_completed_at: null }, 2),
    ).toBe('morning-preparation-wizard');
    expect(phaseForHousehold({ ...complete, connections_setup_completed_at: null }, 2)).toBe(
      'connections-wizard',
    );
    expect(
      phaseForHousehold({ ...complete, notification_preferences_setup_completed_at: null }, 2),
    ).toBe('notifications-wizard');
    expect(phaseForHousehold({ ...complete, onboarding_preview_completed_at: null }, 2)).toBe(
      'week-preview-wizard',
    );
    expect(phaseForHousehold(complete, 2)).toBe('ready');
  });
});
