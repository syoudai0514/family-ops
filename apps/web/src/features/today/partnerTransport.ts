import type { DailyBriefPartnerSummary } from './useTodayData';

// Ordinary work assigned to the other parent is not a checklist for the viewer.
// Transport is shared coordination; requests and schedules have their own sections.
export function partnerTransportItems(summary: DailyBriefPartnerSummary) {
  return (summary.critical_items ?? []).filter((item) => item.task_kind === 'transport');
}
