import { useCallback, useEffect, useMemo, useState } from 'react';
import { Modal } from '../../components/Modal';
import { useHousehold } from '../../app/HouseholdContext';
import { mamaUserId, papaUserId } from '../../lib/familyRoles';
import { supabase } from '../../lib/supabaseClient';
import type { TaskInstance, TaskSubtaskInstance } from '../../lib/types';
import { TaskChecklistItem } from '../tasks/TaskChecklistItem';
import { TaskFormModal } from '../tasks/TaskFormModal';
import {
  buildCalendarProjection,
  transportTokens,
  type CalendarProjectionItem,
  type PlanningTask,
} from './calendarProjection';
import { usePlanningData } from './usePlanningData';
import './DayAgendaSheet.css';
import { ScheduleEventCard } from './ScheduleEventCard';
import { isTaskRecorded, summarizeTaskRecording } from '../tasks/taskRecording';
import { groupTasksByOwner } from '../tasks/taskOwnerGroups';
import { TaskRecordingBadge } from '../tasks/TaskRecordingBadge';
import { RemoveDayTransport } from './RemoveDayTransport';
import { tokyoIsoDate } from './dateHelpers';

function dayTitle(date: string) {
  const parsed = new Date(`${date}T00:00:00+09:00`);
  if (Number.isNaN(parsed.getTime())) return date;
  return new Intl.DateTimeFormat('ja-JP', {
    month: 'long',
    day: 'numeric',
    weekday: 'long',
    timeZone: 'Asia/Tokyo',
  }).format(parsed);
}

function clock(value: string | null) {
  if (!value) return null;
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) return null;
  return new Intl.DateTimeFormat('ja-JP', {
    timeZone: 'Asia/Tokyo',
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  }).format(parsed);
}

function timelineLabel(item: CalendarProjectionItem, task?: PlanningTask | null) {
  if (item.allDay && task?.routine_phase === 'evening' && !task.due_at) return { start: '夜', end: '時刻未定' };
  if (item.allDay) return { start: '終日', end: null };
  return { start: clock(item.startsAt) ?? '—', end: clock(item.endsAt) };
}

function isTransportTask(task: PlanningTask) {
  return (
    task.task_kind === 'transport' ||
    task.definition_code === 'dropoff' ||
    task.definition_code === 'pickup' ||
    task.category === 'dropoff' ||
    task.category === 'pickup'
  );
}

// Time order only. Recorded tasks used to sink below the open ones, so checking one off moved
// it away and shifted every row under the finger; a task now stays where it was and only its
// check changes (2026-10-09: recording a whole day's tasks one by one).
function taskSort(a: PlanningTask, b: PlanningTask) {
  return (a.due_at ?? '9999').localeCompare(b.due_at ?? '9999') || a.title.localeCompare(b.title) || a.id.localeCompare(b.id);
}

function AgendaFrame({ inline, children, ...props }: Parameters<typeof Modal>[0] & { inline?: boolean }) {
  return inline ? <section className="day-agenda-inline"><h1>{props.title}</h1>{children}</section> : <Modal {...props}>{children}</Modal>;
}

