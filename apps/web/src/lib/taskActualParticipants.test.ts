import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { TaskInstance } from './types';
import { withTaskActualParticipants } from './taskActualParticipants';

const { from } = vi.hoisted(() => ({ from: vi.fn() }));
vi.mock('./supabaseClient', () => ({ supabase: { from } }));

function query(data: unknown[], error: unknown = null) {
  const builder = {
    select: vi.fn(), eq: vi.fn(), in: vi.fn(), is: vi.fn(),
    then: (resolve: (value: unknown) => unknown, reject: (reason: unknown) => unknown) =>
      Promise.resolve({ data, error }).then(resolve, reject),
  };
  for (const method of [builder.select, builder.eq, builder.in, builder.is]) method.mockReturnValue(builder);
  return builder;
}

function task(id = 't1', extra: Partial<TaskInstance> = {}): TaskInstance {
  return {
    id, household_id: 'h1', title: '保育園の準備', completion_mode: 'subtasks',
    status: 'completed', actual_completed_by_id: null, ...extra,
  } as TaskInstance;
}

function participant(actorRef = 'a1', extra: Record<string, unknown> = {}) {
  return { household_id: 'h1', task_instance_id: 't1', actor_ref_id: actorRef, removed_at: null, test_context_id: null, ...extra };
}

function actor(id = 'a1', userId: string | null = 'u1', extra: Record<string, unknown> = {}) {
  return { id, household_id: 'h1', actor_kind: 'real_user', real_user_id: userId, test_context_id: null, ...extra };
}

describe('withTaskActualParticipants', () => {
  beforeEach(() => from.mockReset());

  it('hydrates a completed optional-only checklist without a legacy completion actor', async () => {
    const participants = query([participant(), participant(), participant('a2')]);
    const actors = query([actor(), actor('a2', 'u2')]);
    from.mockImplementation((table: string) => table === 'task_actual_participants' ? participants : actors);
    const result = await withTaskActualParticipants('h1', [task()]);
    expect(result[0].actual_participant_user_ids).toEqual(['u1', 'u2']);
    expect(result[0].actual_completed_by_id).toBeNull();
    expect(participants.eq).toHaveBeenCalledWith('household_id', 'h1');
    expect(participants.is).toHaveBeenCalledWith('removed_at', null);
    expect(participants.is).toHaveBeenCalledWith('test_context_id', null);
    expect(actors.eq).toHaveBeenCalledWith('actor_kind', 'real_user');
    expect(actors.is).toHaveBeenCalledWith('test_context_id', null);
  });

  it('excludes removed, test, unrelated task, other household, and non-real actor data', async () => {
    const participants = query([
      participant(), participant('removed', { removed_at: '2026-10-13T00:00:00Z' }),
      participant('test', { test_context_id: 'test-1' }), participant('other-task', { task_instance_id: 't-other' }),
      participant('other-household', { household_id: 'h2' }),
      participant('simulated'), participant('system'), participant('no-user'), participant('bad-household'), participant('test-actor'),
    ]);
    const actors = query([
      actor(), actor('simulated', 'u-simulated', { actor_kind: 'simulated_member' }),
      actor('system', 'u-system', { actor_kind: 'system' }), actor('no-user', null),
      actor('bad-household', 'u-other', { household_id: 'h2' }),
      actor('test-actor', 'u-test', { test_context_id: 'test-1' }), actor('unrequested-ref', 'u-unrequested'),
    ]);
    from.mockImplementation((table: string) => table === 'task_actual_participants' ? participants : actors);
    expect((await withTaskActualParticipants('h1', [task()]))[0].actual_participant_user_ids).toEqual(['u1']);
    expect(actors.in).toHaveBeenCalledWith('id', ['a1', 'simulated', 'system', 'no-user', 'bad-household', 'test-actor']);
  });

  it('does not fetch participants for open or other-household parent rows', async () => {
    const result = await withTaskActualParticipants('h1', [
      task('open', { status: 'in_progress' }), task('other', { household_id: 'h2' }),
    ]);
    expect(from).not.toHaveBeenCalled();
    expect(result.map(row => row.actual_participant_user_ids)).toEqual([[], []]);
  });

  it('keeps an observation with no known contributor unknown rather than assigning the viewer', async () => {
    from.mockReturnValue(query([]));
    const [result] = await withTaskActualParticipants('h1', [task()]);
    expect(result.actual_participant_user_ids).toEqual([]);
    expect(from).toHaveBeenCalledTimes(1);
  });

  it('bounds the UUID lists when reading a month with many completed tasks', async () => {
    const participants = query([]);
    from.mockReturnValue(participants);
    const tasks = Array.from({ length: 201 }, (_, index) => task(`t-${index}`));
    const result = await withTaskActualParticipants('h1', tasks);
    expect(result).toHaveLength(201);
    expect(participants.in.mock.calls.map(([field, ids]) => [field, ids.length])).toEqual([
      ['task_instance_id', 100], ['task_instance_id', 100], ['task_instance_id', 1],
    ]);
  });

  it.each(['task_actual_participants', 'domain_actor_refs'])('propagates %s lookup failure instead of inventing contributors', async failingTable => {
    const error = new Error('lookup denied');
    from.mockImplementation((table: string) => table === failingTable
      ? query([], error) : query([participant()]));
    await expect(withTaskActualParticipants('h1', [task()])).rejects.toBe(error);
  });
});
