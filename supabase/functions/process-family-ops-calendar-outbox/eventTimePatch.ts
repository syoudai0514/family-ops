// Google Calendar PATCH merges nested objects. An event that changes between all-day
// and timed (2026-10-05: 将生のプール, "14:00" all-day -> 14:00-15:00) keeps the old
// start.date next to the new start.dateTime and the PATCH is refused with 400. The
// field the desired event does not use is therefore cleared explicitly with null.

type EventTime = Record<string, unknown>;

function exclusiveTime(time: unknown): unknown {
  if (!time || typeof time !== "object") return time;
  const t = time as EventTime;
  if (typeof t.dateTime === "string") return { ...t, date: null };
  if (typeof t.date === "string") return { ...t, dateTime: null, timeZone: null };
  return time;
}

export function withExclusiveEventTimes(body: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = { ...body };
  if ("start" in body) out.start = exclusiveTime(body.start);
  if ("end" in body) out.end = exclusiveTime(body.end);
  return out;
}
