import { useEffect, useState } from 'react';
import { FamilyOpsApiError } from '../../lib/apiClient';
import {
  disablePush,
  enablePush,
  fetchPushConfig,
  isPushEnabledHere,
  notificationPermission,
  pushAvailability,
  sendTestPush,
} from '../../lib/webPush';

type State =
  | { kind: 'loading' }
  | { kind: 'unsupported' }
  | { kind: 'needs-home-screen' }
  | { kind: 'not-configured' }
  | { kind: 'denied' }
  | { kind: 'off'; publicKey: string }
  | { kind: 'on'; publicKey: string };

export function PushSection() {
  const [state, setState] = useState<State>({ kind: 'loading' });
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    async function load() {
      const availability = pushAvailability();
      if (availability !== 'supported') {
        if (!cancelled) setState({ kind: availability });
        return;
      }
      try {
        const config = await fetchPushConfig();
        let next: State;
        if (!config.enabled || !config.publicKey) next = { kind: 'not-configured' };
        else if (notificationPermission() === 'denied') next = { kind: 'denied' };
        else next = { kind: (await isPushEnabledHere()) ? 'on' : 'off', publicKey: config.publicKey };
        if (!cancelled) setState(next);
      } catch {
        if (!cancelled) {
          setState({ kind: 'not-configured' });
          setError('通知の設定を確認できませんでした。通信状態を確認してください。');
        }
      }
    }
    void load();
    return () => {
      cancelled = true;
    };
  }, []);

  async function run(action: () => Promise<void>) {
    setBusy(true);
    setError(null);
    setMessage(null);
    try {
      await action();
    } catch (err) {
      setError(err instanceof FamilyOpsApiError ? err.message : '設定できませんでした。もう一度お試しください。');
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="card push-section">
      <h2>この端末への通知</h2>
      <p>
        予定の通知をこの端末に直接届けます。オンにした人には予定の通知をLINEでは送らないので、LINEの無料枠（家族で月200通）を節約できます。
      </p>
      {state.kind === 'loading' && <p role="status">確認中…</p>}
      {state.kind === 'unsupported' && (
        <p className="empty-hint">このブラウザは通知に対応していません。予定の通知はLINEで届きます。</p>
      )}
      {state.kind === 'needs-home-screen' && (
        <div className="push-howto">
          <p>iPhone・iPadでは、ホーム画面に追加したおうちノートで通知をオンにできます。</p>
          <ol>
            <li>Safariで共有ボタン（□に↑）を押す</li>
            <li>「ホーム画面に追加」を選ぶ</li>
            <li>ホーム画面のおうちノートを開き、この画面で通知をオンにする</li>
          </ol>
        </div>
      )}
      {state.kind === 'not-configured' && (
        <p className="empty-hint">この端末への通知はまだ使えません。予定の通知はLINEで届きます。</p>
      )}
      {state.kind === 'denied' && (
        <p className="empty-hint">
          通知が許可されていません。端末の設定で「おうちノート」の通知を許可してから、この画面を開き直してください（iPhone：設定 → 通知 → おうちノート）。
        </p>
      )}
      {state.kind === 'off' && (
        <button
          type="button"
          disabled={busy}
          onClick={() =>
            void run(async () => {
              const result = await enablePush(state.publicKey);
              if (result === 'denied') setState({ kind: 'denied' });
              else {
                setState({ kind: 'on', publicKey: state.publicKey });
                setMessage('この端末で通知を受け取ります。');
              }
            })
          }
        >
          {busy ? '設定中…' : 'この端末で通知を受け取る'}
        </button>
      )}
      {state.kind === 'on' && (
        <>
          <p className="task-item-meta">✓ この端末で予定の通知を受け取ります。</p>
          <div className="push-actions">
            <button
              type="button"
              className="secondary-button"
              disabled={busy}
              onClick={() =>
                void run(async () => {
                  const outcome = await sendTestPush();
                  if (outcome === 'sent') setMessage('テスト通知を送りました。届かない場合は端末の通知設定を確認してください。');
                  else if (outcome === 'gone') {
                    setState({ kind: 'off', publicKey: state.publicKey });
                    setMessage('この端末の通知が無効になっていました。もう一度オンにしてください。');
                  } else setError('テスト通知を送れませんでした。少し待ってからもう一度お試しください。');
                })
              }
            >
              テスト通知を送る
            </button>
            <button
              type="button"
              className="text-button"
              disabled={busy}
              onClick={() =>
                void run(async () => {
                  await disablePush();
                  setState({ kind: 'off', publicKey: state.publicKey });
                  setMessage('この端末への通知をオフにしました。予定の通知はLINEで届きます。');
                })
              }
            >
              この端末の通知をオフにする
            </button>
          </div>
        </>
      )}
      {message && <p role="status">{message}</p>}
      {error && (
        <p role="alert" className="error-text">
          {error}
        </p>
      )}
    </section>
  );
}
