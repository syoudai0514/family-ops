import { useCallback, useEffect, useState, type FormEvent } from 'react';
import { useHousehold } from '../../app/HouseholdContext';
import { supabase } from '../../lib/supabaseClient';
import { callEdgeFunction, FamilyOpsApiError } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { newOperationId } from '../../lib/id';
import { getShoppingItemActions } from './shoppingActions';
import type { PurchaseMethod, ShoppingItem, ShoppingItemStatus } from '../../lib/types';

const STATUS_ORDER: ShoppingItemStatus[] = ['wanted', 'assigned', 'ordered', 'purchased', 'arrived', 'cancelled'];
const STATUS_LABELS: Record<ShoppingItemStatus, string> = {
  wanted: '欲しい',
  assigned: '担当決定',
  ordered: '注文済み',
  purchased: '購入済み',
  arrived: '到着済み',
  cancelled: 'キャンセル',
};
const PURCHASE_METHOD_LABELS: Record<PurchaseMethod, string> = {
  store: '店舗',
  online: 'オンライン',
  either: 'どちらでも',
  undecided: '未定',
};

function useShoppingItems(householdId: string | null) {
  const [items, setItems] = useState<ShoppingItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [actorRefId, setActorRefId] = useState<string | null>(null);

  const load = useCallback(async () => {
    if (!householdId) {
      setLoading(false);
      return;
    }
    setLoading(true);
    const { data, error: fetchError } = await supabase.rpc('get_my_shopping_workspace');
    if (fetchError) setError(fetchError.message);
    else {
      const workspace = (data ?? {}) as { actor_ref_id?: string; active?: Array<Record<string, unknown>>; history?: Array<Record<string, unknown>> };
      const rows = [...(workspace.active ?? []), ...(workspace.history ?? [])].map((row) => ({
        ...row,
        id: String(row.shopping_item_id),
      })) as unknown as ShoppingItem[];
      setItems(rows);
      setActorRefId(workspace.actor_ref_id ?? null);
    }
    setLoading(false);
  }, [householdId]);

  useEffect(() => {
    load();
  }, [load]);

  return { items, actorRefId, loading, error, refresh: load };
}

export function Shopping() {
  const { household, members } = useHousehold();
  const { items, actorRefId, loading, error, refresh } = useShoppingItems(household?.id ?? null);
  const [showForm, setShowForm] = useState(false);

  if (loading) return <div className="app-shell">読み込み中…</div>;

  const grouped = STATUS_ORDER.map((status) => ({
    status,
    items: items.filter((item) => item.status === status),
  })).filter((group) => group.items.length > 0);

  return (
    <div className="app-shell">
      <div className="today-header">
        <h1>買い物</h1>
        <button type="button" onClick={() => setShowForm((v) => !v)}>
          {showForm ? '閉じる' : '+ 追加'}
        </button>
      </div>
      {error && (
        <p role="alert" className="error-text">
          {error}
        </p>
      )}
      {showForm && (
        <AddShoppingItemForm
          onAdded={() => {
            setShowForm(false);
            refresh();
          }}
        />
      )}

      {grouped.length === 0 && <p className="empty-hint">買い物リストは空です。</p>}
      {grouped.map(({ status, items: statusItems }) => (
        <section className="card" key={status}>
          <h2>
            {STATUS_LABELS[status]} ({statusItems.length})
          </h2>
          <ul className="shopping-list">
            {statusItems.map((item) => (
              <ShoppingItemRow key={item.id} item={item} members={members} currentActorRefId={actorRefId} onChanged={refresh} />
            ))}
          </ul>
        </section>
      ))}
    </div>
  );
}

