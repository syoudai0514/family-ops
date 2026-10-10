import { useCallback, useEffect, useRef, useState } from 'react';
import { useHousehold } from '../../app/HouseholdContext';
import { callEdgeFunction } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { formatDateTimeJa } from '../../lib/date';

type Target = {
  id: string;
  title: string;
  date: string;
  due_at: string | null;
  from_user_id: string | null;
  to_user_id: string | null;
};
type Preview = {
  targets: Target[];
  linked: Target[];
  stale: boolean;
  revision: number;
  terms_revision: number;
};
export function AssignmentPreview({
  requestId,
  attemptId,
  expectedRevision,
  expectedTermsRevision,
  onReady,
}: {
  requestId: string;
  attemptId: string;
  expectedRevision: number;
  expectedTermsRevision: number;
  onReady: (ready: boolean) => void;
}) {
  const { members } = useHousehold();
  const [preview, setPreview] = useState<Preview | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const loadVersion = useRef(0);
  const load = useCallback(async () => {
    const version = ++loadVersion.current;
    setLoading(true);
    setError(null);
    onReady(false);
    try {
      const result = await callEdgeFunction<Preview>(EDGE_FUNCTIONS.familySetup, {
        action: 'assignment_preview',
        request_id: requestId,
        attempt_id: attemptId,
      });
      if (version !== loadVersion.current) return;
      if (
        !Array.isArray(result.targets) ||
        !Array.isArray(result.linked) ||
        result.targets.length === 0
      )
        throw new Error('対象の担当を確認できませんでした。');
      if (
        result.stale ||
        result.revision !== expectedRevision ||
        result.terms_revision !== expectedTermsRevision
      )
        throw new Error('家族が先に変更しました。お願いを読み直して最新の条件を確認してください。');
      setPreview(result);
      onReady(true);
    } catch (err) {
      if (version === loadVersion.current)
        setError(err instanceof Error ? err.message : '変更内容を取得できませんでした。');
    } finally {
      if (version === loadVersion.current) setLoading(false);
    }
  }, [requestId, attemptId, expectedRevision, expectedTermsRevision, onReady]);
  useEffect(() => {
    void load();
    return () => {
      loadVersion.current++;
    };
  }, [load]);
  const name = (id: string | null) => {
    const m = members.find((m) => m.user_id === id);
    return m?.family_role === 'papa'
      ? 'パパ'
      : m?.family_role === 'mama'
        ? 'ママ'
        : (m?.profile?.display_name ?? '未担当');
  };
  const list = (rows: Target[]) => (
    <ul>
      {rows.map((row) => (
        <li key={row.id}>
          {row.due_at ? formatDateTimeJa(row.due_at) : row.date} · {row.title}
          <br />
          <small>
            {name(row.from_user_id)} → {name(row.to_user_id)}
          </small>
        </li>
      ))}
    </ul>
  );
  return (
    <div aria-label="変わる担当">
      {loading && <p role="status">変わる担当を確認中…</p>}
      {error && (
        <p role="alert">
          {error}
          <button type="button" className="text-button" onClick={() => void load()}>
            再確認
          </button>
        </p>
      )}
      {!loading && !error && preview && (
        <>
          <strong>お願いの対象</strong>
          {list(preview.targets)}
          {preview.linked.length > 0 && (
            <>
              <strong>一緒に変わる当日の家事</strong>
              {list(preview.linked)}
            </>
          )}
          <p className="task-item-meta">確定後も、個別に合意した担当は保たれます。</p>
        </>
      )}
    </div>
  );
}
