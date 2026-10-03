import { fireEvent, render, screen } from '@testing-library/react';
import { MemoryRouter, useLocation } from 'react-router-dom';
import { describe, expect, it, vi } from 'vitest';
import { Today } from './Today';

vi.mock('./useTodayClock', () => ({ useTodayClock: () => ({now:new Date('2026-10-03T03:00:00Z'),localDate:'2026-10-03',daypart:'morning'}) }));
vi.mock('../planning/DayAgendaSheet', () => ({ DayAgendaSheet: ({date}:{date:string}) => <p>対象日:{date}</p> }));
function Location() { return <output data-testid="location">{useLocation().search}</output>; }
describe('date-specific actuals from the top screen', () => {
  it('moves across past and future days and preserves the LINE recipient parameter', () => {
    render(<MemoryRouter initialEntries={['/today?date=2026-10-02&for=mama']}><Today /><Location /></MemoryRouter>);
    expect(screen.getByText('対象日:2026-10-02')).toBeTruthy();
    fireEvent.click(screen.getByRole('button',{name:'前日'}));
    expect(screen.getByText('対象日:2026-10-01')).toBeTruthy();
    fireEvent.change(screen.getByLabelText('表示する日'),{target:{value:'2026-10-06'}});
    expect(screen.getByText('対象日:2026-10-06')).toBeTruthy();
    fireEvent.click(screen.getByRole('button',{name:'翌日'}));
    expect(screen.getByText('対象日:2026-10-07')).toBeTruthy();
    expect(screen.getByTestId('location').textContent).toContain('for=mama');
    expect(screen.getByRole('button',{name:'今日に戻る'})).toBeTruthy();
  });
});
