import { useState, type FormEvent } from 'react';
import { callEdgeFunction, FamilyOpsApiError } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { newOperationId } from '../../lib/id';
import { WEEKDAYS } from '../../lib/weekdays';
import { useHousehold } from '../../app/HouseholdContext';
import { EVENING_ROUTINE_TASK_CODES, type AssigneeStrategy, type EveningRoutineTaskCode } from '../../lib/types';

const TASK_LABELS: Record<EveningRoutineTaskCode, string> = {
  dinner: '夕食対応',
  bath: 'お風呂',
  laundry: '洗濯',
  dishes: '食器洗い',
  cleaning: '掃除',
  smile_zemi: 'スマイルゼミ',
  media_30min: 'テレビ/ゲーム30分管理',
};

const STRATEGY_LABELS: Record<AssigneeStrategy, string> = {
  pickup_assignee: 'お迎え担当者と同じ',
  nonpickup_adult: 'お迎え担当でない方',
  fixed: '固定の担当者',
};

interface RowState {
  enabled: boolean;
  weekdays: number[];
  assigneeStrategy: AssigneeStrategy;
  fixedAssigneeId: string;
  scheduledLocalTime: string;
}

function initialRows(): Record<EveningRoutineTaskCode, RowState> {
  const rows = {} as Record<EveningRoutineTaskCode, RowState>;
  for (const code of EVENING_ROUTINE_TASK_CODES) {
    rows[code] = {
      enabled: false,
      weekdays: [1, 2, 3, 4, 5, 6, 7],
      assigneeStrategy: 'nonpickup_adult',
      fixedAssigneeId: '',
      scheduledLocalTime: '',
    };
  }
  return rows;
}

export function EveningRoutinesStep() {
  const { household, members, refresh } = useHousehold();
  const [rows, setRows] = useState<Record<EveningRoutineTaskCode, RowState>>(initialRows);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [operationId] = useState(() => newOperationId());

  function updateRow(code: EveningRoutineTaskCode, patch: Partial<RowState>) {
    setRows((prev) => ({ ...prev, [code]: { ...prev[code], ...patch } }));
  }

  function toggleWeekday(code: EveningRoutineTaskCode, weekday: number) {
    setRows((prev) => {
      const current = prev[code].weekdays;
      const next = current.includes(weekday)
        ? current.filter((d) => d !== weekday)
        : [...current, weekday].sort((a, b) => a - b);
      return { ...prev, [code]: { ...prev[code], weekdays: next } };
    });
  }

  async function handleSubmit(event: FormEvent) {
    event.preventDefault();
    setError(null);

    for (const code of EVENING_ROUTINE_TASK_CODES) {
      const row = rows[code];
      if (row.enabled && row.assigneeStrategy === 'fixed' && !row.fixedAssigneeId) {
        setError(`${TASK_LABELS[code]}の固定担当者を選んでください。`);
        return;
      }
    }

    setSubmitting(true);
    try {
      const payloadRows = EVENING_ROUTINE_TASK_CODES.map((code) => {
        const row = rows[code];
        return {
          task_code: code,
          enabled: row.enabled,
          weekdays: row.weekdays,
          assignee_strategy: row.assigneeStrategy,
          fixed_assignee_id: row.assigneeStrategy === 'fixed' ? row.fixedAssigneeId : undefined,
          scheduled_local_time: row.scheduledLocalTime || undefined,
        };
      });

      await callEdgeFunction(EDGE_FUNCTIONS.configureEveningRoutines, {
        operation_id: operationId,
        rows: payloadRows,
      });
      await refresh();
    } catch (err) {
      setError(err instanceof FamilyOpsApiError ? err.message : '保存に失敗しました。');
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <main className="app-shell">
      <h1>夜のルーティンを設定</h1>
      <p>「{household?.name}」の毎晩の家事担当を決めてください。</p>
      <form onSubmit={handleSubmit} className="stack-form">
        {EVENING_ROUTINE_TASK_CODES.map((code) => {
          const row = rows[code];
          return (
            <fieldset key={code}>
              <legend>
                <label>
                  <input
                    type="checkbox"
                    checked={row.enabled}
                    onChange={(e) => updateRow(code, { enabled: e.target.checked })}
                  />
                  {TASK_LABELS[code]}
                </label>
              </legend>
              {row.enabled && (
                <div className="wizard-fieldset-body">
                  <div className="weekday-picker">
                    {WEEKDAYS.map(({ value, label }) => (
                      <label key={value} className="weekday-chip">
                        <input
                          type="checkbox"
                          checked={row.weekdays.includes(value)}
                          onChange={() => toggleWeekday(code, value)}
                        />
                        {label}
                      </label>
                    ))}
                  </div>
                  <label>
                    担当の決め方
                    <select
                      value={row.assigneeStrategy}
                      onChange={(e) => updateRow(code, { assigneeStrategy: e.target.value as AssigneeStrategy })}
                    >
                      {(Object.keys(STRATEGY_LABELS) as AssigneeStrategy[]).map((strategy) => (
                        <option key={strategy} value={strategy}>
                          {STRATEGY_LABELS[strategy]}
                        </option>
                      ))}
                    </select>
                  </label>
                  {row.assigneeStrategy === 'fixed' && (
                    <label>
                      固定担当者
                      <select
                        value={row.fixedAssigneeId}
                        onChange={(e) => updateRow(code, { fixedAssigneeId: e.target.value })}
                      >
                        <option value="">担当者を選択</option>
                        {members.map((m) => (
                          <option key={m.user_id} value={m.user_id}>
                            {m.profile?.display_name ?? m.user_id}
                          </option>
                        ))}
                      </select>
                    </label>
                  )}
                  <label>
                    予定時刻（任意）
                    <input
                      type="time"
                      value={row.scheduledLocalTime}
                      onChange={(e) => updateRow(code, { scheduledLocalTime: e.target.value })}
                    />
                  </label>
                </div>
              )}
            </fieldset>
          );
        })}
        {error && (
          <p role="alert" className="error-text">
            {error}
          </p>
        )}
        <button type="submit" disabled={submitting}>
          {submitting ? '保存中…' : '設定を完了する'}
        </button>
      </form>
    </main>
  );
}
