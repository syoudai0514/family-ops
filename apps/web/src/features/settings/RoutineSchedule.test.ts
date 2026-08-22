import { describe, expect, it, vi } from 'vitest';
import { scrollToRoutineAnchor } from './RoutineSchedule';

describe('routine settings anchors', () => {
  it('scrolls and focuses the requested section after route navigation', () => {
    const node = document.createElement('section');
    node.id = 'morning-preparation';
    node.tabIndex = -1;
    node.scrollIntoView = vi.fn();
    document.body.append(node);
    try {
      expect(scrollToRoutineAnchor('#morning-preparation')).toBe(true);
      expect(node.scrollIntoView).toHaveBeenCalledWith({ block: 'start' });
      expect(document.activeElement).toBe(node);
      expect(scrollToRoutineAnchor('#not-a-routine')).toBe(false);
    } finally {
      node.remove();
    }
  });
});
