import { useState } from 'react';
import { callEdgeFunction, FamilyOpsApiError } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { newOperationId } from '../../lib/id';
import { useHousehold } from '../../app/HouseholdContext';

interface InviteResult {
  raw_token: string;
  expires_at: string;
}

export function InviteSection() {
  const { partner } = useHousehold();
  const [invite, setInvite] = useState<InviteResult | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  async function handleGenerate() {
    setError(null);
    setSubmitting(true);
    try {
      const result = await callEdgeFunction<InviteResult>(EDGE_FUNCTIONS.createHouseholdInvite, {
        operation_id: newOperationId(),
      });
      setInvite(result);
    } catch (err) {
      if (err instanceof FamilyOpsApiError && err.code === 'INVITE_TOKEN_ALREADY_ISSUED') {
        setError('すでに発行済みの招待コードがあります。パートナーに以前共有したコードを確認してください。');
      } else {
        setError(err instanceof FamilyOpsApiError ? err.message : '招待の作成に失敗しました。');
      }
    } finally {
      setSubmitting(false);
    }
  }

  if (partner) {
    return (
      <section className="card">
        <h2>招待</h2>
        <p>
          パートナー「{partner.profile?.display_name ?? partner.user_id}」がすでに参加しています。
        </p>
      </section>
    );
  }

  return (
    <section className="card">
      <h2>パートナーを招待</h2>
      <p>招待コードを発行して、パートナーに共有してください。</p>
      <button type="button" onClick={handleGenerate} disabled={submitting}>
        {submitting ? '発行中…' : '招待コードを発行'}
      </button>
      {invite && (
        <div className="invite-result">
          <p>
            招待コード: <code>{invite.raw_token}</code>
          </p>
          <p>有効期限: {new Date(invite.expires_at).toLocaleString('ja-JP')}</p>
        </div>
      )}
      {error && (
        <p role="alert" className="error-text">
          {error}
        </p>
      )}
    </section>
  );
}
