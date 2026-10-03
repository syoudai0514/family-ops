import { render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { WeekView } from './WeekView';
import { usePlanningData } from './usePlanningData';
vi.mock('../../app/HouseholdContext', () => ({useHousehold:()=>({household:{id:'hh'},members:[],me:null,partner:null})}));
vi.mock('./usePlanningData', () => ({usePlanningData:vi.fn(()=>({tasks:[],occurrences:[],loading:false,error:null,refresh:vi.fn()}))}));
vi.mock('./useWeekSchedule', () => ({useWeekSchedule:()=>({schedule:null,error:null,refresh:vi.fn()})}));
vi.mock('./useCalendarFreshness', () => ({useCalendarFreshness:()=>({})}));
afterEach(()=>vi.useRealTimers());
describe('rolling week range',()=>{
  it('starts on Tokyo Tuesday and ends the following Monday, even when UTC is still Monday',()=>{
    vi.useFakeTimers();vi.setSystemTime(new Date('2026-10-05T16:00:00Z'));
    render(<MemoryRouter><WeekView /></MemoryRouter>);
    expect(vi.mocked(usePlanningData)).toHaveBeenCalledWith('hh','2026-10-06','2026-10-12');
    expect(screen.getByRole('heading',{name:'これから7日間'})).toBeTruthy();
    expect(screen.getByRole('heading',{name:'10/6(火)'})).toBeTruthy();
    expect(screen.getByRole('heading',{name:'10/12(月)'})).toBeTruthy();
  });
});
