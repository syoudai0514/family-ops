import { useMemo, useState } from 'react';
import { callEdgeFunction, FamilyOpsApiError } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { newOperationId } from '../../lib/id';

interface TomorrowPreparationCardProps {
  tomorrowDate: string;
  assigneeId: string | null;
  assigneeLabel: string;
  existingTitles: string[];
  onChanged: () => void;
}

function normalizedTitle(value: string) {
  return value.trim().replace(/\s+/g, ' ').toLocaleLowerCase('ja-JP');
}

function formatDate(date: string) {
  const parsed = new Date(`${date}T00:00:00+09:00`);
  return new Intl.DateTimeFormat('ja-JP', {
    timeZone: 'Asia/Tokyo',
    month: 'long',
    day: 'numeric',
    weekday: 'short',
  }).format(parsed);
}

export function TomorrowPreparationCard({
  tomorrowDate,
  assigneeId,
  assigneeLabel,
  existingTitles,
  onChanged,
}: TomorrowPreparationCardProps) {
  const [customTitle, setCustomTitle] = useState('');
  const [busyTitle, setBusyTitle] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const formattedDate = useMemo(() => formatDate(tomorrowDate), [tomorrowDate]);
  const registeredTitles = useMemo(
    () => new Set(existingTitles.map(normalizedTitle)),
    [existingTitles],
  );

  async function register(title: string) {
    const cleanTitle = title.trim();
    if (!cleanTitle || busyTitle) return;
    if (registeredTitles.has(normalizedTitle(cleanTitle))) {
      setError('同じ準備はすでに明日に追加されています。');
      setSuccess(null);
      return;
    }
    setBusyTitle(cleanTitle);
    setError(null);
    setSuccess(null);
    try {
      await callEdgeFunction(EDGE_FUNCTIONS.createHandover, {
        operation_id: newOperationId(),
        title: cleanTitle,
        scheduled_date: tomorrowDate,
        planned_assignee_user_id: assigneeId ?? undefined,
      });
      setSuccess(`${cleanTitle} を ${formattedDate} に引き継ぎました。`);
      setCustomTitle('');
      onChanged();
    } catch (err) {
      setError(err instanceof FamilyOpsApiError ? err.message : '引き継ぎの登録に失敗しました。');
    } finally {
      setBusyTitle(null);
    }
  }

  return (
    <section className="card tomorrow-preparation-card" aria-labelledby="tomorrow-preparation-title">
      <div className="section-heading">
        <div>
          <p className="eyebrow">迎えで分かった持ち物を、その場で翌朝へ</p>
          <h2 id="tomorrow-preparation-title">明日の準備・引き継ぎ</h2>
        </div>
        <span>{formattedDate}</span>
      </div>

      <p className="page-lead">
        登録すると、明日の「引き継ぎ・今日だけの準備」にチェック項目として出ます。
        {assigneeLabel ? ` 朝担当：${assigneeLabel}` : ' 朝担当はまだ未定です。'}
      </p>

      {existingTitles.length > 0 && (
        <div className="preparation-added-list" aria-label="すでに追加済みの準備">
          <p className="task-item-meta">追加済み</p>
          <ul>{existingTitles.map((title) => <li key={title}>✓ {title}</li>)}</ul>
        </div>
      )}

      <div className="task-item-actions preparation-custom-row">
        <input
          aria-label="明日の準備"
          value={customTitle}
          onChange={(event) => setCustomTitle(event.target.value)}
          placeholder="持ち物・提出物を追加"
          disabled={Boolean(busyTitle)}
        />
        <button
          type="button"
          disabled={!customTitle.trim() || Boolean(busyTitle)}
          onClick={() => void register(customTitle)}
        >
          明日に追加
        </button>
      </div>

      {success && <p role="status">✓ {success}</p>}
      {error && (
        <p className="error-text" role="alert">
          {error}
        </p>
      )}
    </section>
  );
}
