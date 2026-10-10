import { useCallback, useEffect, useRef, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { useHousehold } from '../../app/HouseholdContext';
import { supabase } from '../../lib/supabaseClient';
import { formatDateTimeJa } from '../../lib/date';
import { TaskFormModal } from '../tasks/TaskFormModal';
import type { TaskInstance, TaskSubtaskInstance } from '../../lib/types';
import { TaskChecklistItem } from '../tasks/TaskChecklistItem';

type EventRow = {
  id: string;
  title: string;
  all_day: boolean;
  starts_on: string | null;
  starts_at: string | null;
  location_text: string | null;
  details: string | null;
  status: string;
};
export function EventDetailPage() {
  const { id } = useParams();
  const { household, members, partner } = useHousehold();
  const householdId = household?.id;
  const [event, setEvent] = useState<EventRow | null>(null);
  const [tasks, setTasks] = useState<TaskInstance[]>([]);
  const [editingTask, setEditingTask] = useState<TaskInstance | null>(null);
  const [subtasks, setSubtasks] = useState<TaskSubtaskInstance[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const loadVersion = useRef(0);
  const load = useCallback(async () => {
    const version = ++loadVersion.current;
    if (!householdId || !id) {
      setLoading(false);
      return;
    }
    setLoading(true);
    setError(null);
    try {
      const [ev, todo] = await Promise.all([
        supabase
          .from('family_events')
          .select('id,title,all_day,starts_on,starts_at,location_text,details,status')
          .eq('household_id', householdId)
          .eq('id', id)
          .single(),
        supabase
          .from('task_instances')
          .select('*')
          .eq('household_id', householdId)
          .eq('event_id', id)
          .order('scheduled_date'),
      ]);
      if (ev.error || todo.error) throw ev.error ?? todo.error;
      const ids = (todo.data ?? []).map((t) => t.id);
      const st = ids.length
        ? await supabase
            .from('task_subtask_instances')
            .select('*')
            .in('task_instance_id', ids)
            .order('sort_order')
        : { data: [], error: null };
      if (st.error) throw st.error;
      if (version !== loadVersion.current) return;
      setSubtasks(st.data ?? []);
      setEvent(ev.data);
      setTasks(todo.data ?? []);
    } catch {
      if (version === loadVersion.current) setError('行事・準備を取得できませんでした。');
    } finally {
      if (version === loadVersion.current) setLoading(false);
    }
  }, [householdId, id]);
  useEffect(() => {
    void load();
    return () => {
      loadVersion.current++;
    };
  }, [load]);
  return (
    <main className="app-shell">
      <Link to="/week">‹ 週へ</Link>
      <h1>{event?.title ?? '行事と準備'}</h1>
      {loading && <p role="status">内容を確認中…</p>}
      {error && (
        <p role="alert">
          {error}
          <button onClick={() => void load()}>再読み込み</button>
        </p>
      )}
      {event && !loading && !error && (
        <>
          <section className="card">
            <h2>行事の予定</h2>
            <p>
              {event.all_day
                ? event.starts_on
                : event.starts_at && formatDateTimeJa(event.starts_at)}
            </p>
            {event.location_text && <p>{event.location_text}</p>}
            {event.details && <p>{event.details}</p>}
            {event.status === 'cancelled' && <p>中止した予定です。</p>}
          </section>
          <section className="card">
            <h2>準備すること</h2>
            <p className="task-item-meta">
              日付は準備の対象日です。担当未定の項目は、その日の詳細から担当を決められます。
            </p>
            {tasks.length === 0 ? (
              <p>登録された準備はありません。</p>
            ) : (
              <ul className="task-list">
                {tasks.map((task) => (
                  <li key={task.id}>
                    <Link to={`/today?date=${task.scheduled_date}`}>
                      {task.scheduled_date}の詳細
                    </Link>
                    <ul className="task-list">
                      <TaskChecklistItem
                        task={task}
                        subtasks={subtasks.filter((s) => s.task_instance_id === task.id)}
                        members={members}
                        hasPartner={Boolean(partner)}
                        onEdit={setEditingTask}
                        onChanged={load}
                        compact
                      />
                    </ul>
                  </li>
                ))}
              </ul>
            )}
          </section>
        </>
      )}
      {editingTask && (
        <TaskFormModal
          mode="edit"
          task={editingTask}
          onClose={() => setEditingTask(null)}
          onSaved={() => {
            setEditingTask(null);
            void load();
          }}
        />
      )}
    </main>
  );
}
