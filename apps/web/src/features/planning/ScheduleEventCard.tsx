import { useCallback, useEffect, useState, type FormEvent } from 'react';
import { Link } from 'react-router-dom';
import { useHousehold } from '../../app/HouseholdContext';
import { supabase } from '../../lib/supabaseClient';
import { useCommandAttempt } from '../../lib/useCommandAttempt';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import type { CalendarProjectionItem, PlanningTask } from './calendarProjection';
import {
  emptyScheduleDetails,
  SCHEDULE_ATTACHMENT_BUCKET,
  validateScheduleFiles,
} from './scheduleDetails';
import { uploadScheduleAttachment } from './scheduleAttachments';
import { tokyoIsoDate } from './dateHelpers';

type Attachment = { id: string; file_name: string; object_path: string; url?: string };
type Comment = { id: string; author_id: string; body: string; created_at: string };

function localTime(value: string | null | undefined) {
  return value
    ? new Intl.DateTimeFormat('en-GB', {
        timeZone: 'Asia/Tokyo',
        hour: '2-digit',
        minute: '2-digit',
        hour12: false,
      }).format(new Date(value))
    : null;
}

export function ScheduleEventCard({
  item,
  task,
  onEdit,
  onChanged,
}: {
  item: CalendarProjectionItem;
  task: PlanningTask | null;
  onEdit: (task: PlanningTask) => void;
  onChanged: () => void;
}) {
  const { members } = useHousehold();
  const [expanded, setExpanded] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const runCommand = useCommandAttempt();
  const details = {
    ...emptyScheduleDetails(task?.scheduled_date ?? item.localDate),
    ...task?.scheduler_details,
  };
  const checked = details.checked_items ?? [];
  const countdown = task
    ? Math.ceil(
        (Date.parse(`${task.scheduled_date}T00:00:00Z`) -
          Date.parse(`${tokyoIsoDate(new Date())}T00:00:00Z`)) /
          86400000,
      )
    : 0;
  async function toggleCheck(index: number) {
    if (!task) return;
    setBusy(true);
    setError(null);
    try {
      await runCommand(
        `schedule:${task.id}:check:${index}:r${task.revision ?? 1}`,
        EDGE_FUNCTIONS.editTask,
        (operationId) => ({
          operation_id: operationId,
          task_id: task.id,
          expected_revision: task.revision ?? 1,
          title: task.title,
          category: task.category,
          scheduled_date: task.scheduled_date,
          due_local_time: localTime(task.due_at),
          calendar_end_local_time: task.due_at ? localTime(task.calendar_ends_at) : null,
          calendar_visibility: task.calendar_visibility ?? 'hidden',
          planned_assignee_user_id: task.planned_assignee_id,
          scheduler_details: {
            ...details,
            checked_items: checked.includes(index)
              ? checked.filter((i) => i !== index)
              : [...checked, index],
          },
        }),
      );
      onChanged();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'チェックを保存できませんでした。');
    } finally {
      setBusy(false);
    }
  }
  return (
    <article className="schedule-event-card" style={{ borderLeftColor: details.label_color }}>
      <div className="schedule-event-heading">
        <button
          type="button"
          className="schedule-event-title"
          aria-expanded={expanded}
          onClick={() => setExpanded((v) => !v)}
        >
          <strong>{item.fullTitle}</strong>
          <span>
            {task
              ? item.kind === 'task'
                ? 'やること'
                : '予定'
              : item.source === 'google'
                ? 'Google Calendar'
                : 'おうちノート'}{' '}
            · {expanded ? '閉じる' : '詳細'}
          </span>
        </button>
        {task?.origin === 'manual' && task.status !== 'cancelled' && (
          <button type="button" className="secondary-button" onClick={() => onEdit(task)}>
            編集
          </button>
        )}
      </div>
      {details.pinned && <small>📌 メモ</small>}
      {details.countdown && (
        <small>
          {countdown > 0
            ? `あと${countdown}日`
            : countdown === 0
              ? '今日'
              : `${Math.abs(countdown)}日前`}
        </small>
      )}
      {(details.location || item.location) && (
        <p className="schedule-location">📍 {details.location || item.location}</p>
      )}
      {expanded && (
        <div className="schedule-event-body">
          <p className="meta">
            {task?.scheduled_date ?? item.localDate}
            {details.ends_on !== (task?.scheduled_date ?? item.localDate)
              ? ` 〜 ${details.ends_on}`
              : ''}
            {task?.due_at
              ? ` ${localTime(task.due_at)}${task.calendar_ends_at ? ` 〜 ${localTime(task.calendar_ends_at)}` : ''}`
              : item.allDay
                ? ' 終日'
                : ''}
          </p>
          {details.participants.length > 0 && (
            <p className="meta">
              参加:{' '}
              {details.participants
                .map((id) => members.find((m) => m.user_id === id)?.profile?.display_name ?? '家族')
                .join('・')}
            </p>
          )}
          {details.url && (
            <a href={details.url} target="_blank" rel="noreferrer">
              リンクを開く ↗
            </a>
          )}
          {(details.notes || item.description) && (
            <p className="schedule-notes">{details.notes || item.description}</p>
          )}
          {details.checklist.length > 0 && (
            <ul className="schedule-checklist">
              {details.checklist.map(
                (title, index) =>
                  title.trim() && (
                    <li key={index}>
                      <label>
                        <input
                          type="checkbox"
                          checked={checked.includes(index)}
                          disabled={busy || !task}
                          onChange={() => void toggleCheck(index)}
                        />
                        <span className={checked.includes(index) ? 'checked' : ''}>{title}</span>
                      </label>
                    </li>
                  ),
              )}
            </ul>
          )}
          {details.repeat_frequency !== 'none' && (
            <p className="meta">
              繰り返し:{' '}
              {
                ({ daily: '毎日', weekly: '毎週', monthly: '毎月' } as const)[
                  details.repeat_frequency
                ]
              }{' '}
              / {details.repeat_until}まで
            </p>
          )}
          {details.reminder_minutes !== null && (
            <p className="meta">
              通知: {details.reminder_minutes === 0 ? '開始時' : `${details.reminder_minutes}分前`}
            </p>
          )}
          {item.familyEventId && <Link to={`/events/${item.familyEventId}`}>行事と準備することを見る</Link>}
          {!task && (
            <p className="meta">
              {item.source === 'google'
                ? 'Google Calendar側で編集できます。'
                : '取り込んだ予定です。'}
            </p>
          )}
          {task && <ScheduleFilesAndComments task={task} />}
          {error && (
            <p role="alert" className="error-text">
              {error}
            </p>
          )}
        </div>
      )}
    </article>
  );
}

