// Routines (定例) grouped by who does them, for the role editor (owner instruction 2026-10-11).
// A routine's group comes from its weekly rules: 送りの人, 迎えの人, 誰でもOK, a fixed person…
// 「余裕があれば」 and stopped routines get their own groups whatever their rule.
import { WEEKDAYS } from '../../lib/weekdays';

export type RoutineStrategy =
  | 'dropoff_assignee'
  | 'pickup_assignee'
  | 'nonpickup_adult'
  | 'next_day_nondropoff_adult'
  | 'previous_evening_assignee'
  | 'anyone_adult'
  | 'fixed'
  | 'unassigned';

export const STRATEGY_LABELS: Record<RoutineStrategy, string> = {
  dropoff_assignee: '送りの人',
  pickup_assignee: '迎えの人',
  nonpickup_adult: '迎えない人',
  next_day_nondropoff_adult: '翌朝送らない人（前の晩に準備）',
  previous_evening_assignee: '前の晩に迎えた人',
  anyone_adult: '誰でもOK',
  fixed: '決まった人',
  unassigned: '決めない',
};

/** Rules whose person depends on the 送り・お迎え table; they can name who does it on a day without transport. */
export const TRANSPORT_ROLE_STRATEGIES: RoutineStrategy[] = ['dropoff_assignee', 'pickup_assignee', 'nonpickup_adult'];

export interface RoutineRule {
  weekday: number;
  strategy: RoutineStrategy;
  assigneeId: string | null;
  fallbackAssigneeId: string | null;
  localTime: string | null;
  slotKey: string;
}

export interface RoutineSubtask { id?: string; title: string; required: boolean }

export interface RoutineItem {
  id: string;
  code: string;
  title: string;
  taskKind: string;
  phase: string;
  active: boolean;
  optional: boolean;
  includeInLine: boolean;
  rules: RoutineRule[];
  subtasks: RoutineSubtask[];
}

export interface RoutineGroup { key: string; title: string; hint?: string; anchor?: string; items: RoutineItem[] }

/** Codmon rules live in their own slot; the generic weekly editor only owns the default slot. */
export function hasLockedSchedule(item: RoutineItem): boolean {
  return item.rules.some((rule) => rule.slotKey !== 'default');
}

export function routineGroupKey(item: RoutineItem): string {
  if (!item.active) return 'stopped';
  if (item.optional) return 'optional';
  const strategies = [...new Set(item.rules.map((rule) => rule.strategy === 'fixed' ? `fixed:${rule.assigneeId ?? ''}` : rule.strategy))];
  if (strategies.length === 0) return 'noschedule';
  if (strategies.length > 1) return 'mixed';
  return strategies[0];
}

const GROUP_ORDER: Array<{ key: string; title: string; hint?: string; anchor?: string }> = [
  { key: 'dropoff_assignee', title: '送りの人がやること', hint: '上の表で、その日に送りになった人' },
  { key: 'pickup_assignee', title: '迎えの人がやること', hint: '上の表で、その日にお迎えになった人' },
  { key: 'nonpickup_adult', title: '迎えない人がやること', hint: 'その日にお迎えをしない人' },
  { key: 'next_day_nondropoff_adult', title: '前の晩に、翌朝送らない人が準備すること', anchor: 'morning-preparation' },
  { key: 'previous_evening_assignee', title: '前の晩に迎えた人がやること' },
  { key: 'anyone_adult', title: '誰でもOK', hint: '手が空いている人がやる' },
  { key: 'unassigned', title: '担当を決めていない' },
  { key: 'mixed', title: '曜日で担当が変わる' },
  { key: 'optional', title: '余裕があれば', hint: 'やらなくても「できなかった」にならない' },
  { key: 'noschedule', title: '曜日が決まっていない' },
  { key: 'stopped', title: '止めている定例', hint: '今は作られません。押すと再開できます' },
];

export function groupRoutines(items: RoutineItem[], memberLabel: (userId: string) => string): RoutineGroup[] {
  const byKey = new Map<string, RoutineItem[]>();
  for (const item of items) {
    const key = routineGroupKey(item);
    byKey.set(key, [...(byKey.get(key) ?? []), item]);
  }
  const sortItems = (list: RoutineItem[]) => [...list].sort((a, b) => firstTime(a).localeCompare(firstTime(b)) || a.title.localeCompare(b.title, 'ja'));
  const groups: RoutineGroup[] = [];
  for (const group of GROUP_ORDER) {
    // Fixed people sit after 誰でもOK, one group per person.
    if (group.key === 'unassigned') {
      for (const key of [...byKey.keys()].filter((k) => k.startsWith('fixed:')).sort()) {
        groups.push({ key, title: `${memberLabel(key.slice('fixed:'.length))}がやること（固定）`, items: sortItems(byKey.get(key)!) });
      }
    }
    const list = byKey.get(group.key);
    if (list?.length) groups.push({ ...group, items: sortItems(list) });
  }
  return groups;
}

function firstTime(item: RoutineItem): string {
  const phaseOrder = item.phase === 'morning' ? '0' : item.phase === 'evening' ? '2' : '1';
  return phaseOrder + (item.rules.map((rule) => rule.localTime ?? '').filter(Boolean).sort()[0] ?? '99:99');
}

const PHASE_LABELS: Record<string, string> = { morning: '朝', evening: '夜', anytime: 'いつでも' };

/** 「月〜金」「火・土」「毎日」 */
export function weekdaySummary(weekdays: number[]): string {
  const days = [...new Set(weekdays)].sort((a, b) => a - b);
  if (days.length === 7) return '毎日';
  if (days.length === 0) return '曜日なし';
  const label = (day: number) => WEEKDAYS.find((w) => w.value === day)?.label ?? '';
  const consecutive = days.every((day, index) => index === 0 || day === days[index - 1] + 1);
  if (consecutive && days.length >= 3) return `${label(days[0])}〜${label(days[days.length - 1])}`;
  return days.map(label).join('・');
}

/** 「夜 · 月〜金 20:00」, plus the rule per day when it changes by weekday. */
export function routineSummary(item: RoutineItem, memberLabel: (userId: string) => string): string {
  const times = [...new Set(item.rules.map((rule) => rule.localTime).filter(Boolean))] as string[];
  const parts = [PHASE_LABELS[item.phase] ?? '', weekdaySummary(item.rules.map((rule) => rule.weekday))];
  if (times.length === 1) parts.push(times[0]);
  else if (times.length > 1) parts.push('時刻は曜日ごと');
  const key = routineGroupKey(item);
  if (key === 'mixed' || key === 'optional' || key === 'stopped') {
    const roles = [...new Set(item.rules.map((rule) => strategyLabel(rule, memberLabel)))];
    if (roles.length) parts.push(roles.join('／'));
  }
  return parts.filter(Boolean).join(' · ');
}

export function strategyLabel(rule: Pick<RoutineRule, 'strategy' | 'assigneeId'>, memberLabel: (userId: string) => string): string {
  return rule.strategy === 'fixed' && rule.assigneeId ? memberLabel(rule.assigneeId) : STRATEGY_LABELS[rule.strategy];
}
