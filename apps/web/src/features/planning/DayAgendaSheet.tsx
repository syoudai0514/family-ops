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

function timelineLabel(item: CalendarProjectionItem) {
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

function taskSort(a: PlanningTask, b: PlanningTask) {
  const aDone = a.status === 'completed' ? 1 : 0;
  const bDone = b.status === 'completed' ? 1 : 0;
  if (aDone !== bDone) return aDone - bDone;
  return (a.due_at ?? '9999').localeCompare(b.due_at ?? '9999') || a.title.localeCompare(b.title);
}

export function DayAgendaSheet({
  date,
  onClose,
  onChanged,
}: {
  date: string;
  onClose: () => void;
  onChanged: () => void | Promise<void>;
}) {
  const { household, members, partner } = useHousehold();
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
  const timelineTaskIds = new Set(
    dayItems.map((item) => item.linkedTaskId).filter((id): id is string => Boolean(id)),
  );
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
        !isTransportTask(task) &&
        !timelineTaskIds.has(task.id),
    )
    .sort(taskSort);
  const completedOperational = operationalTasks.filter((task) => task.status === 'completed').length;
  const outstandingCount =
    operationalTasks.filter((task) => task.status !== 'completed').length +
    transportTasks.filter((task) => task.status !== 'completed').length +
    dayItems.filter((item) => {
      const task = item.linkedTaskId ? taskById.get(item.linkedTaskId) : null;
      return task ? task.status !== 'completed' : false;
    }).length;

  const renderTask = (task: PlanningTask, showTime = true) => (
    <TaskChecklistItem
      key={task.id}
      task={task}
      subtasks={subtasksByTaskId.get(task.id) ?? []}
      members={members}
      hasPartner={Boolean(partner)}
      onEdit={setEditingTask}
      onChanged={() => void refreshAll()}
      showTime={showTime}
    />
  );

  return (
    <>
      <Modal
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
              {(planning.error || subtaskError) && (
                <p role="alert" className="error-text day-agenda-error">
                  {planning.error ?? subtaskError}
                </p>
              )}

              <section className="day-agenda-overview" aria-label="その日の概要">
                <div>
                  <span>予定</span>
                  <strong>{dayItems.length}</strong>
                </div>
                <div>
                  <span>やること</span>
                  <strong>{operationalTasks.length + transportTasks.length}</strong>
                </div>
                <div className={outstandingCount > 0 ? 'attention' : 'done'}>
                  <span>{outstandingCount > 0 ? '未完了' : '完了'}</span>
                  <strong>{outstandingCount}</strong>
                </div>
              </section>

              {(transportTasks.length > 0 || tokens.dropoff.token !== '—' || tokens.pickup.token !== '—') && (
                <section className="day-agenda-section">
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
                </section>
              )}

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
                      const time = timelineLabel(item);
                      const linkedTask = item.linkedTaskId ? taskById.get(item.linkedTaskId) : null;
                      return (
                        <div className="day-agenda-timeline-row" key={item.id}>
                          <div className="day-agenda-time">
                            <strong>{time.start}</strong>
                            {time.end && <span>{time.end}</span>}
                          </div>
                          <div className={`day-agenda-timeline-line ${item.source}`} aria-hidden="true" />
                          <div className="day-agenda-timeline-content">
                            {linkedTask ? (
                              <ul className="task-list day-agenda-inline-task-list">
                                {renderTask(linkedTask, false)}
                              </ul>
                            ) : (
                              <article className="day-agenda-external-event">
                                <strong>{item.fullTitle}</strong>
                                <span className="day-agenda-source-badge">Google Calendar</span>
                                {item.location && <p>📍 {item.location}</p>}
                                {item.description && <p>{item.description}</p>}
                                <small>
                                  {item.sourceCalendar
                                    ? `${item.sourceCalendar} · Google側で編集`
                                    : 'Google側で編集'}
                                </small>
                              </article>
                            )}
                          </div>
                        </div>
                      );
                    })}
                  </div>
                )}
              </section>

              <section className="day-agenda-section day-agenda-tasks-section">
                <div className="day-agenda-section-heading">
                  <div>
                    <p className="eyebrow">チェックして進める</p>
                    <h3>やること</h3>
                  </div>
                  <span className="day-agenda-progress">
                    {completedOperational}/{operationalTasks.length}
                  </span>
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
                  <ul className="task-list day-agenda-task-list">
                    {operationalTasks.map((task) => renderTask(task))}
                  </ul>
                )}
              </section>

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
      </Modal>

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
