import { useCallback, useEffect, useState } from 'react';
import { useFamilySetup } from '../settings/useFamilySetup';
import { useAuth } from '../../app/AuthContext';
import { useHousehold } from '../../app/HouseholdContext';
import { supabase } from '../../lib/supabaseClient';
import { callEdgeFunction, FamilyOpsApiError } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { newOperationId } from '../../lib/id';
import { formatDateTimeJa } from '../../lib/date';
import type { NotificationPreferences, UserNotification } from '../../lib/types';
import { PushSection } from './PushSection';
import { MorningNudgeSection } from './MorningNudgeSection';
import { ReminderSettingsSection } from './ReminderSettingsSection';

const PREFERENCE_FIELDS: {
  key: keyof Omit<NotificationPreferences, 'household_id' | 'user_id' | 'updated_at'>;
  label: string;
}[] = [
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
      .order('created_at', { ascending: false })
      .limit(30);
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
  const { notifications, loading, error } = useNotifications(
    household?.id ?? null,
    user?.id ?? null,
  );

  return (
    <div className="app-shell">
      <h1>通知</h1>
      {error && (
        <p role="alert" className="error-text">
          {error}
        </p>
      )}
      <PushSection />
      <MorningNudgeSection />
      <ReminderSettingsSection />
      <LineLinkSection />
      <PreferencesSection householdId={household?.id ?? null} userId={user?.id ?? null} />
      <section className="card">
        <h2>LINEで送った内容（控え）</h2>
        <p className="empty-hint">LINEに届いたものと同じ内容です。読んだかどうかはLINEで分かるので、ここで既読にする必要はありません。</p>
        {loading ? (
          <p role="status">読み込み中…</p>
        ) : notifications.length === 0 ? (
          <p className="empty-hint">まだ送った内容はありません。</p>
        ) : (
          <ul className="notification-list">
            {notifications.map((n) => (
              <NotificationRow key={n.id} notification={n} />
            ))}
          </ul>
        )}
      </section>
    </div>
  );
}

/** A 7-day code for the other adult: sent to them on LINE, it links their LINE to their place here. */
export function partnerLinkShareText(name: string, token: string, expiresAt: string): string {
  return [
    `おうちノートの「${name}」用のLINE連携コードです。`,
    '① 「おうちノート」をLINEで友だち追加',
    '② このメッセージを長押し →「転送」→「おうちノート」を選んで送信',
    '（コピーして、おうちノートのトークに貼り付けて送ってもOK）',
    `有効期限：${formatDateTimeJa(expiresAt)}`,
    '',
    token,
  ].join('\n');
}

function PartnerLineCode({ userId, name }: { userId: string; name: string }) {
  const [code, setCode] = useState<{ token: string; expiresAt: string } | null>(null);
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  async function create() {
    setBusy(true);
    setError(null);
    setNotice(null);
    try {
      const result = await callEdgeFunction<{ raw_token: string; expires_at: string }>(
        EDGE_FUNCTIONS.createLineLinkToken,
        { operation_id: newOperationId(), member_user_id: userId },
      );
      setCode({ token: result.raw_token, expiresAt: result.expires_at });
    } catch (err) {
      setError(err instanceof FamilyOpsApiError ? err.message : '連携コードを作れませんでした。');
    } finally {
      setBusy(false);
    }
  }

  async function send() {
    if (!code) return;
    const text = partnerLinkShareText(name, code.token, code.expiresAt);
    try {
      if (navigator.share) await navigator.share({ text });
      else {
        await navigator.clipboard.writeText(text);
        setNotice('コピーしました。LINEで送ってください。');
      }
    } catch (err) {
      if (!(err instanceof DOMException && err.name === 'AbortError')) setError('送れませんでした。もう一度お試しください。');
    }
  }

  return (
    <div className="partner-line-code">
      <p className="task-item-meta">{name}のLINEを、{name}本人のLINEにつなぎます。コードは7日間使えます。</p>
      {!code ? (
        <button type="button" className="secondary-button" disabled={busy} onClick={() => void create()}>
          {busy ? '作成中…' : `${name}用の連携コードを作る`}
        </button>
      ) : (
        <>
          <button type="button" onClick={() => void send()}>{name}にLINEで送る</button>
          <p className="task-item-meta">有効期限：{formatDateTimeJa(code.expiresAt)}。新しく作ると、前のコードは使えなくなります。</p>
        </>
      )}
      {notice && <p role="status">{notice}</p>}
      {error && <p role="alert" className="error-text">{error}</p>}
    </div>
  );
}

