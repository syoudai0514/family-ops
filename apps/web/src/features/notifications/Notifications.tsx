import { useCallback, useEffect, useState } from 'react';
import { useAuth } from '../../app/AuthContext';
import { useHousehold } from '../../app/HouseholdContext';
import { supabase } from '../../lib/supabaseClient';
import { callEdgeFunction, FamilyOpsApiError } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { newOperationId } from '../../lib/id';
import { formatDateTimeJa } from '../../lib/date';
import type { NotificationPreferences, UserNotification } from '../../lib/types';

const PREFERENCE_FIELDS: { key: keyof Omit<NotificationPreferences, 'household_id' | 'user_id' | 'updated_at'>; label: string }[] = [
  { key: 'request_line', label: 'お願い通知' },
  { key: 'handover_line', label: '引き継ぎ通知' },
  { key: 'calendar_line', label: 'カレンダー通知' },
  { key: 'conflict_line', label: '予定重複の通知' },
  { key: 'routine_completion_line', label: 'ルーティン完了通知' },
  { key: 'shopping_minor_line', label: '買い物の細かい通知' },
  { key: 'weekly_digest_line', label: '週次まとめ' },
  { key: 'daily_assignment_line', label: '今日の担当のお知らせ' },
  { key: 'routine_checklist_line', label: 'ルーティンチェックリスト' },
  { key: 'routine_checkin_prompt_line', label: 'ルーティン確認の催促' },
  { key: 'in_app', label: 'アプリ内通知' },
];

function useNotifications(householdId: string | null, userId: string | null) {
  const [notifications, setNotifications] = useState<UserNotification[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    if (!householdId || !userId) {
      setLoading(false);
      return;
    }
    setLoading(true);
    const { data, error: fetchError } = await supabase
      .from('user_notifications')
      .select('*')
      .eq('household_id', householdId)
      .eq('recipient_user_id', userId)
      .order('created_at', { ascending: false });
    if (fetchError) setError(fetchError.message);
    else setNotifications(data ?? []);
    setLoading(false);
  }, [householdId, userId]);

  useEffect(() => {
    load();
  }, [load]);

  return { notifications, loading, error, refresh: load };
}

export function Notifications() {
  const { user } = useAuth();
  const { household } = useHousehold();
  const { notifications, loading, error, refresh } = useNotifications(household?.id ?? null, user?.id ?? null);

  return (
    <div className="app-shell">
      <h1>通知</h1>
      {error && (
        <p role="alert" className="error-text">
          {error}
        </p>
      )}
      <section className="card">
        <h2>通知一覧</h2>
        {loading ? (
          <p role="status">読み込み中…</p>
        ) : notifications.length === 0 ? (
          <p className="empty-hint">通知はありません。</p>
        ) : (
          <ul className="notification-list">
            {notifications.map((n) => (
              <NotificationRow key={n.id} notification={n} onChanged={refresh} />
            ))}
          </ul>
        )}
      </section>
      <PreferencesSection householdId={household?.id ?? null} userId={user?.id ?? null} />
    </div>
  );
}

function NotificationRow({ notification, onChanged }: { notification: UserNotification; onChanged: () => void }) {
  const [busy, setBusy] = useState(false);
  const isRead = Boolean(notification.read_at);

  async function markRead() {
    setBusy(true);
    try {
      await callEdgeFunction(EDGE_FUNCTIONS.markNotificationRead, {
        operation_id: newOperationId(),
        notification_id: notification.id,
      });
      onChanged();
    } finally {
      setBusy(false);
    }
  }

  return (
    <li className={isRead ? 'notification-item' : 'notification-item unread'}>
      <div>
        <strong>{notification.title}</strong>
        {notification.body && <p>{notification.body}</p>}
        <span className="task-item-meta">{formatDateTimeJa(notification.created_at)}</span>
      </div>
      {!isRead && (
        <button type="button" disabled={busy} onClick={markRead}>
          既読にする
        </button>
      )}
    </li>
  );
}

function usePreferences(householdId: string | null, userId: string | null) {
  const [preferences, setPreferences] = useState<NotificationPreferences | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    if (!householdId || !userId) {
      setLoading(false);
      return;
    }
    setLoading(true);
    const { data, error: fetchError } = await supabase
      .from('notification_preferences')
      .select('*')
      .eq('household_id', householdId)
      .eq('user_id', userId)
      .maybeSingle();
    if (fetchError) setError(fetchError.message);
    else setPreferences(data);
    setLoading(false);
  }, [householdId, userId]);

  useEffect(() => {
    load();
  }, [load]);

  return { preferences, loading, error, refresh: load };
}

function PreferencesSection({ householdId, userId }: { householdId: string | null; userId: string | null }) {
  const { preferences, loading, error, refresh } = usePreferences(householdId, userId);
  const [saving, setSaving] = useState<string | null>(null);
  const [saveError, setSaveError] = useState<string | null>(null);

  async function toggle(key: (typeof PREFERENCE_FIELDS)[number]['key']) {
    if (!preferences) return;
    setSaving(key);
    setSaveError(null);
    const nextValue = !preferences[key];
    try {
      // Partial update: only the single changed field is sent.
      await callEdgeFunction(EDGE_FUNCTIONS.updateNotificationPreferences, {
        operation_id: newOperationId(),
        [key]: nextValue,
      });
      await refresh();
    } catch (err) {
      setSaveError(err instanceof FamilyOpsApiError ? err.message : '保存に失敗しました。');
    } finally {
      setSaving(null);
    }
  }

  return (
    <section className="card">
      <h2>通知設定</h2>
      {loading && <p role="status">読み込み中…</p>}
      {error && (
        <p role="alert" className="error-text">
          {error}
        </p>
      )}
      {!loading && !preferences && <p className="empty-hint">通知設定がまだありません。</p>}
      {preferences && (
        <ul className="preference-list">
          {PREFERENCE_FIELDS.map(({ key, label }) => (
            <li key={key}>
              <label>
                <input
                  type="checkbox"
                  checked={Boolean(preferences[key])}
                  disabled={saving === key}
                  onChange={() => toggle(key)}
                />
                {label}
              </label>
            </li>
          ))}
        </ul>
      )}
      {saveError && (
        <p role="alert" className="error-text">
          {saveError}
        </p>
      )}
    </section>
  );
}