export function DayAgendaSheet({
  date,
  onClose,
  onChanged,
  inline = false,
}: {
  date: string;
  onClose: () => void;
  onChanged: () => void | Promise<void>;
  inline?: boolean;
}) {
  const { household, members, partner, me } = useHousehold();
  const planning = usePlanningData(household?.id ?? null, date, date);
  const primaryUserId = papaUserId(members);
  const partnerUserId = mamaUserId(members);
  const [subtasksByTaskId, setSubtasksByTaskId] = useState<Map<string, TaskSubtaskInstance[]>>(
    new Map(),
  );
  const [subtaskError, setSubtaskError] = useState<string | null>(null);
  const [editingTask, setEditingTask] = useState<TaskInstance | null>(null);
  const [createKind, setCreateKind] = useState<'event' | 'task' | null>(null);

  const projection = useMemo(
    () =>
      buildCalendarProjection({
        tasks: planning.tasks,
        occurrences: planning.occurrences,
        primaryUserId,
        partnerUserId,
      }),
    [partnerUserId, planning.occurrences, planning.tasks, primaryUserId],
  );

  const loadSubtasks = useCallback(async () => {
    if (!household?.id) return;
    const ids = planning.tasks
      .filter((task) => task.completion_mode === 'subtasks')
      .map((task) => task.id);
    if (ids.length === 0) {
      setSubtasksByTaskId(new Map());
      setSubtaskError(null);
      return;
    }
    const { data, error } = await supabase
      .from('task_subtask_instances')
      .select('*')
      .eq('household_id', household.id)
      .in('task_instance_id', ids)
      .order('sort_order', { ascending: true });
    if (error) {
      setSubtaskError(error.message);
      return;
    }
    const grouped = new Map<string, TaskSubtaskInstance[]>();
    for (const row of data ?? []) {
      const list = grouped.get(row.task_instance_id) ?? [];
      list.push(row as TaskSubtaskInstance);
      grouped.set(row.task_instance_id, list);
    }
    setSubtasksByTaskId(grouped);
    setSubtaskError(null);
  }, [household?.id, planning.tasks]);

  useEffect(() => {
    void loadSubtasks();
  }, [loadSubtasks]);

  const refreshAll = useCallback(async () => {
    await planning.refresh();
    await onChanged();
  }, [onChanged, planning]);

  const dayItems = projection.itemsByDate.get(date) ?? [];
  const transport = projection.transportByDate.get(date);
  const tokens = transportTokens(transport, primaryUserId, partnerUserId);
  const taskById = new Map(planning.tasks.map((task) => [task.id, task]));
  const transportTaskIds = new Set(
    [transport?.dropoffTaskId, transport?.pickupTaskId].filter((id): id is string => Boolean(id)),
  );
  const transportTasks = [...transportTaskIds]
    .map((id) => taskById.get(id))
    .filter((task): task is PlanningTask => Boolean(task))
    .sort(taskSort);
  const operationalTasks = planning.tasks
    .filter(
      (task) =>
        task.scheduled_date === date &&
        !isTransportTask(task),
    )
    .sort(taskSort);
  // 余裕があれば (optional) is kept apart and quiet: it is never "left to do" (owner 2026-10-09).
  const optionalTasks = operationalTasks.filter((task) => task.expectation === 'optional');
  const requiredTasks = operationalTasks.filter((task) => task.expectation !== 'optional');
  const recordedOperational = requiredTasks.filter(isTaskRecorded).length;
  const recording = summarizeTaskRecording(planning.tasks, date, { userId: me?.user_id });

  const renderTask = (task: PlanningTask, showTime = true) => (
    <TaskChecklistItem
      key={task.id}
      task={task}
      subtasks={subtasksByTaskId.get(task.id) ?? []}
      members={members}
      hasPartner={Boolean(partner)}
      currentUserId={me?.user_id}
      onEdit={setEditingTask}
      onChanged={refreshAll}
      showTime={showTime}
    />
  );

  // Mine / shared / the other adult's, apart from each other (owner 2026-10-09: with both lists
  // mixed, a tap could land on the other adult's task). The other adult's list is folded.
  const ownerGroups = groupTasksByOwner(requiredTasks, me?.user_id);
  const roleLabel = (role: string | null | undefined, fallback: string) => role === 'papa' ? 'パパ' : role === 'mama' ? 'ママ' : fallback;
  const meLabel = roleLabel(me?.family_role, '自分');
  const partnerLabel = roleLabel(partner?.family_role, '相手');
  const renderOwnerGroup = (kind: 'mine' | 'shared' | 'partner', title: string, list: PlanningTask[], folded = false) => {
    if (list.length === 0) return null;
    const open = list.filter((task) => !isTaskRecorded(task)).length;
    const summary = (
      <>
        <strong>{title}</strong>
        <span>{list.length}件{open > 0 ? `・未記録${open}` : '・すべて記録済み'}</span>
      </>
    );
    const items = <ul className="task-list day-agenda-task-list">{list.map((task) => renderTask(task))}</ul>;
    return folded ? (
      <details className={`day-agenda-owner day-agenda-owner-${kind}`} key={kind}>
        <summary className="day-agenda-owner-heading">{summary}</summary>
        {items}
      </details>
    ) : (
      <div className={`day-agenda-owner day-agenda-owner-${kind}`} key={kind}>
        <h4 className="day-agenda-owner-heading">{summary}</h4>
        {items}
      </div>
    );
  };

  const scheduleSection = (
    <section className="day-agenda-section">
    <div className="day-agenda-section-heading">
      <div>
        <p className="eyebrow">時間順</p>
        <h3>予定</h3>
      </div>
      <button type="button" className="text-button" onClick={() => setCreateKind('event')}>
        ＋ 追加
      </button>
    </div>
    {dayItems.length === 0 ? (
      <button
        type="button"
        className="day-agenda-empty-action"
        onClick={() => setCreateKind('event')}
      >
        予定はありません。＋ この日に予定を追加
      </button>
    ) : (
      <div className="day-agenda-timeline">
        {dayItems.map((item) => {
          const linkedTask = item.linkedTaskId ? taskById.get(item.linkedTaskId) : null;
          const time = timelineLabel(item, linkedTask);
          return (
            <div className="day-agenda-timeline-row" key={item.id}>
              <div className="day-agenda-time">
                <strong>{time.start}</strong>
                {time.end && <span>{time.end}</span>}
              </div>
              <div className={`day-agenda-timeline-line ${item.source}`} aria-hidden="true" />
              <div className="day-agenda-timeline-content">
                <ScheduleEventCard item={item} task={linkedTask ?? null} onEdit={setEditingTask} onChanged={() => void refreshAll()} />
              </div>
            </div>
          );
        })}
      </div>
    )}
  </section>
  );

  return (
    <>
      <AgendaFrame inline={inline}
        title={dayTitle(date)}
        onClose={onClose}
        panelClassName="day-agenda-modal"
        backdropClassName="day-agenda-backdrop"
        headerAction={
          <button
            type="button"
            className="day-agenda-header-add"
            aria-label="この日に予定を追加"
            onClick={() => setCreateKind('event')}
          >
            ＋
          </button>
        }
      >
        <div className="day-agenda">
          <div className="day-agenda-handle" aria-hidden="true" />

          {planning.loading ? (
            <p role="status" className="day-agenda-loading">読み込み中…</p>
          ) : (
            <>
              {!inline && !planning.error && <div className="day-agenda-recording" role="status" aria-label="自分の記録状況">
                <TaskRecordingBadge summary={recording} future={date > tokyoIsoDate(new Date())} />
              </div>}
              {(planning.error || subtaskError) && (
                <p role="alert" className="error-text day-agenda-error">
                  {planning.error ?? subtaskError}
                </p>
              )}


              {!inline && scheduleSection}

              {(transportTasks.length > 0 || tokens.dropoff.token !== '—' || tokens.pickup.token !== '—') && (
                <section className="day-agenda-section day-agenda-transport-section">
                  <div className="day-agenda-section-heading">
                    <div>
                      <p className="eyebrow">送り迎え</p>
                      <h3>送迎</h3>
                    </div>
                    <span className="day-agenda-transport-summary">
                      {tokens.dropoff.token !== '—' && <b>送 {tokens.dropoff.token}</b>}
                      {tokens.pickup.token !== '—' && <b>迎 {tokens.pickup.token}</b>}
                    </span>
                  </div>
                  {transportTasks.length > 0 ? (
                    <ul className="task-list day-agenda-task-list">
                      {transportTasks.map((task) => renderTask(task))}
                    </ul>
                  ) : (
                    <p className="empty-hint">送迎担当だけ設定されています。</p>
                  )}
                  <RemoveDayTransport date={date} tasks={planning.tasks} onChanged={refreshAll} />
                </section>
              )}

              <section className="day-agenda-section day-agenda-tasks-section">
                <div className="day-agenda-section-heading">
                  <div>
                    <p className="eyebrow">チェックして進める</p>
                    <h3>実績・やること</h3>
                  </div>
                  {requiredTasks.length > 0 && (
                    <span className="day-agenda-progress">
                      記録 {recordedOperational}/{requiredTasks.length}
                    </span>
                  )}
                </div>
                {operationalTasks.length === 0 ? (
                  <button
                    type="button"
                    className="day-agenda-empty-action"
                    onClick={() => setCreateKind('task')}
                  >
                    やることはありません。＋ 追加
                  </button>
                ) : (
                  ownerGroups ? (
                    <>
                      {renderOwnerGroup('mine', `${meLabel}（自分）の担当`, ownerGroups.mine)}
                      {renderOwnerGroup('shared', '誰でもOK・担当未定', ownerGroups.shared)}
                      {renderOwnerGroup('partner', `${partnerLabel}の担当`, ownerGroups.partner, true)}
                    </>
                  ) : (
                    <ul className="task-list day-agenda-task-list">
                      {requiredTasks.map((task) => renderTask(task))}
                    </ul>
                  )
                )}
                {optionalTasks.length > 0 && (
                  <details className="day-agenda-optional">
                    <summary>
                      <span>余裕があれば</span>
                      <small>{optionalTasks.length}件</small>
                    </summary>
                    <ul className="task-list day-agenda-task-list">{optionalTasks.map((task) => renderTask(task))}</ul>
                  </details>
                )}
              </section>

              {inline && scheduleSection}

              <div className="day-agenda-sticky-actions" aria-label="この日に追加">
                <button type="button" className="secondary-button" onClick={() => setCreateKind('task')}>
                  ＋ やること
                </button>
                <button type="button" onClick={() => setCreateKind('event')}>
                  ＋ 予定
                </button>
              </div>
            </>
          )}
        </div>
      </AgendaFrame>

      {createKind && (
        <TaskFormModal
          mode="create"
          initialScheduledDate={date}
          initialCalendarVisibility={createKind === 'event' ? 'special' : 'hidden'}
          onClose={() => setCreateKind(null)}
          onSaved={() => {
            setCreateKind(null);
            void refreshAll();
          }}
        />
      )}

      {editingTask && (
        <TaskFormModal
          mode="edit"
          task={editingTask}
          onClose={() => setEditingTask(null)}
          onSaved={() => {
            setEditingTask(null);
            void refreshAll();
          }}
        />
      )}
    </>
  );
}