export function LineLinkSection() {
  const { data: familySetup, loading: statusLoading, error: statusError, refresh: refreshStatus } = useFamilySetup();
  const { members, me } = useHousehold();
  const [expiresAt, setExpiresAt] = useState<string | null>(null);
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => { const timer = window.setInterval(() => setNow(Date.now()), 15000); return () => window.clearInterval(timer); }, []);
  const expired = Boolean(expiresAt && new Date(expiresAt).getTime() <= now);
  const [token, setToken] = useState<string | null>(null);
  const [friendUrl, setFriendUrl] = useState<string | null>(null);
  const [followUrl, setFollowUrl] = useState<string | null>(null);
  const myLinked = Boolean(familySetup?.members?.find((member) => member.user_id === me?.user_id)?.line_linked);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);

  async function createLinkToken() {
    setBusy(true);
    setError(null);
    try {
      const result = await callEdgeFunction<{ raw_token: string; expires_at: string; line_add_friend_url?: string; line_follow_url?: string }>(
        EDGE_FUNCTIONS.createLineLinkToken,
        { operation_id: newOperationId() },
      );
      setToken(result.raw_token); setExpiresAt(result.expires_at); setCopied(false); setNow(Date.now());
      setFriendUrl(result.line_add_friend_url ?? null);
      setFollowUrl(result.line_follow_url ?? null);
    } catch (err) {
      setError(
        err instanceof FamilyOpsApiError ? err.message : 'LINE連携コードを発行できませんでした。',
      );
    } finally {
      setBusy(false);
    }
  }

  async function copyToken() {
    if (!token) return;
    try {
      await navigator.clipboard.writeText(token);
      setCopied(true);
    } catch {
      setError('コピーできませんでした。もう一度お試しください。');
    }
  }

  return (
    <section className="card">
      <h2>LINE連携</h2>
      <p>通知を受ける人ごとに、LINE公式アカウント「おうちノート」と連携します。</p>
      {statusLoading && <p role="status">連携状況を確認中…</p>}
      {statusError && <p role="alert">{statusError}</p>}
      {familySetup?.members.map(member => <p key={member.user_id} className="task-item-meta">{members.find(m => m.user_id === member.user_id)?.profile?.display_name ?? '家族'}：{member.line_linked ? 'LINE連携済み' : 'LINE未連携'}</p>)}
      {familySetup?.members.filter(member => member.user_id !== me?.user_id && !member.line_linked).map(member => (
        <PartnerLineCode key={member.user_id} userId={member.user_id} name={members.find(m => m.user_id === member.user_id)?.profile?.display_name ?? '家族'} />
      ))}
      <button type="button" className="text-button" disabled={statusLoading} onClick={() => void refreshStatus()}>連携状況を再確認</button>
      <p className="task-item-meta">連携済みでも通知が届かない場合は、LINEで公式アカウントのブロックと、下の通知設定を確認してください。</p>
      {myLinked ? (
        <p role="status">✓ あなたのLINEは「おうちノート」とつながっています。</p>
      ) : !token || expired ? (
        <button type="button" disabled={busy} onClick={createLinkToken}>
          {busy ? '準備中…' : expired ? '時間切れ：もう一度LINEとつなぐ' : 'LINEとつなぐ'}
        </button>
      ) : friendUrl ? (
        <ol className="line-link-steps">
          {followUrl && (
            <li>
              <a className="button-link" href={followUrl}>おうちノートを友だち追加</a>
              <span className="task-item-meta">LINEが開いたら「追加」を押して、この画面に戻ってきてください。</span>
            </li>
          )}
          <li>
            <a className="button-link" href={friendUrl}>LINEでつなぐ</a>
            <span className="task-item-meta">LINEが開いたら、そのまま「送信」を押すだけです。「LINE連携が完了しました」と届けば完了です。{expiresAt && `（${formatDateTimeJa(expiresAt)}まで）`}</span>
          </li>
          <li className="task-item-meta">
            <details><summary>うまく開かない時</summary>
              <p>次のコードを「おうちノート」のLINEトークへ送ってください。</p>
              <div className="line-link-token">
                <code>{token}</code>
                <button type="button" className="line-link-copy" onClick={copyToken}>{copied ? 'コピー済み' : 'コードをコピー'}</button>
              </div>
            </details>
          </li>
        </ol>
      ) : (
        <>
          <p>次のコードを「おうちノート」のLINEトークへ送信してください。{expiresAt && `期限：${formatDateTimeJa(expiresAt)}`}</p>
          <div className="line-link-token">
            <code>{token}</code>
            <button type="button" className="line-link-copy" onClick={copyToken}>
              {copied ? 'コピー済み' : 'コードをコピー'}
            </button>
          </div>
          <button type="button" className="text-button" disabled={busy} onClick={() => void createLinkToken()}>新しいコードを発行する</button>
          <p className="empty-hint">公式アカウントを友だち追加してから、上のコードをそのまま送信してください。</p>
        </>
      )}
      {error && (
        <p role="alert" className="error-text">
          {error}
        </p>
      )}
    </section>
  );
}

// A copy of what was sent on LINE. Read state is not tracked here: LINE already shows it, and
// nothing else used the in-app 既読 (owner 2026-10-10).
function NotificationRow({ notification }: { notification: UserNotification }) {
  const body = notification.body?.startsWith(notification.title)
    ? notification.body.slice(notification.title.length).trimStart()
    : notification.body;
  return (
    <li className="notification-item">
      <details className="notification-copy">
        <summary>
          <strong>{notification.title}</strong>
          <span className="task-item-meta">{formatDateTimeJa(notification.created_at)}</span>
        </summary>
        {body && <p>{body}</p>}
      </details>
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

function PreferencesSection({
  householdId,
  userId,
}: {
  householdId: string | null;
  userId: string | null;
}) {
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
