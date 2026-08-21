import { useState, type FormEvent } from 'react';
import { callEdgeFunction, FamilyOpsApiError } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { newOperationId } from '../../lib/id';
import { useHousehold } from '../../app/HouseholdContext';

type Tab = 'create' | 'join';

export function HouseholdSetup() {
  const [tab, setTab] = useState<Tab>('create');
  const { refresh } = useHousehold();
  const tokenFromLink = new URLSearchParams(window.location.search).get('token') ?? '';

  return (
    <main className="app-shell">
      <h1>家庭を設定する</h1>
      <div className="tab-row" role="tablist">
        <button
          type="button"
          role="tab"
          aria-selected={tab === 'create'}
          className={tab === 'create' ? 'tab active' : 'tab'}
          onClick={() => setTab('create')}
        >
          新しく作る
        </button>
        <button
          type="button"
          role="tab"
          aria-selected={tab === 'join'}
          className={tab === 'join' ? 'tab active' : 'tab'}
          onClick={() => setTab('join')}
        >
          招待コードで参加する
        </button>
      </div>
      {tab === 'create' && !tokenFromLink ? (
        <CreateHouseholdForm onDone={refresh} />
      ) : (
        <JoinHouseholdForm onDone={refresh} initialToken={tokenFromLink} />
      )}
    </main>
  );
}

function CreateHouseholdForm({ onDone }: { onDone: () => void }) {
  const [householdName, setHouseholdName] = useState('');
  const [displayName, setDisplayName] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [operationId] = useState(() => newOperationId());

  async function handleSubmit(event: FormEvent) {
    event.preventDefault();
    setError(null);
    setSubmitting(true);
    try {
      await callEdgeFunction(EDGE_FUNCTIONS.createHousehold, {
        operation_id: operationId,
        household_name: householdName,
        display_name: displayName,
      });
      onDone();
    } catch (err) {
      setError(err instanceof FamilyOpsApiError ? err.message : '作成に失敗しました。');
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <form onSubmit={handleSubmit} className="stack-form">
      <label>
        家庭の名前
        <input
          value={householdName}
          onChange={(e) => setHouseholdName(e.target.value)}
          required
          placeholder="例: 田中家"
        />
      </label>
      <label>
        あなたの表示名
        <input
          value={displayName}
          onChange={(e) => setDisplayName(e.target.value)}
          required
          placeholder="例: たろう"
        />
      </label>
      {error && (
        <p role="alert" className="error-text">
          {error}
        </p>
      )}
      <button type="submit" disabled={submitting}>
        {submitting ? '作成中…' : '家庭を作る'}
      </button>
    </form>
  );
}

function JoinHouseholdForm({
  onDone,
  initialToken = '',
}: {
  onDone: () => void;
  initialToken?: string;
}) {
  const [inviteToken, setInviteToken] = useState(initialToken);
  const [displayName, setDisplayName] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [operationId] = useState(() => newOperationId());

  async function handleSubmit(event: FormEvent) {
    event.preventDefault();
    setError(null);
    setSubmitting(true);
    try {
      await callEdgeFunction(EDGE_FUNCTIONS.joinHousehold, {
        operation_id: operationId,
        invite_token: inviteToken,
        display_name: displayName,
      });
      onDone();
    } catch (err) {
      if (err instanceof FamilyOpsApiError) {
        if (err.code === 'INVITE_EXPIRED') setError('招待コードの有効期限が切れています。');
        else if (err.code === 'INVITE_USED') setError('この招待コードはすでに使用されています。');
        else if (err.code === 'HOUSEHOLD_FULL') setError('この家庭はすでに定員に達しています。');
        else setError(err.message);
      } else {
        setError('参加に失敗しました。');
      }
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <form onSubmit={handleSubmit} className="stack-form">
      <label>
        招待コード
        <input
          value={inviteToken}
          onChange={(e) => setInviteToken(e.target.value)}
          required
          placeholder="パートナーから共有された招待コード"
        />
      </label>
      <label>
        あなたの表示名
        <input
          value={displayName}
          onChange={(e) => setDisplayName(e.target.value)}
          required
          placeholder="例: はなこ"
        />
      </label>
      {error && (
        <p role="alert" className="error-text">
          {error}
        </p>
      )}
      <button type="submit" disabled={submitting}>
        {submitting ? '参加中…' : '参加する'}
      </button>
    </form>
  );
}