function ShoppingItemRow({
  item,
  members,
  currentActorRefId,
  onChanged,
}: {
  item: ShoppingItem;
  members: { user_id: string; profile: { display_name: string } | null }[];
  currentActorRefId: string | null;
  onChanged: () => void;
}) {
  const actions = getShoppingItemActions(item.status, item.purchase_method);
  const revision = item.revision ?? 1;
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function run(fn: () => Promise<unknown>) {
    setBusy(true);
    setError(null);
    try {
      await fn();
      onChanged();
    } catch (err) {
      if (err instanceof FamilyOpsApiError && err.code === 'INVALID_SHOPPING_TRANSITION') {
        setError('この操作は現在の状態では実行できません。');
      } else {
        setError(err instanceof FamilyOpsApiError ? err.message : '操作に失敗しました。');
      }
    } finally {
      setBusy(false);
    }
  }

  const assignee = members.find((m) => m.user_id === item.assignee_id);
  const assignmentMode = item.assignment_mode ?? (item.assignee_id ? 'person' : 'unassigned');
  const primaryAction = actions.canOrder
    ? { label: '注文した', run: () => callEdgeFunction(EDGE_FUNCTIONS.orderShoppingItem, { operation_id: newOperationId(), shopping_item_id: item.id, expected_revision: revision }) }
    : actions.canPurchase
      ? { label: '購入した', run: () => callEdgeFunction(EDGE_FUNCTIONS.purchaseShoppingItem, { operation_id: newOperationId(), shopping_item_id: item.id, expected_revision: revision }) }
      : actions.canArrive
        ? { label: '到着した', run: () => callEdgeFunction(EDGE_FUNCTIONS.arriveShoppingItem, { operation_id: newOperationId(), shopping_item_id: item.id, expected_revision: revision }) }
        : assignmentMode === 'anyone' && item.status === 'wanted' && !item.active_claimant_actor_ref_id
          ? { label: '自分がやる', run: () => callEdgeFunction(EDGE_FUNCTIONS.claimShoppingItem, { operation_id: newOperationId(), shopping_item_id: item.id, action: 'claim', expected_revision: revision }) }
          : null;

  return (
    <li className="shopping-item">
      <div>
        <strong>{item.title}</strong>
        <span className="task-item-meta">
          {' '}
          — {PURCHASE_METHOD_LABELS[item.purchase_method]}
          {assignee ? ` · 担当: ${assignee.profile?.display_name ?? assignee.user_id}` : ''}
          {assignmentMode === 'anyone' ? (item.active_claimant_actor_ref_id ? ' · 誰かが対応中' : ' · 誰でもOK') : ''}
        </span>
        {item.url && (
          <div>
            <a href={item.url} target="_blank" rel="noreferrer">
              {item.url}
            </a>
          </div>
        )}
      </div>
      <div className="shopping-item-actions">
        {primaryAction && (
          <button type="button" className="shopping-primary-action" disabled={busy} onClick={() => run(primaryAction.run)}>
            {primaryAction.label}
          </button>
        )}
        <details className="task-overflow shopping-overflow">
          <summary aria-label={`${item.title}のその他の操作`}>その他</summary>
          <div className="task-item-actions">
        {actions.canAssign && (
          <select
            aria-label="担当者を割り当て"
            disabled={busy}
            defaultValue=""
            onChange={(e) => {
              if (!e.target.value) return;
              run(() =>
                callEdgeFunction(EDGE_FUNCTIONS.assignShoppingItem, {
                  operation_id: newOperationId(),
                  shopping_item_id: item.id,
                  assignee_user_id: e.target.value,
                  assignment_mode: 'person',
                  expected_revision: revision,
                }),
              );
            }}
          >
            <option value="">担当者を割り当て</option>
            {members.map((m) => (
              <option key={m.user_id} value={m.user_id}>
                {m.profile?.display_name ?? m.user_id}
              </option>
            ))}
          </select>
        )}
        {actions.canUnassign && (
          <button
            type="button"
            disabled={busy}
            onClick={() =>
              run(() =>
                callEdgeFunction(EDGE_FUNCTIONS.assignShoppingItem, {
                  operation_id: newOperationId(),
                  shopping_item_id: item.id,
                  assignee_user_id: null,
                  assignment_mode: 'unassigned',
                  expected_revision: revision,
                }),
              )
            }
          >
            担当解除
          </button>
        )}
        {actions.canAssign && assignmentMode !== 'anyone' && (
          <button
            type="button"
            disabled={busy}
            onClick={() => run(() => callEdgeFunction(EDGE_FUNCTIONS.assignShoppingItem, {
              operation_id: newOperationId(), shopping_item_id: item.id,
              assignment_mode: 'anyone', assignee_user_id: null, expected_revision: revision,
            }))}
          >
            誰でもOK
          </button>
        )}
        {assignmentMode === 'anyone' && item.status === 'wanted' && !item.active_claimant_actor_ref_id && !primaryAction && (
          <button type="button" disabled={busy} onClick={() => run(() => callEdgeFunction(EDGE_FUNCTIONS.claimShoppingItem, {
            operation_id: newOperationId(), shopping_item_id: item.id, action: 'claim', expected_revision: revision,
          }))}>自分がやる</button>
        )}
        {assignmentMode === 'anyone' && item.status === 'wanted' && item.active_claimant_actor_ref_id && (
          <button
            type="button"
            disabled={busy}
            onClick={() => run(() => callEdgeFunction(EDGE_FUNCTIONS.claimShoppingItem, {
              operation_id: newOperationId(), shopping_item_id: item.id,
              action: item.active_claimant_actor_ref_id === currentActorRefId ? 'release' : 'takeover',
              expected_revision: revision,
            }))}
          >
            {item.active_claimant_actor_ref_id === currentActorRefId ? '担当を戻す' : '引き継ぐ'}
          </button>
        )}
        {actions.canOrder && primaryAction?.label !== '注文した' && (
          <button
            type="button"
            disabled={busy}
            onClick={() =>
              run(() =>
                callEdgeFunction(EDGE_FUNCTIONS.orderShoppingItem, {
                  operation_id: newOperationId(),
                  shopping_item_id: item.id,
                  expected_revision: revision,
                }),
              )
            }
          >
            注文した
          </button>
        )}
        {actions.canPurchase && primaryAction?.label !== '購入した' && (
          <button
            type="button"
            disabled={busy}
            onClick={() =>
              run(() =>
                callEdgeFunction(EDGE_FUNCTIONS.purchaseShoppingItem, {
                  operation_id: newOperationId(),
                  shopping_item_id: item.id,
                  expected_revision: revision,
                }),
              )
            }
          >
            購入した
          </button>
        )}
        {actions.canArrive && primaryAction?.label !== '到着した' && (
          <button
            type="button"
            disabled={busy}
            onClick={() =>
              run(() =>
                callEdgeFunction(EDGE_FUNCTIONS.arriveShoppingItem, {
                  operation_id: newOperationId(),
                  shopping_item_id: item.id,
                  expected_revision: revision,
                }),
              )
            }
          >
            到着した
          </button>
        )}
        {actions.canCancel && (
          <button
            type="button"
            disabled={busy}
            onClick={() =>
              run(() =>
                callEdgeFunction(EDGE_FUNCTIONS.cancelShoppingItem, {
                  operation_id: newOperationId(),
                  shopping_item_id: item.id,
                  expected_revision: revision,
                }),
              )
            }
          >
            キャンセル
          </button>
        )}
        {['ordered', 'purchased', 'arrived'].includes(item.status) && (
          <button
            type="button"
            disabled={busy}
            onClick={() => run(() => callEdgeFunction(EDGE_FUNCTIONS.reopenShoppingItem, {
              operation_id: newOperationId(), shopping_item_id: item.id,
              expected_revision: revision, reason: '操作を取り消して未対応に戻す',
            }))}
          >
            未対応に戻す
          </button>
        )}
          </div>
        </details>
      </div>
      {error && (
        <p role="alert" className="error-text">
          {error}
        </p>
      )}
    </li>
  );
}

