import { WEEKDAYS } from '../../lib/weekdays';

const LABELS: Record<string, string> = {
  title: '内容',
  text: '共有内容',
  due_date: '期限・日付',
  date: '日付',
  scheduled_date: '対象日',
  location: '場所',
  details: '詳細',
  url: 'リンク先',
  destination: '提出先',
  add_to_calendar: 'カレンダーにも表示',
  effective_from: '開始日',
  effective_to: '終了日',
  occurrence_date: 'この日のみ',
  trigger_spec: 'いつ必要か',
  preparation_template: '準備する内容',
  items: '準備するもの',
  event: '対象の行事',
  weekdays: '曜日',
  weekday: '曜日',
  recurrence: '繰り返し',
  rules: '繰り返しのルール',
  rule: 'ルール',
  scheduled_local_time: '時刻',
  local_time: '時刻',
  time: '時刻',
  start_time: '開始時刻',
  end_time: '終了時刻',
  starts_at: '開始日時',
  ends_at: '終了日時',
  start_date: '開始日',
  end_date: '終了日',
  starts_on: '開始日',
  ends_on: '終了日',
  all_day: '終日',
  due_at: '期限の日時',
  required: '必須',
  task_kind: '種類',
  assignee_strategy: '担当の決め方',
  source_text: 'おたよりの記載',
  month: '月',
  day: '日',
  interval: '間隔',
  frequency: '頻度',
};
const STRATEGIES = {
  fixed: '指定した人',
  dropoff_assignee: '送り担当',
  pickup_assignee: 'お迎え担当',
  nonpickup_adult: 'お迎え以外の人',
  unassigned: '未担当',
};

export function NurseryValueFields({
  value,
  onChange,
}: {
  value: Record<string, unknown>;
  onChange: (value: Record<string, unknown>) => void;
}) {
  return (
    <div className="form-grid">
      {Object.entries(value).map(([key, entry]) => (
        <ValueField
          key={key}
          field={key}
          value={entry}
          label={LABELS[key] ?? '補足'}
          onChange={(next) => onChange({ ...value, [key]: next })}
        />
      ))}
    </div>
  );
}
function ValueField({
  field,
  value,
  label,
  onChange,
}: {
  field: string;
  value: unknown;
  label: string;
  onChange: (value: unknown) => void;
}) {
  if (field === 'weekdays' && Array.isArray(value))
    return (
      <fieldset>
        <legend>{label}</legend>
        <div className="weekday-picker">
          {WEEKDAYS.map((day) => (
            <label key={day.value}>
              <input
                type="checkbox"
                checked={value.includes(day.value)}
                onChange={() =>
                  onChange(
                    value.includes(day.value)
                      ? value.filter((v) => v !== day.value)
                      : [...value, day.value].sort(),
                  )
                }
              />
              {day.label}
            </label>
          ))}
        </div>
      </fieldset>
    );
  if (field === 'weekday' && typeof value === 'number')
    return (
      <label>
        {label}
        <select value={value} onChange={(e) => onChange(Number(e.target.value))}>
          {WEEKDAYS.map((day) => (
            <option key={day.value} value={day.value}>
              {day.label}
            </option>
          ))}
        </select>
      </label>
    );
  if (Array.isArray(value))
    return (
      <fieldset>
        <legend>{label}</legend>
        {value.map((entry, index) => (
          <div key={index}>
            <ValueField
              field={field}
              value={entry}
              label={`${label} ${index + 1}`}
              onChange={(next) => onChange(value.map((old, i) => (i === index ? next : old)))}
            />
            <button
              type="button"
              className="text-button"
              onClick={() => onChange(value.filter((_, i) => i !== index))}
            >
              この項目を外す
            </button>
          </div>
        ))}
        {value.every((v) => typeof v === 'string') && (
          <button type="button" className="text-button" onClick={() => onChange([...value, ''])}>
            ＋項目を追加
          </button>
        )}
      </fieldset>
    );
  if (value && typeof value === 'object')
    return (
      <fieldset>
        <legend>{label}</legend>
        <NurseryValueFields value={value as Record<string, unknown>} onChange={onChange} />
      </fieldset>
    );
  if (typeof value === 'boolean')
    return (
      <label>
        <input type="checkbox" checked={value} onChange={(e) => onChange(e.target.checked)} />
        {label}
      </label>
    );
  if (field === 'assignee_strategy' && typeof value === 'string')
    return (
      <label>
        {label}
        <select value={value} onChange={(e) => onChange(e.target.value)}>
          {!Object.hasOwn(STRATEGIES, value) && <option value={value}>現在の設定</option>}
          {Object.entries(STRATEGIES).map(([key, text]) => (
            <option key={key} value={key}>
              {text}
            </option>
          ))}
        </select>
      </label>
    );
  const type =
    typeof value === 'number'
      ? 'number'
      : field === 'url'
        ? 'url'
        : /^(date|due_date|scheduled_date|effective_from|effective_to|occurrence_date|start_date|end_date|starts_on|ends_on)$/.test(
              field,
            )
          ? 'date'
          : /^(time|local_time|scheduled_local_time|start_time|end_time)$/.test(field)
            ? 'time'
            : 'text';
  return (
    <label>
      {label}
      <input
        type={type}
        value={value == null ? '' : String(value)}
        onChange={(e) =>
          onChange(
            typeof value === 'number'
              ? Number(e.target.value)
              : e.target.value || (value === null ? null : ''),
          )
        }
      />
    </label>
  );
}
