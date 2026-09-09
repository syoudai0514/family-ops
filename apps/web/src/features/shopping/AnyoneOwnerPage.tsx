import { useCallback, useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { useHousehold } from '../../app/HouseholdContext';
import { callEdgeFunction, FamilyOpsApiError } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { newOperationId } from '../../lib/id';
import { supabase } from '../../lib/supabaseClient';

type AnyoneItem = {
  shopping_item_id: string;
  title: string;
  assignment_mode?: string | null;
  active_claimant_actor_ref_id?: string | null;
  active_claimant_display_name?: string | null;
  revision?: number | null;
};

type Workspace = {
  actor_ref_id?: string | null;
  active?: AnyoneItem[];
};

export function claimantDisclosure(item: AnyoneItem, actorRefId: string | null): string {
  if (!item.active_claimant_actor_ref_id) return '現在: まだ誰も対応中ではありません';
  if (actorRefId && item.active_claimant_actor_ref_id === actorRefId) return '現在: 自分が対応中';
  return item.active_claimant_display_name
    ? `現在: ${item.active_claimant_display_name}が対応中`
    : '現在: 対応者を確認できません';
}

export function claimantAction(item: AnyoneItem, actorRefId: string | null): 'claim' | 'release' | 'takeover' {
  if (!item.active_claimant_actor_ref_id) return 'claim';
  return actorRefId && item.active_claimant_actor_ref_id === actorRefId ? 'release' : 'takeover';
}

const ACTION_LABEL = { claim: '自分がやる', release: '手放す', takeover: '引き継ぐ' } as const;

export function AnyoneOwnerPage() {
  const { household } = useHousehold();
  const [items, setItems] = useState<AnyoneItem[]>([]);
  const [actorRefId, setActorRefId] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [busyId, setBusyId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    if (!household?.id) { setLoading(false); return; }
    setLoading(true);
    setError(null);
    const { data, error: readError } = await supabase.rpc('get_my_shopping_workspace');
    if (readError) setError(readError.message);
    else {
      const workspace = (data ?? {}) as Workspace;
      setActorRefId(workspace.actor_ref_id ?? null);
      setItems((workspace.active ?? []).filter((item) => item.assignment_mode === 'anyone'));
    }
    setLoading(false);
  }, [household?.id]);

  useEffect(() => { void load(); }, [load]);

  async function changeOwner(item: AnyoneItem) {
    const action = claimantAction(item, actorRefId);
    setBusyId(item.shopping_item_id);
    setError(null);
    try {
      await callEdgeFunction(EDGE_FUNCTIONS.claimShoppingItem, {
        operation_id: newOperationId(),
        shopping_item_id: item.shopping_item_id,
        action,
        expected_revision: item.revision ?? 1,
      });
      await load();
    } catch (err) {
      setError(err instanceof FamilyOpsApiError ? err.message : '担当状態を更新できませんでした。');
    } finally {
      setBusyId(null);
    }
  }

  if (loading) return <main className="app-shell">読み込み中…</main>;

  return (
    <main className="app-shell">
      <div className="today-header">
        <div><p className="eyebrow">誰でも担当</p><h1>今、誰が対応中？</h1></div>
        <Link to="/shopping" className="text-button">買い物へ戻る</Link>
      </div>
      <p className="page-lead">「誰でもOK」と「担当未定」は別です。誰かが取りかかったら現在の対応者を表示し、引き継ぎ前にも状態を確認できます。</p>
      {error && <p role="alert" className="error-text">{error}</p>}
      {items.length === 0 ? <p className="empty-hint">「誰でもOK」の未完了項目はありません。</p> : (
        <ul className="shopping-list">
          {items.map((item) => {
            const action = claimantAction(item, actorRefId);
            return <li className="shopping-item card" key={item.shopping_item_id}>
              <div>
                <strong>{item.title}</strong>
                <p className="task-item-meta">担当ルール: 誰でもOK · {claimantDisclosure(item, actorRefId)}</p>
                {action === 'takeover' && <p className="empty-hint">現在の対応者から引き継ぐ場合だけ「引き継ぐ」を押してください。</p>}
              </div>
              <button type="button" disabled={busyId === item.shopping_item_id} onClick={() => void changeOwner(item)}>{ACTION_LABEL[action]}</button>
            </li>;
          })}
        </ul>
      )}
    </main>
  );
}