function ScheduleFilesAndComments({ task }: { task: PlanningTask }) {
  const { members } = useHousehold();
  const runCommand = useCommandAttempt();
  const [attachments, setAttachments] = useState<Attachment[]>([]);
  const [comments, setComments] = useState<Comment[]>([]);
  const [body, setBody] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const load = useCallback(async () => {
    const [files, messages] = await Promise.all([
      supabase
        .from('schedule_attachments')
        .select('id,file_name,object_path')
        .eq('household_id', task.household_id)
        .eq('task_id', task.id)
        .order('created_at'),
      supabase
        .from('schedule_comments')
        .select('id,author_id,body,created_at')
        .eq('household_id', task.household_id)
        .eq('task_id', task.id)
        .order('created_at'),
    ]);
    if (files.error || messages.error) {
      setError(files.error?.message ?? messages.error?.message ?? '読み込めませんでした。');
      return;
    }
    const signed = await Promise.all(
      (files.data ?? []).map(async (file: Attachment) => {
        const result = await supabase.storage
          .from(SCHEDULE_ATTACHMENT_BUCKET)
          .createSignedUrl(file.object_path, 3600);
        return { ...file, url: result.data?.signedUrl };
      }),
    );
    setAttachments(signed);
    setComments(messages.data ?? []);
  }, [task.household_id, task.id]);
  useEffect(() => {
    void load().catch((err) => setError(String(err)));
  }, [load]);
  async function addFiles(files: File[]) {
    setError(null);
    const invalid = validateScheduleFiles(files);
    if (invalid) {
      setError(invalid);
      return;
    }
    setBusy(true);
    try {
      for (const file of files) await uploadScheduleAttachment(task.household_id, task.id, file);
      await load();
    } catch (err) {
      setError(err instanceof Error ? err.message : '添付を保存できませんでした。');
      await load();
    } finally {
      setBusy(false);
    }
  }
  async function remove(file: Attachment) {
    setBusy(true);
    setError(null);
    try {
      await runCommand(
        `schedule:${task.id}:delete:${file.id}`,
        EDGE_FUNCTIONS.editTask,
        (operationId) => ({
          operation_id: operationId,
          sharing_action: 'delete_attachment',
          task_id: task.id,
          attachment_id: file.id,
        }),
      );
      await load();
    } catch (err) {
      setError(err instanceof Error ? err.message : '削除できませんでした。');
    } finally {
      setBusy(false);
    }
  }
  async function comment(event: FormEvent) {
    event.preventDefault();
    if (!body.trim()) return;
    setBusy(true);
    setError(null);
    try {
      await runCommand(
        `schedule:${task.id}:comment`,
        EDGE_FUNCTIONS.editTask,
        (operationId) => ({
          operation_id: operationId,
          sharing_action: 'add_comment',
          task_id: task.id,
          body: body.trim(),
        }),
      );
      setBody('');
      await load();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'コメントを保存できませんでした。');
    } finally {
      setBusy(false);
    }
  }
  return (
    <div className="schedule-sharing">
      <h4>添付ファイル</h4>
      <ul className="schedule-file-list">
        {attachments.map((file) => (
          <li key={file.id}>
            {file.url ? (
              <a href={file.url} target="_blank" rel="noreferrer">
                📎 {file.file_name}
              </a>
            ) : (
              <span>{file.file_name}（再読み込みしてください）</span>
            )}
            <button
              type="button"
              className="text-button"
              disabled={busy}
              onClick={() => void remove(file)}
              aria-label={`${file.file_name}を削除`}
            >
              削除
            </button>
          </li>
        ))}
      </ul>
      <label className="schedule-upload">
        ＋ 添付を追加
        <input
          type="file"
          multiple
          disabled={busy}
          accept="image/jpeg,image/png,image/webp,image/heic,image/heif,application/pdf,text/plain"
          onChange={(e) => {
            const files = Array.from(e.target.files ?? []);
            e.target.value = '';
            void addFiles(files);
          }}
        />
      </label>
      <p className="meta">家族に共有 / 画像・PDF・テキスト / 1件10MBまで</p>
      <h4>コメント</h4>
      <ul className="schedule-comment-list">
        {comments.map((message) => (
          <li key={message.id}>
            <small>
              {members.find((m) => m.user_id === message.author_id)?.profile?.display_name ??
                '家族'}{' '}
              ·{' '}
              {new Intl.DateTimeFormat('ja-JP', {
                timeZone: 'Asia/Tokyo',
                month: 'numeric',
                day: 'numeric',
                hour: '2-digit',
                minute: '2-digit',
              }).format(new Date(message.created_at))}
            </small>
            <p>{message.body}</p>
          </li>
        ))}
      </ul>
      <form onSubmit={(e) => void comment(e)} className="schedule-comment-form">
        <label>
          コメントを書く
          <textarea
            rows={2}
            value={body}
            onChange={(e) => setBody(e.target.value)}
            maxLength={4000}
          />
        </label>
        <button disabled={busy || !body.trim()}>{busy ? '保存中…' : '送信'}</button>
      </form>
      {error && (
        <p role="alert" className="error-text">
          {error}
        </p>
      )}
    </div>
  );
}
