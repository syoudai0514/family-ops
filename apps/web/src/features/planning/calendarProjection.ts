import type { TaskInstance } from '../../lib/types';

export type CalendarProjectionKind = 'transport' | 'special' | 'calendar' | 'request';
export type CalendarProjectionSource = 'family_ops' | 'google';
export type CalendarOwnerKind = 'primary' | 'partner' | 'family' | 'unknown';

export interface PlanningTask extends TaskInstance {
  definition_code?: string | null;
  calendar_visibility?: 'transport' | 'special' | 'hidden' | null;
}

export interface GooglePlanningOccurrence {
  id: string;
  date: string;
  time: string | null;
  endsAt?: string | null;
  title: string;
  allDay: boolean;
  allDayEndExclusive?: string | null;
  transparent: boolean;
  ownerUserId: string | null;
  providerEventId: string | null;
  generatedByFamilyOps: boolean;
  hasConflict: boolean;
  location?: string | null;
  description?: string | null;
  sourceCalendar?: string | null;
}

function addUtcDate(date: string, days: number) {
  const next = new Date(`${date}T00:00:00Z`);
  next.setUTCDate(next.getUTCDate() + days);
  return next.toISOString().slice(0, 10);
}

function projectionDates(event: GooglePlanningOccurrence): string[] {
  if (!event.allDay) return [event.date];
  const endExclusive = event.allDayEndExclusive ?? addUtcDate(event.date, 1);
  const dates: string[] = [];
  // Google all-day ends are exclusive. The guard prevents a bad provider row
  // from turning a Month/Week render into an unbounded loop.
  for (let date = event.date; date < endExclusive && dates.length < 366; date = addUtcDate(date, 1)) {
    dates.push(date);
  }
  return dates.length > 0 ? dates : [event.date];
}

export interface CalendarProjectionItem {
  id: string;
  source: CalendarProjectionSource;
  kind: CalendarProjectionKind;
  localDate: string;
  startsAt: string | null;
  endsAt: string | null;
  allDay: boolean;
  shortTitle: string;
  fullTitle: string;
  ownerUserId: string | null;
  ownerKind: CalendarOwnerKind;
  hasConflict: boolean;
  providerEventId: string | null;
  linkedTaskId: string | null;
  location: string | null;
  description: string | null;
  sourceCalendar: string | null;
}

export interface TransportProjection {
  id: string;
  localDate: string;
  dropoffAssigneeId: string | null;
  pickupAssigneeId: string | null;
  dropoffTaskId: string | null;
  pickupTaskId: string | null;
}

export interface CalendarProjection {
  transportByDate: Map<string, TransportProjection>;
  itemsByDate: Map<string, CalendarProjectionItem[]>;
  allItems: CalendarProjectionItem[];
}

const isTransport = (task: PlanningTask) =>
  task.definition_code === 'dropoff' || task.definition_code === 'pickup' ||
  task.category === 'dropoff' || task.category === 'pickup';

const isRoutine = (task: PlanningTask) =>
  task.routine_phase === 'morning' || task.routine_phase === 'evening';

function taskKind(task: PlanningTask): CalendarProjectionKind | null {
  if (isTransport(task)) return 'transport';
  // Visibility is an explicit domain value. The legacy fallback is based only
  // on persisted category/routine fields, never on a translated title.
  if (task.calendar_visibility === 'special') return 'special';
  if (task.calendar_visibility === 'hidden' || isRoutine(task)) return null;
  // An unknown/legacy row is not a special event merely because it is
  // non-routine. Calendar visibility must be an explicit persisted choice.
  return null;
}

function ownerKind(ownerUserId: string | null, primaryUserId: string | null, partnerUserId: string | null): CalendarOwnerKind {
  if (ownerUserId && ownerUserId === primaryUserId) return 'primary';
  if (ownerUserId && ownerUserId === partnerUserId) return 'partner';
  return ownerUserId ? 'family' : 'unknown';
}

function compactTitle(time: string | null, title: string, allDay: boolean) {
  if (!time || allDay) return title;
  const parsed = new Date(time);
  if (Number.isNaN(parsed.getTime())) return title;
  return `${new Intl.DateTimeFormat('ja-JP', { timeZone: 'Asia/Tokyo', hour: '2-digit', minute: '2-digit', hour12: false }).format(parsed)} ${title}`;
}

export function assigneeToken(ownerKind: CalendarOwnerKind) {
  if (ownerKind === 'primary') return 'P';
  if (ownerKind === 'partner') return 'M';
  if (ownerKind === 'family') return '家族';
  return '未';
}

