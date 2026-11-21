import { StrictMode } from 'react';
import { render } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { Modal } from './Modal';

describe('Modal scroll lock', () => {
  afterEach(() => {
    document.body.removeAttribute('style');
    document.documentElement.removeAttribute('style');
    vi.restoreAllMocks();
  });

  it('registers one Back entry when StrictMode replays the dialog effect', async () => {
    const push = vi.spyOn(window.history, 'pushState');
    render(<StrictMode><Modal title="予定" onClose={() => undefined}>予定</Modal></StrictMode>);
    await Promise.resolve();
    expect(push).toHaveBeenCalledTimes(1);
  });

  it('freezes the page at the current scroll position and restores it on close', () => {
    Object.defineProperty(window, 'scrollY', { configurable: true, value: 320 });
    const scrollTo = vi.spyOn(window, 'scrollTo').mockImplementation(() => undefined);

    const { unmount } = render(
      <Modal title="追加するもの" onClose={() => undefined}>
        <div>content</div>
      </Modal>,
    );

    expect(document.documentElement.style.overflow).toBe('hidden');
    expect(document.body.style.overflow).toBe('hidden');
    expect(document.body.style.position).toBe('fixed');
    expect(document.body.style.top).toBe('-320px');
    expect(document.body.style.width).toBe('100%');

    unmount();

    expect(document.documentElement.style.overflow).toBe('');
    expect(document.body.style.overflow).toBe('');
    expect(document.body.style.position).toBe('');
    expect(document.body.style.top).toBe('');
    expect(scrollTo).toHaveBeenCalledWith(0, 320);
  });
});
