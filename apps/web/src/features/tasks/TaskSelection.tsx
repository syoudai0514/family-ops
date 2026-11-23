import { createContext, useCallback, useContext, useMemo, useRef, useState, type ReactNode } from 'react';
import { useUndoNotice } from '../../app/UndoNotice';
import { FamilyOpsApiError } from '../../lib/apiClient';

/**
 * Tick several tasks, then record them together (owner 2026-10-10).
 *
 * Ticking a box only selects; nothing is saved until 完了 or 今日はなし is
 * pressed in the bar, so a family member can tick quickly without waiting for
 * the network after each tap. Each row registers how it records itself, so the
 * bar reuses the row's own command, idempotency key and completion rules.
 */
export type BulkOutcome = 'complete' | 'could_not_do';

/** Undo for one recorded row, or null when the server returned no revision to undo against. */
export type BulkUndo = (() => Promise<void>) | null;

export interface BulkTaskRunner {
  title: string;
  /** Why this row cannot take the outcome in bulk (it stays selected and the reason is shown). */
  blockedReason: (outcome: BulkOutcome) => string | null;
  /** Partner's own task: 完了 records the partner as the performer, like the row's main button. */
  recordsPartner: boolean;
  run: (outcome: BulkOutcome) => Promise<BulkUndo>;
}

interface TaskSelectionValue {
  isSelected: (taskId: string) => boolean;
  toggle: (taskId: string) => void;
  register: (taskId: string, runner: BulkTaskRunner) => () => void;
  completeGroup: (taskIds: string[]) => Promise<void>;
  busy: boolean;
}

const TaskSelectionContext = createContext<TaskSelectionValue | null>(null);

export function useTaskSelection(): TaskSelectionValue | null {
  return useContext(TaskSelectionContext);
}

interface BulkResult { title: string; message: string }

export function TaskSelectionProvider({
  children,
  onChanged,
  partnerLabel,
}: {
  children: ReactNode;
  onChanged: () => void | Promise<void>;
  partnerLabel?: string;
}) {
  const [selected, setSelected] = useState<string[]>([]);
  const [busy, setBusy] = useState(false);
  const running = useRef(false);
  const [failures, setFailures] = useState<BulkResult[]>([]);
  const runners = useRef(new Map<string, BulkTaskRunner>());
  const offerUndo = useUndoNotice();

  const register = useCallback((taskId: string, runner: BulkTaskRunner) => {
    runners.current.set(taskId, runner);
    return () => {
      if (runners.current.get(taskId) === runner) runners.current.delete(taskId);
    };
  }, []);
  const toggle = useCallback((taskId: string) => {
    setFailures([]);
    setSelected((current) => (current.includes(taskId) ? current.filter((id) => id !== taskId) : [...current, taskId]));
  }, []);
  const isSelected = useCallback((taskId: string) => selected.includes(taskId), [selected]);

  // A row that left the list (recorded elsewhere, date changed) is no longer selectable.
  const live = selected.filter((id) => runners.current.has(id));
  const partnerCount = live.filter((id) => runners.current.get(id)?.recordsPartner).length;

  const runTasks = useCallback(async (ids: string[], outcome: BulkOutcome) => {
    if (running.current) return;
    running.current = true;
    setBusy(true);
    setFailures([]);
    try {
      const undos: Array<() => Promise<void>> = [];
      const done: string[] = [];
      const failed: BulkResult[] = [];
      for (const id of ids) {
        const runner = runners.current.get(id);
        if (!runner) {
          failed.push({ title: '作業', message: '最新の状態を確認してください' });
          continue;
        }
        const blocked = runner.blockedReason(outcome);
        if (blocked) {
          failed.push({ title: runner.title, message: blocked });
          continue;
        }
        try {
          const undo = await runner.run(outcome);
          done.push(id);
          if (undo) undos.push(undo);
        } catch (err) {
          failed.push({
            title: runner.title,
            message: err instanceof FamilyOpsApiError && err.code === 'TASK_TERMINAL'
              ? 'すでに記録済みです'
              : err instanceof Error ? err.message : '記録できませんでした',
          });
        }
      }
      setSelected((current) => current.filter((id) => !done.includes(id)));
      setFailures(failed);
      if (done.length > 0) {
        let pendingUndos = undos;
        const missingUndo = done.length - undos.length;
        const undoGuidance = missingUndo === 0 ? '' : undos.length > 0
          ? `。${undos.length}件は元に戻せます。残りは個別に確認してください。`
          : '。修正するときは個別に確認してください。';
        offerUndo({
          label: `${done.length}件を${outcome === 'complete' ? '完了' : '今日はなし'}にしました${undoGuidance}`,
          ...(undos.length > 0 ? { undo: async () => {
            const failedUndos: Array<() => Promise<void>> = [];
            for (const undo of pendingUndos) {
              try { await undo(); } catch { failedUndos.push(undo); }
            }
            pendingUndos = failedUndos;
            await onChanged();
            if (failedUndos.length) throw new Error(`${failedUndos.length}件を元に戻せませんでした。最新の記録を確認してください。`);
          } } : {}),
        });
        try {
          await onChanged();
        } catch {
          setFailures([...failed, { title: '更新', message: '最新の状態を読み込めませんでした' }]);
        }
      }
    } finally {
      running.current = false;
      setBusy(false);
    }
  }, [onChanged, offerUndo]);

  const value = useMemo(() => ({ isSelected, toggle, register, completeGroup: (ids: string[]) => runTasks(ids, 'complete'), busy }), [isSelected, toggle, register, runTasks, busy]);

  return (
    <TaskSelectionContext.Provider value={value}>
      {children}
      {/* Room to scroll the last rows above the bar. Lives here, not as page padding: the date
          bar shares the page container class and grew a blank gap (owner report 2026-10-10). */}
      {(live.length > 0 || failures.length > 0) && <div className="task-bulk-spacer" aria-hidden="true" />}
      {(live.length > 0 || failures.length > 0) && (
        <aside className="task-bulk-bar" aria-label="選んだ作業をまとめて記録">
          {live.length > 0 && (
            <>
              <p className="task-bulk-count" role="status">
                {live.length}件を選択中
                {partnerCount > 0 && <small>（{partnerLabel ?? '相手'}の担当{partnerCount}件は{partnerLabel ?? '相手'}がやった記録）</small>}
              </p>
              <div className="task-bulk-actions">
                <button type="button" className="task-action task-action-primary" disabled={busy} onClick={() => void runTasks(live, 'complete')}>
                  {busy ? '記録中…' : '✓ 完了'}
                </button>
                <button type="button" className="task-action task-action-missed" disabled={busy} onClick={() => void runTasks(live, 'could_not_do')}>
                  今日はなし（実施せず）
                </button>
                <button type="button" className="text-button" disabled={busy} onClick={() => { setSelected([]); setFailures([]); }}>
                  選択を解除
                </button>
              </div>
            </>
          )}
          {failures.length > 0 && (
            <div role="alert" className="task-bulk-failures">
              {failures.map((failure, index) => <p key={`${index}:${failure.title}`}>記録できませんでした：{failure.title}（{failure.message}）</p>)}
              {live.length === 0 && <button type="button" className="text-button" onClick={() => setFailures([])}>閉じる</button>}
            </div>
          )}
        </aside>
      )}
    </TaskSelectionContext.Provider>
  );
}
