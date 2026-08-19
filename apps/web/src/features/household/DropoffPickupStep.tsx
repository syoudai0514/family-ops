import { useState, type FormEvent } from 'react';
import { callEdgeFunction, FamilyOpsApiError } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { newOperationId } from '../../lib/id';
import { WEEKDAYS } from '../../lib/weekdays';
import { useHousehold } from '../../app/HouseholdContext';

type DropoffPickupCode = 'dropoff' | 'pickup';
const TASK_CODES: { code: DropoffPickupCode; label: string }[] = [
  { code: 'dropoff', label: '送り' },
  { code: 'pickup', label: 'お迎え' },
];

interface CellState {
  enabled: boolean;
  fixedAssigneeId: string;
  scheduledLocalTime: string;
}

function cellKey(code: DropoffPickupCode, weekday: number): string {
  return `${code}-${weekday}`;
}

function initialCells(): Record<string, CellState> {
  const cells: Record<string, CellState> = {};
  for (const { code } of TASK_CODES) {
    for (const { value: weekday } of WEEKDAYS) {
      cells[cellKey(code, weekday)] = { enabled: false, fixedAssigneeId: '', scheduledLocalTime: '' };
    }
  }
  return cells;
}

// Confirmed against the shipped configure-dropoff-pickup Edge Function: it
// accepts any subset of the 14 (dropoff|pickup) x (1..7 weekday)
// combinations, unlike configure-evening-routines which requires an exact
// 7-code batch. This screen still submits the full 14-row grid every time
// (rows left unchecked go through as enabled:false) rather than a sparse
// diff — that's a superset of what's required, always valid, and simpler:
// the wizard UI already renders all 14 checkboxes regardless.
export function DropoffPickupStep() {
  const { household, members, refresh } = useHousehold();
  const [cells, setCells] = useState<Record<string, CellState>>(initialCells);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [operationId] = useState(() => newOperationId());

  function updateCell(code: DropoffPickupCode, weekday: number, patch: Partial<CellState>) {
    setCells((prev) => ({ ...prev, [cellKey(code, weekday)]: { ...prev[cellKey(code, weekday)], ...patch } }));
  }

  async function handleSubmit(event: FormEvent) {
    event.preventDefault();
    setError(null);

    for (const { code, label } of TASK_CODES) {
      for (const { value: weekday, label: dayLabel } of WEEKDAYS) {
        const cell = cells[cellKey(code, weekday)];
        if (cell.enabled && !cell.fixedAssigneeId) {
          setError(`${label}（${dayLabel}）の担当者を選んでください。`);
          return;
        }
      }
    }

    setSubmitting(true);
    try {
      const rows = TASK_CODES.flatMap(({ code }) =>
        WEEKDAYS.map(({ value: weekday }) => {
          const cell = cells[cellKey(code, weekday)];
          return {
            task_code: code,
            weekday,
            enabled: cell.enabled,
            fixed_assignee_id: cell.enabled ? cell.fixedAssigneeId : undefined,
            scheduled_local_time: cell.enabled && cell.scheduledLocalTime ? cell.scheduledLocalTime : undefined,
          };
        }),
      );

      await callEdgeFunction(EDGE_FUNCTIONS.configureDropoffPickup, { operation_id: operationId, rows });
      await refresh();
    } catch (err) {
      setError(err instanceof FamilyOpsApiError ? err.message : '保存に失敗しました。');
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <main className="app-shell">
      <h1>送り・お迎えの担当を設定</h1>
      <p>「{household?.name}」の曜日ごとの送り・お迎え担当を決めてください。</p>
      <form onSubmit={handleSubmit} className="stack-form">
        {TASK_CODES.map(({ code, label }) => (
          <fieldset key={code}>
            <legend>{label}</legend>
            {WEEKDAYS.map(({ value: weekday, label: dayLabel }) => {
              const cell = cells[cellKey(code, weekday)];
              return (
                <div className="wizard-row" key={weekday}>
                  <label className="wizard-row-check">
                    <input
                      type="checkbox"
                      checked={cell.enabled}
                      onChange={(e) => updateCell(code, weekday, { enabled: e.target.checked })}
                    />
                    {dayLabel}曜日
                  </label>
                  {cell.enabled && (
                    <>
                      <select
                        value={cell.fixedAssigneeId}
                        onChange={(e) => updateCell(code, weekday, { fixedAssigneeId: e.target.value })}
                        aria-label={`${label} ${dayLabel}曜日の担当者`}
                      >
                        <option value="">担当者を選択</option>
                        {members.map((m) => (
                          <option key={m.user_id} value={m.user_id}>
                            {m.profile?.display_name ?? m.user_id}
                          </option>
                        ))}
                      </select>
                      <input
                        type="time"
                        value={cell.scheduledLocalTime}
                        onChange={(e) => updateCell(code, weekday, { scheduledLocalTime: e.target.value })}
                        aria-label={`${label} ${dayLabel}曜日の時刻`}
                      />
                    </>
                  )}
                </div>
              );
            })}
          </fieldset>
        ))}
        {error && (
          <p role="alert" className="error-text">
            {error}
          </p>
        )}
        <button type="submit" disabled={submitting}>
          {submitting ? '保存中…' : '次へ'}
        </button>
      </form>
    </main>
  );
}
