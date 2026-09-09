import { render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { TodayContractPage } from './TodayContractPage';

const todayController = vi.fn(() => <div data-testid="today-controller">today-body</div>);

vi.mock('./Today', () => ({
  Today: () => todayController(),
}));

describe('TodayContractPage', () => {
  it('mounts exactly one Today controller', () => {
    render(<TodayContractPage />);

    expect(screen.getAllByTestId('today-controller')).toHaveLength(1);
    expect(todayController).toHaveBeenCalledTimes(1);
  });
});