export function transportTokens(transport: TransportProjection | undefined, primaryUserId: string | null, partnerUserId: string | null) {
  const value = (userId: string | null) => {
    if (!userId) return { token: '—', tone: 'none' };
    const owner = ownerKind(userId, primaryUserId, partnerUserId);
    return { token: assigneeToken(owner), tone: owner };
  };
  return { dropoff: value(transport?.dropoffAssigneeId ?? null), pickup: value(transport?.pickupAssigneeId ?? null) };
}

export function buildCalendarProjection({
  tasks,
  occurrences,
  primaryUserId,
  partnerUserId,
}: {
  tasks: PlanningTask[];
  occurrences: GooglePlanningOccurrence[];
  primaryUserId: string | null;
  partnerUserId: string | null;
}): CalendarProjection {
  const transportByDate = new Map<string, TransportProjection>();
  for (const task of tasks) {
    if (!isTransport(task)) continue;
    const current = transportByDate.get(task.scheduled_date) ?? {
      id: `transport:${task.scheduled_date}`,
      localDate: task.scheduled_date,
      dropoffAssigneeId: null,
      pickupAssigneeId: null,
      dropoffTaskId: null,
      pickupTaskId: null,
    };
    if (task.definition_code === 'dropoff' || task.category === 'dropoff') {
      current.dropoffAssigneeId = task.planned_assignee_id;
      current.dropoffTaskId = task.id;
    } else {
      current.pickupAssigneeId = task.planned_assignee_id;
      current.pickupTaskId = task.id;
    }
    transportByDate.set(task.scheduled_date, current);
  }

  const items: CalendarProjectionItem[] = [];
  for (const task of tasks) {
    const kind = taskKind(task);
    if (!kind || kind === 'transport') continue;
    const owner = ownerKind(task.planned_assignee_id, primaryUserId, partnerUserId);
    items.push({
      id: `task:${task.id}`,
      source: 'family_ops',
      kind,
      localDate: task.scheduled_date,
      startsAt: task.due_at,
      endsAt: task.calendar_ends_at ?? null,
      allDay: !task.due_at,
      shortTitle: compactTitle(task.due_at, task.title, !task.due_at),
      fullTitle: task.title,
      ownerUserId: task.planned_assignee_id,
      ownerKind: owner,
      hasConflict: false,
      providerEventId: null,
      linkedTaskId: task.id,
      location: null,
      description: null,
      sourceCalendar: 'Family Ops',
    });
  }
  for (const event of occurrences) {
    // A Family Ops mirror remains represented by its canonical task, not the
    // inbound Google occurrence. No title/date comparison is used.
    if (event.generatedByFamilyOps) continue;
    const owner = ownerKind(event.ownerUserId, primaryUserId, partnerUserId);
    const dates = projectionDates(event);
    for (const date of dates) {
      items.push({
        id: dates.length === 1 ? `google:${event.id}` : `google:${event.id}:${date}`,
        source: 'google',
        kind: 'calendar',
        localDate: date,
        startsAt: event.time,
        endsAt: event.endsAt ?? null,
        allDay: event.allDay,
        shortTitle: compactTitle(event.time, event.title, event.allDay),
        fullTitle: event.title,
        ownerUserId: event.ownerUserId,
        ownerKind: owner,
        hasConflict: event.hasConflict,
        providerEventId: event.providerEventId,
        linkedTaskId: null,
        location: event.location ?? null,
        description: event.description ?? null,
        sourceCalendar: event.sourceCalendar ?? null,
      });
    }
  }
  const rank = (item: CalendarProjectionItem) =>
    (item.hasConflict ? 0 : 10) + (item.kind === 'special' ? 0 : item.allDay ? 3 : 2);
  items.sort((a, b) => rank(a) - rank(b) || (a.startsAt ?? '').localeCompare(b.startsAt ?? '') || a.id.localeCompare(b.id));
  const itemsByDate = new Map<string, CalendarProjectionItem[]>();
  for (const item of items) itemsByDate.set(item.localDate, [...(itemsByDate.get(item.localDate) ?? []), item]);
  return { transportByDate, itemsByDate, allItems: items };
}

export function transportLabel(transport: TransportProjection | undefined, primaryUserId: string | null, partnerUserId: string | null) {
  if (!transport) return null;
  const token = (id: string | null) => id ? assigneeToken(ownerKind(id, primaryUserId, partnerUserId)) : '—';
  return `送 ${token(transport.dropoffAssigneeId)} ｜ 迎 ${token(transport.pickupAssigneeId)}`;
}
