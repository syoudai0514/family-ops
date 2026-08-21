import { renderHook } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { useRealtimeRefresh } from './useRealtimeRefresh';

interface RegisteredListener {
  table: string;
  callback: (payload: unknown) => void;
}

let registered: RegisteredListener[] = [];
const removeChannelMock = vi.fn();
const subscribeMock = vi.fn();
const channelTopics: string[] = [];
const subscribedTopics = new Set<string>();

vi.mock('./supabaseClient', () => ({
  supabase: {
    channel: vi.fn((topic: string) => {
      channelTopics.push(topic);
      const channelObj = {
        on: (
          _type: string,
          filter: { table: string },
          callback: (payload: unknown) => void,
        ) => {
          if (subscribedTopics.has(topic)) {
            throw new Error(`cannot add callbacks for ${topic} after subscribe()`);
          }
          registered.push({ table: filter.table, callback });
          return channelObj;
        },
        subscribe: (...args: unknown[]) => {
          subscribedTopics.add(topic);
          subscribeMock(...args);
          return channelObj;
        },
      };
      return channelObj;
    }),
    removeChannel: (...args: unknown[]) => removeChannelMock(...args),
  },
}));

describe('useRealtimeRefresh', () => {
  beforeEach(() => {
    registered = [];
    channelTopics.length = 0;
    subscribedTopics.clear();
    removeChannelMock.mockReset();
    subscribeMock.mockReset();
  });

  it('calls onRemoteChange when a postgres_changes event fires for a watched table', () => {
    const onRemoteChange = vi.fn();
    renderHook(() =>
      useRealtimeRefresh({
        householdId: 'household-1',
        userId: 'user-1',
        onRemoteChange,
        tables: ['task_instances'],
      }),
    );

    const listener = registered.find((r) => r.table === 'task_instances');
    expect(listener).toBeDefined();
    listener!.callback({ table: 'task_instances', new: { id: 'task-1' }, old: null });

    expect(onRemoteChange).toHaveBeenCalledTimes(1);
    expect(subscribeMock).toHaveBeenCalledTimes(1);
  });

  it('skips the refetch when the changed row was authored by the current user', () => {
    const onRemoteChange = vi.fn();
    renderHook(() =>
      useRealtimeRefresh({
        householdId: 'household-1',
        userId: 'user-1',
        onRemoteChange,
        tables: ['handovers'],
      }),
    );

    const listener = registered.find((r) => r.table === 'handovers');
    listener!.callback({ table: 'handovers', new: { id: 'h1', author_id: 'user-1' }, old: null });

    expect(onRemoteChange).not.toHaveBeenCalled();
  });

  it('still refetches when the changed row was authored by the partner', () => {
    const onRemoteChange = vi.fn();
    renderHook(() =>
      useRealtimeRefresh({
        householdId: 'household-1',
        userId: 'user-1',
        onRemoteChange,
        tables: ['handovers'],
      }),
    );

    const listener = registered.find((r) => r.table === 'handovers');
    listener!.callback({ table: 'handovers', new: { id: 'h1', author_id: 'user-2' }, old: null });

    expect(onRemoteChange).toHaveBeenCalledTimes(1);
  });

  it('does not subscribe when householdId is null', () => {
    const onRemoteChange = vi.fn();
    renderHook(() => useRealtimeRefresh({ householdId: null, userId: 'user-1', onRemoteChange }));
    expect(registered).toHaveLength(0);
    expect(subscribeMock).not.toHaveBeenCalled();
  });

  it('tears down the channel on unmount', () => {
    const onRemoteChange = vi.fn();
    const { unmount } = renderHook(() =>
      useRealtimeRefresh({
        householdId: 'household-1',
        userId: 'user-1',
        onRemoteChange,
        tables: ['task_instances'],
      }),
    );
    unmount();
    expect(removeChannelMock).toHaveBeenCalledTimes(1);
  });

  it('uses distinct topics when multiple visible views subscribe to one household', () => {
    const onRemoteChange = vi.fn();

    renderHook(() => {
      useRealtimeRefresh({ householdId: 'household-1', userId: 'user-1', onRemoteChange });
      useRealtimeRefresh({
        householdId: 'household-1',
        userId: 'user-1',
        onRemoteChange,
        tables: ['handovers', 'handover_reads'],
      });
    });

    expect(new Set(channelTopics)).toHaveLength(2);
    expect(subscribeMock).toHaveBeenCalledTimes(2);
  });
});