function AddShoppingItemForm({ onAdded }: { onAdded: () => void }) {
  const { members } = useHousehold();
  const [title, setTitle] = useState('');
  const [purchaseMethod, setPurchaseMethod] = useState<PurchaseMethod>('undecided');
  const [assigneeId, setAssigneeId] = useState('');
  const [assignmentMode, setAssignmentMode] = useState<'person' | 'unassigned' | 'anyone'>('unassigned');
  const [url, setUrl] = useState('');
  const [dueDate, setDueDate] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleSubmit(event: FormEvent) {
    event.preventDefault();
    setError(null);
    setSubmitting(true);
    try {
      await callEdgeFunction(EDGE_FUNCTIONS.addShoppingItem, {
        operation_id: newOperationId(),
        title: title.trim(),
        purchase_method: purchaseMethod,
        assignee_user_id: assigneeId || undefined,
        assignment_mode: assignmentMode,
        duplicate_sensitivity: 'avoid_duplicate',
        url: url.trim() || undefined,
        due_at: dueDate ? new Date(dueDate).toISOString() : undefined,
      });
      onAdded();
    } catch (err) {
      setError(err instanceof FamilyOpsApiError ? err.message : '追加に失敗しました。');
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <form onSubmit={handleSubmit} className="stack-form card">
      <label>
        商品名
        <input value={title} onChange={(e) => setTitle(e.target.value)} required />
      </label>
      <label>
        購入方法
        <select value={purchaseMethod} onChange={(e) => setPurchaseMethod(e.target.value as PurchaseMethod)}>
          {(Object.keys(PURCHASE_METHOD_LABELS) as PurchaseMethod[]).map((m) => (
            <option key={m} value={m}>
              {PURCHASE_METHOD_LABELS[m]}
            </option>
          ))}
        </select>
      </label>
      <label>
        担当
        <select value={assignmentMode} onChange={(e) => {
          const mode = e.target.value as 'person' | 'unassigned' | 'anyone';
          setAssignmentMode(mode);
          if (mode !== 'person') setAssigneeId('');
        }}>
          <option value="unassigned">未定</option>
          <option value="anyone">誰でもOK</option>
          <option value="person">担当者を指定</option>
        </select>
      </label>
      {assignmentMode === 'person' && <label>
        担当者（任意）
        <select required value={assigneeId} onChange={(e) => setAssigneeId(e.target.value)}>
          <option value="">選択してください</option>
          {members.map((m) => (
            <option key={m.user_id} value={m.user_id}>
              {m.profile?.display_name ?? m.user_id}
            </option>
          ))}
        </select>
      </label>}
      <label>
        URL（任意）
        <input type="url" value={url} onChange={(e) => setUrl(e.target.value)} />
      </label>
      <label>
        期限（任意）
        <input type="datetime-local" value={dueDate} onChange={(e) => setDueDate(e.target.value)} />
      </label>
      {error && (
        <p role="alert" className="error-text">
          {error}
        </p>
      )}
      <button type="submit" disabled={submitting}>
        {submitting ? '追加中…' : '追加する'}
      </button>
    </form>
  );
}
