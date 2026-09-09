import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { NavigationStateManager } from './NavigationStateManager';
import { QuickAdd } from '../features/tasks/QuickAdd';
import { ConciergePage } from '../features/concierge/ConciergePage';

vi.mock('../features/tasks/TaskFormModal', () => ({ TaskFormModal: () => null }));

function TodayHarness() {
  return (
    <div style={{ minHeight: 1800 }}>
      <h1>今日</h1>
      <QuickAdd label="＋ 追加" ariaLabel="追加する" />
      <div data-testid="return-anchor">戻り先</div>
    </div>
  );
}

function App() {
  return (
    <>
      <NavigationStateManager />
      <Routes>
        <Route path="/today" element={<TodayHarness />} />
        <Route path="/concierge" element={<ConciergePage />} />
      </Routes>
    </>
  );
}

describe('CF-13 Today -> Concierge -> Back state', () => {
  const scrollTo = vi.fn();

  beforeEach(() => {
    sessionStorage.clear();
    scrollTo.mockClear();
    vi.stubGlobal('requestAnimationFrame', (callback: FrameRequestCallback) => {
      callback(0);
      return 1;
    });
    vi.stubGlobal('cancelAnimationFrame', vi.fn());
    Object.defineProperty(window, 'scrollTo', { value: scrollTo, configurable: true });
    Object.defineProperty(window, 'scrollY', { value: 0, writable: true, configurable: true });
  });

  it('restores Today scroll and reopens the Concierge draft after app Back', async () => {
    render(<MemoryRouter initialEntries={['/today']}><App /></MemoryRouter>);

    window.scrollY = 460;
    fireEvent.click(screen.getByRole('button', { name: '追加する' }));
    fireEvent.click(screen.getByRole('button', { name: /おうちコンシェルジュ/ }));
    expect(await screen.findByRole('heading', { name: 'おうちコンシェルジュ' })).toBeInTheDocument();

    fireEvent.change(screen.getByRole('textbox', { name: '何でも書いてください' }), {
      target: { value: '金曜のお迎えをお願いしたい' },
    });
    expect(sessionStorage.getItem('family-ops:concierge-draft')).toBe('金曜のお迎えをお願いしたい');

    window.scrollY = 20;
    fireEvent.click(screen.getByRole('button', { name: /戻る/ }));
    expect(await screen.findByRole('heading', { name: '今日' })).toBeInTheDocument();
    await waitFor(() => expect(scrollTo).toHaveBeenLastCalledWith({ top: 460, left: 0, behavior: 'auto' }));

    fireEvent.click(screen.getByRole('button', { name: '追加する' }));
    fireEvent.click(screen.getByRole('button', { name: /おうちコンシェルジュ/ }));
    expect(await screen.findByRole('textbox', { name: '何でも書いてください' })).toHaveValue('金曜のお迎えをお願いしたい');
  });
});
