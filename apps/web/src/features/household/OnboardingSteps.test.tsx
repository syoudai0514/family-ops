import { render } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { ConnectionsStep } from './OnboardingSteps';

const calendarSettings = vi.hoisted(() => vi.fn());

vi.mock('../../app/HouseholdContext', () => ({
  useHousehold: () => ({ refresh: vi.fn(), household: null, members: [] }),
}));
vi.mock('../../lib/apiClient', () => ({ callEdgeFunction: vi.fn(), FamilyOpsApiError: class extends Error {} }));
vi.mock('../../lib/edgeFunctions', () => ({ EDGE_FUNCTIONS: { completeOnboardingStep: 'complete-onboarding-step' } }));
vi.mock('../../lib/id', () => ({ newOperationId: () => 'operation-id' }));
vi.mock('../notifications/Notifications', () => ({ LineLinkSection: () => <div /> }));
vi.mock('../planning/WeekView', () => ({ WeekView: () => <div /> }));
vi.mock('../settings/RoutineSchedule', () => ({ MorningPreparationEditor: () => <div /> }));
vi.mock('../settings/CalendarIntegrationSettings', () => ({
  CalendarIntegrationSettings: ({ returnTo }: { returnTo: string }) => {
    calendarSettings(returnTo);
    return <div />;
  },
}));

describe('ConnectionsStep Google OAuth return path', () => {
  it('passes an app-relative /today return_to, never an absolute browser origin', () => {
    render(<ConnectionsStep />);
    expect(calendarSettings).toHaveBeenCalledWith('/today');
    expect(calendarSettings.mock.calls[0][0]).not.toContain(window.location.origin);
  });
});
