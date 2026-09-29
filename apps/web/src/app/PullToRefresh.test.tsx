import { fireEvent, render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { PullToRefresh } from './PullToRefresh';

function touch(y: number, x = 40) {
  return [{ clientY: y, clientX: x, identifier: 1, target: document.body }];
}

describe('PullToRefresh', () => {
  it('refreshes only after a deliberate downward pull from the top', () => {
    const onRefresh = vi.fn();
    Object.defineProperty(window, 'scrollY', { configurable: true, value: 0 });
    render(<PullToRefresh onRefresh={onRefresh} threshold={40} />);

    fireEvent.touchStart(document, { touches: touch(20) });
    fireEvent.touchMove(document, { touches: touch(100) });
    expect(screen.getByText('離すと更新')).toBeInTheDocument();
    fireEvent.touchEnd(document);

    expect(onRefresh).toHaveBeenCalledTimes(1);
  });

  it('does not refresh for a short pull', () => {
    const onRefresh = vi.fn();
    Object.defineProperty(window, 'scrollY', { configurable: true, value: 0 });
    render(<PullToRefresh onRefresh={onRefresh} threshold={60} />);

    fireEvent.touchStart(document, { touches: touch(20) });
    fireEvent.touchMove(document, { touches: touch(60) });
    fireEvent.touchEnd(document);

    expect(onRefresh).not.toHaveBeenCalled();
  });

  it('does not start while the page is already scrolled', () => {
    const onRefresh = vi.fn();
    Object.defineProperty(window, 'scrollY', { configurable: true, value: 120 });
    render(<PullToRefresh onRefresh={onRefresh} threshold={40} />);

    fireEvent.touchStart(document, { touches: touch(20) });
    fireEvent.touchMove(document, { touches: touch(120) });
    fireEvent.touchEnd(document);

    expect(onRefresh).not.toHaveBeenCalled();
  });
});
