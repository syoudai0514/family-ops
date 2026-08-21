export interface RecurrencePatternRow {
  weekday: number;
  assignee_strategy: string;
  planned_assignee_id: string | null;
  scheduled_local_time: string | null;
}

export function groupRecurrencePatterns<T extends RecurrencePatternRow>(rules: T[]): T[][] {
  const groups = new Map<string, T[]>();
  for (const rule of rules) {
    const key = [
      rule.assignee_strategy,
      rule.planned_assignee_id ?? '',
      rule.scheduled_local_time?.slice(0, 5) ?? '',
    ].join('|');
    groups.set(key, [...(groups.get(key) ?? []), rule]);
  }
  return [...groups.values()];
}
