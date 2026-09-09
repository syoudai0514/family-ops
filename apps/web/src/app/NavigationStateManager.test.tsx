import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter, useLocation, useNavigate } from 'react-router-dom';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { NavigationStateManager } from './NavigationStateManager';

function Harness() {
  const navigate = useNavigate();
  const location = useLocation();
  return (
    <>
      <NavigationStateManager />
      <output aria-label="current-location">{location.pathname}{location.search}</output>
      <button type="button" onClick={() => navigate('/detail')}>detail</button>
      <button type="button" onClick={() => navigate(-1)}>back</button>
    </>
  );
}

describe('NavigationStateManager', () => {
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

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('starts PUSH navigation at the top and restores the previous history entry, query state and scroll on Back', async () => {
    render(
      <MemoryRouter initialEntries={['/today?tab=tasks&filter=waiting']}>
        <Harness />
      </MemoryRouter>,
    );

    expect(screen.getByLabelText('current-location')).toHaveTextContent('/today?tab=tasks&filter=waiting');
    window.scrollY = 420;
    fireEvent.click(screen.getByRole('button', { name: 'detail' }));
    await waitFor(() => expect(scrollTo).toHaveBeenLastCalledWith({ top: 0, left: 0, behavior: 'auto' }));
    expect(screen.getByLabelText('current-location')).toHaveTextContent('/detail');

    window.scrollY = 80;
    fireEvent.click(screen.getByRole('button', { name: 'back' }));
    await waitFor(() => expect(scrollTo).toHaveBeenLastCalledWith({ top: 420, left: 0, behavior: 'auto' }));
    expect(screen.getByLabelText('current-location')).toHaveTextContent('/today?tab=tasks&filter=waiting');
  });
});
